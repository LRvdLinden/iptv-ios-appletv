import Foundation
import Combine
#if os(iOS)
import BackgroundTasks
#endif

// Build 179 (versie 1.0.8), Apple-agent A: de app-kant van punten 1 (vanzelf verversen), 3 (andere speler onthouden),
// 12 (sorteren per categorie) en 13 (opruimen). Contract: docs/ACCOUNT.md → "Build 179"; pure logica in `Build179`.

extension Build179.SortMode {
    var title: String {
        switch self {
        case .server: return L("Default")
        case .name: return L("Name (A–Z)")
        case .year: return L("Year (newest)")
        case .added: return L("Recently added")
        case .rating: return L("Highest rated")
        }
    }
}

extension Build179.CatalogInterval {
    var title: String {
        switch self {
        case .sixHours: return L("Every 6 hours")
        case .daily: return L("Daily")
        case .threeDays: return L("Every 3 days")
        case .weekly: return L("Weekly")
        case .manual: return L("Manually only")
        }
    }
}

extension Build179.GuideInterval {
    var title: String {
        switch self {
        case .sixHours: return L("Every 6 hours")
        case .twelveHours: return L("Every 12 hours")
        case .daily: return L("Daily")
        }
    }
}

// MARK: - 12. Sorteren per categorie (`profile.<id>.categorySort`, gesynct via StateSync.merge179Sort)

@MainActor
final class CategorySort179: ObservableObject {
    static let shared = CategorySort179()
    @Published private(set) var revision = 0
    private let defaults = UserDefaults.standard
    private func key(_ id: UUID) -> String { "categorySort.v179.\(id.uuidString)" }
    private var store: CloudStore { CloudStore.shared }
    private var current: UUID? { store.activeProfileID ?? store.mainProfileID }

    private struct Stored: Codable { var value: String; var at: String }

    func entries(_ id: UUID) -> [String: Build179.SortEntry] {
        guard let d = defaults.data(forKey: key(id)),
              let m = try? JSONDecoder().decode([String: Stored].self, from: d) else { return [:] }
        return m.mapValues { Build179.SortEntry(value: $0.value, at: $0.at) }
    }

    func setSynced(_ id: UUID, _ m: [String: Build179.SortEntry]) {
        let s = m.mapValues { Stored(value: $0.value, at: $0.at) }
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: key(id)) }
        revision += 1
    }

    /// Sortering van een categorie voor het actieve profiel
    func mode(_ sortKey: String) -> Build179.SortMode {
        _ = revision
        guard let id = current else { return .server }
        return .from(entries(id)[sortKey]?.value)
    }

    func set(_ sortKey: String, _ mode: Build179.SortMode) {
        guard let id = current else { return }
        var m = entries(id)
        guard m[sortKey]?.value != mode.rawValue else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        m[sortKey] = .init(value: mode.rawValue, at: f.string(from: Date()))
        setSynced(id, m)
        store.stateEdited.send((id, .profile))
    }
}

// MARK: - 3. Andere speler onthouden (lokaal, `player.engineMemo`)

@MainActor
enum EngineMemo179 {
    static let key = "player.engineMemo"

    private static func load() -> [String: Build179.EngineMemo] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Build179.EngineMemo].self, from: d)) ?? [:]
    }

    private static func save(_ m: [String: Build179.EngineMemo]) {
        let pruned = Build179.pruneMemo(m, now: Date().timeIntervalSince1970)
        if let d = try? JSONEncoder().encode(pruned) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func get(_ k: String?) -> String? {
        guard let k else { return nil }
        return load()[k]?.e
    }

    static func set(_ k: String?, _ engine: String?) {
        guard let k else { return }
        var m = load()
        if let engine { m[k] = .init(e: engine, at: Date().timeIntervalSince1970) } else { m[k] = nil }
        save(m)
    }
}

// MARK: - 1. Gids en servers vanzelf verversen

@MainActor
final class AutoRefresh179 {
    static let shared = AutoRefresh179()

