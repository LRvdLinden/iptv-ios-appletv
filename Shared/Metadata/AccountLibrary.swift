import Foundation

/// Build 140: de bibliotheek van alle servers van het account, met het filter van het actieve profiel per server
/// (kinderprofiel, leeftijdsgrens, verborgen categorieën). De open server komt uit het geheugen; de andere uit hun cache
/// op dit apparaat (gefilterd op de achtergrond en bewaard tot hun cache of de regels veranderen). Items van een andere
/// server krijgen `sourceID`, zodat openen en afspelen via die server gaat. Gebruikt door "Nieuw op Bingr" en "Voor jou".
@MainActor
final class AccountLibrary {
    static let shared = AccountLibrary()

    private struct Entry {
        var stamp: Date
        var ctx: PlaylistService.FilterContext
        var lib: Library
    }
    private var cache: [UUID: Entry] = [:]
    private var matcherSig = ""
    private var matcher: TitleMatcher?

    /// Build 141: één ronde tegelijk. Home, Films en Series vroegen dit tegelijk op (op Apple TV staan de tabbladen
    /// tegelijk open): dan werd de catalogus van elke andere server drie keer tegelijk ingelezen en gefilterd, wat op
    /// een Apple TV (weinig geheugen) bij grote servers tot een geheugenpiek en het stoppen van de app leidde.
    private var inFlight: Task<[(UUID, Library)], Never>?
    private var inFlightKey = ""
    private var matcherTask: Task<TitleMatcher?, Never>?

    /// Gefilterde bibliotheken van de andere servers (zonder gids), in de volgorde van de servers.
    func others(_ playlists: PlaylistService) async -> [(UUID, Library)] {
        guard !Screenshots.isActive else { return [] }
        let key = (playlists.source?.id.uuidString ?? "-") + "|" + CloudStore.shared.playlists.map(\.id.uuidString).joined(separator: ",")
            + "|" + (CloudStore.shared.activeProfileID?.uuidString ?? "")
        if let t = inFlight, inFlightKey == key { return await t.value }
        let t = Task { @MainActor in await self.load(playlists) }
        inFlight = t
        inFlightKey = key
        let r = await t.value
        if inFlightKey == key { inFlight = nil }
        return r
    }

    private func load(_ playlists: PlaylistService) async -> [(UUID, Library)] {
        #if os(tvOS)
        // build 143: Apple TV (weinig geheugen): de andere servers pas als de start voorbij is, niet tegelijk met het
        // inlezen van de open server
        let up = StartDiagnostics.shared.uptime
        if up < Self.tvSettle { try? await Task.sleep(nanoseconds: UInt64((Self.tvSettle - up) * 1_000_000_000)) }
        #endif
        let activeID = playlists.source?.id
        let sources = CloudStore.shared.playlists.filter { $0.id != activeID }
        var out: [(UUID, Library)] = []
        var keep = Set<UUID>()
        for s in sources {
            keep.insert(s.id)
            let ctx = playlists.context(for: s)
            let stamp = await Task.detached(priority: .utility) { PlaylistService.catalogStamp(s) }.value
            guard let stamp else { continue }
            if let e = cache[s.id], e.stamp == stamp, e.ctx.sameRules(as: ctx) {
                out.append((s.id, e.lib))
                continue
            }
            let sid = s.id
            let lib: Library? = await Task.detached(priority: .utility) { () -> Library? in
                guard let (raw, _) = PlaylistService.readAnyCatalog(s) else { return nil }
                var l = PlaylistService.apply(raw, ctx)
                l.epg = [:]
                l.channels = []
                // build 141: alleen wat de rijen nodig hebben (geen beschrijving, geen afleveringen): op een Apple TV
                // met grote servers liep het geheugen anders zo op dat tvOS de app stopte. Afleveringen en details haalt
                // de detailpagina zelf op bij die server (`PlaylistService.episodes(for:)`).
                l.movies = l.movies.map { var m = $0; m.sourceID = sid; m.plot = nil; return m }
                l.series = l.series.map { var x = $0; x.sourceID = sid; x.plot = nil; x.episodes = []; return x }
                #if os(tvOS)
                // build 143: Apple TV: per andere server alleen de nieuwste titels (genoeg voor Nieuw op Bingr en Voor jou)
                l.movies = AccountLibrary.newest(l.movies, AccountLibrary.tvMovies) { $0.addedAt }
                l.series = AccountLibrary.newest(l.series, AccountLibrary.tvSeries) { $0.addedAt }
                #endif
                return l
            }.value
            guard let lib else { continue }
            cache[s.id] = Entry(stamp: stamp, ctx: ctx, lib: lib)
            out.append((s.id, lib))
        }
        for id in cache.keys where !keep.contains(id) { cache[id] = nil }
        return out
    }

    /// Build 143 (Apple TV): wachten tot zoveel seconden na de start, en zoveel titels per andere server
    nonisolated static var tvSettle: TimeInterval { SmokeTest.isActive ? 15 : 30 }
    nonisolated static let tvMovies = 3000, tvSeries = 1500

