package nl.lrvdlinden.bingr

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonElement

// MARK: - Trakt: beschrijving, score, cast, aanbevelingen, afleveringen -------------

object TraktDetails {
    data class Result(
        val imdb: String?, val slug: String?, val overview: String?, val rating: Double?, val runtime: Int?,
        val genres: List<String> = emptyList(), val certification: String?, val trailer: String?,
        val poster: String?, val fanart: String?, val logo: String?,
        val cast: List<TitleDetails.CastMember> = emptyList(),
        val related: List<TitleDetails.Recommendation> = emptyList(),
        val episodes: Map<String, TitleDetails.EpisodeInfo> = emptyMap(),
    )

    /** Trakt-afbeelding: {"poster": ["walter-r2.trakt.tv/…"]} */
    fun image(images: JsonElement?, key: String): String? {
        val s = images.jStrings(key).firstOrNull() ?: return null
        return if (s.startsWith("http")) s else "https://$s"
    }

    private suspend fun get(path: String, query: List<Pair<String, String>>): JsonElement? =
        runCatching { Trakt.get(path, query, auth = false) }.getOrNull()

    suspend fun fetch(imdb: String?, title: String, year: Int?, isShow: Boolean): Result? {
        if (!Secrets.isSet(Secrets.traktClientID)) return null
        val type = if (isShow) "show" else "movie"
        fun media(hits: JsonElement?): JsonElement? = hits.jItems.firstOrNull()?.let { it.jO("movie") ?: it.jO("show") }
        var m: JsonElement? = null
        if (imdb != null) m = media(get("/search/imdb/$imdb", listOf("type" to type, "extended" to "full,images")))
        if (m == null) {
            val q = mutableListOf("query" to title, "extended" to "full,images", "limit" to "3")
            if (year != null) q.add("years" to year.toString())
            m = media(get("/search/$type", q))
        }
        val media = m ?: return null
        val ids = media.jO("ids")
        val slug = ids.jS("slug") ?: ids.jS("trakt") ?: return null
        val images = media.jO("images")
        val path = if (isShow) "shows" else "movies"

        return coroutineScope {
            val people = async { get("/$path/$slug/people", listOf("extended" to "images")) }
            val related = async { get("/$path/$slug/related", listOf("limit" to "15", "extended" to "images")) }
            val seasons = async { if (isShow) get("/shows/$slug/seasons", listOf("extended" to "episodes,full,images")) else null }

            val cast = people.await().jList("cast").take(20).mapNotNull { p ->
                val person = p.jO("person")
                val name = person.jS("name") ?: return@mapNotNull null
                TitleDetails.CastMember(name = name, role = p.jList("characters").firstOrNull().jFlex ?: p.jS("character"),
                    photo = image(person.jO("images"), "headshot"))
            }
            val rel = related.await().jItems.map { x ->
                TitleDetails.Recommendation(title = x.jS("title") ?: "?", year = x.jI("year"), poster = image(x.jO("images"), "poster"),
                    imdbID = x.jO("ids").jS("imdb"), isShow = isShow)
            }
            val eps = HashMap<String, TitleDetails.EpisodeInfo>()
            for (s in seasons.await().jItems) {
                for (e in s.jList("episodes")) {
                    val sn = e.jI("season") ?: continue
                    val n = e.jI("number") ?: continue
                    eps["$sn-$n"] = TitleDetails.EpisodeInfo(title = e.jS("title"), overview = e.jS("overview"),
                        still = image(e.jO("images"), "screenshot"), airDate = Net.parseISODate(e.jS("first_aired")),
                        runtime = e.jI("runtime"))
                }
            }
            Result(imdb = ids.jS("imdb"), slug = ids.jS("slug"), overview = media.jS("overview"), rating = media.jD("rating"),
                runtime = media.jI("runtime"), genres = media.jList("genres").mapNotNull { it.jFlex },
                certification = media.jS("certification"), trailer = media.jS("trailer"),
                poster = image(images, "poster"), fanart = image(images, "fanart"), logo = image(images, "logo"),
                cast = cast, related = rel, episodes = eps)
        }
    }
}

// MARK: - TMDB (optioneel) --------------------------------------------------------

/**
 * Alleen gebruikt als er een TMDB-sleutel is. Levert foto's van de cast, titel-logo's,
 * achtergronden, afleveringsstills en teksten in de app-taal. De score blijft IMDb + Trakt.
 */
object TMDB {
    data class Result(
        val id: Int, val imdb: String?, val overview: String?, val poster: String?, val backdrop: String?, val logo: String?,
        val trailer: String?, val cast: List<TitleDetails.CastMember> = emptyList(),
        val recommendations: List<TitleDetails.Recommendation> = emptyList(),
    )

    private val language: String
        get() {
            val l = Localizer.language
            return when {
                l == "zh-Hans" -> "zh-CN"
                l == "pt" -> "pt-PT"
                l.length == 2 -> "$l-${l.uppercase()}"
                else -> l
            }
        }

