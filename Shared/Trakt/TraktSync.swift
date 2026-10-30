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
    /// Build 154: Trakt-gezien als inhoudssleutels (`w:m:`, `w:e:`, `w:s:`; docs/ACCOUNT.md "Build 154"), alleen in het
    /// geheugen en de cache, nooit in het account. Ook items zonder IMDb-id tellen mee.
    @Published private(set) var watchedKeys: Set<String> = [] { didSet { keyEpisodeIndex = nil } }
    private var keyEpisodeIndex: [String: Set<String>]?
    /// "seizoen-aflevering" die op Trakt gezien zijn, per show-vorm (inhoudssleutels)
    func contentWatchedEpisodes(forms: [String]) -> Set<String> {
        guard isLoggedIn, profileAllowed, !watchedKeys.isEmpty else { return [] }
        if keyEpisodeIndex == nil { keyEpisodeIndex = CloudStore.episodeIndex(watchedKeys) }
        var out = Set<String>()
        for f in forms { if let x = keyEpisodeIndex?[f] { out.formUnion(x) } }
        return out
    }
    /// Build 154: show-vorm (`tmdb:…`, `imdb:…`, `t:…|jaar`) → uitgezonden afleveringen (Trakt `aired_episodes`)
    private(set) var airedByShow: [String: Int] = [:]
    /// Build 154: blijvende wachtrij voor gezien en niet-gezien (`/sync/history` en `/sync/history/remove`)
    private var queue = TraktQueue.load(TraktSync.queueURL)
    nonisolated static var queueURL: URL { AppDirs.support.appendingPathComponent("trakt-queue.json") }
    private var flushing = false
    private var periodic: Timer?
    /// Items die nu afspelen (scrobble start → stop/pauze), voor het periodiek ophalen
    private var playingIDs: Set<String> = []
    /// Al vanuit de speler als gezien doorgegeven (de speler bewaart elke paar seconden)
    private var markedFromPlayer: Set<String> = []
    /// Diagnose: wachtrij en wat Trakt niet kende
    var queueCount: Int { queue.entries.count }
    var notFoundItems: [String] { queue.notFound }
    @Published private(set) var playback: [PlaybackItem] = []
    @Published private(set) var lastRefresh: Date?
    /// Bezig met synchroniseren (draaiende pijltjes in Mijn Bingr)
    @Published private(set) var isSyncing = false
    /// Kort zichtbaar na een geslaagde sync ("Bijgewerkt ✓")
    @Published private(set) var justSynced = false
    /// Laatste melding over doorgeven aan Trakt ("Gezien op Trakt: …")
    @Published private(set) var lastScrobble: String?
    @Published private(set) var lastScrobbleDate: Date?
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
        /// TMDB-id → IMDb-id (build 75): veel IPTV-servers geven het TMDB-id mee, dat past beter dan de titel
        var tmdbMovies: [Int: String] = [:]
        var tmdbShows: [Int: String] = [:]
        /// IMDb-id → jaar, om bij een titel zonder jaar-treffer geen remake/andere serie met dezelfde naam af te vinken
        var years: [String: Int] = [:]

        init() {}
        private enum K: String, CodingKey { case movies, shows, tmdbMovies, tmdbShows, years }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            movies = (try? c.decodeIfPresent([String: String].self, forKey: .movies)) ?? [:]
            shows = (try? c.decodeIfPresent([String: String].self, forKey: .shows)) ?? [:]
            tmdbMovies = (try? c.decodeIfPresent([Int: String].self, forKey: .tmdbMovies)) ?? [:]
            tmdbShows = (try? c.decodeIfPresent([Int: String].self, forKey: .tmdbShows)) ?? [:]
            years = (try? c.decodeIfPresent([String: Int].self, forKey: .years)) ?? [:]
        }

        static func norm(_ t: String) -> String {
            t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).nativeUTF8
             .filter { $0.isLetter || $0.isNumber }
        }
        mutating func add(title: String?, year: Int?, imdb: String, show: Bool, tmdb: Int? = nil) {
            if let tmdb, tmdb > 0 { if show { tmdbShows[tmdb] = imdb } else { tmdbMovies[tmdb] = imdb } }
            if let year { years[imdb] = year }
            guard let title else { return }
            let n = Self.norm(title)
            guard !n.isEmpty else { return }
            if show { shows[n] = imdb; if let year { shows["\(n)|\(year)"] = imdb } }
            else { movies[n] = imdb; if let year { movies["\(n)|\(year)"] = imdb } }
        }
        func imdb(tmdb: Int?, show: Bool) -> String? {
            guard let tmdb, tmdb > 0 else { return nil }
            return show ? tmdbShows[tmdb] : tmdbMovies[tmdb]
        }
        func imdb(title: String, year: Int?, show: Bool) -> String? {
            let n = Self.norm(title), d = show ? shows : movies
            guard !n.isEmpty else { return nil }
            guard let year else { return d[n] }
            // jaar klopt (of scheelt één jaar: release in het ene land, première in het andere)
            if let i = d["\(n)|\(year)"] ?? d["\(n)|\(year - 1)"] ?? d["\(n)|\(year + 1)"] { return i }
            // alleen op titel als het jaar van die treffer onbekend is of past: "The Office" (2001) ≠ "The Office" (2005)
            guard let i = d[n] else { return nil }
            if let y = years[i], abs(y - year) > 1 { return nil }
            return i
        }
    }

    /// IMDb-ID van een IPTV-titel: eerst uit de Trakt-index, dan uit de metadata-cache.
    /// Ook de schone titel proberen ("NL | Reacher (2022) 4K" → "Reacher", 2022), anders vinden we je Trakt-vinkjes niet.
    /// Volgorde (build 75): IMDb-id van de bron → TMDB-id (van de bron of uit de details) → titel+jaar uit je Trakt-geschiedenis
    /// (een titel met een ander jaar telt niet) → IMDb-id uit de metadata (OMDb/TMDB).
    func imdb(for m: Movie) -> String? {
        m.imdbID ?? titleIndex.imdb(tmdb: m.tmdbID ?? knownTMDb(m.id), show: false)
            ?? indexed(m.title, m.year, show: false) ?? MetadataService.shared.cached(m)?.imdbID
    }
    func imdb(for s: Series) -> String? {
        s.imdbID ?? titleIndex.imdb(tmdb: s.tmdbID ?? knownTMDb(s.id), show: true)
            ?? indexed(s.title, s.year, show: true) ?? MetadataService.shared.cached(s)?.imdbID
    }
    /// TMDB-id dat Bingr eerder bij de details van deze titel vond (ContentLanguage.Facts, build 59)
    private func knownTMDb(_ id: String) -> Int? {
        titleIndex.tmdbMovies.isEmpty && titleIndex.tmdbShows.isEmpty ? nil : ContentLanguage.Facts.shared.tmdbID(id)
    }
    private func indexed(_ raw: String, _ year: Int?, show: Bool) -> String? {
        // niets in de index (niet ingelogd / subprofiel)? dan ook niet elke titel opschonen — scheelt veel rekenwerk bij scrollen
        guard !(show ? titleIndex.shows.isEmpty : titleIndex.movies.isEmpty) else { return nil }
        let c = cleaned(raw)
        let y = year ?? c.year
        if let i = titleIndex.imdb(title: raw, year: y, show: show) { return i }
        return titleIndex.imdb(title: c.title, year: y, show: show)
    }
    private var cleanCache: [String: (title: String, year: Int?)] = [:]
    private func cleaned(_ raw: String) -> (title: String, year: Int?) {
        if let c = cleanCache[raw] { return c }
        let p = TitleCleaner.parse(raw)
        let c = (title: p.title, year: p.year)
        if cleanCache.count > 20_000 { cleanCache.removeAll() }
        cleanCache[raw] = c
        return c
    }

    /// IMDb-ID opzoeken bij Trakt als de titel er nog geen heeft (zodat kijken toch als "gezien" wordt doorgegeven).
    private func resolveIMDb(_ item: PlayableItem) async -> String? {
        if let i = item.imdbID { return i }
        let show = item.type == .episode
        // build 154: met een TMDB-id (van de server) is zoeken op titel niet nodig: Trakt krijgt `ids.tmdb`
        if let t = item.tmdbID, t > 0 { return titleIndex.imdb(tmdb: t, show: show) }
        let c = cleaned(item.title)
        if let i = titleIndex.imdb(title: item.title, year: nil, show: show) ?? titleIndex.imdb(title: c.title, year: c.year, show: show) {
            return i
        }
        let year = item.year ?? (show ? c.year : (c.year ?? item.subtitle.flatMap { Int($0) }))
        guard let hit = await lookup(title: c.title, year: year, isShow: show), let i = hit.ids.imdb else { return nil }
        titleIndex.add(title: item.title, year: nil, imdb: i, show: show)
        titleIndex.add(title: hit.title, year: hit.year, imdb: i, show: show)
        saveCache()
        return i
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
        startPeriodic()
    }

    // MARK: build 154: periodiek ophalen, terugkeer naar de voorgrond, wachtrij

    /// Elke 15 minuten: de wachtrij opnieuw proberen, en ophalen zolang er niets afspeelt.
    private func startPeriodic() {
        periodic?.invalidate()
        periodic = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in await TraktSync.shared.periodicTick() }
        }
    }

    func periodicTick() async {
        guard isLoggedIn, profileAllowed else { return }
        await flushQueue()
        if playingIDs.isEmpty { await refresh() }
    }

    /// Terug naar de voorgrond: wachtrij opnieuw proberen en ophalen (altijd eerst `/sync/last_activities`).
    func appBecameActive() async {
        guard isLoggedIn, profileAllowed else { return }
        await flushQueue()
        await refresh()
    }

    /// Na een geslaagde tokenverversing (TraktClient): de wachtrij opnieuw proberen.
    func tokenRefreshed() {
        Task { await self.flushQueue() }
    }

    /// Inhoudssleutels van een afspeelbaar item (film of aflevering)
    static func contentKeys(_ item: PlayableItem, imdb: String?) -> [String] {
        let tmdb = item.tmdbID.map { String($0) }
        if item.type == .episode {
            return WatchKeys.episode(show: item.title, year: item.year, tmdb: tmdb, imdb: imdb, season: item.season, episode: item.episode)
        }
        return WatchKeys.movie(title: item.title, year: item.year ?? item.subtitle.flatMap { Int($0) }, tmdb: tmdb, imdb: imdb)
    }

    /// Gezien op Trakt: één van de inhoudssleutels (jaar ±1) staat in Trakt-gezien.
    func isWatched(keys: [String]) -> Bool {
        isLoggedIn && profileAllowed && WatchKeys.matches(watchedKeys, keys: keys)
    }

    /// Uitgezonden afleveringen volgens Trakt voor een van de show-vormen
    func aired(forms: [String]) -> Int? {
        for f in forms { if let a = airedByShow[f] { return a } }
        return nil
    }

    /// `ids` voor Trakt: tmdb en/of imdb, wat bekend is
    private static func ids(tmdb: Int?, imdb: String?) -> [String: Any] {
        var d: [String: Any] = [:]
        if let t = tmdb, t > 0 { d["tmdb"] = t }
        if let i = WatchKeys.cleanIMDb(imdb) { d["imdb"] = i }
        return d
    }

    /// In de wachtrij zetten (blijft bewaard tot Trakt het heeft).
    private func enqueue(_ item: PlayableItem, imdb: String?, watched: Bool, at: Date = Date()) {
        let isEp = item.type == .episode && item.season != nil && item.episode != nil
        let c = TitleCleaner.parse(item.title)
        let year = item.year ?? c.year ?? (isEp ? nil : item.subtitle.flatMap { Int($0) })
        let e = TraktQueueEntry(op: watched ? .add : .remove, kind: isEp ? .episode : .movie, tmdb: item.tmdbID, imdb: imdb,
                                title: c.title, year: year, season: isEp ? item.season : nil, episode: isEp ? item.episode : nil,
                                watchedAt: at.timeIntervalSince1970)
        queue.enqueue(e)
        queue.save(Self.queueURL)
    }

    /// Vinkjes meteen in de app (de wachtrij zorgt dat Trakt het krijgt)
    private func applyLocally(_ item: PlayableItem, imdb: String?, watched: Bool) {
        let keys = Self.contentKeys(item, imdb: imdb)
        if watched { watchedKeys.formUnion(keys) } else { watchedKeys.subtract(WatchKeys.removal(watchedKeys, ownIDs: [], keys: keys)) }
        guard let imdb else { return }
        if item.type == .episode, let s = item.season, let e = item.episode {
            if watched { watchedEpisodes[imdb, default: []].insert("\(s)-\(e)") } else { watchedEpisodes[imdb]?.remove("\(s)-\(e)") }
        } else if item.type != .episode {
            if watched { watchedMovies.insert(imdb) } else { watchedMovies.remove(imdb) }
        }
    }

    /// De speler markeerde iets lokaal als gezien (zelfde grens als lokaal): ook naar Trakt, via de wachtrij.
    func markWatchedFromPlayer(_ item: PlayableItem) {
        guard isLoggedIn, profileAllowed, Self.scrobbleEnabled, item.type != .live, EntitlementsService.shared.allows(.trakt),
              !markedFromPlayer.contains(item.id) else { return }
        markedFromPlayer.insert(item.id)
        Task {
            let imdb = await self.resolveIMDb(item)
            self.enqueue(item, imdb: imdb, watched: true)
            self.applyLocally(item, imdb: imdb, watched: true)
            self.saveCache()
            await self.flushQueue()
        }
    }

    /// De wachtrij naar Trakt: bij de start, bij terugkeer naar de voorgrond, na een verversing en elke 15 minuten,
    /// met backoff (en `Retry-After` bij een 429). Wat Trakt niet kent (`not_found`) komt in de diagnose.
    func flushQueue() async {
        guard isLoggedIn, profileAllowed, !flushing, !queue.entries.isEmpty, EntitlementsService.shared.allows(.trakt) else { return }
        flushing = true
        defer { flushing = false }
        let now = Date().timeIntervalSince1970
        // zonder id: eerst zoeken (alleen een treffer met de juiste titel en het juiste jaar)
        let unresolved = queue.entries.filter { !$0.hasIDs && $0.nextAt <= now }
        for e in unresolved {
            let hit = await lookup(title: e.title ?? "", year: e.year, isShow: e.kind == .episode)
            guard let idx = queue.entries.firstIndex(where: { $0.itemKey == e.itemKey && $0.watchedAt == e.watchedAt }) else { continue }
            if let h = hit, (h.ids.tmdb ?? 0) > 0 || WatchKeys.cleanIMDb(h.ids.imdb) != nil {
                var x = queue.entries.remove(at: idx)
                x.tmdb = h.ids.tmdb; x.imdb = h.ids.imdb
                queue.enqueue(x)
            } else if e.attempts < 2 {
                queue.failed([e], now: now)
            } else {
                queue.entries.remove(at: idx)
                queue.noteNotFound([e.title ?? "?"])
                lastScrobble = L("Not found on Trakt: %@", e.title ?? "")
                lastScrobbleDate = Date()
            }
        }
        for op in [TraktQueueEntry.Op.add, .remove] {
            let batch = Array(queue.due(now: now).filter { $0.op == op }.prefix(100))
            guard !batch.isEmpty else { continue }
            do {
                let d = try await client.postRaw(op == .add ? "/sync/history" : "/sync/history/remove", body: TraktQueue.body(batch))
                let resp = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                let nf = TraktQueue.notFound(in: resp, batch: batch)
                if let first = nf.first {
                    queue.noteNotFound(nf.map { $0.title ?? "?" })
                    lastScrobble = L("Not found on Trakt: %@", first.title ?? "")
                    lastScrobbleDate = Date()
                }
                queue.remove(batch)
            } catch TraktError.rateLimited(let after) {
                queue.failed(batch, now: now, retryAfter: after)
                break
            } catch {
                queue.failed(batch, now: now)
                lastError = error.localizedDescription
            }
        }
        queue.save(Self.queueURL)
    }

    /// Trakt hoort bij het hoofdaccount: andere profielen zien geen Trakt-vinkjes, -voortgang of -aanbevelingen
    /// en scrobblen niet naar het Trakt-account van het hoofdaccount.
    private var profileAllowed = true

    func applyProfile(isMain: Bool) async {
        profileAllowed = isMain
        if isMain {
            let loggedIn = await client.isLoggedIn
            let name = await client.tokens?.username
            // intussen naar een ander profiel gewisseld? dan niets van Trakt laten zien
            guard profileAllowed else { return }
            isLoggedIn = loggedIn
            username = name
            loadCache()
            if isLoggedIn { await refresh() }
        } else {
            isLoggedIn = false
            watchedMovies = []; watchedEpisodes = [:]; watchlist = []; playback = []
            watchedKeys = []; airedByShow = [:]
        }
    }

    func bootstrap() async {
        profileAllowed = CloudStore.shared.isMainActive || CloudStore.shared.profiles.count <= 1
        guard profileAllowed else { return }
        let loggedIn = await client.isLoggedIn
        let name = await client.tokens?.username
        guard profileAllowed else { return }   // tijdens het opstarten al een ander profiel gekozen
        isLoggedIn = loggedIn
        username = name
        loadCache()
        if isLoggedIn { await refresh(); await flushQueue(); await loadProfile() }
    }

    // MARK: inloggen

    func startLogin() async throws -> TraktDeviceCode { try await client.startDeviceLogin() }

    func finishLogin(_ code: TraktDeviceCode) async throws {
        let t = try await client.pollForToken(code)
        isLoggedIn = true; username = t.username
        await refresh(force: true)
        await loadProfile()
    }

    /// Trakt-koppeling uit de Bingr-account toegepast (StateSync): de UI meteen bijwerken.
    /// `tokens` nil = elders uitgelogd (lokaal wissen, zonder intrekken bij Trakt).
    func applySyncedConnection(_ tokens: TraktTokens?) async {
        await client.store(tokens)
        guard tokens != nil else {
            isLoggedIn = false; username = nil
            watchedMovies = []; watchedEpisodes = [:]; watchlist = []; playback = []; titleIndex = TitleIndex()
            watchedKeys = []; airedByShow = [:]
            displayName = nil; avatar = nil
            saveCache()
            return
        }
        let wasLoggedIn = isLoggedIn
        username = tokens?.username ?? username
        // andere profielen dan het hoofdaccount zien Trakt niet (zie applyProfile)
        guard profileAllowed else { return }
        isLoggedIn = true
        if !wasLoggedIn {
            loadCache()
            // los starten: dit kan vanuit een Trakt-verversing komen (zie StateSync.beforeTraktRefresh)
            Task { @MainActor in
                await self.refresh(force: true)
                await self.loadProfile()
            }
        }
    }

    func logout() async {
        await client.logout()
        isLoggedIn = false; username = nil
        watchedMovies = []; watchedEpisodes = [:]; watchlist = []; playback = []; titleIndex = TitleIndex()
        watchedKeys = []; airedByShow = [:]
        // bewuste uitlog: de wachtrij hoort bij dit Trakt-account
        queue = TraktQueue(); queue.save(Self.queueURL)
        saveCache()
    }

    // MARK: ophalen

    private struct LastActivities: Decodable { let all: String? }
    private struct WatchedMovie: Decodable { struct M: Decodable { let title: String?; let year: Int?; let ids: TraktIDs }; let movie: M }
    private struct WatchedShow: Decodable {
        struct S: Decodable { let title: String?; let year: Int?; let ids: TraktIDs; let aired_episodes: Int? }
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
        guard isLoggedIn else {
            if force { lastError = L("Not signed in to Trakt.") }
            return
        }
        // build 88: Trakt hoort bij Lifetime; op een Gratis-account staat synchroniseren stil
        guard EntitlementsService.shared.allows(.trakt) else { return }
        guard !isSyncing else { return }
        isSyncing = true
        let started = Date()
        defer {
            // spinner minstens even laten zien, en daarna kort "Bijgewerkt ✓"
            let wait = max(0, 0.9 - Date().timeIntervalSince(started))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.isSyncing = false
                if self.lastError == nil {
                    self.justSynced = true
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    self.justSynced = false
                }
            }
        }
        do {
            let act: LastActivities = try await client.get("/sync/last_activities")
            if !force, let a = act.all, a == lastActivity, !watchedMovies.isEmpty || !watchedEpisodes.isEmpty || !watchedKeys.isEmpty {
                lastRefresh = Date(); return
            }
            async let m: [WatchedMovie] = client.get("/sync/watched/movies")
            // build 154: extended=full voor `aired_episodes` (serie helemaal gezien)
            async let s: [WatchedShow] = client.get("/sync/watched/shows", query: ["extended": "full"])
            async let p: [Playback] = client.get("/sync/playback")
            async let w: [WatchlistItem] = client.get("/sync/watchlist")

            let movies = try await m
            let shows = try await s
            let pb = try await p
            let wl = try await w
            // intussen naar een ander profiel gewisseld of uitgelogd? dan de vinkjes van het hoofdaccount niet tonen
            guard profileAllowed, isLoggedIn else { return }
            watchedMovies = Set(movies.compactMap { $0.movie.ids.imdb })
            // build 154: inhoudssleutels (tmdb, imdb en titel + jaar), ook voor items zonder IMDb-id
            var keys = Set<String>()
            var aired: [String: Int] = [:]
            for x in movies {
                keys.formUnion(WatchKeys.movie(title: x.movie.title ?? "", year: x.movie.year,
                                               tmdb: x.movie.ids.tmdb.map { String($0) }, imdb: x.movie.ids.imdb))
            }
            for show in shows {
                let forms = WatchKeys.showForms(title: show.show.title ?? "", year: show.show.year,
                                                tmdb: show.show.ids.tmdb.map { String($0) }, imdb: show.show.ids.imdb)
                var regular = 0
                for season in show.seasons ?? [] {
                    for e in season.episodes {
                        keys.formUnion(WatchKeys.episode(forms: forms, season: season.number, episode: e.number))
                        if season.number > 0 { regular += 1 }
                    }
                }
                if let a = show.show.aired_episodes, a > 0 {
                    for f in forms { aired[f] = a }
                    if WatchKeys.seriesComplete(watched: regular, aired: a, onServer: 0) { for f in forms { keys.insert("w:s:" + f) } }
                }
            }
            watchedKeys = keys
            airedByShow = aired
            var tIndex = titleIndex
            for x in movies {
                if let i = x.movie.ids.imdb { tIndex.add(title: x.movie.title, year: x.movie.year, imdb: i, show: false, tmdb: x.movie.ids.tmdb) }
            }
            var eps: [String: Set<String>] = [:]
            for show in shows {
                guard let imdb = show.show.ids.imdb else { continue }
                tIndex.add(title: show.show.title, year: show.show.year, imdb: imdb, show: true, tmdb: show.show.ids.tmdb)
                var set = Set<String>()
                for season in show.seasons ?? [] { for e in season.episodes { set.insert("\(season.number)-\(e.number)") } }
                eps[imdb] = set
            }
            watchedEpisodes = eps
            playback = pb.map { x -> PlaybackItem in
                if x.type == "episode" {
                    return PlaybackItem(id: x.id, progress: x.progress, type: x.type, imdb: x.show?.ids.imdb,
                                        title: x.show?.title ?? "", season: x.episode?.season, episode: x.episode?.number)
                }
                return PlaybackItem(id: x.id, progress: x.progress, type: x.type, imdb: x.movie?.ids.imdb, title: x.movie?.title ?? "")
            }
            watchlist = Set(wl.compactMap { $0.movie?.ids.imdb ?? $0.show?.ids.imdb })
            for x in wl {
                if let mm = x.movie, let i = mm.ids.imdb { tIndex.add(title: mm.title, year: mm.year, imdb: i, show: false, tmdb: mm.ids.tmdb) }
                if let ss = x.show, let i = ss.ids.imdb { tIndex.add(title: ss.title, year: ss.year, imdb: i, show: true, tmdb: ss.ids.tmdb) }
            }
            titleIndex = tIndex
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
    /// Bekeken afleveringen ("seizoen-aflevering") van een serie op Trakt.
    func watchedEpisodeKeys(show imdb: String?) -> Set<String> { imdb.flatMap { watchedEpisodes[$0] } ?? [] }

    func playbackProgress(movie imdb: String?) -> Double? {
        guard let imdb else { return nil }
        return playback.first { $0.type == "movie" && $0.imdb == imdb }.map { $0.progress / 100 }
    }

    // MARK: schrijven

    func setWatched(_ item: PlayableItem, _ watched: Bool) async {
        guard isLoggedIn, profileAllowed else { return }
        // build 154: via de blijvende wachtrij (met `watched_at` en ids tmdb/imdb), niet meer los en zonder nieuwe poging
        let imdb = await resolveIMDb(item)
        enqueue(item, imdb: imdb, watched: watched)
        applyLocally(item, imdb: imdb, watched: watched)
        saveCache()
        await flushQueue()
    }

    /// Hele seizoen of serie in één keer afvinken (build 154: via de wachtrij). `show`: de serie als afspeelbaar item.
    func setWatched(show: PlayableItem, imdb: String?, episodes: [Episode], _ watched: Bool) async {
        guard isLoggedIn, profileAllowed else { return }
        for e in episodes {
            var it = show
            it.type = .episode; it.season = e.season; it.episode = e.number; it.id = e.id
            enqueue(it, imdb: imdb, watched: watched)
            applyLocally(it, imdb: imdb, watched: watched)
        }
        saveCache()
        await flushQueue()
    }

    /// Zet een titel op of van de Trakt-watchlist (spiegelt Mijn lijst van het hoofdaccount).
    func setWatchlist(imdb: String, isShow: Bool, _ on: Bool) async {
        guard isLoggedIn, watchlist.contains(imdb) != on else { return }
        await toggleWatchlist(imdb: imdb, isShow: isShow)
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
    /// Uitkomst van een scrobble (voor een melding in de speler en de status in Mijn Bingr).
    enum ScrobbleResult { case ok, notFound, failed, skipped }

    /// Build 154: `watched` = de speler vond het lokaal gezien (zelfde grens als lokaal: 85%, of meer dan 70% met minder
    /// dan 3 minuten over). Bij een stop zonder die grens gaat de voortgang onder de 80% naar Trakt, zodat Trakt niet
    /// eerder "gezien" zet dan Bingr; het gezien zelf gaat via de wachtrij (`markWatchedFromPlayer`).
    @discardableResult
    func scrobble(_ action: ScrobbleAction, item: PlayableItem, progress: Double, watched: Bool = false) async -> ScrobbleResult {
        if action == .start { playingIDs.insert(item.id) } else { playingIDs.remove(item.id) }
        guard isLoggedIn, profileAllowed, Self.scrobbleEnabled, item.type != .live, EntitlementsService.shared.allows(.trakt) else { return .skipped }
        let imdb = await resolveIMDb(item)
        let ids = Self.ids(tmdb: item.tmdbID, imdb: imdb)
        guard !ids.isEmpty else {
            lastScrobble = L("Not found on Trakt: %@", item.title)
            return .notFound
        }
        let isEpisode = item.type == .episode && item.season != nil && item.episode != nil
        var p = min(max(progress * 100, 0), 100)
        if action == .stop && !watched { p = min(p, 79) }
        var body: [String: Any] = ["progress": p, "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.3"]
        if isEpisode, let s = item.season, let e = item.episode {
            body["show"] = ["ids": ids]
            body["episode"] = ["season": s, "number": e]
        } else {
            body["movie"] = ["ids": ids]
        }
        let name = isEpisode ? "\(item.title) S\(item.season ?? 0)E\(item.episode ?? 0)" : item.title
        var result: ScrobbleResult = .ok
        do {
            try await client.postRaw("/scrobble/\(action.rawValue)", body: body)
        } catch HTTPError.status(let code, _) where code == 404 {
            // Trakt kent het item niet: niet als "gelukt" tellen
            result = .notFound
        } catch {
            result = .failed
            lastError = error.localizedDescription
        }
        if action == .stop && watched && result != .ok {
            // scrobble mislukt: de wachtrij zorgt dat het gezien toch bij Trakt komt
            markWatchedFromPlayer(item)
        }
        switch (action, result) {
        case (_, .failed): lastScrobble = L("Could not reach Trakt for %@", name)
        case (_, .notFound): lastScrobble = L("Not found on Trakt: %@", name)
        case (.stop, .ok): lastScrobble = watched ? L("Marked as watched on Trakt: %@", name) : L("Progress saved on Trakt: %@", name)
        case (.start, .ok): lastScrobble = L("Watching on Trakt: %@", name)
        default: break
        }
        lastScrobbleDate = Date()
        // na het kijken de vinkjes van Trakt ophalen (ook wat je intussen elders keek), 3 seconden na de stop
        if action == .stop {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await flushQueue()
            await refresh(force: true)
        }
        return result
    }

    // MARK: metadata via Trakt (IMDb-id en trailer)

    struct TraktMedia: Decodable { let title: String?; let year: Int?; let ids: TraktIDs; let trailer: String? }
    private struct SearchHit: Decodable { let type: String; let movie: TraktMedia?; let show: TraktMedia? }

    func lookup(title: String, year: Int?, isShow: Bool) async -> TraktMedia? {
        guard Secrets.isSet(Secrets.traktClientID) else { return nil }
        // build 154: een treffer alleen met de juiste titel (norm) en het juiste jaar (±1), niet blind de eerste
        func search(_ years: Int?) async -> TraktMedia? {
            var q = ["query": title, "extended": "full", "limit": "10"]
            if let years { q["years"] = String(years) }
            let hits: [SearchHit]? = try? await client.get("/search/\(isShow ? "show" : "movie")", query: q, auth: false)
            let media = (hits ?? []).compactMap { $0.movie ?? $0.show }
            return TraktMatch.pick(media, title: title, year: year, hitTitle: { $0.title }, hitYear: { $0.year })
        }
        if let year, let m = await search(year) { return m }
        return await search(nil)
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
                                                         query: ["limit": "100"], auth: false)
        return r?.compactMap { $0.movie ?? $0.show } ?? []
    }

    // MARK: cache (zodat vinkjes direct zichtbaar zijn bij opstarten)

    /// `v`: versie van de cache; bij een oudere versie alles opnieuw ophalen (build 75: TMDB-ids en jaren in de index)
    /// build 154: `k` = inhoudssleutels, `ae` = uitgezonden afleveringen per show-vorm
    private struct Cache: Codable {
        var m: Set<String>; var e: [String: Set<String>]; var w: Set<String>; var a: String?; var t: TitleIndex?; var v: Int?
        var k: Set<String>?; var ae: [String: Int]?
    }
    private static let cacheVersion = 3
    private var cacheURL: URL {
        AppDirs.caches.appendingPathComponent("trakt-cache.json")
    }
    private func saveCache() {
        let c = Cache(m: watchedMovies, e: watchedEpisodes, w: watchlist, a: lastActivity, t: titleIndex, v: Self.cacheVersion,
                      k: watchedKeys, ae: airedByShow)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL) }
    }
    private func loadCache() {
        guard isLoggedIn, profileAllowed, let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        watchedMovies = c.m; watchedEpisodes = c.e; watchlist = c.w; titleIndex = c.t ?? TitleIndex()
        watchedKeys = c.k ?? []; airedByShow = c.ae ?? [:]
        // oude cache (zonder TMDB-ids/jaren): de volgende verversing niet overslaan
        lastActivity = c.v == Self.cacheVersion ? c.a : nil
    }
}
