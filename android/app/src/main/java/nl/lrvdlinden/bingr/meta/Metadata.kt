package nl.lrvdlinden.bingr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * IMDb-gegevens via OMDb (score, poster, plot, cast) + IMDb-ID en trailer via Trakt (= MetadataService).
 * Resultaten worden op schijf gecachet zodat elke titel maar één keer opgezocht wordt.
 */
object Metadata {
    /** Verhoogt bij nieuwe cache-items (Compose-state, zodat schermen opnieuw lezen). */
    var version by mutableStateOf(0); private set

    /** key: "m|title|year" of "s|title|year" */
    private val cache = ConcurrentHashMap<String, TitleMetadata>()
    private val inFlight = ConcurrentHashMap<String, Deferred<TitleMetadata?>>()
    private var saveJob: Job? = null
    private val serializer = MapSerializer(String.serializer(), TitleMetadata.serializer())
    private val cacheFile: File get() = File(AppState.appContext.cacheDir, "imdb-metadata.json")

    init {
        AppScope.launch {
            val loaded = withContext(Dispatchers.IO) {
                runCatching { Http.json.decodeFromString(serializer, cacheFile.readText()) }.getOrNull()
            }
            if (!loaded.isNullOrEmpty()) {
                loaded.forEach { (k, v) -> cache.putIfAbsent(k, v) }
                version++
            }
        }
    }

    /**
     * Cache-sleutel "m|title|year" / "s|title|year". Pure functie: veilig vanaf elke thread
     * (bijv. bij het filteren van de bibliotheek op Dispatchers.Default).
     */
    @JvmStatic
    fun key(title: String, year: Int?, isShow: Boolean): String =
        "${if (isShow) "s" else "m"}|${title.lowercase()}|${year?.toString() ?: ""}"

    /** Thread-safe (ConcurrentHashMap): ook vanaf de achtergrond te gebruiken. */
    fun cached(m: Movie): TitleMetadata? = cache[key(m.title, m.year, false)]
    fun cached(s: Series): TitleMetadata? = cache[key(s.title, s.year, true)]
    fun cached(title: String, year: Int?, isShow: Boolean): TitleMetadata? = cache[key(title, year, isShow)]

    /** Kopie van de cache (voor filteren op de achtergrond). */
    fun snapshot(): Map<String, TitleMetadata> = HashMap(cache)

    suspend fun metadata(m: Movie, knownIMDb: String? = null): TitleMetadata? =
        fetch(m.title, m.year, false, knownIMDb ?: m.imdbID)
    suspend fun metadata(s: Series): TitleMetadata? = fetch(s.title, s.year, true, s.imdbID)

    suspend fun fetch(title: String, year: Int?, isShow: Boolean, imdb: String?): TitleMetadata? {
        val k = key(title, year, isShow)
        cache[k]?.let { return it }
        val fresh = AppScope.async(start = CoroutineStart.LAZY) { resolve(title, year, isShow, imdb) }
        val task = inFlight.putIfAbsent(k, fresh) ?: fresh
        if (task !== fresh) fresh.cancel()
        val r = try { task.await() } catch (e: CancellationException) { throw e } catch (e: Exception) { null } finally {
            if (task === fresh) inFlight.remove(k)
        }
        if (r != null && task === fresh) {
            cache[k] = r
            withContext(Dispatchers.Main) { version++ }
            scheduleSave()
        }
        return r
    }

    private suspend fun resolve(title: String, year: Int?, isShow: Boolean, imdb: String?): TitleMetadata? {
        // 1. IMDb-ID + trailer via Trakt
        var trakt: Trakt.TraktMedia? = null
        if (imdb != null) trakt = Trakt.lookup(imdb)
        if (trakt == null) trakt = Trakt.lookup(title, year, isShow)
        val imdbID = imdb ?: trakt?.ids?.imdb

        // 2. IMDb-details via OMDb
        var meta = OMDb.fetch(imdbID, title, year, isShow)
        if (meta == null && imdbID != null) {
            meta = TitleMetadata(imdbID = imdbID, title = trakt?.title ?: title, year = trakt?.year?.toString())
        }
        return meta?.copy(trailerYouTubeID = trakt?.trailer?.let { youtubeID(it) }, traktSlug = trakt?.ids?.slug)
    }

    fun youtubeID(url: String): String? {
        val u = url.trim().let { if (it.startsWith("http")) it else "https://$it" }.toHttpUrlOrNull() ?: return null
        u.queryParameter("v")?.let { return it }
        if (u.host.contains("youtu.be")) return u.encodedPath.drop(1).takeIf { it.isNotEmpty() }
        return null
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = AppScope.launch(Dispatchers.IO) {
            delay(2_000)
            val snapshot = HashMap(cache)
            runCatching { cacheFile.writeText(Http.json.encodeToString(serializer, snapshot)) }
        }
    }
}

object OMDb {
    suspend fun fetch(imdbID: String?, title: String, year: Int?, isShow: Boolean): TitleMetadata? {
        if (!Secrets.isSet(Secrets.omdbAPIKey)) return null
        val q = mutableListOf("apikey" to Secrets.omdbAPIKey, "plot" to "full")
        if (imdbID != null) q.add("i" to imdbID)
        else {
            q.add("t" to title)
            q.add("type" to if (isShow) "series" else "movie")
            if (year != null) q.add("y" to year.toString())
        }
        val url = Net.url("https://www.omdbapi.com/", q) ?: return null
        val r = runCatching { Net.json(url) }.getOrNull() ?: return null
        if (r.jS("Response") != "True") return null
        val id = r.jS("imdbID") ?: return null
        fun clean(k: String): String? = r.jS(k)?.takeIf { it != "N/A" }
        return TitleMetadata(imdbID = id, title = r.jS("Title") ?: title, year = clean("Year"), rated = clean("Rated"),
            runtime = clean("Runtime"), genre = clean("Genre"), director = clean("Director"),
            actors = clean("Actors"), plot = clean("Plot"), poster = Net.urlValue(clean("Poster")),
            imdbRating = clean("imdbRating"), imdbVotes = clean("imdbVotes"), type = clean("Type"),
            totalSeasons = clean("totalSeasons")?.toIntOrNull())
    }
}
