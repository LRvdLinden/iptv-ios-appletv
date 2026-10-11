package nl.lrvdlinden.bingr

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Request
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.TimeUnit

// MARK: - Gedeelde helpers ------------------------------------------------------

object DeviceInfo {
    val id: String
        get() = Prefs.string("device.id") ?: UUID.randomUUID().toString().also { Prefs.put("device.id", it) }
    val name: String get() = if (AppState.isTV) "Android TV" else "Android"
}

/** Sessie bij Plex/Jellyfin/Emby (bewaard als JSON in [Store.secret] onder [Playlists.sessionKey]). */
@Serializable
data class ServerSession(val token: String, val userID: String? = null, val serverURI: String)

private fun isoUTC(ms: Long): String =
    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(java.util.Date(ms))

// MARK: - Jellyfin / Emby ------------------------------------------------------

/** Jellyfin en Emby delen dezelfde API. */
class JellyfinClient(source: PlaylistSource, session: ServerSession?) {
    val server: String = Net.normalizedServer(source.serverURL)
    val isEmby: Boolean = source.kind == PlaylistKind.EMBY
    val token: String? = session?.token
    val userID: String? = session?.userID

    companion object {
        val notLoggedIn: ServiceException get() = ServiceException(L("Not signed in. Edit the playlist and sign in again."))
    }

    private val authHeader: Map<String, String>
        get() {
            var v = "MediaBrowser Client=\"Bingr\", Device=\"${DeviceInfo.name}\", DeviceId=\"${DeviceInfo.id}\", Version=\"1.1.0\""
            if (token != null) v += ", Token=\"$token\""
            return mapOf("X-Emby-Authorization" to v, "Authorization" to v)
        }

    private fun url(path: String, q: Map<String, String> = emptyMap()): String? =
        Net.url(server + path, q.entries.sortedBy { it.key }.map { it.key to it.value })

    suspend fun login(username: String, password: String): ServerSession {
        val u = url("/Users/AuthenticateByName") ?: throw Net.badURL()
        val body = buildJsonObject { put("Username", username); put("Pw", password); put("Password", password) }
        val r = Net.parse(Net.send(u, "POST", authHeader, body))
        val token = r.jS("AccessToken") ?: throw Net.decoding("AccessToken")
        val uid = r.jO("User").jS("Id") ?: throw Net.decoding("User.Id")
        return ServerSession(token = token, userID = uid, serverURI = server)
    }

    fun image(id: String): String? = url("/Items/$id/Images/Primary", mapOf("maxHeight" to "600", "quality" to "90"))
    fun stream(id: String): String? = url("/Videos/$id/stream", mapOf("static" to "true", "api_key" to (token ?: "")))

    private suspend fun fetchItems(u: String): List<JsonElement> = Net.parse(Net.send(u, headers = authHeader)).jList("Items")