    private fun img(path: String?, size: String): String? =
        if (path.isNullOrEmpty()) null else "https://image.tmdb.org/t/p/$size$path"

    private suspend fun get(path: String, q: List<Pair<String, String>> = emptyList()): JsonElement? {
        val key = Secrets.tmdbAPIKey
        if (!Secrets.isSet(key)) return null
        val headers = HashMap<String, String>()
        val items = q.toMutableList()
        // v4-token (lang, begint met eyJ) als Bearer, anders v3-sleutel als query
        if (key.length > 40) headers["Authorization"] = "Bearer $key" else items.add("api_key" to key)
        val u = Net.url("https://api.themoviedb.org/3$path", items) ?: return null
        return runCatching { Net.json(u, headers) }.getOrNull()
    }

    private fun yearOf(s: String?): Int? = s?.take(4)?.toIntOrNull()

    /** Trending vandaag (Netflix-achtige Top 10): titels in de app-taal én origineel, met jaar. */
    suspend fun trending(shows: Boolean): List<ExternalTitle> {
        val out = ArrayList<ExternalTitle>()
        for (page in listOf("1", "2")) {
            val r = get(if (shows) "/trending/tv/day" else "/trending/movie/day", listOf("language" to language, "page" to page)) ?: break
            for (i in r.jList("results")) {
                val t = listOf("title", "name", "original_title", "original_name").mapNotNull { i.jS(it) }.filter { it.isNotEmpty() }
                val y = yearOf(i.jS("release_date") ?: i.jS("first_air_date"))
                if (t.isNotEmpty()) out.add(ExternalTitle(t, y))
            }
        }
        return out
    }

    suspend fun details(imdb: String?, tmdbID: Int?, title: String, year: Int?, isShow: Boolean): Result? {
        if (!Secrets.isSet(Secrets.tmdbAPIKey)) return null
        var id = tmdbID
        if (id == null && imdb != null) {
            val f = get("/find/$imdb", listOf("external_source" to "imdb_id"))
            id = f.jList(if (isShow) "tv_results" else "movie_results").firstOrNull().jI("id")
        }
        if (id == null) {
            val q = mutableListOf("query" to title)
            if (year != null) q.add((if (isShow) "first_air_date_year" else "year") to year.toString())
            id = get(if (isShow) "/search/tv" else "/search/movie", q).jList("results").firstOrNull().jI("id")
        }
        val tid = id ?: return null
        val lang = language
        val base = lang.take(2)
        val f = get(if (isShow) "/tv/$tid" else "/movie/$tid", listOf(
            "language" to lang,
            "append_to_response" to if (isShow) "aggregate_credits,recommendations,images,videos,external_ids" else "credits,recommendations,images,videos",
            "include_image_language" to "$base,en,null",
            "include_video_language" to "$base,en",
        )) ?: return null
        val logos = f.jO("images").jList("logos")
        val logo = logos.firstOrNull { it.jS("iso_639_1") == base } ?: logos.firstOrNull { it.jS("iso_639_1") == "en" } ?: logos.firstOrNull()
        val castSrc = f.jO(if (isShow) "aggregate_credits" else "credits").jList("cast")
        return Result(
            id = f.jI("id") ?: tid,
            imdb = f.jS("imdb_id") ?: f.jO("external_ids").jS("imdb_id"),
            overview = f.jS("overview"),
            poster = img(f.jS("poster_path"), "w780"), backdrop = img(f.jS("backdrop_path"), "w1280"),
            logo = img(logo.jS("file_path"), "w500"),
            trailer = f.jO("videos").jList("results").firstOrNull { it.jS("site") == "YouTube" && it.jS("type") == "Trailer" }.jS("key"),
            cast = castSrc.take(20).mapNotNull { c ->
                val name = c.jS("name") ?: return@mapNotNull null
                TitleDetails.CastMember(name = name, role = c.jS("character") ?: c.jList("roles").firstOrNull().jS("character"),
                    photo = img(c.jS("profile_path"), "w185"))
            },
            recommendations = f.jO("recommendations").jList("results").take(15).map { r ->
                TitleDetails.Recommendation(title = r.jS("title") ?: r.jS("name") ?: "?",
                    year = yearOf(r.jS("release_date") ?: r.jS("first_air_date")),
                    poster = img(r.jS("poster_path"), "w342"), imdbID = null, isShow = isShow)
            },
        )
    }

    /** Afleveringen van één seizoen; key "s-e". */
    suspend fun season(tvID: Int, season: Int): Map<String, TitleDetails.EpisodeInfo> {
        val r = get("/tv/$tvID/season/$season", listOf("language" to language))
        val out = HashMap<String, TitleDetails.EpisodeInfo>()
        for (e in r.jList("episodes")) {
            val n = e.jI("episode_number") ?: continue
            out["$season-$n"] = TitleDetails.EpisodeInfo(title = e.jS("name"), overview = e.jS("overview"),
                still = img(e.jS("still_path"), "w500"), airDate = Net.parseDay(e.jS("air_date")), runtime = e.jI("runtime"))
        }
        return out
    }
}
