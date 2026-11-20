import Foundation

// Build 179 (versie 1.0.8): live scores, standen en teamkleuren in Sport. Pure logica (alleen Foundation), ook los gebouwd
// in de zelftest van CI (tools/selftest/main.swift), gelijk aan Build179Logic.kt (bingr-android) en web/js/build179.js
// (bingr-website). Gedeelde testgevallen: docs/build179_cases.json (secties teamEq, espnLink, scoreText, teamColor, contrast).
// - wedstrijden en scores van ESPN (`site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard`, geen sleutel),
//   standen van `site.api.espn.com/apis/v2/sports/<sport>/<league>/standings` (de site/v2-variant geeft geen tabel);
// - koppelen aan de gids: zelfde teams (in elke volgorde) en aftrap ±15 min (zoals het ontdubbelen van build 172);
// - cache: scores 60 s, standen 1 uur; Data besparen (176) op mobiel: alleen wat er al is;
// - teamkleur: ESPN color → alternateColor → gemiddelde kleur van het logo → vaste kleur van build 172, met genoeg
//   contrast voor witte tekst (WCAG ≥ 4,5); een te lichte kleur wordt donkerder gemaakt.
// Regels en sleutels: docs/ACCOUNT.md → "Build 179" (punten 7 en 8; secties teamEq, espnLink, scoreText, teamColor, contrast).

/// Eén team in een ESPN-wedstrijd.
struct EspnTeam179: Equatable, Hashable, Codable {
    var id: String
    var names: [String]
    var abbreviation: String
    var score: String?
    var color: UInt32?
    var alternateColor: UInt32?
    var logo: String?
    var displayName: String { names.first ?? abbreviation }
}

/// Eén wedstrijd uit een ESPN-scoreboard.
struct EspnEvent179: Equatable, Hashable, Codable {
    var id: String
    /// "soccer/ned.1", "basketball/nba", …
    var league: String
    var start: Date
    /// "pre", "in" of "post"
    var state: String
    /// Korte status van ESPN ("67'", "HT", "FT", "Q3 4:12")
    var detail: String
    /// `status.displayClock` ("67'")
    var clock: String
    var home: EspnTeam179
    var away: EspnTeam179

    var isLive: Bool { state == "in" }
    var isFinished: Bool { state == "post" }
    /// Stand volgens `Sport179.scoreText` (nil = geen stand tonen)
    var scoreLine: String? { Sport179.status(self) }
}

/// Eén regel van een stand.
struct EspnStanding179: Equatable, Hashable, Codable {
    var rank: Int
    var names: [String]
    var abbreviation: String
    var logo: String?
    var played: Int
    var wins: Int
    var draws: Int
    var losses: Int
    var points: Int
    var difference: Int
    var displayName: String { names.first ?? abbreviation }
}

/// Een stand (een competitie kan meer groepen hebben: conferences, poules).
struct EspnTable179: Equatable, Codable {
    var name: String
    var rows: [EspnStanding179]
}

enum Sport179 {
    static let scoresMaxAge: Double = 60
    static let standingsMaxAge: Double = 3600
    static let matchSeconds: Double = 900
    /// Data besparen (176): scores hooguit elke 5 minuten
    static let scoresMaxAgeSaver: Double = 300

    // MARK: competities

    /// ESPN-pad (sport/competitie) voor een Sport173-competitie, of nil (geen scores, bv. darts, F1, tennis).
    static func espnLeague(competitionID: String, sport: String = "") -> String? {
        switch competitionID {
        case "eredivisie": return "soccer/ned.1"
        case "kkd": return "soccer/ned.2"
        case "knvb-beker": return "soccer/ned.cup"
        case "champions-league": return "soccer/uefa.champions"
        case "europa-league": return "soccer/uefa.europa"
        case "conference-league": return "soccer/uefa.europa.conf"
        case "premier-league": return "soccer/eng.1"
        case "laliga": return "soccer/esp.1"
        case "serie-a": return "soccer/ita.1"
        case "bundesliga": return "soccer/ger.1"
        case "ligue-1": return "soccer/fra.1"
        case "jupiler-pro-league": return "soccer/bel.1"
        case "nba": return "basketball/nba"
        case "nfl": return "football/nfl"
        case "nhl": return "hockey/nhl"
        default: return nil   // andere competities: geen scores
        }
    }

