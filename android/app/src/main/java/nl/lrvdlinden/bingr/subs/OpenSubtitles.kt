package nl.lrvdlinden.bingr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/** OpenSubtitles.com REST API: inloggen met je eigen account, zoeken op IMDb-ID (of titel), .srt downloaden. */
object OpenSubtitles {
    private const val DEFAULT_HOST = "api.opensubtitles.com"
    private const val SESSION_KEY = "opensubtitles.session"

    @Serializable
    private data class Session(val token: String, val baseURL: String, val username: String)

    data class Subtitle(val id: Int, val language: String, val release: String, val downloads: Int,
                        val hearingImpaired: Boolean, val fromTrusted: Boolean)

    var username by mutableStateOf<String?>(null); private set
    var remainingDownloads by mutableStateOf<Int?>(null); private set

    private var sessionState = mutableStateOf<Session?>(null)
    private var session: Session?
        get() = sessionState.value
        set(v) {
            sessionState.value = v
            Store.setSecret(SESSION_KEY, v?.let { Http.json.encodeToString(Session.serializer(), it) })
            username = v?.username
        }
    val isLoggedIn: Boolean get() = sessionState.value != null

    private val languagesState = mutableStateOf(
        Prefs.string("os.languages")?.let {
            runCatching { Http.json.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull()
        } ?: listOf("nl", "en")
    )
    /** Voorkeurstalen (volgorde = sortering van zoekresultaten). Prefs "os.languages" */
    var preferredLanguages: List<String>
        get() = languagesState.value
        set(v) {
            languagesState.value = v
            Prefs.put("os.languages", Http.json.encodeToString(ListSerializer(String.serializer()), v))
        }

    private val defaultLanguageState = mutableStateOf(initialDefaultLanguage())
    /** Standaardtaal (ISO 639-1, bijv. "nl"); "" = alle talen. Prefs "os.language" */
    var defaultLanguage: String
        get() = defaultLanguageState.value
        set(v) { defaultLanguageState.value = v; Prefs.put("os.language", v) }

    private fun initialDefaultLanguage(): String {
        Prefs.string("os.language")?.let { return it }
        val track = runCatching { TrackPreferences.subtitle }.getOrDefault("")
        val first = preferredLanguages.firstOrNull()?.take(2)?.lowercase()
        return if (track.length == 2) track else (first ?: Localizer.language.take(2))
    }

    init {
        val s = Store.secret(SESSION_KEY)?.let { runCatching { Http.json.decodeFromString(Session.serializer(), it) }.getOrNull() }
        sessionState.value = s
        username = s?.username
    }

    private val notLoggedIn: ServiceException get() = ServiceException(L("Sign in to OpenSubtitles first (My Bingr)."))

    private suspend fun request(
        path: String, method: String = "GET", query: Map<String, String> = emptyMap(), body: JsonObject? = null,
        base: String? = null,
    ): String {
        val host = base ?: session?.baseURL ?: DEFAULT_HOST
        val u = Net.url("https://$host/api/v1$path", query.entries.sortedBy { it.key }.map { it.key to it.value })
            ?: throw Net.badURL()
        val headers = HashMap<String, String>()
        headers["Api-Key"] = Secrets.openSubtitlesAPIKey
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        session?.token?.let { headers["Authorization"] = "Bearer $it" }
        val r = Http.request(u, method = method, headers = headers, jsonBody = body?.toString())
        if (r.code == 401 && session != null && path != "/login") session = null
        if (!r.ok) {
            val msg = runCatching { Http.json.parseToJsonElement(r.body).jS("message") }.getOrNull() ?: r.body
            throw Net.statusError(r.code, msg)
        }
        return r.body
    }

    // MARK: account

    suspend fun login(user: String, pass: String) {
        val body = buildJsonObject { put("username", user); put("password", pass) }
        val r = Net.parse(request("/login", "POST", body = body, base = DEFAULT_HOST))
        val token = r.jS("token") ?: throw Net.decoding("token")
        session = Session(token, r.jS("base_url") ?: DEFAULT_HOST, user)
        val u = r.jO("user")
        remainingDownloads = u.jI("remaining_downloads") ?: u.jI("allowed_downloads")
    }

    suspend fun logout() {
        runCatching { request("/logout", "DELETE") }
        session = null
        remainingDownloads = null
    }

    /** Account-info (resterende downloads vandaag) verversen. */
    suspend fun refreshUser() {
        if (!isLoggedIn) return
        val d = runCatching { Net.parse(request("/infos/user")).jO("data") }.getOrNull() ?: return
        remainingDownloads = d.jI("remaining_downloads") ?: d.jI("allowed_downloads")
    }

    // MARK: zoeken

    /** Taalcode(s) zoals OpenSubtitles ze gebruikt. */
    fun apiCodes(code: String): List<String> = when (code) {
        "pt" -> listOf("pt-br", "pt-pt")
        "zh" -> listOf("zh-cn", "zh-tw")
        "" -> emptyList()
        else -> listOf(code.lowercase())
    }
    /** Terug naar ISO 639-1 ("pt-PT" → "pt"). */
    fun baseCode(c: String): String = c.lowercase().take(2)

    /** Zoeken op IMDb-ID, of (als die er niet is) op titel. [languages] leeg = alle talen. */
    suspend fun search(
        imdbID: String?, title: String? = null, year: Int? = null, season: Int? = null, episode: Int? = null,
        languages: List<String>,
    ): List<Subtitle> {
        val q = HashMap<String, String>()
        val langs = languages.flatMap { apiCodes(it) }.toSet().sorted()
        if (langs.isNotEmpty()) q["languages"] = langs.joinToString(",")
        val numeric = (imdbID ?: "").replace("tt", "").toIntOrNull()
        if (numeric != null && numeric > 0) {
            if (season != null && episode != null) {
                q["parent_imdb_id"] = numeric.toString()
                q["season_number"] = season.toString(); q["episode_number"] = episode.toString()
            } else {
                q["imdb_id"] = numeric.toString()
            }
        } else if (!title.isNullOrEmpty()) {
            val parsed = TitleCleaner.parse(title)
            q["query"] = parsed.title.lowercase()
            if (season != null && episode != null) {
                q["type"] = "episode"; q["season_number"] = season.toString(); q["episode_number"] = episode.toString()
            } else {
                q["type"] = "movie"
                (year ?: parsed.year)?.let { q["year"] = it.toString() }
            }
        } else {
            return emptyList()
        }
        val r = Net.parse(request("/subtitles", query = q))
        val subs = r.jList("data").mapNotNull { i ->
            val a = i.jO("attributes")
            val f = a.jList("files").firstOrNull() ?: return@mapNotNull null
            val fileID = f.jI("file_id") ?: return@mapNotNull null
            Subtitle(id = fileID, language = a.jS("language") ?: "?",
                release = a.jS("release") ?: f.jS("file_name") ?: "Subtitle",
                downloads = a.jI("download_count") ?: 0,
                hearingImpaired = a.jB("hearing_impaired") ?: false,
                fromTrusted = a.jB("from_trusted") ?: false)
        }
        // eerst gevraagde taal, dan betrouwbaar, dan populariteit
        val order = languages.map { it.lowercase() }
        fun rank(s: Subtitle) = order.indexOf(baseCode(s.language)).let { if (it < 0) 99 else it }
        return subs.sortedWith(compareBy<Subtitle>({ rank(it) }, { if (it.fromTrusted) 0 else 1 }, { -it.downloads }))
    }

    /** Zoeken in de standaardtaal. */
    suspend fun search(imdbID: String, season: Int? = null, episode: Int? = null, title: String? = null): List<Subtitle> =
        search(imdbID = imdbID, title = title, season = season, episode = episode,
            languages = if (defaultLanguage.isEmpty()) emptyList() else listOf(defaultLanguage))

    /** Download → lokaal .srt-bestand (cacheDir) dat de speler kan inladen. */
    suspend fun download(s: Subtitle): File {
        if (!isLoggedIn) throw notLoggedIn
        val body = buildJsonObject { put("file_id", s.id); put("sub_format", "srt") }
        val r = Net.parse(request("/download", "POST", body = body))
        remainingDownloads = r.jI("remaining")
        val link = r.jS("link") ?: throw Net.badURL()
        val data = Http.bytes(link)
        // tekenset herkennen (UTF-8/UTF-16/Windows-1252) en als UTF-8 opslaan, zodat ExoPlayer, VLC en de eigen overlay het goed lezen
        return withContext(Dispatchers.IO) {
            val dir = File(AppState.appContext.cacheDir, "subtitles").apply { mkdirs() }
            val file = File(dir, "sub-${s.id}.srt")
            file.writeText(SRT.decode(data), Charsets.UTF_8)
            file
        }
    }

    /** Talen voor de keuzelijst. */
    val languages: List<Pair<String, String>> = listOf(
        "nl" to "Nederlands", "en" to "English", "de" to "Deutsch", "fr" to "Français", "es" to "Español",
        "it" to "Italiano", "pt-PT" to "Português", "tr" to "Türkçe", "ar" to "العربية", "pl" to "Polski", "zh-CN" to "简体中文",
    )
}
