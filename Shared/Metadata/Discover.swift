import Foundation

// MARK: - Home: "Binnenkort op Bingr" en "Nieuw op Bingr" (TMDB) ------------------------------------
//
// Twee rijen op Home met titels uit TMDB: wat binnenkort uitkomt (films in de bioscoop/regio, nieuwe series) en wat
// net nieuw is op streamingdiensten in de regio (TMDB watch providers, gegevens van JustWatch). Nooit namen of logo's
// van streamingdiensten: we vragen alleen "flatrate" op, zonder de aanbieders zelf te tonen.
// Staat een titel in de eigen bibliotheek (TMDB-id van de bron, anders titel + jaar), dan opent die; anders een
// detailpagina met Mijn lijst. Build 112: "Nieuw op Bingr" toont alleen titels uit de eigen bibliotheek (meteen
// afspeelbaar; geen match = weg, niets = geen rij). De bronvermelding (TMDB, JustWatch) staat niet meer onder de rijen
// maar één keer in Instellingen → Over. De resultaten worden 12 uur bewaard; netwerk en koppelen op de achtergrond.
// Zelfde sleutels en regels op Android, Samsung TV en de webspeler.

enum DiscoverKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Build 152: `cinema` (sleutel "nowplaying", zoals de webspeler) = "Nu in de bioscoop" (TMDB `/movie/now_playing`; IMDb heeft geen openbare API)
    case upcoming, streaming
    case cinema = "nowplaying"

    /// Sleutel in de Home-indeling (HomeLayout), gelijk op alle platforms
    var homeKey: String { rawValue }
    /// Getoonde naam (build 112: "Binnenkort op Bingr" / "Nieuw op Bingr"); de sleutels blijven upcoming/streaming
    var title: String {
        switch self {
        case .upcoming: return L("Coming soon to Bingr")
        case .streaming: return L("New on Bingr")
        case .cinema: return L("In cinemas now")
        }
    }
    /// Build 112: "Nieuw op Bingr" alleen met titels uit de eigen bibliotheek (meteen afspeelbaar)
    var onlyLibrary: Bool { self == .streaming }
    /// Build 112: bronvermelding van TMDB en JustWatch, één keer in Instellingen → Over (niet meer onder de rijen)
    static var attribution: String {
        L("Movie and series data: TMDB. This app uses the TMDB API but is not endorsed or certified by TMDB. Availability data: JustWatch.")
    }
}

/// Eén titel uit TMDB (niet per se in je bibliotheek).
struct DiscoverItem: Codable, Hashable, Identifiable, Sendable {
    var tmdbID: Int
    var isShow: Bool
    var title: String
    var originalTitle: String?
    /// yyyy-MM-dd (release in de regio of eerste uitzending)
    var date: String?
    var posterPath: String?
    var backdropPath: String?
    var overview: String?
    var kind: DiscoverKind

    /// Id van de detailpagina en in Mijn lijst: "tmdb-movie-123" / "tmdb-tv-123" (zelfde op alle platforms)
    var id: String { Self.externalID(tmdbID, isShow: isShow) }
    var year: Int? { date.flatMap { Int($0.prefix(4)) } }
    var poster: URL? { TMDB.img(posterPath, "w342") }

