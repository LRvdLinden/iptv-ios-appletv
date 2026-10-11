package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.roundToInt

enum class Filter { ALL, MOVIES, SERIES }

// MARK: vooraf berekende rijen (= HomeIndex in HomeView.swift)

/** Vooraf berekende rijen voor Home/Films/Series: één keer per lijst, op de achtergrond (Dispatchers.Default). */
class HomeIndex(
    val movieGroups: List<Pair<String, List<Movie>>> = emptyList(),
    val seriesGroups: List<Pair<String, List<Series>>> = emptyList(),
    val recent: List<Movie> = emptyList(),
    val movieByID: Map<String, Movie> = emptyMap(),
    val seriesByID: Map<String, Series> = emptyMap(),
    val channelByID: Map<String, Channel> = emptyMap(),
    val movieByIMDb: Map<String, Movie> = emptyMap(),
    val seriesByTitle: Map<String, Series> = emptyMap(),
) {
    val seriesTitles: Set<String> get() = seriesByTitle.keys

    private fun itemID(key: String, playlist: String): String? =
        if (key.length > playlist.length + 1 && key.startsWith("$playlist|")) key.substring(playlist.length + 1) else null

    fun movie(forKey: String, playlist: String): Movie? = itemID(forKey, playlist)?.let { movieByID[it] }
    fun series(forKey: String, playlist: String): Series? = itemID(forKey, playlist)?.let { seriesByID[it] }
    fun channel(forKey: String, playlist: String): Channel? = itemID(forKey, playlist)?.let { channelByID[it] }

    /** Staat deze titel (nog) in de gefilterde lijst? */
    fun contains(t: DetailTarget): Boolean = if (t.isSeries) t.id in seriesByID else t.id in movieByID

    companion object {
        fun build(lib: Library): HomeIndex {
            val mGroups = LinkedHashMap<String, MutableList<Movie>>()
            val movieByID = HashMap<String, Movie>(lib.movies.size * 2)
            val movieByIMDb = HashMap<String, Movie>()
            for (m in lib.movies) {
                mGroups.getOrPut(m.group) { ArrayList() }.add(m)
                movieByID.putIfAbsent(m.id, m)
                val i = m.imdbID
                if (!i.isNullOrEmpty()) movieByIMDb.putIfAbsent(i, m)
            }
            val sGroups = LinkedHashMap<String, MutableList<Series>>()
            val seriesByID = HashMap<String, Series>(lib.series.size * 2)
            val seriesByTitle = HashMap<String, Series>()
            for (s in lib.series) {
                sGroups.getOrPut(s.group) { ArrayList() }.add(s)
                seriesByID.putIfAbsent(s.id, s)
                seriesByTitle.putIfAbsent(s.title, s)
            }
            val channelByID = HashMap<String, Channel>(lib.channels.size * 2)
            for (c in lib.channels) channelByID.putIfAbsent(c.id, c)
            val recent = lib.movies.filter { it.addedAt != null }.sortedByDescending { it.addedAt ?: 0L }
            return HomeIndex(
                movieGroups = mGroups.map { e -> Pair<String, List<Movie>>(e.key, e.value) },
                seriesGroups = sGroups.map { e -> Pair<String, List<Series>>(e.key, e.value) },
                recent = recent, movieByID = movieByID, seriesByID = seriesByID, channelByID = channelByID,
                movieByIMDb = movieByIMDb, seriesByTitle = seriesByTitle,
            )
        }
    }
}

/** Eén [HomeIndex] per geladen lijst, gedeeld door Home/Films/Series en Mijn Bingr (niet opnieuw bij wisselen van tab). */
object HomeIndexCache {
    private var lib: Library? = null
    private var index: HomeIndex? = null

    /** Al klaar voor deze lijst? (alleen op de main thread) */
    fun peek(l: Library): HomeIndex? = if (lib === l) index else null

    /** Bouwt (op Dispatchers.Default) of geeft de bestaande index voor deze lijst. Aanroepen vanaf de main thread. */
    suspend fun get(l: Library): HomeIndex {
        peek(l)?.let { return it }
        val built = withContext(Dispatchers.Default) { HomeIndex.build(l) }
        lib = l; index = built
        return built
    }
}

/** De index van de huidige lijst als Compose-state: eerst wat er al is, dan na het (achtergrond)bouwen. */
@Composable
fun rememberHomeIndex(lib: Library): HomeIndex {
    val libKey = System.identityHashCode(lib)
    var index by remember(libKey) { mutableStateOf(HomeIndexCache.peek(lib) ?: HomeIndex()) }
    LaunchedEffect(libKey) { index = HomeIndexCache.get(lib) }
    return index
}

// MARK: Billboard, Top 10, Voor jou

/** Gegevens van één Home-tab (billboard, Top 10, Voor jou) — eerst uit de cache, daarna het netwerk. */
private class HomeModel(val filter: Filter) {
    var hero by mutableStateOf<DetailTarget?>(null)
    var trendingMovies by mutableStateOf(emptyList<Movie>())
    var trendingSeries by mutableStateOf(emptyList<Series>())
    var forYou by mutableStateOf(emptyList<DetailTarget>())

