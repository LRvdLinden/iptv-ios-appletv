import Foundation

/// Build 154: "gezien" over alle servers (docs/ACCOUNT.md, "Build 154: gezien over alle servers en betrouwbare
/// Trakt-sync"). Naast de id-sleutels (`xv123`, `ep:<serie>|s-e`) staan inhoudssleutels (`w:m:`, `w:e:`, `w:s:`)
/// in dezelfde set `profile.<id>.watched`; de bestaande account-sync neemt ze mee (ook in `removed.watched`).
/// De pure regels staan in Build154.swift (`WatchKeys`, ook in de zelftest); hier het toepassen in de app:
/// lezen (posters, rijen, detailpagina, afleveringen, Verder kijken, Volgende aflevering, zoeken, filters),
/// schrijven, uitvinken, serie gezien en de eenmalige migratie.
@MainActor
enum Watched154 {
    // MARK: sleutels (gecachet: posters vragen ze bij elke weergave)

    private static var movieCache: [String: [String]] = [:]
    private static var showCache: [String: [String]] = [:]

    private static func tmdb(_ id: Int?, fallbackID: String) -> String? {
        if let id, id > 0 { return String(id) }
        if let f = ContentLanguage.Facts.shared.tmdbID(fallbackID), f > 0 { return String(f) }
        return nil
    }

    static func movieKeys(_ m: Movie, imdb: String?) -> [String] {
        let t = tmdb(m.tmdbID, fallbackID: m.id)
        let ck = "\(m.title)\u{1}\(m.year ?? 0)\u{1}\(t ?? "")\u{1}\(imdb ?? m.imdbID ?? "")"
        if let hit = movieCache[ck] { return hit }
        let keys = WatchKeys.movie(title: m.title, year: m.year, tmdb: t, imdb: imdb ?? m.imdbID)
        if movieCache.count > 60_000 { movieCache.removeAll(keepingCapacity: true) }
        movieCache[ck] = keys
        return keys
    }

    static func showForms(_ s: Series, imdb: String?) -> [String] {
        let t = tmdb(s.tmdbID, fallbackID: s.id)
        let ck = "\(s.title)\u{1}\(s.year ?? 0)\u{1}\(t ?? "")\u{1}\(imdb ?? s.imdbID ?? "")"
        if let hit = showCache[ck] { return hit }
        let forms = WatchKeys.showForms(title: s.title, year: s.year, tmdb: t, imdb: imdb ?? s.imdbID)
        if showCache.count > 30_000 { showCache.removeAll(keepingCapacity: true) }
        showCache[ck] = forms
        return forms
    }

    static func showKeys(_ s: Series, imdb: String?) -> [String] { showForms(s, imdb: imdb).map { "w:s:" + $0 } }

    static func episodeKeys(_ e: Episode, series: Series?, imdb: String?) -> [String] {
        guard let s = series ?? self.series(id: e.seriesID) else { return [] }
        return WatchKeys.episode(forms: showForms(s, imdb: imdb), season: e.season, episode: e.number)
    }

    // MARK: serie bij een aflevering (uit de geladen catalogus)

    /// De catalogus van de app (gezet door `PlaylistService.publish`)
    static weak var service: PlaylistService?
    private static var seriesIndex: [String: Series] = [:]
    private static var seriesIndexVersion = -1

    static func series(id: String) -> Series? {
        guard let ps = service else { return nil }
        if seriesIndexVersion != ps.libraryVersion {
            var idx: [String: Series] = [:]
            idx.reserveCapacity(ps.library.series.count)
            for s in ps.library.series { idx[s.id] = s }
            seriesIndex = idx
            seriesIndexVersion = ps.libraryVersion
        }
        return seriesIndex[id]
    }

    // MARK: lezen

    /// Lokaal gezien volgens de set én de regel "nieuwste gebeurtenis wint" over alle kandidaatsleutels (contract
    /// Build 154): een verwijdering van bijv. alleen de titelsleutel (andere server, zonder tmdb) wint van een oudere
    /// tmdb-sleutel.
    static func locallyWatched(_ set: Set<String>, own: [String], keys: [String], profile: UUID? = nil) -> Bool {
        let cands = WatchKeys.candidates(own + keys)
        guard cands.contains(where: { set.contains($0) }) else { return false }
        let store = CloudStore.shared
        guard let pid = profile ?? store.activeProfileID ?? store.mainProfileID else { return true }
        let st = StateSync.shared.watchedStamps(profile: pid)
        guard !st.removed.isEmpty else { return true }
        return WatchKeys.latestWins(present: st.present, removed: st.removed, ownIDs: own, keys: keys, inSet: set)
    }

