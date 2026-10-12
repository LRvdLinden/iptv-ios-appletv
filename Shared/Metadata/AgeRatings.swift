import Foundation
import Combine

/// Leeftijdsinfo van één titel uit TMDB: de classificatie (Kijkwijzer eerst, dan VS/VK/DE/overig)
/// en de genres. Wordt op schijf bewaard zodat elke titel maar één keer opgezocht wordt (build 53).
struct AgeInfo: Codable, Hashable {
    /// Minimumleeftijd volgens de classificatie; nil = geen classificatie gevonden
    var age: Int?
    /// Zoals het land het schrijft, bijv. "12" (Kijkwijzer) of "PG-13"
    var label: String?
    /// Land van de gebruikte classificatie ("NL", "US", …)
    var country: String?
    /// TMDB-genre-ID's
    var genres: [Int] = []
    /// Titel bij TMDB gevonden?
    var found: Bool
    var checked: Date

    /// Animatie, familie of kids (film én serie)
    var kidsGenre: Bool { genres.contains { [16, 10751, 10762].contains($0) } }
    /// Horror, thriller, misdaad, oorlog (film) en misdaad, oorlog & politiek (serie)
    var adultGenre: Bool { genres.contains { [27, 53, 80, 10752, 10768].contains($0) } }

    /// Nog bruikbaar? Gevonden met classificatie: 60 dagen, anders na 14 dagen opnieuw proberen.
    var isFresh: Bool {
        let days: Double = (found && age != nil) ? 60 : 14
        return Date().timeIntervalSince(checked) < days * 86_400
    }
}

/// Haalt classificaties op bij TMDB en houdt ze bij voor het leeftijdsfilter van profielen.
@MainActor
final class AgeRatingService: ObservableObject {
    static let shared = AgeRatingService()

    /// key: zelfde sleutel als MetadataService ("m|titel|jaar" / "s|titel|jaar"), met de titel zoals in de afspeellijst
    @Published private(set) var cache: [String: AgeInfo] = [:]
    private var inFlight: [String: Task<AgeInfo?, Never>] = [:]
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("age-ratings.json")
    private var saveTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchKey = ""

    var available: Bool { Secrets.isSet(Secrets.tmdbAPIKey) }

    private init() {
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: AgeInfo].self, from: d) { cache = c }
    }

    nonisolated static func key(title: String, year: Int?, isShow: Bool) -> String {
        MetadataService.key(title: title, year: year, isShow: isShow)
    }

    func cached(_ m: Movie) -> AgeInfo? { cache[Self.key(title: m.title, year: m.year, isShow: false)] }
    func cached(_ s: Series) -> AgeInfo? { cache[Self.key(title: s.title, year: s.year, isShow: true)] }

    /// Classificatie van één titel (uit de cache, anders bij TMDB opgezocht).
    func info(title: String, year: Int?, isShow: Bool, imdb: String? = nil, tmdbID: Int? = nil) async -> AgeInfo? {
        let k = Self.key(title: title, year: year, isShow: isShow)
        if let c = cache[k], c.isFresh { return c }
        guard available else { return cache[k] }
        if let t = inFlight[k] { return await t.value }
        let task = Task<AgeInfo?, Never> {
            await TMDBRatings.lookup(title: title, year: year, isShow: isShow, imdb: imdb, tmdbID: tmdbID)
        }
        inFlight[k] = task
        let r = await task.value
        inFlight[k] = nil
        if let r { cache[k] = r; scheduleSave() }
        return r ?? cache[k]
    }

    /// Op de achtergrond classificaties ophalen voor een lijst (alleen nodig bij een profiel met leeftijdsgrens).
    /// Eerst wat nu zichtbaar kan zijn (kindergroepen), daarna de rest; per sessie begrensd, de cache groeit mee.
    func prefetch(_ lib: Library) {
        guard available, !lib.movies.isEmpty || !lib.series.isEmpty else { return }
        let key = "\(lib.movies.count)-\(lib.series.count)-\(lib.movies.first?.id ?? "")-\(lib.series.first?.id ?? "")"
        guard key != prefetchKey else { return }
        prefetchKey = key
        prefetchTask?.cancel()
        let known = cache
        prefetchTask = Task { [weak self] in
            // werklijst op de achtergrond samenstellen (tienduizenden titels)
            let work: [Job] = await Task.detached(priority: .utility) {
                var first: [Job] = [], rest: [Job] = []
                func add(_ j: Job, _ group: String) {
                    if let c = known[j.key], c.isFresh { return }
                    if ParentalControl.isAdultGroup(group) { return }   // wordt toch altijd verborgen
                    if ParentalControl.isKidsGroup(group) { first.append(j) } else { rest.append(j) }
                }
                for m in lib.movies {
                    add(Job(key: AgeRatingService.key(title: m.title, year: m.year, isShow: false),
                            title: m.title, year: m.year, isShow: false, imdb: m.imdbID), m.group)
                }
                for s in lib.series {
                    add(Job(key: AgeRatingService.key(title: s.title, year: s.year, isShow: true),
                            title: s.title, year: s.year, isShow: true, imdb: s.imdbID), s.group)
                }
                var seen = Set<String>()
                return Array((first + rest).filter { seen.insert($0.key).inserted }.prefix(2500))
            }.value
            guard !work.isEmpty, !Task.isCancelled else { return }
            var batch: [String: AgeInfo] = [:]
            var index = 0
            while index < work.count, !Task.isCancelled {
                let chunk = Array(work[index..<min(index + 6, work.count)])   // 6 tegelijk: ruim binnen de TMDB-limiet
                index += chunk.count
                await withTaskGroup(of: (String, AgeInfo?).self) { g in
                    for j in chunk {
                        g.addTask { (j.key, await TMDBRatings.lookup(title: j.title, year: j.year, isShow: j.isShow, imdb: j.imdb, tmdbID: nil)) }
                    }
                    for await (k, r) in g { if let r { batch[k] = r } }
                }
                // in porties doorgeven: het filter loopt dan niet bij elke titel opnieuw
                if batch.count >= 60 || index >= work.count {
                    self?.merge(batch); batch = [:]
                }
            }
            if !batch.isEmpty { self?.merge(batch) }
        }
    }

    private struct Job: Sendable { let key: String; let title: String; let year: Int?; let isShow: Bool; let imdb: String? }

    private func merge(_ b: [String: AgeInfo]) {
        guard !b.isEmpty else { return }
        cache.merge(b) { _, new in new }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = cache, url = cacheURL
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }
}

