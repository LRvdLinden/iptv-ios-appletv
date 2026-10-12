import Foundation

/// Een acteur/actrice om een eigen pagina voor te openen. Zonder TMDB-ID (OMDb/afspeellijst geven
/// alleen namen) zoekt de pagina de persoon bij het openen op naam op.
struct PersonRef: Identifiable, Hashable {
    var id: String { tmdbID.map { "tmdb-\($0)" } ?? "name-\(name)" }
    var tmdbID: Int?
    var name: String
    var photo: URL?
    var department: String?
}

/// Gegevens van één persoon (TMDB /person/{id}).
struct PersonInfo: Hashable {
    var id: Int
    var name: String
    var photo: URL?
    var department: String?
    var birthday: Date?
    var deathday: Date?
    var birthPlace: String?
    var biography: String?
}

/// Een film of serie waarin de persoon speelt (TMDB /person/{id}/combined_credits).
struct PersonCredit: Identifiable, Hashable {
    var id: String { "\(isShow ? "tv" : "movie")-\(tmdbID)" }
    var tmdbID: Int
    var isShow: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var date: String?
    var poster: URL?
    var overview: String?
    var popularity: Double
    var voteCount: Int
    var character: String?
    var genreIDs: [Int]

    /// Titels om mee te koppelen aan de afspeellijst (app-taal én origineel).
    var titles: [String] { [title, originalTitle].compactMap { $0 }.filter { !$0.isEmpty } }
}

/// Personen ophalen bij TMDB, met een geheugencache (pagina's en zoekresultaten worden vaak opnieuw geopend).
@MainActor
final class PersonService {
    static let shared = PersonService()

    private var infoCache: [String: PersonInfo] = [:]          // "id|taal"
    private var creditCache: [String: [PersonCredit]] = [:]    // "id|taal"
    private var searchCache: [String: [PersonRef]] = [:]       // "taal|zoekterm"
    private var nameCache: [String: Int] = [:]

    var available: Bool { Secrets.isSet(Secrets.tmdbAPIKey) }

    // MARK: TMDB-antwoorden

    private struct PersonR: Decodable {
        let id: Int; let name: String?; let profile_path: String?; let known_for_department: String?
        let birthday: String?; let deathday: String?; let place_of_birth: String?; let biography: String?
    }
    private struct SearchR: Decodable {
        struct P: Decodable { let id: Int; let name: String?; let profile_path: String?; let known_for_department: String?; let popularity: Double? }
        let results: [P]?
    }
    private struct CreditsR: Decodable {
        struct C: Decodable {
            let id: Int; let media_type: String?
            let title: String?; let name: String?; let original_title: String?; let original_name: String?
            let release_date: String?; let first_air_date: String?
            let poster_path: String?; let overview: String?; let popularity: Double?; let vote_count: Int?
            let character: String?; let genre_ids: [Int]?
        }
        let cast: [C]?
    }

    private static func date(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    // MARK: ophalen

    /// TMDB-ID bij een naam (eerste zoekresultaat, voorkeur voor acteurs).
    func resolve(name: String) async -> Int? {
        let key = name.lowercased()
        if let id = nameCache[key] { return id }
        guard available else { return nil }
        let r: SearchR? = await TMDB.get("/search/person", ["query": name, "include_adult": "false", "language": TMDB.language])
        let list = r?.results ?? []
        let id = (list.first { $0.known_for_department == "Acting" } ?? list.first)?.id
        if let id { nameCache[key] = id }
        return id
    }

    /// Persoonsgegevens in de app-taal; lege biografie → Engels.
    func info(id: Int) async -> PersonInfo? {
        let lang = TMDB.language, key = "\(id)|\(lang)"
        if let c = infoCache[key] { return c }
        guard available, let p: PersonR = await TMDB.get("/person/\(id)", ["language": lang]) else { return nil }
        var bio = p.biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (bio?.isEmpty ?? true) && lang != "en-US" {
            let en: PersonR? = await TMDB.get("/person/\(id)", ["language": "en-US"])
            bio = en?.biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let info = PersonInfo(id: p.id, name: p.name ?? "", photo: TMDB.img(p.profile_path, "h632"),
                              department: p.known_for_department, birthday: Self.date(p.birthday), deathday: Self.date(p.deathday),
                              birthPlace: p.place_of_birth.flatMap { $0.isEmpty ? nil : $0 },
                              biography: (bio?.isEmpty ?? true) ? nil : bio)
        infoCache[key] = info
        return info
    }

    /// Films en series als acteur/actrice: zonder dubbelen, talkshows/nieuws en optredens als zichzelf;
    /// populairste eerst.
    func credits(id: Int) async -> [PersonCredit] {
        let lang = TMDB.language, key = "\(id)|\(lang)"
        if let c = creditCache[key] { return c }
        guard available, let r: CreditsR = await TMDB.get("/person/\(id)/combined_credits", ["language": lang]) else { return [] }
        var seen = Set<String>(), out: [PersonCredit] = []
        for c in r.cast ?? [] {
            let isShow = c.media_type == "tv"
            guard c.media_type == "movie" || isShow else { continue }
            let genres = c.genre_ids ?? []
            if genres.contains(10767) || genres.contains(10763) { continue }   // talkshow, nieuws
            let ch = c.character?.lowercased() ?? ""
            if ch == "self" || ch.hasPrefix("self ") || ch.hasPrefix("himself") || ch.hasPrefix("herself") { continue }
            guard let title = c.title ?? c.name, !title.isEmpty else { continue }
            let credit = PersonCredit(tmdbID: c.id, isShow: isShow, title: title, originalTitle: c.original_title ?? c.original_name,
                                      year: (c.release_date ?? c.first_air_date).flatMap { Int($0.prefix(4)) },
                                      date: c.release_date ?? c.first_air_date,
                                      poster: TMDB.img(c.poster_path, "w342"), overview: c.overview,
                                      popularity: c.popularity ?? 0, voteCount: c.vote_count ?? 0,
                                      character: c.character, genreIDs: genres)
            if seen.insert(credit.id).inserted { out.append(credit) }
        }
        // populair én bekend (stemmen) eerst; bij gelijke stand het nieuwste
        out.sort { a, b in
            let sa = a.popularity + log10(Double(a.voteCount) + 1) * 5, sb = b.popularity + log10(Double(b.voteCount) + 1) * 5
            if abs(sa - sb) > 0.001 { return sa > sb }
            return (a.date ?? "") > (b.date ?? "")
        }
        creditCache[key] = out
        return out
    }

    /// Personen zoeken op naam (voor Zoeken).
    func search(_ query: String) async -> [PersonRef] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let key = "\(TMDB.language)|\(q.lowercased())"
        if let c = searchCache[key] { return c }
        guard available, q.count >= 3 else { return [] }
        guard let r: SearchR = await TMDB.get("/search/person", ["query": q, "include_adult": "false", "language": TMDB.language]) else { return [] }
        if Task.isCancelled { return [] }
        let list = (r.results ?? [])
            .filter { $0.name?.isEmpty == false && ($0.profile_path != nil || ($0.popularity ?? 0) > 2) }
            .prefix(20)
            .map { PersonRef(tmdbID: $0.id, name: $0.name ?? "", photo: TMDB.img($0.profile_path, "w185"), department: $0.known_for_department) }
        searchCache[key] = Array(list)
        return Array(list)
    }
}