    /// De nieuwste `n` (op toevoegdatum; zonder datum in de volgorde van de server), de rest weg.
    nonisolated static func newest<T>(_ xs: [T], _ n: Int, _ date: (T) -> Date?) -> [T] {
        guard xs.count > n else { return xs }
        let withDate = xs.enumerated().map { ($0.offset, date($0.element)) }
        let keep = withDate.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?): return x != y ? x > y : a.0 < b.0
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0 < b.0
            }
        }.prefix(n).map(\.0).sorted()
        return keep.map { xs[$0] }
    }

    /// Titel-index van de andere servers samen (voor aanbevelingen die niet op de open server staan).
    func othersMatcher(_ libs: [(UUID, Library)]) async -> TitleMatcher? {
        guard !libs.isEmpty else { return nil }
        let sig = libs.map { "\($0.0.uuidString):\($0.1.movies.count):\($0.1.series.count)" }.joined(separator: ",")
        if sig == matcherSig, let matcher { return matcher }
        // build 141: één opbouw tegelijk (zie `others`)
        if let t = matcherTask, matcherSig == sig { return await t.value }
        matcherSig = sig
        matcher = nil
        let t = Task.detached(priority: .utility) { () -> TitleMatcher? in
            TitleMatcher(movies: libs.flatMap { $0.1.movies }, series: libs.flatMap { $0.1.series })
        }
        matcherTask = t
        let m = await t.value
        if matcherSig == sig { matcher = m; matcherTask = nil }
        return m
    }
}

/// Build 140: "Nieuw op Bingr": de titels die het laatst aan de bibliotheek (alle servers) zijn toegevoegd, nieuwste
/// eerst. Volgorde: de toevoegdatum van de provider (Xtream `added`, Plex/Jellyfin/Emby), anders het moment waarop dit
/// apparaat de titel voor het eerst zag (`FirstSeen`, lokaal bewaard). Tot build 139 was dit een TMDB-lijst van titels
/// die de laatste 90/120 dagen nieuw waren op streamingdiensten in je regio, gekoppeld aan je bibliotheek.
@MainActor
final class NewOnBingr {
    static let shared = NewOnBingr()
    nonisolated static let limit = 30

    /// Per server: sleutel ("m|<id>" / "s|<id>") → eerste keer gezien (0 = was er al bij de eerste keer)
    private var firstSeen: [String: [String: Double]] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    nonisolated private static var fileURL: URL {
        let dir = AppDirs.support
        return dir.appendingPathComponent("firstseen.v140.json")
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL
        let d: [String: [String: Double]]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        }.value
        if let d { for (k, v) in d where firstSeen[k] == nil { firstSeen[k] = v } }
    }

    private func save() {
        saveTask?.cancel()
        let snapshot = firstSeen, url = Self.fileURL
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let d = try? JSONEncoder().encode(snapshot) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }

    /// De titels voor de rij (en het billboard): `active` = de (gefilterde) bibliotheek van de open server.
    func titles(active: Library, activeID: UUID?, others: [(UUID, Library)]) async -> [DetailTarget] {
        guard !Screenshots.isActive else { return [] }
        await load()
        var all: [(UUID?, Library)] = [(activeID, active)]
        all += others.map { (Optional($0.0), $0.1) }
        // eerste keer gezien bijwerken, alleen voor titels zonder datum van de provider
        var changed = false
        var stamps: [String: [String: Double]] = [:]
        let now = Date().timeIntervalSince1970
        for (sid, lib) in all {
            guard let sid else { continue }
            let k = sid.uuidString
            let ids = lib.movies.filter { $0.addedAt == nil }.map { "m|" + $0.id }
                + lib.series.filter { $0.addedAt == nil }.map { "s|" + $0.id }
            let seeded = firstSeen[k] != nil
            var known = firstSeen[k] ?? [:]
            if FirstSeen.update(&known, ids: ids, now: now, seeded: seeded) || !seeded {
                firstSeen[k] = known
                changed = true
            }
            stamps[k] = known
        }
        // servers die er niet meer zijn: weg
        let live = Set(CloudStore.shared.playlists.map(\.id.uuidString))
        for k in firstSeen.keys where !live.contains(k) { firstSeen[k] = nil; changed = true }
        if changed { save() }

        let snapshot = all
        let seenStamps = stamps
        return await Task.detached(priority: .utility) { () -> [DetailTarget] in
            var byKey: [String: DetailTarget] = [:]
            var items: [(id: String, provider: Double?)] = []
            var seen: [String: Double] = [:]
            for (sid, lib) in snapshot {
                let s = sid?.uuidString ?? "-"
                let fs = seenStamps[s] ?? [:]
                for m in lib.movies {
                    let key = s + "|m|" + m.id
                    byKey[key] = .movie(m)
                    items.append((key, m.addedAt?.timeIntervalSince1970))
                    if let t = fs["m|" + m.id] { seen[key] = t }
                }
                for x in lib.series {
                    let key = s + "|s|" + x.id
                    byKey[key] = .series(x)
                    items.append((key, x.addedAt?.timeIntervalSince1970))
                    if let t = fs["s|" + x.id] { seen[key] = t }
                }
            }
            // ruim kiezen; daarna dezelfde titel op twee servers één keer
            let ordered = FirstSeen.newest(items, firstSeen: seen, limit: Self.limit * 4)
            var out: [DetailTarget] = []
            var works = Set<String>()
            for key in ordered {
                guard let t = byKey[key], t.posterURL != nil else { continue }
                let w: String
                switch t {
                case .movie(let m): w = CatalogIdentity.title(kind: .movie, title: m.title, year: m.year, tmdb: m.tmdbID)
                case .series(let x): w = CatalogIdentity.title(kind: .series, title: x.title, year: x.year, tmdb: x.tmdbID)
                }
                guard works.insert(w).inserted else { continue }
                out.append(t)
                if out.count >= Self.limit { break }
            }
            return out
        }.value
    }
}

extension DetailTarget {
    /// Build 140: poster van de titel (zoals de bron hem levert)
    var posterURL: URL? { switch self { case .movie(let m): return m.poster; case .series(let s): return s.poster } }
}