/// TMDB-classificaties: films via release_dates, series via content_ratings.
enum TMDBRatings {
    /// Volgorde van landen: Kijkwijzer (NL) eerst, dan VS, VK, Duitsland, België
    static let countries = ["NL", "US", "GB", "DE", "BE"]

    private struct Find: Decodable { struct R: Decodable { let id: Int }; let movie_results: [R]?; let tv_results: [R]? }
    private struct Search: Decodable { struct R: Decodable { let id: Int }; let results: [R]? }
    private struct Genre: Decodable { let id: Int }
    private struct MovieR: Decodable {
        struct RD: Decodable {
            struct C: Decodable { struct D: Decodable { let certification: String?; let type: Int? }; let iso_3166_1: String; let release_dates: [D]? }
            let results: [C]?
        }
        let id: Int; let genres: [Genre]?; let release_dates: RD?
    }
    private struct TVR: Decodable {
        struct CR: Decodable { struct C: Decodable { let iso_3166_1: String; let rating: String? }; let results: [C]? }
        let id: Int; let genres: [Genre]?; let content_ratings: CR?
    }

    static func lookup(title: String, year: Int?, isShow: Bool, imdb: String?, tmdbID: Int?) async -> AgeInfo? {
        guard Secrets.isSet(Secrets.tmdbAPIKey) else { return nil }
        var id = tmdbID
        if id == nil, let imdb, imdb.hasPrefix("tt") {
            let f: Find? = await TMDB.get("/find/\(imdb)", ["external_source": "imdb_id"])
            id = isShow ? f?.tv_results?.first?.id : f?.movie_results?.first?.id
        }
        if id == nil {
            // IPTV-titels schoonmaken ("NL | Frozen (2013) 4K" → "Frozen", 2013)
            let p = TitleCleaner.parse(title)
            let y = p.year ?? year
            var q = ["query": p.title, "include_adult": "false"]
            if let y { q[isShow ? "first_air_date_year" : "year"] = String(y) }
            let s: Search? = await TMDB.get(isShow ? "/search/tv" : "/search/movie", q)
            id = s?.results?.first?.id
            if id == nil, y != nil {
                q[isShow ? "first_air_date_year" : "year"] = nil
                let s2: Search? = await TMDB.get(isShow ? "/search/tv" : "/search/movie", q)
                id = s2?.results?.first?.id
            }
        }
        guard let id else {
            // niet gevonden: onthouden (zodat we niet blijven zoeken), zonder leeftijd
            return AgeInfo(age: nil, label: nil, country: nil, genres: [], found: false, checked: Date())
        }
        var certs: [(country: String, label: String)] = []
        var genres: [Int] = []
        if isShow {
            guard let r: TVR = await TMDB.get("/tv/\(id)", ["append_to_response": "content_ratings"]) else { return nil }
            genres = r.genres?.map(\.id) ?? []
            certs = (r.content_ratings?.results ?? []).compactMap { c in
                guard let l = c.rating?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
                return (c.iso_3166_1, l)
            }
        } else {
            guard let r: MovieR = await TMDB.get("/movie/\(id)", ["append_to_response": "release_dates"]) else { return nil }
            genres = r.genres?.map(\.id) ?? []
            for c in r.release_dates?.results ?? [] {
                // bioscoop/digitaal eerst; de eerste niet-lege classificatie per land
                let ds = (c.release_dates ?? []).sorted { ($0.type ?? 9) < ($1.type ?? 9) }
                if let l = ds.compactMap({ $0.certification?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                    certs.append((c.iso_3166_1, l))
                }
            }
        }
        var info = AgeInfo(age: nil, label: nil, country: nil, genres: genres, found: true, checked: Date())
        for country in countries {
            if let c = certs.first(where: { $0.country == country }), let a = age(c.label, country: country) {
                info.age = a; info.label = c.label; info.country = country
                return info
            }
        }
        // andere landen: de strengste bekende classificatie
        let other = certs.compactMap { c in age(c.label, country: c.country).map { (c, $0) } }.max { $0.1 < $1.1 }
        if let o = other { info.age = o.1; info.label = o.0.label; info.country = o.0.country }
        return info
    }

    /// Classificatie → minimumleeftijd, per land waar dat nodig is.
    static func age(_ label: String, country: String) -> Int? {
        let l = label.uppercased().trimmingCharacters(in: .whitespaces)
        switch country {
        case "NL", "BE":
            if l == "AL" || l == "KT" || l == "ALL" || l == "KT/EA" { return 0 }
            if l == "MG6" { return 6 }
        case "BR": if l == "L" { return 0 }
        case "FR": if l == "U" || l == "TP" || l == "TOUS PUBLICS" { return 0 }
        default: break
        }
        return ParentalControl.minimumAge(l)
    }
}
