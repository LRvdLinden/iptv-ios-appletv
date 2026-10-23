import Foundation

/// Alles wat de detailpagina laat zien, samengesteld uit meerdere bronnen:
/// 1. de afspeellijst zelf (Xtream-info, Plex/Jellyfin) — werkt altijd, zonder sleutels
/// 2. IMDb via OMDb (score, plot, cast)
/// 3. Trakt (beschrijving, %-score, genres, cast, aanbevelingen, afleveringen)
/// 4. TMDB, optioneel (foto's van cast, titel-logo, achtergrond, stills, NL-teksten)
struct TitleDetails: Hashable {
    var title: String
    var year: String?
    var runtime: String?
    var overview: String?
    var genres: [String] = []
    var certification: String?
    var poster: URL?
    var backdrop: URL?
    /// Meer achtergronden (TMDB, Xtream), voor de bewegende kop op Apple TV (build 85)
    var backdrops: [URL] = []
    var logo: URL?
    var trailerYouTubeID: String?
    var imdbID: String?
    var traktSlug: String?
    var ratings: [Rating] = []
    var cast: [CastMember] = []
    var director: String?
    var recommendations: [Recommendation] = []
    var episodeInfo: [String: EpisodeInfo] = [:]     // "s-e"
    var seasonCount: Int?
    var tmdbID: Int?
    /// Originele taal volgens TMDB ("en", "it"), build 59
    var originalLanguage: String?

    struct Rating: Hashable, Identifiable { var id: String { source }; var source: String; var value: String }
    struct CastMember: Hashable, Identifiable {
        var id: String { name + (character ?? "") }
        var name: String; var character: String?; var photo: URL?
        /// TMDB-persoons-ID (alleen bij TMDB-cast; OMDb/Trakt/afspeellijst geven alleen namen)
        var personID: Int? = nil
    }
    struct Recommendation: Hashable, Identifiable {
        var id: String { imdbID ?? title }
        var title: String; var year: Int?; var poster: URL?; var imdbID: String?; var isShow: Bool
    }
    struct EpisodeInfo: Hashable { var title: String?; var overview: String?; var still: URL?; var airDate: Date?; var runtime: Int? }
}

@MainActor
final class DetailsService: ObservableObject {
    static let shared = DetailsService()
    private var cache: [String: TitleDetails] = [:]

