import Foundation
import Combine

/// Laadt, cachet en presenteert de inhoud van de gekozen afspeellijst.
/// `library` is de inhoud na jouw aanpassingen (hernoemd, verborgen, volgorde,
/// samengevoegd) en zonder groepen die op kinderslot staan.
@MainActor
final class PlaylistService: ObservableObject {
    @Published private(set) var source: PlaylistSource?
    @Published private(set) var library = Library()
    @Published private(set) var rawLibrary = Library()
    @Published private(set) var isLoading = false
    @Published private(set) var loadingText = ""
    @Published var error: String?
    @Published private(set) var episodeCache: [String: [Episode]] = [:]

    private var stalker: StalkerClient?
    private var stremioAddons: [StremioClient.Addon] = []
    private var bag = Set<AnyCancellable>()

    init() {
        // aanpassingen of kinderslot gewijzigd (ook via iCloud) → opnieuw toepassen
        CloudStore.shared.$customizations.combineLatest(CloudStore.shared.$parental)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyCustomizations() }
            .store(in: &bag)
        ParentalControl.shared.$unlockedUntil
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyCustomizations() }
            .store(in: &bag)
    }

    // MARK: laden

    func select(_ s: PlaylistSource, forceRefresh: Bool = false) async {
        source = s
        stalker = s.kind == .stalker ? StalkerClient(source: s) : nil
        episodeCache = [:]
        error = nil

        if !forceRefresh, let cached = Self.readCache(s) {
            setRaw(cached)
            if !RefreshPolicy.current.isDue(age: cacheAge(s)) { return }
            Task { await refresh(s, showSpinner: false) }
            return
        }
        setRaw(Library())
        await refresh(s, showSpinner: true)
    }

    func refresh(_ s: PlaylistSource, showSpinner: Bool) async {
        if showSpinner { isLoading = true }
        defer { isLoading = false; loadingText = "" }
        do {
            var lib: Library
            let password = Keychain.get(s.passwordKey) ?? ""
            switch s.kind {
            case .m3u:
                loadingText = L("Downloading playlist…")
                guard let u = s.m3uURL.urlValue else { throw HTTPError.badURL }
                let data = try await HTTP.get(u)
                loadingText = L("Sorting channels and movies…")
                let text = String(decoding: data, as: UTF8.self)
                let pid = s.id
                lib = await Task.detached(priority: .userInitiated) { M3UParser.library(from: text, playlistID: pid) }.value
                let epg = s.epgURL.urlValue ?? M3UParser.epgURL(fromHeader: text)
                if let epg { loadingText = L("Loading TV guide…"); lib.epg = await loadEPG(epg) }
            case .xtream:
                loadingText = L("Signing in to server…")
                let x = XtreamClient(source: s, password: password)
                try await x.authenticate()
                loadingText = L("Fetching live TV, movies and series…")
                lib = try await x.library(playlistID: s.id)
                let epg = s.epgURL.urlValue ?? x.xmltvURL
                if let epg { loadingText = L("Loading TV guide…"); lib.epg = await loadEPG(epg) }
            case .stalker:
                loadingText = L("Connecting to portal…")
                let st = (source?.id == s.id ? stalker : nil) ?? StalkerClient(source: s)
                try await st.connect()
                loadingText = L("Fetching channels and videos…")
                lib = try await st.library()
                if let epg = s.epgURL.urlValue { lib.epg = await loadEPG(epg) }
            case .jellyfin, .emby:
                loadingText = L("Fetching your library…")
                let jf = JellyfinClient(source: s, session: Self.session(s))
                lib = try await jf.library()
            case .plex:
                loadingText = L("Fetching your library…")
                guard var session = Self.session(s) else { throw MediaError.notLoggedIn }
                // server-adres kan veranderen: bij fout opnieuw zoeken
                do { lib = try await PlexClient(session: session).library() }
                catch {
                    guard let userToken = Keychain.get(s.passwordKey) else { throw error }
                    session = try await PlexClient.discoverServer(userToken: userToken)
                    Keychain.setCodable(session, for: Self.sessionKey(s))
                    lib = try await PlexClient(session: session).library()
                }
            case .stremio:
                loadingText = L("Loading Stremio add-ons…")
                let addons = await Self.stremioAddons(s)
                if source?.id == s.id { stremioAddons = addons }
                loadingText = L("Fetching catalogs…")
                lib = await StremioClient(addons: addons).library()
            }
            if source?.id == s.id {
                setRaw(lib)
                writeCache(s, lib)
                SplashPosters.save(from: lib)
            } else {
                writeCache(s, lib)     // andere afspeellijst op de achtergrond ververst
            }
        } catch {
            guard source?.id == s.id else { return }
            if rawLibrary.channels.isEmpty && rawLibrary.movies.isEmpty && rawLibrary.series.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    /// Bij terugkeren in de app: verversen als het volgens de instelling tijd is.
    func refreshIfDue() async {
        guard let s = source, !isLoading, RefreshPolicy.current.isDue(age: cacheAge(s)),
              RefreshPolicy.current != .manual else { return }
        await refresh(s, showSpinner: false)
    }

    /// Alle afspeellijsten op de achtergrond verversen.
    @Published private(set) var refreshingAll = false
    func refreshAll() async {
        refreshingAll = true
        defer { refreshingAll = false }
        for p in CloudStore.shared.playlists { await refresh(p, showSpinner: false) }
    }

    private func loadEPG(_ url: URL) async -> [String: [EPGProgram]] {
        guard let d = try? await HTTP.get(url) else { return [:] }
        return await Task.detached(priority: .utility) { XMLTVParser.parse(d) }.value
    }

    // MARK: sessies (Plex / Jellyfin / Emby / Stremio)

    static func sessionKey(_ s: PlaylistSource) -> String { "playlist.\(s.id.uuidString).session" }
    static func session(_ s: PlaylistSource) -> MediaSession? { Keychain.getCodable(MediaSession.self, sessionKey(s)) }

    static func stremioAddons(_ s: PlaylistSource) async -> [StremioClient.Addon] {
        var urls = s.m3uURL.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        if let key = Keychain.get(s.passwordKey), !key.isEmpty, let acct = try? await StremioClient.accountAddons(authKey: key) {
            urls = acct + urls
        }
        if !urls.contains(where: { $0.contains("cinemeta") }) { urls.insert(StremioClient.cinemeta, at: 0) }
        var out: [StremioClient.Addon] = []
        for u in orderedUnique(urls) { if let a = await StremioClient.loadAddon(u) { out.append(a) } }
        return out
    }

    // MARK: aanpassingen toepassen

    private func setRaw(_ lib: Library) {
        rawLibrary = lib
        applyCustomizations()
    }

    func applyCustomizations() {
        guard let s = source else { library = rawLibrary; return }
        library = Self.apply(rawLibrary, CloudStore.shared.customization(s.id), playlist: s.id)
    }

    static func apply(_ raw: Library, _ c: Customization, playlist: UUID) -> Library {
        let parental = ParentalControl.shared
        func group(_ g: String) -> String {
            let merged = c.merged[g] ?? g
            return c.renamed[Customization.groupKey(merged)] ?? merged
        }
        func visible(_ id: String, _ g: String) -> Bool {
            !c.hidden.contains(id) && !c.hidden.contains(Customization.groupKey(g))
                && !c.hidden.contains(Customization.groupKey(c.merged[g] ?? g))
                && !parental.isLocked(playlist: playlist, group: g)
                && !parental.isLocked(playlist: playlist, group: c.merged[g] ?? g)
        }
        var lib = raw
        lib.channels = raw.channels.filter { visible($0.id, $0.group) }.map { ch in
            var x = ch; x.group = group(ch.group); x.name = c.renamed[ch.id] ?? ch.name; return x
        }
        lib.movies = raw.movies.filter { visible($0.id, $0.group) }.map { m in
            var x = m; x.group = group(m.group); x.title = c.renamed[m.id] ?? m.title; return x
        }
        lib.series = raw.series.filter { visible($0.id, $0.group) }.map { se in
            var x = se; x.group = group(se.group); x.title = c.renamed[se.id] ?? se.title; return x
        }
        // eigen volgorde: groepen, dan kanalen binnen een groep
        if !c.groupOrder.isEmpty || !c.channelOrder.isEmpty {
            let gIndex = Dictionary(c.groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let natural = Dictionary(orderedUnique(lib.channels.map(\.group)).enumerated().map { ($1, $0 + 10_000) },
                                     uniquingKeysWith: { a, _ in a })
            var cIndex: [String: Int] = [:]
            for (_, ids) in c.channelOrder { for (i, id) in ids.enumerated() { cIndex[id] = i } }
            let original = Dictionary(lib.channels.enumerated().map { ($1.id, $0 + 100_000) }, uniquingKeysWith: { a, _ in a })
            lib.channels.sort { a, b in
                let ga = gIndex[a.group] ?? natural[a.group] ?? 0, gb = gIndex[b.group] ?? natural[b.group] ?? 0
                if ga != gb { return ga < gb }
                return (cIndex[a.id] ?? original[a.id] ?? 0) < (cIndex[b.id] ?? original[b.id] ?? 0)
            }
        }
        return lib
    }

    // MARK: details

    func episodes(for series: Series) async -> [Episode] {
        if !series.episodes.isEmpty { return series.episodes }
        if let c = episodeCache[series.id] { return c }
        guard let s = source else { return [] }
        var eps: [Episode] = []
        switch s.kind {
        case .xtream:
            eps = (try? await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").episodes(for: series)) ?? []
        case .jellyfin, .emby:
            eps = (try? await JellyfinClient(source: s, session: Self.session(s)).episodes(series)) ?? []
        case .plex:
            if let session = Self.session(s) { eps = (try? await PlexClient(session: session).episodes(series)) ?? [] }
        case .stremio:
            if stremioAddons.isEmpty { stremioAddons = await Self.stremioAddons(s) }
            eps = (try? await StremioClient(addons: stremioAddons).episodes(series)) ?? []
        default: break
        }
        episodeCache[series.id] = eps
        return eps
    }

    func xtreamSeriesInfo(_ series: Series) async -> XtreamClient.SeriesInfo? {
        guard let s = source, s.kind == .xtream, let id = series.xtreamSeriesID else { return nil }
        return await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").seriesInfo(id)
    }

    func xtreamVodInfo(_ m: Movie) async -> XtreamClient.VodInfo.Info? {
        guard let s = source, s.kind == .xtream, let id = m.xtreamVodID else { return nil }
        return await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").vodInfo(id)
    }

    /// Stremio: alle beschikbare streams voor een titel.
    func stremioStreams(_ item: PlayableItem) async -> [StremioClient.Stream] {
        guard let ref = item.stremio, let s = source else { return [] }
        if stremioAddons.isEmpty { stremioAddons = await Self.stremioAddons(s) }
        let parts = ref.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        return await StremioClient(addons: stremioAddons).streams(type: parts[0], id: parts[1])
    }

    /// Geeft de echte afspeel-URL (Stalker maakt per keer een link aan, Stremio zoekt een stream).
    func resolve(_ item: PlayableItem) async -> URL? {
        if let u = item.url { if item.stalkerCmd == nil { return u } }
        if let cmd = item.stalkerCmd, let st = stalker {
            return (try? await st.createLink(cmd: cmd, type: item.type == .live ? .live : .movie)) ?? item.url
        }
        if item.stremio != nil { return await stremioStreams(item).first?.url }
        return item.url
    }

    func catchupURL(_ c: Channel, _ p: EPGProgram) -> URL? {
        catchupURL(channelID: c.id, start: p.start, end: p.end)
    }

    /// Terugkijken / timeshift vanaf een willekeurig moment (Xtream).
    func catchupURL(channelID: String, start: Date, end: Date) -> URL? {
        guard let s = source, s.kind == .xtream,
              let ch = rawLibrary.channels.first(where: { $0.id == channelID }), ch.catchupDays > 0 else { return nil }
        let p = EPGProgram(channelID: channelID, title: "", start: start, end: end)
        return XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").catchupURL(channel: ch, program: p)
    }

    func shortEPG(_ c: Channel) async -> [EPGProgram] {
        if let s = stalker, library.epg[c.epgID ?? c.id] == nil {
            let p = await s.shortEPG(channelID: c.id)
            if !p.isEmpty { rawLibrary.epg[c.id] = p; library.epg[c.id] = p }
            return p
        }
        return library.upcoming(c, count: 10)
    }

    // MARK: zoeken

    struct SearchResults {
        var channels: [Channel] = []; var movies: [Movie] = []; var series: [Series] = []
        var other: [OtherHit] = []
        var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty && other.isEmpty }
    }

    /// Treffer in een andere afspeellijst.
    struct OtherHit: Identifiable, Hashable {
        var id: String { "\(playlist.id)-\(itemID)" }
        var playlist: PlaylistSource
        var itemID: String
        var title: String
        var subtitle: String
        var artwork: URL?
    }

    nonisolated static func normTitle(_ t: String) -> String { fold(t).filter { $0.isLetter || $0.isNumber } }
    nonisolated static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    func search(_ q: String, allPlaylists: Bool = true) async -> SearchResults {
        let t = Self.fold(q.trimmingCharacters(in: .whitespaces))
        guard t.count >= 2 else { return SearchResults() }
        func m(_ s: String) -> Bool { Self.fold(s).contains(t) }
        var r = SearchResults(channels: Array(library.channels.filter { m($0.name) }.prefix(40)),
                              movies: Array(library.movies.filter { m($0.title) }.prefix(60)),
                              series: Array(library.series.filter { m($0.title) }.prefix(60)))
        guard allPlaylists else { return r }
        // zoeken in de cache van alle andere afspeellijsten
        let others = CloudStore.shared.playlists.filter { $0.id != source?.id }
        r.other = await Task.detached(priority: .userInitiated) {
            var hits: [OtherHit] = []
            for p in others {
                guard let lib = Self.readCache(p) else { continue }
                for c in lib.channels where Self.fold(c.name).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: c.id, title: c.name, subtitle: "Live TV", artwork: c.logo))
                    if hits.count > 80 { break }
                }
                for mv in lib.movies where Self.fold(mv.title).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: mv.id, title: mv.title, subtitle: mv.year.map(String.init) ?? "", artwork: mv.poster))
                }
                for se in lib.series where Self.fold(se.title).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: se.id, title: se.title, subtitle: se.year.map(String.init) ?? "", artwork: se.poster))
                }
            }
            return Array(hits.prefix(120))
        }.value
        return r
    }

    /// Dezelfde titel in andere groepen of andere afspeellijsten ("Andere bronnen").
    func otherSources(title: String, year: Int?, isShow: Bool, excluding id: String) async -> [OtherHit] {
        let norm = Self.normTitle(title)
        guard !norm.isEmpty else { return [] }
        let current = source
        let currentLib = rawLibrary
        let all = CloudStore.shared.playlists
        return await Task.detached(priority: .userInitiated) {
            var hits: [OtherHit] = []
            for p in all {
                let lib = (p.id == current?.id) ? currentLib : (Self.readCache(p) ?? Library())
                if isShow {
                    for s in lib.series where s.id != id && Self.normTitle(s.title) == norm && (year == nil || s.year == nil || s.year == year) {
                        hits.append(OtherHit(playlist: p, itemID: s.id, title: s.title, subtitle: s.group, artwork: s.poster))
                    }
                } else {
                    for m in lib.movies where m.id != id && Self.normTitle(m.title) == norm && (year == nil || m.year == nil || m.year == year) {
                        hits.append(OtherHit(playlist: p, itemID: m.id, title: m.title, subtitle: m.group, artwork: m.poster))
                    }
                }
            }
            return hits
        }.value
    }

    // MARK: cache

    nonisolated static func cacheURL(_ s: PlaylistSource) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-\(s.id.uuidString).json")
    }
    nonisolated static func readCache(_ s: PlaylistSource) -> Library? {
        guard let d = try? Data(contentsOf: cacheURL(s)) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: d)
    }
    private func cacheAge(_ s: PlaylistSource) -> TimeInterval? {
        let a = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL(s).path)
        return (a?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
    }
    private func writeCache(_ s: PlaylistSource, _ lib: Library) {
        let url = Self.cacheURL(s)
        Task.detached(priority: .background) {
            if let d = try? JSONEncoder().encode(lib) { try? d.write(to: url, options: .atomic) }
        }
    }
    func clearCache(_ s: PlaylistSource) { try? FileManager.default.removeItem(at: Self.cacheURL(s)) }
}

/// Hoe vaak afspeellijsten (incl. gids) automatisch ververst worden.
enum RefreshPolicy: String, CaseIterable, Identifiable {
    case manual, launch, sixHours, daily, weekly
    var id: String { rawValue }

    static var current: RefreshPolicy {
        RefreshPolicy(rawValue: UserDefaults.standard.string(forKey: "playlist.refresh") ?? "") ?? .daily
    }

    var title: String {
        switch self {
        case .manual: return L("Manually")
        case .launch: return L("Every time the app opens")
        case .sixHours: return L("Every 6 hours")
        case .daily: return L("Daily")
        case .weekly: return L("Weekly")
        }
    }

    func isDue(age: TimeInterval?) -> Bool {
        guard let age else { return true }
        switch self {
        case .manual: return false
        case .launch: return age > 60
        case .sixHours: return age > 6 * 3600
        case .daily: return age > 24 * 3600
        case .weekly: return age > 7 * 24 * 3600
        }
    }
}