    /** Wat niet (meer) in de gefilterde lijst staat weghalen (ander profiel, leeftijdsgrens, verborgen groep). */
    fun prune(lib: Library) {
        val movieIDs = lib.movies.mapTo(HashSet()) { it.id }
        val seriesIDs = lib.series.mapTo(HashSet()) { it.id }
        fun ok(t: DetailTarget) = if (t.isSeries) t.id in seriesIDs else t.id in movieIDs
        hero?.let { if (!ok(it)) hero = null }
        if (trendingMovies.any { it.id !in movieIDs }) trendingMovies = trendingMovies.filter { it.id in movieIDs }
        if (trendingSeries.any { it.id !in seriesIDs }) trendingSeries = trendingSeries.filter { it.id in seriesIDs }
        if (forYou.any { !ok(it) }) forYou = forYou.filter { ok(it) }
    }

    suspend fun prepare(key: String) {
        val lib = Playlists.library
        if (lib.movies.isEmpty() && lib.series.isEmpty()) {
            hero = null; trendingMovies = emptyList(); trendingSeries = emptyList(); forYou = emptyList()
            return
        }
        // 0. wat niet (meer) in de gefilterde lijst staat weghalen
        prune(lib)
        // 1. meteen iets laten zien: billboard en Top 10 uit de cache van vandaag (of je eigen lijst)
        if (hero == null) hero = quickHero(lib)
        val matcher = screensSafe { MatcherCache.matcher(lib, key) }
        applyTrending(lib, matcher, TrendingStore.cached(false, kidsProfile()), TrendingStore.cached(true, kidsProfile()))
        if (forYou.isEmpty()) forYou = buildForYou(lib, false, matcher)
        if (hero == null) hero = quickHero(lib)

        // 2. daarna pas het netwerk (gedeeld door alle tabbladen)
        val (m, s) = coroutineScope {
            val a = async { screensSafe { TrendingStore.get(false, kidsProfile()) } ?: emptyList() }
            val b = async { screensSafe { TrendingStore.get(true, kidsProfile()) } ?: emptyList() }
            a.await() to b.await()
        }
        applyTrending(lib, matcher, m, s)
        forYou = buildForYou(lib, true, matcher)
        prune(Playlists.library)
    }

    /** Billboard zonder te wachten: iets uit de Top 10, anders willekeurig met poster. */
    private fun quickHero(lib: Library): DetailTarget? = when (filter) {
        Filter.SERIES -> (trendingSeries.firstOrNull() ?: lib.series.filter { it.poster != null }.randomOrNull())
            ?.let { DetailTarget.SeriesT(it) }
        Filter.MOVIES -> (trendingMovies.firstOrNull() ?: lib.movies.filter { it.poster != null }.randomOrNull())
            ?.let { DetailTarget.MovieT(it) }
        Filter.ALL -> {
            val m = trendingMovies.randomOrNull() ?: lib.movies.filter { it.poster != null }.randomOrNull()
            if (m != null) DetailTarget.MovieT(m) else lib.series.randomOrNull()?.let { DetailTarget.SeriesT(it) }
        }
    }

    /** Top 10: trending gekoppeld aan je lijst; te weinig treffers → aanvullen met je best beoordeelde/nieuwste titels. */
    private suspend fun applyTrending(lib: Library, matcher: TitleMatcher?, movies: List<ExternalTitle>, series: List<ExternalTitle>) {
        if (filter != Filter.SERIES) {
            val found = withContext(Dispatchers.Default) { if (matcher == null || movies.isEmpty()) emptyList() else matcher.movies(movies) }
            if (found.size >= 5 || trendingMovies.isEmpty()) {
                trendingMovies = if (found.size >= 5) found
                else found + withContext(Dispatchers.Default) { localTopMovies(lib.movies) }.filter { m -> found.none { it.id == m.id } }
            }
        }
        if (filter != Filter.MOVIES) {
            val found = withContext(Dispatchers.Default) { if (matcher == null || series.isEmpty()) emptyList() else matcher.series(series) }
            if (found.size >= 5 || trendingSeries.isEmpty()) {
                trendingSeries = if (found.size >= 5) found
                else found + withContext(Dispatchers.Default) { localTopSeries(lib.series) }.filter { s -> found.none { it.id == s.id } }
            }
        }
    }

    private fun localTopMovies(items: List<Movie>): List<Movie> {
        val withPoster = items.filter { it.poster != null }
        val pool = withPoster.ifEmpty { items }
        val rated = pool.filter { (it.rating ?: 0.0) > 0 }
        if (rated.size >= 10) return rated.sortedByDescending { it.rating ?: 0.0 }.take(10)
        val recent = pool.filter { it.addedAt != null }.sortedByDescending { it.addedAt ?: 0L }
        if (recent.size >= 10) return recent.take(10)
        return pool.take(10)
    }

