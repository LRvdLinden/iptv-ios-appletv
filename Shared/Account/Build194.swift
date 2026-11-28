import Foundation

/// Build 194 (versie 1.1.3): Live TV heeft een eigen categorie Terugkijken met alle zenders waarvan je kunt terugkijken
/// (`catchupDays > 0`), over alle servers heen. Pure logica, alleen Foundation: de zelftest compileert dit bestand los
/// van de app (generiek over het type, zodat `Channel` er niet bij nodig is).
enum Build194 {

    /// Zenders met terugkijken: eerst die van de open server (op hun eigen volgorde, zoals Alle zenders), daarna die van
    /// de andere servers. Elke zender één keer per id (dubbele id's laten de lijst vastlopen, zie P0-fix) en dezelfde
    /// zender op twee servers (zelfde identiteit: naam + gids-id) één keer, de eerste blijft. Zenders zonder
    /// terugkijken doen niet mee, ook niet als de andere server ze wel heeft.
    static func select<T>(active: [T], others: [T], days: (T) -> Int, id: (T) -> String, identity: (T) -> String) -> [T] {
        var seenID = Set<String>(), seenIdentity = Set<String>()
        var out: [T] = []
        for c in active + others where days(c) > 0 {
            guard seenID.insert(id(c)).inserted else { continue }
            guard seenIdentity.insert(identity(c)).inserted else { continue }
            out.append(c)
        }
        return out
    }

    /// De categorie staat alleen in de keuze als er minstens één zender met terugkijken is
    static func showsCategory(activeHasCatchup: Bool, otherCount: Int) -> Bool { activeHasCatchup || otherCount > 0 }

    /// Is de gekozen categorie nog geldig? Verdwijnt Terugkijken (andere server, andere lijst), dan terug naar Alle zenders.
    static func validSelection(_ group: String, catchupKey: String, shows: Bool, allKey: String) -> String {
        group == catchupKey && !shows ? allKey : group
    }

    // MARK: Tweeling-koppeling (terugkijken via een gelijke zender op dezelfde server)

    /// Eén zender voor het zoeken naar een tweeling (zelfde regels als Android `Build194Logic.kt`, `Twin`)
    struct TwinInput {
        let id: String
        let name: String
        let epg: String?
        let days: Int
        let server: String
    }
    struct TwinMatch: Equatable { let server: String; let id: String; let twin: String }

    private static let tagWords = ["catch-up", "catchup", "catch up", "terugkijken", "replay", "timeshift"]
    private static let dropWords: Set<String> = ["hd", "uhd", "fhd", "sd", "4k", "hevc", "h265", "raw"]

    /// Naam om zenders te vergelijken: kleine letters, zonder accenten, tags tussen [] () {} en | die op terugkijken
    /// wijzen weg, losse kwaliteitswoorden (hd, uhd, fhd, sd, 4k, hevc, h265, raw) weg, alleen letters en cijfers.
    static func normalizedName(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        func hasTag(_ t: Substring) -> Bool { tagWords.contains { t.contains($0) } }
        // tags tussen haakjes
        var out = "", i = s.startIndex
        let open: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        while i < s.endIndex {
            let ch = s[i]
            if let close = open[ch], let end = s[s.index(after: i)...].firstIndex(of: close) {
                let inner = s[s.index(after: i)..<end]
                if hasTag(inner) { i = s.index(after: end); out.append(" "); continue }
            }
            out.append(ch); i = s.index(after: i)
        }
        s = out
        // delen tussen | die op terugkijken wijzen
        if s.contains("|") { s = s.split(separator: "|", omittingEmptySubsequences: false).filter { !hasTag($0) }.joined(separator: " ") }
        let words = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !dropWords.contains($0) }
        return words.joined()
    }

    private static func epgKey(_ e: String?) -> String? {
        guard let t = e?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// Voor zenders zonder eigen terugkijken (`days == 0`) een tweeling zoeken: een andere zender op DEZELFDE server met
    /// terugkijken (`days > 0`). Eerst op gids-id (precies één kandidaat = match, twee of meer = geen match, niet
    /// doorvallen naar de naam), anders op de genormaliseerde naam (minstens 3 tekens, precies één kandidaat). Een zender
    /// met eigen terugkijken gebruikt altijd zichzelf. Live kijken blijft op de originele zender.
    static func twins(_ channels: [TwinInput]) -> [TwinMatch] {
        var out: [TwinMatch] = []
        for (server, list) in Dictionary(grouping: channels, by: \.server) {
            var seenID = Set<String>()
            let unique = list.filter { seenID.insert($0.id).inserted }
            let candidates = unique.filter { $0.days > 0 }
            guard !candidates.isEmpty else { continue }
            var byEPG: [String: [String]] = [:], byName: [String: [String]] = [:]
            for c in candidates {
                if let k = epgKey(c.epg) { byEPG[k, default: []].append(c.id) }
                let n = normalizedName(c.name)
                if n.count >= 3 { byName[n, default: []].append(c.id) }
            }
            for t in unique where t.days == 0 {
                if let k = epgKey(t.epg), let hit = byEPG[k] {
                    if hit.count == 1 { out.append(TwinMatch(server: server, id: t.id, twin: hit[0])) }
                    continue   // twee of meer kandidaten met dit gids-id: geen match
                }
                let n = normalizedName(t.name)
                if n.count >= 3, let hit = byName[n], hit.count == 1 { out.append(TwinMatch(server: server, id: t.id, twin: hit[0])) }
            }
        }
        return out
    }
}
