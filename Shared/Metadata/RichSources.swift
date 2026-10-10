import Foundation

// MARK: - Trakt: beschrijving, score, cast, aanbevelingen, afleveringen -------------

enum TraktDetails {
    struct Result {
        var imdb: String?; var slug: String?; var overview: String?; var rating: Double?; var runtime: Int?
        var genres: [String] = []; var certification: String?; var trailer: String?
        var poster: URL?; var fanart: URL?; var logo: URL?
        var cast: [TitleDetails.CastMember] = []
        var related: [TitleDetails.Recommendation] = []
        var episodes: [String: TitleDetails.EpisodeInfo] = [:]
    }

    private struct Media: Decodable {
        let title: String?; let year: Int?; let ids: TraktIDs; let overview: String?; let rating: Double?
        let runtime: Int?; let genres: [String]?; let certification: String?; let trailer: String?
        let images: [String: [String]]?
    }
    private struct Hit: Decodable { let movie: Media?; let show: Media? }
    private struct People: Decodable {
        struct Cast: Decodable {
            struct Person: Decodable { let name: String; let images: [String: [String]]? }
            let character: String?; let characters: [String]?; let person: Person
        }
        let cast: [Cast]?
    }
    private struct Season: Decodable {
        struct Ep: Decodable {
            let season: Int; let number: Int; let title: String?; let overview: String?
            let first_aired: String?; let runtime: Int?; let images: [String: [String]]?
        }
        let number: Int; let episodes: [Ep]?
    }

    static func image(_ dict: [String: [String]]?, _ key: String) -> URL? {
        guard let s = dict?[key]?.first, !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("http") ? s : "https://" + s)
    }

    static func fetch(imdb: String?, title: String, year: Int?, isShow: Bool) async -> Result? {
        guard Secrets.isSet(Secrets.traktClientID) else { return nil }
        let c = TraktClient.shared
        let type = isShow ? "show" : "movie"
        var media: Media?
        if let imdb {
            let hits: [Hit]? = try? await c.get("/search/imdb/\(imdb)", query: ["type": type, "extended": "full,images"], auth: false)
            media = hits?.first.flatMap { $0.movie ?? $0.show }
        }
        if media == nil {
            var q = ["query": title, "extended": "full,images", "limit": "3"]
            if let year { q["years"] = String(year) }
            let hits: [Hit]? = try? await c.get("/search/\(type)", query: q, auth: false)
            media = hits?.first.flatMap { $0.movie ?? $0.show }
        }
        guard let m = media, let slug = m.ids.slug ?? m.ids.trakt.map(String.init) else { return nil }

        var r = Result(imdb: m.ids.imdb, slug: m.ids.slug, overview: m.overview, rating: m.rating, runtime: m.runtime,
                       genres: m.genres ?? [], certification: m.certification, trailer: m.trailer,
                       poster: image(m.images, "poster"), fanart: image(m.images, "fanart"), logo: image(m.images, "logo"))
        let path = isShow ? "shows" : "movies"

        async let people: People? = try? c.get("/\(path)/\(slug)/people", query: ["extended": "images"], auth: false)
        async let related: [Media]? = try? c.get("/\(path)/\(slug)/related", query: ["limit": "15", "extended": "images"], auth: false)
        async let seasons: [Season]? = isShow ? (try? c.get("/shows/\(slug)/seasons", query: ["extended": "episodes,full,images"], auth: false)) : nil

        r.cast = (await people)?.cast?.prefix(20).map { p in
            TitleDetails.CastMember(name: p.person.name, character: p.characters?.first ?? p.character, photo: image(p.person.images, "headshot"))
        } ?? []
        r.related = (await related)?.map { x in
            TitleDetails.Recommendation(title: x.title ?? "?", year: x.year, poster: image(x.images, "poster"), imdbID: x.ids.imdb, isShow: isShow)
        } ?? []
        for s in (await seasons) ?? [] {
            for e in s.episodes ?? [] {
                r.episodes["\(e.season)-\(e.number)"] = .init(title: e.title, overview: e.overview,
                                                              still: image(e.images, "screenshot"),
                                                              airDate: parseISODate(e.first_aired), runtime: e.runtime)
            }
        }
        return r
    }
}

// MARK: - TMDB (optioneel) --------------------------------------------------------

/// Alleen gebruikt als er een TMDB-sleutel in Secrets.swift staat. Levert foto's van
/// de cast, titel-logo's, achtergronden, afleveringsstills en teksten in de app-taal.
/// De score die Bingr toont blijft IMDb + Trakt.
enum TMDB {
    struct Result {
        var id: Int; var imdb: String?; var overview: String?; var poster: URL?; var backdrop: URL?; var logo: URL?
        var trailer: String?; var cast: [TitleDetails.CastMember] = []; var recommendations: [TitleDetails.Recommendation] = []
    }

    private static var language: String {
        let l = Localizer.shared.language
        switch l {
        case "zh-Hans": return "zh-CN"
        case "pt": return "pt-PT"
        default: return l.count == 2 ? "\(l)-\(l.uppercased())" : l
        }
    }

