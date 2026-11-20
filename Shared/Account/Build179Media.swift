import Foundation

/// Build 179 (versie 1.0.8), punten 9, 10, 11 en 16: beoordelingen (MDBList via de server), intro/samenvatting
/// (IntroDB via de server), "Voor jou" met duimen en WebDAV als bron. Pure logica, gelijk op alle platforms (Android
/// `Build179Logic.kt`, web `web/js/build179.js`); gedeelde testgevallen: docs/build179_cases.json (secties ratingText,
/// forYou, webdavParse). Alleen Foundation: de zelftest compileert dit bestand los van de app.
/// Contract: docs/ACCOUNT.md → "Build 179".
extension Build179 {

    // MARK: 9. Beoordelingen (ratingText)

    /// Bronnen in de volgorde van de rij op de detailpagina.
    static let ratingSources = ["imdb", "tomatoes", "tomatoesaudience", "metacritic", "letterboxd", "trakt", "tmdb"]

    /// Score als tekst: imdb, tmdb, letterboxd één decimaal; tomatoes, tomatoesaudience, trakt als percentage;
    /// metacritic als geheel getal; onbekende bron of geen waarde = nil (niet tonen).
    static func ratingText(_ source: String, _ value: Double?) -> String? {
        guard let v = value, v.isFinite, v > 0 else { return nil }
        switch source {
        case "imdb", "tmdb", "letterboxd": return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
        case "tomatoes", "tomatoesaudience", "trakt": return "\(Int(v.rounded()))%"
        case "metacritic": return "\(Int(v.rounded()))"
        default: return nil
        }
    }

    /// Korte naam op de rij ("RT", "MC"); `audience` = de vertaalde naam van het publiek van Rotten Tomatoes.
    static func ratingName(_ source: String, audience: String) -> String {
        switch source {
        case "imdb": return "IMDb"
        case "tmdb": return "TMDB"
        case "tomatoes": return "RT"
        case "tomatoesaudience": return audience
        case "metacritic": return "MC"
        case "letterboxd": return "Letterboxd"
        case "trakt": return "Trakt"
        default: return source
        }
    }

    /// Antwoord van de functie `ratings` → (bron, waarde), alleen bekende bronnen, in de volgorde van de rij.
    static func parseRatings(_ json: [String: Any]) -> [(source: String, value: Double)]? {
        guard (json["ok"] as? Bool) == true, let list = json["ratings"] as? [[String: Any]] else { return nil }
        var out: [(source: String, value: Double)] = []
        for r in list {
            guard let s = r["source"] as? String, ratingSources.contains(s), !out.contains(where: { $0.source == s }),
                  let v = (r["value"] as? NSNumber)?.doubleValue, ratingText(s, v) != nil else { continue }
            out.append((s, v))
        }
        return out.sorted { ratingSources.firstIndex(of: $0.source)! < ratingSources.firstIndex(of: $1.source)! }
    }

    // MARK: 10. IntroDB

    /// Tijden van één aflevering (seconden); nil = niet bekend.
    struct Segments: Codable, Equatable {
        var introStart: Double?
        var introEnd: Double?
        var recapStart: Double?
        var recapEnd: Double?
        var creditsStart: Double?
        var isEmpty: Bool { introEnd == nil && recapEnd == nil && creditsStart == nil }
    }

    /// Antwoord van de functie `introdb` → tijden; nil bij `ok: false` (dan de bestaande markeringen).
    static func parseIntro(_ json: [String: Any]) -> Segments? {
        guard (json["ok"] as? Bool) == true else { return nil }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func seg(_ k: String) -> (Double, Double?)? {
            guard let d = json[k] as? [String: Any], let s = num(d["start"]), s >= 0 else { return nil }
            let e = num(d["end"])
            return (s, e.flatMap { $0 > s ? $0 : nil })
        }
        var out = Segments()
        if let i = seg("intro"), let e = i.1 { out.introStart = i.0; out.introEnd = e }
        if let r = seg("recap"), let e = r.1 { out.recapStart = r.0; out.recapEnd = e }
        if let c = seg("credits") { out.creditsStart = c.0 }
        return out.isEmpty ? nil : out
    }

    /// Wat de knop nu overslaat: (eind, is samenvatting) als `t` in de samenvatting of de intro ligt.
    static func skip(at t: Double, _ s: Segments?, userIntroStart: Double?, userIntroEnd: Double?) -> (end: Double, recap: Bool)? {
        if let s, let e = s.recapEnd, t >= max(0, s.recapStart ?? 0), t < e - 1 { return (e, true) }
        let start = s?.introEnd != nil ? s?.introStart : userIntroStart
        if let e = s?.introEnd ?? userIntroEnd, e > 0, t >= max(0, start ?? 0), t < e - 1 { return (e, false) }
        return nil
    }

    // MARK: 11. Duimen (`profile.<id>.ratings`)

    struct Thumb: Codable, Equatable {
        var key: String
        /// 1 = duim omhoog, −1 = omlaag, 0 = weggehaald (tombstone)
        var value: Int
        /// seconden sinds 1970
        var at: Double
    }

