import Foundation
import Network

// Build 147: onderdelen van diagnose-schema 2 (docs/ACCOUNT.md, "Build 147"): verbinding, opslag en ophalen per server.

/// Verbinding: wifi, mobiel of ethernet (op Apple TV: ethernet of wifi). Vroeg gestart (`StartDiagnostics.start`).
final class NetworkType: @unchecked Sendable {
    static let shared = NetworkType()
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var type = "unknown"
    private var online: Bool?

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let t: String
            if path.status != .satisfied { t = "none" }
            else if path.usesInterfaceType(.wiredEthernet) { t = "ethernet" }
            else if path.usesInterfaceType(.wifi) { t = "wifi" }
            else if path.usesInterfaceType(.cellular) { t = "cellular" }
            else if path.usesInterfaceType(.other) || path.usesInterfaceType(.loopback) { t = "other" }
            else { t = "unknown" }
            self?.lock.lock(); self?.type = t; self?.online = path.status == .satisfied; self?.lock.unlock()
        }
        m.start(queue: DispatchQueue(label: "bingr.diag.network", qos: .utility))
        monitor = m
    }

    /// `wifi`, `cellular`, `ethernet`, `none`, `other` of `unknown`
    var current: String { lock.lock(); defer { lock.unlock() }; return type }
    var isOnline: Bool? { lock.lock(); defer { lock.unlock() }; return online }
}

/// Opslag van Bingr op dit apparaat: één totaal met cache, catalogus en downloads (samen het totaal), plus vrije ruimte.
/// De mappen worden buiten de hoofdthread doorlopen; de laatste uitkomst blijft bewaard voor elke diagnose.
@MainActor
final class StorageSnapshot {
    static let shared = StorageSnapshot()
    private(set) var last: StorageBreakdown.Result?
    private var task: Task<StorageBreakdown.Result, Never>?

    @discardableResult
    func refresh() async -> StorageBreakdown.Result {
        if let task { return await task.value }
        let t = Task.detached(priority: .utility) { () -> StorageBreakdown.Result in
            let fm = FileManager.default
            func bytes(_ dir: URL) -> Int64 {
                guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]) else { return 0 }
                var total: Int64 = 0
                for case let u as URL in e {
                    guard let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
                          v.isRegularFile == true else { continue }
                    total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                }
                return total
            }
            func size(_ u: URL) -> Int64 {
                Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])).flatMap { $0.totalFileAllocatedSize ?? $0.fileSize } ?? 0)
            }
            let caches = AppDirs.caches, support = AppDirs.support
            var app = bytes(caches) + bytes(fm.temporaryDirectory)
            if support.standardizedFileURL.path != caches.standardizedFileURL.path { app += bytes(support) }
            // catalogus: de bewaarde lijsten per server (library-*.json, catalog-*.json)
            var catalog: Int64 = 0
            for u in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
            where u.lastPathComponent.hasPrefix("library-") || u.lastPathComponent.hasPrefix("catalog-") {
                catalog += size(u)
            }
            #if os(iOS)
            let downloads = bytes(support.appendingPathComponent("Downloads", isDirectory: true))
            #else
            let downloads: Int64 = 0
            #endif
            var free: Int64?
            #if os(tvOS)
            if let v = try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]) { free = v.volumeAvailableCapacity.map(Int64.init) }
            #else
            if let v = try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
                free = v.volumeAvailableCapacityForImportantUsage ?? v.volumeAvailableCapacity.map(Int64.init)
            }
            #endif
            return StorageBreakdown.make(appBytes: app, catalogBytes: catalog, downloadBytes: downloads, freeBytes: free)
        }
        task = t
        let r = await t.value
        last = r
        task = nil
        return r
    }

    var json: [String: Any]? {
        guard let s = last else { return nil }
        var o: [String: Any] = ["totalMB": s.totalMB, "cacheMB": s.cacheMB, "catalogMB": s.catalogMB, "downloadsMB": s.downloadsMB]
        if let f = s.freeMB { o["freeMB"] = f }
        return o
    }
}

/// Build 148: wat er van één soort zichtbaar is en waarom de rest verborgen is
struct FetchVisibility: Codable, Equatable, Sendable { var visible: Int; var hidden: HiddenCounts.Counts }

