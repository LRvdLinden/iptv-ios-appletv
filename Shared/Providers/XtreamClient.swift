import Foundation

/// Xtream Codes player_api.php
struct XtreamClient {
    let server: String
    let username: String
    let password: String
    let preferHLS: Bool

    init(source: PlaylistSource, password: String) {
        var s = source.serverURL.trimmedSlash
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        server = s; username = source.username; self.password = password; preferHLS = source.preferHLS
    }

    private func api(_ action: String? = nil, _ extra: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: server + "/player_api.php")
        var q = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { q.append(URLQueryItem(name: "action", value: action)) }
        extra.forEach { q.append(URLQueryItem(name: $0, value: $1)) }
        c?.queryItems = q
        return c?.url
    }

    // MARK: DTO's

    struct AuthResponse: Decodable {
        struct UserInfo: Decodable { let auth: Flex?; let status: String?; let exp_date: Flex?; let max_connections: Flex? }
        let user_info: UserInfo?
    }
    struct Cat: Decodable { let category_id: Flex; let category_name: String? }
    struct Live: Decodable {
        let stream_id: Flex; let name: String?; let stream_icon: String?; let epg_channel_id: String?
        let category_id: Flex?; let num: Flex?; let tv_archive: Flex?; let tv_archive_duration: Flex?
    }
    struct Vod: Decodable {
        let stream_id: Flex; let name: String?; let stream_icon: String?; let category_id: Flex?
        let container_extension: String?; let rating: Flex?; let added: Flex?; let year: Flex?
    }
    struct SeriesDTO: Decodable {
        let series_id: Flex; let name: String?; let cover: String?; let category_id: Flex?
        let plot: String?; let rating: Flex?; let releaseDate: String?; let year: Flex?
    }
    struct SeriesInfo: Decodable {
        struct Ep: Decodable {
            struct Info: Decodable {
                let movie_image: String?; let plot: String?; let duration_secs: Flex?
                let releasedate: String?; let air_date: String?; let rating: Flex?
            }
            let id: Flex; let episode_num: Flex?; let title: String?; let container_extension: String?
            let season: Flex?; let info: Info?
        }
        struct SInfo: Decodable {
            let name: String?; let cover: String?; let plot: String?; let cast: String?; let director: String?
            let genre: String?; let releaseDate: String?; let rating: Flex?; let backdrop_path: StringOrArray?
            let youtube_trailer: String?; let tmdb: Flex?; let episode_run_time: Flex?
        }
        let episodes: [String: [Ep]]?
        let info: SInfo?
    }
    struct VodInfo: Decodable {
        struct Info: Decodable {
            let imdb_id: String?; let plot: String?; let rating: Flex?; let youtube_trailer: String?
            let tmdb_id: Flex?; let name: String?; let cover_big: String?; let movie_image: String?
            let backdrop_path: StringOrArray?; let director: String?; let cast: String?; let actors: String?
            let genre: String?; let releasedate: String?; let duration: String?; let duration_secs: Flex?
            let description: String?; let country: String?
        }
        let info: Info?
    }
    struct ShortEPG: Decodable {
        struct L: Decodable { let title: String?; let description: String?; let start_timestamp: Flex?; let stop_timestamp: Flex? }
        let epg_listings: [L]?
    }

    // MARK: Calls

    func authenticate() async throws {
        guard let u = api() else { throw HTTPError.badURL }
        let r = try await HTTP.json(AuthResponse.self, u)
        guard r.user_info?.auth?.int == 1 else { throw XtreamError.auth }
    }

    func library(playlistID: UUID) async throws -> Library {
        guard let lc = api("get_live_categories"), let ls = api("get_live_streams"),
              let vc = api("get_vod_categories"), let vs = api("get_vod_streams"),
              let sc = api("get_series_categories"), let ss = api("get_series") else { throw HTTPError.badURL }

        async let liveCats = (try? HTTP.json([Cat].self, lc)) ?? []
        async let live = (try? HTTP.json([Live].self, ls)) ?? []
        async let vodCats = (try? HTTP.json([Cat].self, vc)) ?? []
        async let vod = (try? HTTP.json([Vod].self, vs)) ?? []
        async let serCats = (try? HTTP.json([Cat].self, sc)) ?? []
        async let ser = (try? HTTP.json([SeriesDTO].self, ss)) ?? []

        func map(_ cats: [Cat]) -> [String: String] {
            Dictionary(cats.compactMap { c in c.category_id.string.map { ($0, c.category_name ?? L("Other")) } },
                       uniquingKeysWith: { a, _ in a })
        }
        let lcMap = map(await liveCats), vcMap = map(await vodCats), scMap = map(await serCats)
        let liveExt = preferHLS ? "m3u8" : "ts"

        var lib = Library()
        lib.channels = await live.compactMap { l in
            guard let sid = l.stream_id.string else { return nil }
            return Channel(id: "x\(sid)", name: l.name ?? "Channel", logo: l.stream_icon?.urlValue,
                           group: lcMap[l.category_id?.string ?? ""] ?? L("Other"),
                           streamURL: URL(string: "\(server)/live/\(username)/\(password)/\(sid).\(liveExt)"),
                           epgID: l.epg_channel_id.flatMap { $0.isEmpty ? nil : $0 },
                           number: l.num?.int,
                           catchupDays: l.tv_archive?.int == 1 ? (l.tv_archive_duration?.int ?? 0) : 0)
        }
        lib.movies = await vod.compactMap { v in
            guard let sid = v.stream_id.string else { return nil }
            let p = TitleCleaner.parse(v.name ?? "")
            return Movie(id: "xv\(sid)", title: p.title, year: v.year?.int ?? p.year, poster: v.stream_icon?.urlValue,
                         group: vcMap[v.category_id?.string ?? ""] ?? L("Other"),
                         streamURL: URL(string: "\(server)/movie/\(username)/\(password)/\(sid).\(v.container_extension ?? "mp4")"),
                         rating: v.rating?.double,
                         addedAt: v.added?.double.map { Date(timeIntervalSince1970: $0) },
                         xtreamVodID: Int(sid))
        }
        lib.series = await ser.compactMap { s in
            guard let sid = s.series_id.int else { return nil }
            let p = TitleCleaner.parse(s.name ?? "")
            let y = s.year?.int ?? s.releaseDate.flatMap { Int($0.prefix(4)) } ?? p.year
            return Series(id: "xs\(sid)", title: p.title, year: y, poster: s.cover?.urlValue,
                          group: scMap[s.category_id?.string ?? ""] ?? L("Other"),
                          plot: s.plot, rating: s.rating?.double, xtreamSeriesID: sid)
        }
        return lib
    }

    func episodes(for series: Series) async throws -> [Episode] {
        guard let sid = series.xtreamSeriesID, let u = api("get_series_info", ["series_id": String(sid)]) else { return [] }
        let info = try await HTTP.json(SeriesInfo.self, u)
        var out: [Episode] = []
        for (seasonKey, eps) in info.episodes ?? [:] {
            for e in eps {
                guard let eid = e.id.string else { continue }
                out.append(Episode(id: "xe\(eid)", seriesID: series.id,
                                   season: e.season?.int ?? Int(seasonKey) ?? 1,
                                   number: e.episode_num?.int ?? 0,
                                   title: e.title ?? L("Episode"),
                                   streamURL: URL(string: "\(server)/series/\(username)/\(password)/\(eid).\(e.container_extension ?? "mp4")"),
                                   still: e.info?.movie_image?.urlValue, plot: e.info?.plot,
                                   durationSeconds: e.info?.duration_secs?.int))
            }
        }
        return out.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    func seriesInfo(_ seriesID: Int) async -> SeriesInfo? {
        guard let u = api("get_series_info", ["series_id": String(seriesID)]) else { return nil }
        return try? await HTTP.json(SeriesInfo.self, u)
    }

    func vodInfo(_ vodID: Int) async -> VodInfo.Info? {
        guard let u = api("get_vod_info", ["vod_id": String(vodID)]) else { return nil }
        return try? await HTTP.json(VodInfo.self, u).info
    }

    var xmltvURL: URL? {
        var c = URLComponents(string: server + "/xmltv.php")
        c?.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return c?.url
    }

    /// Catch-up / terugkijken (tv_archive).
    func catchupURL(channel: Channel, program: EPGProgram) -> URL? {
        guard channel.id.hasPrefix("x") else { return nil }
        let sid = channel.id.dropFirst()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd:HH-mm"; f.timeZone = .current
        let minutes = Int(program.end.timeIntervalSince(program.start) / 60)
        return URL(string: "\(server)/timeshift/\(username)/\(password)/\(minutes)/\(f.string(from: program.start))/\(sid).ts")
    }
}

enum XtreamError: LocalizedError {
    case auth
    var errorDescription: String? { L("Couldn't sign in to the server. Check the server, username and password.") }
}
