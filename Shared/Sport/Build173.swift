import Foundation

// Build 172 (Sport). Pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift),
// gelijk aan web/js/sportlogic.js (bingr-website) en Build173Logic.kt (bingr-android). Gedeelde testgevallen:
// docs/sport_cases.json.
// - sportzenders herkennen aan de categorie (en favoriete zenders die op sport lijken);
// - een programma is een wedstrijd als de titel een duel is ("A - B", "A vs B", "A v B") of een bekend evenement;
// - herhalingen, samenvattingen en studio's niet; korter dan 20 min alleen evenementen;
// - sport en competitie uit titel, beschrijving, zender en categorie (kleine tabel), anders "other";
// - teamnamen opschonen, initialen (3 tekens) en een vaste kleur;
// - ontdubbelen over zenders/servers (zelfde teams of titel, aftrap ±15 min): favoriet > kwaliteit > gids;
// - een vaste sleutel per wedstrijd (herinneringen, dempen).

/// Een herkende wedstrijd.
struct SportMatch173: Equatable, Hashable, Codable {
    /// "duel" of "event"
    var kind: String
    var title: String
    var home: String
    var away: String
    /// football, motorsport, tennis, darts, cycling, basketball, icehockey, americanfootball, combat, golf, other
    var sport: String
    var competition: String
    var competitionID: String
    var isDuel: Bool { kind == "duel" }
}

/// Eén programma op één zender dat een wedstrijd is (invoer voor ontdubbelen).
struct SportListing173: Equatable {
    var id: String
    var channel: String
    var favorite: Bool
    var start: Date
    var end: Date
    var match: SportMatch173
}

/// Eén wedstrijd, met alle zenders waarop hij te zien is (beste eerst).
struct SportGroup173: Equatable {
    var key: String
    var start: Date
    var end: Date
    var match: SportMatch173
    var listings: [SportListing173]
}

enum Sport173 {
    static let minMinutes: Double = 20
    static let mergeSeconds: Double = 15 * 60
    static let days = 7
    static let leads = [0, 5, 15]
    static let defaultLead = 5
    static let sports = ["football", "motorsport", "tennis", "darts", "cycling", "basketball", "icehockey",
                         "americanfootball", "combat", "golf", "other"]
    static let colors: [UInt32] = [0xC8102E, 0x1D4ED8, 0x15803D, 0xB45309, 0x7C3AED, 0xBE185D,
                                   0x0E7490, 0x4D7C0F, 0x9A3412, 0x1E3A8A, 0x6D28D9, 0x374151]

    // MARK: tekst

    private static let extra: [Character: String] = ["ß": "ss", "ø": "o", "æ": "ae", "œ": "oe", "ł": "l", "đ": "d",
                                                     "ı": "i", "þ": "th"]

    /// Kleine letters, zonder accenten (NFD zonder U+0300–U+036F) en een paar losse letters.
    static func fold(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.decomposedStringWithCanonicalMapping.unicodeScalars where !(0x300...0x36F).contains(u.value) {
            scalars.append(u)
        }
        let lower = String(scalars).lowercased()
        var out = ""
        out.reserveCapacity(lower.count)
        for c in lower { if let r = extra[c] { out += r } else { out.append(c) } }
        return out
    }

    private static func isAlnum(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
    }

    /// Woorden van [a-z0-9] na fold.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in fold(s).unicodeScalars {
            if isAlnum(u) { cur.append(u) } else if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    private static func padded(_ s: String) -> String { " " + tokens(s).joined(separator: " ") + " " }
    private static func hasPhrase(_ p: String, _ phrase: String) -> Bool { p.contains(" " + phrase + " ") }
    private static func anyPhrase(_ p: String, _ list: [String]) -> Bool { list.contains { hasPhrase(p, $0) } }