    private fun localTopSeries(items: List<Series>): List<Series> {
        val withPoster = items.filter { it.poster != null }
        val pool = withPoster.ifEmpty { items }
        val rated = pool.filter { (it.rating ?: 0.0) > 0 }
        if (rated.size >= 10) return rated.sortedByDescending { it.rating ?: 0.0 }.take(10)
        return pool.take(10)
    }

    private data class Seed(val imdb: String, val show: Boolean)

    /**
     * "Voor jou": vergelijkbaar met wat je keek, Trakt-aanbevelingen die in je lijst staan,
     * onbekeken titels uit de groepen waar je het meest kijkt, en trending.
     */
    private suspend fun buildForYou(lib: Library, useNetwork: Boolean, matcher: TitleMatcher?): List<DetailTarget> {
        // Compose-state op de main thread lezen, daarna op de achtergrond rekenen
        val progress = Store.progress
        val localWatched = Store.localWatched
        val myList = Store.myList
        val pid = Playlists.source?.id
        val tm = trendingMovies
        val ts = trendingSeries
        return withContext(Dispatchers.Default) {
            val out = ArrayList<DetailTarget>()
            val seen = HashSet<String>()
            fun add(t: DetailTarget) {
                if (t.id in seen || progress[t.id] != null) return
                if (filter == Filter.MOVIES && t.isSeries) return
                if (filter == Filter.SERIES && !t.isSeries) return
                when (t) {
                    is DetailTarget.MovieT -> if (Trakt.isWatched(Trakt.imdb(t.movie)) || t.movie.id in localWatched) return
                    is DetailTarget.SeriesT -> if (Trakt.watchedCount(Trakt.imdb(t.series)) > 0) return
                }
                seen.add(t.id); out.add(t)
            }
            val movieByID = HashMap<String, Movie>(lib.movies.size * 2).apply { lib.movies.forEach { putIfAbsent(it.id, it) } }
            val seriesByTitle = HashMap<String, Series>().apply { lib.series.forEach { putIfAbsent(it.title, it) } }

            // 1. vergelijkbaar met wat je (half) gekeken hebt
            if (matcher != null) {
                val seeds = ArrayList<Seed>()
                for (k in progress.entries.sortedByDescending { it.value.updated }.map { it.key }) {
                    val m = movieByID[k]
                    if (m != null) {
                        Trakt.imdb(m)?.let { seeds.add(Seed(it, false)) }
                    } else {
                        progress[k]?.title?.let { seriesByTitle[it] }?.let { Trakt.imdb(it) }?.let { seeds.add(Seed(it, true)) }
                    }
                    if (seeds.size >= 4) break
                }
                Trakt.watchedEpisodes.keys.shuffled().take(2).forEach { seeds.add(Seed(it, true)) }
                Trakt.watchedMovies.shuffled().take(2).forEach { seeds.add(Seed(it, false)) }
                if (filter == Filter.MOVIES) seeds.removeAll { it.show }
                if (filter == Filter.SERIES) seeds.removeAll { !it.show }
                if (useNetwork) {
                    for (seed in seeds.distinctBy { it.imdb }) {
                        val rel = screensSafe { Trakt.related(seed.imdb, seed.show) } ?: emptyList()
                        if (rel.isEmpty()) continue
                        if (seed.show) matcher.series(rel, 6).forEach { add(DetailTarget.SeriesT(it)) }
                        else matcher.movies(rel, 6).forEach { add(DetailTarget.MovieT(it)) }
                    }
                }

                // 2. persoonlijke Trakt-aanbevelingen
                if (useNetwork && Trakt.isLoggedIn) {
                    val rm = screensSafe { Trakt.recommendations(false) } ?: emptyList()
                    val rs = screensSafe { Trakt.recommendations(true) } ?: emptyList()
                    val recMovies = if (rm.isEmpty()) emptyList() else matcher.movies(rm, 40)
                    val recSeries = if (rs.isEmpty()) emptyList() else matcher.series(rs, 40)
                    recMovies.take(15).zip(recSeries.take(15)).forEach { (a, b) -> add(DetailTarget.MovieT(a)); add(DetailTarget.SeriesT(b)) }
                    recMovies.drop(15).take(5).forEach { add(DetailTarget.MovieT(it)) }
                    recSeries.drop(15).take(5).forEach { add(DetailTarget.SeriesT(it)) }
                }
            }

            // 3. groepen waar je in kijkt (voortgang, Mijn lijst, bekeken) — via sleutels, niet de hele lijst
            val groupScore = HashMap<String, Int>()
            for (k in progress.keys + localWatched) {
                movieByID[k]?.let { groupScore[it.group] = (groupScore[it.group] ?: 0) + 1 }
            }
            if (pid != null) {
                val seriesByID = HashMap<String, Series>().apply { lib.series.forEach { putIfAbsent(it.id, it) } }
                val prefix = "$pid|"
                for (k in myList) {
                    if (!k.startsWith(prefix)) continue
                    val id = k.substring(prefix.length)
                    movieByID[id]?.let { groupScore[it.group] = (groupScore[it.group] ?: 0) + 1 }
                    seriesByID[id]?.let { groupScore[it.group] = (groupScore[it.group] ?: 0) + 2 }
                }
            }
            val topGroups = groupScore.entries.sortedByDescending { it.value }.take(4).map { it.key }.toSet()
            if (topGroups.isNotEmpty()) {
                val gm = lib.movies.filter { it.group in topGroups }.groupBy { it.group }
                val gs = lib.series.filter { it.group in topGroups }.groupBy { it.group }
                for (g in topGroups) {
                    gm[g].orEmpty().shuffled().take(5).forEach { add(DetailTarget.MovieT(it)) }
                    gs[g].orEmpty().shuffled().take(5).forEach { add(DetailTarget.SeriesT(it)) }
                }
            }
            // 4. aanvullen met trending
            tm.take(8).zip(ts.take(8)).forEach { (a, b) -> add(DetailTarget.MovieT(a)); add(DetailTarget.SeriesT(b)) }
            if (filter == Filter.MOVIES) tm.take(8).forEach { add(DetailTarget.MovieT(it)) }
            if (filter == Filter.SERIES) ts.take(8).forEach { add(DetailTarget.SeriesT(it)) }
            if (out.size < 8) {
                lib.movies.filter { it.poster != null }.shuffled().take(6).forEach { add(DetailTarget.MovieT(it)) }
                lib.series.filter { it.poster != null }.shuffled().take(6).forEach { add(DetailTarget.SeriesT(it)) }
            }
            out.take(30)
        }
    }
}

