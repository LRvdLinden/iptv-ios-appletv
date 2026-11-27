import Foundation

// Build 171 (versie 1.0.6): ideeën uit Netflix en NLZIET. Pure logica (alleen Foundation), ook los gebouwd in de
// zelftest van CI (tools/selftest/main.swift):
// - "Kijk je nog?" (StillWatching171): wanneer vragen, en hoe lang er op een antwoord gewacht wordt;
// - zenders verbergen en titels blokkeren per profiel (ProfileHide171): sleutels en filteren;
// - overzicht van categorieën (CategoryRegion171): landen/regio's uit de voorvoegsels, vastpinnen;
// - radio (Radio171): radiozenders herkennen;
// - "Te veel apparaten" (DeviceList171): volgorde en het voorstel om af te melden;
// - crashrapporten (Crash171): URL's, IP-adressen, e-mailadressen en tokens weghalen, handtekening, wachtrij.

// MARK: - 1. "Kijk je nog?"

/// Telt automatisch gestarte afleveringen en houdt bij wanneer er voor het laatst bediend is.
/// Tijden in seconden (bijv. `Date().timeIntervalSince1970`).
struct StillWatching171: Equatable {
    /// Na zoveel afleveringen achter elkaar (automatisch of met Volgende aflevering gestart) zonder bediening
    static let askAfterEpisodes = 3
    /// Zo lang wacht de vraag op een antwoord; daarna pauzeren en de stream afmelden
    static let answerSeconds: Double = 30
    /// Keuzes voor live en films (uren zonder enige bediening)
    static let hourChoices = [2, 3, 4]
    static let defaultHours = 3
    /// Na een automatische start telt bediening die de app zelf veroorzaakt (focus, bediening tonen) even niet mee
    static let quietSeconds: Double = 3

    private(set) var autoEpisodes = 0
    private(set) var lastInteraction: Double
    private(set) var quietUntil: Double = 0

    init(now: Double) { lastInteraction = now }

    static func hours(_ h: Int) -> Int { hourChoices.contains(h) ? h : defaultHours }

    /// Bediening (toets, tik, focuswissel, volume, zenderwissel): de teller begint opnieuw.
    /// Vlak na een automatische start (stil venster) telt het niet mee.
    mutating func interaction(now: Double) {
        guard now >= quietUntil else { return }
        autoEpisodes = 0
        lastInteraction = now
    }

    /// Een aflevering startte automatisch of met de knop Volgende aflevering.
    mutating func autoEpisodeStarted(now: Double) {
        autoEpisodes += 1
        quietUntil = now + Self.quietSeconds
    }

    /// De app startte zelf iets (eerste start, overnemen uit beeld-in-beeld): geen bediening, maar ook geen aflevering.
    mutating func programmatic(now: Double) {
        quietUntil = max(quietUntil, now + Self.quietSeconds)
    }

    /// Verder kijken gekozen (of opnieuw gestart na Gepauzeerd): alles begint opnieuw.
    mutating func answered(now: Double) {
        autoEpisodes = 0
        lastInteraction = now
        quietUntil = 0
    }

    /// Nu vragen? Na 3 automatische afleveringen, of na `hours` uur zonder enige bediening.
    func shouldAsk(now: Double, hours: Int, enabled: Bool) -> Bool {
        guard enabled, now.isFinite else { return false }
        if autoEpisodes >= Self.askAfterEpisodes { return true }
        return now - lastInteraction >= Double(Self.hours(hours)) * 3600
    }

    /// Seconden die de vraag nog blijft staan (afgerond naar boven, nooit negatief).
    static func secondsLeft(askedAt: Double, now: Double) -> Int {
        guard askedAt.isFinite, now.isFinite else { return 0 }
        return max(0, Int((answerSeconds - (now - askedAt)).rounded(.up)))
    }

    /// Geen antwoord binnen 60 s: pauzeren en `stream_stop`.
    static func timedOut(askedAt: Double, now: Double) -> Bool {
        guard askedAt.isFinite, now.isFinite else { return true }
        return now - askedAt >= answerSeconds
    }
}

