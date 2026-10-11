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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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

enum class Filter { ALL, MOVIES, SERIES }

/** Gegevens van één Home-tab (billboard, Top 10, Voor jou) — eerst uit de cache, daarna het netwerk. */
private class HomeModel(val filter: Filter) {
    var hero by mutableStateOf<DetailTarget?>(null)
    var trendingMovies by mutableStateOf(emptyList<Movie>())
    var trendingSeries by mutableStateOf(emptyList<Series>())
    var forYou by mutableStateOf(emptyList<DetailTarget>())

    suspend fun prepare(key: String) {
        val lib = Playlists.library
        if (lib.movies.isEmpty() && lib.series.isEmpty()) { hero = null; return }
        // 1. meteen iets laten zien: billboard en Top 10 uit de cache van vandaag (of je eigen lijst)
        if (hero == null) hero = quickHero(lib)
        val matcher = screensSafe { MatcherCache.matcher(lib, key) }
        applyTrending(lib, matcher, TrendingStore.cached(false), TrendingStore.cached(true))
        if (forYou.isEmpty()) forYou = buildForYou(lib, false, matcher)
        if (hero == null) hero = quickHero(lib)

        // 2. daarna pas het netwerk (gedeeld door alle tabbladen)
        val (m, s) = coroutineScope {
            val a = async { screensSafe { TrendingStore.get(false) } ?: emptyList() }
            val b = async { screensSafe { TrendingStore.get(true) } ?: emptyList() }
            a.await() to b.await()
        }
        applyTrending(lib, matcher, m, s)
        forYou = buildForYou(lib, true, matcher)
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
    private suspend fun buildForYou(lib: Library, useNetwork: Boolean, matcher: TitleMatcher?): List<DetailTarget> =
        withContext(Dispatchers.Default) {
            val out = ArrayList<DetailTarget>()
            val seen = HashSet<String>()
            val progress = Store.progress
            fun add(t: DetailTarget) {
                if (t.id in seen || progress[t.id] != null) return
                if (filter == Filter.MOVIES && t.isSeries) return
                if (filter == Filter.SERIES && !t.isSeries) return
                when (t) {
                    is DetailTarget.MovieT -> if (Playables.isWatched(t.movie, Trakt.imdb(t.movie))) return
                    is DetailTarget.SeriesT -> if (Trakt.watchedCount(Trakt.imdb(t.series)) > 0) return
                }
                seen.add(t.id); out.add(t)
            }
            val movieByID = lib.movies.associateBy { it.id }

            // 1. vergelijkbaar met wat je (half) gekeken hebt
            if (matcher != null) {
                val seeds = ArrayList<Seed>()
                for (k in progress.entries.sortedByDescending { it.value.updated }.map { it.key }) {
                    val m = movieByID[k]
                    if (m != null) {
                        Trakt.imdb(m)?.let { seeds.add(Seed(it, false)) }
                    } else {
                        val title = progress[k]?.title
                        lib.series.firstOrNull { it.title == title }?.let { Trakt.imdb(it) }?.let { seeds.add(Seed(it, true)) }
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

            // 3. groepen waar je in kijkt (voortgang, Mijn lijst, bekeken)
            val groupScore = HashMap<String, Int>()
            for (k in progress.keys + Store.localWatched) {
                movieByID[k]?.let { groupScore[it.group] = (groupScore[it.group] ?: 0) + 1 }
            }
            val pid = Playlists.source?.id
            if (pid != null) {
                for (m in lib.movies) if (Store.inMyList(pid, m.id)) groupScore[m.group] = (groupScore[m.group] ?: 0) + 1
                for (s in lib.series) if (Store.inMyList(pid, s.id)) groupScore[s.group] = (groupScore[s.group] ?: 0) + 2
            }
            val topGroups = groupScore.entries.sortedByDescending { it.value }.take(4).map { it.key }
            for (g in topGroups) {
                lib.movies.filter { it.group == g }.shuffled().take(5).forEach { add(DetailTarget.MovieT(it)) }
                lib.series.filter { it.group == g }.shuffled().take(5).forEach { add(DetailTarget.SeriesT(it)) }
            }
            // 4. aanvullen met trending
            trendingMovies.take(8).zip(trendingSeries.take(8)).forEach { (a, b) -> add(DetailTarget.MovieT(a)); add(DetailTarget.SeriesT(b)) }
            if (filter == Filter.MOVIES) trendingMovies.take(8).forEach { add(DetailTarget.MovieT(it)) }
            if (filter == Filter.SERIES) trendingSeries.take(8).forEach { add(DetailTarget.SeriesT(it)) }
            if (out.size < 8) {
                lib.movies.filter { it.poster != null }.shuffled().take(6).forEach { add(DetailTarget.MovieT(it)) }
                lib.series.filter { it.poster != null }.shuffled().take(6).forEach { add(DetailTarget.SeriesT(it)) }
            }
            out.take(30)
        }
}

private class ContinueItem(
    val id: String, val title: String, val subtitle: String, val artwork: String?,
    val fraction: Double, val updated: Long, val isMovie: Boolean,
)

private fun openDetail(t: DetailTarget) = ScreensNav.detail(t)
private fun openCategory(title: String, items: List<DetailTarget>) = ScreensNav.category(CategoryTarget(title, items))

/** Home / Films / Series in Netflix-stijl (= HomeView.swift). */
@Composable
fun HomeScreen(filter: Filter) {
    val tv = AppState.isTV
    val lib = Playlists.library
    val pid = Playlists.source?.id
    val model = remember(filter) { HomeModel(filter) }
    val listState = rememberLazyListState()
    val prepKey = "${pid ?: ""}-${lib.movies.size}-${lib.series.size}"
    LaunchedEffect(prepKey) { model.prepare(prepKey) }

    val movieGroups = remember(lib) { lib.movieGroups }
    val seriesGroups = remember(lib) { lib.seriesGroups }
    val groupLimit = if (filter == Filter.ALL) 8 else 40

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(tvs(26)),
            modifier = Modifier.fillMaxSize()
        ) {
            item {
                val h = model.hero
                if (h != null) {
                    HeroBanner(
                        target = h,
                        onPlay = {
                            when (h) {
                                is DetailTarget.MovieT -> AppState.play(Playables.movie(h.movie, Trakt.imdb(h.movie)))
                                is DetailTarget.SeriesT -> openDetail(h)
                            }
                        },
                        onInfo = { openDetail(h) }
                    )
                } else {
                    Spacer(Modifier.then(if (tv) Modifier else Modifier.statusBarsPadding()).height(tvs(90)))
                }
            }

            // Mijn lijst
            item {
                if (filter != Filter.SERIES) {
                    val mine = remember(lib, pid, Store.myList) { lib.movies.filter { m -> pid != null && Store.inMyList(pid, m.id) } }
                    if (mine.isNotEmpty()) MovieRow(L("My List"), mine, mine, pid)
                } else {
                    val mine = remember(lib, pid, Store.myList) { lib.series.filter { s -> pid != null && Store.inMyList(pid, s.id) } }
                    if (mine.isNotEmpty()) SeriesRow(L("My List"), mine, mine)
                }
            }
            // Onlangs toegevoegd
            if (filter != Filter.SERIES) item {
                val all = remember(lib) { lib.movies.filter { it.addedAt != null }.sortedByDescending { it.addedAt ?: 0L } }
                if (all.isNotEmpty()) MovieRow(L("Recently added"), all.take(30), all, pid)
            }
            // Verder kijken
            item { ContinueRow(filter, lib) }
            // Voor jou
            item { ForYouRow(filter, model.forYou) }
            // Top 10 (Home: eerst series, dan films)
            if (filter != Filter.MOVIES) item {
                val list = model.trendingSeries
                if (list.isNotEmpty()) Top10SeriesRow(L("Top 10 series today"), list)
            }
            if (filter != Filter.SERIES) item {
                val list = model.trendingMovies
                if (list.isNotEmpty()) Top10MoviesRow(L("Top 10 movies today"), list)
            }

            // favoriete zenders
            if (filter == Filter.ALL) item {
                val favs = remember(lib, pid, Store.favorites) { lib.channels.filter { c -> pid != null && Store.isFavorite(pid, c.id) } }
                if (favs.isNotEmpty()) {
                    MediaRow(L("Favorite channels")) {
                        items(favs) { c ->
                            val now = lib.nowPlaying(c)
                            ChannelCard(
                                c, now, favorite = true,
                                modifier = Modifier.focusLift { AppState.play(Playables.channel(c, now), favs) }
                            )
                        }
                    }
                }
            }

            // categorieën
            if (filter != Filter.SERIES) items(movieGroups.take(groupLimit)) { g ->
                val all = remember(lib, g) { lib.movies.filter { it.group == g } }
                if (all.isNotEmpty()) MovieRow(g, all.take(40), all, pid)
            }
            if (filter != Filter.MOVIES) items(seriesGroups.take(groupLimit)) { g ->
                val all = remember(lib, g) { lib.series.filter { it.group == g } }
                if (all.isNotEmpty()) SeriesRow(g, all.take(40), all)
            }

            if (lib.movies.isEmpty() && lib.series.isEmpty() && !Playlists.isLoading) item {
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
                Playlists.source?.let { s ->
                    Box(Modifier.focusLift { AppState.switchPlaylist() }) { AvatarCircle(s, 30.dp) }
                }
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

@Composable
private fun SeriesRow(title: String, items: List<Series>, all: List<Series>?) {
    MediaRow(title, onSeeAll = all?.let { list -> { openCategory(title, list.map { DetailTarget.SeriesT(it) }) } }) {
        items(items) { s ->
            val count = Trakt.watchedCount(Trakt.imdb(s))
            PosterCard(
                s.title, s.poster,
                modifier = Modifier.focusLift { openDetail(DetailTarget.SeriesT(s)) },
                badge = if (count > 0) L("%d WATCHED", count) else null
            )
        }
    }
}

/** Poster met lang-indrukken-menu (afspelen, bekeken, Mijn lijst). */
@Composable
private fun MoviePoster(m: Movie, pid: String?) {
    var menu by remember { mutableStateOf(false) }
    val imdb = Trakt.imdb(m)
    val watched = Playables.isWatched(m, imdb)
    Box {
        PosterCard(
            m.title, m.poster,
            modifier = Modifier.focusLift(onLongClick = { menu = true }) { openDetail(DetailTarget.MovieT(m)) },
            watched = watched,
            progress = Store.progress[m.id]?.fraction
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(L("Play")) },
                leadingIcon = { Icon(Icons.Default.PlayArrow, null) },
                onClick = { menu = false; AppState.play(Playables.movie(m, imdb)) }
            )
            DropdownMenuItem(
                text = { Text(if (watched) L("Mark as unwatched") else L("Mark as watched")) },
                leadingIcon = { Icon(if (watched) Icons.Default.VisibilityOff else Icons.Default.CheckCircle, null) },
                onClick = {
                    menu = false
                    Store.setLocalWatched(m.id, !watched)
                    AppScope.launch { screensSafe { Trakt.setWatched(Playables.movie(m, imdb), !watched) } }
                }
            )
            if (pid != null) {
                val inList = Store.inMyList(pid, m.id)
                DropdownMenuItem(
                    text = { Text(if (inList) L("Remove from My List") else L("Add to My List")) },
                    leadingIcon = { Icon(if (inList) Icons.Default.Close else Icons.Default.Add, null) },
                    onClick = { menu = false; Store.toggleMyList(pid, m.id) }
                )
            }
        }
    }
}

@Composable
private fun ContinueRow(filter: Filter, lib: Library) {
    val progress = Store.progress
    val items = remember(progress, lib, filter) {
        val movieIDs = lib.movies.mapTo(HashSet()) { it.id }
        val m3uEpisodes = HashSet<String>().apply { lib.series.forEach { s -> s.episodes.forEach { add(it.id) } } }
        progress.mapNotNull { (key, e) ->
            val isMovie = key in movieIDs
            if (!isMovie && !key.startsWith("xe") && !key.startsWith("jfe") && !key.startsWith("pxe") && !key.startsWith("se")
                && key !in m3uEpisodes) return@mapNotNull null
            if (filter == Filter.MOVIES && !isMovie) return@mapNotNull null
            if (filter == Filter.SERIES && isMovie) return@mapNotNull null
            val left = max(0.0, e.position / max(e.fraction, 0.01) - e.position)
            ContinueItem(key, e.title, L("%d min left", (left / 60).toInt()), e.artwork, e.fraction, e.updated, isMovie)
        }.sortedByDescending { it.updated }.take(20)
    }
    if (items.isEmpty()) return
    MediaRow(L("Continue watching")) {
        items(items) { c -> ContinueCard(c, lib) }
    }
}

@Composable
private fun ContinueCard(c: ContinueItem, lib: Library) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier.width(Theme.posterWidth).focusLift(onLongClick = { menu = true }) { resume(c, lib) }
        ) {
            PosterCard(c.title, c.artwork, progress = c.fraction)
            Spacer(Modifier.height(4.dp))
            Text(c.subtitle, color = Theme.secondary, fontSize = tsp(10), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(L("Remove from Continue watching")) },
                leadingIcon = { Icon(Icons.Default.Close, null) },
                onClick = { menu = false; Store.clearProgress(c.id) }
            )
        }
    }
}

private fun resume(c: ContinueItem, lib: Library) {
    lib.movies.firstOrNull { it.id == c.id }?.let { m -> AppState.play(Playables.movie(m, Trakt.imdb(m))); return }
    for (s in lib.series) {
        val e = s.episodes.firstOrNull { it.id == c.id }
        if (e != null) { AppState.play(Playables.episode(e, s, Trakt.imdb(s))); return }
    }
    // aflevering die pas bij openen geladen wordt → open de serie
    lib.series.firstOrNull { it.title == c.title }?.let { openDetail(DetailTarget.SeriesT(it)) }
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
