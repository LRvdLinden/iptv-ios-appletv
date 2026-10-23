import Foundation

// Build 141: pure logica (zonder SwiftUI), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).

// MARK: - Mijn lijst: welk id en waar de titel vandaan komt

enum MyListID {
    /// Voorvoegsel van een TMDB-titel ("tmdb-movie-123" / "tmdb-tv-123"), gelijk aan `DiscoverItem.idPrefix`
    static let externalPrefix = "tmdb-"

    /// Id waaronder een titel in Mijn lijst komt. Een titel uit een bibliotheek houdt zijn eigen id. Een aanbeveling die
    /// niet in een bibliotheek staat ("rec-…", alleen op dit apparaat bekend) krijgt zijn TMDB-id, zodat Mijn lijst
    /// hem op elk apparaat kan tonen (tot build 140 kwam "rec-…" in de lijst en verscheen hij nergens). nil = het
    /// TMDB-id is (nog) niet bekend: dan geen knop Mijn lijst.
    static func forTitle(id: String, tmdb: Int?, isShow: Bool) -> String? {
        guard id.hasPrefix("rec-") else { return id }
        guard let tmdb, tmdb > 0 else { return nil }
        return "\(externalPrefix)\(isShow ? "tv" : "movie")-\(tmdb)"
    }

    enum Origin: Equatable {
        /// op de open server (uit de bibliotheek)
        case active
        /// op een andere server van het account (via CrossServer / catalogmeta)
        case otherServer
        /// TMDB-titel (niet in een bibliotheek)
        case external
    }

    /// Waar een sleutel uit Mijn lijst ("<server-id>|<item-id>") vandaan komt, gezien vanaf de open server.
    /// Server-id hoofdletterongevoelig, item-id exact. nil = geen geldige sleutel.
    static func origin(of key: String, activeSID: String?) -> Origin? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        let sid = key[..<bar], item = key[key.index(after: bar)...]
        guard !sid.isEmpty, !item.isEmpty else { return nil }
        let isActive = activeSID.map { sid.caseInsensitiveCompare($0) == .orderedSame } ?? false
        // een TMDB-titel hoort bij geen enkele server (ook als hij onder een andere server-id is bewaard)
        if item.hasPrefix(externalPrefix) { return .external }
        return isActive ? .active : .otherServer
    }

    /// De tegels van Mijn lijst: per sleutel de titel als die te tonen is. `active`: items van de open server (op
    /// item-id), `other`: gevonden of net toegevoegde items van andere servers (op genormaliseerde sleutel),
    /// `external`: bekende TMDB-titels (op id). Volgorde: laatst toegevoegd eerst.
    static func visible<T>(keys: [(key: String, at: Double)], activeSID: String?, active: [String: T], other: [String: T],
                           external: [String: T]) -> [T] {
        var out: [(T, Double)] = []
        for (k, at) in keys {
            guard let o = origin(of: k, activeSID: activeSID), let bar = k.firstIndex(of: "|") else { continue }
            let item = String(k[k.index(after: bar)...])
            let norm = k[..<bar].lowercased() + "|" + item
            switch o {
            case .active: if let t = active[item] { out.append((t, at)) }
            case .external: if let t = external[item] { out.append((t, at)) }
            case .otherServer: if let t = other[norm] { out.append((t, at)) }
            }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

// MARK: - Home: Nieuw op Bingr op de plek van Nieuw toegevoegd

enum HomeRowOrder {
    /// "Nieuw toegevoegd" (`recent`) staat niet meer op Home; Nieuw op Bingr (`streaming`) komt op zijn plek, met zijn
    /// eigen aan/uit (of dat van `recent` als `streaming` er nog niet stond). Daarna is er één rij Nieuw op Bingr.
    static func newOnBingrAtRecent<R>(_ rows: [R], key: (R) -> String, visible: (R) -> Bool,
                                      make: (String, Bool) -> R) -> [R] {
        guard let ri = rows.firstIndex(where: { key($0) == "recent" }) else { return rows }
        let v = rows.first(where: { key($0) == "streaming" }).map(visible) ?? visible(rows[ri])
        var out: [R] = []
        for (i, r) in rows.enumerated() {
            if i == ri { out.append(make("streaming", v)) }
            else if key(r) != "streaming" && key(r) != "recent" { out.append(r) }
        }
        return out
    }
}