// MARK: - 15 en 20. Zenders verbergen en titels blokkeren, per profiel

/// Sleutels van `profile.<id>.hiddenChannels` ("<server-id kleine letters>|<stream-id>") en
/// `profile.<id>.blockedTitles` ("<server-id kleine letters>|movie:<id>" of "…|series:<id>"), zie docs/ACCOUNT.md.
/// Server-id hoofdletterongevoelig, het item-id exact.
enum ProfileHide171 {
    enum Kind: String, CaseIterable { case movie, series }

    static func channelKey(server: String, item: String) -> String { server.lowercased() + "|" + item }

    static func titleKey(server: String, kind: Kind, item: String) -> String {
        server.lowercased() + "|" + kind.rawValue + ":" + item
    }

    /// (server-id in kleine letters, soort of nil bij een zender, item-id) of nil bij een onbruikbare sleutel
    static func parse(_ key: String) -> (server: String, kind: Kind?, item: String)? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        let server = key[..<bar].lowercased()
        var rest = String(key[key.index(after: bar)...])
        guard !server.isEmpty, !rest.isEmpty else { return nil }
        var kind: Kind?
        for k in Kind.allCases where rest.hasPrefix(k.rawValue + ":") {
            kind = k
            rest = String(rest.dropFirst(k.rawValue.count + 1))
            break
        }
        guard !rest.isEmpty else { return nil }
        return (server, kind, rest)
    }

    /// Item-id's van verborgen zenders op deze server
    static func channelIDs(_ keys: Set<String>, server: String) -> Set<String> {
        ids(keys, server: server) { $0 == nil }
    }

    /// Item-id's van geblokkeerde films en series op deze server
    static func titleIDs(_ keys: Set<String>, server: String) -> Set<String> {
        ids(keys, server: server) { $0 != nil }
    }

    private static func ids(_ keys: Set<String>, server: String, _ want: (Kind?) -> Bool) -> Set<String> {
        let sid = server.lowercased()
        var out = Set<String>()
        for k in keys {
            guard let p = parse(k), p.server == sid, want(p.kind) else { continue }
            out.insert(p.item)
        }
        return out
    }

    /// Staat dit item (zender of titel) in de set? Server-id in elke schrijfwijze.
    static func contains(_ keys: Set<String>, server: String, kind: Kind?, item: String) -> Bool {
        let body = kind.map { $0.rawValue + ":" + item } ?? item
        return keys.contains(server.lowercased() + "|" + body) || keys.contains(server.uppercased() + "|" + body)
            || keys.contains(server + "|" + body)
    }

    /// Alle schrijfwijzen van een item (voor weer tonen/deblokkeren: allemaal weg)
    static func variants(_ keys: Set<String>, server: String, kind: Kind?, item: String) -> Set<String> {
        let sid = server.lowercased()
        return keys.filter { k in
            guard let p = parse(k) else { return false }
            return p.server == sid && p.kind == kind && p.item == item
        }
    }

    /// Een lijst filteren op verborgen/geblokkeerde item-id's (volgorde blijft)
    static func filter<T>(_ items: [T], hidden: Set<String>, id: (T) -> String) -> [T] {
        hidden.isEmpty ? items : items.filter { !hidden.contains(id($0)) }
    }
}

// MARK: - 17. Overzicht van categorieën: landen en regio's

enum CategoryRegion171 {
    /// Labels die geen land of regio zijn (taalvorm of ondertiteling)
    static let notRegions: Set<String> = ["MULTI", "SUB", "SUBS", "DUB", "DUBBED", "VOSTFR", "VO", "VF", "VOST", "ORIG"]

    /// Eerste label dat een land/regio is ("NL", "BE", "UK", "EXYU"), of nil
    static func region(_ labels: [String]) -> String? {
        for l in labels {
            let u = l.uppercased().trimmingCharacters(in: .whitespaces)
            guard (2...4).contains(u.count), u.allSatisfy({ $0.isLetter }), !notRegions.contains(u) else { continue }
            return u
        }
        return nil
    }