    /// Basisgegevens uit de afspeellijst + alle verrijkingen.
    func details(for target: DetailTarget, playlists: PlaylistService, knownIMDb: String?) async -> TitleDetails {
        if let c = cache[target.id] { return c }
        var d: TitleDetails
        let isShow = target.isSeries
        switch target {
        case .movie(let m):
            // titel zonder taallabel ("Animal (IT)" → "Animal"), build 59
            d = TitleDetails(title: ContentLanguage.displayTitle(m.title), year: m.year.map(String.init), overview: m.plot, poster: m.poster, imdbID: knownIMDb ?? m.imdbID)
            if let r = m.rating, r > 0 { d.ratings.append(.init(source: L("Playlist"), value: String(format: "%.1f", r))) }
            if let vi = await playlists.xtreamVodInfo(m) { merge(xtream: vi, into: &d) }
        case .series(let s):
            d = TitleDetails(title: ContentLanguage.displayTitle(s.title), year: s.year.map(String.init), overview: s.plot, poster: s.poster, imdbID: knownIMDb ?? s.imdbID)
            if let r = s.rating, r > 0 { d.ratings.append(.init(source: L("Playlist"), value: String(format: "%.1f", r))) }
            if let si = await playlists.xtreamSeriesInfo(s) { merge(xtream: si, into: &d) }
        }
        // App Store-screenshots: alleen de demo-gegevens, geen IMDb/Trakt/TMDB
        if Screenshots.isActive {
            ScreenshotDemo.enrich(&d, target: target)
            cache[target.id] = d
            return d
        }
        // zoeken en koppelen met de opgeschoonde titel (zonder taallabel en IPTV-rommel)
        let cleaned = TitleCleaner.parse(d.title)
        let searchTitle = cleaned.title
        let yearInt = d.year.flatMap { Int($0.prefix(4)) } ?? cleaned.year

        // IMDb via OMDb
        let meta: TitleMetadata?
        switch target {
        case .movie(let m): meta = await MetadataService.shared.metadata(m, knownIMDb: d.imdbID)
        case .series(let s): meta = await MetadataService.shared.fetch(title: s.title, year: s.year, isShow: true, imdb: d.imdbID)
        }
        if let meta {
            d.imdbID = d.imdbID ?? meta.imdbID
            if let r = meta.imdbRating { d.ratings.insert(.init(source: "IMDb", value: r), at: 0) }
            d.overview = d.overview ?? meta.plot
            d.runtime = d.runtime ?? meta.runtime
            d.certification = meta.rated
            d.director = d.director ?? meta.director
            if d.genres.isEmpty, let g = meta.genre { d.genres = g.components(separatedBy: ", ") }
            if d.cast.isEmpty, let a = meta.actors { d.cast = a.components(separatedBy: ", ").map { TitleDetails.CastMember(name: $0) } }
            d.poster = d.poster ?? meta.poster
            d.trailerYouTubeID = d.trailerYouTubeID ?? meta.trailerYouTubeID
            d.traktSlug = meta.traktSlug
            d.seasonCount = meta.totalSeasons
        }

        // Trakt
        if let t = await TraktDetails.fetch(imdb: d.imdbID, title: searchTitle, year: yearInt, isShow: isShow) {
            d.imdbID = d.imdbID ?? t.imdb
            d.traktSlug = d.traktSlug ?? t.slug
            if let r = t.rating, r > 0 { d.ratings.append(.init(source: "Trakt", value: "\(Int((r * 10).rounded()))%")) }
            if d.overview?.isEmpty ?? true { d.overview = t.overview }
            if d.genres.isEmpty { d.genres = t.genres.map { $0.capitalized } }
            if d.runtime == nil, let rt = t.runtime { d.runtime = L("%d min", rt) }
            d.certification = d.certification ?? t.certification
            d.trailerYouTubeID = d.trailerYouTubeID ?? t.trailer.flatMap(MetadataService.youtubeID)
            if !t.cast.isEmpty && d.cast.allSatisfy({ $0.character == nil }) { d.cast = t.cast }
            if d.recommendations.isEmpty { d.recommendations = t.related }
            for (k, v) in t.episodes where d.episodeInfo[k] == nil { d.episodeInfo[k] = v }
            d.poster = d.poster ?? t.poster
            d.backdrop = d.backdrop ?? t.fanart
            d.logo = d.logo ?? t.logo
        }

        // TMDB (optioneel): foto's, logo, achtergrond, stills en teksten in de app-taal
        // build 111: bij een titel uit TMDB (Binnenkort / Nieuw op streamingdiensten) staat het TMDB-id in het id
        if let tm = await TMDB.details(imdb: d.imdbID, tmdbID: DiscoverItem.parse(target.id)?.tmdbID ?? tmdbHint,
                                       title: searchTitle, year: yearInt, isShow: isShow) {
            d.backdrop = tm.backdrop ?? d.backdrop
            d.logo = tm.logo ?? d.logo
            d.poster = d.poster ?? tm.poster
            if let o = tm.overview, !o.isEmpty, Localizer.shared.language != "en" { d.overview = o }
            else if d.overview?.isEmpty ?? true { d.overview = tm.overview }
            if !tm.cast.isEmpty { d.cast = tm.cast }
            if !tm.recommendations.isEmpty { d.recommendations = tm.recommendations }
            d.trailerYouTubeID = d.trailerYouTubeID ?? tm.trailer
            d.imdbID = d.imdbID ?? tm.imdb
            d.tmdbID = tm.id
            d.originalLanguage = tm.originalLanguage
            d.backdrops += tm.backdrops
        }
        d.backdrops = orderedUnique(([d.backdrop].compactMap { $0 } + d.backdrops)).filter { $0 != d.backdrop }
        // originele taal en TMDB-id onthouden voor de cover en voor automatische ondertitels (build 59)
        ContentLanguage.Facts.shared.set(id: target.id, original: d.originalLanguage, tmdbID: d.tmdbID)
        tmdbHint = nil
        cache[target.id] = d
        return d
    }