// MARK: Verder kijken (= ContinueWatching.swift)

class ContinueItem(
    val id: String, val title: String, val subtitle: String, val artwork: String?,
    val fraction: Double, val updated: Long, val isMovie: Boolean,
    val position: Double? = null, val traktPlaybackID: Long? = null,
)

/**
 * Verder kijken van het actieve profiel op deze server (nieuwste eerst). Afleveringen alleen als de serie (nog)
 * zichtbaar is voor dit profiel. [trakt] = films die je in een andere app (via Trakt) half keek.
 */
fun continueItems(filter: Filter, index: HomeIndex, pid: String?, progress: Map<String, ProgressEntry>,
                  trakt: List<ContinueItem> = emptyList()): List<ContinueItem> {
    val out = ArrayList<ContinueItem>()
    for ((key, e) in progress) {
        if (!Store.belongsToActive(e.profileID)) continue                    // alleen van dit profiel
        if (e.playlistID != null && e.playlistID != pid) continue           // alleen van deze server
        val isMovie = key in index.movieByID
        if (!isMovie && e.title !in index.seriesTitles) continue
        if (filter == Filter.MOVIES && !isMovie) continue
        if (filter == Filter.SERIES && isMovie) continue
        val left = max(0.0, e.position / max(e.fraction, 0.01) - e.position)
        val art = e.artwork ?: if (isMovie) index.movieByID[key]?.poster else index.seriesByTitle[e.title]?.poster
        out.add(ContinueItem(key, e.title, L("%d min left", (left / 60).toInt()), art, e.fraction, e.updated, isMovie,
            position = if (e.position > 0) e.position else null))
    }
    if (filter != Filter.SERIES && trakt.isNotEmpty()) {
        val known = out.mapTo(HashSet()) { it.id }
        out.addAll(trakt.filter { it.id !in known })
    }
    return out.sortedByDescending { it.updated }.take(20)
}

/** Films die je in een andere app (via Trakt) half keek, gekoppeld aan je lijst (op de achtergrond). */
@Composable
fun rememberTraktContinue(index: HomeIndex): List<ContinueItem> {
    val playback = Trakt.playback
    var list by remember { mutableStateOf(emptyList<ContinueItem>()) }
    LaunchedEffect(index, playback) {
        if (playback.isEmpty()) { list = emptyList(); return@LaunchedEffect }
        val movies = index.movieByID.values
        list = withContext(Dispatchers.Default) {
            playback.filter { it.type == "movie" }.mapNotNull { p ->
                val imdb = p.imdb ?: return@mapNotNull null
                val m = index.movieByIMDb[imdb] ?: movies.firstOrNull { Trakt.imdb(it) == imdb } ?: return@mapNotNull null
                ContinueItem(m.id, m.title, "Trakt · ${p.progress.toInt()}%", m.poster, p.progress / 100.0, 0L, true,
                    traktPlaybackID = p.id)
            }
        }
    }
    return list
}

fun ContinueItem.choice(index: HomeIndex): ResumeChoice {
    val d: DetailTarget? = if (isMovie) index.movieByID[id]?.let { DetailTarget.MovieT(it) }
    else index.seriesByTitle[title]?.let { DetailTarget.SeriesT(it) }
    return ResumeChoice(id, title, fraction, position, d)
}

fun removeFromContinue(c: ContinueItem) {
    Store.clearProgress(c.id)
    c.traktPlaybackID?.let { id -> AppScope.launch { screensSafe { Trakt.removePlayback(id) } } }
}

