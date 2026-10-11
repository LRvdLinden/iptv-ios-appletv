package nl.lrvdlinden.bingr

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.serialization.Serializable

/** Een titel van buiten (TMDB/Trakt) met jaar, om te koppelen aan je afspeellijst. */
@Serializable
data class ExternalTitle(val titles: List<String>, val year: Int? = null)

/**
 * Snelle titel-index van de afspeellijst. Wordt één keer per lijst op de achtergrond gebouwd
 * (het opschonen van tienduizenden IPTV-titels is te zwaar voor de main thread) en gedeeld
 * door Home, Films en Series.
 */
class TitleMatcher(movies: List<Movie>, series: List<Series>) {
    val allMovies: List<Movie> = movies
    val allSeries: List<Series> = series
    private val movieIndex: Map<String, Int> = index(movies.map { it.title to it.year })
    private val seriesIndex: Map<String, Int> = index(series.map { it.title to it.year })

    companion object {
        fun norm(t: String): String = Net.normTitle(t)

        private fun index(titles: List<Pair<String, Int?>>): Map<String, Int> {
            val d = HashMap<String, Int>(titles.size * 3)
            titles.forEachIndexed { i, (raw, year) ->
                val parsed = TitleCleaner.parse(raw)
                for (n in setOf(norm(parsed.title), norm(raw))) {
                    if (n.length <= 1) continue
                    if (n !in d) d[n] = i
                    val y = year ?: parsed.year
                    if (y != null && "$n|$y" !in d) d["$n|$y"] = i
                }
            }
            return d
        }
    }

    fun movies(list: List<ExternalTitle>, limit: Int = 10): List<Movie> = find(list, movieIndex, allMovies, limit)
    fun series(list: List<ExternalTitle>, limit: Int = 10): List<Series> = find(list, seriesIndex, allSeries, limit)

    private fun <T> find(list: List<ExternalTitle>, idx: Map<String, Int>, items: List<T>, limit: Int): List<T> {
        val out = ArrayList<T>()
        val seen = HashSet<Int>()
        for (t in list) {
            for (title in t.titles) {
                val n = norm(title)
                val i = t.year?.let { idx["$n|$it"] } ?: idx[n]
                if (i != null) {
                    if (seen.add(i)) out.add(items[i])
                    break
                }
            }
            if (out.size >= limit) break
        }
        return out
    }
}

/** Bewaart de index per afspeellijst-versie; bouwen gebeurt één keer, op de achtergrond. */
object MatcherCache {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var key = ""
    private var current: TitleMatcher? = null
    private var building: Deferred<TitleMatcher>? = null

    suspend fun matcher(lib: Library, key: String): TitleMatcher {
        val task: Deferred<TitleMatcher> = synchronized(this) {
            if (key == this.key) {
                current?.let { cur -> return cur }
                building?.let { return@synchronized it }
            }
            this.key = key
            current = null
            val movies = lib.movies
            val series = lib.series
            scope.async { TitleMatcher(movies, series) }.also { building = it }
        }
        return awaitAndStore(key, task)
    }

    private suspend fun awaitAndStore(k: String, t: Deferred<TitleMatcher>): TitleMatcher {
        val m = t.await()
        synchronized(this) { if (key == k && building === t) { current = m; building = null } }
        return m
    }
}

/** Trending vandaag (TMDB in de app-taal + Trakt), 6 uur bewaard en gedeeld door alle tabbladen. */
object TrendingStore {
    @Serializable
    private data class Saved(val date: Long, val items: List<ExternalTitle>)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inFlight = HashMap<Boolean, Deferred<List<ExternalTitle>>>()

    private fun key(shows: Boolean) = "trending.${if (shows) "tv" else "movie"}.${Localizer.language}"

    private fun saved(shows: Boolean): Saved? =
        Prefs.string(key(shows))?.let { runCatching { Http.json.decodeFromString(Saved.serializer(), it) }.getOrNull() }

    /** Direct uit de cache (ook als die verlopen is), zonder netwerk. */
    fun cached(shows: Boolean): List<ExternalTitle> = saved(shows)?.items ?: emptyList()

    fun isFresh(shows: Boolean): Boolean {
        val s = saved(shows) ?: return false
        return System.currentTimeMillis() - s.date < 6 * 3_600_000L && s.items.isNotEmpty()
    }

    suspend fun get(shows: Boolean): List<ExternalTitle> {
        if (isFresh(shows)) return cached(shows)
        val t = synchronized(inFlight) {
            inFlight.getOrPut(shows) {
                scope.async { TMDB.trending(shows) + Trakt.trending(shows) }
            }
        }
        val items = try { t.await() } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() } finally {
            synchronized(inFlight) { if (inFlight[shows] === t) inFlight.remove(shows) }
        }
        if (items.isNotEmpty()) {
            Prefs.put(key(shows), Http.json.encodeToString(Saved.serializer(), Saved(System.currentTimeMillis(), items)))
            return items
        }
        return cached(shows)
    }
}
