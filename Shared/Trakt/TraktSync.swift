import Foundation
import Combine

/// Houdt bij wat er bekeken is (2 kanten op):
/// - haalt bekeken films/afleveringen, voortgang en watchlist van Trakt → vinkjes in de app
/// - afvinken in de app of uitkijken in de player → naar Trakt (history + scrobble)
@MainActor
final class TraktSync: ObservableObject {
    static let shared = TraktSync()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var username: String?
    @Published private(set) var watchedMovies: Set<String> = []                 // imdb
    @Published private(set) var watchedEpisodes: [String: Set<String>] = [:]    // show-imdb → "s-e"
    @Published private(set) var watchlist: Set<String> = []                     // imdb
    @Published private(set) var playback: [PlaybackItem] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?
    @Published private(set) var displayName: String?
    @Published private(set) var avatar: URL?

    static var scrobbleEnabled: Bool { UserDefaults.standard.object(forKey: "trakt.scrobble") as? Bool ?? true }
    static var askRating: Bool { UserDefaults.standard.object(forKey: "trakt.askRating") as? Bool ?? true }
    /// Titel(+jaar) → IMDb-ID, zodat vinkjes direct op IPTV-titels passen zonder per titel op te zoeken.
    @Published private(set) var titleIndex = TitleIndex()

    struct TitleIndex: Codable {
        var movies: [String: String] = [:]
        var shows: [String: String] = [:]
        static func norm(_ t: String) -> String {
            t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
             .filter { $0.isLetter || $0.isNumber }
        }
        mutating func add(title: String?, year: Int?, imdb: String, show: Bool) {
            guard let title else { return }
            let n = Self.norm(title)
            if show { shows[n] = imdb; if let year { shows["\(n)|\(year)"] = imdb } }
            else { movies[n] = imdb; if let year { movies["\(n)|\(year)"] = imdb } }
        }
        func imdb(title: String, year: Int?, show: Bool) -> String? {
            let n = Self.norm(title), d = show ? shows : movies
            if let year, let i = d["\(n)|\(year)"] { return i }
            return d[n]
        }
    }

    /// IMDb-ID van een IPTV-titel: eerst uit de Trakt-index, dan uit de metadata-cache.
    func imdb(for m: Movie) -> String? {
        m.imdbID ?? titleIndex.imdb(title: m.title, year: m.year, show: false) ?? MetadataService.shared.cached(m)?.imdbID
    }
    func imdb(for s: Series) -> String? {
        s.imdbID ?? titleIndex.imdb(title: s.title, year: s.year, show: true) ?? MetadataService.shared.cached(s)?.imdbID
    }

    private let client = TraktClient.shared
    private var lastActivity: String?

    struct PlaybackItem: Identifiable, Hashable {
        var id: Int
        var progress: Double      // 0..100
        var type: String          // movie / episode
        var imdb: String?         // film of serie
        var title: String
        var season: Int?
        var episode: Int?
    }

