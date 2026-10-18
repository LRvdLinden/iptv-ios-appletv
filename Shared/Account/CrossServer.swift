import Foundation
import Combine

/// Build 128: één Verder kijken, Mijn lijst, favorieten, recente zenders, geschiedenis en collecties per profiel over
/// alle servers heen (docs/ACCOUNT.md → "Build 128: één lijst over alle servers").
///
/// - Items van andere servers worden opgezocht in de catalogus van hun eigen server (cache op dit apparaat, anders
///   op de achtergrond opgehaald zonder gids) en getoond als gewone tegels; openen en afspelen gaat via die server.
/// - Staat een item niet (meer) op zijn server, of is de server verwijderd, dan zoekt Bingr het rustig op de
///   achtergrond (niet tijdens afspelen, na het scrollen, met time-outs) en bij aanklikken op de andere servers. Gevonden
///   → remap (nieuwe sleutel in alle lijsten en collecties van alle profielen, met dezelfde `at`). Niet gevonden →
///   het item blijft staan; bij aanklikken een melding (`Prompt`).
/// - De meta (titel, jaar, TMDB-id, poster, aflevering, zender) en de remap-regels staan in de state-section
///   `catalogmeta` (pure logica in CatalogMeta.swift).
@MainActor
final class CrossServer: ObservableObject {
    static let shared = CrossServer()

    /// Telt op als de opgezochte items veranderen (schermen tekenen dan opnieuw)
    @Published private(set) var version = 0
    private(set) var meta = CatalogMeta()

    weak var playlists: PlaylistService?
    /// Speelt er iets af? Dan wacht het achtergrondwerk.
    var isPlaying: () -> Bool = { false }

    /// Waar een item vandaan komt (voor de knop in de melding)
    enum ListKind: Hashable {
        case continueWatching, myList, favorites, recentChannels, history
        case collection(String)
    }

    struct Found: Equatable {
        var movie: Movie?
        var series: Series?
        var channel: Channel?
    }

    struct Missing: Equatable {
        var title: String
        var kind: CatalogMeta.Kind?
        var sid: String
        var item: String
        var image: URL?
        var year: Int?
        /// De server bestaat niet meer (tombstone)
        var serverDeleted: Bool
        /// De catalogus van de server kon (nog) niet geladen worden: nog niet zeker dat het item weg is
        var unverified: Bool
    }

