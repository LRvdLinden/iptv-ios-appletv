import Foundation

// Build 151: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
//
// Aanleiding: een tweede server met 123k films, 30k series en 12k zenders, waarvan ±80% in verborgen categorieën,
// gaf op de Apple TV een geheugenpiek van 1,8 GB: alles werd als volledig item ingelezen en bewaard (`rawLibrary`),
// ook wat nooit in beeld komt. Android, Samsung TV en de webspeler slaan dat sinds build 149 over; Apple nu ook.
//
// - `SkipFilter`: per categorie één keer: is die verborgen (dan niet inlezen)?
// - `SkippedCatalog`: wat niet is ingelezen, als telling per categorie (Categorieën, Beheren, diagnose) en als
//   compacte zoekindex (id, titel, categorie, jaar, afbeelding) voor films en series (zoeken in verborgen categorieën).
//   Zet de gebruiker een categorie weer aan, dan wordt de server opnieuw opgehaald (`needsRefetch`).
// - `SourcePreference`: bij dubbele titels in samengevoegde categorieën (build 150) de beste bron houden.

/// Build 151: wat bij het inlezen overgeslagen wordt (verborgen categorie), per categorienaam één keer gevraagd.
final class SkipFilter: @unchecked Sendable {
    private let hidden: (String) -> Bool
    private var memo: [String: Bool] = [:]
    private let lock = NSLock()

    init(_ hidden: @escaping (String) -> Bool) { self.hidden = hidden }

    func skip(_ group: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let v = memo[group] { return v }
        let v = hidden(group)
        memo[group] = v
        return v
    }
}

/// Build 151: niet ingelezen items (verborgen categorieën). Bewaard met de lijst (`Library.skipped`).
struct SkippedCatalog: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable { case live, movie, series }

    /// Eén categorie met het aantal overgeslagen items
    struct Cat: Codable, Sendable, Equatable {
        var k: Kind
        var g: String
        var n: Int
    }

    /// Compacte rij voor het zoeken (korte sleutels: dit staat honderdduizend keer in het bestand)
    struct Row: Codable, Sendable, Equatable {
        /// soort (alleen films en series)
        var k: Kind
        /// id zoals de app hem gebruikt ("xv123", "xs45")
        var i: String
        /// naam zoals de server hem levert
        var t: String
        /// index in `groups`
        var g: Int32
        /// jaar
        var y: Int?
        /// afbeelding (poster)
        var p: String?
        /// bestandsextensie (films)
        var x: String?
        /// TMDB-id
        var d: Int?
    }

    /// Categorieën in de volgorde waarin ze voorkwamen (per soort)
    var cats: [Cat] = []
    /// Categorienamen van de rijen (index = `Row.g`)
    var groups: [String] = []
    var rows: [Row] = []

    var isEmpty: Bool { cats.isEmpty }

    /// Totaal overgeslagen van een soort
    func count(_ k: Kind) -> Int { cats.reduce(0) { $1.k == k ? $0 + $1.n : $0 } }

    /// Categorie → aantal van een soort
    func counts(_ k: Kind) -> [String: Int] {
        var out: [String: Int] = [:]
        for c in cats where c.k == k { out[c.g, default: 0] += c.n }
        return out
    }

    /// Categorienamen van een soort, in volgorde
    func groupNames(_ k: Kind) -> [String] { cats.filter { $0.k == k }.map(\.g) }

    func group(of r: Row) -> String { Int(r.g) < groups.count && r.g >= 0 ? groups[Int(r.g)] : "" }

    func rows(_ k: Kind) -> [Row] { rows.filter { $0.k == k } }

    /// Staat er een overgeslagen categorie die nu wél zichtbaar zou zijn? Dan moet de server opnieuw opgehaald worden.
    func needsRefetch(stillHidden: (String) -> Bool) -> Bool {
        cats.contains { $0.n > 0 && !stillHidden($0.g) }
    }

    /// Bouwt een `SkippedCatalog` tijdens het inlezen (per soort, één lijst tegelijk)
    final class Builder: @unchecked Sendable {
        private var order: [String: Int] = [:]           // "soort|categorie" → index in cats
        private var groupIndex: [String: Int32] = [:]
        private(set) var out = SkippedCatalog()

        init() {}

        /// Eén overgeslagen item tellen
        func count(_ k: Kind, _ g: String) {
            let key = k.rawValue + "|" + g
            if let i = order[key] { out.cats[i].n += 1 } else { order[key] = out.cats.count; out.cats.append(Cat(k: k, g: g, n: 1)) }
        }

        /// Overgeslagen item tellen en in de zoekindex zetten
        func add(_ k: Kind, id: String, title: String, group g: String, year: Int? = nil, poster: String? = nil,
                 ext: String? = nil, tmdb: Int? = nil) {
            count(k, g)
            let gi: Int32
            if let x = groupIndex[g] { gi = x } else { gi = Int32(out.groups.count); groupIndex[g] = gi; out.groups.append(g) }
            out.rows.append(Row(k: k, i: id, t: title, g: gi, y: year, p: poster.flatMap { $0.isEmpty ? nil : $0 },
                                x: ext.flatMap { $0.isEmpty || $0 == "mp4" ? nil : $0 }, d: tmdb))
        }

        func finish() -> SkippedCatalog? {
            return out.isEmpty ? nil : out
        }
    }

    /// Geleverd per soort = ingelezen + overgeslagen (de diagnose "geleverd · zichtbaar" blijft zo kloppen)
    static func delivered(loaded: Int, _ s: SkippedCatalog?, _ k: Kind) -> Int { loaded + (s?.count(k) ?? 0) }

    /// Categorieën met aantallen: de ingelezen (in volgorde) en daarna de overgeslagen, zonder dubbele
    static func groupCounts(loaded: [String], _ s: SkippedCatalog?, _ k: Kind) -> [(group: String, count: Int)] {
        var idx: [String: Int] = [:]
        var out: [(group: String, count: Int)] = []
        for g in loaded {
            if let i = idx[g] { out[i].count += 1 } else { idx[g] = out.count; out.append((g, 1)) }
        }
        for c in s?.cats ?? [] where c.k == k {
            if let i = idx[c.g] { out[i].count += c.n } else { idx[c.g] = out.count; out.append((c.g, c.n)) }
        }
        return out
    }
}