/** Kaart voor "Verder kijken": poster met afspeelicoon, daaronder een duidelijke voortgangsbalk en de resterende tijd. */
@Composable
fun ContinueCard(title: String, poster: String?, fraction: Double, caption: String?, modifier: Modifier = Modifier) {
    Column(modifier.width(Theme.posterWidth), verticalArrangement = Arrangement.spacedBy(tvs(5))) {
        Box(contentAlignment = Alignment.Center) {
            PosterCard(title, poster)
            Box(
                Modifier.size(tvs(38)).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f))
                    .border(1.5.dp, Color.White.copy(alpha = 0.9f), CircleShape),
                contentAlignment = Alignment.Center
            ) { Icon(Icons.Default.PlayArrow, null, tint = Color.White, modifier = Modifier.size(tvs(20))) }
        }
        ProgressBar(max(fraction, 0.03), Modifier.width(Theme.posterWidth).height(tvs(4)).clip(RoundedCornerShape(50)))
        if (caption != null) {
            Text(caption, color = Theme.secondary, fontSize = tsp(10), maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(Theme.posterWidth))
        }
    }
}

/** "Hervatten vanaf … / Vanaf het begin kijken / Meer info" voor een titel uit Verder kijken. */
@Composable
fun ResumeDialog(choice: ResumeChoice, onDismiss: () -> Unit) {
    val pct = (choice.fraction * 100).roundToInt()
    val actions = buildList {
        add(S2Action(choice.position?.let { L("Resume from %@", Playables.formatPosition(it)) } ?: L("Resume"), Icons.Default.PlayArrow) {
            AppScope.launch { ResumePlayer.play(choice.id, choice.title, restart = false)?.let { ScreensNav.detail(it) } }
        })
        add(S2Action(L("Watch from the beginning"), Icons.Default.Replay) {
            AppScope.launch { ResumePlayer.play(choice.id, choice.title, restart = true)?.let { ScreensNav.detail(it) } }
        })
        choice.detail?.let { d -> add(S2Action(L("More info"), Icons.Outlined.Info) { ScreensNav.detail(d) }) }
    }
    S2ActionDialog("${choice.title} · ${L("%d%% watched", pct)}", actions, onDismiss = onDismiss)
}

/** Rij "Verder kijken": tik = kiezen (hervatten/opnieuw/meer info), lang indrukken = verwijderen. */
@Composable
fun ContinueRow(items: List<ContinueItem>, index: HomeIndex) {
    if (items.isEmpty()) return
    var choice by remember { mutableStateOf<ResumeChoice?>(null) }
    var removing by remember { mutableStateOf<ContinueItem?>(null) }
    MediaRow(L("Continue watching")) {
        items(items) { c ->
            ContinueCard(
                c.title, c.artwork, c.fraction, c.subtitle,
                Modifier.focusLift(onLongClick = { removing = c }) { choice = c.choice(index) }
            )
        }
    }
    choice?.let { ResumeDialog(it) { choice = null } }
    removing?.let { c ->
        S2ActionDialog(c.title, listOf(
            S2Action(L("Remove from Continue watching"), Icons.Default.Close, destructive = true) { removeFromContinue(c) }
        ), onDismiss = { removing = null })
    }
}

private fun openDetail(t: DetailTarget) = ScreensNav.detail(t)
private fun openCategory(title: String, items: List<DetailTarget>) = ScreensNav.category(CategoryTarget(title, items))

/** Profielen met een leeftijdsgrens gaan via de detailpagina (die controleert de classificatie). */
private fun homePlay(t: DetailTarget) {
    val ageLimited = Store.activeProfile?.effectiveAgeLimit != null
    when {
        t is DetailTarget.MovieT && !ageLimited -> AppState.play(Playables.movie(t.movie, Trakt.imdb(t.movie)))
        else -> openDetail(t)
    }
}

