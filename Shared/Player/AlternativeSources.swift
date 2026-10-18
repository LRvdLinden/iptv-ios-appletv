import Foundation

/// Dezelfde zender of titel op een andere server of als andere zender in dezelfde lijst (build 52):
/// back-upbron voor live TV en "Andere bron" bij een afspeelfout.
struct AlternativeSource: Identifiable, Hashable {
    var id: String { "\(source.id.uuidString)|\(itemID)|\(season ?? -1)-\(episode ?? -1)" }
    var source: PlaylistSource
    var itemID: String
    var name: String
    /// Waarom dit een treffer is (zelfde EPG-ID weegt zwaarder dan alleen de naam)
    var byEPG: Bool
    var url: URL?
    var stalkerCmd: String?
    var logo: URL?
    var channel: Channel?
    var season: Int?
    var episode: Int?
    /// In de bron die nu open is (anders een andere server)
    var isCurrentSource: Bool
}

enum AlternativeSources {
    // MARK: zender-index (alleen zenders; wordt per bron één keer ingelezen)

    private final class Index: @unchecked Sendable {
        let lock = NSLock()
        var channels: [UUID: (stamp: Date, list: [Channel])] = [:]
    }
    private static let index = Index()

    /// Zenders van een bron uit de cache (opnieuw ingelezen als de lijst intussen ververst is).
    nonisolated static func cachedChannels(_ p: PlaylistSource) -> [Channel] {
        let url = PlaylistService.cacheURL(p)
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        index.lock.lock()
        if let hit = index.channels[p.id], hit.stamp == stamp { index.lock.unlock(); return hit.list }
        index.lock.unlock()
        let list = PlaylistService.readCache(p)?.channels ?? []
        index.lock.lock(); index.channels[p.id] = (stamp, list); index.lock.unlock()
        return list
    }

    // MARK: naam vergelijken

