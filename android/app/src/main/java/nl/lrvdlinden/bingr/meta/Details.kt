package nl.lrvdlinden.bingr

import kotlinx.serialization.json.JsonObject
import java.util.Locale

/**
 * Alles wat de detailpagina laat zien, samengesteld uit meerdere bronnen (= DetailsService.swift):
 * 1. de afspeellijst zelf (Xtream-info, Plex/Jellyfin) — werkt altijd, zonder sleutels
 * 2. IMDb via OMDb (score, plot, cast)
 * 3. Trakt (beschrijving, %-score, genres, cast, aanbevelingen, afleveringen)
 * 4. TMDB, optioneel (foto's van cast, titel-logo, achtergrond, stills, teksten in de app-taal)
 */
data class TitleDetails(
    var title: String,
    var year: String? = null,
    var runtime: String? = null,
    var overview: String? = null,
    var genres: List<String> = emptyList(),
    var certification: String? = null,
    var poster: String? = null,
    var backdrop: String? = null,
    var logo: String? = null,
    var trailerYouTubeID: String? = null,
    var imdbID: String? = null,
    var traktSlug: String? = null,
    var ratings: List<Rating> = emptyList(),
    var cast: List<CastMember> = emptyList(),
    var director: String? = null,
    var recommendations: List<Recommendation> = emptyList(),
    /** key "s-e" */
    var episodeInfo: Map<String, EpisodeInfo> = emptyMap(),
    var seasonCount: Int? = null,
    var tmdbID: Int? = null,
) {
    data class Rating(val source: String, val value: String) { val id: String get() = source }
    data class CastMember(val name: String, val role: String? = null, val photo: String? = null) {
        val id: String get() = name + (role ?: "")
    }
    data class Recommendation(val title: String, val year: Int?, val poster: String?, val imdbID: String?, val isShow: Boolean) {
        val id: String get() = imdbID ?: title
    }
    /** [airDate] in epoch-ms, [runtime] in minuten */
    data class EpisodeInfo(val title: String?, val overview: String?, val still: String?, val airDate: Long?, val runtime: Int?)
}

object Details {
    private val cache = HashMap<String, TitleDetails>()

    /** Basisgegevens uit de afspeellijst + alle verrijkingen (gecachet per item). */
    suspend fun load(t: DetailTarget, knownIMDb: String? = null): TitleDetails {
        synchronized(cache) { cache[t.id] }?.let { return it.copy() }
        val isShow = t.isSeries
        var tmdbHint: Int? = null
        val d: TitleDetails
        when (t) {
            is DetailTarget.MovieT -> {
                val m = t.movie
                d = TitleDetails(title = m.title, year = m.year?.toString(), overview = m.plot, poster = m.poster, imdbID = knownIMDb ?: m.imdbID)
                m.rating?.takeIf { it > 0 }?.let { d.ratings += TitleDetails.Rating(L("Playlist"), String.format(Locale.US, "%.1f", it)) }
                Playlists.xtreamVodInfo(m)?.let { tmdbHint = mergeVod(it, d) }
            }
            is DetailTarget.SeriesT -> {
                val s = t.series
                d = TitleDetails(title = s.title, year = s.year?.toString(), overview = s.plot, poster = s.poster, imdbID = knownIMDb ?: s.imdbID)
                s.rating?.takeIf { it > 0 }?.let { d.ratings += TitleDetails.Rating(L("Playlist"), String.format(Locale.US, "%.1f", it)) }
                Playlists.xtreamSeriesInfo(s)?.let { tmdbHint = mergeSeries(it, d) }
            }
        }
        val yearInt = d.year?.take(4)?.toIntOrNull()

        // IMDb via OMDb
        val meta = when (t) {
            is DetailTarget.MovieT -> Metadata.metadata(t.movie, knownIMDb = d.imdbID)
            is DetailTarget.SeriesT -> Metadata.fetch(t.series.title, t.series.year, true, d.imdbID)
        }
        if (meta != null) {
            d.imdbID = d.imdbID ?: meta.imdbID
            meta.imdbRating?.let { d.ratings = listOf(TitleDetails.Rating("IMDb", it)) + d.ratings }
            d.overview = d.overview ?: meta.plot
            d.runtime = d.runtime ?: meta.runtime
            d.certification = meta.rated
            d.director = d.director ?: meta.director
            if (d.genres.isEmpty()) meta.genre?.let { d.genres = it.split(", ") }
            if (d.cast.isEmpty()) meta.actors?.let { a -> d.cast = a.split(", ").map { TitleDetails.CastMember(it) } }
            d.poster = d.poster ?: meta.poster
            d.trailerYouTubeID = d.trailerYouTubeID ?: meta.trailerYouTubeID
            d.traktSlug = meta.traktSlug
            d.seasonCount = meta.totalSeasons
        }

        // Trakt
        TraktDetails.fetch(d.imdbID, d.title, yearInt, isShow)?.let { tr ->
            d.imdbID = d.imdbID ?: tr.imdb
            d.traktSlug = d.traktSlug ?: tr.slug
            tr.rating?.takeIf { it > 0 }?.let { d.ratings += TitleDetails.Rating("Trakt", "${Math.round(it * 10)}%") }
            if (d.overview.isNullOrEmpty()) d.overview = tr.overview
            if (d.genres.isEmpty()) d.genres = tr.genres.map { g -> g.replaceFirstChar { it.titlecase(Locale.getDefault()) } }
            if (d.runtime == null) tr.runtime?.let { d.runtime = L("%d min", it) }
            d.certification = d.certification ?: tr.certification
            d.trailerYouTubeID = d.trailerYouTubeID ?: tr.trailer?.let { Metadata.youtubeID(it) }
            if (tr.cast.isNotEmpty() && d.cast.all { it.role == null }) d.cast = tr.cast
            if (d.recommendations.isEmpty()) d.recommendations = tr.related
            val eps = d.episodeInfo.toMutableMap()
            for ((k, v) in tr.episodes) if (eps[k] == null) eps[k] = v
            d.episodeInfo = eps
            d.poster = d.poster ?: tr.poster
            d.backdrop = d.backdrop ?: tr.fanart
            d.logo = d.logo ?: tr.logo
        }

        // TMDB (optioneel): foto's, logo, achtergrond, stills en teksten in de app-taal
        TMDB.details(d.imdbID, tmdbHint, d.title, yearInt, isShow)?.let { tm ->
            d.backdrop = tm.backdrop ?: d.backdrop
            d.logo = tm.logo ?: d.logo
            d.poster = d.poster ?: tm.poster
            val o = tm.overview
            if (!o.isNullOrEmpty() && Localizer.language != "en") d.overview = o
            else if (d.overview.isNullOrEmpty()) d.overview = tm.overview
            if (tm.cast.isNotEmpty()) d.cast = tm.cast
            if (tm.recommendations.isNotEmpty()) d.recommendations = tm.recommendations
            d.trailerYouTubeID = d.trailerYouTubeID ?: tm.trailer
            d.imdbID = d.imdbID ?: tm.imdb
            d.tmdbID = tm.id
        }
        synchronized(cache) { cache[t.id] = d.copy() }
        return d
    }