    /// Heeft deze competitie een stand? (bekers niet)
    static func hasStandings(_ league: String) -> Bool { !league.hasSuffix(".cup") }

    static func scoreboardURL(_ league: String, day: String?) -> String {
        "https://site.api.espn.com/apis/site/v2/sports/\(league)/scoreboard" + (day.map { "?dates=" + $0 } ?? "")
    }

    static func standingsURL(_ league: String) -> String {
        "https://site.api.espn.com/apis/v2/sports/\(league)/standings"
    }

    /// Datum voor `dates=` (jjjjmmdd in de opgegeven tijdzone).
    static func day(_ d: Date, timeZone: TimeZone) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let x = c.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d%02d%02d", x.year ?? 0, x.month ?? 0, x.day ?? 0)
    }

    // MARK: lezen

    /// Kleur uit ESPN ("e4002b", "#E4002B"), of nil.
    static func parseColor(_ raw: String?) -> UInt32? { hex(raw) }

    /// ESPN-datum ("2026-11-15T13:30Z" of met seconden).
    static func parseDate(_ raw: String?) -> Date? {
        guard let s = raw, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        if s.hasSuffix("Z"), s.count == 17, let d = f.date(from: String(s.dropLast()) + ":00Z") { return d }
        return nil
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func team(_ c: [String: Any]) -> EspnTeam179? {
        guard let t = c["team"] as? [String: Any] else { return nil }
        var names: [String] = []
        for k in ["displayName", "shortDisplayName", "name", "location"] {
            if let s = t[k] as? String, !s.isEmpty, !names.contains(s) { names.append(s) }
        }
        guard !names.isEmpty else { return nil }
        var score = string(c["score"])
        if let d = c["score"] as? [String: Any] { score = string(d["displayValue"]) ?? string(d["value"]) }
        let logo = (t["logo"] as? String) ?? ((t["logos"] as? [[String: Any]])?.first?["href"] as? String)
        return EspnTeam179(id: string(t["id"]) ?? "", names: names, abbreviation: (t["abbreviation"] as? String) ?? "",
                           score: score, color: parseColor(t["color"] as? String),
                           alternateColor: parseColor(t["alternateColor"] as? String),
                           logo: logo.flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil })
    }

    /// Wedstrijden uit een scoreboard-antwoord.
    static func parseScoreboard(_ data: Data, league: String) -> [EspnEvent179] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = j["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { e in
            guard let comp = (e["competitions"] as? [[String: Any]])?.first,
                  let cs = comp["competitors"] as? [[String: Any]], cs.count == 2,
                  let start = parseDate((comp["date"] as? String) ?? (e["date"] as? String)) else { return nil }
            let homeC = cs.first { ($0["homeAway"] as? String) == "home" } ?? cs[0]
            let awayC = cs.first { ($0["homeAway"] as? String) == "away" } ?? cs[1]
            guard let home = team(homeC), let away = team(awayC) else { return nil }
            let status = (comp["status"] as? [String: Any]) ?? (e["status"] as? [String: Any]) ?? [:]
            let type = status["type"] as? [String: Any] ?? [:]
            let state = ((type["state"] as? String) ?? "pre").lowercased()
            let detail = (type["shortDetail"] as? String) ?? ""
            return EspnEvent179(id: string(e["id"]) ?? "", league: league, start: start,
                                state: state, detail: detail, clock: (status["displayClock"] as? String) ?? "",
                                home: home, away: away)
        }
    }

    /// Standen uit een standings-antwoord (groepen in `children`, of één tabel in `standings`).
    static func parseStandings(_ data: Data) -> [EspnTable179] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var groups: [(String, [String: Any])] = []
        func collect(_ node: [String: Any]) {
            if let s = node["standings"] as? [String: Any], s["entries"] != nil {
                groups.append(((node["name"] as? String) ?? "", s))
            }
            for c in (node["children"] as? [[String: Any]]) ?? [] { collect(c) }
        }
        collect(j)
        return groups.compactMap { name, s in
            let entries = (s["entries"] as? [[String: Any]]) ?? []
            var rows: [EspnStanding179] = entries.compactMap { e in
                guard let t = e["team"] as? [String: Any] else { return nil }
                var names: [String] = []
                for k in ["displayName", "shortDisplayName", "name", "location"] {
                    if let x = t[k] as? String, !x.isEmpty, !names.contains(x) { names.append(x) }
                }
                guard !names.isEmpty else { return nil }
                var st: [String: Double] = [:]
                for x in (e["stats"] as? [[String: Any]]) ?? [] {
                    if let n = x["name"] as? String, let v = (x["value"] as? NSNumber)?.doubleValue { st[n] = v }
                }
                func v(_ keys: String...) -> Int { for k in keys { if let x = st[k] { return Int(x.rounded()) } }; return 0 }
                let logo = (t["logos"] as? [[String: Any]])?.first?["href"] as? String
                return EspnStanding179(rank: v("rank", "playoffSeed"), names: names,
                                       abbreviation: (t["abbreviation"] as? String) ?? "",
                                       logo: logo, played: v("gamesPlayed"), wins: v("wins"), draws: v("ties"),
                                       losses: v("losses"), points: v("points"),
                                       difference: v("pointDifferential", "differential"))
            }
            if rows.contains(where: { $0.rank > 0 }) {
                rows.sort { a, b in (a.rank > 0 ? a.rank : Int.max) < (b.rank > 0 ? b.rank : Int.max) }
            } else {
                for i in rows.indices { rows[i].rank = i + 1 }
            }
            return rows.isEmpty ? nil : EspnTable179(name: name, rows: rows)
        }
    }

    // MARK: koppelen aan de gids (espnLink, teamEq)

    /// Zelfde team (`teamEq`): `teamKey` gelijk, of de kortste (≥ 3 tekens) is het begin van de langste, of de kortste
    /// (≥ 5 tekens) staat in de langste.
    static func teamEq(_ a: String, _ b: String) -> Bool {
        let x = Sport173.teamKey(a), y = Sport173.teamKey(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short.count >= 3 && long.hasPrefix(short) { return true }
        return short.count >= 5 && long.contains(short)
    }

    /// Is de naam uit de gids een van de ESPN-namen van dit team?
    static func sameTeam(_ guideName: String, _ names: [String]) -> Bool { names.contains { teamEq(guideName, $0) } }

    /// De ESPN-wedstrijd bij een duel uit de gids: beide teams (ook omgedraaid), aftrap ≤ 900 s verschil, de dichtstbijzijnde.
    static func match(home: String, away: String, start: Date, in events: [EspnEvent179]) -> EspnEvent179? {
        guard !home.isEmpty, !away.isEmpty else { return nil }
        var best: EspnEvent179?
        var bestDiff = Double.infinity
        for e in events {
            let d = abs(e.start.timeIntervalSince(start))
            guard d <= matchSeconds, d < bestDiff else { continue }
            let names = (e.home.names + [e.home.abbreviation], e.away.names + [e.away.abbreviation])
            if (sameTeam(home, names.0) && sameTeam(away, names.1)) || (sameTeam(home, names.1) && sameTeam(away, names.0)) {
                best = e
                bestDiff = d
            }
        }
        return best
    }

    /// ESPN-wedstrijden die de gids niet heeft ("Niet in je gids"): niet gekoppeld, op aftrap gesorteerd.
    static func notInGuide(_ events: [EspnEvent179], matched: Set<String>) -> [EspnEvent179] {
        var seen = Set<String>()
        return events.filter { e in
            let k = key(e)
            guard !matched.contains(k), !seen.contains(k) else { return false }
            seen.insert(k)
            return true
        }.sorted { a, b in a.start != b.start ? a.start < b.start : Sport173.jsLess(a.home.displayName, b.home.displayName) }
    }

    static func key(_ e: EspnEvent179) -> String { e.league + "|" + e.id }

    /// Plaats van een team in een stand, of nil.
    static func rank(_ name: String, in tables: [EspnTable179]) -> Int? {
        for t in tables {
            if let r = t.rows.first(where: { sameTeam(name, $0.names + [$0.abbreviation]) }), r.rank > 0 { return r.rank }
        }
        return nil
    }

    // MARK: tekst (scoreText)

    /// `in`: "2–1 · 67'" (zonder klok alleen de stand), `post`: "2–1", anders (of zonder beide scores) nil.
    static func scoreText(state: String, home: Int?, away: Int?, clock: String?) -> String? {
        guard state == "in" || state == "post", let home, let away else { return nil }
        let s = "\(home)\u{2013}\(away)"
        let c = (clock ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return state == "in" && !c.isEmpty ? s + " \u{00B7} " + c : s
    }

    /// Tekst voor op de kaart (zie `scoreText`).
    static func status(_ e: EspnEvent179) -> String? {
        func n(_ s: String?) -> Int? { s.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) ?? Double($0).map { Int($0) } } }
        return scoreText(state: e.state, home: n(e.home.score), away: n(e.away.score), clock: e.clock)
    }

    // MARK: teamkleur (teamColor, contrast)

    /// Relatieve luminantie (WCAG 2.1).
    static func luminance(_ c: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let s = Double(v & 0xFF) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(c >> 16) + 0.7152 * ch(c >> 8) + 0.0722 * ch(c)
    }

    /// Contrast met wit: 1.05 / (L + 0.05).
    static func contrastWithWhite(_ c: UInt32) -> Double { 1.05 / (luminance(c) + 0.05) }

    static let minContrast = 4.5

    /// Elk kanaal × f, afgerond.
    static func darken(_ c: UInt32, _ f: Double) -> UInt32 {
        func ch(_ v: UInt32) -> UInt32 { UInt32((Double(v & 0xFF) * f).rounded()) }
        return (ch(c >> 16) << 16) | (ch(c >> 8) << 8) | ch(c)
    }

    /// Hex van 6 tekens (met of zonder #), anders nil (ook geen korte 3-tekenvorm).
    static func hex(_ raw: String?) -> UInt32? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt32(s, radix: 16)
    }

    static func hexString(_ c: UInt32) -> String { String(format: "%06x", c & 0xFFFFFF) }

    /// Kandidaten in volgorde (ESPN color, alternateColor, logo); de eerste met contrast ≥ 4,5 met wit wint; anders de
    /// eerste kandidaat donkerder (f = 1 − 0,1·k, k = 1…9) tot ≥ 4,5, anders zwart; geen kandidaten: `fallback`.
    static func teamColor(_ candidates: [UInt32], fallback: UInt32) -> UInt32 {
        guard let first = candidates.first else { return fallback }
        if let ok = candidates.first(where: { contrastWithWhite($0) >= minContrast }) { return ok }
        for k in 1...9 {
            let d = darken(first, 1 - 0.1 * Double(k))
            if contrastWithWhite(d) >= minContrast { return d }
        }
        return 0
    }

    static func teamColor(name: String, color: UInt32?, alternate: UInt32?, logo: UInt32?) -> UInt32 {
        teamColor([color, alternate, logo].compactMap { $0 }, fallback: Sport173.color(name))
    }

    /// Gemiddelde kleur van de dekkende pixels (RGBA, 8 bit per kanaal, alfa ≥ 128).
    static func averageColor(rgba: [UInt8]) -> UInt32? {
        var r = 0, g = 0, b = 0, n = 0
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] >= 128 { r += Int(rgba[i]); g += Int(rgba[i + 1]); b += Int(rgba[i + 2]); n += 1 }
            i += 4
        }
        guard n > 0 else { return nil }
        return (UInt32(r / n) << 16) | (UInt32(g / n) << 8) | UInt32(b / n)
    }
}