    private init() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        isLoggedIn = await client.isLoggedIn
        username = await client.tokens?.username
        loadCache()
        if isLoggedIn { await refresh(); await loadProfile() }
    }

    // MARK: inloggen

    func startLogin() async throws -> TraktDeviceCode { try await client.startDeviceLogin() }

    func finishLogin(_ code: TraktDeviceCode) async throws {
        let t = try await client.pollForToken(code)
        isLoggedIn = true; username = t.username
        await refresh(force: true)
        await loadProfile()
    }

    func logout() async {
        await client.logout()
        isLoggedIn = false; username = nil
        watchedMovies = []; watchedEpisodes = [:]; watchlist = []; playback = []; titleIndex = TitleIndex()
        saveCache()
    }

    // MARK: ophalen

    private struct LastActivities: Decodable { let all: String? }
    private struct WatchedMovie: Decodable { struct M: Decodable { let title: String?; let year: Int?; let ids: TraktIDs }; let movie: M }
    private struct WatchedShow: Decodable {
        struct S: Decodable { let title: String?; let year: Int?; let ids: TraktIDs }
        struct Season: Decodable { struct E: Decodable { let number: Int }; let number: Int; let episodes: [E] }
        let show: S; let seasons: [Season]?
    }
    private struct Playback: Decodable {
        struct Media: Decodable { let title: String?; let ids: TraktIDs; let season: Int?; let number: Int? }
        let id: Int; let progress: Double; let type: String
        let movie: Media?; let episode: Media?; let show: Media?
    }
    private struct WatchlistItem: Decodable {
        struct Media: Decodable { let title: String?; let year: Int?; let ids: TraktIDs }
        let movie: Media?; let show: Media?
    }

    func refresh(force: Bool = false) async {
        guard isLoggedIn else { return }
        do {
            let act: LastActivities = try await client.get("/sync/last_activities")
            if !force, let a = act.all, a == lastActivity, !watchedMovies.isEmpty || !watchedEpisodes.isEmpty {
                lastRefresh = Date(); return
            }
            async let m: [WatchedMovie] = client.get("/sync/watched/movies")
            async let s: [WatchedShow] = client.get("/sync/watched/shows")
            async let p: [Playback] = client.get("/sync/playback")
            async let w: [WatchlistItem] = client.get("/sync/watchlist")

            let movies = try await m
            watchedMovies = Set(movies.compactMap { $0.movie.ids.imdb })
            var tIndex = titleIndex
            for x in movies { if let i = x.movie.ids.imdb { tIndex.add(title: x.movie.title, year: x.movie.year, imdb: i, show: false) } }
            var eps: [String: Set<String>] = [:]
            for show in try await s {
                guard let imdb = show.show.ids.imdb else { continue }
                tIndex.add(title: show.show.title, year: show.show.year, imdb: imdb, show: true)
                var set = Set<String>()
                for season in show.seasons ?? [] { for e in season.episodes { set.insert("\(season.number)-\(e.number)") } }
                eps[imdb] = set
            }
            watchedEpisodes = eps
            titleIndex = tIndex
            playback = try await p.map { x -> PlaybackItem in
                if x.type == "episode" {
                    return PlaybackItem(id: x.id, progress: x.progress, type: x.type, imdb: x.show?.ids.imdb,
                                        title: x.show?.title ?? "", season: x.episode?.season, episode: x.episode?.number)
                }
                return PlaybackItem(id: x.id, progress: x.progress, type: x.type, imdb: x.movie?.ids.imdb, title: x.movie?.title ?? "")
            }
            let wl = try await w
            watchlist = Set(wl.compactMap { $0.movie?.ids.imdb ?? $0.show?.ids.imdb })
            for x in wl {
                if let mm = x.movie, let i = mm.ids.imdb { titleIndex.add(title: mm.title, year: mm.year, imdb: i, show: false) }
                if let ss = x.show, let i = ss.ids.imdb { titleIndex.add(title: ss.title, year: ss.year, imdb: i, show: true) }
            }
            lastActivity = act.all
            lastRefresh = Date()
            lastError = nil
            saveCache()
        } catch {
            lastError = error.localizedDescription
            if case TraktError.notLoggedIn = error { isLoggedIn = false }
        }
    }

    // MARK: status in de UI

    func isWatched(movie imdb: String?) -> Bool {
        guard let imdb else { return false }; return watchedMovies.contains(imdb)
    }
    func isWatched(show imdb: String?, season: Int, episode: Int) -> Bool {
        guard let imdb else { return false }; return watchedEpisodes[imdb]?.contains("\(season)-\(episode)") ?? false
    }
    func watchedCount(show imdb: String?) -> Int { imdb.flatMap { watchedEpisodes[$0]?.count } ?? 0 }

    func playbackProgress(movie imdb: String?) -> Double? {
        guard let imdb else { return nil }
        return playback.first { $0.type == "movie" && $0.imdb == imdb }.map { $0.progress / 100 }
    }

    // MARK: schrijven

    func setWatched(_ item: PlayableItem, _ watched: Bool) async {
        guard isLoggedIn, let imdb = item.imdbID else { return }
        let body: [String: Any]
        if item.type == .episode, let s = item.season, let e = item.episode {
            body = ["shows": [["ids": ["imdb": imdb], "seasons": [["number": s, "episodes": [["number": e]]]]]]]
            var set = watchedEpisodes[imdb] ?? []
            if watched { set.insert("\(s)-\(e)") } else { set.remove("\(s)-\(e)") }
            watchedEpisodes[imdb] = set
        } else {
            body = ["movies": [["ids": ["imdb": imdb]]]]
            if watched { watchedMovies.insert(imdb) } else { watchedMovies.remove(imdb) }
        }
        saveCache()
        do { try await client.postRaw(watched ? "/sync/history" : "/sync/history/remove", body: body) }
        catch { lastError = error.localizedDescription }
    }

    /// Hele seizoen of serie in één keer afvinken.
    func setWatched(show imdb: String, episodes: [Episode], _ watched: Bool) async {
        guard isLoggedIn else { return }
        let bySeason = Dictionary(grouping: episodes, by: \.season)
        let seasons = bySeason.map { s, eps in ["number": s, "episodes": eps.map { ["number": $0.number] }] as [String: Any] }
        var set = watchedEpisodes[imdb] ?? []
        for e in episodes { if watched { set.insert("\(e.season)-\(e.number)") } else { set.remove("\(e.season)-\(e.number)") } }
        watchedEpisodes[imdb] = set
        saveCache()
        do { try await client.postRaw(watched ? "/sync/history" : "/sync/history/remove",
                                      body: ["shows": [["ids": ["imdb": imdb], "seasons": seasons]]]) }
        catch { lastError = error.localizedDescription }
    }

    func toggleWatchlist(imdb: String, isShow: Bool) async {
        guard isLoggedIn else { return }
        let add = !watchlist.contains(imdb)
        if add { watchlist.insert(imdb) } else { watchlist.remove(imdb) }
        let body: [String: Any] = [isShow ? "shows" : "movies": [["ids": ["imdb": imdb]]]]
        do { try await client.postRaw(add ? "/sync/watchlist" : "/sync/watchlist/remove", body: body) }
        catch { lastError = error.localizedDescription }
    }

    enum ScrobbleAction: String { case start, pause, stop }

    /// Scrobble: Trakt markeert automatisch als bekeken bij stop ≥ 80%.
    func scrobble(_ action: ScrobbleAction, item: PlayableItem, progress: Double) async {
        guard isLoggedIn, Self.scrobbleEnabled, let imdb = item.imdbID, item.type != .live else { return }
        var body: [String: Any] = ["progress": min(max(progress * 100, 0), 100), "app_version": "1.0.0"]
        if item.type == .episode, let s = item.season, let e = item.episode {
            body["show"] = ["ids": ["imdb": imdb]]
            body["episode"] = ["season": s, "number": e]
        } else {
            body["movie"] = ["ids": ["imdb": imdb]]
        }
        _ = try? await client.postRaw("/scrobble/\(action.rawValue)", body: body)
        if action == .stop && progress >= 0.8 {
            if item.type == .episode, let s = item.season, let e = item.episode {
                watchedEpisodes[imdb, default: []].insert("\(s)-\(e)")
            } else { watchedMovies.insert(imdb) }
            saveCache()
        }
    }

    // MARK: metadata via Trakt (IMDb-id en trailer)

    struct TraktMedia: Decodable { let title: String?; let year: Int?; let ids: TraktIDs; let trailer: String? }
    private struct SearchHit: Decodable { let type: String; let movie: TraktMedia?; let show: TraktMedia? }

    func lookup(title: String, year: Int?, isShow: Bool) async -> TraktMedia? {
        guard Secrets.isSet(Secrets.traktClientID) else { return nil }
        var q = ["query": title, "extended": "full", "limit": "5"]
        if let year { q["years"] = String(year) }
        let hits: [SearchHit]? = try? await client.get("/search/\(isShow ? "show" : "movie")", query: q, auth: false)
        if let h = hits?.first { return h.movie ?? h.show }
        if year != nil { return await lookup(title: title, year: nil, isShow: isShow) }
        return nil
    }

    func lookup(imdb: String) async -> TraktMedia? {
        let hits: [SearchHit]? = try? await client.get("/search/imdb/\(imdb)", query: ["extended": "full"], auth: false)
        return hits?.first.flatMap { $0.movie ?? $0.show }
    }

    /// Profiel (naam + avatar) voor het Trakt-scherm.
    func loadProfile() async {
        struct S: Decodable {
            struct U: Decodable {
                struct Img: Decodable { struct A: Decodable { let full: String? }; let avatar: A? }
                let username: String?; let name: String?; let images: Img?
            }
            let user: U?
        }
        guard isLoggedIn, let s: S = try? await client.get("/users/settings", query: ["extended": "full"]) else { return }
        displayName = s.user?.name.flatMap { $0.isEmpty ? nil : $0 } ?? s.user?.username
        username = s.user?.username ?? username
        avatar = s.user?.images?.avatar?.full.flatMap(URL.init(string:))
    }

    /// Waardering 1–10 naar Trakt sturen.
    func rate(_ item: PlayableItem, _ rating: Int) async {
        guard isLoggedIn, let imdb = item.imdbID else { return }
        let body: [String: Any]
        if item.type == .episode, let s = item.season, let e = item.episode {
            body = ["shows": [["ids": ["imdb": imdb], "seasons": [["number": s, "episodes": [["number": e, "rating": rating]]]]]]]
        } else {
            body = ["movies": [["ids": ["imdb": imdb], "rating": rating]]]
        }
        _ = try? await client.postRaw("/sync/ratings", body: body)
    }

    /// Verwijder een half-gekeken item uit Trakt's "verder kijken".
    func removePlayback(_ id: Int) async {
        playback.removeAll { $0.id == id }
        try? await client.delete("/sync/playback/\(id)")
    }

    /// Titels die lijken op een film/serie (werkt ook zonder inloggen).
    func related(imdb: String, shows: Bool) async -> [TraktMedia] {
        guard Secrets.isSet(Secrets.traktClientID) else { return [] }
        let r: [TraktMedia]? = try? await client.get("/\(shows ? "shows" : "movies")/\(imdb)/related",
                                                      query: ["limit": "20"], auth: false)
        return r ?? []
    }

    /// Persoonlijke aanbevelingen van Trakt (alleen ingelogd).
    func recommendations(shows: Bool) async -> [TraktMedia] {
        guard isLoggedIn else { return [] }
        let r: [TraktMedia]? = try? await client.get(shows ? "/recommendations/shows" : "/recommendations/movies",
                                                      query: ["limit": "50", "ignore_collected": "false"])
        return r ?? []
    }

    struct TrendingEntry: Decodable { let movie: TraktMedia?; let show: TraktMedia? }
    func trending(shows: Bool) async -> [TraktMedia] {
        let r: [TrendingEntry]? = try? await client.get(shows ? "/shows/trending" : "/movies/trending",
                                                         query: ["limit": "40"], auth: false)
        return r?.compactMap { $0.movie ?? $0.show } ?? []
    }

    // MARK: cache (zodat vinkjes direct zichtbaar zijn bij opstarten)

    private struct Cache: Codable { var m: Set<String>; var e: [String: Set<String>]; var w: Set<String>; var a: String?; var t: TitleIndex? }
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("trakt-cache.json")
    }
    private func saveCache() {
        let c = Cache(m: watchedMovies, e: watchedEpisodes, w: watchlist, a: lastActivity, t: titleIndex)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL) }
    }
    private func loadCache() {
        guard isLoggedIn, let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        watchedMovies = c.m; watchedEpisodes = c.e; watchlist = c.w; lastActivity = c.a; titleIndex = c.t ?? TitleIndex()
    }
}