    static func isWatched(movie m: Movie, imdb: String?) -> Bool {
        let keys = movieKeys(m, imdb: imdb)
        return locallyWatched(CloudStore.shared.localWatched, own: [m.id], keys: keys) || TraktSync.shared.isWatched(keys: keys)
    }

    static func isWatched(_ e: Episode, series: Series?, imdb: String?) -> Bool {
        let own = [e.id, CloudStore.episodeKey(series: e.seriesID, season: e.season, episode: e.number)]
        let keys = episodeKeys(e, series: series, imdb: imdb)
        return locallyWatched(CloudStore.shared.localWatched, own: own, keys: keys) || TraktSync.shared.isWatched(keys: keys)
    }

    /// Seriekaart "gezien": `w:s:` staat erin (lokaal of op Trakt)
    static func isSeriesWatched(_ s: Series, imdb: String?) -> Bool {
        let keys = showKeys(s, imdb: imdb)
        guard !keys.isEmpty else { return false }
        return locallyWatched(CloudStore.shared.localWatched, own: [], keys: keys) || TraktSync.shared.isWatched(keys: keys)
    }

    /// "seizoen-aflevering" die als inhoudssleutel gezien zijn (lokaal en op Trakt), voor het label "N bekeken"
    static func watchedEpisodeKeys(_ s: Series, imdb: String?) -> Set<String> {
        let forms = showForms(s, imdb: imdb)
        guard !forms.isEmpty else { return [] }
        var out = CloudStore.shared.contentWatchedEpisodes(forms: forms)
        out.formUnion(TraktSync.shared.contentWatchedEpisodes(forms: forms))
        return out
    }

    // MARK: schrijven en uitvinken

    static func setMovie(_ m: Movie, imdb: String?, _ watched: Bool, profile: UUID? = nil) {
        let store = CloudStore.shared
        let keys = movieKeys(m, imdb: imdb)
        if watched {
            store.setLocalWatched(keys: [m.id] + keys, true, profile: profile)
        } else {
            // de oude id-sleutel en alle inhoudssleutels (ook een titelsleutel met jaar ±1) naar `removed`
            store.setLocalWatched(keys: Array(WatchKeys.removal(store.watchedSet(profile: profile), ownIDs: [m.id], keys: keys)),
                                  false, profile: profile)
        }
    }

    static func setEpisode(_ e: Episode, series: Series?, imdb: String?, _ watched: Bool, profile: UUID? = nil, updateSeries: Bool = true) {
        let store = CloudStore.shared
        let own = [e.id, CloudStore.episodeKey(series: e.seriesID, season: e.season, episode: e.number)]
        let keys = episodeKeys(e, series: series, imdb: imdb)
        if watched {
            store.setLocalWatched(keys: own + keys, true, profile: profile)
        } else {
            store.setLocalWatched(keys: Array(WatchKeys.removal(store.watchedSet(profile: profile), ownIDs: own, keys: keys)),
                                  false, profile: profile)
        }
        if updateSeries, let s = series ?? self.series(id: e.seriesID) { updateSeriesFlag(s, imdb: imdb, profile: profile) }
    }

    /// Afspeelbaar item (speler, Verder kijken): film of aflevering
    static func setItem(_ item: PlayableItem, _ watched: Bool, profile: UUID? = nil) {
        let store = CloudStore.shared
        let tmdb = item.tmdbID.map { String($0) }
        var own = [item.id]
        let keys: [String]
        if item.type == .episode {
            if let sid = item.seriesID, let s = item.season, let e = item.episode { own.append(CloudStore.episodeKey(series: sid, season: s, episode: e)) }
            let known = item.seriesID.flatMap { self.series(id: $0) }
            let forms = known.map { showForms($0, imdb: item.imdbID) }
                ?? WatchKeys.showForms(title: item.title, year: item.year, tmdb: tmdb, imdb: item.imdbID)
            keys = WatchKeys.episode(forms: forms, season: item.season, episode: item.episode)
        } else {
            keys = WatchKeys.movie(title: item.title, year: item.year ?? item.subtitle.flatMap { Int($0) }, tmdb: tmdb, imdb: item.imdbID)
        }
        let changed: Bool
        if watched {
            changed = store.setLocalWatched(keys: own + keys, true, profile: profile)
        } else {
            changed = store.setLocalWatched(keys: Array(WatchKeys.removal(store.watchedSet(profile: profile), ownIDs: own, keys: keys)),
                                            false, profile: profile)
        }
        if changed, item.type == .episode, let sid = item.seriesID, let s = self.series(id: sid) {
            updateSeriesFlag(s, imdb: item.imdbID, profile: profile)
        }
    }