    static let thumbTombstoneLifetime: Double = 90 * 86400
    static let maxThumbs = 2000

    /// Sleutel: `tmdb:movie:<id>` / `tmdb:tv:<id>`; zonder TMDB-id `"<server-id kleine letters>|movie:<id>"` / `"…|series:<id>"`.
    static func thumbKey(tmdb: Int?, isShow: Bool, server: String, id: String) -> String {
        if let t = tmdb, t > 0 { return "tmdb:\(isShow ? "tv" : "movie"):\(t)" }
        return server.lowercased() + "|" + (isShow ? "series:" : "movie:") + id
    }

    /// Per sleutel de nieuwste `at` (gelijk: `a` blijft); tombstones ouder dan 90 dagen weg; max. 2000 (oudste
    /// tombstones eerst weg, dan de oudste). Gesorteerd op sleutel.
    static func mergeThumbs(_ a: [Thumb], _ b: [Thumb], now: Double) -> [Thumb] {
        var by: [String: Thumb] = [:]
        for t in a where (-1...1).contains(t.value) { if let x = by[t.key] { if t.at > x.at { by[t.key] = t } } else { by[t.key] = t } }
        for t in b where (-1...1).contains(t.value) { if let x = by[t.key] { if t.at > x.at { by[t.key] = t } } else { by[t.key] = t } }
        var list = by.values.filter { $0.value != 0 || now - $0.at < thumbTombstoneLifetime }
        if list.count > maxThumbs {
            list.sort { a, b in
                if (a.value == 0) != (b.value == 0) { return a.value == 0 }
                return a.at < b.at
            }
            list.removeFirst(list.count - maxThumbs)
        }
        return list.sorted { $0.key < $1.key }
    }