    suspend fun library(): Library {
        val uid = userID ?: throw notLoggedIn
        suspend fun items(type: String): List<JsonElement> {
            val u = url("/Users/$uid/Items", mapOf("IncludeItemTypes" to type, "Recursive" to "true",
                "Fields" to "ProviderIds,Overview,Genres,DateCreated", "SortBy" to "DateCreated",
                "SortOrder" to "Descending", "Limit" to "3000")) ?: return emptyList()
            return fetchItems(u)
        }
        val moviesL = L("Movies"); val seriesL = L("Series")
        val movies = items("Movie").mapNotNull { i ->
            val id = i.jS("Id") ?: return@mapNotNull null
            Movie(id = "jf$id", title = i.jS("Name") ?: "?", year = i.jI("ProductionYear"), poster = image(id),
                group = i.jList("Genres").firstOrNull().jFlex ?: moviesL, streamURL = stream(id),
                imdbID = i.jO("ProviderIds").jS("Imdb"), rating = i.jD("CommunityRating"), plot = i.jS("Overview"),
                addedAt = Net.parseISODate(i.jS("DateCreated")))
        }
        val series = items("Series").mapNotNull { i ->
            val id = i.jS("Id") ?: return@mapNotNull null
            Series(id = "jfs$id", title = i.jS("Name") ?: "?", year = i.jI("ProductionYear"), poster = image(id),
                group = i.jList("Genres").firstOrNull().jFlex ?: seriesL, imdbID = i.jO("ProviderIds").jS("Imdb"),
                plot = i.jS("Overview"), rating = i.jD("CommunityRating"), remoteID = id)
        }
        // Live TV (optioneel)
        var channels = emptyList<Channel>()
        val epg = HashMap<String, MutableList<EPGProgram>>()
        val cu = url("/LiveTv/Channels", mapOf("UserId" to uid, "EnableImages" to "true"))
        val ch = cu?.let { runCatching { fetchItems(it) }.getOrNull() }
        if (ch != null) {
            channels = ch.mapNotNull { c ->
                val id = c.jS("Id") ?: return@mapNotNull null
                Channel(id = "jfc$id", name = c.jS("Name") ?: "?", logo = image(id), group = "Live TV",
                    streamURL = stream(id), epgID = id, number = c.jS("Number")?.toIntOrNull())
            }
            val now = System.currentTimeMillis()
            val pu = url("/LiveTv/Programs", mapOf("UserId" to uid, "MinEndDate" to isoUTC(now),
                "MaxStartDate" to isoUTC(now + 86_400_000L * 2)))
            val progs = if (ch.isNotEmpty() && pu != null) runCatching { fetchItems(pu) }.getOrNull() else null
            for (p in progs ?: emptyList()) {
                val cid = p.jS("ChannelId") ?: continue
                val s = Net.parseISODate(p.jS("StartDate")) ?: continue
                val e = Net.parseISODate(p.jS("EndDate")) ?: continue
                epg.getOrPut(cid) { ArrayList() }.add(EPGProgram(channelID = cid, title = p.jS("Name") ?: "",
                    description = p.jS("Overview"), start = s, end = e))
            }
        }
        return Library(channels = channels, movies = movies, series = series,
            epg = epg.mapValues { (_, v) -> v.sortedBy { it.start } })
    }

    suspend fun episodes(series: Series): List<Episode> {
        val sid = series.remoteID ?: return emptyList()
        val uid = userID ?: return emptyList()
        val u = url("/Shows/$sid/Episodes", mapOf("UserId" to uid, "Fields" to "Overview")) ?: return emptyList()
        return fetchItems(u).mapNotNull { e ->
            val id = e.jS("Id") ?: return@mapNotNull null
            Episode(id = "jfe$id", seriesID = series.id, season = e.jI("ParentIndexNumber") ?: 1, number = e.jI("IndexNumber") ?: 0,
                title = e.jS("Name") ?: "", streamURL = stream(id), still = image(id), plot = e.jS("Overview"),
                durationSeconds = e.jL("RunTimeTicks")?.let { (it / 10_000_000).toInt() })
        }
    }
}

// MARK: - Plex ------------------------------------------------------------------

/** Koppelcode voor plex.tv/link. */
data class PlexPin(val id: Long, val code: String)

