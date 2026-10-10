import Foundation

// MARK: - Gedeelde helpers ------------------------------------------------------

enum DeviceInfo {
    static var id: String {
        if let v = UserDefaults.standard.string(forKey: "device.id") { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: "device.id")
        return v
    }
    static var name: String {
        #if os(tvOS)
        return "Apple TV"
        #else
        return "iPhone"
        #endif
    }
}

/// ISO-datums met 0–7 decimalen (Jellyfin/Emby gebruiken er 7).
func parseISODate(_ s: String?) -> Date? {
    guard var s else { return nil }
    if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
        s.removeSubrange(dot..<end)
    }
    if !s.hasSuffix("Z") && !s.contains("+") && s.count == 19 { s += "Z" }
    return ISO8601DateFormatter.plain.date(from: s)
}

private func jsonRequest(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (d, h) = try await HTTP.data(r)
    guard (200..<300).contains(h.statusCode) else { throw HTTPError.status(h.statusCode, String(decoding: d, as: UTF8.self)) }
    return d
}

private func normalizedServer(_ s: String) -> String {
    var v = s.trimmedSlash
    if !v.lowercased().hasPrefix("http") { v = "http://" + v }
    return v
}

// MARK: - Jellyfin / Emby ------------------------------------------------------

/// Jellyfin en Emby delen dezelfde API.
struct JellyfinClient {
    let server: String
    let isEmby: Bool
    var token: String?
    var userID: String?

    init(source: PlaylistSource, session: MediaSession?) {
        server = normalizedServer(source.serverURL)
        isEmby = source.kind == .emby
        token = session?.token; userID = session?.userID
    }

    private var authHeader: [String: String] {
        var v = "MediaBrowser Client=\"Bingr\", Device=\"\(DeviceInfo.name)\", DeviceId=\"\(DeviceInfo.id)\", Version=\"1.1.0\""
        if let token { v += ", Token=\"\(token)\"" }
        return ["X-Emby-Authorization": v, "Authorization": v]
    }

    private func url(_ path: String, _ q: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: server + path)
        if !q.isEmpty { c?.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c?.url
    }

    func login(username: String, password: String) async throws -> MediaSession {
        struct R: Decodable { struct U: Decodable { let Id: String }; let AccessToken: String; let User: U }
        guard let u = url("/Users/AuthenticateByName") else { throw HTTPError.badURL }
        let d = try await jsonRequest(u, method: "POST", headers: authHeader,
                                      body: ["Username": username, "Pw": password, "Password": password])
        let r = try JSONDecoder().decode(R.self, from: d)
        return MediaSession(token: r.AccessToken, userID: r.User.Id, serverURI: server)
    }

    private struct Items: Decodable { let Items: [Item] }
    private struct Item: Decodable {
        let Id: String; let Name: String?; let ProductionYear: Int?; let Overview: String?
        let CommunityRating: Double?; let Genres: [String]?; let DateCreated: String?
        let ProviderIds: [String: String]?; let ParentIndexNumber: Int?; let IndexNumber: Int?
        let RunTimeTicks: Int64?; let Number: String?; let ChannelId: String?
        let StartDate: String?; let EndDate: String?; let CollectionType: String?
    }

    func image(_ id: String) -> URL? { url("/Items/\(id)/Images/Primary", ["maxHeight": "600", "quality": "90"]) }
    func stream(_ id: String) -> URL? { url("/Videos/\(id)/stream", ["static": "true", "api_key": token ?? ""]) }

