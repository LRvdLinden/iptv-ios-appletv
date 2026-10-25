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