    private static let qualityTags: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "8k", "hq", "lq", "hdr", "hevc", "h264", "h265", "x264", "x265",
        "1080", "1080p", "1080i", "720", "720p", "576p", "2160p", "50fps", "60fps", "fps", "raw", "backup", "vip", "multi", "plus"
    ]
    private static let countryCodes: Set<String> = [
        "nl", "be", "de", "uk", "gb", "us", "fr", "es", "it", "pt", "tr", "pl", "ar", "ca", "au", "ie", "at", "ch",
        "dk", "se", "no", "fi", "ru", "ro", "gr", "al", "rs", "hr", "ba", "ex", "yu", "vl", "fl", "int", "eu"
    ]

    /// "NL: NPO 1 FHD", "|NL| NPO1 HD", "NPO 1 (4K)" → "npo1"
    nonisolated static func normalizedName(_ raw: String) -> String {
        var s = PlaylistService.fold(raw)
        // landcode/prefix vooraan: "NL:", "NL |", "|NL|", "[NL]", "NL -"
        if let r = s.range(of: #"^\s*[\[\(|]?\s*[a-z]{2,3}\s*[\]\)|:\-]+\s*"#, options: .regularExpression) {
            let code = s[r].filter { $0.isLetter }
            if countryCodes.contains(String(code)) { s.removeSubrange(r) }
        }
        // haakjes en scheidingstekens → spaties
        let cleaned = s.map { $0.isLetter || $0.isNumber || $0 == "+" ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
            .filter { !qualityTags.contains($0) }
        // een losse landcode achteraan ("Discovery NL")
        var w = words
        if w.count > 1, let last = w.last, countryCodes.contains(last) { w.removeLast() }
        return w.joined()
    }

    // MARK: live

    /// Treffers voor een zender: eerst zelfde EPG-ID, daarna zelfde genormaliseerde naam.
    /// Andere servers van het account (build 130: voor elk profiel, zoals "Andere bronnen" op de detailpagina).
    @MainActor
    static func liveMatches(for channelID: String, playlists: PlaylistService) async -> [AlternativeSource] {
        let lib = playlists.library
        guard let current = playlists.source,
              let ch = lib.channels.first(where: { $0.id == channelID }) ?? playlists.rawLibrary.channels.first(where: { $0.id == channelID })
        else { return [] }
        let store = CloudStore.shared
        let others = store.playlists.filter { $0.id != current.id }   // build 130: voor elk profiel
        // build 130: met het filter van het profiel per server (kinderslot, leeftijd, verborgen categorieën)
        let filters = Dictionary(uniqueKeysWithValues: others.map { ($0.id, playlists.context(for: $0)) })
        let currentChannels = lib.channels
        let epg = ch.epgID?.lowercased().trimmingCharacters(in: .whitespaces)
        let name = normalizedName(ch.name)
        return await Task.detached(priority: .userInitiated) {
            var hits: [AlternativeSource] = []
            func scan(_ p: PlaylistSource, _ list: [Channel], isCurrent: Bool) {
                for c in list where !(isCurrent && c.id == ch.id) {
                    let sameEPG = epg.map { !$0.isEmpty && c.epgID?.lowercased().trimmingCharacters(in: .whitespaces) == $0 } ?? false
                    guard sameEPG || (!name.isEmpty && normalizedName(c.name) == name) else { continue }
                    // een andere server via een MAC-portal kan alleen met een eigen sessie: overslaan
                    if !isCurrent && c.stalkerCmd != nil { continue }
                    guard c.streamURL != nil || (isCurrent && c.stalkerCmd != nil) else { continue }
                    hits.append(AlternativeSource(source: p, itemID: c.id, name: c.name, byEPG: sameEPG,
                                                  url: c.streamURL, stalkerCmd: isCurrent ? c.stalkerCmd : nil,
                                                  logo: c.logo, channel: c, isCurrentSource: isCurrent))
                }
            }
            scan(current, currentChannels, isCurrent: true)
            for p in others {
                var raw = Library()
                raw.channels = cachedChannels(p)
                let visible = filters[p.id].map { PlaylistService.apply(raw, $0).channels } ?? raw.channels
                scan(p, visible, isCurrent: false)
            }
            // EPG-treffers eerst, dan de eigen bron, dan de rest
            return hits.sorted { a, b in
                if a.byEPG != b.byEPG { return a.byEPG }
                if a.isCurrentSource != b.isCurrentSource { return a.isCurrentSource }
                return a.name.count < b.name.count
            }
        }.value
    }

    // MARK: films en afleveringen

    /// Dezelfde film (of aflevering van dezelfde serie) op een andere server of in een andere groep.
    @MainActor
    static func vodMatches(for item: PlayableItem, playlists: PlaylistService) async -> [AlternativeSource] {
        guard item.type == .movie || item.type == .episode else { return [] }
        let lib = playlists.library
        let isShow = item.type == .episode
        let seriesTitle: String
        var year: Int?
        if isShow {
            guard let s = lib.series.first(where: { $0.id == item.seriesID }) else { return [] }
            seriesTitle = s.title; year = s.year
        } else {
            seriesTitle = item.title
            year = lib.movies.first(where: { $0.id == item.id })?.year
        }
        let hits = await playlists.otherSources(title: seriesTitle, year: year, isShow: isShow,
                                                excluding: isShow ? (item.seriesID ?? "") : item.id)
        var out: [AlternativeSource] = []
        let currentID = playlists.source?.id
        for h in hits {
            let isCurrent = h.playlist.id == currentID
            if !isShow {
                var source: Library? = lib
                if !isCurrent {
                    let p = h.playlist
                    source = await Task.detached(priority: .userInitiated) { PlaylistService.readCache(p) }.value
                }
                guard let m = source?.movies.first(where: { $0.id == h.itemID }), m.streamURL != nil || (isCurrent && m.stalkerCmd != nil)
                else { continue }
                out.append(AlternativeSource(source: h.playlist, itemID: m.id, name: m.title, byEPG: false, url: m.streamURL,
                                             stalkerCmd: isCurrent ? m.stalkerCmd : nil, logo: m.poster, isCurrentSource: isCurrent))
            } else {
                guard let season = item.season, let number = item.episode else { continue }
                let eps = await episodes(seriesID: h.itemID, in: h.playlist, playlists: playlists, isCurrent: isCurrent)
                guard let e = eps.first(where: { $0.season == season && $0.number == number }), e.streamURL != nil else { continue }
                out.append(AlternativeSource(source: h.playlist, itemID: e.id, name: "\(h.title) · S\(season):E\(number)",
                                             byEPG: false, url: e.streamURL, logo: h.artwork,
                                             season: season, episode: number, isCurrentSource: isCurrent))
            }
        }
        return out
    }

    /// Afleveringen van een serie in een (eventueel andere) bron: M3U uit de cache, Xtream via de server.
    @MainActor
    private static func episodes(seriesID: String, in p: PlaylistSource, playlists: PlaylistService, isCurrent: Bool) async -> [Episode] {
        if isCurrent, let s = playlists.library.series.first(where: { $0.id == seriesID }) {
            return await playlists.episodes(for: s)
        }
        let found = await Task.detached(priority: .userInitiated) { () -> Series? in
            PlaylistService.readCache(p)?.series.first(where: { $0.id == seriesID })
        }.value
        guard let s = found else { return [] }
        if !s.episodes.isEmpty { return s.episodes }
        guard p.kind == .xtream else { return [] }
        return (try? await XtreamClient(source: p, password: Keychain.get(p.passwordKey) ?? "").episodes(for: s)) ?? []
    }
}