    func library() async throws -> Library {
        guard let uid = userID else { throw MediaError.notLoggedIn }
        func items(_ type: String) async throws -> [Item] {
            guard let u = url("/Users/\(uid)/Items", ["IncludeItemTypes": type, "Recursive": "true",
                  "Fields": "ProviderIds,Overview,Genres,DateCreated", "SortBy": "DateCreated",
                  "SortOrder": "Descending", "Limit": "3000"]) else { return [] }
            return try JSONDecoder().decode(Items.self, from: try await jsonRequest(u, headers: authHeader)).Items
        }
        var lib = Library()
        lib.movies = try await items("Movie").map { i in
            Movie(id: "jf\(i.Id)", title: i.Name ?? "?", year: i.ProductionYear, poster: image(i.Id),
                  group: i.Genres?.first ?? L("Movies"), streamURL: stream(i.Id), imdbID: i.ProviderIds?["Imdb"],
                  rating: i.CommunityRating, plot: i.Overview, addedAt: parseISODate(i.DateCreated))
        }
        lib.series = try await items("Series").map { i in
            Series(id: "jfs\(i.Id)", title: i.Name ?? "?", year: i.ProductionYear, poster: image(i.Id),
                   group: i.Genres?.first ?? L("Series"), imdbID: i.ProviderIds?["Imdb"], plot: i.Overview,
                   rating: i.CommunityRating, remoteID: i.Id)
        }
        // Live TV (optioneel)
        if let u = url("/LiveTv/Channels", ["UserId": uid, "EnableImages": "true"]),
           let d = try? await jsonRequest(u, headers: authHeader),
           let ch = try? JSONDecoder().decode(Items.self, from: d).Items {
            lib.channels = ch.map { c in
                Channel(id: "jfc\(c.Id)", name: c.Name ?? "?", logo: image(c.Id), group: "Live TV",
                        streamURL: stream(c.Id), epgID: c.Id, number: c.Number.flatMap { Int($0) })
            }
            let now = Date()
            if !ch.isEmpty, let pu = url("/LiveTv/Programs", ["UserId": uid,
                    "MinEndDate": ISO8601DateFormatter.plain.string(from: now),
                    "MaxStartDate": ISO8601DateFormatter.plain.string(from: now.addingTimeInterval(86400 * 2))]),
               let pd = try? await jsonRequest(pu, headers: authHeader),
               let progs = try? JSONDecoder().decode(Items.self, from: pd).Items {
                for p in progs {
                    guard let cid = p.ChannelId, let s = parseISODate(p.StartDate), let e = parseISODate(p.EndDate) else { continue }
                    lib.epg[cid, default: []].append(EPGProgram(channelID: cid, title: p.Name ?? "", description: p.Overview, start: s, end: e))
                }
                lib.epg = lib.epg.mapValues { $0.sorted { $0.start < $1.start } }
            }
        }
        return lib
    }

    func episodes(_ series: Series) async throws -> [Episode] {
        guard let sid = series.remoteID, let uid = userID,
              let u = url("/Shows/\(sid)/Episodes", ["UserId": uid, "Fields": "Overview"]) else { return [] }
        let items = try JSONDecoder().decode(Items.self, from: try await jsonRequest(u, headers: authHeader)).Items
        return items.map { e in
            Episode(id: "jfe\(e.Id)", seriesID: series.id, season: e.ParentIndexNumber ?? 1, number: e.IndexNumber ?? 0,
                    title: e.Name ?? "", streamURL: stream(e.Id), still: image(e.Id), plot: e.Overview,
                    durationSeconds: e.RunTimeTicks.map { Int($0 / 10_000_000) })
        }
    }
}

struct MediaSession: Codable { var token: String; var userID: String?; var serverURI: String }

enum MediaError: LocalizedError {
    case notLoggedIn, noServer
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L("Not signed in. Edit the playlist and sign in again.")
        case .noServer: return L("No reachable server found on this account.")
        }
    }
}

// MARK: - Plex ------------------------------------------------------------------

/// Plex: inloggen met een koppelcode op plex.tv/link (werkt ook op Apple TV).
struct PlexClient {
    static var headers: [String: String] {
        ["X-Plex-Product": "Bingr", "X-Plex-Client-Identifier": DeviceInfo.id, "X-Plex-Version": "1.1.0",
         "X-Plex-Device-Name": DeviceInfo.name, "X-Plex-Platform": DeviceInfo.name == "Apple TV" ? "tvOS" : "iOS"]
    }

    struct Pin: Decodable { let id: Int; let code: String; let authToken: String? }

