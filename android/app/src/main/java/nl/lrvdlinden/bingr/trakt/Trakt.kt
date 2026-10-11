package nl.lrvdlinden.bingr

import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.addJsonObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Trakt API v2 (= TraktClient.swift + TraktSync.swift).
 * Inloggen via koppelcode (device flow, ook op TV). Nieuwe Trakt-apps hebben alleen een Client ID:
 * PKCE (code_challenge S256 / code_verifier); client_secret gaat alleen mee als die ingesteld is.
 * Houdt bij wat er bekeken is (2 kanten op): vinkjes, voortgang, watchlist, scrobble.
 */
object Trakt {
    private const val BASE = "https://api.trakt.tv"
    private const val TOKEN_KEY = "trakt.tokens"
    private val oauthHosts = listOf("https://api.trakt.tv", "https://auth.trakt.tv")
    /** Redirect-URI's zoals ze bij de Trakt-app geregistreerd kunnen zijn (nodig bij verversen). */
    val redirectURIs = listOf("https://github.com/LRvdLinden/iptv-ios-appletv", "urn:ietf:wg:oauth:2.0:oob")

    @Serializable
    data class Tokens(val accessToken: String, val refreshToken: String, val expiresAt: Long, val username: String? = null)

    data class DeviceCode(val deviceCode: String, val userCode: String, val verificationUrl: String, val expiresIn: Int, val interval: Int)

    data class TraktIDs(val trakt: Int? = null, val slug: String? = null, val imdb: String? = null, val tmdb: Int? = null, val tvdb: Int? = null)
    data class TraktMedia(val title: String?, val year: Int?, val ids: TraktIDs, val trailer: String?)
    data class PlaybackItem(val id: Long, val progress: Double, val type: String, val imdb: String?, val title: String,
                            val season: Int? = null, val episode: Int? = null)

    enum class Scrobble { START, PAUSE, STOP }

    /** Titel(+jaar) → IMDb-ID, zodat vinkjes direct op IPTV-titels passen zonder per titel op te zoeken. */
    @Serializable
    data class TitleIndex(val movies: Map<String, String> = emptyMap(), val shows: Map<String, String> = emptyMap()) {
        fun imdb(title: String, year: Int?, show: Boolean): String? {
            val n = Net.normTitle(title)
            val d = if (show) shows else movies
            if (year != null) d["$n|$year"]?.let { return it }
            return d[n]
        }
    }
    private class IndexBuilder(from: TitleIndex) {
        val movies = HashMap(from.movies)
        val shows = HashMap(from.shows)
        fun add(title: String?, year: Int?, imdb: String, show: Boolean) {
            if (title == null) return
            val n = Net.normTitle(title)
            val d = if (show) shows else movies
            d[n] = imdb
            if (year != null) d["$n|$year"] = imdb
        }
        fun build() = TitleIndex(movies, shows)
    }

    private class NotLoggedIn : Exception(L("Not signed in to Trakt."))

    // MARK: state

    var isLoggedIn by mutableStateOf(false); private set
    var username by mutableStateOf<String?>(null); private set
    var displayName by mutableStateOf<String?>(null); private set
    var avatar by mutableStateOf<String?>(null); private set
    /** imdb */
    var watchedMovies by mutableStateOf(setOf<String>()); private set
    /** show-imdb → "s-e" */
    var watchedEpisodes by mutableStateOf(mapOf<String, Set<String>>()); private set
    var watchlist by mutableStateOf(setOf<String>()); private set
    var playback by mutableStateOf(listOf<PlaybackItem>()); private set
    var lastRefresh by mutableStateOf<Long?>(null); private set
    var lastError by mutableStateOf<String?>(null)
    var titleIndex by mutableStateOf(TitleIndex()); private set