    /// Afleveringsdetails per seizoen (TMDB heeft stills + teksten in de app-taal).
    func seasonInfo(_ d: TitleDetails, season: Int) async -> [String: TitleDetails.EpisodeInfo] {
        guard let id = d.tmdbID else { return [:] }
        return await TMDB.season(tvID: id, season: season)
    }

    private var tmdbHint: Int?

    private func merge(xtream vi: XtreamClient.VodInfo.Info, into d: inout TitleDetails) {
        if let p = vi.plot ?? vi.description, !p.isEmpty { d.overview = p }
        if let i = vi.imdb_id, i.hasPrefix("tt") { d.imdbID = d.imdbID ?? i }
        d.backdrop = vi.backdrop_path?.first?.urlValue
        d.backdrops = vi.backdrop_path?.values.compactMap(\.urlValue) ?? []
        d.poster = d.poster ?? (vi.cover_big ?? vi.movie_image)?.urlValue
        if let g = vi.genre, !g.isEmpty { d.genres = g.components(separatedBy: CharacterSet(charactersIn: ",/")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let c = vi.cast ?? vi.actors, !c.isEmpty { d.cast = c.components(separatedBy: ",").map { TitleDetails.CastMember(name: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty } }
        d.director = vi.director.flatMap { $0.isEmpty ? nil : $0 }
        if let s = vi.duration_secs?.int, s > 0 { d.runtime = L("%d min", s / 60) }
        if let y = vi.releasedate, y.count >= 4 { d.year = d.year ?? String(y.prefix(4)) }
        if let t = Trailer.safeID(vi.youtube_trailer) { d.trailerYouTubeID = t }   // build 141: strikt
        tmdbHint = vi.tmdb_id?.int
    }

    private func merge(xtream si: XtreamClient.SeriesInfo, into d: inout TitleDetails) {
        if let i = si.info {
            if let p = i.plot, !p.isEmpty { d.overview = p }
            d.backdrop = i.backdrop_path?.first?.urlValue
            d.backdrops = i.backdrop_path?.values.compactMap(\.urlValue) ?? []
            if let g = i.genre, !g.isEmpty { d.genres = g.components(separatedBy: CharacterSet(charactersIn: ",/")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if let c = i.cast, !c.isEmpty { d.cast = c.components(separatedBy: ",").map { TitleDetails.CastMember(name: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty } }
            d.director = i.director.flatMap { $0.isEmpty ? nil : $0 }
            if let y = i.releaseDate, y.count >= 4 { d.year = d.year ?? String(y.prefix(4)) }
            if let t = Trailer.safeID(i.youtube_trailer) { d.trailerYouTubeID = t }   // build 141: strikt
            if let rt = i.episode_run_time?.int, rt > 0 { d.runtime = L("%d min", rt) }
            tmdbHint = i.tmdb?.int
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for (season, eps) in si.episodes ?? [:] {
            for e in eps {
                let s = e.season?.int ?? Int(season) ?? 1, n = e.episode_num?.int ?? 0
                d.episodeInfo["\(s)-\(n)"] = .init(title: e.title, overview: e.info?.plot, still: e.info?.movie_image?.urlValue,
                                                   airDate: (e.info?.releasedate ?? e.info?.air_date).flatMap { df.date(from: String($0.prefix(10))) },
                                                   runtime: e.info?.duration_secs?.int.map { $0 / 60 })
            }
        }
    }
}