    static func createPin() async throws -> Pin {
        let d = try await jsonRequest(URL(string: "https://plex.tv/api/v2/pins?strong=false")!, method: "POST", headers: headers)
        return try JSONDecoder().decode(Pin.self, from: d)
    }

    static func waitForToken(_ pin: Pin) async throws -> String {
        for _ in 0..<150 {     // ±5 minuten
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let d = try await jsonRequest(URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!, headers: headers)
            if let t = try JSONDecoder().decode(Pin.self, from: d).authToken, !t.isEmpty { return t }
        }
        throw TraktError.expired
    }

    /// Zoekt de eerste bereikbare Plex Media Server van dit account.
    static func discoverServer(userToken: String) async throws -> MediaSession {
        struct Res: Decodable {
            struct Conn: Decodable { let uri: String; let local: Bool?; let relay: Bool? }
            let name: String?; let provides: String?; let accessToken: String?; let connections: [Conn]?
        }
        var h = headers; h["X-Plex-Token"] = userToken
        let d = try await jsonRequest(URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!, headers: h)
        let servers = try JSONDecoder().decode([Res].self, from: d).filter { ($0.provides ?? "").contains("server") }
        for s in servers {
            let conns = (s.connections ?? []).sorted { ($0.local == true ? 0 : $0.relay == true ? 2 : 1) < ($1.local == true ? 0 : $1.relay == true ? 2 : 1) }
            for c in conns {
                var r = URLRequest(url: URL(string: c.uri + "/identity")!); r.timeoutInterval = 4
                if let res = try? await HTTP.data(r), res.1.statusCode == 200 {
                    return MediaSession(token: s.accessToken ?? userToken, userID: s.name, serverURI: c.uri)
                }
            }
        }
        throw MediaError.noServer
    }

    let session: MediaSession