    static let idPrefix = "tmdb-"
    static func externalID(_ id: Int, isShow: Bool) -> String { "\(idPrefix)\(isShow ? "tv" : "movie")-\(id)" }
    /// Titel die alleen uit TMDB komt (niet uit een afspeellijst)?
    static func isExternal(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
    static func parse(_ id: String) -> (tmdbID: Int, isShow: Bool)? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let parts = id.dropFirst(idPrefix.count).split(separator: "-")
        guard parts.count == 2, parts[0] == "tv" || parts[0] == "movie", let n = Int(parts[1]), n > 0 else { return nil }
        return (n, parts[0] == "tv")
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func day(_ d: Date) -> String { dayFormat.string(from: d) }
    var releaseDate: Date? { date.flatMap { Self.dayFormat.date(from: String($0.prefix(10))) } }

    /// Korte datum op de poster ("17 okt", "Oct 17"; in de app-taal), alleen bij Binnenkort op Bingr. Build 112: als
    /// rood label linksboven (PosterLabel, zoals SERIE/FILM), zonder punt achter de afgekorte maand.
    var dateLabel: String? {
        guard kind == .upcoming, let d = releaseDate else { return nil }
        var s = d.formatted(.dateTime.day().month(.abbreviated).locale(Localizer.shared.locale))
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Detailpagina voor een titel die niet in je bibliotheek staat (zoals de aanbevelingen in DetailView)
    var target: DetailTarget {
        isShow
            ? .series(Series(id: id, title: title, year: year, poster: poster, group: "", plot: overview, tmdbID: tmdbID))
            : .movie(Movie(id: id, title: title, year: year, poster: poster, group: "", plot: overview, tmdbID: tmdbID))
    }
    var external: ExternalTitle {
        ExternalTitle(titles: orderedUnique([title, originalTitle ?? ""].filter { !$0.isEmpty }), year: year)
    }
}

/// Eén kaart in een TMDB-rij: de titel en, als hij in je bibliotheek staat, die titel.
struct DiscoverEntry: Identifiable, Hashable {
    let item: DiscoverItem
    let match: DetailTarget?
    var id: String { match?.id ?? item.id }
    var target: DetailTarget { match ?? item.target }
}

/// TMDB-titels die op Home stonden (of via Mijn lijst opgezocht zijn), zodat Mijn lijst ze kan tonen. Alleen op dit
/// apparaat (geen sync), maximaal 400, de oudste vallen eraf.
final class DiscoverKnown: @unchecked Sendable {
    static let shared = DiscoverKnown()
    private struct Saved: Codable { var item: DiscoverItem; var seen: Date }
    private let lock = NSLock()
    private var items: [String: Saved]?
    private let key = "discover.known"

    private func loaded() -> [String: Saved] {
        if let items { return items }
        let d = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
        items = d
        return d
    }

    func item(_ id: String) -> DiscoverItem? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[id]?.item
    }

    func contains(_ id: String) -> Bool { item(id) != nil }

    func remember(_ list: [DiscoverItem]) {
        guard !list.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loaded()
        let now = Date()
        for i in list { all[i.id] = Saved(item: i, seen: now) }
        if all.count > 400 {
            let keep = all.sorted { $0.value.seen > $1.value.seen }.prefix(400)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        items = all
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Sleutel uit Mijn lijst ("<bron>|tmdb-movie-123") → de TMDB-titel, als die bekend is. Build 141: ongeacht de
    /// server-id (een TMDB-titel hoort bij geen server; een sleutel van een andere server bleef anders onzichtbaar).
    func item(forKey k: String, playlist: UUID) -> DiscoverItem? {
        guard let bar = k.firstIndex(of: "|") else { return nil }
        let id = String(k[k.index(after: bar)...])
        guard DiscoverItem.isExternal(id) else { return nil }
        return item(id)
    }
    func movie(forKey k: String, playlist: UUID) -> Movie? {
        guard let i = item(forKey: k, playlist: playlist), !i.isShow, case .movie(let m) = i.target else { return nil }
        return m
    }
    func series(forKey k: String, playlist: UUID) -> Series? {
        guard let i = item(forKey: k, playlist: playlist), i.isShow, case .series(let s) = i.target else { return nil }
        return s
    }
}

/// Haalt de TMDB-rijen op (12 uur bewaard per soort, taal, regio en kinderprofiel) en koppelt ze aan je bibliotheek.
actor DiscoverStore {
    static let shared = DiscoverStore()
    static let maxAge: TimeInterval = 12 * 3600
    private struct Saved: Codable { var date: Date; var items: [DiscoverItem] }
    private var inFlight: [String: Task<[DiscoverItem], Never>] = [:]

    /// Regio voor TMDB: die van de app-taal (nl → NL, de → DE, …); bij Engels of een andere taal de regio van het
    /// apparaat, anders NL. Zelfde regel op alle platforms.
    nonisolated static var region: String {
        let byLanguage = ["nl": "NL", "de": "DE", "fr": "FR", "es": "ES", "it": "IT", "pt": "PT", "pl": "PL", "tr": "TR"]
        if let r = byLanguage[Localizer.shared.language] { return r }
        if let r = Locale.current.region?.identifier, r.count == 2, r.allSatisfy({ $0.isASCII && $0.isUppercase }) { return r }
        return "NL"
    }

    private nonisolated static func key(_ kind: DiscoverKind, kids: Bool) -> String {
        "discover.\(kind.rawValue).\(kids ? "kids." : "")\(Localizer.shared.language).\(region)"
    }
    private nonisolated static func saved(_ kind: DiscoverKind, kids: Bool) -> Saved? {
        guard let d = UserDefaults.standard.data(forKey: key(kind, kids: kids)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }

    /// Direct uit de cache (ook als die verlopen is), zonder netwerk; Binnenkort zonder wat intussen uit is.
    nonisolated static func cached(_ kind: DiscoverKind, kids: Bool) -> [DiscoverItem] {
        let s = saved(kind, kids: kids)
        // build 152: wat er in de bioscoop draait, verandert per week: een oude lijst (geen netwerk) niet meer tonen
        if kind == .cinema, let s, Date().timeIntervalSince(s.date) > NowPlaying.maxStale { return [] }
        let items = s?.items ?? []
        guard kind == .upcoming else { return items }
        let today = DiscoverItem.day(Date())
        return items.filter { ($0.date ?? "") > today }
    }

    func get(_ kind: DiscoverKind, kids: Bool) async -> [DiscoverItem] {
        if let s = Self.saved(kind, kids: kids), Date().timeIntervalSince(s.date) < Self.maxAge, !s.items.isEmpty {
            return Self.cached(kind, kids: kids)
        }
        let k = Self.key(kind, kids: kids)
        if let t = inFlight[k] { return await t.value }
        let t = Task<[DiscoverItem], Never> { await Self.fetch(kind, kids: kids) }
        inFlight[k] = t
        let items = await t.value
        inFlight[k] = nil
        guard !items.isEmpty else { return Self.cached(kind, kids: kids) }
        if let d = try? JSONEncoder().encode(Saved(date: Date(), items: items)) { UserDefaults.standard.set(d, forKey: k) }
        DiscoverKnown.shared.remember(items)
        return items
    }

    private struct Page: Decodable {
        struct R: Decodable {
            let id: Int
            let title: String?, name: String?, original_title: String?, original_name: String?
            let release_date: String?, first_air_date: String?
            let poster_path: String?, backdrop_path: String?, overview: String?
            let adult: Bool?
            let popularity: Double?
        }
        let results: [R]?
    }

    private static func items(_ path: String, _ q: [String: String], show: Bool, kind: DiscoverKind) async -> [DiscoverItem] {
        guard let p: Page = await TMDB.get(path, q) else { return [] }
        return (p.results ?? []).compactMap { r -> DiscoverItem? in
            guard r.adult != true, let t = (show ? r.name : r.title) ?? r.title ?? r.name, !t.isEmpty,
                  let poster = r.poster_path, !poster.isEmpty else { return nil }
            let o = show ? r.original_name : r.original_title
            return DiscoverItem(tmdbID: r.id, isShow: show, title: t, originalTitle: o == t ? nil : o,
                                date: (show ? r.first_air_date : r.release_date).flatMap { $0.isEmpty ? nil : $0 },
                                posterPath: poster, backdropPath: r.backdrop_path,
                                overview: r.overview.flatMap { $0.isEmpty ? nil : $0 }, kind: kind)
        }
    }

    /// TMDB-verzoeken voor een rij (films en series, de populairste eerst). Kinderprofiel: alleen animatie/familie
    /// (films t/m PG), zoals de Top 10 voor kids.
    private static func fetch(_ kind: DiscoverKind, kids: Bool) async -> [DiscoverItem] {
        guard Secrets.isSet(Secrets.tmdbAPIKey) else { return [] }
        if kind == .cinema { return await nowPlaying(kids: kids) }
        let lang = TMDB.language, region = Self.region
        let now = Date()
        func d(_ days: Double) -> String { DiscoverItem.day(now.addingTimeInterval(days * 86400)) }
        let today = d(0)
        var mq: [String: String] = ["language": lang, "region": region, "include_adult": "false", "sort_by": "popularity.desc", "page": "1"]
        var tq: [String: String] = ["language": lang, "include_adult": "false", "sort_by": "popularity.desc", "page": "1"]
        if kids {
            mq["with_genres"] = "16|10751"; mq["certification_country"] = "US"; mq["certification.lte"] = "PG"
            tq["with_genres"] = "10762|16|10751"
        }
        let moviePath: String
        switch kind {
        case .upcoming:
            if kids {
                moviePath = "/discover/movie"
                mq["with_release_type"] = "2|3"
                mq["release_date.gte"] = d(1); mq["release_date.lte"] = d(120)
            } else {
                moviePath = "/movie/upcoming"
            }
            tq["first_air_date.gte"] = d(1); tq["first_air_date.lte"] = d(120)
        case .cinema:
            return []   // `nowPlaying`
        case .streaming:
            moviePath = "/discover/movie"
            mq["watch_region"] = region; mq["with_watch_monetization_types"] = "flatrate"
            mq["release_date.gte"] = d(-90); mq["release_date.lte"] = today
            tq["watch_region"] = region; tq["with_watch_monetization_types"] = "flatrate"
            tq["first_air_date.gte"] = d(-120); tq["first_air_date.lte"] = today
        }
        let movieQuery = mq, tvQuery = tq
        async let mv = items(moviePath, movieQuery, show: false, kind: kind)
        async let tv = items("/discover/tv", tvQuery, show: true, kind: kind)
        var movies = await mv, shows = await tv
        if kind == .upcoming {
            // /movie/upcoming geeft ook titels van de afgelopen dagen
            movies = movies.filter { ($0.date ?? "") > today }
            shows = shows.filter { ($0.date ?? "") > today }
        } else {
            movies = movies.filter { ($0.date ?? "") <= today }
            shows = shows.filter { ($0.date ?? "") <= today }
        }
        // om en om (populairste eerst), geen dubbele
        var out: [DiscoverItem] = []
        var seen = Set<String>()
        for i in 0..<max(movies.count, shows.count) {
            for x in [i < movies.count ? movies[i] : nil, i < shows.count ? shows[i] : nil].compactMap({ $0 }) where seen.insert(x.id).inserted {
                out.append(x)
            }
        }
        out = Array(out.prefix(40))
        // Binnenkort: de 40 populairste, op datum (eerst wat het eerst uitkomt)
        if kind == .upcoming { out.sort { ($0.date ?? "", $0.title) < ($1.date ?? "", $1.title) } }
        return out
    }

    /// Build 152: "Nu in de bioscoop": TMDB `/movie/now_playing` (regio NL, app-taal), twee pagina's, populairste
    /// eerst, hooguit 20 (`NowPlaying.pick`). Kinderprofiel: animatie/familie t/m PG die de laatste 60 dagen in de
    /// bioscoop uitkwam (`/discover/movie`, zoals de andere TMDB-rijen voor kids).
    private static func nowPlaying(kids: Bool) async -> [DiscoverItem] {
        let lang = TMDB.language, region = NowPlaying.region
        var pages: [Page] = []
        if kids {
            let now = Date()
            for page in ["1", "2"] {
                guard let p: Page = await TMDB.get("/discover/movie", [
                    "language": lang, "region": region, "include_adult": "false", "sort_by": "popularity.desc", "page": page,
                    "with_genres": "16|10751", "certification_country": "US", "certification.lte": "PG",
                    "with_release_type": "2|3",
                    "release_date.gte": DiscoverItem.day(now.addingTimeInterval(-60 * 86400)),
                    "release_date.lte": DiscoverItem.day(now),
                ]) else { break }
                pages.append(p)
            }
        } else {
            for page in ["1", "2"] {
                guard let p: Page = await TMDB.get("/movie/now_playing", ["language": lang, "region": region, "page": page]) else { break }
                pages.append(p)
            }
        }
        let all = pages.flatMap { $0.results ?? [] }
        var byID: [Int: Page.R] = [:]
        var rows: [NowPlaying.Row] = []
        for r in all where byID[r.id] == nil {
            guard let t = r.title ?? r.name, !t.isEmpty, let poster = r.poster_path, !poster.isEmpty else { continue }
            byID[r.id] = r
            rows.append(NowPlaying.Row(id: r.id, popularity: r.popularity ?? 0, adult: r.adult ?? false))
        }
        return NowPlaying.pick(rows).compactMap { id -> DiscoverItem? in
            guard let r = byID[id], let t = r.title ?? r.name else { return nil }
            let o = r.original_title
            return DiscoverItem(tmdbID: r.id, isShow: false, title: t, originalTitle: o == t ? nil : o,
                                date: r.release_date.flatMap { $0.isEmpty ? nil : $0 }, posterPath: r.poster_path,
                                backdropPath: r.backdrop_path, overview: r.overview.flatMap { $0.isEmpty ? nil : $0 }, kind: .cinema)
        }
    }

    /// Koppelen aan je bibliotheek (op de achtergrond): eerst het TMDB-id van de bron, dan titel + jaar.
    /// `onlyLibrary`: profielen met een leeftijdsgrens zien alleen wat in hun (gefilterde) bibliotheek staat,
    /// zoals de aanbevelingen op de detailpagina.
    nonisolated static func match(_ items: [DiscoverItem], matcher: TitleMatcher, index: HomeIndex,
                                  onlyLibrary: Bool, limit: Int = 30) async -> [DiscoverEntry] {
        await Task.detached(priority: .utility) { () -> [DiscoverEntry] in
            var out: [DiscoverEntry] = []
            var seen = Set<String>()
            for i in items {
                var m: DetailTarget?
                if i.isShow {
                    if let s = index.seriesByTMDB[i.tmdbID] ?? matcher.series(i.external) { m = .series(s) }
                } else {
                    if let x = index.movieByTMDB[i.tmdbID] ?? matcher.movie(i.external) { m = .movie(x) }
                }
                if onlyLibrary && m == nil { continue }
                let e = DiscoverEntry(item: i, match: m)
                if seen.insert(e.id).inserted { out.append(e) }
                if out.count >= limit { break }
            }
            return out
        }.value
    }

    /// TMDB-titels uit Mijn lijst die dit apparaat nog niet kent (bijv. op een ander apparaat toegevoegd) opzoeken.
    /// Geeft true als er iets nieuws bekend is.
    func resolve(_ ids: [String]) async -> Bool {
        struct Full: Decodable {
            let id: Int
            let title: String?, name: String?, original_title: String?, original_name: String?
            let release_date: String?, first_air_date: String?
            let poster_path: String?, backdrop_path: String?, overview: String?
        }
        var found: [DiscoverItem] = []
        for id in orderedUnique(ids).prefix(20) where !DiscoverKnown.shared.contains(id) {
            guard let p = DiscoverItem.parse(id) else { continue }
            guard let f: Full = await TMDB.get(p.isShow ? "/tv/\(p.tmdbID)" : "/movie/\(p.tmdbID)", ["language": TMDB.language]),
                  let t = (p.isShow ? f.name : f.title) ?? f.title ?? f.name else { continue }
            let o = p.isShow ? f.original_name : f.original_title
            found.append(DiscoverItem(tmdbID: f.id, isShow: p.isShow, title: t, originalTitle: o == t ? nil : o,
                                      date: p.isShow ? f.first_air_date : f.release_date, posterPath: f.poster_path,
                                      backdropPath: f.backdrop_path, overview: f.overview, kind: .streaming))
        }
        DiscoverKnown.shared.remember(found)
        return !found.isEmpty
    }

    /// Regel onder de beschrijving op de detailpagina van een TMDB-titel: niet in je afspeellijst en de datum (build 112:
    /// zonder bronvermelding; die staat in Instellingen → Over). nil voor titels uit je bibliotheek.
    nonisolated static func detailNote(for id: String) -> String? {
        guard DiscoverItem.isExternal(id) else { return nil }
        var note = L("Not in your playlists")
        if let d = DiscoverKnown.shared.item(id)?.releaseDate {
            note += " · " + L("Release date: %@", d.formatted(date: .long, time: .omitted))
        }
        return note
    }
}