/// Build 151: bij dezelfde titel in samengevoegde categorieën (build 150) de beste bron houden: eerst de bron in de
/// gewenste taal (audio-taal, anders de app-taal), dan een meertalige bron (Multi/Dub/Sub), dan de rest (de eerste).
/// Zoals Android, Samsung TV en de webspeler.
enum SourcePreference {
    /// Rang van een categorie (lager = beter). `want`: taalcodes in volgorde van voorkeur ("NL", "EN"), hoofdletters.
    static func rank(group: String, want: [String]) -> Int {
        let labels = CategoryName.parse(group).labels.map { $0.uppercased() }
        for (i, w) in want.enumerated() where labels.contains(w) { return i }
        if labels.contains(where: { $0 == "MULTI" || $0 == "DUB" || $0 == "SUB" }) { return want.count }
        return want.count + 1
    }

    /// Talen van een taalcode (ISO 639-1, "nl", "en") naar de labels van `CategoryName` ("NL"/"BE", "EN"/"UK"/"US")
    static func labels(forLanguage code: String) -> [String] {
        switch code.lowercased().prefix(2) {
        case "nl": return ["NL", "BE"]
        case "en": return ["EN", "UK", "US"]
        case "de": return ["DE"]
        case "fr": return ["FR"]
        case "es": return ["ES"]
        case "it": return ["IT"]
        case "tr": return ["TR"]
        case "pl": return ["PL"]
        case "pt": return ["PT", "BR"]
        case "ar": return ["AR"]
        default: return [String(code.prefix(2)).uppercased()]
        }
    }

    /// Gewenste labels: eerst de audio-talen, daarna de app-taal (zonder dubbele)
    static func want(audio: [String], app: String) -> [String] {
        var out: [String] = []
        for c in audio + [app] { for l in labels(forLanguage: c) where !out.contains(l) { out.append(l) } }
        return out
    }

    /// `better(nieuw, oud)` voor `CategoryMerge.unique`: alleen wisselen bij een echt betere rang
    static func better(_ new: String, than old: String, want: [String]) -> Bool {
        rank(group: new, want: want) < rank(group: old, want: want)
    }
}

// MARK: - Rij "Zenders" op Home

