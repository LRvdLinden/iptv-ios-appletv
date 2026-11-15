import Foundation

/// Build 176 (versie 1.0.8): pure logica, gelijk op alle platforms (Android `Build176Logic.kt`, web `web/js/build176.js`).
/// Regels: docs/ACCOUNT.md → "Build 176"; gedeelde testgevallen: docs/build176_cases.json (tools/selftest).
/// Alleen Foundation: de zelftest compileert dit bestand los van de app.
enum Build176 {

    // MARK: 1. Automatisch volgende aflevering

    /// Start de volgende aflevering vanzelf? Niet ingesteld = aan, behalve in een kinderprofiel; "Kijk je nog?" gaat voor.
    static func autoplay(value: Bool?, kids: Bool, stillWatchingDue: Bool) -> Bool {
        (value ?? !kids) && !stillWatchingDue
    }

    // MARK: 2. Vergrendelen met pincode

    /// Zo lang blijft een item open na de juiste pincode (op dit apparaat)
    static let unlockSeconds: Double = 4 * 3600

    /// Moet het openen van dit item eerst de pincode van het hoofdprofiel vragen?
    static func lockAsks(locked: Bool, hasMainPin: Bool, unlockedAt: Double?, now: Double) -> Bool {
        guard locked, hasMainPin else { return false }
        if let u = unlockedAt, now - u < unlockSeconds { return false }
        return true
    }

    // MARK: 6. Data besparen

    enum DataMode: String, CaseIterable { case auto, saver, max }
    enum Net: String { case wifi, cellular, unknown }

    /// Data besparen actief? Alleen op mobiel netwerk; `auto` volgt de databesparing van het systeem.
    static func saver(mode: String, net: Net, constrained: Bool) -> Bool {
        let m = DataMode(rawValue: mode) ?? .auto
        guard net == .cellular else { return false }
        switch m {
        case .saver: return true
        case .auto: return constrained
        case .max: return false
        }
    }

    static let saverMaxBitrate = 1_500_000
    static let saverMaxHeight = 576

    struct Variant: Equatable { var bandwidth: Int; var height: Int? }

    /// Variant uit een HLS-master bij Data besparen (index), nil = de speler kiest zelf.
    static func variant(saver: Bool, _ variants: [Variant]) -> Int? {
        guard saver, !variants.isEmpty else { return nil }
        var best: Int?
        for (i, v) in variants.enumerated() where v.bandwidth <= saverMaxBitrate && (v.height ?? 0) <= saverMaxHeight {
            if best == nil || v.bandwidth > variants[best!].bandwidth { best = i }
        }
        if let best { return best }
        var low = 0
        for (i, v) in variants.enumerated() where v.bandwidth < variants[low].bandwidth { low = i }
        return low
    }