    private static func img(_ path: String?, _ size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    private static func get<T: Decodable>(_ path: String, _ q: [String: String] = [:]) async -> T? {
        guard Secrets.isSet(Secrets.tmdbAPIKey) else { return nil }
        var c = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        var items = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        var headers: [String: String] = [:]
        // v4-token (lang, begint met eyJ) als Bearer, anders v3-sleutel als query
        if Secrets.tmdbAPIKey.count > 40 { headers["Authorization"] = "Bearer \(Secrets.tmdbAPIKey)" }
        else { items.append(URLQueryItem(name: "api_key", value: Secrets.tmdbAPIKey)) }
        c.queryItems = items
        guard let u = c.url else { return nil }
        return try? await HTTP.json(T.self, u, headers: headers)
    }

    private struct Find: Decodable { struct R: Decodable { let id: Int }; let movie_results: [R]?; let tv_results: [R]? }
    private struct Search: Decodable { struct R: Decodable { let id: Int }; let results: [R]? }
    private struct Full: Decodable {
        struct Credits: Decodable {
            struct Cast: Decodable {
                struct Role: Decodable { let character: String? }
                let name: String; let character: String?; let profile_path: String?; let roles: [Role]?
            }
            let cast: [Cast]?
        }
        struct Recs: Decodable {
            struct R: Decodable { let title: String?; let name: String?; let poster_path: String?; let release_date: String?; let first_air_date: String? }
            let results: [R]?
        }
        struct Images: Decodable { struct I: Decodable { let file_path: String; let iso_639_1: String? }; let logos: [I]?; let backdrops: [I]? }
        struct Videos: Decodable { struct V: Decodable { let key: String; let site: String; let type: String }; let results: [V]? }
        struct Ext: Decodable { let imdb_id: String? }
        let id: Int; let overview: String?; let poster_path: String?; let backdrop_path: String?
        let imdb_id: String?; let credits: Credits?; let aggregate_credits: Credits?; let recommendations: Recs?
        let images: Images?; let videos: Videos?; let external_ids: Ext?
    }

    static func details(imdb: String?, tmdbID: Int?, title: String, year: Int?, isShow: Bool) async -> Result? {
        guard Secrets.isSet(Secrets.tmdbAPIKey) else { return nil }
        var id = tmdbID
        if id == nil, let imdb {
            let f: Find? = await get("/find/\(imdb)", ["external_source": "imdb_id"])
            id = isShow ? f?.tv_results?.first?.id : f?.movie_results?.first?.id
        }
        if id == nil {
            var q = ["query": title]
            if let year { q[isShow ? "first_air_date_year" : "year"] = String(year) }
            let s: Search? = await get(isShow ? "/search/tv" : "/search/movie", q)
            id = s?.results?.first?.id
        }
        guard let id else { return nil }
        let lang = language, base = String(lang.prefix(2))
        let full: Full? = await get(isShow ? "/tv/\(id)" : "/movie/\(id)", [
            "language": lang,
            "append_to_response": isShow ? "aggregate_credits,recommendations,images,videos,external_ids" : "credits,recommendations,images,videos",
            "include_image_language": "\(base),en,null",
            "include_video_language": "\(base),en"])
        guard let f = full else { return nil }
        let logo = f.images?.logos?.first { $0.iso_639_1 == base } ?? f.images?.logos?.first { $0.iso_639_1 == "en" } ?? f.images?.logos?.first
        let castSrc = (isShow ? f.aggregate_credits : f.credits)?.cast ?? []
        return Result(
            id: f.id, imdb: f.imdb_id ?? f.external_ids?.imdb_id, overview: f.overview,
            poster: img(f.poster_path, "w780"), backdrop: img(f.backdrop_path, "w1280"), logo: img(logo?.file_path, "w500"),
            trailer: f.videos?.results?.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key,
            cast: castSrc.prefix(20).map { TitleDetails.CastMember(name: $0.name, character: $0.character ?? $0.roles?.first?.character, photo: img($0.profile_path, "w185")) },
            recommendations: (f.recommendations?.results ?? []).prefix(15).map { r in
                TitleDetails.Recommendation(title: r.title ?? r.name ?? "?", year: (r.release_date ?? r.first_air_date).flatMap { Int($0.prefix(4)) },
                      poster: img(r.poster_path, "w342"), imdbID: nil, isShow: isShow)
            })
    }

    private struct SeasonR: Decodable {
        struct E: Decodable { let episode_number: Int; let name: String?; let overview: String?; let still_path: String?; let air_date: String?; let runtime: Int? }
        let season_number: Int; let episodes: [E]?
    }

    static func season(tvID: Int, season: Int) async -> [String: TitleDetails.EpisodeInfo] {
        let r: SeasonR? = await get("/tv/\(tvID)/season/\(season)", ["language": language])
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var out: [String: TitleDetails.EpisodeInfo] = [:]
        for e in r?.episodes ?? [] {
            out["\(season)-\(e.episode_number)"] = .init(title: e.name, overview: e.overview, still: img(e.still_path, "w500"),
                                                         airDate: e.air_date.flatMap { df.date(from: $0) }, runtime: e.runtime)
        }
        return out
    }
}
