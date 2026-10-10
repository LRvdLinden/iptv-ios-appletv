import Foundation
import Combine

/// Laadt en cachet de inhoud van de gekozen afspeellijst.
@MainActor
final class PlaylistService: ObservableObject {
    @Published private(set) var source: PlaylistSource?
    @Published private(set) var library = Library()
    @Published private(set) var isLoading = false
    @Published private(set) var loadingText = ""
    @Published var error: String?
    @Published private(set) var episodeCache: [String: [Episode]] = [:]

    private var stalker: StalkerClient?

    // MARK: laden

    func select(_ s: PlaylistSource, forceRefresh: Bool = false) async {
        source = s
        stalker = s.kind == .stalker ? StalkerClient(source: s) : nil
        episodeCache = [:]
        error = nil

        if !forceRefresh, let cached = readCache(s) {
            library = cached
            // op de achtergrond verversen als de cache ouder is dan 12 uur
            if let age = cacheAge(s), age < 12 * 3600 { return }
            Task { await refresh(s, showSpinner: false) }
            return
        }
        library = Library()
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
                loadingText = "Afspeellijst downloaden…"
                guard let u = s.m3uURL.urlValue else { throw HTTPError.badURL }
                let data = try await HTTP.get(u)
                loadingText = "Kanalen en films indelen…"
                let text = String(decoding: data, as: UTF8.self)
                let pid = s.id
                lib = await Task.detached(priority: .userInitiated) { M3UParser.library(from: text, playlistID: pid) }.value
                let epg = s.epgURL.urlValue ?? M3UParser.epgURL(fromHeader: text)
                if let epg { lib.epg = await loadEPG(epg) }
            case .xtream:
                loadingText = "Inloggen bij server…"
                let x = XtreamClient(source: s, password: password)
                try await x.authenticate()
                loadingText = "Live TV, films en series ophalen…"
                lib = try await x.library(playlistID: s.id)
                let epg = s.epgURL.urlValue ?? x.xmltvURL
                if let epg { loadingText = "Gids laden…"; lib.epg = await loadEPG(epg) }
            case .stalker:
                loadingText = "Verbinden met portal…"
                guard let st = stalker else { return }
                try await st.connect()
                loadingText = "Zenders en video's ophalen…"
                lib = try await st.library()
                if let epg = s.epgURL.urlValue { lib.epg = await loadEPG(epg) }
            }
            if source?.id == s.id {
                library = lib
                writeCache(s, lib)
            }
        } catch {
            if library.channels.isEmpty && library.movies.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func loadEPG(_ url: URL) async -> [String: [EPGProgram]] {
        guard let d = try? await HTTP.get(url) else { return [:] }
        return await Task.detached(priority: .utility) { XMLTVParser.parse(d) }.value
    }

    // MARK: details

    func episodes(for series: Series) async -> [Episode] {
        if !series.episodes.isEmpty { return series.episodes }
        if let c = episodeCache[series.id] { return c }
        guard let s = source, s.kind == .xtream else { return [] }
        let x = XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "")
        let eps = (try? await x.episodes(for: series)) ?? []
        episodeCache[series.id] = eps
        return eps
    }

    func xtreamVodInfo(_ m: Movie) async -> XtreamClient.VodInfo.Info? {
        guard let s = source, s.kind == .xtream, let id = m.xtreamVodID else { return nil }
        return await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").vodInfo(id)
    }

    /// Geeft de echte afspeel-URL (Stalker maakt per keer een link aan).
    func resolve(_ item: PlayableItem) async -> URL? {
        if let cmd = item.stalkerCmd, let st = stalker {
            return (try? await st.createLink(cmd: cmd, type: item.type == .live ? .live : .movie)) ?? item.url
        }
        return item.url
    }

    func catchupURL(_ c: Channel, _ p: EPGProgram) -> URL? {
        guard let s = source, s.kind == .xtream else { return nil }
        return XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").catchupURL(channel: c, program: p)
    }

    func shortEPG(_ c: Channel) async -> [EPGProgram] {
        if let s = stalker, library.epg[c.epgID ?? c.id] == nil {
            let p = await s.shortEPG(channelID: c.id)
            if !p.isEmpty { library.epg[c.id] = p }
            return p
        }
        return library.upcoming(c, count: 10)
    }

    // MARK: zoeken

    struct SearchResults { var channels: [Channel] = []; var movies: [Movie] = []; var series: [Series] = [] }

    func search(_ q: String) -> SearchResults {
        let t = q.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard t.count >= 2 else { return SearchResults() }
        func m(_ s: String) -> Bool { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(t) }
        return SearchResults(channels: Array(library.channels.filter { m($0.name) }.prefix(40)),
                             movies: Array(library.movies.filter { m($0.title) }.prefix(60)),
                             series: Array(library.series.filter { m($0.title) }.prefix(60)))
    }

    // MARK: cache

    private func cacheURL(_ s: PlaylistSource) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-\(s.id.uuidString).json")
    }
    private func readCache(_ s: PlaylistSource) -> Library? {
        guard let d = try? Data(contentsOf: cacheURL(s)) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: d)
    }
    private func cacheAge(_ s: PlaylistSource) -> TimeInterval? {
        let a = try? FileManager.default.attributesOfItem(atPath: cacheURL(s).path)
        return (a?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
    }
    private func writeCache(_ s: PlaylistSource, _ lib: Library) {
        let url = cacheURL(s)
        Task.detached(priority: .background) {
            if let d = try? JSONEncoder().encode(lib) { try? d.write(to: url, options: .atomic) }
        }
    }
    func clearCache(_ s: PlaylistSource) { try? FileManager.default.removeItem(at: cacheURL(s)) }
}
