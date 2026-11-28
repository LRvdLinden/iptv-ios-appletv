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
}
