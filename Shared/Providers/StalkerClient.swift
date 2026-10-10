import Foundation

/// Stalker / Ministra (MAC-portal). Ondersteunt live TV en VOD.
actor StalkerClient {
    let portal: String
    let mac: String
    private var endpoint: String?
    private var token: String?

    init(source: PlaylistSource) {
        var p = source.serverURL.trimmedSlash
        if !p.lowercased().hasPrefix("http") { p = "http://" + p }
        if p.hasSuffix("/c") { p.removeLast(2) }
        portal = p
        mac = source.macAddress.uppercased()
    }

    private struct JS<T: Decodable>: Decodable { let js: T }
    private struct Handshake: Decodable { let token: String? }
    private struct Genre: Decodable { let id: Flex; let title: String? }
    private struct ChannelDTO: Decodable {
        let id: Flex; let name: String?; let cmd: String?; let logo: String?; let tv_genre_id: Flex?
        let number: Flex?; let xmltv_id: String?; let tv_archive_duration: Flex?
    }
    private struct Paged<T: Decodable>: Decodable { let data: [T]?; let total_items: Flex?; let max_page_items: Flex? }
    private struct VodDTO: Decodable {
        let id: Flex; let name: String?; let cmd: String?; let screenshot_uri: String?; let year: Flex?
        let rating_imdb: Flex?; let description: String?; let category_id: Flex?; let is_series: Flex?
    }
    private struct Link: Decodable { let cmd: String? }
    private struct EPGItem: Decodable { let name: String?; let descr: String?; let start_timestamp: Flex?; let stop_timestamp: Flex? }

    private var headers: [String: String] {
        var h = ["Cookie": "mac=\(mac); stb_lang=en; timezone=\(TimeZone.current.identifier)",
                 "User-Agent": "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3",
                 "X-User-Agent": "Model: MAG250; Link: WiFi"]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    private func url(_ q: [String: String], base: String? = nil) -> URL? {
        var c = URLComponents(string: base ?? endpoint ?? "")
        c?.queryItems = q.map { URLQueryItem(name: $0, value: $1) } + [URLQueryItem(name: "JsHttpRequest", value: "1-xml")]
        return c?.url
    }

    func connect() async throws {
        let candidates = ["\(portal)/portal.php", "\(portal)/server/load.php",
                          "\(portal)/stalker_portal/server/load.php", "\(portal)/c/portal.php"]
        for base in candidates {
            guard let u = url(["type": "stb", "action": "handshake", "token": ""], base: base) else { continue }
            if let r = try? await HTTP.json(JS<Handshake>.self, u, headers: headers), let t = r.js.token {
                endpoint = base; token = t
                if let p = url(["type": "stb", "action": "get_profile", "hd": "1"]) {
                    _ = try? await HTTP.get(p, headers: headers)
                }
                return
            }
        }
        throw StalkerError.handshake
    }

    func library() async throws -> Library {
        if token == nil { try await connect() }
        var lib = Library()

        if let g = url(["type": "itv", "action": "get_genres"]),
           let c = url(["type": "itv", "action": "get_all_channels"]) {
            let genres = (try? await HTTP.json(JS<[Genre]>.self, g, headers: headers).js) ?? []
            let gMap = Dictionary(genres.compactMap { x in x.id.string.map { ($0, x.title ?? L("Other")) } }, uniquingKeysWith: { a, _ in a })
            let chans = (try? await HTTP.json(JS<Paged<ChannelDTO>>.self, c, headers: headers).js.data) ?? []
            lib.channels = chans.compactMap { ch in
                guard let id = ch.id.string else { return nil }
                return Channel(id: "st\(id)", name: ch.name ?? "Channel", logo: ch.logo?.urlValue,
                               group: gMap[ch.tv_genre_id?.string ?? ""] ?? L("Other"),
                               streamURL: directURL(ch.cmd), epgID: ch.xmltv_id, number: ch.number?.int,
                               catchupDays: (ch.tv_archive_duration?.int ?? 0) / 24, stalkerCmd: ch.cmd)
            }
        }

        if let vc = url(["type": "vod", "action": "get_categories"]) {
            let cats = (try? await HTTP.json(JS<[Genre]>.self, vc, headers: headers).js) ?? []
            for cat in cats.prefix(40) {
                guard let cid = cat.id.string, cid != "*" else { continue }
                for page in 1...3 {   // eerste ~3 pagina's per categorie; meer laadt bij zoeken
                    guard let u = url(["type": "vod", "action": "get_ordered_list", "category": cid,
                                       "p": String(page), "sortby": "added"]) else { break }
                    let items = (try? await HTTP.json(JS<Paged<VodDTO>>.self, u, headers: headers).js.data) ?? []
                    if items.isEmpty { break }
                    for v in items {
                        guard let id = v.id.string else { continue }
                        let p = TitleCleaner.parse(v.name ?? "")
                        if v.is_series?.int == 1 {
                            lib.series.append(Series(id: "sts\(id)", title: p.title, year: v.year?.int ?? p.year,
                                                     poster: v.screenshot_uri?.urlValue, group: cat.title ?? L("Series"),
                                                     plot: v.description, rating: v.rating_imdb?.double))
                        } else {
                            lib.movies.append(Movie(id: "stv\(id)", title: p.title, year: v.year?.int ?? p.year,
                                                    poster: v.screenshot_uri?.urlValue, group: cat.title ?? L("Movies"),
                                                    rating: v.rating_imdb?.double, plot: v.description, stalkerCmd: v.cmd))
                        }
                    }
                }
            }
        }
        return lib
    }

    /// Vraagt een tijdelijke stream-link aan bij het portal.
    func createLink(cmd: String, type: MediaType) async throws -> URL? {
        if token == nil { try await connect() }
        let t = type == .live ? "itv" : "vod"
        guard let u = url(["type": t, "action": "create_link", "cmd": cmd, "forced_storage": "undefined", "disable_ad": "0"]) else { return nil }
        let r = try await HTTP.json(JS<Link>.self, u, headers: headers)
        return directURL(r.js.cmd)
    }

    func shortEPG(channelID: String) async -> [EPGProgram] {
        let id = channelID.replacingOccurrences(of: "st", with: "")
        guard let u = url(["type": "itv", "action": "get_short_epg", "ch_id": id, "size": "10"]) else { return [] }
        let items = (try? await HTTP.json(JS<[EPGItem]>.self, u, headers: headers).js) ?? []
        return items.compactMap { i in
            guard let s = i.start_timestamp?.double, let e = i.stop_timestamp?.double else { return nil }
            return EPGProgram(channelID: channelID, title: i.name ?? "", description: i.descr,
                              start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e))
        }
    }

    private nonisolated func directURL(_ cmd: String?) -> URL? {
        guard var c = cmd else { return nil }
        for prefix in ["ffmpeg ", "ffrt ", "auto "] where c.hasPrefix(prefix) { c = String(c.dropFirst(prefix.count)) }
        c = c.trimmingCharacters(in: .whitespaces)
        guard c.lowercased().hasPrefix("http"), !c.contains("localhost") else { return nil }
        return URL(string: c)
    }
}

enum StalkerError: LocalizedError {
    case handshake
    var errorDescription: String? { L("Couldn't connect to the portal. Check the portal URL and MAC address.") }
}