    /// Varianten uit de tekst van een HLS-master (`#EXT-X-STREAM-INF`), met de URI-regel erna.
    static func parseMaster(_ text: String) -> [(variant: Variant, uri: String)] {
        var out: [(Variant, String)] = []
        var pending: Variant?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                var bw = 0, h: Int?
                if let r = attrs.range(of: #"(?<![A-Z-])BANDWIDTH=(\d+)"#, options: .regularExpression) {
                    bw = Int(attrs[r].split(separator: "=").last ?? "") ?? 0
                }
                if let r = attrs.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                    h = Int(attrs[r].split(separator: "x").last ?? "")
                }
                pending = Variant(bandwidth: bw, height: h)
            } else if let v = pending, !line.isEmpty, !line.hasPrefix("#") {
                out.append((v, line))
                pending = nil
            }
        }
        return out
    }

    // MARK: 5. Zoeken in programmabeschrijvingen

    /// Eén teken normaliseren: kleine letters zonder accenten, geen letter/cijfer = spatie (altijd één teken terug,
    /// zodat een plek in de genormaliseerde tekst ook de plek in de originele tekst is).
    static func foldChar(_ c: Character) -> Character {
        let s = String(c).decomposedStringWithCanonicalMapping.unicodeScalars
        guard let base = s.first else { return " " }
        guard CharacterSet.alphanumerics.contains(base) else { return " " }
        let lower = String(Character(base)).lowercased()
        return lower.count == 1 ? lower.first! : Character(String(base))
    }

    static func fold(_ s: String) -> [Character] { s.map(foldChar) }

    /// Woorden van de zoekterm (≥ 2 tekens); leeg = niet zoeken (ook als de hele term korter is dan 3 tekens).
    static func queryWords(_ q: String) -> [String] {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return [] }
        return String(fold(t)).split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    enum Field: String { case title, description }

    struct EPGMatch: Equatable {
        var field: Field
        /// Het gevonden stuk in de originele tekst (titel bij `title`, anders beschrijving)
        var highlight: String?
        /// Plek van `highlight` in de originele tekst (tekens)
        var range: Range<Int>?
    }

    /// Voorbewerkte tekst van een programma (de index): genormaliseerde titel en beschrijving
    struct Folded {
        let title: [Character]; let desc: [Character]
        let titleText: String; let descText: String
        init(title: String, desc: String?) {
            titleText = title; descText = desc ?? ""
            self.title = Build176.fold(title); self.desc = Build176.fold(desc ?? "")
        }
    }

    static func find(_ word: [Character], in hay: [Character]) -> Int? {
        guard !word.isEmpty, word.count <= hay.count else { return nil }
        let first = word[0]
        var i = 0
        let last = hay.count - word.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < word.count && hay[i + j] == word[j] { j += 1 }
                if j == word.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Genormaliseerde tekst als String (voor de index; zelfde lengte in tekens als het origineel)
    static func foldString(_ s: String) -> String { String(fold(s)) }

    /// Snel filter voor de index: past het programma, en waar (zonder markering)?
    static func epgField(words: [String], title: String, desc: String) -> Field? {
        guard !words.isEmpty else { return nil }
        var inTitle = true
        for w in words {
            if title.contains(w) { continue }
            inTitle = false
            if !desc.contains(w) { return nil }
        }
        return inTitle ? .title : .description
    }

    static func epgMatch(_ q: String, title: String, desc: String?) -> EPGMatch? {
        epgMatch(words: queryWords(q).map(Array.init), Folded(title: title, desc: desc))
    }

    static func epgMatch(words: [[Character]], _ f: Folded) -> EPGMatch? {
        guard !words.isEmpty else { return nil }
        var inTitle = true
        for w in words {
            if find(w, in: f.title) != nil { continue }
            inTitle = false
            if find(w, in: f.desc) == nil { return nil }
        }
        func piece(_ text: String, _ at: Int, _ len: Int) -> String {
            let chars = Array(text)
            return String(chars[at..<min(chars.count, at + len)])
        }
        if inTitle {
            let w = words[0]
            guard let at = find(w, in: f.title) else { return EPGMatch(field: .title, highlight: nil, range: nil) }
            return EPGMatch(field: .title, highlight: piece(f.titleText, at, w.count), range: at..<(at + w.count))
        }
        for w in words {
            if let at = find(w, in: f.desc) {
                return EPGMatch(field: .description, highlight: piece(f.descText, at, w.count), range: at..<(at + w.count))
            }
        }
        return EPGMatch(field: .description, highlight: nil, range: nil)
    }

    /// Een stukje beschrijving rond de treffer (voor de resultatenlijst), met "…" waar ingekort.
    static func snippet(_ text: String, around r: Range<Int>?, width: Int = 90) -> String {
        let chars = Array(text)
        guard chars.count > width else { return text }
        let center = r?.lowerBound ?? 0
        let start = max(0, min(center - width / 3, chars.count - width))
        let end = min(chars.count, start + width)
        return (start > 0 ? "…" : "") + String(chars[start..<end]) + (end < chars.count ? "…" : "")
    }

    // MARK: 4. Herinnering op de releasedatum

    static func releaseKey(mediaType: String, tmdb: Int, season: Int?) -> String {
        "release:\(mediaType == "tv" ? "tv" : "movie"):\(tmdb)" + (season.map { ":s\($0)" } ?? "")
    }

    static func releaseID(mediaType: String, tmdb: Int, season: Int?, profile: String?) -> String {
        let k = releaseKey(mediaType: mediaType, tmdb: tmdb, season: season)
        guard let profile, !profile.isEmpty else { return k }
        return "p:\(profile.lowercased()):\(k)"
    }

    /// Releasedatum ("yyyy-MM-dd") om 09:00 in deze tijdzone
    static func releaseStart(day: String, timeZone: TimeZone) -> Date? {
        let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9))
    }

    // MARK: 14. Lichtere afbeeldingen

    /// Kleinere postermaten die TMDB levert (de app vraagt posters op als w780)
    static let tmdbPosterWidths = [342, 500]

    /// TMDB-poster (w780) in de kleinste passende maat voor `maxPixel` (grootste zijde in pixels, zoals `RemoteImage`;
    /// posters zijn 2:3, dus de breedte is 2/3 van `maxPixel`). Alleen kleiner, nooit groter. Andere maten
    /// (achtergronden w1280, stills en logo's w500, w342, `original`) en andere URL's blijven zoals ze zijn.
    static func tmdbSized(_ url: URL, maxPixel: Int) -> URL {
        guard url.host == "image.tmdb.org" else { return url }
        let parts = url.path.split(separator: "/")
        // /t/p/w780/<bestand>
        guard parts.count == 4, parts[0] == "t", parts[1] == "p", parts[2] == "w780" else { return url }
        let need = (maxPixel * 2 + 2) / 3
        guard let pick = tmdbPosterWidths.first(where: { $0 >= need }) else { return url }
        return URL(string: "https://image.tmdb.org/t/p/w\(pick)/\(parts[3])") ?? url
    }

    // MARK: 8. Helpcentrum

    static let helpURL = URL(string: "https://support.bingr.online/hulp/")!
}