/** Home / Films / Series in Netflix-stijl (= HomeView.swift). */
@Composable
fun HomeScreen(filter: Filter) {
    val tv = AppState.isTV
    val lib = Playlists.library
    val pid = Playlists.source?.id
    val model = remember(filter) { HomeModel(filter) }
    val listState = rememberLazyListState()
    val index = rememberHomeIndex(lib)
    val prepKey = "${Store.activeProfileID ?: ""}-${pid ?: ""}-${lib.movies.size}-${lib.series.size}"
    LaunchedEffect(prepKey) { model.prepare("${pid ?: ""}-${lib.movies.size}-${lib.series.size}") }

    val kids = Store.activeProfile?.kids ?: false
    val groupLimit = if (filter == Filter.ALL) 8 else 40

    // Verder kijken, Mijn lijst en favorieten via sleutels (snel), niet door de hele bibliotheek te lopen
    val progress = Store.progress
    val traktContinue = rememberTraktContinue(index)
    val continueList = remember(progress, index, pid, filter, traktContinue, Store.activeProfileID) {
        continueItems(filter, index, pid, progress, traktContinue)
    }
    val myList = Store.myList
    val myMovies = remember(myList, index, pid) {
        if (pid == null) emptyList<Movie>() else myList.mapNotNull { index.movie(it, pid) }.sortedBy { it.title }
    }
    val mySeries = remember(myList, index, pid) {
        if (pid == null) emptyList<Series>() else myList.mapNotNull { index.series(it, pid) }.sortedBy { it.title }
    }
    val favorites = Store.favorites
    val favChannels = remember(favorites, index, pid) {
        if (pid == null) emptyList<Channel>() else favorites.mapNotNull { index.channel(it, pid) }
    }

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(tvs(26)),
            modifier = Modifier.fillMaxSize()
        ) {
            item(key = "hero") {
                val h = model.hero
                if (h != null) {
                    HeroBanner(target = h, onPlay = { homePlay(h) }, onInfo = { openDetail(h) })
                } else {
                    Spacer(Modifier.then(if (tv) Modifier else Modifier.statusBarsPadding()).height(tvs(90)))
                }
            }

            // Verder kijken
            item(key = "continue") { ContinueRow(continueList, index) }

            // Mijn lijst
            item(key = "mylist") {
                when (filter) {
                    Filter.ALL -> {
                        val mine = remember(myMovies, mySeries) {
                            val a: List<DetailTarget> = myMovies.map { DetailTarget.MovieT(it) }
                            val b: List<DetailTarget> = mySeries.map { DetailTarget.SeriesT(it) }
                            a + b
                        }
                        if (mine.isNotEmpty()) TargetRow(L("My List"), mine, pid)
                    }
                    Filter.MOVIES -> if (myMovies.isNotEmpty()) MovieRow(L("My List"), myMovies, myMovies, pid)
                    Filter.SERIES -> if (mySeries.isNotEmpty()) SeriesRow(L("My List"), mySeries, mySeries)
                }
            }
            // Onlangs toegevoegd
            if (filter != Filter.SERIES) item(key = "recent") {
                val all = index.recent
                if (all.isNotEmpty()) MovieRow(L("Recently added"), all.take(30), all, pid)
            }
            // Voor jou
            item(key = "foryou") { ForYouRow(filter, model.forYou) }
            // Top 10 (Home: eerst series, dan films)
            if (filter != Filter.MOVIES) item(key = "top10s") {
                val list = model.trendingSeries
                if (list.isNotEmpty()) Top10SeriesRow(if (kids) L("Top 10 kids series") else L("Top 10 series today"), list)
            }
            if (filter != Filter.SERIES) item(key = "top10m") {
                val list = model.trendingMovies
                if (list.isNotEmpty()) Top10MoviesRow(if (kids) L("Top 10 kids movies") else L("Top 10 movies today"), list)
            }

            // favoriete zenders
            if (filter == Filter.ALL && favChannels.isNotEmpty()) item(key = "favs") {
                MediaRow(L("Favorite channels")) {
                    items(favChannels) { c ->
                        val now = lib.nowPlaying(c)
                        ChannelCard(
                            c, now, favorite = true,
                            modifier = Modifier.focusLift { AppState.play(Playables.channel(c, now), favChannels) }
                        )
                    }
                }
            }

            // categorieën
            if (filter != Filter.SERIES) items(index.movieGroups.take(groupLimit), key = { "m|" + it.first }) { (g, all) ->
                if (all.isNotEmpty()) MovieRow(g, all.take(40), all, pid)
            }
            if (filter != Filter.MOVIES) items(index.seriesGroups.take(groupLimit), key = { "s|" + it.first }) { (g, all) ->
                if (all.isNotEmpty()) SeriesRow(g, all.take(40), all)
            }

            if (lib.movies.isEmpty() && lib.series.isEmpty() && !Playlists.isLoading && !Playlists.isFiltering) item(key = "empty") {
                Column(
                    Modifier.fillMaxWidth().padding(top = 60.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(Icons.Default.Movie, null, tint = Theme.secondary, modifier = Modifier.size(tvs(40)))
                    Spacer(Modifier.height(10.dp))
                    Text(
                        if (filter == Filter.ALL) L("This playlist only contains live TV.") else L("No titles found in this playlist."),
                        color = Theme.secondary, fontSize = tsp(14), textAlign = TextAlign.Center
                    )
                }
            }
        }

        // telefoon: bovenbalk die donker wordt bij scrollen (op TV zit Zoeken in de tabbalk)
        if (!tv) {
            val solid by remember { derivedStateOf { listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 300 } }
            Row(
                Modifier.fillMaxWidth()
                    .background(
                        Brush.verticalGradient(
                            listOf(Color.Black.copy(alpha = if (solid) 0.95f else 0.55f), Color.Black.copy(alpha = if (solid) 0.9f else 0f))
                        )
                    )
                    .statusBarsPadding()
                    .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                BingrLogo(26.sp)
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(34.dp).focusLift { ScreensNav.search() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Search, L("Search"), tint = Color.White, modifier = Modifier.size(25.dp))
                }
                Box(Modifier.focusLift { AppState.switchPlaylist() }) { ProfileAvatar(size = 30.dp) }
            }
        }
    }
}