    private static func regex(_ pattern: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: opts)
    }
    private static func replace(_ s: String, _ re: NSRegularExpression, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }
    private static func matches(_ s: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: zenders en categorieën

    private static let catWords = ["sport", "sports", "voetbal", "football", "soccer", "f1", "motorsport", "tennis",
                                   "darts", "golf", "nba", "nfl", "nhl", "ufc", "boxing", "dazn", "espn", "eurosport",
                                   "viaplay", "bein", "supersport"]
    private static let catPhrases = ["ziggo sport", "sky sports", "tnt sports", "canal sport", "arena sport"]
    private static let eventWords = ["events", "event", "ppv"]

    /// Woord gelijk aan een sleutelwoord, of sleutelwoord + cijfers ("sport1", "espn2").
    private static func wordHit(_ tokens: [String], _ words: [String]) -> Bool {
        for t in tokens {
            for w in words {
                if t == w { return true }
                if t.count > w.count, t.hasPrefix(w), t.dropFirst(w.count).allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
            }
        }
        return false
    }

    /// Lijkt deze naam (categorie of zender) op sport?
    static func looksSport(_ name: String) -> Bool {
        let t = tokens(name)
        return wordHit(t, catWords) || anyPhrase(" " + t.joined(separator: " ") + " ", catPhrases)
    }
    static func isEventCategory(_ name: String) -> Bool { wordHit(tokens(name), eventWords) }
    /// Sportcategorie (inclusief EVENTS/PPV).
    static func isSportCategory(_ name: String) -> Bool { looksSport(name) || isEventCategory(name) }
    /// Doet deze zender mee: sportcategorie, of favoriete zender die op sport lijkt.
    static func isSportChannel(_ channelName: String, category: String, favorite: Bool) -> Bool {
        isSportCategory(category) || (favorite && looksSport(channelName))
    }

    /// Kwaliteit uit de zendernaam: 4 = 4K/UHD, 3 = FHD, 2 = HD (en onbekend), 1 = SD.
    static func quality(_ channelName: String) -> Int {
        let t = Set(tokens(channelName))
        if !t.isDisjoint(with: ["4k", "uhd", "2160p", "2160"]) { return 4 }
        if !t.isDisjoint(with: ["fhd", "1080p", "1080", "1080i"]) { return 3 }
        if !t.isDisjoint(with: ["sd", "576p", "480p", "576i"]) { return 1 }
        return 2
    }

    // MARK: titels opschonen

    private static let dropWords: Set<String> = ["live", "hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264",
                                                 "50fps", "60fps", "1080p", "720p", "2160p"]
    private static let timeRE = regex("^[0-9]{1,2}[:.h][0-9]{2}u?$", .caseInsensitive)
    private static let bracketRE = regex("\\([^()]*\\)|\\[[^\\[\\]]*\\]|\\{[^{}]*\\}")
    private static let pipeTagRE = regex("^\\s*\\|[^|]{1,12}\\|\\s*")
    private static let countryRE = regex("^\\s*[A-Z]{2,3}\\s*[:|]\\s*")
    private static let spaceRE = regex("\\s+")
    private static let trimSet: Set<Character> = [" ", "-", "|", ":", ".", ",", "·", "•", "*", "–", "—", "_", "/"]

    private static func stripBrackets(_ s: String) -> String {
        var cur = s
        while true {
            let next = replace(cur, bracketRE, " ")
            if next == cur { return cur }
            cur = next
        }
    }

    private static func stripPrefixTags(_ s: String) -> String {
        var cur = s
        while true {
            var next = replace(cur, pipeTagRE, "")
            next = replace(next, countryRE, "")
            if next == cur { return cur }
            cur = next
        }
    }

    private static func trimPunct(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, trimSet.contains(f) { chars.removeFirst() }
        while let l = chars.last, trimSet.contains(l) { chars.removeLast() }
        return String(chars)
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func dropNoise(_ s: String) -> String {
        words(s).filter { w in
            let core = trimPunct(w)
            return core.isEmpty || !(dropWords.contains(fold(core)) || matches(core, timeRE))
        }.joined(separator: " ")
    }

    private static func collapse(_ s: String) -> String {
        replace(s, spaceRE, " ").trimmingCharacters(in: .whitespaces)
    }

    /// Titel zonder haakjes, voorvoegsels, LIVE, kwaliteit en tijden.
    static func cleanTitle(_ raw: String) -> String {
        var s = stripPrefixTags(raw)
        s = stripBrackets(s)
        s = dropNoise(s)
        s = trimPunct(collapse(s))
        return collapse(s)
    }

    /// Teamnaam opgeschoond (zonder land- en kwaliteitslabels, LIVE en tijden).
    static func cleanTeam(_ raw: String) -> String { cleanTitle(raw) }

    // MARK: herhalingen

    private static let replayWords: Set<String> = ["herh", "herhaling", "replay", "samenvatting", "samenvattingen",
                                                   "highlights", "studio", "voorbeschouwing", "nabeschouwing", "magazine"]
    private static let rerunRE = regex("\\(\\s*r\\s*\\)", .caseInsensitive)

    /// Herhaling, samenvatting, studio of magazine.
    static func isExcluded(_ title: String) -> Bool {
        if matches(title, rerunRE) { return true }
        return tokens(title).contains { replayWords.contains($0) }
    }

    // MARK: competities

    struct Competition: Equatable {
        let id: String
        let name: String
        let sport: String
        let phrases: [String]
    }

    // volgorde telt: specifiek vóór algemeen (Premier League Darts vóór Premier League, MotoGP vóór Formule 1)
    static let competitions: [Competition] = [
        .init(id: "premier-league-darts", name: "Premier League Darts", sport: "darts", phrases: ["premier league darts"]),
        .init(id: "wk-darts", name: "WK Darts", sport: "darts", phrases: ["wk darts", "world darts championship", "pdc world championship"]),
        .init(id: "pdc", name: "PDC", sport: "darts", phrases: ["pdc"]),
        .init(id: "eredivisie", name: "Eredivisie", sport: "football", phrases: ["eredivisie"]),
        .init(id: "kkd", name: "Keuken Kampioen Divisie", sport: "football", phrases: ["keuken kampioen divisie", "kkd", "eerste divisie"]),
        .init(id: "knvb-beker", name: "KNVB beker", sport: "football", phrases: ["knvb beker", "knvb cup"]),
        .init(id: "champions-league", name: "Champions League", sport: "football", phrases: ["champions league", "ucl"]),
        .init(id: "europa-league", name: "Europa League", sport: "football", phrases: ["europa league", "uel"]),
        .init(id: "conference-league", name: "Conference League", sport: "football", phrases: ["conference league", "uecl"]),
        .init(id: "premier-league", name: "Premier League", sport: "football", phrases: ["premier league", "epl"]),
        .init(id: "laliga", name: "LaLiga", sport: "football", phrases: ["laliga", "la liga"]),
        .init(id: "serie-a", name: "Serie A", sport: "football", phrases: ["serie a"]),
        .init(id: "bundesliga", name: "Bundesliga", sport: "football", phrases: ["bundesliga"]),
        .init(id: "ligue-1", name: "Ligue 1", sport: "football", phrases: ["ligue 1"]),
        .init(id: "jupiler-pro-league", name: "Jupiler Pro League", sport: "football", phrases: ["jupiler pro league", "jupiler"]),
        .init(id: "wk", name: "WK", sport: "football", phrases: ["wk voetbal", "fifa world cup", "wk kwalificatie", "world cup qualifier", "world cup qualifiers"]),
        .init(id: "ek", name: "EK", sport: "football", phrases: ["ek voetbal", "uefa euro", "ek kwalificatie", "euro qualifier", "euro qualifiers"]),
        .init(id: "motogp", name: "MotoGP", sport: "motorsport", phrases: ["motogp", "moto gp"]),
        .init(id: "formula-1", name: "Formule 1", sport: "motorsport", phrases: ["formule 1", "formula 1", "f1", "grand prix", "gp"]),
        .init(id: "atp", name: "ATP", sport: "tennis", phrases: ["atp"]),
        .init(id: "wta", name: "WTA", sport: "tennis", phrases: ["wta"]),
        .init(id: "nba", name: "NBA", sport: "basketball", phrases: ["nba"]),
        .init(id: "nfl", name: "NFL", sport: "americanfootball", phrases: ["nfl"]),
        .init(id: "nhl", name: "NHL", sport: "icehockey", phrases: ["nhl"]),
        .init(id: "ufc", name: "UFC", sport: "combat", phrases: ["ufc"])
    ]

    /// Eerste bekende competitie in deze tekst, of nil.
    static func findCompetition(_ text: String) -> Competition? {
        let p = padded(text)
        guard p.count > 2 else { return nil }
        return competitions.first { anyPhrase(p, $0.phrases) }
    }
    static func competition(id: String) -> Competition? { competitions.first { $0.id == id } }

    // MARK: evenementen

    private static let evDarts = ["darts", "pdc", "premier league darts", "wk darts"]
    private static let evTennis = ["atp", "wta", "wimbledon", "roland garros", "australian open", "us open", "davis cup",
                                   "billie jean king cup", "grand slam"]
    private static let evCycling = ["tour de", "giro", "vuelta", "parijs roubaix", "paris roubaix", "ronde van vlaanderen",
                                    "tour of flanders", "milaan sanremo", "milano sanremo", "luik bastenaken luik",
                                    "liege bastogne liege", "amstel gold race", "strade bianche", "omloop het nieuwsblad",
                                    "gent wevelgem", "il lombardia", "wielrennen", "cycling"]
    private static let evCombat = ["ufc", "boksen", "boxing", "mma"]
    private static let evMotor = ["grand prix", "gp", "formule 1", "formula 1", "f1", "motogp", "moto gp", "kwalificatie",
                                  "qualifying", "indycar", "nascar"]
    private static let evMotorWeak = ["race", "sprint", "training", "vrije training", "practice", "fp1", "fp2", "fp3"]

    /// Sport van een bekend evenement in de titel (context: zender, categorie, beschrijving), of nil.
    static func eventSport(_ title: String, context: String) -> String? {
        let p = padded(title)
        if anyPhrase(p, evDarts) { return "darts" }
        if anyPhrase(p, evTennis) { return "tennis" }
        if anyPhrase(p, evCycling) { return "cycling" }
        if anyPhrase(p, evCombat) { return "combat" }
        if anyPhrase(p, evMotor) { return "motorsport" }
        if anyPhrase(p, evMotorWeak) && anyPhrase(padded(context), evMotor + ["motorsport"]) { return "motorsport" }
        return nil
    }

    // MARK: sport uit trefwoorden

    private static let keywords: [(String, [String])] = [
        ("americanfootball", ["american football", "nfl"]),
        ("icehockey", ["ijshockey", "ice hockey", "hockey", "nhl"]),
        ("basketball", ["basketbal", "basketball", "nba", "euroleague"]),
        ("motorsport", ["f1", "formule 1", "formula 1", "motorsport", "motogp", "racing"]),
        ("tennis", ["tennis"]),
        ("darts", ["darts"]),
        ("cycling", ["wielrennen", "cycling", "wielersport"]),
        ("combat", ["vechtsport", "ufc", "boxing", "boksen", "mma", "kickboxing"]),
        ("golf", ["golf", "pga"]),
        ("football", ["voetbal", "football", "soccer", "fussball", "futbol", "calcio"])
    ]
    static func keywordSport(_ text: String) -> String? {
        let p = padded(text)
        return keywords.first { anyPhrase(p, $0.1) }?.0
    }

    // MARK: duels

    private static let notTeam: Set<String> = ["journaal", "weer", "nieuws", "news", "weather", "talkshow", "show",
                                               "documentaire", "documentary", "aflevering", "episode", "seizoen", "season",
                                               "deel", "part", "film", "movie", "serie", "series", "race", "sprint",
                                               "kwalificatie", "qualifying", "training", "etappe", "stage", "gp"]
    private static let generic: Set<String> = ["sport", "sports", "voetbal", "football", "soccer", "live", "tennis",
                                               "darts", "wielrennen"]
    private static let sepRE = regex("\\s+(?:vs\\.?|v|-|–|—)\\s+", .caseInsensitive)

    private static func isLabelPart(_ part: String) -> Bool {
        let t = tokens(part)
        if t.isEmpty { return true }
        let j = t.joined(separator: " ")
        if generic.contains(j) { return true }
        return competitions.contains { $0.phrases.contains(j) || fold($0.name) == j }
    }

    private static func hasLatinLetter(_ w: String) -> Bool {
        w.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) || (0xC0...0x24F).contains($0.value) }
    }

    private static func validTeam(_ name: String) -> Bool {
        let t = tokens(name)
        let letters = fold(name).unicodeScalars.filter { (97...122).contains($0.value) }.count
        if letters < 2 { return false }
        if words(name).filter(hasLatinLetter).count > 4 { return false }
        if t.contains(where: { notTeam.contains($0) }) { return false }
        if generic.contains(t.joined(separator: " ")) { return false }
        return true
    }

    private static func split(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var last = 0
        for m in sepRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func splitDuel(_ text: String) -> (home: String, away: String)? {
        var parts = split(text)
        while parts.count > 2 && isLabelPart(parts[0]) { parts.removeFirst() }
        while parts.count > 2 && isLabelPart(parts[parts.count - 1]) { parts.removeLast() }
        guard parts.count == 2 else { return nil }
        let home = cleanTeam(parts[0]), away = cleanTeam(parts[1])
        guard validTeam(home), validTeam(away) else { return nil }
        return (home, away)
    }

    /// Duel uit de titel, of nil.
    static func parseDuel(_ title: String) -> (home: String, away: String)? {
        let s = collapse(stripBrackets(stripPrefixTags(title)))
        if let r = s.range(of: ": "), r.lowerBound > s.startIndex {
            let head = String(s[..<r.lowerBound]), tail = String(s[r.upperBound...])
            if !matches(head, sepRE), let d = splitDuel(tail) { return d }
        }
        return splitDuel(s)
    }

    // MARK: teams

    private static let affix: Set<String> = ["fc", "afc", "cf", "sc", "sv", "vv", "bv", "fk", "sk", "cd", "ud", "ac", "as",
                                             "ss", "ssc", "us", "rc", "sl"]
    private static let numericRE = regex("^[0-9.]+$")

    /// Sleutel van een team om te vergelijken: fold, alleen letters/cijfers, zonder clubaffixen.
    static func teamKey(_ name: String) -> String {
        let t = tokens(cleanTeam(name))
        let k = t.filter { !affix.contains($0) }
        return (k.isEmpty ? t : k).joined()
    }

    /// Initialen voor de cirkel (hooguit 3 tekens, hoofdletters).
    static func short(_ name: String) -> String {
        let clean = cleanTeam(name)
        let raw = clean.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init).filter { !tokens($0).isEmpty }
        var ws = raw.filter { !affix.contains(tokens($0).joined()) && !matches($0, numericRE) }
        if ws.isEmpty { ws = raw }
        guard let first = ws.first else { return "" }
        func letters(_ w: String) -> String {
            String(String.UnicodeScalarView(fold(w).unicodeScalars.filter(isAlnum))).uppercased()
        }
        func isCaps(_ w: String) -> Bool {
            let l = String(String.UnicodeScalarView(w.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }))
            return !l.isEmpty && l == l.uppercased()
        }
        if ws.count == 1 { return String(letters(first).prefix(3)) }
        if ws.count == 2 {
            if isCaps(first) && letters(first).count <= 3 { return letters(first) }
            return String(letters(first).prefix(3))
        }
        return ws.prefix(3).map { String(letters($0).prefix(1)) }.joined()
    }

    /// FNV-1a (32 bit) over de UTF-8-bytes.
    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
        return h
    }
    /// Index in `colors`, vast per team.
    static func colorIndex(_ name: String) -> Int { Int(hash(teamKey(name)) % UInt32(colors.count)) }
    static func color(_ name: String) -> UInt32 { colors[colorIndex(name)] }

    // MARK: herkennen

    /// Is dit programma een wedstrijd? Geeft de wedstrijd of nil.
    static func classify(title: String, description: String? = nil, channel: String = "", category: String = "",
                         start: Date, end: Date) -> SportMatch173? {
        guard !title.isEmpty, !isExcluded(title) else { return nil }
        let desc = description ?? ""
        let ev = eventSport(title, context: [channel, category, desc].joined(separator: " "))
        // geen duels in de motorsport en het wielrennen ("GP van Valencia - Race")
        let duel = (ev == "motorsport" || ev == "cycling") ? nil : parseDuel(title)
        if duel == nil && ev == nil { return nil }
        let minutes = end.timeIntervalSince(start) / 60
        if duel != nil && ev == nil && !(minutes >= minMinutes) { return nil }   // korte duels niet, evenementen wel
        var comp = findCompetition(title) ?? findCompetition(desc)
        let sport: String
        if let c = comp {
            sport = c.sport
        } else {
            let cc = findCompetition(channel) ?? findCompetition(category)
            if let ev {
                sport = ev
                comp = cc?.sport == ev ? cc : nil
            } else if let cc {
                sport = cc.sport
                comp = cc
            } else {
                sport = keywordSport(title) ?? keywordSport(desc) ?? keywordSport(channel) ?? keywordSport(category) ?? "other"
            }
        }
        return SportMatch173(kind: duel != nil ? "duel" : "event",
                             title: duel.map { $0.home + " - " + $0.away } ?? cleanTitle(title),
                             home: duel?.home ?? "", away: duel?.away ?? "", sport: sport,
                             competition: comp?.name ?? "", competitionID: comp?.id ?? "")
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func utcStamp(_ d: Date, withTime: Bool) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        var s = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if withTime { s += String(format: "%02d%02d", c.hour ?? 0, (c.minute ?? 0) < 30 ? 0 : 30) }
        return s
    }

    /// Vaste sleutel per wedstrijd: "sport:<a>~<b>:<jjjjmmdd>" (teams op volgorde) of "sport:<titel>:<jjjjmmdduumm>".
    static func matchKey(_ m: SportMatch173, start: Date) -> String {
        if m.isDuel {
            let a = teamKey(m.home), b = teamKey(m.away)
            return "sport:" + (a <= b ? a + "~" + b : b + "~" + a) + ":" + utcStamp(start, withTime: false)
        }
        return "sport:" + tokens(m.title).joined() + ":" + utcStamp(start, withTime: true)
    }

    private static let keyDayRE = regex(":([0-9]{8})(?:[0-9]{4})?$")

    /// Datum (jjjjmmdd) uit een sleutel, of nil.
    static func keyDay(_ key: String) -> String? {
        let ns = key as NSString
        guard let m = keyDayRE.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Wie dezelfde identiteit heeft (zelfde teams of zelfde titel) en binnen 15 min begint, is dezelfde wedstrijd.
    static func ident(_ m: SportMatch173) -> String {
        if m.isDuel { return "d:" + [teamKey(m.home), teamKey(m.away)].sorted().joined(separator: "~") }
        return "e:" + tokens(m.title).joined()
    }

    /// Ontdubbelen. `listings` in gidsvolgorde; geeft de wedstrijden op aftrap gesorteerd, per wedstrijd de zenders:
    /// favoriet, kwaliteit, gids. Een programma hoort bij de eerste wedstrijd met dezelfde identiteit waarvan het eerste
    /// programma hooguit 15 min verschilt.
    static func dedupe(_ listings: [SportListing173]) -> [SportGroup173] {
        var groups: [[(Int, SportListing173)]] = []
        var byIdent: [String: [Int]] = [:]
        for (i, l) in listings.enumerated() {
            let id = ident(l.match)
            if let g = byIdent[id]?.first(where: { abs(groups[$0][0].1.start.timeIntervalSince(l.start)) <= mergeSeconds }) {
                groups[g].append((i, l))
            } else {
                byIdent[id, default: []].append(groups.count)
                groups.append([(i, l)])
            }
        }
        var qualities: [String: Int] = [:]
        func q(_ name: String) -> Int {
            if let v = qualities[name] { return v }
            let v = quality(name); qualities[name] = v; return v
        }
        var out: [(Int, SportGroup173)] = groups.enumerated().map { gi, ls in
            let sorted = ls.sorted { a, b in
                if a.1.favorite != b.1.favorite { return a.1.favorite }
                let qa = q(a.1.channel), qb = q(b.1.channel)
                if qa != qb { return qa > qb }
                return a.0 < b.0
            }.map(\.1)
            let best = sorted[0]
            return (gi, SportGroup173(key: matchKey(best.match, start: best.start), start: best.start, end: best.end,
                                      match: best.match, listings: sorted))
        }
        out.sort { a, b in
            if a.1.start != b.1.start { return a.1.start < b.1.start }
            if a.1.match.title != b.1.match.title { return jsLess(a.1.match.title, b.1.match.title) }
            return a.0 < b.0
        }
        return out.map(\.1)
    }

    /// Vergelijken zoals JavaScript (UTF-16-code-eenheden), zodat alle platforms dezelfde volgorde hebben.
    static func jsLess(_ a: String, _ b: String) -> Bool { Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16)) }

    // MARK: herinneringen

    /// Toegestane voorlooptijd in minuten (0, 5 of 15; anders de standaard).
    static func lead(_ n: Int?) -> Int { n.map { leads.contains($0) ? $0 : defaultLead } ?? defaultLead }

    /// Hoort deze wedstrijd bij een favoriet team of een favoriete competitie?
    static func isFavorite(_ m: SportMatch173, teams: [String], competitions comps: [String]) -> Bool {
        let keys = Set(teams.map(teamKey))
        if m.isDuel && (keys.contains(teamKey(m.home)) || keys.contains(teamKey(m.away))) { return true }
        return !m.competitionID.isEmpty && comps.contains(m.competitionID)
    }

    /// Welke wedstrijden krijgen automatisch een belletje: favoriet, binnen 7 dagen, nog niet begonnen, niet gedempt en
    /// nog geen herinnering. Geeft de sleutels.
    static func autoReminders(_ groups: [SportGroup173], now: Date, teams: [String], competitions comps: [String],
                              muted: Set<String>, existing: Set<String>) -> [String] {
        let until = now.addingTimeInterval(Double(days) * 86400)
        return groups.filter { g in
            g.start > now && g.start <= until && isFavorite(g.match, teams: teams, competitions: comps)
                && !muted.contains(g.key) && !existing.contains(g.key)
        }.map(\.key)
    }

    /// Gedempte sleutels opruimen: alles van meer dan 2 dagen geleden (UTC-datum in de sleutel).
    static func pruneMuted(_ keys: [String], now: Date) -> [String] {
        let limit = utcStamp(now.addingTimeInterval(-2 * 86400), withTime: false)
        return keys.filter { k in keyDay(k).map { $0 >= limit } ?? true }
    }
}
