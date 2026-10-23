import Foundation

// Build 140 (versie 1.0.1): pure logica, zonder app-afhankelijkheden, zodat de zelftest (tools/selftest) hem los kan
// bouwen. Zie docs/ACCOUNT.md → "Build 140: categorieën per account, kinderprofielen en de ouderpoort".

// MARK: - Kindercategorieën

/// Is een categorie (zoals de server hem levert, vóór hernoemen/samenvoegen) voor kinderen?
enum KidsCategory {
    /// Woordbegin: het woord mag doorlopen ("kinderfilms", "cartoons", "disney+")
    static let prefixWords = ["kinder", "kids", "children", "familie", "family", "jeugd", "cartoon", "animatie", "animation",
                              "disney", "pixar", "nickelodeon", "peuter", "kleuter", "ketnet", "zappelin", "jetix", "boomerang"]
    /// Heel woord: geen letter of cijfer erachter ("kidnap" telt dus niet)
    static let wholeWords = ["kid", "child", "baby", "junior", "nick jr", "z@pp"]
    /// Nooit voor kinderen, ook niet met een kinderwoord erin
    static let adultWords = ["adult", "xxx", "18+", "+18", "porn", "erotic", "erotiek"]

    private static let prefixRE = try! NSRegularExpression(
        pattern: #"^\s*(?:\|([a-z]{2,3})\||\[([a-z]{2,3})\]|\(([a-z]{2,3})\)|([a-z]{2,3})\s*[|:\-–])\s*"#)

    /// Kleine letters, zonder accenten.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Kleine letters, zonder accenten en zonder landprefix vooraan ("NL | ", "|EN| ", "[NL] ", "NL - "), ook herhaald.
    static func normalize(_ name: String) -> String {
        var s = fold(name)
        for _ in 0..<4 {
            let ns = s as NSString
            guard let m = prefixRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range.length > 0 else { break }
            // "Kid - …": "kid" is zelf een kinderwoord, geen landcode
            var code = ""
            for i in 1...4 where m.range(at: i).location != NSNotFound { code = ns.substring(with: m.range(at: i)) }
            if wholeWords.contains(code) { break }
            s = ns.substring(from: m.range.location + m.range.length)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isAdult(_ name: String) -> Bool {
        let s = fold(name)
        return adultWords.contains { s.contains($0) }
    }

    static func isKids(_ name: String) -> Bool {
        if isAdult(name) { return false }
        let s = normalize(name)
        guard !s.isEmpty else { return false }
        for w in prefixWords where occurs(w, in: s, whole: false) { return true }
        for w in wholeWords where occurs(w, in: s, whole: true) { return true }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// `w` staat in `s` aan het begin van een woord (en bij `whole` ook aan het eind van een woord).
    private static func occurs(_ w: String, in s: String, whole: Bool) -> Bool {
        var from = s.startIndex
        while let r = s.range(of: w, range: from..<s.endIndex) {
            let okStart = r.lowerBound == s.startIndex || !isWordChar(s[s.index(before: r.lowerBound)])
            let okEnd = !whole || r.upperBound == s.endIndex || !isWordChar(s[r.upperBound])
            if okStart && okEnd { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }
}

// MARK: - Categorieën per account

/// Sleutels van `account.hiddenCategories`: server-id in kleine letters + `|` + categorienaam exact.
enum AccountCategories {
    static func key(sid: String, group: String) -> String { sid.lowercased() + "|" + group }

    /// Een opgeslagen sleutel (ook met een server-id in hoofdletters, build 128) in de vorm van build 140.
    static func normalize(_ k: String) -> String {
        guard let bar = k.firstIndex(of: "|") else { return k }
        return k[..<bar].lowercased() + String(k[bar...])
    }

    /// Server-id en categorie uit een sleutel.
    static func split(_ k: String) -> (sid: String, group: String)? {
        guard let bar = k.firstIndex(of: "|") else { return nil }
        return (String(k[..<bar]).lowercased(), String(k[k.index(after: bar)...]))
    }

    /// Migratie: de unie van de per-profiel-sets van alle niet-kinderprofielen (genormaliseerd).
    static func migrate(_ profileSets: [Set<String>]) -> Set<String> {
        var out = Set<String>()
        for s in profileSets { for k in s { out.insert(normalize(k)) } }
        return out
    }

    /// Verborgen categorieën van één server uit de account-set.
    static func groups(_ set: Set<String>, sid: String) -> Set<String> {
        let p = sid.lowercased()
        var out = Set<String>()
        for k in set { if let (s, g) = split(k), s == p { out.insert(g) } }
        return out
    }
}

// MARK: - Lijsten: tijd van een eigen toevoeging

enum ListStamp {
    /// Tijd voor een item dat hier (opnieuw) is toegevoegd. Is er een verwijdering bekend met een tijd die even laat of
    /// later is (bijv. van een apparaat waarvan de klok voorloopt), dan net daarna: anders "wint" die verwijdering en
    /// verdwijnt het zojuist toegevoegde item bij de volgende sync weer uit Mijn lijst.
    static func addedAt(now: Double, knownRemoval: Double?) -> Double {
        guard now > 0, let r = knownRemoval, r >= now else { return now }
        return r + 0.001
    }
}

// MARK: - Ouderpoort (rekensom)

struct ParentGateSum: Equatable {
    let a: Int
    let b: Int
    let multiply: Bool

    var answer: Int { multiply ? a * b : a + b }
    var text: String { "\(a) \(multiply ? "×" : "+") \(b) = ?" }
    var answerDigits: Int { String(answer).count }

    /// Helft vermenigvuldigen (6…12 × 3…9), helft optellen (11…49 + 11…49).
    static func random<G: RandomNumberGenerator>(using g: inout G) -> ParentGateSum {
        if Bool.random(using: &g) {
            return ParentGateSum(a: Int.random(in: 6...12, using: &g), b: Int.random(in: 3...9, using: &g), multiply: true)
        }
        return ParentGateSum(a: Int.random(in: 11...49, using: &g), b: Int.random(in: 11...49, using: &g), multiply: false)
    }

    static func random() -> ParentGateSum {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }
}

/// Stand van de ouderpoort: maximaal 3 pogingen per som, daarna een nieuwe som.
struct ParentGateState {
    static let maxAttempts = 3
    static let maxDigits = 3
    enum Outcome: Equatable { case correct, wrong, newSum }

    private(set) var sum: ParentGateSum
    private(set) var attempts = 0

    init(sum: ParentGateSum = .random()) { self.sum = sum }

    /// Alleen cijfers, maximaal 3.
    static func sanitize(_ input: String) -> String { String(input.filter(\.isNumber).prefix(maxDigits)) }

    /// Vanzelf controleren zodra er evenveel cijfers staan als het antwoord heeft.
    func readyToCheck(_ input: String) -> Bool { Self.sanitize(input).count >= sum.answerDigits }

    mutating func submit(_ input: String, next: () -> ParentGateSum = { .random() }) -> Outcome {
        let v = Int(Self.sanitize(input))
        if v == sum.answer { attempts = 0; return .correct }
        attempts += 1
        if attempts >= Self.maxAttempts {
            var s = next()
            var guardCount = 0
            while s == sum && guardCount < 5 { s = next(); guardCount += 1 }
            sum = s
            attempts = 0
            return .newSum
        }
        return .wrong
    }
}

// MARK: - Uitgelicht (hero): vaste, roulerende selectie

enum HeroRotation {
    static let limit = 8
    static let interval: TimeInterval = 8

    /// Om en om uit Voor jou en Nieuw op Bingr, dubbele weg, maximaal `limit`.
    static func pick(forYou: [String], new: [String], limit: Int = HeroRotation.limit) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var i = 0
        while out.count < limit && (i < forYou.count || i < new.count) {
            for list in [forYou, new] where i < list.count && out.count < limit {
                if seen.insert(list[i]).inserted { out.append(list[i]) }
            }
            i += 1
        }
        return out
    }

    /// Dagnummer (lokale kalender) sinds 1970.
    static func day(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    /// Startplek van vandaag: schuift elke dag één plek op.
    static func start(day: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((day % count) + count) % count
    }

    static func rotated<T>(_ xs: [T], day: Int) -> [T] {
        guard !xs.isEmpty else { return xs }
        let s = start(day: day, count: xs.count)
        return Array(xs[s...] + xs[..<s])
    }
}

// MARK: - Nieuw op Bingr: toevoegdatum of eerste keer gezien

enum FirstSeen {
    /// Werk de "eerste keer gezien" bij. Een server die voor het eerst gezien wordt (`seeded == false`) krijgt voor
    /// alles tijd 0 (niet nieuw); daarna krijgt een nieuw id de tijd `now`. Geeft true als er iets veranderd is.
    @discardableResult
    static func update(_ known: inout [String: Double], ids: [String], now: Double, seeded: Bool) -> Bool {
        var changed = false
        for id in ids where known[id] == nil {
            known[id] = seeded ? now : 0
            changed = true
        }
        return changed
    }

    /// Volgorde voor Nieuw op Bingr: de toevoegdatum van de provider, anders de eerste keer gezien; nieuwste eerst.
    /// Items zonder bekende tijd (0) tellen niet als nieuw. Bij gelijke tijd op id (vaste volgorde).
    static func newest(_ items: [(id: String, provider: Double?)], firstSeen: [String: Double], limit: Int) -> [String] {
        var scored: [(String, Double)] = []
        for i in items {
            let t = i.provider ?? firstSeen[i.id] ?? 0
            if t > 0 { scored.append((i.id, t)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var out: [String] = []
        var seen = Set<String>()
        for (id, _) in scored where seen.insert(id).inserted {
            out.append(id)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Server automatisch vernieuwen

enum AutoRefresh {
    /// Na een mislukte poging niet vaker dan eens per 15 minuten opnieuw
    static let retryAfter: TimeInterval = 15 * 60

    /// Wanneer een cache van deze leeftijd ververst moet worden. `policy` = de raw value van `RefreshPolicy`
    /// (manual, launch, sixHours, daily, weekly). `periodic`: de controle terwijl de app openstaat; "bij elke start"
    /// telt dan niet (anders elke minuut).
    static func isDue(policy: String, age: TimeInterval?, periodic: Bool = false) -> Bool {
        switch policy {
        case "manual": return false
        case "launch": return !periodic && (age ?? .infinity) > 60
        case "sixHours": return (age ?? .infinity) > 6 * 3600
        case "weekly": return (age ?? .infinity) > 7 * 24 * 3600
        default: return (age ?? .infinity) > 24 * 3600   // daily (standaard)
        }
    }

    /// Welke servers nu ververst moeten worden: alle servers van het account waarvan de cache te oud is (of ontbreekt),
    /// behalve die net (binnen `retryAfter`) geprobeerd zijn. De volgorde blijft die van `servers`.
    static func due(policy: String, servers: [(id: String, age: TimeInterval?)], lastAttempt: [String: Date],
                    now: Date, periodic: Bool) -> [String] {
        servers.filter { s in
            guard isDue(policy: policy, age: s.age, periodic: periodic) else { return false }
            if let t = lastAttempt[s.id], now.timeIntervalSince(t) < retryAfter { return false }
            return true
        }.map(\.id)
    }
}

// MARK: - Voor jou: welke titels het actieve profiel keek

enum ForYouSeeds {
    struct Watch { var key: String; var at: Double }

    /// Titels om aanbevelingen op te baseren: het meest bekeken eerst (aantal keer in de geschiedenis/voortgang), bij
    /// gelijk aantal het laatst bekeken. `key` is de titel (film-id of serie-id).
    static func rank(_ watches: [Watch], limit: Int) -> [String] {
        var count: [String: Int] = [:]
        var last: [String: Double] = [:]
        for w in watches {
            count[w.key, default: 0] += 1
            last[w.key] = max(last[w.key] ?? 0, w.at)
        }
        let ordered = count.keys.sorted { a, b in
            let ca = count[a] ?? 0, cb = count[b] ?? 0
            if ca != cb { return ca > cb }
            let la = last[a] ?? 0, lb = last[b] ?? 0
            return la != lb ? la > lb : a < b
        }
        return Array(ordered.prefix(limit))
    }

    /// Score van een kandidaat: overlap van genres met de bekeken titels (gewogen) plus dezelfde categorie.
    static func score(genres: Set<Int>, group: String, seedGenres: [Int: Int], seedGroups: [String: Int]) -> Int {
        var s = 0
        for g in genres { s += seedGenres[g] ?? 0 }
        s += 2 * (seedGroups[group] ?? 0)
        return s
    }
}