    /** Afleveringsdetails per seizoen (TMDB heeft stills + teksten in de app-taal). Key "s-e". */
    suspend fun season(tmdbTvID: Int, season: Int): Map<String, TitleDetails.EpisodeInfo> = TMDB.season(tmdbTvID, season)

    fun clearCache() = synchronized(cache) { cache.clear() }

    private fun splitList(s: String): List<String> =
        s.split(',', '/').map { it.trim() }.filter { it.isNotEmpty() }

    /** Xtream get_vod_info → details; geeft de TMDB-id terug (hint). */
    private fun mergeVod(vi: JsonObject, d: TitleDetails): Int? {
        val p = vi.jS("plot") ?: vi.jS("description")
        if (!p.isNullOrEmpty()) d.overview = p
        vi.jS("imdb_id")?.takeIf { it.startsWith("tt") }?.let { d.imdbID = d.imdbID ?: it }
        d.backdrop = Net.urlValue(vi.jStrings("backdrop_path").firstOrNull())
        d.poster = d.poster ?: Net.urlValue(vi.jS("cover_big") ?: vi.jS("movie_image"))
        vi.jS("genre")?.takeIf { it.isNotEmpty() }?.let { d.genres = splitList(it) }
        val c = vi.jS("cast") ?: vi.jS("actors")
        if (!c.isNullOrEmpty()) d.cast = c.split(',').map { TitleDetails.CastMember(it.trim()) }.filter { it.name.isNotEmpty() }
        d.director = vi.jS("director")?.takeIf { it.isNotEmpty() }
        vi.jI("duration_secs")?.takeIf { it > 0 }?.let { d.runtime = L("%d min", it / 60) }
        vi.jS("releasedate")?.takeIf { it.length >= 4 }?.let { d.year = d.year ?: it.take(4) }
        vi.jS("youtube_trailer")?.takeIf { it.isNotEmpty() }?.let { d.trailerYouTubeID = it }
        return vi.jI("tmdb_id")
    }

    /** Xtream get_series_info → details + afleveringsinfo; geeft de TMDB-id terug (hint). */
    private fun mergeSeries(si: JsonObject, d: TitleDetails): Int? {
        var hint: Int? = null
        si.jO("info")?.let { i ->
            i.jS("plot")?.takeIf { it.isNotEmpty() }?.let { d.overview = it }
            d.backdrop = Net.urlValue(i.jStrings("backdrop_path").firstOrNull())
            i.jS("genre")?.takeIf { it.isNotEmpty() }?.let { d.genres = splitList(it) }
            i.jS("cast")?.takeIf { it.isNotEmpty() }?.let { c ->
                d.cast = c.split(',').map { TitleDetails.CastMember(it.trim()) }.filter { it.name.isNotEmpty() }
            }
            d.director = i.jS("director")?.takeIf { it.isNotEmpty() }
            i.jS("releaseDate")?.takeIf { it.length >= 4 }?.let { d.year = d.year ?: it.take(4) }
            i.jS("youtube_trailer")?.takeIf { it.isNotEmpty() }?.let { d.trailerYouTubeID = it }
            i.jI("episode_run_time")?.takeIf { it > 0 }?.let { d.runtime = L("%d min", it) }
            hint = i.jI("tmdb")
        }
        val eps = d.episodeInfo.toMutableMap()
        val x = XtreamClient.episodeGroups(si)
        for ((season, list) in x) {
            for (e in list) {
                val s = e.jI("season") ?: season.toIntOrNull() ?: 1
                val n = e.jI("episode_num") ?: 0
                val info = e.jO("info")
                eps["$s-$n"] = TitleDetails.EpisodeInfo(
                    title = e.jS("title"), overview = info.jS("plot"), still = Net.urlValue(info.jS("movie_image")),
                    airDate = Net.parseDay(info.jS("releasedate") ?: info.jS("air_date")),
                    runtime = info.jI("duration_secs")?.let { it / 60 })
            }
        }
        d.episodeInfo = eps
        return hint
    }
}