/// Laatste uitkomst van het ophalen per server en soort (zenders, films, series), op het apparaat bewaard (zonder URL,
/// naam of tekst van de server). `PlaylistService.refresh` schrijft hem; de diagnose leest hem.
@MainActor
final class FetchLog {
    static let shared = FetchLog()
    private let key = "diag.fetch.v147"
    private var entries: [String: [FetchStatus.Entry]] = [:]
    /// Build 148: per server en soort wat de gebruiker ziet en waarom de rest verborgen is
    typealias Visibility = FetchVisibility
    private let visKey = "diag.visible.v148"
    private var visibility: [String: [String: Visibility]] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([String: [FetchStatus.Entry]].self, from: d) { entries = e }
        if let d = UserDefaults.standard.data(forKey: visKey),
           let v = try? JSONDecoder().decode([String: [String: Visibility]].self, from: d) { visibility = v }
    }

    /// Build 148: na het filteren: zichtbaar en verborgen per soort
    func noteVisibility(_ server: UUID, _ v: [FetchStatus.Kind: Visibility]) {
        var m: [String: Visibility] = [:]
        for (k, x) in v { m[k.rawValue] = x }
        guard visibility[server.uuidString] != m else { return }
        visibility[server.uuidString] = m
        let live = Set(CloudStore.shared.playlists.map(\.id.uuidString))
        for k in visibility.keys where !live.contains(k) { visibility[k] = nil }
        if let d = try? JSONEncoder().encode(visibility) { UserDefaults.standard.set(d, forKey: visKey) }
    }

    func note(_ server: UUID, _ list: [FetchStatus.Entry]) {
        entries[server.uuidString] = list
        let live = Set(CloudStore.shared.playlists.map(\.id.uuidString))
        for k in entries.keys where !live.contains(k) && k != server.uuidString { entries[k] = nil }
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Een volledige lijst ophalen (M3U, Stalker, mediaservers): elke soort met het aantal; mislukt = alle soorten.
    func noteLibrary(_ server: UUID, _ lib: Library?, error: Error? = nil) {
        let now = Date().timeIntervalSince1970
        if let lib {
            note(server, [.init(kind: .live, delivered: lib.channels.count, error: nil, at: now),
                          .init(kind: .movie, delivered: lib.movies.count, error: nil, at: now),
                          .init(kind: .series, delivered: lib.series.count, error: nil, at: now)])
        } else {
            let code = error.map(XtreamClient.fetchCode) ?? "error"
            note(server, FetchStatus.Kind.allCases.map { .init(kind: $0, delivered: nil, error: code, at: now) })
        }
    }

    func entries(for server: UUID) -> [FetchStatus.Entry]? { entries[server.uuidString] }

    /// `fetch` voor de bijlage: servers als s1, s2, … in de volgorde van de lijst. Zonder bewaarde uitkomst (lijst uit
    /// een oudere build) telt de bewaarde catalogus van de open server als geleverd.
    func rows(playlists: PlaylistService) -> [[String: Any]] {
        let servers = CloudStore.shared.playlists
        var all: [[FetchStatus.Entry]] = []
        var visible: [[FetchStatus.Kind: Int]] = []
        let now = Date().timeIntervalSince1970
        for s in servers {
            let active = s.id == playlists.source?.id
            var list = entries[s.id.uuidString] ?? []
            if list.isEmpty, active, !playlists.rawLibrary.isEmptyLibrary {
                let r = playlists.rawLibrary
                // build 151: met de niet ingelezen items uit verborgen categorieën
                list = [.init(kind: .live, delivered: SkippedCatalog.delivered(loaded: r.channels.count, r.skipped, .live), error: nil, at: now),
                        .init(kind: .movie, delivered: SkippedCatalog.delivered(loaded: r.movies.count, r.skipped, .movie), error: nil, at: now),
                        .init(kind: .series, delivered: SkippedCatalog.delivered(loaded: r.series.count, r.skipped, .series), error: nil, at: now)]
            }
            all.append(list)
            if active, !playlists.isFiltering {
                let l = playlists.library
                visible.append([.live: l.channels.count, .movie: l.movies.count, .series: l.series.count])
            } else {
                visible.append([:])
            }
        }
        var rows = FetchStatus.rows(servers: all, visible: visible)
        // build 148 (schema 3): geleverd, zichtbaar en de reden van het verschil
        for i in rows.indices {
            guard let srv = rows[i]["server"] as? String, let idx = Int(srv.dropFirst()), idx >= 1, idx <= servers.count,
                  let kind = rows[i]["kind"] as? String, rows[i]["status"] as? String != "failed",
                  let delivered = rows[i]["count"] as? Int else { continue }
            rows[i]["delivered"] = delivered
            guard let v = visibility[servers[idx - 1].id.uuidString]?[kind] else { continue }
            rows[i]["visible"] = min(v.visible, delivered)
            rows[i]["hidden"] = ["categories": v.hidden.categories, "kids": v.hidden.kids,
                                 "duplicates": v.hidden.duplicates, "other": v.hidden.other]
        }
        return rows
    }
}