// MARK: rijen

@Composable
private fun MovieRow(title: String, items: List<Movie>, all: List<Movie>?, pid: String?) {
    MediaRow(title, onSeeAll = all?.let { list -> { openCategory(title, list.map { DetailTarget.MovieT(it) }) } }) {
        items(items) { m -> MoviePoster(m, pid) }
    }
}

/** Aantal bekeken afleveringen van een serie: Trakt, of lokaal (per profiel). */
private fun watchedEpisodeCount(s: Series): Int {
    val lw = Store.localWatched
    return maxOf(Trakt.watchedCount(Trakt.imdb(s)), Store.localWatchedCount(s.id), s.episodes.count { it.id in lw })
}

@Composable
private fun SeriesRow(title: String, items: List<Series>, all: List<Series>?) {
    MediaRow(title, onSeeAll = all?.let { list -> { openCategory(title, list.map { DetailTarget.SeriesT(it) }) } }) {
        items(items) { s -> SeriesPoster(s) }
    }
}

@Composable
private fun SeriesPoster(s: Series) {
    val count = watchedEpisodeCount(s)
    PosterCard(
        s.title, s.poster,
        modifier = Modifier.focusLift { openDetail(DetailTarget.SeriesT(s)) },
        badge = if (count > 0) L("%d WATCHED", count) else null
    )
}

/** Films én series in één rij (Mijn lijst op Home). */
@Composable
private fun TargetRow(title: String, items: List<DetailTarget>, pid: String?) {
    MediaRow(title, onSeeAll = { openCategory(title, items) }) {
        items(items) { t ->
            when (t) {
                is DetailTarget.MovieT -> MoviePoster(t.movie, pid)
                is DetailTarget.SeriesT -> SeriesPoster(t.series)
            }
        }
    }
}

/** Poster met lang-indrukken-menu (afspelen, bekeken, Mijn lijst). */
@Composable
private fun MoviePoster(m: Movie, pid: String?) {
    var menu by remember { mutableStateOf(false) }
    val imdb = Trakt.imdb(m)
    val watched = Playables.isWatched(m, imdb)
    PosterCard(
        m.title, m.poster,
        modifier = Modifier.focusLift(onLongClick = { menu = true }) { openDetail(DetailTarget.MovieT(m)) },
        watched = watched,
        progress = Store.progress[m.id]?.fraction
    )
    if (menu) {
        val actions = buildList {
            add(S2Action(L("Play"), Icons.Default.PlayArrow) { homePlay(DetailTarget.MovieT(m)) })
            add(S2Action(if (watched) L("Mark as unwatched") else L("Mark as watched"),
                if (watched) Icons.Default.VisibilityOff else Icons.Default.CheckCircle) {
                Store.setLocalWatched(m.id, !watched)
                AppScope.launch { screensSafe { Trakt.setWatched(Playables.movie(m, imdb), !watched) } }
            })
            if (pid != null) {
                val inList = Store.inMyList(pid, m.id)
                add(S2Action(if (inList) L("Remove from My List") else L("Add to My List"),
                    if (inList) Icons.Default.Close else Icons.Default.Add) { Store.setMyList(pid, m.id, !inList) })
            }
        }
        S2ActionDialog(m.title, actions, onDismiss = { menu = false })
    }
}

@Composable
private fun ForYouRow(filter: Filter, all: List<DetailTarget>) {
    val items = all.filter { t ->
        when (filter) {
            Filter.MOVIES -> !t.isSeries
            Filter.SERIES -> t.isSeries
            Filter.ALL -> true
        }
    }
    if (items.isEmpty()) return
    MediaRow(L("For you"), onSeeAll = { openCategory(L("For you"), items) }) {
        items(items) { t ->
            PosterCard(
                t.title, t.poster,
                modifier = Modifier.focusLift { openDetail(t) },
                badge = if (t.isSeries) L("SERIES") else L("MOVIE")
            )
        }
    }
}

@Composable
private fun Top10MoviesRow(title: String, all: List<Movie>) {
    val recentSince = System.currentTimeMillis() - 14L * 86_400_000L
    MediaRow(title, onSeeAll = { openCategory(title, all.map { DetailTarget.MovieT(it) }) }) {
        itemsIndexed(all.take(10)) { i, m ->
            Box(Modifier.focusLift { openDetail(DetailTarget.MovieT(m)) }) {
                Top10Card(
                    i + 1, m.title, m.poster,
                    watched = Playables.isWatched(m, Trakt.imdb(m)),
                    badge = if ((m.addedAt ?: 0L) > recentSince) L("Recently added") else null
                )
            }
        }
    }
}