/** Plex: inloggen met een koppelcode op plex.tv/link (werkt ook op Android TV). */
class PlexClient(val session: ServerSession) {
    companion object {
        val headers: Map<String, String>
            get() = mapOf("X-Plex-Product" to "Bingr", "X-Plex-Client-Identifier" to DeviceInfo.id, "X-Plex-Version" to "1.1.0",
                "X-Plex-Device-Name" to DeviceInfo.name, "X-Plex-Platform" to (if (AppState.isTV) "Android TV" else "Android"))

        suspend fun createPin(): PlexPin {
            val r = Net.parse(Net.send("https://plex.tv/api/v2/pins?strong=false", "POST", headers))
            val id = r.jL("id") ?: throw Net.decoding("id")
            return PlexPin(id, r.jS("code") ?: throw Net.decoding("code"))
        }

        /** Eén keer kijken of de code bevestigd is: token of null. */
        suspend fun checkPin(pin: PlexPin): String? {
            val r = Net.parse(Net.send("https://plex.tv/api/v2/pins/${pin.id}", headers = headers))
            return r.jS("authToken")?.takeIf { it.isNotEmpty() }
        }

        suspend fun waitForToken(pin: PlexPin): String {
            repeat(150) {     // ±5 minuten
                delay(2_000)
                checkPin(pin)?.let { return it }
            }
            throw ServiceException(L("The code has expired. Please try again."))
        }

        /** Zoekt de eerste bereikbare Plex Media Server van dit account. */
        suspend fun discoverServer(userToken: String): ServerSession {
            val r = Net.parse(Net.send("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1",
                headers = headers + ("X-Plex-Token" to userToken)))
            val servers = r.jItems.filter { (it.jS("provides") ?: "").contains("server") }
            val quick = Http.client.newBuilder().callTimeout(4, TimeUnit.SECONDS).connectTimeout(4, TimeUnit.SECONDS).build()
            for (s in servers) {
                fun rank(c: JsonElement) = if (c.jB("local") == true) 0 else if (c.jB("relay") == true) 2 else 1
                val conns = s.jList("connections").sortedBy { rank(it) }
                for (c in conns) {
                    val uri = c.jS("uri") ?: continue
                    val ok = withContext(Dispatchers.IO) {
                        runCatching {
                            quick.newCall(Request.Builder().url("$uri/identity").header("User-Agent", Http.USER_AGENT).build())
                                .execute().use { it.code == 200 }
                        }.getOrDefault(false)
                    }
                    if (ok) return ServerSession(token = s.jS("accessToken") ?: userToken, userID = s.jS("name"), serverURI = uri)
                }
            }
            throw ServiceException(L("No reachable server found on this account."))
        }
    }

    private fun url(path: String, q: Map<String, String> = emptyMap()): String? =
        Net.url(session.serverURI + path, (q + ("X-Plex-Token" to session.token)).map { it.key to it.value })

    private suspend fun get(path: String, q: Map<String, String> = emptyMap()): JsonElement? {
        val u = url(path, q) ?: throw Net.badURL()
        return Net.parse(Net.send(u, headers = headers)).jO("MediaContainer")
    }

    private fun imdb(m: JsonElement): String? =
        m.jList("Guid").mapNotNull { it.jS("id") }.firstOrNull { it.startsWith("imdb://") }?.drop(7)
    private fun image(path: String?): String? = path?.let { url(it) }
    private fun stream(m: JsonElement): String? =
        m.jList("Media").firstOrNull().jList("Part").firstOrNull().jS("key")?.let { url(it) }

    suspend fun library(): Library {
        val movies = ArrayList<Movie>()
        val series = ArrayList<Series>()
        for (dir in get("/library/sections").jList("Directory")) {
            val type = dir.jS("type")
            if (type != "movie" && type != "show") continue
            val key = dir.jS("key") ?: continue
            val items = get("/library/sections/$key/all", mapOf("includeGuids" to "1")).jList("Metadata")
            for (m in items) {
                val rk = m.jS("ratingKey") ?: continue
                val group = m.jList("Genre").firstOrNull().jS("tag") ?: dir.jS("title") ?: "Plex"
                val rating = m.jD("audienceRating") ?: m.jD("rating")
                if (type == "movie") {
                    movies.add(Movie(id = "px$rk", title = m.jS("title") ?: "?", year = m.jI("year"), poster = image(m.jS("thumb")),
                        group = group, streamURL = stream(m), imdbID = imdb(m), rating = rating, plot = m.jS("summary"),
                        addedAt = m.jL("addedAt")?.let { it * 1000 }))
                } else {
                    series.add(Series(id = "pxs$rk", title = m.jS("title") ?: "?", year = m.jI("year"), poster = image(m.jS("thumb")),
                        group = group, imdbID = imdb(m), plot = m.jS("summary"), rating = rating, remoteID = rk))
                }
            }
        }
        movies.sortByDescending { it.addedAt ?: Long.MIN_VALUE }
        return Library(movies = movies, series = series)
    }