    /// Filterchips: regio's op aantal categorieën (meeste eerst, dan alfabetisch), alleen als er minstens twee zijn
    /// (één regio filtert niets). Hooguit `limit`.
    static func chips(_ regions: [String?], limit: Int = 16) -> [String] {
        var count: [String: Int] = [:]
        for r in regions { if let r { count[r, default: 0] += 1 } }
        guard count.count >= 2 else { return [] }
        return Array(count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key).prefix(limit))
    }

    /// Volgorde in het overzicht: vastgepinde eerst (in hun eigen volgorde), dan de rest (volgorde blijft)
    static func ordered<T>(_ items: [T], pinned: (T) -> Bool) -> [T] {
        items.filter(pinned) + items.filter { !pinned($0) }
    }
}

// MARK: - 30. Radio

enum Radio171 {
    /// Xtream: `stream_type` van een live-stream
    static func isRadio(streamType: String?) -> Bool {
        guard let t = streamType?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return t == "radio_streams" || t == "radio"
    }

    /// M3U: `radio="true"` (ook "1"/"yes"), of een groep met "radio" erin
    static func isRadio(m3uAttributes a: [String: String]) -> Bool {
        if let r = a["radio"]?.lowercased(), ["true", "1", "yes"].contains(r) { return true }
        if let g = a["group-title"], isRadioGroup(g) { return true }
        return false
    }

    /// Categorie (groep) met het woord "radio" (ook "Radios", "Radiozenders", "Rádio"; niet midden in een woord)
    static func isRadioGroup(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var search = folded.startIndex
        while let r = folded.range(of: "radio", range: search..<folded.endIndex) {
            if r.lowerBound == folded.startIndex { return true }
            let before = folded[folded.index(before: r.lowerBound)]
            if !before.isLetter { return true }
            search = r.upperBound
        }
        return false
    }

    /// Zender als radio: gemarkeerd door de bron of in een radiocategorie
    static func isRadio(flag: Bool?, group: String) -> Bool { flag == true || isRadioGroup(group) }

    /// Volgorde in de radiolijst (CarPlay, Android Auto, het scherm): favorieten bovenaan, verder de volgorde van de bron
    static func ordered<T>(_ items: [T], favorite: (T) -> Bool) -> [T] {
        items.filter(favorite) + items.filter { !favorite($0) }
    }
}

// MARK: - 31. "Te veel apparaten" en "te veel streams"

enum DeviceList171 {
    struct Entry: Equatable {
        var id: String
        /// Laatst gebruikt (seconden), nil = onbekend (telt als het oudst)
        var lastUsed: Double?
        var current: Bool
    }

