package nl.lrvdlinden.bingr

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import java.util.TimeZone

/** Stalker / Ministra (MAC-portal). Ondersteunt live TV en VOD. */
class StalkerClient(source: PlaylistSource) {
    val portal: String
    val mac: String = source.macAddress.uppercase()
    @Volatile private var endpoint: String? = null
    @Volatile private var token: String? = null
    private val lock = Mutex()

    init {
        var p = Net.normalizedServer(source.serverURL)
        if (p.endsWith("/c")) p = p.dropLast(2)
        portal = p
    }

    companion object {
        val handshakeError: ServiceException
            get() = ServiceException(L("Couldn't connect to the portal. Check the portal URL and MAC address."))
    }

    private val headers: Map<String, String>
        get() {
            val h = mutableMapOf(
                "Cookie" to "mac=$mac; stb_lang=en; timezone=${TimeZone.getDefault().id}",
                "User-Agent" to "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3",
                "X-User-Agent" to "Model: MAG250; Link: WiFi",
            )
            token?.let { h["Authorization"] = "Bearer $it" }
            return h
        }

    private fun url(q: List<Pair<String, String>>, base: String? = null): String? {
        val b = base ?: endpoint ?: return null
        return Net.url(b, q + ("JsHttpRequest" to "1-xml"))
    }

    /** "js" uit het antwoord. */
    private suspend fun js(u: String): JsonElement? = Net.json(u, headers).jObj?.get("js")

    suspend fun connect(): Unit = lock.withLock {
        val candidates = listOf("$portal/portal.php", "$portal/server/load.php",
            "$portal/stalker_portal/server/load.php", "$portal/c/portal.php")
        for (base in candidates) {
            val u = url(listOf("type" to "stb", "action" to "handshake", "token" to ""), base) ?: continue
            token = null
            val t = runCatching { js(u).jS("token") }.getOrNull()
            if (!t.isNullOrEmpty()) {
                endpoint = base; token = t
                url(listOf("type" to "stb", "action" to "get_profile", "hd" to "1"))?.let { p ->
                    runCatching { Net.text(p, headers) }
                }
                return@withLock
            }
        }
        throw handshakeError
    }

    /** Bibliotheek ophalen; omzetten van (grote) lijsten op Dispatchers.Default. */
    suspend fun library(): Library = withContext(Dispatchers.Default) { loadLibrary() }

    private suspend fun loadLibrary(): Library {
        if (token == null) connect()
        val other = L("Other")
        var channels = emptyList<Channel>()
        val movies = ArrayList<Movie>()
        val series = ArrayList<Series>()

        val g = url(listOf("type" to "itv", "action" to "get_genres"))
        val c = url(listOf("type" to "itv", "action" to "get_all_channels"))
        if (g != null && c != null) {
            val genres = runCatching { js(g).jItems }.getOrDefault(emptyList())
            val gMap = HashMap<String, String>()
            for (x in genres) { val id = x.jS("id") ?: continue; if (id !in gMap) gMap[id] = x.jS("title") ?: other }
            val chans = runCatching { js(c).jList("data") }.getOrDefault(emptyList())
            channels = chans.mapNotNull { ch ->
                val id = ch.jS("id") ?: return@mapNotNull null
                Channel(id = "st$id", name = ch.jS("name") ?: "Channel", logo = Net.urlValue(ch.jS("logo")),
                    group = gMap[ch.jS("tv_genre_id") ?: ""] ?: other,
                    streamURL = directURL(ch.jS("cmd")), epgID = ch.jS("xmltv_id"), number = ch.jI("number"),
                    catchupDays = (ch.jI("tv_archive_duration") ?: 0) / 24, stalkerCmd = ch.jS("cmd"))
            }
        }

        val vc = url(listOf("type" to "vod", "action" to "get_categories"))
        if (vc != null) {
            val cats = runCatching { js(vc).jItems }.getOrDefault(emptyList())
            for (cat in cats.take(40)) {
                val cid = cat.jS("id") ?: continue
                if (cid == "*") continue
                for (page in 1..3) {   // eerste ~3 pagina's per categorie
                    val u = url(listOf("type" to "vod", "action" to "get_ordered_list", "category" to cid,
                        "p" to page.toString(), "sortby" to "added")) ?: break
                    val items = runCatching { js(u).jList("data") }.getOrDefault(emptyList())
                    if (items.isEmpty()) break
                    for (v in items) {
                        val id = v.jS("id") ?: continue
                        val p = TitleCleaner.parse(v.jS("name") ?: "")
                        if (v.jI("is_series") == 1) {
                            series.add(Series(id = "sts$id", title = p.title, year = v.jI("year") ?: p.year,
                                poster = Net.urlValue(v.jS("screenshot_uri")), group = cat.jS("title") ?: L("Series"),
                                plot = v.jS("description"), rating = v.jD("rating_imdb")))
                        } else {
                            movies.add(Movie(id = "stv$id", title = p.title, year = v.jI("year") ?: p.year,
                                poster = Net.urlValue(v.jS("screenshot_uri")), group = cat.jS("title") ?: L("Movies"),
                                rating = v.jD("rating_imdb"), plot = v.jS("description"), stalkerCmd = v.jS("cmd")))
                        }
                    }
                }
            }
        }
        return Library(channels = channels, movies = movies, series = series)
    }

    /** Vraagt een tijdelijke stream-link aan bij het portal. */
    suspend fun createLink(cmd: String, type: MediaType): String? {
        if (token == null) connect()
        val t = if (type == MediaType.LIVE) "itv" else "vod"
        val u = url(listOf("type" to t, "action" to "create_link", "cmd" to cmd, "forced_storage" to "undefined",
            "disable_ad" to "0")) ?: return null
        return directURL(js(u).jS("cmd"))
    }

    suspend fun shortEPG(channelID: String): List<EPGProgram> {
        if (token == null) runCatching { connect() }
        val id = channelID.removePrefix("st")
        val u = url(listOf("type" to "itv", "action" to "get_short_epg", "ch_id" to id, "size" to "10")) ?: return emptyList()
        val items = runCatching { js(u).jItems }.getOrDefault(emptyList())
        return items.mapNotNull { i ->
            val s = i.jD("start_timestamp") ?: return@mapNotNull null
            val e = i.jD("stop_timestamp") ?: return@mapNotNull null
            EPGProgram(channelID = channelID, title = i.jS("name") ?: "", description = i.jS("descr"),
                start = (s * 1000).toLong(), end = (e * 1000).toLong())
        }
    }

    private fun directURL(cmd: String?): String? {
        var c = cmd ?: return null
        for (prefix in listOf("ffmpeg ", "ffrt ", "auto ")) if (c.startsWith(prefix)) c = c.drop(prefix.length)
        c = c.trim()
        if (!c.lowercase().startsWith("http") || c.contains("localhost")) return null
        return c
    }
}
