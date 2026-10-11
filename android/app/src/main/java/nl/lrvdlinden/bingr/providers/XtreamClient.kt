package nl.lrvdlinden.bingr

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Xtream Codes player_api.php */
class XtreamClient(source: PlaylistSource, val password: String) {
    val server: String = Net.normalizedServer(source.serverURL)
    val username: String = source.username
    val preferHLS: Boolean = source.preferHLS

    private fun api(action: String? = null, extra: List<Pair<String, String>> = emptyList()): String? {
        val q = mutableListOf("username" to username, "password" to password)
        if (action != null) q.add("action" to action)
        q.addAll(extra)
        return Net.url("$server/player_api.php", q)
    }

    companion object {
        val authError: ServiceException
            get() = ServiceException(L("Couldn't sign in to the server. Check the server, username and password."))

        /** Afleveringen per seizoen: object {"1": [...]} of (bij sommige panelen) een lijst met lijsten. */
        fun episodeGroups(info: JsonElement?): List<Pair<String, List<JsonElement>>> =
            when (val eps = info.jObj?.get("episodes")) {
                is JsonObject -> eps.entries.map { (k, v) -> k to v.jItems }
                is JsonArray -> eps.mapIndexed { i, v ->
                    when (v) {
                        is JsonArray -> (i + 1).toString() to v.toList()
                        else -> (v.jS("season") ?: (i + 1).toString()) to listOf(v)
                    }
                }
                else -> emptyList()
            }
    }

    // MARK: calls

    suspend fun authenticate() {
        val u = api() ?: throw Net.badURL()
        val r = Net.json(u)
        if (r.jO("user_info").jI("auth") != 1) throw authError
    }

    private suspend fun list(action: String): List<JsonElement> {
        val u = api(action) ?: return emptyList()
        return runCatching { Net.json(u).jItems }.getOrDefault(emptyList())
    }

    suspend fun library(): Library = coroutineScope {
        val liveCats = async { list("get_live_categories") }
        val live = async { list("get_live_streams") }
        val vodCats = async { list("get_vod_categories") }
        val vod = async { list("get_vod_streams") }
        val serCats = async { list("get_series_categories") }
        val ser = async { list("get_series") }

        val other = L("Other")
        fun map(cats: List<JsonElement>): Map<String, String> {
            val m = HashMap<String, String>()
            for (c in cats) { val id = c.jS("category_id") ?: continue; if (id !in m) m[id] = c.jS("category_name") ?: other }
            return m
        }
        val lcMap = map(liveCats.await()); val vcMap = map(vodCats.await()); val scMap = map(serCats.await())
        val liveExt = if (preferHLS) "m3u8" else "ts"

        val channels = live.await().mapNotNull { l ->
            val sid = l.jS("stream_id") ?: return@mapNotNull null
            Channel(id = "x$sid", name = l.jS("name") ?: "Channel", logo = Net.urlValue(l.jS("stream_icon")),
                group = lcMap[l.jS("category_id") ?: ""] ?: other,
                streamURL = "$server/live/$username/$password/$sid.$liveExt",
                epgID = l.jS("epg_channel_id")?.takeIf { it.isNotEmpty() },
                number = l.jI("num"),
                catchupDays = if (l.jI("tv_archive") == 1) (l.jI("tv_archive_duration") ?: 0) else 0)
        }
        val movies = vod.await().mapNotNull { v ->
            val sid = v.jS("stream_id") ?: return@mapNotNull null
            val p = TitleCleaner.parse(v.jS("name") ?: "")
            Movie(id = "xv$sid", title = p.title, year = v.jI("year") ?: p.year, poster = Net.urlValue(v.jS("stream_icon")),
                group = vcMap[v.jS("category_id") ?: ""] ?: other,
                streamURL = "$server/movie/$username/$password/$sid.${v.jS("container_extension") ?: "mp4"}",
                rating = v.jD("rating"),
                addedAt = v.jD("added")?.let { (it * 1000).toLong() },
                xtreamVodID = sid.toIntOrNull())
        }
        val series = ser.await().mapNotNull { s ->
            val sid = s.jI("series_id") ?: return@mapNotNull null
            val p = TitleCleaner.parse(s.jS("name") ?: "")
            val y = s.jI("year") ?: s.jS("releaseDate")?.take(4)?.toIntOrNull() ?: p.year
            Series(id = "xs$sid", title = p.title, year = y, poster = Net.urlValue(s.jS("cover")),
                group = scMap[s.jS("category_id") ?: ""] ?: other,
                plot = s.jS("plot"), rating = s.jD("rating"), xtreamSeriesID = sid)
        }
        Library(channels = channels, movies = movies, series = series)
    }

    suspend fun episodes(series: Series): List<Episode> {
        val sid = series.xtreamSeriesID ?: return emptyList()
        val u = api("get_series_info", listOf("series_id" to sid.toString())) ?: return emptyList()
        val info = Net.json(u)
        val out = ArrayList<Episode>()
        for ((seasonKey, eps) in episodeGroups(info)) {
            for (e in eps) {
                val eid = e.jS("id") ?: continue
                val i = e.jO("info")
                out.add(Episode(id = "xe$eid", seriesID = series.id,
                    season = e.jI("season") ?: seasonKey.toIntOrNull() ?: 1,
                    number = e.jI("episode_num") ?: 0,
                    title = e.jS("title") ?: L("Episode"),
                    streamURL = "$server/series/$username/$password/$eid.${e.jS("container_extension") ?: "mp4"}",
                    still = Net.urlValue(i.jS("movie_image")), plot = i.jS("plot"),
                    durationSeconds = i.jI("duration_secs")))
            }
        }
        return out.sortedWith(compareBy<Episode>({ it.season }, { it.number }))
    }

    /** Ruwe get_series_info (voor de detailpagina). */
    suspend fun seriesInfo(seriesID: Int): JsonObject? {
        val u = api("get_series_info", listOf("series_id" to seriesID.toString())) ?: return null
        return runCatching { Net.json(u).jObj }.getOrNull()
    }

    /** "info" uit get_vod_info (voor de detailpagina). */
    suspend fun vodInfo(vodID: Int): JsonObject? {
        val u = api("get_vod_info", listOf("vod_id" to vodID.toString())) ?: return null
        return runCatching { Net.json(u).jO("info") }.getOrNull()
    }

    val xmltvURL: String? get() = Net.url("$server/xmltv.php", listOf("username" to username, "password" to password))

    /** Catch-up / terugkijken (tv_archive). */
    fun catchupURL(channel: Channel, start: Long, end: Long): String? {
        if (!channel.id.startsWith("x")) return null
        val sid = channel.id.drop(1)
        val f = SimpleDateFormat("yyyy-MM-dd:HH-mm", Locale.US).apply { timeZone = TimeZone.getDefault() }
        val minutes = ((end - start) / 60_000).toInt()
        return "$server/timeshift/$username/$password/$minutes/${f.format(java.util.Date(start))}/$sid.ts"
    }
}