    suspend fun episodes(series: Series): List<Episode> {
        val key = series.remoteID ?: return emptyList()
        return get("/library/metadata/$key/allLeaves").jList("Metadata").mapNotNull { e ->
            val rk = e.jS("ratingKey") ?: return@mapNotNull null
            Episode(id = "pxe$rk", seriesID = series.id, season = e.jI("parentIndex") ?: 1, number = e.jI("index") ?: 0,
                title = e.jS("title") ?: "", streamURL = stream(e), still = image(e.jS("thumb")), plot = e.jS("summary"),
                durationSeconds = e.jI("duration")?.let { it / 1000 })
        }
    }
}

/** Plex koppelen via plex.tv/link (voor het toevoeg-scherm). */
object PlexAuth {
    /** Vraagt een nieuwe koppelcode aan; toon [PlexPin.code] en verwijs naar plex.tv/link. */
    suspend fun startPin(): PlexPin = PlexClient.createPin()
    /** Eén keer controleren: het Plex-token zodra de code bevestigd is, anders null. */
    suspend fun poll(pin: PlexPin): String? = PlexClient.checkPin(pin)
    /** Wacht (max ±5 min, elke 2 s) tot de code bevestigd is; gooit bij verlopen. */
    suspend fun waitForToken(pin: PlexPin): String = PlexClient.waitForToken(pin)
}

/** Stremio-login (voor het toevoeg-scherm). */
object StremioAuth {
    /** E-mail + wachtwoord → authKey (bewaren in Store.secret(p.passwordKey)). */
    suspend fun login(email: String, password: String): String = StremioClient.login(email, password)
}

// MARK: - Stremio ----------------------------------------------------------------

/**
 * Stremio-addons: catalogi (films/series met IMDb-ID's) en streams. Alleen directe
 * http(s)-streams worden afgespeeld.
 */
class StremioClient(val addons: List<Addon>) {
    @Serializable
    data class Addon(
        val base: String,          // transportUrl zonder /manifest.json
        val name: String,
        val resources: List<String>,
        val types: List<String>,
        val catalogs: List<Catalog>,
    ) {
        @Serializable
        data class Catalog(val type: String, val id: String, val name: String)
    }

    companion object {
        const val cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

        /** Inloggen bij Stremio → authKey */
        suspend fun login(email: String, password: String): String {
            val body = buildJsonObject {
                put("type", "Login"); put("email", email); put("password", password); put("facebook", false)
            }
            val r = Net.parse(Net.send("https://api.strem.io/api/login", "POST", body = body))
            return r.jO("result").jS("authKey") ?: throw XtreamClient.authError
        }

        suspend fun accountAddons(authKey: String): List<String> {
            val body = buildJsonObject { put("type", "AddonCollectionGet"); put("authKey", authKey); put("update", true) }
            val r = Net.parse(Net.send("https://api.strem.io/api/addonCollectionGet", "POST", body = body))
            return r.jO("result").jList("addons").mapNotNull { it.jS("transportUrl") }
        }

        suspend fun loadAddon(manifestURL: String): Addon? {
            var m = manifestURL.trim()
            if (m.startsWith("stremio://")) m = "https://" + m.drop("stremio://".length)
            val obj = runCatching { Net.json(m).jObj }.getOrNull() ?: return null
            val resources = obj.jList("resources").mapNotNull { r -> r.jFlex ?: r.jS("name") }
            val catalogs = obj.jList("catalogs").mapNotNull { c ->
                val t = c.jS("type") ?: return@mapNotNull null
                val id = c.jS("id") ?: return@mapNotNull null
                if (c.jList("extra").any { it.jB("isRequired") == true }) return@mapNotNull null
                if (c.jList("extraRequired").isNotEmpty()) return@mapNotNull null
                Addon.Catalog(type = t, id = id, name = c.jS("name") ?: id)
            }
            val base = m.replace("/manifest.json", "")
            return Addon(base = base, name = obj.jS("name") ?: "Addon", resources = resources,
                types = obj.jList("types").mapNotNull { it.jFlex }, catalogs = catalogs)
        }
    }