    private var scrobbleState = mutableStateOf(Prefs.bool("trakt.scrobble", true))
    var scrobbleEnabled: Boolean
        get() = scrobbleState.value
        set(v) { scrobbleState.value = v; Prefs.put("trakt.scrobble", v) }
    private var askRatingState = mutableStateOf(Prefs.bool("trakt.askRating", true))
    var askRating: Boolean
        get() = askRatingState.value
        set(v) { askRatingState.value = v; Prefs.put("trakt.askRating", v) }

    private var lastActivity: String? = null
    private var verifier = ""
    private val tokenLock = Mutex()

    private val tokens: Tokens?
        get() = Store.secret(TOKEN_KEY)?.let { runCatching { Http.json.decodeFromString(Tokens.serializer(), it) }.getOrNull() }
    private fun saveTokens(t: Tokens?) =
        Store.setSecret(TOKEN_KEY, t?.let { Http.json.encodeToString(Tokens.serializer(), it) })

    private var oauthBase: String
        get() = Prefs.string("trakt.oauthHost") ?: "https://api.trakt.tv"
        set(v) = Prefs.put("trakt.oauthHost", v)

    init {
        val t = tokens
        isLoggedIn = t != null
        username = t?.username
        loadCache()
        if (isLoggedIn) AppScope.launch { refresh(); loadProfile() }
    }

    // MARK: inloggen (device flow + PKCE)