    /// Langst niet gebruikt bovenaan; dit apparaat altijd onderaan
    static func sorted(_ list: [Entry]) -> [Entry] {
        list.enumerated().sorted { a, b in
            if a.element.current != b.element.current { return !a.element.current }
            let x = a.element.lastUsed ?? -.infinity, y = b.element.lastUsed ?? -.infinity
            if x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Voorstel "Afmelden: niet gebruikt sinds …": het langst niet gebruikte andere apparaat, als dat minstens
    /// `minIdle` seconden (standaard een dag) niet gebruikt is
    static func suggestion(_ list: [Entry], now: Double, minIdle: Double = 24 * 3600) -> String? {
        guard let first = sorted(list).first, !first.current else { return nil }
        guard let t = first.lastUsed else { return first.id }
        return now - t >= minIdle ? first.id : nil
    }
}

// MARK: - 37. Crashrapporten

enum Crash171 {
    static let maxMessage = 500
    static let maxStack = 16 * 1024
    /// Hooguit zoveel rapporten per uur van dit apparaat (de server telt ook)
    static let maxPerHour = 20
    /// Niet verstuurde rapporten blijven hooguit 7 dagen bewaard
    static let keepSeconds: Double = 7 * 24 * 3600
    /// Lokale wachtrij hooguit zo lang
    static let maxQueued = 50

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    // volgorde telt: eerst URL's (met inloggegevens), dan e-mail, IP, query-strings en lange tokens
    private static let url = regex(#"\b[a-z][a-z0-9+.\-]{1,15}://[^\s"'<>]+"#)
    private static let www = regex(#"\bwww\.[^\s"'<>]+"#)
    private static let email = regex(#"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#)
    private static let ipv4 = regex(#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#)
    private static let ipv6 = regex(#"\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b"#)
    private static let query = regex(#"\?[^\s"'<>]*=[^\s"'<>]*"#)
    private static let hostPath = regex(#"\b[a-z0-9\-]+(?:\.[a-z0-9\-]+)+(?::\d{2,5})?/[^\s"'<>]+"#)
    private static let token = regex(#"(?<![$\w])[a-z0-9_\-+/=]{32,}"#)

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    /// Alles wat op een URL, e-mailadres, IP-adres, query-string of lang token lijkt eruit. IPTV-URL's bevatten
    /// gebruikersnamen en wachtwoorden: alles wat op een URL lijkt wordt `<url>`.
    static func scrub(_ s: String) -> String {
        var out = replace(url, in: s, with: "<url>")
        out = replace(www, in: out, with: "<url>")
        out = replace(email, in: out, with: "<email>")
        out = replace(hostPath, in: out, with: "<url>")
        out = replace(ipv6, in: out, with: "<ip>")
        out = replace(ipv4, in: out, with: "<ip>")
        out = replace(query, in: out, with: "")
        out = token.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<token>")
        return out
    }

    /// Hooguit `maxBytes` UTF-8-bytes, zonder een teken door te knippen
    static func clip(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    static func message(_ s: String) -> String { String(scrub(s).prefix(maxMessage)) }
    static func stack(_ s: String) -> String { clip(scrub(s), maxBytes: maxStack) }

    /// Eén regel van de stack zonder adressen en offsets ("3 Bingr 0x1a2b PlayerController.stop() + 120" →
    /// "Bingr PlayerController.stop()"), zodat dezelfde crash in elke build dezelfde handtekening heeft.
    static func frameKey(_ line: String) -> String {
        var parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let f = parts.first, Int(f) != nil { parts.removeFirst() }
        parts = parts.filter { !$0.hasPrefix("0x") && Int($0) == nil && $0 != "+" }
        return parts.joined(separator: " ")
    }

    /// Handtekening: soort + naam + de eerste 5 regels (zonder adressen) als stabiele hash (16 hex-tekens)
    static func signature(kind: String, name: String, frames: [String]) -> String {
        let top = frames.map(frameKey).filter { !$0.isEmpty }.prefix(5)
        let text = ([kind, name] + top).joined(separator: "\n")
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Een bewaard rapport (lokaal, tot het verstuurd is)
    struct Report: Codable, Equatable {
        var kind: String
        var signature: String
        var message: String
        var stack: String
        var at: Double
        var count: Int
        var appVersion: String
        var build: String
        var osVersion: String
        var deviceModel: String
    }

    /// Nieuw rapport in de wachtrij: dezelfde handtekening en build = alleen `count` erbij; ouder dan 7 dagen weg;
    /// hooguit `maxQueued`
    static func enqueue(_ queue: [Report], _ r: Report, now: Double) -> [Report] {
        var q = prune(queue, now: now)
        if let i = q.firstIndex(where: { $0.signature == r.signature && $0.build == r.build }) {
            q[i].count += max(1, r.count)
            q[i].at = max(q[i].at, r.at)
        } else {
            q.append(r)
        }
        if q.count > maxQueued { q = Array(q.suffix(maxQueued)) }
        return q
    }

    static func prune(_ queue: [Report], now: Double) -> [Report] {
        queue.filter { now - $0.at <= keepSeconds && $0.at <= now + 3600 }
    }

    /// Mag er nog een rapport weg? (tijden van verstuurde rapporten in het afgelopen uur)
    static func maysend(sent: [Double], now: Double) -> Bool {
        sent.filter { now - $0 < 3600 }.count < maxPerHour
    }
}