    suspend fun library(): Library = coroutineScope {
        val jobs = addons.filter { "catalog" in it.resources }.flatMap { a ->
            a.catalogs.take(10).filter { it.type == "movie" || it.type == "series" }.map { c ->
                async {
                    val metas = runCatching { Net.json("${a.base}/catalog/${c.type}/${c.id}.json").jList("metas") }
                        .getOrDefault(emptyList())
                    c to metas
                }
            }
        }
        val movies = ArrayList<Movie>()
        val series = ArrayList<Series>()
        val moviesL = L("Movies"); val seriesL = L("Series")
        for ((cat, metas) in jobs.awaitAll()) {
            val groupName = "${cat.name} · ${if (cat.type == "movie") moviesL else seriesL}"
            for (m in metas) {
                val id = m.jS("id") ?: continue
                if (!id.startsWith("tt")) continue
                val year = m.jS("releaseInfo")?.take(4)?.toIntOrNull()
                val rating = m.jS("imdbRating")?.toDoubleOrNull()
                if (cat.type == "movie") {
                    movies.add(Movie(id = "sm$id-${cat.id}", title = m.jS("name") ?: "?", year = year,
                        poster = Net.urlValue(m.jS("poster")), group = groupName, imdbID = id,
                        rating = rating, plot = m.jS("description")))
                } else {
                    series.add(Series(id = "ss$id-${cat.id}", title = m.jS("name") ?: "?", year = year,
                        poster = Net.urlValue(m.jS("poster")), group = groupName, imdbID = id,
                        plot = m.jS("description"), rating = rating, remoteID = id))
                }
            }
        }
        Library(movies = movies, series = series)
    }

    suspend fun episodes(series: Series): List<Episode> {
        val id = series.remoteID ?: return emptyList()
        val metaAddon = addons.firstOrNull { "meta" in it.resources && "series" in it.types }
        val base = metaAddon?.base ?: cinemeta.replace("/manifest.json", "")
        val r = Net.json("$base/meta/series/$id.json")
        return r.jO("meta").jList("videos").filter { (it.jI("season") ?: 0) > 0 }.mapNotNull { v ->
            val vid = v.jS("id") ?: return@mapNotNull null
            Episode(id = "se$vid", seriesID = series.id, season = v.jI("season") ?: 1,
                number = v.jI("episode") ?: v.jI("number") ?: 0,
                title = v.jS("name") ?: v.jS("title") ?: "", streamURL = null,
                still = Net.urlValue(v.jS("thumbnail")), plot = v.jS("overview"))
        }.sortedWith(compareBy<Episode>({ it.season }, { it.number }))
    }

    /** Alle directe streams voor een film (tt…) of aflevering (tt…:s:e). */
    suspend fun streams(type: String, id: String): List<StremioStream> = coroutineScope {
        addons.filter { "stream" in it.resources }.map { a ->
            async {
                val list = runCatching { Net.json("${a.base}/stream/$type/$id.json").jList("streams") }.getOrDefault(emptyList())
                list.mapNotNull { s ->
                    val su = s.jS("url") ?: return@mapNotNull null
                    if (!su.lowercase().startsWith("http")) return@mapNotNull null
                    val t = listOfNotNull(s.jS("name"), s.jS("title") ?: s.jS("description")).joinToString(" · ")
                    StremioStream(title = t.ifEmpty { a.name }, addon = a.name, url = su)
                }
            }
        }.awaitAll().flatten()
    }
}