    static func thumbsJSON(_ list: [Thumb]) -> [[String: Any]] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return list.map { ["key": $0.key, "value": $0.value, "at": f.string(from: Date(timeIntervalSince1970: $0.at))] }
    }

    static func thumbs(fromJSON v: Any?) -> [Thumb] {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        return ((v as? [[String: Any]]) ?? []).compactMap { d in
            guard let k = d["key"] as? String, !k.isEmpty, let val = (d["value"] as? NSNumber)?.intValue, (-1...1).contains(val),
                  let s = d["at"] as? String, let at = f1.date(from: s) ?? f2.date(from: s) else { return nil }
            return Thumb(key: k, value: val, at: at.timeIntervalSince1970)
        }
    }

    // MARK: 11. "Voor jou" (forYou)

    struct Candidate: Equatable {
        var key: String
        var title: String
        var genres: [String]
        var cast: [String]
        var rating: Double
    }

    /// Score per titel: genregewicht (+2 per duim omhoog, +1 per bekeken titel zonder duim, −2 per duim omlaag),
    /// castgewicht (+1 per persoon uit de top 5 van een titel met duim omhoog), +3 × aanbevolen bij titels met duim
    /// omhoog, +1 × aanbevolen bij bekeken titels. Alleen niet bekeken, zonder duim, niet geblokkeerd; score > 0;
    /// volgorde score ↓, beoordeling ↓, genormaliseerde titel ↑; max. 30.
    static func forYou(_ titles: [Candidate], liked: Set<String>, disliked: Set<String>, watched: Set<String>,
                       blocked: Set<String>, recLiked: [String: Int], recWatched: [String: Int], limit: Int = 30) -> [String] {
        var genre: [String: Int] = [:]
        var cast: [String: Int] = [:]
        for t in titles {
            if liked.contains(t.key) {
                for g in Set(t.genres) { genre[g, default: 0] += 2 }
                for p in Set(t.cast.prefix(5)) { cast[p, default: 0] += 1 }
            } else if disliked.contains(t.key) {
                for g in Set(t.genres) { genre[g, default: 0] -= 2 }
            } else if watched.contains(t.key) {
                for g in Set(t.genres) { genre[g, default: 0] += 1 }
            }
        }
        var scored: [(Candidate, Int)] = []
        for t in titles {
            if liked.contains(t.key) || disliked.contains(t.key) || watched.contains(t.key) || blocked.contains(t.key) { continue }
            var s = Set(t.genres).reduce(0) { $0 + (genre[$1] ?? 0) }
            s += Set(t.cast.prefix(5)).reduce(0) { $0 + (cast[$1] ?? 0) }
            s += 3 * (recLiked[t.key] ?? 0) + (recWatched[t.key] ?? 0)
            if s > 0 { scored.append((t, s)) }
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.rating != b.0.rating { return a.0.rating > b.0.rating }
            return Sport173.jsLess(norm(a.0.title), norm(b.0.title))
        }
        return scored.prefix(limit).map { $0.0.key }
    }

    /// Genormaliseerd zoals build 176 (`epgSearch`), spaties samengevoegd.
    static func norm(_ s: String) -> String {
        Build176.foldString(s).split(separator: " ").joined(separator: " ")
    }

    // MARK: 16. WebDAV (webdavParse)

    struct WebDAVItem: Equatable {
        /// "movie", "episode" of "other"
        var kind: String
        var title: String = ""
        var year: Int? = nil
        var season: Int? = nil
        var episode: Int? = nil
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "wmv", "ts", "m2ts", "webm", "mpg", "mpeg", "flv"]
    private static let quality: Set<String> = ["2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "hdr", "hdr10",
                                               "dv", "x264", "x265", "h264", "h265", "hevc", "avc", "web-dl", "webdl", "webrip",
                                               "web", "bluray", "blu-ray", "brrip", "bdrip", "dvdrip", "hdrip", "hdtv", "remux",
                                               "proper", "repack", "10bit", "aac", "ac3", "dts", "xvid", "divx", "atmos", "ddp5",
                                               "dd5", "nf", "amzn"]
    private static let generic: Set<String> = ["movie", "film", "video"]

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let bracketRE = re("\\[[^\\]]*\\]")
    private static let sxeRE = re("(?:^|[^a-z0-9])s(\\d{1,2})[ ._-]*e(\\d{1,3})(?![0-9])")
    private static let xRE = re("(?:^|[^a-z0-9])(\\d{1,2})x(\\d{1,3})(?![0-9])")
    private static let seasonDirRE = re("^(?:season|seizoen|staffel|saison|serie|s)[ ._-]*(\\d{1,3})$")
    private static let epRE = re("(?:^|[^a-z0-9])(?:e|ep|episode|aflevering|afl)[ ._-]*(\\d{1,3})(?![0-9])")
    private static let leadRE = re("^(\\d{1,3})(?![0-9])")
    private static let yearRE = re("^(19|20)\\d{2}$")

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func matchRange(_ r: NSRegularExpression, _ s: String) -> Int? {
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return m.range.location
    }

    /// Opschonen: `.`/`_` → spatie, `[...]` weg, haakjes weg, afkappen bij het eerste kwaliteitswoord; dan het jaartal
    /// (het laatste 1900–2099 dat niet vooraan staat) eruit, de titel is wat ervoor staat.
    static func cleanName(_ raw: String) -> (title: String, year: Int?) {
        var s = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        s = bracketRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        s = s.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        var words = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let q = words.firstIndex(where: { quality.contains($0.lowercased()) }) { words = Array(words[..<q]) }
        var year: Int?
        if let i = words.indices.last(where: { $0 > 0 && matchRange(yearRE, words[$0]) != nil }) {
            year = Int(words[i])
            words = Array(words[..<i])
        }
        let trim = CharacterSet(charactersIn: " -–—:,")
        let title = words.joined(separator: " ").trimmingCharacters(in: trim)
        return (title, year)
    }

    /// Bestand in een WebDAV-map → film, aflevering of iets anders.
    static func webdavParse(_ path: String) -> WebDAVItem {
        let decoded = path.removingPercentEncoding ?? path
        let parts = decoded.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let file = parts.last, let dot = file.lastIndex(of: "."), dot > file.startIndex else { return WebDAVItem(kind: "other") }
        let ext = file[file.index(after: dot)...].lowercased()
        guard videoExtensions.contains(ext) else { return WebDAVItem(kind: "other") }
        let base = String(file[..<dot])
        let dirs = Array(parts.dropLast())
        let parent = dirs.last
        let parentSeason = parent.flatMap { groups(seasonDirRE, $0.trimmingCharacters(in: .whitespaces)) }.flatMap { Int($0[0]) }

        func seriesTitle() -> String {
            // de map boven de seizoensmap, of de map zelf
            let dir = parentSeason != nil ? (dirs.count >= 2 ? dirs[dirs.count - 2] : "") : (parent ?? "")
            return cleanName(dir).title
        }

        // aflevering: SxxEyy of 1x02 in de bestandsnaam
        if let g = groups(sxeRE, base) ?? groups(xRE, base), let s = Int(g[0]), let e = Int(g[1]) {
            var title: String
            if parentSeason != nil {
                title = seriesTitle()
            } else {
                let cut = matchRange(sxeRE, base) ?? matchRange(xRE, base) ?? 0
                let prefix = String(base.prefix(cut))
                title = cleanName(prefix).title
                if title.isEmpty { title = seriesTitle() }
            }
            return WebDAVItem(kind: "episode", title: title, year: nil, season: s, episode: e)
        }
        // aflevering in een seizoensmap: E04, Episode 4, Aflevering 4 of een nummer vooraan
        if let season = parentSeason {
            let trimmed = base.trimmingCharacters(in: .whitespaces)
            if let g = groups(epRE, trimmed) ?? groups(leadRE, trimmed), let e = Int(g[0]) {
                return WebDAVItem(kind: "episode", title: seriesTitle(), year: nil, season: season, episode: e)
            }
        }
        // film
        var m = cleanName(base)
        if generic.contains(m.title.lowercased()) || m.year == nil, let p = parent {
            let pm = cleanName(p)
            if pm.year != nil, !pm.title.isEmpty { m = pm }
        }
        if m.title.isEmpty { return WebDAVItem(kind: "other") }
        return WebDAVItem(kind: "movie", title: m.title, year: m.year)
    }
}