/// Build 151: welke zenders de rij "Zenders" op Home toont (zenderlogo's van de eigen server, zoals een rij
/// streamingdiensten). Eerst de recent bekeken zenders en de favorieten, daarna om de beurt uit de grootste zichtbare
/// live-categorieën (zenders met een logo eerst). Zonder dubbele, hooguit `max`.
enum ChannelLogoRow {
    static func pick(first: [String], groups: [(group: String, ids: [String])], hasLogo: (String) -> Bool,
                     max: Int = 15, topGroups: Int = 6) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in first where out.count < max && seen.insert(id).inserted { out.append(id) }
        guard out.count < max else { return out }
        let top = groups.enumerated()
            .sorted { $0.element.ids.count != $1.element.ids.count ? $0.element.ids.count > $1.element.ids.count : $0.offset < $1.offset }
            .prefix(topGroups).map(\.element.ids)
        // eerst alleen met logo, daarna (als dat niet genoeg is) ook zonder
        for needLogo in [true, false] {
            var pos = Array(repeating: 0, count: top.count)
            var progress = true
            while out.count < max && progress {
                progress = false
                for (gi, ids) in top.enumerated() where out.count < max {
                    while pos[gi] < ids.count {
                        let id = ids[pos[gi]]
                        pos[gi] += 1
                        if seen.contains(id) || (needLogo && !hasLogo(id)) { continue }
                        seen.insert(id)
                        out.append(id)
                        progress = true
                        break
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Geen dubbele titels in de rijen op Home (meer servers)

/// Build 151: dezelfde titel op meer servers staat in een rij op Home maar één keer. Een item is dubbel als één van
/// zijn sleutels al gezien is (TMDB-id, IMDb-id, genormaliseerde titel + jaar; zenders: de opgeschoonde naam). Van de
/// dubbele blijft de bron met de laagste rang (audio-/app-taal, dan de actieve server, dan de rest) op de plek van
/// de eerste; bij gelijke rang de eerste (bij Verder kijken: de meest recente, want die lijst is al op tijd gesorteerd).
enum HomeDedupe {
    /// Sleutels van een film of serie. `title`: de titel zonder taallabels (door de aanroeper opgeschoond).
    static func titleKeys(series: Bool, title: String, year: Int?, tmdb: Int?, imdb: String?) -> [String] {
        let k = series ? "s" : "m"
        var out: [String] = []
        if let t = tmdb, t > 0 { out.append(k + "|t\(t)") }
        if let i = imdb?.lowercased(), !i.isEmpty { out.append(k + "|i" + i) }
        let n = ProviderMatch.key(title)
        if !n.isEmpty { out.append(k + "|n" + n + "|\(year ?? 0)") }
        return out
    }

    /// Sleutel van een zender: de opgeschoonde naam ("NL | NPO 1 HD" = "NPO 1")
    static func channelKey(_ name: String) -> String {
        "c|" + CategoryName.mergeKey(CategoryName.clean(name, title: true))
    }

    /// Op volgorde, zonder dubbele; `rank` lager = betere bron (die neemt de plek van de eerste over)
    static func unique<T>(_ items: [T], keys: (T) -> [String], rank: (T) -> Int = { _ in 0 }) -> [T] {
        guard items.count > 1 else { return items }
        var at: [String: Int] = [:]
        var out: [T] = []
        var ranks: [Int] = []
        out.reserveCapacity(items.count)
        for x in items {
            let ks = keys(x)
            if let i = ks.lazy.compactMap({ at[$0] }).first {
                let r = rank(x)
                if r < ranks[i] { out[i] = x; ranks[i] = r }
                for k in ks where at[k] == nil { at[k] = i }
                continue
            }
            let i = out.count
            for k in ks { at[k] = i }
            out.append(x)
            ranks.append(rank(x))
        }
        return out
    }

    /// Rang van een bron: taal (0 audio-taal, 1 app-taal, 2 meertalig, 3 anders) × 2 + (0 actieve server, 1 andere)
    static func rank(audio: String?, multi: Bool, preferredAudio: String, appLanguage: String, active: Bool) -> Int {
        let a = audio.map { String($0.lowercased().prefix(2)) }
        let lang: Int
        if let a, a == preferredAudio.lowercased().prefix(2) { lang = 0 }
        else if let a, a == appLanguage.lowercased().prefix(2) { lang = 1 }
        else if multi { lang = 2 }
        else { lang = 3 }
        return lang * 2 + (active ? 0 : 1)
    }
}