    /// Serie helemaal gezien (alle uitgezonden afleveringen: Trakt `aired_episodes`, anders het aantal op de server)
    /// → `w:s:` erin; daarna een aflevering niet meer gezien → `w:s:` naar `removed`. Zonder geladen afleveringen niets.
    static func updateSeriesFlag(_ s: Series, imdb: String?, profile: UUID? = nil, episodes: [Episode]? = nil) {
        let forms = showForms(s, imdb: imdb)
        guard !forms.isEmpty else { return }
        guard let ps = service else { return }
        var all: [Episode] = episodes ?? s.episodes
        if all.isEmpty, let c = ps.episodeCache[s.id] { all = c }
        if all.isEmpty, let sid = s.sourceID, let c = ps.episodeCache[sid.uuidString + "|" + s.id] { all = c }
        let eps = all.filter { $0.season > 0 }
        guard !eps.isEmpty else { return }
        let store = CloudStore.shared
        let set = store.watchedSet(profile: profile)
        let watchedCount = eps.filter { e in
            let keys = WatchKeys.episode(forms: forms, season: e.season, episode: e.number)
            let own = [e.id, CloudStore.episodeKey(series: e.seriesID, season: e.season, episode: e.number)]
            return locallyWatched(set, own: own, keys: keys, profile: profile) || TraktSync.shared.isWatched(keys: keys)
        }.count
        let complete = WatchKeys.seriesComplete(watched: watchedCount, aired: TraktSync.shared.aired(forms: forms), onServer: eps.count)
        let keys = forms.map { "w:s:" + $0 }
        if complete {
            if !keys.allSatisfy(set.contains) { store.setLocalWatched(keys: keys, true, profile: profile) }
        } else if WatchKeys.matches(set, keys: keys) {
            store.setLocalWatched(keys: Array(WatchKeys.removal(set, ownIDs: [], keys: keys)), false, profile: profile)
        }
    }

    // MARK: migratie (eenmalig per profiel, server en apparaat)

    /// Nieuwe sleutel → oude id-sleutel, per profiel: StateSync geeft de nieuwe sleutel dezelfde `at` (`takeInherit`).
    private static var inherit: [UUID: [String: String]] = [:]

    static func takeInherit(_ profile: UUID) -> [String: String] {
        defer { inherit[profile] = nil }
        return inherit[profile] ?? [:]
    }

    /// Na het laden van een catalogus: oude id-sleutels die bij een item van deze server horen krijgen hun
    /// inhoudssleutels erbij (met dezelfde `at`). Wat niet te vinden is, blijft zoals het is. Niets raden.
    static func migrate(_ lib: Library, playlist: UUID?) {
        let store = CloudStore.shared
        guard let playlist, let profile = store.activeProfileID ?? store.mainProfileID,
              !lib.movies.isEmpty || !lib.series.isEmpty else { return }
        let flag = "watched154.migrated.\(profile.uuidString).\(playlist.uuidString)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let stored = store.localWatched
        guard stored.contains(where: { !WatchKeys.isContentKey($0) }) else { return }
        var resolve: [String: [String]] = [:]
        for m in lib.movies where stored.contains(m.id) { resolve[m.id] = movieKeys(m, imdb: m.imdbID) }
        // "ep:<serie>|s-e" en (oudere) aflevering-id's van al geladen afleveringen
        var epBySeries: [String: [(key: String, season: Int, episode: Int)]] = [:]
        for k in stored where k.hasPrefix("ep:") {
            guard let bar = k.lastIndex(of: "|") else { continue }
            let sid = String(k[k.index(k.startIndex, offsetBy: 3)..<bar])
            let se = k[k.index(after: bar)...].split(separator: "-")
            guard se.count == 2, let s = Int(se[0]), let e = Int(se[1]) else { continue }
            epBySeries[sid, default: []].append((k, s, e))
        }
        for s in lib.series {
            let list = epBySeries[s.id] ?? []
            let eps = s.episodes.filter { stored.contains($0.id) }
            guard !list.isEmpty || !eps.isEmpty else { continue }
            let forms = showForms(s, imdb: s.imdbID)
            for x in list { resolve[x.key] = WatchKeys.episode(forms: forms, season: x.season, episode: x.episode) }
            for e in eps { resolve[e.id] = WatchKeys.episode(forms: forms, season: e.season, episode: e.number) }
        }
        let plan = WatchKeys.migration(stored) { resolve[$0] }
        guard !plan.isEmpty else { return }
        inherit[profile, default: [:]].merge(plan) { a, _ in a }
        store.setLocalWatched(keys: Array(plan.keys), true)
    }
}