    static let catalogKey = "refresh.catalog"
    static let epgKey = "refresh.epg"
    static let cellularKey = "refresh.cellular"
    #if os(iOS)
    static let guideTaskID = "nl.lrvdlinden.bingr.refresh"
    static let fullTaskID = "nl.lrvdlinden.bingr.refresh.full"
    #endif

    weak var playlists: PlaylistService?
    private var timer: Timer?
    private var running = false

    static var catalog: String? { UserDefaults.standard.string(forKey: catalogKey) }
    static var epg: String? { UserDefaults.standard.string(forKey: epgKey) }
    static var allowCellular: Bool { UserDefaults.standard.bool(forKey: cellularKey) }

    private static func fullKey(_ id: UUID) -> String { "refresh.last.\(id.uuidString.lowercased())" }
    private static func epgStampKey(_ id: UUID) -> String { "refresh.lastEpg.\(id.uuidString.lowercased())" }

    /// Laatste geslaagde volledige verversing; zonder stempel (van vóór build 179) de leeftijd van de bewaarde lijst
    static func lastFull(_ s: PlaylistSource) -> Double? {
        let v = UserDefaults.standard.double(forKey: fullKey(s.id))
        if v > 0 { return v }
        return PlaylistService.catalogStamp(s)?.timeIntervalSince1970 ?? cacheDate(s)
    }
    private static func cacheDate(_ s: PlaylistSource) -> Double? {
        let a = try? FileManager.default.attributesOfItem(atPath: PlaylistService.cacheURL(s).path)
        return (a?[.modificationDate] as? Date)?.timeIntervalSince1970
    }
    static func lastEpg(_ s: PlaylistSource) -> Double? {
        let v = UserDefaults.standard.double(forKey: epgStampKey(s.id))
        return v > 0 ? v : nil
    }
    static func noteFull(_ id: UUID) { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fullKey(id)) }
    static func noteEpg(_ id: UUID) { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: epgStampKey(id)) }

    static func plan(_ s: PlaylistSource, now: Double = Date().timeIntervalSince1970) -> Build179.RefreshPlan {
        Build179.refreshPlan(catalog: catalog, epg: epg, lastFull: lastFull(s), lastEpg: lastEpg(s), now: now,
                             saver: DataSaver176.active, allowCellular: allowCellular)
    }

    func start(playlists: PlaylistService) {
        self.playlists = playlists
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in AutoRefresh179.shared.check() }
        }
    }

    /// Moet de open server nu volledig ververst worden? (Dan geen vraag "Servers bijwerken?")
    func activeFullDue() -> Bool {
        guard let s = playlists?.source else { return false }
        return Self.plan(s) == .full
    }

    /// Kijken of er iets ververst moet worden, en dat dan op de achtergrond doen (één tegelijk, niet tijdens afspelen).
    func check() {
        guard !Screenshots.isActive, !SmokeTest.isActive, !running, let pl = playlists else { return }
        guard !pl.refreshingAll, !pl.updatingServers, !pl.isLoading else { return }
        guard pl.mayLoad?() ?? false else { return }
        let all = CloudStore.shared.playlists
        guard all.contains(where: { Self.plan($0) == .full || Self.plan($0) == .epg }) else { scheduleBackground(); return }
        running = true
        Task { @MainActor in
            await self.run(pl, background: false)
            self.running = false
            self.scheduleBackground()
        }
    }

    /// Alle servers langs (de open server eerst). Geeft true als alles wat moest gelukt is.
    @discardableResult
    func run(_ pl: PlaylistService, background: Bool) async -> Bool {
        let all = CloudStore.shared.playlists
        let activeID = pl.source?.id
        let ordered = all.filter { $0.id == activeID } + all.filter { $0.id != activeID }
        var ok = true
        for p in ordered {
            if Task.isCancelled { return false }
            // niet tijdens het afspelen, niet buiten het hoofdscherm (op de achtergrond speelt er niets)
            if !background {
                while (pl.isPlaying?() ?? false) || !(pl.mayLoad?() ?? true) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { return false }
                }
                if pl.refreshingAll || pl.updatingServers { return false }
            }
            guard CloudStore.shared.playlists.contains(where: { $0.id == p.id }) else { continue }
            switch Self.plan(p) {
            case .full:
                let r = await CrossServer.withTimeout(p.id == activeID ? 300 : 180, { await pl.refresh(p, showSpinner: false) }) ?? false
                if r { CrossServer.shared.serversRefreshed([p.id]) } else { ok = false }
            case .epg:
                let r = await CrossServer.withTimeout(120, { await pl.refreshGuide(p) }) ?? false
                if !r { ok = false }
            case .none, .blocked:
                continue
            }
        }
        return ok
    }

    // MARK: achtergrond (iOS/iPadOS)

    #if os(iOS)
    /// Eén keer bij het starten (vóór het einde van `didFinishLaunching`)
    nonisolated static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: guideTaskID, using: nil) { task in
            Task { @MainActor in AutoRefresh179.shared.handle(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: fullTaskID, using: nil) { task in
            Task { @MainActor in AutoRefresh179.shared.handle(task) }
        }
    }

    private func handle(_ task: BGTask) {
        guard let pl = playlists, !running else { task.setTaskCompleted(success: false); scheduleBackground(); return }
        running = true
        let work = Task { @MainActor in
            let ok = await self.run(pl, background: true)
            self.running = false
            self.scheduleBackground()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleBackground() {
        let all = CloudStore.shared.playlists
        guard !all.isEmpty, !Screenshots.isActive else { return }
        let now = Date().timeIntervalSince1970
        var next = now + 86400
        var needsFull = false
        for s in all {
            next = min(next, Build179.nextDue(catalog: Self.catalog, epg: Self.epg, lastFull: Self.lastFull(s),
                                              lastEpg: Self.lastEpg(s), now: now))
            if let i = Build179.CatalogInterval.from(Self.catalog).seconds, let lf = Self.lastFull(s) {
                if lf + i - now < 3 * 3600 { needsFull = true }
            }
        }
        let guide = BGAppRefreshTaskRequest(identifier: Self.guideTaskID)
        guide.earliestBeginDate = Date(timeIntervalSince1970: next)
        try? BGTaskScheduler.shared.submit(guide)
        if needsFull || Build179.CatalogInterval.from(Self.catalog) != .manual {
            let full = BGProcessingTaskRequest(identifier: Self.fullTaskID)
            full.requiresNetworkConnectivity = true
            full.requiresExternalPower = false
            full.earliestBeginDate = Date(timeIntervalSince1970: next)
            try? BGTaskScheduler.shared.submit(full)
        }
    }
    #else
    func scheduleBackground() {}
    #endif
}

// MARK: - 13. Titels opruimen die de aanbieder verwijderd heeft

/// Wat er van een server bekend was vóór een volledige verversing (alleen id's en tellingen, buiten de hoofdthread)
struct CatalogIDs179: Sendable {
    var movies: Set<String> = []
    var series: Set<String> = []
    var count: Int { movies.count + series.count }

    init() {}
    init(_ lib: Library) {
        movies = Set(lib.movies.map(\.id))
        series = Set(lib.series.map(\.id))
        for r in lib.skipped?.rows ?? [] {
            if r.k == .movie { movies.insert(r.i) } else if r.k == .series { series.insert(r.i) }
        }
    }
}

/// Om een titel op een andere server te vinden: TMDB-id, anders genormaliseerde titel + jaar + soort
struct TitleRef179: Sendable {
    var kind: String
    var title: String
    var year: Int?
    var tmdb: Int?
    var matchKey: String { "\(kind)|\(PlaylistService.normTitle(TitleCleaner.parse(title).title))|\(year.map(String.init) ?? "")" }
}

@MainActor
enum Cleanup179 {
    /// Na een volledige, geslaagde verversing van server `s`: verwijzingen in Verder kijken, Mijn lijst en de
    /// metadata van downloads opruimen of naar een andere server laten wijzen. Geeft het aantal titels terug.
    @discardableResult
    static func run(server s: PlaylistSource, old: CatalogIDs179, oldLib: [String: TitleRef179], new: Library,
                    complete: Bool) async -> Int {
        let newIDs = await Task.detached(priority: .utility) { CatalogIDs179(new) }.value
        guard Build179.cleanupAllowed(old: old.count, new: newIDs.count, complete: complete) else { return 0 }
        let gone = old.movies.subtracting(newIDs.movies).union(old.series.subtracting(newIDs.series))
        guard !gone.isEmpty else { return 0 }
        let store = CloudStore.shared
        // welke verwijzingen raken het?
        var refs = Set<String>()
        let sid = s.id
        for k in store.myList {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, UUID(uuidString: parts[0]) == sid, gone.contains(parts[1]) else { continue }
            refs.insert(parts[1])
        }
        for (k, e) in store.progress where e.playlistID == sid && gone.contains(k) { refs.insert(k) }
        #if os(iOS)
        for d in DownloadManager.shared.items where d.sourceID == sid {
            if gone.contains(d.itemID) { refs.insert(d.itemID) }
            if let ser = d.seriesID, gone.contains(ser) { refs.insert(ser) }
        }
        #endif
        guard !refs.isEmpty else { return 0 }
        // op een andere server zoeken (alleen als er iets te verplaatsen valt)
        let others = store.playlists.filter { $0.id != sid }
        let wanted = refs.compactMap { id in oldLib[id].map { (id, $0) } }
        let found: [String: (UUID, String)] = await Task.detached(priority: .utility) {
            var out: [String: (UUID, String)] = [:]
            guard !wanted.isEmpty else { return out }
            for o in others {
                guard let lib = PlaylistService.readCache(o) else { continue }
                var byTMDB: [String: String] = [:], byKey: [String: String] = [:]
                for m in lib.movies {
                    if let t = m.tmdbID { byTMDB["movie|\(t)"] = m.id }
                    byKey[TitleRef179(kind: "movie", title: m.title, year: m.year).matchKey] = m.id
                }
                for x in lib.series {
                    if let t = x.tmdbID { byTMDB["series|\(t)"] = x.id }
                    byKey[TitleRef179(kind: "series", title: x.title, year: x.year).matchKey] = x.id
                }
                for (id, r) in wanted where out[id] == nil {
                    if let t = r.tmdb, let hit = byTMDB["\(r.kind)|\(t)"] { out[id] = (o.id, hit) }
                    else if let hit = byKey[r.matchKey] { out[id] = (o.id, hit) }
                }
            }
            return out
        }.value
        var count = 0
        for id in refs {
            let target = found[id]
            switch Build179.cleanupAction(present: false, elsewhere: target != nil) {
            case .keep: continue
            case .remap, .remove: count += 1
            }
            // Mijn lijst
            if store.inMyList(sid, id) {
                store.setMyList(sid, id, false)
                if let t = target { store.setMyList(t.0, t.1, true) }
            }
            // Verder kijken
            if var e = store.progress[id], e.playlistID == sid {
                store.clearProgress(id)
                if let t = target {
                    e.playlistID = t.0
                    store.setProgress(t.1, e)
                }
            }
        }
        #if os(iOS)
        DownloadManager.shared.relink179(server: sid, gone: refs, to: found)
        #endif
        return count
    }

    /// Titel-informatie van de oude lijst voor de verwijzingen (voor het zoeken op een andere server)
    nonisolated static func refs(_ lib: Library) -> [String: TitleRef179] {
        var out: [String: TitleRef179] = [:]
        for m in lib.movies { out[m.id] = TitleRef179(kind: "movie", title: m.title, year: m.year, tmdb: m.tmdbID) }
        for s in lib.series { out[s.id] = TitleRef179(kind: "series", title: s.title, year: s.year, tmdb: s.tmdbID) }
        return out
    }
}

// MARK: - 2. Live Activity bij live tv (instelling per apparaat; de activiteit zelf alleen op iPhone/iPad)

enum LiveTVSettings179 {
    static let liveActivityKey = "liveActivity.tv"
    static var liveActivityEnabled: Bool { UserDefaults.standard.object(forKey: liveActivityKey) as? Bool ?? true }
}