    private func url(_ path: String, _ q: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: session.serverURI + path)
        c?.queryItems = (q.merging(["X-Plex-Token": session.token]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    private struct Container: Decodable { let MediaContainer: MC }
    private struct MC: Decodable { let Directory: [Dir]?; let Metadata: [Meta]? }
    private struct Dir: Decodable { let key: String; let title: String?; let type: String? }
    private struct Meta: Decodable {
        struct Tag: Decodable { let tag: String? }
        struct GuidT: Decodable { let id: String }
        struct Media: Decodable { struct Part: Decodable { let key: String? }; let Part: [Part]? }
        let ratingKey: String; let title: String?; let year: Int?; let thumb: String?; let summary: String?
        let audienceRating: Double?; let rating: Double?; let addedAt: Int?; let parentIndex: Int?; let index: Int?
        let duration: Int?; let Genre: [Tag]?; let Guid: [GuidT]?; let Media: [Media]?
    }

    private func get(_ path: String, _ q: [String: String] = [:]) async throws -> MC {
        guard let u = url(path, q) else { throw HTTPError.badURL }
        return try JSONDecoder().decode(Container.self, from: try await jsonRequest(u, headers: Self.headers)).MediaContainer
    }

    private func imdb(_ m: Meta) -> String? {
        m.Guid?.first { $0.id.hasPrefix("imdb://") }.map { String($0.id.dropFirst(7)) }
    }
    private func image(_ path: String?) -> URL? { path.flatMap { url($0) } }
    private func stream(_ m: Meta) -> URL? { m.Media?.first?.Part?.first?.key.flatMap { url($0) } }

    func library() async throws -> Library {
        var lib = Library()
        for dir in try await get("/library/sections").Directory ?? [] {
            guard dir.type == "movie" || dir.type == "show" else { continue }
            let items = try await get("/library/sections/\(dir.key)/all", ["includeGuids": "1"]).Metadata ?? []
            for m in items {
                let group = m.Genre?.first?.tag ?? dir.title ?? "Plex"
                if dir.type == "movie" {
                    lib.movies.append(Movie(id: "px\(m.ratingKey)", title: m.title ?? "?", year: m.year, poster: image(m.thumb),
                                            group: group, streamURL: stream(m), imdbID: imdb(m),
                                            rating: m.audienceRating ?? m.rating, plot: m.summary,
                                            addedAt: m.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                } else {
                    lib.series.append(Series(id: "pxs\(m.ratingKey)", title: m.title ?? "?", year: m.year, poster: image(m.thumb),
                                             group: group, imdbID: imdb(m), plot: m.summary,
                                             rating: m.audienceRating ?? m.rating, remoteID: m.ratingKey))
                }
            }
        }
        lib.movies.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        return lib
    }

    func episodes(_ series: Series) async throws -> [Episode] {
        guard let key = series.remoteID else { return [] }
        return (try await get("/library/metadata/\(key)/allLeaves").Metadata ?? []).map { e in
            Episode(id: "pxe\(e.ratingKey)", seriesID: series.id, season: e.parentIndex ?? 1, number: e.index ?? 0,
                    title: e.title ?? "", streamURL: stream(e), still: image(e.thumb), plot: e.summary,
                    durationSeconds: e.duration.map { $0 / 1000 })
        }
    }
}

// MARK: - Stremio ----------------------------------------------------------------

/// Stremio-addons: catalogi (films/series met IMDb-ID's) en streams. Alleen directe
/// http(s)-streams worden afgespeeld.
struct StremioClient {
    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    struct Addon: Codable, Hashable {
        var base: String          // transportUrl zonder /manifest.json
        var name: String
        var resources: [String]
        var types: [String]
        var catalogs: [Catalog]
        struct Catalog: Codable, Hashable { var type: String; var id: String; var name: String }
    }

    // inloggen bij Stremio → addon-collectie van het account
    static func login(email: String, password: String) async throws -> String {
        struct R: Decodable { struct Res: Decodable { let authKey: String }; let result: Res? }
        let d = try await jsonRequest(URL(string: "https://api.strem.io/api/login")!, method: "POST",
                                      body: ["type": "Login", "email": email, "password": password, "facebook": false])
        guard let k = try JSONDecoder().decode(R.self, from: d).result?.authKey else { throw XtreamError.auth }
        return k
    }

    static func accountAddons(authKey: String) async throws -> [String] {
        struct R: Decodable { struct Res: Decodable { struct A: Decodable { let transportUrl: String }; let addons: [A] }; let result: Res? }
        let d = try await jsonRequest(URL(string: "https://api.strem.io/api/addonCollectionGet")!, method: "POST",
                                      body: ["type": "AddonCollectionGet", "authKey": authKey, "update": true])
        return try JSONDecoder().decode(R.self, from: d).result?.addons.map(\.transportUrl) ?? []
    }

    static func loadAddon(_ manifestURL: String) async -> Addon? {
        var m = manifestURL.trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("stremio://") { m = "https://" + m.dropFirst("stremio://".count) }
        guard let u = URL(string: m), let d = try? await HTTP.get(u),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let resources: [String] = (obj["resources"] as? [Any] ?? []).compactMap { r in
            (r as? String) ?? ((r as? [String: Any])?["name"] as? String)
        }
        let catalogs: [Addon.Catalog] = (obj["catalogs"] as? [[String: Any]] ?? []).compactMap { c in
            guard let t = c["type"] as? String, let id = c["id"] as? String else { return nil }
            let extras = (c["extra"] as? [[String: Any]] ?? [])
            if extras.contains(where: { ($0["isRequired"] as? Bool) == true }) { return nil }
            if let req = c["extraRequired"] as? [String], !req.isEmpty { return nil }
            return Addon.Catalog(type: t, id: id, name: (c["name"] as? String) ?? id)
        }
        let base = m.replacingOccurrences(of: "/manifest.json", with: "")
        return Addon(base: base, name: obj["name"] as? String ?? "Addon", resources: resources,
                     types: obj["types"] as? [String] ?? [], catalogs: catalogs)
    }

    let addons: [Addon]

    private struct Metas: Decodable { let metas: [Meta]? }
    private struct Meta: Decodable {
        let id: String; let type: String?; let name: String?; let poster: String?; let releaseInfo: String?
        let imdbRating: String?; let description: String?
        let videos: [Video]?
    }
    private struct Video: Decodable {
        let id: String; let season: Int?; let episode: Int?; let number: Int?; let name: String?; let title: String?
        let overview: String?; let thumbnail: String?
    }

    func library() async -> Library {
        var lib = Library()
        await withTaskGroup(of: (Addon.Catalog, [Meta]).self) { group in
            for a in addons where a.resources.contains("catalog") {
                for c in a.catalogs.prefix(10) where c.type == "movie" || c.type == "series" {
                    group.addTask {
                        guard let u = URL(string: "\(a.base)/catalog/\(c.type)/\(c.id).json"),
                              let d = try? await HTTP.get(u),
                              let m = try? JSONDecoder().decode(Metas.self, from: d).metas else { return (c, []) }
                        return (c, m)
                    }
                }
            }
            for await (cat, metas) in group {
                let groupName = "\(cat.name) · \(cat.type == "movie" ? L("Movies") : L("Series"))"
                for m in metas where m.id.hasPrefix("tt") {
                    let year = m.releaseInfo.flatMap { Int($0.prefix(4)) }
                    if cat.type == "movie" {
                        lib.movies.append(Movie(id: "sm\(m.id)-\(cat.id)", title: m.name ?? "?", year: year,
                                                poster: m.poster?.urlValue, group: groupName, imdbID: m.id,
                                                rating: m.imdbRating.flatMap(Double.init), plot: m.description))
                    } else {
                        lib.series.append(Series(id: "ss\(m.id)-\(cat.id)", title: m.name ?? "?", year: year,
                                                 poster: m.poster?.urlValue, group: groupName, imdbID: m.id,
                                                 plot: m.description, rating: m.imdbRating.flatMap(Double.init), remoteID: m.id))
                    }
                }
            }
        }
        return lib
    }

    func episodes(_ series: Series) async throws -> [Episode] {
        guard let id = series.remoteID else { return [] }
        let metaAddon = addons.first { $0.resources.contains("meta") && $0.types.contains("series") }
        let base = metaAddon?.base ?? StremioClient.cinemeta.replacingOccurrences(of: "/manifest.json", with: "")
        struct R: Decodable { let meta: Meta? }
        guard let u = URL(string: "\(base)/meta/series/\(id).json") else { return [] }
        let r = try JSONDecoder().decode(R.self, from: try await HTTP.get(u))
        return (r.meta?.videos ?? []).filter { ($0.season ?? 0) > 0 }.map { v in
            Episode(id: "se\(v.id)", seriesID: series.id, season: v.season ?? 1, number: v.episode ?? v.number ?? 0,
                    title: v.name ?? v.title ?? "", streamURL: nil, still: v.thumbnail?.urlValue, plot: v.overview)
        }
        .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    struct Stream: Identifiable, Hashable { var id: String { url.absoluteString }; var url: URL; var title: String; var addon: String }

    /// Alle directe streams voor een film (tt…) of aflevering (tt…:s:e).
    func streams(type: String, id: String) async -> [Stream] {
        struct R: Decodable { struct S: Decodable { let url: String?; let title: String?; let name: String?; let description: String? }; let streams: [S]? }
        var out: [Stream] = []
        await withTaskGroup(of: [Stream].self) { group in
            for a in addons where a.resources.contains("stream") {
                group.addTask {
                    guard let u = URL(string: "\(a.base)/stream/\(type)/\(id).json"),
                          let d = try? await HTTP.get(u), let r = try? JSONDecoder().decode(R.self, from: d) else { return [] }
                    return (r.streams ?? []).compactMap { s in
                        guard let su = s.url, let url = URL(string: su), su.lowercased().hasPrefix("http") else { return nil }
                        let t = [s.name, s.title ?? s.description].compactMap { $0 }.joined(separator: " · ")
                        return Stream(url: url, title: t.isEmpty ? a.name : t, addon: a.name)
                    }
                }
            }
            for await s in group { out += s }
        }
        return out
    }
}