@Composable
private fun Top10SeriesRow(title: String, all: List<Series>) {
    MediaRow(title, onSeeAll = { openCategory(title, all.map { DetailTarget.SeriesT(it) }) }) {
        itemsIndexed(all.take(10)) { i, s ->
            Box(Modifier.focusLift { openDetail(DetailTarget.SeriesT(s)) }) {
                Top10Card(i + 1, s.title, s.poster)
            }
        }
    }
}

// MARK: billboard (= HeroBanner.swift)

/** Grote uitgelichte titel bovenaan Home (Netflix "billboard"). */
@Composable
fun HeroBanner(target: DetailTarget, onPlay: () -> Unit, onInfo: () -> Unit, playFocus: FocusRequester? = null) {
    var info by remember(target.id) { mutableStateOf<TitleMetadata?>(null) }
    LaunchedEffect(target.id) {
        info = screensSafe {
            when (target) {
                is DetailTarget.MovieT -> Metadata.metadata(target.movie)
                is DetailTarget.SeriesT -> Metadata.metadata(target.series)
            }
        }
    }
    val poster = info?.poster ?: target.poster
    val tags = listOfNotNull(
        info?.year,
        info?.genre?.split(",")?.take(2)?.joinToString(" • ") { it.trim() },
        info?.runtime
    ).filter { it.isNotBlank() }.joinToString("  •  ").ifEmpty { if (target.isSeries) L("Series") else L("Movie") }

    if (AppState.isTV) {
        Box(Modifier.fillMaxWidth().height(400.dp)) {
            RemoteImage(poster, Modifier.matchParentSize().blur(30.dp).graphicsLayer { alpha = 0.7f })
            RemoteImage(
                poster,
                Modifier.align(Alignment.CenterEnd).padding(end = 80.dp).fillMaxHeight().aspectRatio(2f / 3f)
            )
            Box(
                Modifier.matchParentSize().background(
                    Brush.horizontalGradient(0f to Color.Black.copy(alpha = 0.95f), 0.55f to Color.Black.copy(alpha = 0.4f), 1f to Color.Transparent)
                )
            )
            Box(Modifier.matchParentSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black)))
            Column(
                Modifier.align(Alignment.BottomStart).padding(start = Theme.edge, bottom = 28.dp).widthIn(max = 540.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(target.title, color = Color.White, fontSize = 38.sp, fontWeight = FontWeight.Black, maxLines = 2,
                    overflow = TextOverflow.Ellipsis, lineHeight = 42.sp)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    info?.imdbRating?.takeIf { it != "N/A" }?.let { ImdbBadge(it) }
                    Text(tags, color = Theme.secondary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                }
                info?.plot?.takeIf { it.isNotBlank() && it != "N/A" }?.let {
                    Text(it, color = Color.White.copy(alpha = 0.9f), fontSize = 14.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    NetflixButton(
                        title = L("Play"), icon = Icons.Default.PlayArrow, kind = NetflixKind.PRIMARY,
                        modifier = if (playFocus != null) Modifier.focusRequester(playFocus) else Modifier, onClick = onPlay
                    )
                    NetflixButton(title = L("More info"), icon = Icons.Outlined.Info, kind = NetflixKind.SECONDARY, onClick = onInfo)
                }
            }
        }
    } else {
        Box(Modifier.fillMaxWidth()) {
            RemoteImage(poster, Modifier.matchParentSize().blur(50.dp).graphicsLayer { alpha = 0.65f })
            Box(Modifier.matchParentSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color.Black)))
            val shape = RoundedCornerShape(12.dp)
            Box(
                Modifier.align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 80.dp, bottom = 24.dp)
                    .fillMaxWidth(0.86f).widthIn(max = 330.dp).aspectRatio(330f / 470f)
                    .shadow(20.dp, shape)
                    .clip(shape)
                    .border(1.dp, Color.White.copy(alpha = 0.12f), shape)
            ) {
                RemoteImage(poster, Modifier.matchParentSize(), placeholder = target.title)
                Box(Modifier.matchParentSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
                Column(
                    Modifier.align(Alignment.BottomCenter).padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        target.title.uppercase(), color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Black,
                        letterSpacing = 1.sp, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 31.sp
                    )
                    Text(tags, color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        NetflixButton(title = L("Play"), icon = Icons.Default.PlayArrow, kind = NetflixKind.PRIMARY,
                            modifier = Modifier.weight(1f), onClick = onPlay)
                        NetflixButton(title = L("Info"), icon = Icons.Outlined.Info, kind = NetflixKind.SECONDARY,
                            modifier = Modifier.weight(1f), onClick = onInfo)
                    }
                }
            }
        }
    }
}

@Composable
fun ImdbBadge(rating: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "IMDb", color = Color.Black, fontSize = tsp(10), fontWeight = FontWeight.Black,
            modifier = Modifier.clip(RoundedCornerShape(3.dp)).background(Theme.imdb).padding(horizontal = 4.dp, vertical = 1.dp)
        )
        Text(rating, color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.Bold)
    }
}


/** Kinderprofiel: eigen Top 10 met kids-titels. */
private fun kidsProfile(): Boolean = Store.activeProfile?.kids == true