    private fun randomVerifier(): String {
        val chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        val rnd = SecureRandom()
        return String(CharArray(64) { chars[rnd.nextInt(chars.length)] })
    }
    private fun challenge(v: String): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(v.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(hash, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private val apiHeaders: Map<String, String>
        get() = mapOf("trakt-api-version" to "2", "trakt-api-key" to Secrets.traktClientID)

    /** Body met client_secret alleen als de app er (nog) een heeft. */
    private fun oauthBody(extra: Map<String, String>): JsonObject = buildJsonObject {
        extra.forEach { (k, v) -> put(k, v) }
        put("client_id", Secrets.traktClientID)
        if (Secrets.isSet(Secrets.traktClientSecret)) put("client_secret", Secrets.traktClientSecret)
    }

    private suspend fun oauthPost(path: String, body: JsonObject, host: String? = null): Http.Response =
        Http.request((host ?: oauthBase) + path, method = "POST", headers = apiHeaders, jsonBody = body.toString())

    suspend fun startLogin(): DeviceCode {
        verifier = randomVerifier()
        val body = buildJsonObject {
            put("client_id", Secrets.traktClientID)
            put("code_challenge", challenge(verifier)); put("code_challenge_method", "S256")
        }
        var lastStatus = 0
        var lastError: Exception? = null
        for (h in oauthHosts) {
            try {
                val r = oauthPost("/oauth/device/code", body, h)
                if (r.ok) {
                    val j = runCatching { Http.json.parseToJsonElement(r.body) }.getOrNull()
                    val dc = j.jS("device_code"); val uc = j.jS("user_code")
                    if (dc != null && uc != null) {
                        oauthBase = h
                        return DeviceCode(dc, uc, j.jS("verification_url") ?: "https://trakt.tv/activate",
                            j.jI("expires_in") ?: 600, j.jI("interval") ?: 5)
                    }
                }
                lastStatus = r.code
            } catch (e: CancellationException) { throw e } catch (e: Exception) { lastError = e }
        }
        if (lastStatus == 0 && lastError != null) throw lastError
        throw Net.statusError(lastStatus, "Trakt")
    }

    /** Pollt tot de gebruiker de code heeft bevestigd op trakt.tv/activate; daarna ingelogd + gesynchroniseerd. */
    suspend fun finishLogin(c: DeviceCode) {
        val deadline = System.currentTimeMillis() + c.expiresIn * 1000L
        var interval = maxOf(c.interval, 5).toLong()
        while (System.currentTimeMillis() < deadline) {
            delay(interval * 1000)
            val r = oauthPost("/oauth/device/token", oauthBody(mapOf("code" to c.deviceCode, "code_verifier" to verifier)))
            when (r.code) {
                200 -> {
                    var tok = parseTokens(r.body) ?: throw Net.decoding("token")
                    tok = tok.copy(username = runCatching { fetchUsername(tok.accessToken) }.getOrNull())
                    saveTokens(tok)
                    isLoggedIn = true; username = tok.username
                    refresh(force = true)
                    loadProfile()
                    return
                }
                400 -> continue                    // nog niet bevestigd
                429 -> interval += 1               // te snel
                404, 409, 410, 418 -> throw ServiceException(L("Trakt refused the connection (%d).", r.code))
                else -> continue
            }
        }
        throw ServiceException(L("The code has expired. Please try again."))
    }

    fun logout() {
        tokens?.let { t ->
            AppScope.launch { runCatching { oauthPost("/oauth/revoke", oauthBody(mapOf("token" to t.accessToken))) } }
        }
        saveTokens(null)
        isLoggedIn = false; username = null; displayName = null; avatar = null
        watchedMovies = emptySet(); watchedEpisodes = emptyMap(); watchlist = emptySet(); playback = emptyList()
        titleIndex = TitleIndex()
        lastActivity = null
        saveCache()
    }

    private fun parseTokens(body: String): Tokens? {
        val j = runCatching { Http.json.parseToJsonElement(body) }.getOrNull() ?: return null
        val at = j.jS("access_token") ?: return null
        val rt = j.jS("refresh_token") ?: return null
        val created = j.jL("created_at") ?: (System.currentTimeMillis() / 1000)
        val expires = j.jL("expires_in") ?: 0
        return Tokens(at, rt, (created + expires) * 1000)
    }

    private suspend fun fetchUsername(token: String): String? {
        val r = Http.request("$BASE/users/settings", headers = headers(token))
        return runCatching { Http.json.parseToJsonElement(r.body).jO("user").jS("username") }.getOrNull()
    }

    /**
     * Geldig access-token; ververst als het binnen 24 uur verloopt. Refresh-tokens zijn eenmalig:
     * het nieuwe paar wordt direct bewaard (en een Mutex voorkomt dubbel verversen).
     */
    private suspend fun validToken(): String = tokenLock.withLock {
        var t = tokens ?: throw NotLoggedIn()
        if (t.expiresAt - System.currentTimeMillis() < 24 * 3_600_000L) {
            var refreshed = false
            var unauthorized = 0
            for (redirect in redirectURIs) {
                val r = oauthPost("/oauth/token", oauthBody(mapOf(
                    "refresh_token" to t.refreshToken, "redirect_uri" to redirect, "grant_type" to "refresh_token")))
                val n = if (r.code == 200) parseTokens(r.body) else null
                if (n != null) {
                    t = n.copy(username = t.username)
                    saveTokens(t)
                    refreshed = true
                    break
                }
                if (r.code == 401 || r.code == 400) unauthorized++
            }
            if (!refreshed && unauthorized == redirectURIs.size && t.expiresAt < System.currentTimeMillis()) {
                saveTokens(null)
                withContext(Dispatchers.Main) { isLoggedIn = false }
                throw NotLoggedIn()
            }
        }
        t.accessToken
    }

    // MARK: requests

    private fun headers(token: String?): Map<String, String> {
        val h = HashMap(apiHeaders)
        h["Content-Type"] = "application/json"
        if (token != null) h["Authorization"] = "Bearer $token"
        return h
    }

    /** GET op api.trakt.tv → JSON (gooit bij een foutstatus). */
    suspend fun get(path: String, query: List<Pair<String, String>> = emptyList(), auth: Boolean = true): JsonElement {
        val u = Net.url(BASE + path, query) ?: throw Net.badURL()
        val token = if (auth) validToken() else null
        val r = Http.request(u, headers = headers(token))
        if (!r.ok) throw Net.statusError(r.code, r.body)
        return Net.parse(r.body)
    }

    /** POST (409 = al gedaan, telt als gelukt). */
    suspend fun post(path: String, body: JsonElement, auth: Boolean = true): String {
        val token = if (auth) validToken() else null
        val r = Http.request(BASE + path, method = "POST", headers = headers(token), jsonBody = body.toString())
        if (!r.ok && r.code != 409) throw Net.statusError(r.code, r.body)
        return r.body
    }

    suspend fun delete(path: String) {
        val token = validToken()
        Http.request(BASE + path, method = "DELETE", headers = headers(token))
    }

    // MARK: ophalen

    private fun ids(e: JsonElement?): TraktIDs {
        val i = e.jO("ids")
        return TraktIDs(trakt = i.jI("trakt"), slug = i.jS("slug"), imdb = i.jS("imdb"), tmdb = i.jI("tmdb"), tvdb = i.jI("tvdb"))
    }
    private fun media(e: JsonElement?): TraktMedia? {
        if (e == null || e !is JsonObject) return null
        return TraktMedia(title = e.jS("title"), year = e.jI("year"), ids = ids(e), trailer = e.jS("trailer"))
    }

    suspend fun refresh(force: Boolean = false) {
        if (!isLoggedIn) return
        try {
            val act = get("/sync/last_activities").jS("all")
            if (!force && act != null && act == lastActivity && (watchedMovies.isNotEmpty() || watchedEpisodes.isNotEmpty())) {
                lastRefresh = System.currentTimeMillis(); return
            }
            coroutineScope {
                val m = async { get("/sync/watched/movies") }
                val s = async { get("/sync/watched/shows") }
                val p = async { get("/sync/playback") }
                val w = async { get("/sync/watchlist") }

                val idx = IndexBuilder(titleIndex)
                val movies = m.await().jItems
                val wm = HashSet<String>()
                for (x in movies) {
                    val mv = x.jO("movie")
                    val i = ids(mv).imdb ?: continue
                    wm.add(i); idx.add(mv.jS("title"), mv.jI("year"), i, false)
                }
                val eps = HashMap<String, Set<String>>()
                for (show in s.await().jItems) {
                    val sh = show.jO("show")
                    val imdb = ids(sh).imdb ?: continue
                    idx.add(sh.jS("title"), sh.jI("year"), imdb, true)
                    val set = HashSet<String>()
                    for (season in show.jList("seasons")) {
                        val sn = season.jI("number") ?: continue
                        for (e in season.jList("episodes")) e.jI("number")?.let { set.add("$sn-$it") }
                    }
                    eps[imdb] = set
                }
                val pb = p.await().jItems.mapNotNull { x ->
                    val id = x.jL("id") ?: return@mapNotNull null
                    val progress = x.jD("progress") ?: 0.0
                    val type = x.jS("type") ?: "movie"
                    if (type == "episode") {
                        val ep = x.jO("episode")
                        PlaybackItem(id, progress, type, ids(x.jO("show")).imdb, x.jO("show").jS("title") ?: "",
                            ep.jI("season"), ep.jI("number"))
                    } else PlaybackItem(id, progress, type, ids(x.jO("movie")).imdb, x.jO("movie").jS("title") ?: "")
                }
                val wl = w.await().jItems
                val wset = HashSet<String>()
                for (x in wl) {
                    val mm = x.jO("movie"); val ss = x.jO("show")
                    (ids(mm).imdb ?: ids(ss).imdb)?.let { wset.add(it) }
                    if (mm != null) ids(mm).imdb?.let { idx.add(mm.jS("title"), mm.jI("year"), it, false) }
                    if (ss != null) ids(ss).imdb?.let { idx.add(ss.jS("title"), ss.jI("year"), it, true) }
                }
                withContext(Dispatchers.Main) {
                    watchedMovies = wm; watchedEpisodes = eps; playback = pb; watchlist = wset
                    titleIndex = idx.build()
                    lastActivity = act
                    lastRefresh = System.currentTimeMillis()
                    lastError = null
                }
            }
            saveCache()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            lastError = Net.message(e)
            if (e is NotLoggedIn) isLoggedIn = false
        }
    }

    // MARK: status in de UI

    /** IMDb-ID van een IPTV-titel: eerst uit de Trakt-index, dan uit de metadata-cache. */
    fun imdb(m: Movie): String? = m.imdbID ?: titleIndex.imdb(m.title, m.year, false) ?: Metadata.cached(m)?.imdbID
    fun imdb(s: Series): String? = s.imdbID ?: titleIndex.imdb(s.title, s.year, true) ?: Metadata.cached(s)?.imdbID

    fun isWatched(movieImdb: String?): Boolean = movieImdb != null && movieImdb in watchedMovies
    fun isWatched(showImdb: String?, season: Int, episode: Int): Boolean =
        showImdb != null && watchedEpisodes[showImdb]?.contains("$season-$episode") == true
    fun watchedCount(showImdb: String?): Int = showImdb?.let { watchedEpisodes[it]?.size } ?: 0

    fun playbackProgress(movieImdb: String?): Double? {
        if (movieImdb == null) return null
        return playback.firstOrNull { it.type == "movie" && it.imdb == movieImdb }?.let { it.progress / 100 }
    }

    // MARK: schrijven

    suspend fun setWatched(item: PlayableItem, watched: Boolean) {
        val imdb = item.imdbID
        if (!isLoggedIn || imdb == null) return
        val s = item.season; val e = item.episode
        val body: JsonObject
        if (item.type == MediaType.EPISODE && s != null && e != null) {
            body = buildJsonObject {
                putJsonArray("shows") { addJsonObject {
                    putJsonObject("ids") { put("imdb", imdb) }
                    putJsonArray("seasons") { addJsonObject {
                        put("number", s)
                        putJsonArray("episodes") { addJsonObject { put("number", e) } }
                    } }
                } }
            }
            val set = watchedEpisodes[imdb] ?: emptySet()
            watchedEpisodes = watchedEpisodes + (imdb to if (watched) set + "$s-$e" else set - "$s-$e")
        } else {
            body = buildJsonObject { putJsonArray("movies") { addJsonObject { putJsonObject("ids") { put("imdb", imdb) } } } }
            watchedMovies = if (watched) watchedMovies + imdb else watchedMovies - imdb
        }
        saveCache()
        try { post(if (watched) "/sync/history" else "/sync/history/remove", body) }
        catch (ex: CancellationException) { throw ex } catch (ex: Exception) { lastError = Net.message(ex) }
    }

    /** Hele seizoen of serie in één keer afvinken. */
    suspend fun setWatched(showImdb: String, episodes: List<Episode>, watched: Boolean) {
        if (!isLoggedIn) return
        val bySeason = episodes.groupBy { it.season }
        var set = watchedEpisodes[showImdb] ?: emptySet()
        for (e in episodes) set = if (watched) set + "${e.season}-${e.number}" else set - "${e.season}-${e.number}"
        watchedEpisodes = watchedEpisodes + (showImdb to set)
        saveCache()
        val body = buildJsonObject {
            putJsonArray("shows") { addJsonObject {
                putJsonObject("ids") { put("imdb", showImdb) }
                putJsonArray("seasons") {
                    bySeason.forEach { (s, eps) ->
                        addJsonObject {
                            put("number", s)
                            putJsonArray("episodes") { eps.forEach { ep -> addJsonObject { put("number", ep.number) } } }
                        }
                    }
                }
            } }
        }
        try { post(if (watched) "/sync/history" else "/sync/history/remove", body) }
        catch (ex: CancellationException) { throw ex } catch (ex: Exception) { lastError = Net.message(ex) }
    }

    suspend fun toggleWatchlist(imdb: String, isShow: Boolean) {
        if (!isLoggedIn) return
        val add = imdb !in watchlist
        watchlist = if (add) watchlist + imdb else watchlist - imdb
        val body = buildJsonObject {
            putJsonArray(if (isShow) "shows" else "movies") { addJsonObject { putJsonObject("ids") { put("imdb", imdb) } } }
        }
        try { post(if (add) "/sync/watchlist" else "/sync/watchlist/remove", body) }
        catch (ex: CancellationException) { throw ex } catch (ex: Exception) { lastError = Net.message(ex) }
    }

    /** Scrobble: Trakt markeert automatisch als bekeken bij stop ≥ 80%. [progress] 0…1 */
    suspend fun scrobble(a: Scrobble, item: PlayableItem, progress: Double) {
        val imdb = item.imdbID
        if (!isLoggedIn || !scrobbleEnabled || imdb == null || item.type == MediaType.LIVE) return
        val s = item.season; val e = item.episode
        val isEpisode = item.type == MediaType.EPISODE && s != null && e != null
        val body = buildJsonObject {
            put("progress", (progress * 100).coerceIn(0.0, 100.0))
            put("app_version", "1.0.0")
            if (isEpisode) {
                putJsonObject("show") { putJsonObject("ids") { put("imdb", imdb) } }
                putJsonObject("episode") { put("season", s); put("number", e) }
            } else {
                putJsonObject("movie") { putJsonObject("ids") { put("imdb", imdb) } }
            }
        }
        runCatching { post("/scrobble/${a.name.lowercase()}", body) }
        if (a == Scrobble.STOP && progress >= 0.8) {
            if (isEpisode) watchedEpisodes = watchedEpisodes + (imdb to ((watchedEpisodes[imdb] ?: emptySet()) + "$s-$e"))
            else watchedMovies = watchedMovies + imdb
            saveCache()
        }
    }

    /** Waardering 1–10 naar Trakt sturen. */
    suspend fun rate(item: PlayableItem, rating: Int) {
        val imdb = item.imdbID
        if (!isLoggedIn || imdb == null) return
        val s = item.season; val e = item.episode
        val body = if (item.type == MediaType.EPISODE && s != null && e != null) buildJsonObject {
            putJsonArray("shows") { addJsonObject {
                putJsonObject("ids") { put("imdb", imdb) }
                putJsonArray("seasons") { addJsonObject {
                    put("number", s)
                    putJsonArray("episodes") { addJsonObject { put("number", e); put("rating", rating) } }
                } }
            } }
        } else buildJsonObject {
            putJsonArray("movies") { addJsonObject { putJsonObject("ids") { put("imdb", imdb) }; put("rating", rating) } }
        }
        runCatching { post("/sync/ratings", body) }
    }

    /** Verwijder een half-gekeken item uit Trakt's "verder kijken". */
    suspend fun removePlayback(id: Long) {
        playback = playback.filterNot { it.id == id }
        runCatching { delete("/sync/playback/$id") }
    }

    // MARK: metadata via Trakt (IMDb-id en trailer)

    suspend fun lookup(title: String, year: Int?, isShow: Boolean): TraktMedia? {
        if (!Secrets.isSet(Secrets.traktClientID)) return null
        val q = mutableListOf("query" to title, "extended" to "full", "limit" to "5")
        if (year != null) q.add("years" to year.toString())
        val hits = runCatching { get("/search/${if (isShow) "show" else "movie"}", q, auth = false) }.getOrNull()
        hits.jItems.firstOrNull()?.let { h -> return media(h.jO("movie") ?: h.jO("show")) }
        if (year != null) return lookup(title, null, isShow)
        return null
    }

    suspend fun lookup(imdb: String): TraktMedia? {
        if (!Secrets.isSet(Secrets.traktClientID)) return null
        val hits = runCatching { get("/search/imdb/$imdb", listOf("extended" to "full"), auth = false) }.getOrNull()
        return hits.jItems.firstOrNull()?.let { media(it.jO("movie") ?: it.jO("show")) }
    }

    /** YouTube-id van de trailer (via Trakt). */
    suspend fun trailer(imdb: String, isShow: Boolean): String? {
        val m = lookup(imdb) ?: return null
        return m.trailer?.let { Metadata.youtubeID(it) }
    }

    /** Profiel (naam + avatar) voor het Trakt-scherm. */
    suspend fun loadProfile() {
        if (!isLoggedIn) return
        val s = runCatching { get("/users/settings", listOf("extended" to "full")) }.getOrNull() ?: return
        val u = s.jO("user")
        displayName = u.jS("name")?.takeIf { it.isNotEmpty() } ?: u.jS("username")
        username = u.jS("username") ?: username
        avatar = Net.urlValue(u.jO("images").jO("avatar").jS("full"))
    }

    private fun titles(list: List<TraktMedia>): List<ExternalTitle> =
        list.mapNotNull { m -> m.title?.let { ExternalTitle(listOf(it), m.year) } }

    /** Titels die lijken op een film/serie (werkt ook zonder inloggen). */
    suspend fun relatedMedia(imdb: String, shows: Boolean): List<TraktMedia> {
        if (!Secrets.isSet(Secrets.traktClientID)) return emptyList()
        val r = runCatching { get("/${if (shows) "shows" else "movies"}/$imdb/related", listOf("limit" to "20"), auth = false) }.getOrNull()
        return r.jItems.mapNotNull { media(it) }
    }
    suspend fun related(imdb: String, shows: Boolean): List<ExternalTitle> = titles(relatedMedia(imdb, shows))

    /** Persoonlijke aanbevelingen van Trakt (alleen ingelogd). */
    suspend fun recommendationsMedia(shows: Boolean): List<TraktMedia> {
        if (!isLoggedIn) return emptyList()
        val r = runCatching {
            get(if (shows) "/recommendations/shows" else "/recommendations/movies", listOf("limit" to "50", "ignore_collected" to "false"))
        }.getOrNull()
        return r.jItems.mapNotNull { media(it) }
    }
    suspend fun recommendations(shows: Boolean): List<ExternalTitle> = titles(recommendationsMedia(shows))

    suspend fun trendingMedia(shows: Boolean): List<TraktMedia> {
        if (!Secrets.isSet(Secrets.traktClientID)) return emptyList()
        val r = runCatching {
            get(if (shows) "/shows/trending" else "/movies/trending", listOf("limit" to "100"), auth = false)
        }.getOrNull()
        return r.jItems.mapNotNull { media(it.jO("movie") ?: it.jO("show")) }
    }
    suspend fun trending(shows: Boolean): List<ExternalTitle> = titles(trendingMedia(shows))

    // MARK: cache (zodat vinkjes direct zichtbaar zijn bij opstarten)

    @Serializable
    private data class Cache(val m: Set<String>, val e: Map<String, Set<String>>, val w: Set<String>, val a: String? = null,
                             val t: TitleIndex? = null)

    private val cacheFile: File get() = File(AppState.appContext.cacheDir, "trakt-cache.json")

    private fun saveCache() {
        val c = Cache(watchedMovies, watchedEpisodes, watchlist, lastActivity, titleIndex)
        AppScope.launch(Dispatchers.IO) {
            runCatching { cacheFile.writeText(Http.json.encodeToString(Cache.serializer(), c)) }
        }
    }

    private fun loadCache() {
        if (!isLoggedIn) return
        val c = runCatching { Http.json.decodeFromString(Cache.serializer(), cacheFile.readText()) }.getOrNull() ?: return
        watchedMovies = c.m; watchedEpisodes = c.e; watchlist = c.w; lastActivity = c.a; titleIndex = c.t ?: TitleIndex()
    }
}