    /// Kan direct geopend worden, of de melding
    enum Outcome {
        case movie(Movie), series(Series), channel(Channel)
        case prompt(Prompt)
    }

    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let removeLabel: String
        let remove: () -> Void
        let searchQuery: String
    }

    private var found: [String: Found] = [:]
    private var missing: [String: Missing] = [:]
    /// voortgang van een aflevering ("<server>|<aflevering>") → de serie op die server
    private var episodeSeries: [String: Series] = [:]

    private var bag = Set<AnyCancellable>()
    private var started = false
    private var timer: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var again = false
    private var saveTask: Task<Void, Never>?
    /// Per server: handtekening van de laatste opzoekronde (cache-tijd, sleutels, filter) en de uitkomst
    private var lastSig: [UUID: String] = [:]
    private var lastResult: [UUID: ServerResult] = [:]
    /// Per server: laatste poging om een catalogus op te halen (niet vaker dan eens per 6 uur). Build 130: bewaard
    /// op het apparaat, zodat ook een herstart van de app (of een server die steeds faalt) niet vaker ophaalt.
    private var lastFetch: [UUID: Date] = {
        let raw = UserDefaults.standard.dictionary(forKey: CrossServer.lastFetchKey) as? [String: Double] ?? [:]
        var out: [UUID: Date] = [:]
        for (k, v) in raw { if let u = UUID(uuidString: k) { out[u] = Date(timeIntervalSince1970: v) } }
        return out
    }() {
        didSet {
            var raw: [String: Double] = [:]
            for (k, v) in lastFetch where Date().timeIntervalSince(v) < 7 * 24 * 3600 { raw[k.uuidString] = v.timeIntervalSince1970 }
            UserDefaults.standard.set(raw, forKey: CrossServer.lastFetchKey)
        }
    }
    nonisolated private static let lastFetchKey = "crossserver.lastFetch.v130"
    /// Build 130: niet-actieve servers met een oude cache (> 6 uur), die stil op de achtergrond ververst worden
    private var staleQueue: [UUID] = []
    private var staleTask: Task<Void, Never>?
    nonisolated static let freshFor: TimeInterval = 6 * 3600
    /// Na het matchen: niet opnieuw proberen binnen 6 uur (tenzij bij aanklikken)
    private var lastMatchTry: [String: Date] = [:]
    /// Build 129: slimme collecties over alle servers: per collectie-id de treffers op de niet-actieve servers (in de
    /// volgorde van de sources), en per server de laatste uitkomst met zijn handtekening
    private var smartFound: [String: CollectionContent] = [:]
    private var smartSig: [UUID: String] = [:]
    private var smartResult: [UUID: [String: CollectionContent]] = [:]

    private static let migratedKey = "crossserver.migrated.v128"
    nonisolated private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalogmeta.json")
    }

    private init() {
        guard !Screenshots.isActive else { return }
        if let d = try? Data(contentsOf: Self.fileURL), let j = try? JSONSerialization.jsonObject(with: d) {
            meta = CatalogMeta(json: j)
        }
    }

    // MARK: - Starten

    func start(playlists: PlaylistService, isPlaying: @escaping () -> Bool) {
        guard !started, !Screenshots.isActive else { return }
        started = true
        self.playlists = playlists
        self.isPlaying = isPlaying
        let store = CloudStore.shared
        let lists: [AnyPublisher<Void, Never>] = [
            store.$myList.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$favorites.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$recentChannels.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$progress.map { Set($0.keys) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$history.map { $0.map(\.id) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$collections.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$playlists.map { $0.map(\.id) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$activeProfileID.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$hiddenCategories.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            playlists.$libraryVersion.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(lists)
            .dropFirst(lists.count)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.schedule() }
            .store(in: &bag)
        migrateCategories()
        schedule(delay: 8)
    }

    /// Oude categoriekeuzes (per server voor het hele account) naar elk profiel (build 128, eenmalig per profiel/server).
    func migrateCategories() {
        let added = CloudStore.shared.migrateLegacyCategories()
        for (p, keys) in added { StateSync.shared.presetOld(profile: p, field: "hiddenCategories", keys: keys) }
    }

    /// Een opzoekronde inplannen (wijzigingen komen vaak vlak na elkaar)
    func schedule(delay: Double = 4) {
        guard started else { return }
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.timer = nil
            await self.run(interactive: false, only: nil)
        }
    }

    private func run(interactive: Bool, only: Set<String>?) async {
        if let running, !interactive {
            again = true
            await running.value
            return
        }
        if let running { await running.value }
        let t = Task { @MainActor in
            repeat {
                self.again = false
                await self.pass(interactive: interactive, only: only)
            } while self.again && !interactive && !Task.isCancelled
            self.running = nil
            if interactive && self.again { self.schedule(delay: 2) }
        }
        running = t
        await t.value
    }

    // MARK: - Verwijzingen

    struct Ref: Sendable {
        var key: String
        var norm: String
        var sid: String
        var item: String
        /// Welke soorten het kan zijn (Mijn lijst: film of serie; voortgang: film of aflevering)
        var kinds: Set<CatalogMeta.Kind>
        var title: String?
        var image: String?
        var season: Int?
        var episode: Int?
        var lists: Set<ListKind>
    }

    /// Alle verwijzingen van alle profielen en collecties, per genormaliseerde sleutel.
    func gatherRefs() -> [String: Ref] {
        let store = CloudStore.shared
        var out: [String: Ref] = [:]
        func add(_ key: String, _ kinds: Set<CatalogMeta.Kind>, _ list: ListKind, title: String? = nil, image: String? = nil,
                 se: (season: Int, episode: Int)? = nil) {
            guard let (sid, item) = CatalogKey.split(key), UUID(uuidString: sid) != nil, !DiscoverItem.isExternal(item) else { return }
            let n = CatalogKey.normalize(key)
            if var r = out[n] {
                r.kinds = r.kinds.intersection(kinds).isEmpty ? r.kinds.union(kinds) : r.kinds.intersection(kinds)
                if r.title == nil || r.title?.isEmpty == true { r.title = title }
                if r.image == nil { r.image = image }
                if r.season == nil, let se { r.season = se.season; r.episode = se.episode }
                r.lists.insert(list)
                out[n] = r
            } else {
                out[n] = Ref(key: key, norm: n, sid: sid.lowercased(), item: item, kinds: kinds, title: title, image: image,
                             season: se?.season, episode: se?.episode, lists: [list])
            }
        }
        for p in store.profiles {
            let d = store.profileData(p.id)
            for k in d.myList { add(k, [.movie, .series], .myList) }
            for k in d.favorites { add(k, [.channel], .favorites) }
            for k in d.recentChannels { add(k, [.channel], .recentChannels) }
            for (k, e) in d.progress {
                guard let pid = e.playlistID else { continue }
                add(pid.uuidString + "|" + k, [.movie, .episode], .continueWatching, title: e.title, image: e.artwork?.absoluteString)
            }
            for h in d.history {
                guard let pid = h.playlistID else { continue }
                let kind: CatalogMeta.Kind = h.type == .live ? .channel : h.type == .movie ? .movie : h.type == .series ? .series : .episode
                add(pid.uuidString + "|" + h.itemID, [kind], .history, title: h.title, image: h.artwork?.absoluteString,
                    se: kind == .episode ? CatalogNorm.seasonEpisode(h.subtitle) : nil)
            }
        }
        for c in store.collections where !c.deleted && c.kind == .manual {
            for i in c.items {
                guard let sid = i.sid ?? c.sourceID, !sid.isEmpty else { continue }
                let kind: CatalogMeta.Kind = i.type == .channel ? .channel : i.type == .movie ? .movie : .series
                add(sid + "|" + i.id, [kind], .collection(c.id))
            }
        }
        return out
    }

    // MARK: - Opzoeken per server (achtergrond)

    struct ServerResult: Sendable {
        var found: [String: Found] = [:]
        var missing: [String] = []
        var metaUpdates: [String: CatalogMeta.Item] = [:]
        var episodeSeries: [String: Series] = [:]
        /// Collectie-items zonder server die op deze server staan: "<type>|<id>"
        var legacyHits: Set<String> = []
    }

    /// Items van één server opzoeken in zijn catalogus; zichtbaarheid volgens het filter van het actieve profiel.
    nonisolated static func resolve(refs: [Ref], lib: Library, sid: UUID, sname: String, isActive: Bool,
                                    ctx: PlaylistService.FilterContext?, meta: [String: CatalogMeta.Item],
                                    legacy: [CollectionItem], now: Double) -> ServerResult {
        var r = ServerResult()
        var movies: [String: Movie] = [:], series: [String: Series] = [:], channels: [String: Channel] = [:]
        movies.reserveCapacity(lib.movies.count); series.reserveCapacity(lib.series.count)
        for m in lib.movies where movies[m.id] == nil { movies[m.id] = m }
        for s in lib.series where series[s.id] == nil { series[s.id] = s }
        for c in lib.channels where channels[c.id] == nil { channels[c.id] = c }
        let wanted = Set(refs.map(\.item))
        var episodeOwner: [String: Series] = [:]
        if refs.contains(where: { $0.kinds.contains(.episode) }) {
            for s in lib.series where !s.episodes.isEmpty {
                for e in s.episodes where wanted.contains(e.id) && episodeOwner[e.id] == nil { episodeOwner[e.id] = s }
            }
        }
        var byTitle: [String: Series] = [:]
        if refs.contains(where: { $0.kinds.contains(.episode) }) {
            for s in lib.series where byTitle[s.title] == nil { byTitle[s.title] = s }
        }
        var subset = Library()
        var hits: [String: (kind: CatalogMeta.Kind, ref: Ref, series: Series?)] = [:]
        for ref in refs {
            if ref.kinds.contains(.channel), let c = channels[ref.item] {
                subset.channels.append(c); hits[ref.norm] = (.channel, ref, nil)
            } else if ref.kinds.contains(.movie), let m = movies[ref.item] {
                subset.movies.append(m); hits[ref.norm] = (.movie, ref, nil)
            } else if ref.kinds.contains(.series), let s = series[ref.item] {
                subset.series.append(s); hits[ref.norm] = (.series, ref, nil)
            } else if ref.kinds.contains(.episode) {
                var owner = episodeOwner[ref.item]
                if owner == nil, let ep = meta[ref.norm]?.ep, let (_, sItem) = CatalogKey.split(ep.series) { owner = series[sItem] }
                if owner == nil, let t = ref.title { owner = byTitle[t] }
                if let s = owner {
                    // de serie bestaat op deze server; de aflevering zelf wordt bij het afspelen opgehaald
                    subset.series.append(s); hits[ref.norm] = (.episode, ref, s)
                } else if !lib.isEmptyLibrary {
                    r.missing.append(ref.norm)
                }
            } else if !lib.isEmptyLibrary {
                r.missing.append(ref.norm)
            }
        }
        // zichtbaarheid: leeftijd, kinderslot en categorieën van het actieve profiel op deze server
        var visibleMovies = Set<String>(), visibleSeries = Set<String>(), visibleChannels = Set<String>()
        var shownMovies: [String: Movie] = [:], shownSeries: [String: Series] = [:], shownChannels: [String: Channel] = [:]
        let vis = ctx.map { PlaylistService.apply(subset, $0) } ?? subset
        for m in vis.movies { visibleMovies.insert(m.id); shownMovies[m.id] = m }
        for s in vis.series { visibleSeries.insert(s.id); shownSeries[s.id] = s }
        for c in vis.channels { visibleChannels.insert(c.id); shownChannels[c.id] = c }
        let tag: UUID? = isActive ? nil : sid
        for (norm, h) in hits {
            let ref = h.ref
            switch h.kind {
            case .channel:
                guard let c = channels[ref.item] else { continue }
                r.metaUpdates[norm] = .init(title: c.name, year: nil, kind: .channel, tmdb: nil, image: c.logo?.absoluteString,
                                            sid: sid.uuidString.lowercased(), serverName: sname, ep: nil,
                                            ch: .init(name: c.name, epg: c.epgID), at: now)
                if var x = shownChannels[ref.item] { x.sourceID = tag; r.found[norm] = Found(channel: x) }
            case .movie:
                guard let m = movies[ref.item] else { continue }
                r.metaUpdates[norm] = .init(title: m.title, year: m.year, kind: .movie, tmdb: m.tmdbID, image: m.poster?.absoluteString,
                                            sid: sid.uuidString.lowercased(), serverName: sname, ep: nil, ch: nil, at: now)
                if var x = shownMovies[ref.item] { x.sourceID = tag; r.found[norm] = Found(movie: x) }
            case .series:
                guard let s = series[ref.item] else { continue }
                r.metaUpdates[norm] = .init(title: s.title, year: s.year, kind: .series, tmdb: s.tmdbID, image: s.poster?.absoluteString,
                                            sid: sid.uuidString.lowercased(), serverName: sname, ep: nil, ch: nil, at: now)
                if var x = shownSeries[ref.item] { x.sourceID = tag; r.found[norm] = Found(series: x) }
            case .episode:
                guard let s = h.series else { continue }
                let old = meta[norm]?.ep
                let season = ref.season ?? old?.season
                let number = ref.episode ?? old?.episode
                var ep: CatalogMeta.EpisodeRef?
                if let season, let number {
                    ep = .init(series: sid.uuidString.lowercased() + "|" + s.id, seriesTitle: s.title, season: season, episode: number)
                }
                r.metaUpdates[norm] = .init(title: s.title, year: s.year, kind: .episode, tmdb: s.tmdbID,
                                            image: ref.image ?? s.poster?.absoluteString, sid: sid.uuidString.lowercased(),
                                            serverName: sname, ep: ep, ch: nil, at: now)
                if var x = shownSeries[s.id] { x.sourceID = tag; r.episodeSeries[norm] = x }
            }
        }
        // collectie-items zonder server (van vóór build 128): staan ze op deze server?
        for i in legacy {
            let ok: Bool
            switch i.type {
            case .channel: ok = channels[i.id] != nil
            case .movie: ok = movies[i.id] != nil
            case .series: ok = series[i.id] != nil
            }
            if ok { r.legacyHits.insert(i.type.rawValue + "|" + i.id) }
        }
        return r
    }

    /// Build 129: slimme collecties in de catalogus van een andere server, met het filter (leeftijd, kinderslot,
    /// categorieën) van het profiel op die server; zelfde zoeklogica als op de actieve server (`CollectionResolver`).
    nonisolated static func smart(_ list: [BingrCollection], lib: Library, ctx: PlaylistService.FilterContext,
                                  sid: UUID) -> [String: CollectionContent] {
        let vis = PlaylistService.apply(lib, ctx)
        let ix = LibrarySearchIndex(vis, version: 0)
        var out: [String: CollectionContent] = [:]
        for c in list {
            var r = CollectionResolver.resolve(c, lib: vis, source: sid, index: ix)
            for i in r.channels.indices { r.channels[i].sourceID = sid }
            for i in r.movies.indices { r.movies[i].sourceID = sid }
            for i in r.series.indices { r.series[i].sourceID = sid }
            out[c.id] = r
        }
        return out
    }

    /// Lichte koppel-index van een catalogus (achtergrond)
    nonisolated static func index(_ lib: Library) -> CatalogIndex {
        var titles: [CatalogIndex.Entry] = []
        titles.reserveCapacity(lib.movies.count + lib.series.count)
        for m in lib.movies { titles.append(CatalogIndex.entry(id: m.id, kind: .movie, title: m.title, year: m.year, tmdb: m.tmdbID)) }
        for s in lib.series { titles.append(CatalogIndex.entry(id: s.id, kind: .series, title: s.title, year: s.year, tmdb: s.tmdbID)) }
        let channels = lib.channels.map { CatalogIndex.channelEntry(id: $0.id, name: $0.name, epg: $0.epgID) }
        return CatalogIndex(titles: titles, channels: channels)
    }

    nonisolated static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await op() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r
        }
    }

    /// Catalogus van een server: de open bron uit het geheugen, anders de cache, anders (mag `fetch`) ophalen.
    /// Build 130: een oude cache (> 6 uur) van een niet-actieve server wordt meteen gebruikt en daarna stil op de
    /// achtergrond ververst (`queueStale`); nooit met de laadindicator, die hoort alleen bij de actieve server.
    private func catalog(_ s: PlaylistSource, fetch: Bool, force: Bool = false) async -> (Library, Date)? {
        if let pl = playlists, pl.source?.id == s.id, !pl.rawLibrary.isEmptyLibrary {
            return (pl.rawLibrary, Date(timeIntervalSince1970: Double(pl.libraryVersion)))
        }
        if let hit = await Task.detached(priority: .utility, operation: { PlaylistService.readAnyCatalog(s) }).value {
            if fetch, Date().timeIntervalSince(hit.1) > Self.freshFor, s.id != playlists?.source?.id { queueStale(s.id) }
            return hit
        }
        guard fetch else { return nil }
        if !force, let last = lastFetch[s.id], Date().timeIntervalSince(last) < Self.freshFor { return nil }
        if !force { await waitUntilNotPlaying() }
        lastFetch[s.id] = Date()
        guard let lib = await Self.withTimeout(90, { try? await PlaylistService.fetchCatalog(s) }), !lib.isEmptyLibrary else { return nil }
        await Task.detached(priority: .utility) { PlaylistService.writeCatalog(s, lib) }.value
        return (lib, Date())
    }

    /// Build 130: een niet-actieve server met een oude cache stil verversen (één tegelijk, niet tijdens afspelen,
    /// hooguit eens per 6 uur per server, ook over herstarts heen). Daarna één nieuwe ronde; die vindt een verse
    /// catalogus en zet niets opnieuw in de rij, dus geen lus.
    private func queueStale(_ id: UUID) {
        if let last = lastFetch[id], Date().timeIntervalSince(last) < Self.freshFor { return }
        guard !staleQueue.contains(id) else { return }
        staleQueue.append(id)
        guard staleTask == nil else { return }
        staleTask = Task { @MainActor [weak self] in
            var updated = false
            while let self, !self.staleQueue.isEmpty, !Task.isCancelled {
                let id = self.staleQueue.removeFirst()
                await self.waitUntilQuiet()
                guard let s = CloudStore.shared.playlists.first(where: { $0.id == id }), s.id != self.playlists?.source?.id,
                      let stamp = PlaylistService.catalogStamp(s), Date().timeIntervalSince(stamp) > Self.freshFor else { continue }
                if let last = self.lastFetch[id], Date().timeIntervalSince(last) < Self.freshFor { continue }
                self.lastFetch[id] = Date()
                guard let lib = await Self.withTimeout(90, { try? await PlaylistService.fetchCatalog(s) }), !lib.isEmptyLibrary else { continue }
                await Task.detached(priority: .utility) { PlaylistService.writeCatalog(s, lib) }.value
                updated = true
            }
            self?.staleTask = nil
            if updated { self?.schedule(delay: 2) }
        }
    }

    /// Build 130: na "alle servers verversen" (PlaylistService.refreshAll): de verse catalogi meteen gebruiken voor
    /// catalogmeta, remap en slimme collecties, en ontbrekende items opnieuw op alle servers zoeken.
    func serversRefreshed(_ ids: [UUID]) {
        guard started else { return }
        let now = Date()
        for id in ids { lastFetch[id] = now }
        staleQueue.removeAll { ids.contains($0) }
        lastMatchTry = [:]
        schedule(delay: 1)
    }

    /// Wachten tot er niets afspeelt (hooguit 6 uur)
    func waitUntilNotPlaying() async {
        var waited = 0
        while isPlaying() && !Task.isCancelled && waited < 6 * 3600 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            waited += 10
        }
    }

    /// Wachten tot er niets afspeelt en er niet gescrold wordt
    private func waitUntilQuiet() async {
        await waitUntilNotPlaying()
        await ScrollActivity.shared.waitUntilIdle()
    }

    // MARK: - De ronde

    private func pass(interactive: Bool, only: Set<String>?) async {
        guard let pl = playlists, !Screenshots.isActive else { return }
        if !interactive { await waitUntilQuiet() }
        guard !Task.isCancelled else { return }
        migrateCategories()
        applyRemapEverywhere()
        let store = CloudStore.shared
        var refs = gatherRefs()
        if let only {
            let wanted = Set(only.map(CatalogKey.normalize))
            refs = refs.filter { wanted.contains($0.key) }
        }
        let sources = store.playlists
        let activeID = pl.source?.id
        let ordered = sources.filter { $0.id == activeID } + sources.filter { $0.id != activeID }
        let now = Date().timeIntervalSince1970
        var bySid: [String: [Ref]] = [:]
        for r in refs.values { bySid[r.sid, default: []].append(r) }
        // collectie-items zonder server (van vóór build 128)
        var legacy: [CollectionItem] = []
        for c in store.collections where !c.deleted && c.kind == .manual && (c.sourceID ?? "").isEmpty {
            legacy += c.items.filter { ($0.sid ?? "").isEmpty }
        }

        // build 129: slimme collecties (zoekwoorden) van het actieve profiel; alleen in een volledige ronde
        let smartList = only == nil ? store.activeCollections.filter { !$0.deleted && $0.kind == .smart && !$0.keywords.isEmpty } : []
        var newSmart: [UUID: [String: CollectionContent]] = [:]

        var newFound = only == nil ? [String: Found]() : found
        var newMissing = only == nil ? [String: Missing]() : missing
        var newEpisodes = only == nil ? [String: Series]() : episodeSeries
        var metaChanged = false
        var legacyStamps: [String: String] = [:]   // "<type>|<id>" → server-id

        func missingInfo(_ r: Ref, deleted: Bool, unverified: Bool) -> Missing {
            let m = meta.item(forKey: r.norm)
            let kind = m?.kind ?? (r.kinds.count == 1 ? r.kinds.first : (r.season != nil ? .episode : nil))
            let title = (m?.kind == .episode ? (m?.ep?.seriesTitle ?? m?.title) : m?.title) ?? r.title ?? ""
            return Missing(title: title, kind: kind, sid: r.sid, item: r.item,
                           image: (m?.image ?? r.image).flatMap(URL.init(string:)), year: m?.year,
                           serverDeleted: deleted, unverified: unverified)
        }

        for src in ordered {
            let list = bySid[src.id.uuidString.lowercased()] ?? []
            let isActive = src.id == activeID
            let smartHere = isActive ? [] : smartList.filter { CollectionResolver.matchesSource($0, src.id) }
            guard !list.isEmpty || (isActive && !legacy.isEmpty) || !smartHere.isEmpty else { continue }
            let ctx = pl.context(for: src)
            guard let (lib, stamp) = await catalog(src, fetch: !list.isEmpty || !smartHere.isEmpty, force: interactive) else {
                for r in list { newMissing[r.norm] = missingInfo(r, deleted: false, unverified: true) }
                if let old = smartResult[src.id], !smartHere.isEmpty { newSmart[src.id] = old }
                continue
            }
            guard !Task.isCancelled else { return }
            let base = "\(stamp.timeIntervalSince1970)|\(store.activeProfileID?.uuidString ?? "")|\(ctx.ageLimit ?? -1)|\(ctx.strict)|"
                + "\(ctx.parentalEnabled)|\(ctx.unlocked)|\(ctx.hiddenGroups.sorted().joined(separator: ","))|\(ctx.custom.hashValue)|"
            // build 129: slimme collecties op deze (niet-actieve) server, met het filter van het profiel op deze server
            if !smartHere.isEmpty {
                let ssig = base + smartHere.map { "\($0.id):\($0.query):\($0.types.joined(separator: "+")):\($0.group ?? "")" }
                    .sorted().joined(separator: ";")
                if smartSig[src.id] == ssig, let cached = smartResult[src.id] {
                    newSmart[src.id] = cached
                } else {
                    let sid = src.id
                    let r = await Task.detached(priority: .utility) { Self.smart(smartHere, lib: lib, ctx: ctx, sid: sid) }.value
                    guard !Task.isCancelled else { return }
                    smartSig[src.id] = ssig
                    smartResult[src.id] = r
                    newSmart[src.id] = r
                }
            }
            guard !list.isEmpty || (isActive && !legacy.isEmpty) else { continue }
            let sig = base + list.map(\.norm).sorted().joined(separator: ",") + "|\(isActive ? legacy.count : 0)"
            let result: ServerResult
            if only == nil, lastSig[src.id] == sig, let cached = lastResult[src.id] {
                result = cached
            } else {
                let metaSnapshot = Dictionary(uniqueKeysWithValues: list.compactMap { r in meta.item(forKey: r.norm).map { (r.norm, $0) } })
                let leg = isActive ? legacy : []
                let name = src.name
                result = await Task.detached(priority: .utility) {
                    Self.resolve(refs: list, lib: lib, sid: src.id, sname: name, isActive: isActive, ctx: ctx,
                                 meta: metaSnapshot, legacy: leg, now: now)
                }.value
                if only == nil { lastSig[src.id] = sig; lastResult[src.id] = result }
            }
            for (k, f) in result.found { newFound[k] = f; newMissing[k] = nil }
            for (k, s) in result.episodeSeries { newEpisodes[k] = s; newMissing[k] = nil }
            for k in result.missing { if let r = refs[k] { newMissing[k] = missingInfo(r, deleted: false, unverified: false) } }
            for (k, item) in result.metaUpdates where setMerged(k, item) { metaChanged = true }
            if isActive { for h in result.legacyHits { legacyStamps[h] = src.id.uuidString } }
        }
        // servers die niet meer bestaan
        let existing = Set(sources.map { $0.id.uuidString.lowercased() })
        for (sid, list) in bySid where !existing.contains(sid) {
            for r in list { newMissing[r.norm] = missingInfo(r, deleted: true, unverified: false) }
        }

        // collectie-items zonder server: de server invullen waar ze staan (eenmalig, build 128)
        if !legacyStamps.isEmpty { stampLegacyCollectionItems(legacyStamps) }

        // zoeken op de andere servers
        var remapped = false
        let candidates = newMissing.filter { k, m in
            guard interactive || !m.unverified else { return false }
            if !interactive, let t = lastMatchTry[k], Date().timeIntervalSince(t) < 6 * 3600 { return false }
            return true
        }
        if !candidates.isEmpty, !ordered.isEmpty {
            for k in candidates.keys { lastMatchTry[k] = Date() }
            var open = candidates
            for target in ordered {
                guard !open.isEmpty, !Task.isCancelled else { break }
                let mine = open.filter { $0.value.sid != target.id.uuidString.lowercased() }
                guard !mine.isEmpty else { continue }
                guard let (lib, _) = await catalog(target, fetch: true, force: interactive) else { continue }
                let idx = await Task.detached(priority: .utility) { Self.index(lib) }.value
                for (k, m) in mine {
                    guard let item = matchItem(k, m), let hit = idx.match(item) else { continue }
                    var newItem = hit
                    var newMeta = item
                    if item.kind == .episode {
                        guard let ep = item.ep, let s = lib.series.first(where: { $0.id == hit }) else { continue }
                        let eps = await Self.withTimeout(25, { await PlaylistService.fetchEpisodes(s, in: target) }) ?? []
                        guard let e = eps.first(where: { $0.season == ep.season && $0.number == ep.episode }) else { continue }
                        newItem = e.id
                        newMeta.ep = .init(series: target.id.uuidString.lowercased() + "|" + s.id, seriesTitle: s.title,
                                           season: ep.season, episode: ep.episode)
                    }
                    let from = m.sid + "|" + m.item
                    let to = target.id.uuidString + "|" + newItem
                    guard meta.addRemap(from: from, to: to, at: now) else { continue }
                    newMeta.sid = target.id.uuidString.lowercased()
                    newMeta.serverName = target.name
                    newMeta.at = now
                    _ = setMerged(to, newMeta)
                    metaChanged = true
                    remapped = true
                    open[k] = nil
                    newMissing[k] = nil
                }
            }
        }

        if metaChanged {
            prune()
            persist()
            StateSync.shared.catalogMetaChanged(delay: isPlaying() ? 30 : 3)
        }
        var changed = newFound != found || newMissing != missing || newEpisodes != episodeSeries
        if only == nil {
            // build 129: slimme collecties samenvoegen in de volgorde van de sources (de actieve server zit er niet in)
            var merged: [String: CollectionContent] = [:]
            for src in ordered where src.id != activeID {
                guard let r = newSmart[src.id] else { continue }
                for (cid, c) in r where !c.isEmpty {
                    merged[cid, default: CollectionContent()].channels += c.channels
                    merged[cid, default: CollectionContent()].movies += c.movies
                    merged[cid, default: CollectionContent()].series += c.series
                }
            }
            let gone = Set(smartResult.keys).subtracting(sources.map(\.id))
            for g in gone { smartResult[g] = nil; smartSig[g] = nil }
            if merged != smartFound { smartFound = merged; changed = true }
        }
        found = newFound
        missing = newMissing
        episodeSeries = newEpisodes
        if changed { version &+= 1 }
        if only == nil { UserDefaults.standard.set(true, forKey: Self.migratedKey) }
        if remapped {
            applyRemapEverywhere()
            // de nieuwe sleutels opzoeken (andere server)
            again = !interactive
        }
    }

    /// Het meta-item om mee te zoeken: de meta, anders wat voortgang/geschiedenis weet (nooit raden op het id).
    private func matchItem(_ norm: String, _ m: Missing) -> CatalogMeta.Item? {
        if var i = meta.item(forKey: norm) {
            if i.kind == .episode, i.ep == nil { return nil }
            if i.title.isEmpty { i.title = m.title }
            return i.title.isEmpty && i.kind != .channel ? nil : i
        }
        guard !m.title.isEmpty else { return nil }
        let kind = m.kind ?? .movie
        if kind == .episode { return nil }   // zonder seizoen/aflevering niet te koppelen
        return .init(title: m.title, year: m.year, kind: kind, tmdb: nil, image: m.image?.absoluteString, sid: m.sid,
                     serverName: nil, ep: nil, ch: kind == .channel ? .init(name: m.title, epg: nil) : nil, at: 0)
    }

    /// Meta samenvoegen met wat er al is (bekende velden niet wissen). true = gewijzigd.
    private func setMerged(_ key: String, _ item: CatalogMeta.Item) -> Bool {
        var i = item
        if let old = meta.item(forKey: key) {
            if i.title.isEmpty { i.title = old.title }
            i.year = i.year ?? old.year
            i.tmdb = i.tmdb ?? old.tmdb
            i.image = i.image ?? old.image
            i.serverName = i.serverName ?? old.serverName
            if i.ep == nil { i.ep = old.ep }
            if let c = i.ch, c.epg == nil, let oc = old.ch { i.ch?.epg = oc.epg }
            if i.ch == nil { i.ch = old.ch }
            if old.sameContent(i) { return false }
        }
        return meta.set(key, i)
    }

    private func prune() {
        meta.prune(referenced: Set(gatherRefs().keys), now: Date().timeIntervalSince1970)
    }

    private func persist() {
        saveTask?.cancel()
        let j = meta.json()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, JSONSerialization.isValidJSONObject(j),
                  let d = try? JSONSerialization.data(withJSONObject: j) else { return }
            try? d.write(to: CrossServer.fileURL, options: .atomic)
        }
    }

    // MARK: - Afspelen: meta meeschrijven

    func notePlayed(_ it: PlayableItem) {
        let store = CloudStore.shared
        guard !Screenshots.isActive, let sid = it.sourceID ?? store.activePlaylistID, !it.id.contains("-cu-") else { return }
        let sname = store.playlists.first { $0.id == sid }?.name
        let s = sid.uuidString.lowercased()
        let now = Date().timeIntervalSince1970
        var key: String
        var item: CatalogMeta.Item
        switch it.type {
        case .live:
            let ch = it.channelID ?? it.id
            key = sid.uuidString + "|" + ch
            item = .init(title: it.title, year: nil, kind: .channel, tmdb: nil, image: it.artwork?.absoluteString, sid: s,
                         serverName: sname, ep: nil, ch: .init(name: it.title, epg: nil), at: now)
        case .movie:
            key = sid.uuidString + "|" + it.id
            item = .init(title: it.title, year: it.subtitle.flatMap { Int($0) }, kind: .movie, tmdb: nil,
                         image: it.artwork?.absoluteString, sid: s, serverName: sname, ep: nil, ch: nil, at: now)
        case .episode:
            key = sid.uuidString + "|" + it.id
            var ep: CatalogMeta.EpisodeRef?
            if let season = it.season, let e = it.episode, let series = it.seriesID {
                ep = .init(series: s + "|" + series, seriesTitle: it.title, season: season, episode: e)
            }
            item = .init(title: it.title, year: nil, kind: .episode, tmdb: nil, image: it.artwork?.absoluteString, sid: s,
                         serverName: sname, ep: ep, ch: nil, at: now)
        case .series:
            return
        }
        if setMerged(key, item) {
            persist()
            StateSync.shared.catalogMetaChanged(delay: 30)
        }
    }

    // MARK: - Sync (state-section `catalogmeta`)

    /// Server-versie samenvoegen (nieuwste `at` per sleutel), begrenzen en lokaal bewaren. Geeft de data terug als er
    /// geüpload moet worden.
    func mergeRemote(_ data: Any?, hadRemote: Bool) -> [String: Any]? {
        guard !Screenshots.isActive else { return nil }
        let remote = CatalogMeta(json: data)
        var merged = CatalogMeta.merge(meta, remote)
        merged.prune(referenced: Set(gatherRefs().keys), now: Date().timeIntervalSince1970)
        let newRules = merged.remap != meta.remap
        if merged != meta {
            meta = merged
            persist()
        }
        if newRules { schedule(delay: 1) }
        let same = hadRemote && merged.items == remote.items && merged.remap == remote.remap
        if same || (!hadRemote && merged.items.isEmpty && merged.remap.isEmpty) { return nil }
        var out = merged
        out.updatedAt = Date().timeIntervalSince1970
        return out.json()
    }

    // MARK: - Remap toepassen (alle profielen en collecties)

    /// Alle remap-regels toepassen. Idempotent; ketens worden gevolgd (CatalogMeta.resolve), lussen genegeerd.
    @discardableResult
    func applyRemapEverywhere() -> Bool {
        guard !meta.remap.isEmpty, !Screenshots.isActive else { return false }
        let store = CloudStore.shared
        let sync = StateSync.shared
        let now = Date()
        var any = false
        for p in store.profiles {
            var d = store.profileData(p.id)
            var changes: [(String, String)] = []
            func note(_ field: String, _ ch: [(String, String)]) {
                for (o, n) in ch { sync.noteRemap(profile: p.id, field: field, old: o, new: n, at: now) }
            }
            let (ml, c1) = CatalogRemap.set(d.myList, meta)
            if !c1.isEmpty { note("myList", c1); d.myList = ml; changes += c1 }
            let (fv, c2) = CatalogRemap.set(d.favorites, meta)
            if !c2.isEmpty { note("favorites", c2); d.favorites = fv; changes += c2 }
            let (rc, c3) = CatalogRemap.list(d.recentChannels, meta)
            if !c3.isEmpty { note("recentChannels", c3); d.recentChannels = rc; changes += c3 }
            // voortgang: sleutel (item-id) en server; positie en tijd blijven
            var progress = d.progress
            for (k, e) in d.progress {
                guard let pid = e.playlistID, let to = meta.resolve(pid.uuidString + "|" + k),
                      let (ts, ti) = CatalogKey.split(to), let tu = UUID(uuidString: ts) else { continue }
                var e2 = e
                e2.playlistID = tu
                progress[k] = nil
                if let cur = progress[ti], cur.updated >= e2.updated, cur.playlistID == tu { } else { progress[ti] = e2 }
                if ti != k { note("progress", [(k, ti)]) }
                changes.append((pid.uuidString + "|" + k, tu.uuidString + "|" + ti))
            }
            d.progress = progress
            // geschiedenis
            var hist: [HistoryEntry] = []
            var seen = Set<String>()
            var histChanged = false
            for h in d.history {
                var x = h
                if let pid = h.playlistID, let to = meta.resolve(pid.uuidString + "|" + h.itemID),
                   let (ts, ti) = CatalogKey.split(to), let tu = UUID(uuidString: ts) {
                    let oldID = h.id
                    x.playlistID = tu
                    x.itemID = ti
                    if h.channelID != nil { x.channelID = ti }
                    note("history", [(oldID, x.id)])
                    histChanged = true
                    changes.append((pid.uuidString + "|" + h.itemID, tu.uuidString + "|" + ti))
                }
                if seen.insert(x.id).inserted { hist.append(x) }
            }
            if histChanged { d.history = hist }
            // bekeken: het nieuwe item-id (en bij een serie/aflevering de sleutel per serie) erbij
            for (o, n) in changes {
                guard let (_, oi) = CatalogKey.split(o), let (_, ni) = CatalogKey.split(n), oi != ni else { continue }
                if d.watched.contains(oi) { d.watched.insert(ni) }
                let oldSeries = meta.item(forKey: o)?.ep.flatMap { CatalogKey.split($0.series)?.item } ?? oi
                let newSeries = meta.item(forKey: n)?.ep.flatMap { CatalogKey.split($0.series)?.item } ?? ni
                guard oldSeries != newSeries else { continue }
                for w in d.watched where w.hasPrefix("ep:\(oldSeries)|") {
                    d.watched.insert("ep:\(newSeries)|" + w.dropFirst("ep:\(oldSeries)|".count))
                }
            }
            if !changes.isEmpty || histChanged {
                store.applyRemappedProfileData(p.id, d)
                any = true
            }
        }
        // collecties (alle profielen): `id` en `sid` van het item
        var list = store.collections
        var collectionsChanged = false
        for i in list.indices where !list[i].deleted && list[i].kind == .manual {
            var items: [CollectionItem] = []
            var changed = false
            for var it in list[i].items {
                if let sid = it.sid ?? list[i].sourceID, !sid.isEmpty, let to = meta.resolve(sid + "|" + it.id),
                   let (ts, ti) = CatalogKey.split(to) {
                    it.id = ti
                    it.sid = UUID(uuidString: ts)?.uuidString ?? ts
                    changed = true
                }
                if !items.contains(where: { $0.type == it.type && $0.id == it.id && ($0.sid ?? "").caseInsensitiveCompare(it.sid ?? "") == .orderedSame }) {
                    items.append(it)
                }
            }
            if changed {
                list[i].items = items
                list[i].updatedAt = now
                collectionsChanged = true
            }
        }
        if collectionsChanged {
            store.applyRemappedCollections(list)
            any = true
        }
        return any
    }

    /// Collectie-items zonder server krijgen de server waarop ze gevonden zijn (build 128).
    private func stampLegacyCollectionItems(_ stamps: [String: String]) {
        let store = CloudStore.shared
        var list = store.collections
        var changed = false
        let now = Date()
        for i in list.indices where !list[i].deleted && list[i].kind == .manual && (list[i].sourceID ?? "").isEmpty {
            var c = false
            for j in list[i].items.indices where (list[i].items[j].sid ?? "").isEmpty {
                let it = list[i].items[j]
                if let sid = stamps[it.type.rawValue + "|" + it.id] { list[i].items[j].sid = sid; c = true }
            }
            if c { list[i].updatedAt = now; changed = true }
        }
        if changed { store.applyRemappedCollections(list) }
    }

    // MARK: - Voor de schermen

    private var showsUnknown: Bool { CloudStore.shared.activeProfile?.effectiveAgeLimit == nil }

    private func synthMovie(_ m: Missing) -> Movie {
        Movie(id: m.item, title: m.title.isEmpty ? L("Unknown title") : m.title, year: m.year, poster: m.image, group: "",
              streamURL: nil, imdbID: nil, rating: nil, plot: nil, addedAt: nil, stalkerCmd: nil, xtreamVodID: nil,
              sourceID: UUID(uuidString: m.sid))
    }
    private func synthSeries(_ m: Missing) -> Series {
        Series(id: m.item, title: m.title.isEmpty ? L("Unknown title") : m.title, year: m.year, poster: m.image, group: "",
               imdbID: nil, plot: nil, rating: nil, xtreamSeriesID: nil, sourceID: UUID(uuidString: m.sid))
    }
    private func synthChannel(_ m: Missing) -> Channel {
        Channel(id: m.item, name: m.title.isEmpty ? L("Unknown title") : m.title, logo: m.image, group: "", streamURL: nil,
                epgID: nil, number: nil, sourceID: UUID(uuidString: m.sid))
    }

    /// Film van een andere server (of een tegel voor een item dat nog niet gevonden is)
    func movie(forKey k: String) -> Movie? {
        let n = CatalogKey.normalize(k)
        if let m = found[n]?.movie { return m }
        guard found[n] == nil, showsUnknown, let m = missing[n], m.kind == .movie || m.kind == nil else { return nil }
        return synthMovie(m)
    }

    func series(forKey k: String) -> Series? {
        let n = CatalogKey.normalize(k)
        if let s = found[n]?.series { return s }
        guard found[n] == nil, showsUnknown, let m = missing[n], m.kind == .series else { return nil }
        return synthSeries(m)
    }

    func channel(forKey k: String) -> Channel? {
        let n = CatalogKey.normalize(k)
        if let c = found[n]?.channel { return c }
        guard found[n] == nil, showsUnknown, let m = missing[n], m.kind == .channel || m.kind == nil else { return nil }
        return synthChannel(m)
    }

    /// Serie van een aflevering uit Verder kijken op een andere server
    func episodeSeries(playlist: UUID, key: String) -> Series? { episodeSeries[CatalogKey.make(playlist.uuidString, key)] }

    /// Is dit een item dat (nog) niet gevonden is? Dan eerst `open` (zoeken, anders de melding).
    func isMissing(_ key: String) -> Bool { missing[CatalogKey.normalize(key)] != nil }
    func isMissing(_ t: DetailTarget) -> Bool { t.sourceID.map { isMissing($0.uuidString + "|" + t.id) } ?? false }
    func isMissing(_ c: Channel) -> Bool { c.sourceID.map { isMissing($0.uuidString + "|" + c.id) } ?? false }

    /// Dezelfde titel op twee servers: één tegel (de eerste blijft; de actieve server staat vooraan)
    static func dedupe<T>(_ items: [T], identity: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(identity($0)).inserted }
    }
    static func identity(_ m: Movie) -> String { CatalogIdentity.title(kind: .movie, title: m.title, year: m.year, tmdb: m.tmdbID) }
    static func identity(_ s: Series) -> String { CatalogIdentity.title(kind: .series, title: s.title, year: s.year, tmdb: s.tmdbID) }
    static func identity(_ c: Channel) -> String { CatalogIdentity.channel(name: c.name, epg: c.epgID) }

    /// Volgorde: laatst toegevoegd eerst (tijd uit de sync, anders uit de meta)
    func addedAt(_ key: String, field: String) -> Double {
        let store = CloudStore.shared
        if let p = store.activeProfileID ?? store.mainProfileID,
           let t = StateSync.shared.addedAt(profile: p, field: field, key: key), t > 1 { return t }
        return meta.item(forKey: key)?.at ?? 0
    }

    /// Items van andere servers in een collectie (handmatig: de items met een andere server; slim, build 129: de
    /// treffers op de andere servers)
    func collectionContent(_ c: BingrCollection, active: UUID?) -> CollectionContent {
        guard c.kind == .manual else {
            guard var out = smartFound[c.id] else { return CollectionContent() }
            // is er intussen van server gewisseld: de actieve server komt al uit de eigen bibliotheek
            if let active {
                out.channels.removeAll { $0.sourceID == active }
                out.movies.removeAll { $0.sourceID == active }
                out.series.removeAll { $0.sourceID == active }
            }
            return out
        }
        var out = CollectionContent()
        for i in c.items {
            guard let sid = i.sid ?? c.sourceID, !sid.isEmpty,
                  active.map({ sid.caseInsensitiveCompare($0.uuidString) != .orderedSame }) ?? true else { continue }
            let key = sid + "|" + i.id
            switch i.type {
            case .channel: if let x = channel(forKey: key) { out.channels.append(x) }
            case .movie: if let x = movie(forKey: key) { out.movies.append(x) }
            case .series: if let x = series(forKey: key) { out.series.append(x) }
            }
        }
        return out
    }

    /// Naam van een collectie-item van een andere server (bewerkscherm)
    func title(of i: CollectionItem, in c: BingrCollection?) -> String? {
        guard let sid = i.sid ?? c?.sourceID else { return nil }
        let k = sid + "|" + i.id
        if let f = found[CatalogKey.normalize(k)] { return f.movie?.title ?? f.series?.title ?? f.channel?.name }
        return meta.item(forKey: k)?.title
    }

    // MARK: - Aanklikken: zoeken, anders de melding

    /// Een item openen dat (nog) niet gevonden is: nu zoeken op de eigen en de andere servers. Gevonden → het item
    /// (na de remap), niet gevonden → de melding.
    func open(key: String, list: ListKind) async -> Outcome {
        let n = CatalogKey.normalize(key)
        await run(interactive: true, only: [key])
        if let f = found[n], let o = outcome(f) { return o }
        if let se = episodeSeries[n] { return .series(se) }
        if let to = meta.resolve(key) {
            await run(interactive: true, only: [CatalogRemap.appForm(to)])
            let tn = CatalogKey.normalize(to)
            if let f = found[tn], let o = outcome(f) { return o }
            if let se = episodeSeries[tn] { return .series(se) }
        }
        return .prompt(prompt(key: key, list: list))
    }

    private func outcome(_ f: Found) -> Outcome? {
        if let m = f.movie { return .movie(m) }
        if let s = f.series { return .series(s) }
        if let c = f.channel { return .channel(c) }
        return nil
    }

    /// De melding "niet gevonden" (NL/EN in Translations.json)
    func prompt(key: String, list: ListKind) -> Prompt {
        let store = CloudStore.shared
        let n = CatalogKey.normalize(key)
        let split = CatalogKey.split(key)
        let sid = split?.sid ?? ""
        let item = split?.item ?? key
        let m = missing[n]
        let metaItem = meta.item(forKey: key)
        var title = m?.title ?? metaItem?.title ?? ""
        if title.isEmpty { title = L("Unknown title") }
        let source = store.playlists.first { $0.id.uuidString.caseInsensitiveCompare(sid) == .orderedSame }
        let deleted = source == nil
        let serverName = source?.name ?? metaItem?.serverName ?? L("a removed server")
        let others = store.playlists.filter { $0.id.uuidString.caseInsensitiveCompare(sid) != .orderedSame }.map(\.name)
        let names = others.joined(separator: ", ")
        let message: String
        switch (deleted, others.isEmpty) {
        case (true, false): message = L("“%@” was on “%@”, but that server has been removed. This title wasn't found on your other servers (%@).", title, serverName, names)
        case (true, true): message = L("“%@” was on “%@”, but that server has been removed, and you have no other server to search.", title, serverName)
        case (false, false): message = L("“%@” is no longer on “%@” and wasn't found on %@ either.", title, serverName, names)
        case (false, true): message = L("“%@” is no longer on “%@”, and you have no other server to search.", title, serverName)
        }
        let u = UUID(uuidString: sid)
        let kind = m?.kind ?? metaItem?.kind
        let removeLabel: String
        let remove: () -> Void
        switch list {
        case .continueWatching:
            removeLabel = L("Remove from Continue watching")
            remove = { store.clearProgress(item) }
        case .myList:
            removeLabel = L("Remove from My List")
            remove = { if let u { store.setMyList(u, item, false) } }
        case .favorites:
            removeLabel = L("Remove from favorites")
            remove = { if let u, store.isFavorite(u, item) { store.toggleFavorite(u, item) } }
        case .recentChannels:
            removeLabel = L("Remove")
            remove = { if let u { store.removeRecentChannel(u, item) } }
        case .history:
            removeLabel = L("Remove from history")
            remove = {
                if let e = store.history.first(where: { $0.itemID == item && ($0.playlistID?.uuidString.caseInsensitiveCompare(sid) == .orderedSame) }) {
                    store.removeHistory(e)
                }
            }
        case .collection(let cid):
            removeLabel = L("Remove from collection")
            let type: CollectionItem.Kind = kind == .channel ? .channel : kind == .series ? .series : .movie
            remove = { store.toggleInCollection(cid, CollectionItem(type: type, id: item, sid: sid)) }
        }
        let query = m?.title.isEmpty == false ? m!.title : (metaItem?.ep?.seriesTitle ?? metaItem?.title ?? "")
        return Prompt(title: title, message: message, removeLabel: removeLabel, remove: remove,
                      searchQuery: ContentLanguage.displayTitle(query))
    }
}
