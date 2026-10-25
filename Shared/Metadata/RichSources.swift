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
            struct Person: Decodable { let name: String; let images: [String: [String]]?; let ids: TraktIDs? }
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
            TitleDetails.CastMember(name: p.person.name, character: p.characters?.first ?? p.character, photo: image(p.person.images, "headshot"), personID: p.person.ids?.tmdb)
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
        /// Originele taal (ISO 639-1), build 59
        var originalLanguage: String? = nil
        /// Extra achtergronden (zonder tekst eerst) voor de bewegende kop op Apple TV, build 85
        var backdrops: [URL] = []
    }

    /// TMDB-locale voor de app-taal. build 97: geldige codes (vroeger "en-EN" en "ar-AR", die TMDB niet kent;
    /// daardoor werkte ook de Engelse terugval `lang != "en-US"` in PersonService niet goed).
    static var language: String {
        let l = Localizer.shared.language
        switch l {
        case "en": return "en-US"
        case "ar": return "ar-SA"
        case "zh-Hans": return "zh-CN"
        case "pt": return "pt-PT"
        default: return l.count == 2 ? "\(l)-\(l.uppercased())" : l
        }
    }

    /// Build 141: pad ("/abc.jpg") van een TMDB-afbeelding (https://image.tmdb.org/t/p/<maat>/abc.jpg), anders nil.
    static func path(of url: URL?) -> String? {
        guard let url, url.host?.hasSuffix("tmdb.org") == true, url.pathComponents.count >= 2 else { return nil }
        return "/" + url.lastPathComponent
    }

    static func img(_ path: String?, _ size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    static func get<T: Decodable>(_ path: String, _ q: [String: String] = [:]) async -> T? {
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

    /// Trending vandaag (Netflix-achtige Top 10): titels in de app-taal én origineel, met jaar.
    static func trending(shows: Bool) async -> [(titles: [String], year: Int?)] {
        struct R: Decodable {
            struct I: Decodable {
                let title: String?, name: String?, original_title: String?, original_name: String?
                let release_date: String?, first_air_date: String?
            }
            let results: [I]?
        }
        var out: [(titles: [String], year: Int?)] = []
        for page in ["1", "2"] {
            guard let r: R = await get(shows ? "/trending/tv/day" : "/trending/movie/day", ["language": language, "page": page]) else { break }
            for i in r.results ?? [] {
                let t = [i.title, i.name, i.original_title, i.original_name].compactMap { $0 }.filter { !$0.isEmpty }
                let y = (i.release_date ?? i.first_air_date).flatMap { Int($0.prefix(4)) }
                if !t.isEmpty { out.append((t, y)) }
            }
        }
        return out
    }

    /// Populair bij kids vandaag: animatie/familie (films) en kids/animatie (series), zonder volwassen titels.
    static func kidsTrending(shows: Bool) async -> [(titles: [String], year: Int?)] {
        struct R: Decodable {
            struct I: Decodable {
                let title: String?, name: String?, original_title: String?, original_name: String?
                let release_date: String?, first_air_date: String?
            }
            let results: [I]?
        }
        var q = ["language": language, "sort_by": "popularity.desc", "include_adult": "false",
                 "with_genres": shows ? "10762|16|10751" : "16|10751"]
        if !shows { q["certification_country"] = "US"; q["certification.lte"] = "PG" }
        var out: [(titles: [String], year: Int?)] = []
        for page in ["1", "2"] {
            q["page"] = page
            guard let r: R = await get(shows ? "/discover/tv" : "/discover/movie", q) else { break }
            for i in r.results ?? [] {
                let t = [i.title, i.name, i.original_title, i.original_name].compactMap { $0 }.filter { !$0.isEmpty }
                let y = (i.release_date ?? i.first_air_date).flatMap { Int($0.prefix(4)) }
                if !t.isEmpty { out.append((t, y)) }
            }
        }
        return out
    }

    private struct Find: Decodable { struct R: Decodable { let id: Int }; let movie_results: [R]?; let tv_results: [R]? }
    private struct Search: Decodable { struct R: Decodable { let id: Int }; let results: [R]? }
    private struct Full: Decodable {
        struct Credits: Decodable {
            struct Cast: Decodable {
                struct Role: Decodable { let character: String? }
                let id: Int?; let name: String; let character: String?; let profile_path: String?; let roles: [Role]?
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
        let original_language: String?
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
        var result = Result(
            id: f.id, imdb: f.imdb_id ?? f.external_ids?.imdb_id, overview: f.overview,
            poster: img(f.poster_path, "w780"), backdrop: img(f.backdrop_path, "w1280"), logo: img(logo?.file_path, "w500"),
            trailer: f.videos?.results?.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key,
            cast: castSrc.prefix(20).map { TitleDetails.CastMember(name: $0.name, character: $0.character ?? $0.roles?.first?.character, photo: img($0.profile_path, "w185"), personID: $0.id) },
            recommendations: (f.recommendations?.results ?? []).prefix(15).map { r in
                TitleDetails.Recommendation(title: r.title ?? r.name ?? "?", year: (r.release_date ?? r.first_air_date).flatMap { Int($0.prefix(4)) },
                      poster: img(r.poster_path, "w342"), imdbID: nil, isShow: isShow)
            })
        result.originalLanguage = f.original_language
        // achtergronden zonder tekst (iso_639_1 = null) eerst, dan de rest; max. 4 naast de hoofdafbeelding
        let bds = f.images?.backdrops ?? []
        let ordered = bds.filter { $0.iso_639_1 == nil } + bds.filter { $0.iso_639_1 != nil }
        result.backdrops = Array(ordered.compactMap { img($0.file_path, "w1280") }.filter { $0 != result.backdrop }.prefix(4))
        return result
    }

    private struct SeasonR: Decodable {
        struct E: Decodable { let episode_number: Int; let name: String?; let overview: String?; let still_path: String?; let air_date: String?; let runtime: Int? }
        let season_number: Int; let episodes: [E]?
    }

    /// Trailer van één seizoen (build 53): eerst "Trailer", dan "Teaser"; app-taal eerst, dan Engels.
    static func seasonTrailer(tvID: Int, season: Int) async -> String? {
        struct R: Decodable {
            struct V: Decodable { let key: String; let site: String; let type: String; let iso_639_1: String? }
            let results: [V]?
        }
        guard tvID > 0 else { return nil }
        let base = String(language.prefix(2))
        let r: R? = await get("/tv/\(tvID)/season/\(season)/videos",
                              ["language": language, "include_video_language": "\(base),en,null"])
        let vids = (r?.results ?? []).filter { $0.site == "YouTube" && ($0.type == "Trailer" || $0.type == "Teaser") }
        func rank(_ v: R.V) -> (Int, Int) {
            (v.type == "Trailer" ? 0 : 1, v.iso_639_1 == base ? 0 : (v.iso_639_1 == "en" ? 1 : 2))
        }
        return vids.min { rank($0) < rank($1) }?.key
    }

    static func season(tvID: Int, season: Int) async -> [String: TitleDetails.EpisodeInfo] {
        let r: SeasonR? = await get("/tv/\(tvID)/season/\(season)", ["language": language])
        var out: [String: TitleDetails.EpisodeInfo] = [:]
        for e in r?.episodes ?? [] {
            out["\(season)-\(e.episode_number)"] = .init(title: e.name, overview: e.overview, still: img(e.still_path, "w500"),
                                                         airDate: e.air_date.flatMap { FastISO.day($0) }, runtime: e.runtime)
        }
        return out
    }
}
