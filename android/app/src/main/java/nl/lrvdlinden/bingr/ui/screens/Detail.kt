package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Theaters
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Detailpagina in UHF/Netflix-stijl (= DetailView.swift): grote afbeelding met logo, score, afspeelknop,
 * Mijn lijst, trailer, bekeken, andere bronnen, beschrijving, afleveringen, beoordelingen, cast en aanbevelingen.
 */
@Composable
fun DetailScreen(target: DetailTarget, onClose: () -> Unit) {
    val tv = AppState.isTV
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var d by remember(target.id) { mutableStateOf<TitleDetails?>(null) }
    var episodes by remember(target.id) { mutableStateOf(emptyList<Episode>()) }
    var season by remember(target.id) { mutableIntStateOf(1) }
    var seasonInfo by remember(target.id) { mutableStateOf(mapOf<String, TitleDetails.EpisodeInfo>()) }
    var loading by remember(target.id) { mutableStateOf(true) }
    var fetchedTrailer by remember(target.id) { mutableStateOf<String?>(null) }
    var showSources by remember { mutableStateOf(false) }
    var sourcesLoading by remember { mutableStateOf(false) }
    var sources by remember { mutableStateOf(emptyList<OtherHit>()) }
    var toast by remember { mutableStateOf<String?>(null) }
    var ageGate by remember { mutableStateOf(false) }
    var afterPIN by remember { mutableStateOf<(() -> Unit)?>(null) }
    var seasonMenu by remember { mutableStateOf(false) }
    var recMatches by remember(target.id) { mutableStateOf(mapOf<Int, DetailTarget>()) }

    val pid = Playlists.source?.id
    val lib = Playlists.library
    val details = d
    val title = details?.title?.takeIf { it.isNotBlank() } ?: target.title
    val imdb: String? = when (target) {
        is DetailTarget.MovieT -> Trakt.imdb(target.movie)
        is DetailTarget.SeriesT -> Trakt.imdb(target.series)
    } ?: screensText(details?.imdbID)
    val heroImage = if (tv) screensText(details?.backdrop) ?: screensText(details?.poster) ?: target.poster
    else screensText(details?.poster) ?: target.poster ?: screensText(details?.backdrop)
    val trailerID = screensText(details?.trailerYouTubeID) ?: fetchedTrailer
    val isMovie = target is DetailTarget.MovieT
    val seasons = remember(episodes) { episodes.map { it.season }.distinct().sorted() }
    val progress = Store.progress
    val nextEpisode: Episode? = episodes.firstOrNull { (progress[it.id]?.fraction ?: 0.0) > 0.02 }
        ?: episodes.firstOrNull { !Playables.isWatched(it, imdb) } ?: episodes.firstOrNull()
    val isWatchedTitle = (target as? DetailTarget.MovieT)?.let { Playables.isWatched(it.movie, imdb) } ?: false
    val inMyList = (imdb != null && imdb in Trakt.watchlist) || (pid != null && Store.inMyList(pid, target.id))
    val resumeFraction: Double? = when (target) {
        is DetailTarget.MovieT -> Playables.resume(target.movie.id, imdb)
        is DetailTarget.SeriesT -> nextEpisode?.let { progress[it.id]?.fraction }
    }
    val playTitle = when (target) {
        is DetailTarget.MovieT -> if ((resumeFraction ?: 0.0) > 0.02) L("Resume") else L("Play")
        is DetailTarget.SeriesT -> nextEpisode?.let { L("Play Season %d: Episode %d", it.season, it.number) } ?: L("Play")
    }

    fun flash(t: String) {
        toast = t
        scope.launch { delay(1600); if (toast == t) toast = null }
    }

    // MARK: laden
    LaunchedEffect(target.id) {
        loading = true
        coroutineScope {
            val eps = (target as? DetailTarget.SeriesT)?.let { st -> async { screensSafe { Playlists.episodes(st.series) } ?: emptyList() } }
            d = screensSafe { Details.load(target) }
            episodes = eps?.await() ?: emptyList()
        }
        val id = when (target) {
            is DetailTarget.MovieT -> Trakt.imdb(target.movie)
            is DetailTarget.SeriesT -> Trakt.imdb(target.series)
        } ?: screensText(d?.imdbID)
        val n = nextEpisodeOf(episodes, id)
        season = n?.season ?: episodes.map { it.season }.minOrNull() ?: 1
        loading = false
        if (screensText(d?.trailerYouTubeID) == null && id != null) {
            fetchedTrailer = screensSafe { Trakt.trailer(id, target.isSeries) }
        }
    }
    LaunchedEffect(season, details) {
        val tmdb = screensInt(details?.tmdbID) ?: return@LaunchedEffect
        if (target !is DetailTarget.SeriesT) return@LaunchedEffect
        val info = screensSafe { Details.season(tmdb, season) } ?: emptyMap()
        if (info.isNotEmpty()) seasonInfo = seasonInfo + info
    }
    // aanbevelingen die in deze afspeellijst staan
    LaunchedEffect(details, lib) {
        val recs = details?.recommendations ?: return@LaunchedEffect
        recMatches = withContext(Dispatchers.Default) {
            val movies = HashMap<String, MutableList<Movie>>()
            lib.movies.forEach { movies.getOrPut(screensNormTitle(it.title)) { ArrayList() }.add(it) }
            val series = HashMap<String, Series>()
            lib.series.forEach { series.putIfAbsent(screensNormTitle(it.title), it) }
            val out = HashMap<Int, DetailTarget>()
            recs.forEachIndexed { i, r ->
                val n = screensNormTitle(r.title)
                if (r.isShow) {
                    series[n]?.let { out[i] = DetailTarget.SeriesT(it) }
                } else {
                    val y = screensInt(r.year)
                    movies[n]?.firstOrNull { y == null || it.year == null || it.year == y }?.let { out[i] = DetailTarget.MovieT(it) }
                }
            }
            out
        }
    }

    // MARK: acties

    fun ageChecked(action: () -> Unit) {
        val limit = Playlists.source?.ageLimit
        val rated = screensText(details?.certification) ?: when (target) {
            is DetailTarget.MovieT -> Metadata.cached(target.movie)?.rated
            is DetailTarget.SeriesT -> Metadata.cached(target.series)?.rated
        }
        if (ParentalControl.allowed(rated, target.group, limit)) { action(); return }
        if (ParentalControl.hasPIN) { afterPIN = action; ageGate = true }
        else flash(L("Not available on this profile (age limit)."))
    }

    fun openSources() {
        if (sourcesLoading) return
        sourcesLoading = true
        scope.launch {
            val year = screensInt(details?.year) ?: target.year
            sources = screensSafe { Playlists.otherSources(title, year, target.isSeries, target.id) } ?: emptyList()
            sourcesLoading = false
            showSources = true
        }
    }

    fun play() = ageChecked {
        when (target) {
            is DetailTarget.MovieT -> {
                val m = target.movie
                if (m.streamURL == null && m.stalkerCmd == null && m.imdbID == null && imdb == null) openSources()
                else AppState.play(Playables.movie(m, imdb))
            }
            is DetailTarget.SeriesT -> {
                val n = nextEpisode
                if (n != null) AppState.play(Playables.episode(n, target.series, imdb)) else openSources()
            }
        }
    }

    fun toggleMyList() {
        val p = pid ?: return
        Store.toggleMyList(p, target.id)
        val nowIn = Store.inMyList(p, target.id)
        if (imdb != null) AppScope.launch { screensSafe { Trakt.toggleWatchlist(imdb, target.isSeries) } }
        flash(if (nowIn) L("Added to My List") else L("Removed from My List"))
    }

    fun toggleWatchedMovie() {
        val m = (target as? DetailTarget.MovieT)?.movie ?: return
        val w = isWatchedTitle
        Store.setLocalWatched(m.id, !w)
        AppScope.launch { screensSafe { Trakt.setWatched(Playables.movie(m, imdb), !w) } }
    }

    fun openLocal(id: String) {
        lib.movies.firstOrNull { it.id == id }?.let { ScreensNav.detail(DetailTarget.MovieT(it)); return }
        lib.series.firstOrNull { it.id == id }?.let { ScreensNav.detail(DetailTarget.SeriesT(it)) }
    }

    BackHandler(enabled = !showSources && !ageGate) { onClose() }
    BackHandler(enabled = showSources) { showSources = false }

    val playFocus = rememberInitialFocus(key = target.id)
    val headerHeight: Dp = if (tv) 330.dp else 560.dp
    val contentAlign = if (tv) Alignment.Start else Alignment.CenterHorizontally

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        Column(
            Modifier.fillMaxSize().blockFocus(showSources || ageGate).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(tvs(22))
        ) {
            // MARK: kop
            Box(Modifier.fillMaxWidth().height(headerHeight)) {
                RemoteImage(heroImage, Modifier.matchParentSize())
                Box(
                    Modifier.matchParentSize().background(
                        Brush.verticalGradient(0.35f to Color.Transparent, 0.75f to Color.Black.copy(alpha = 0.65f), 1f to Color.Black)
                    )
                )
                if (tv) {
                    Box(Modifier.matchParentSize().background(Brush.horizontalGradient(0f to Color.Black.copy(alpha = 0.85f), 0.5f to Color.Transparent)))
                }
                Box(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = Theme.edge).padding(bottom = tvs(8)),
                    contentAlignment = if (tv) Alignment.BottomStart else Alignment.BottomCenter
                ) {
                    val logo = screensText(details?.logo)
                    val titleText: @Composable () -> Unit = {
                        Text(
                            title.uppercase(), color = Color.White, fontSize = tsp(34), fontWeight = FontWeight.Black,
                            letterSpacing = 1.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            textAlign = if (tv) TextAlign.Start else TextAlign.Center, lineHeight = tsp(38)
                        )
                    }
                    if (logo != null) {
                        coil.compose.SubcomposeAsyncImage(
                            model = logo, contentDescription = title,
                            modifier = Modifier.widthIn(max = tvs(300)).heightIn(max = tvs(110)),
                            contentScale = ContentScale.Fit,
                            loading = { titleText() },
                            error = { titleText() }
                        )
                    } else {
                        titleText()
                    }
                }
            }

            // MARK: score, jaar, duur
            Column(
                Modifier.fillMaxWidth().padding(horizontal = Theme.edge),
                horizontalAlignment = contentAlign,
                verticalArrangement = Arrangement.spacedBy(tvs(22))
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(tvs(14))) {
                    val main = details?.ratings?.firstOrNull { it.source == "IMDb" } ?: details?.ratings?.firstOrNull()
                    Text(
                        "★ ${main?.value?.toString() ?: "–"}", color = Color.White, fontSize = tsp(15), fontWeight = FontWeight.Bold,
                        modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.15f))
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                    )
                    (screensText(details?.year) ?: target.year?.toString())?.let { Text(it.take(4), color = Color.White, fontSize = tsp(16)) }
                    screensText(details?.certification)?.let {
                        Text(
                            it, color = Color.White, fontSize = tsp(12), fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.border(1.dp, Theme.secondary, RoundedCornerShape(3.dp)).padding(horizontal = 5.dp, vertical = 1.dp)
                        )
                    }
                    if (!isMovie && seasons.isNotEmpty()) {
                        Text(if (seasons.size == 1) L("1 season") else L("%d seasons", seasons.size), color = Color.White, fontSize = tsp(16))
                    } else {
                        screensText(details?.runtime)?.let { Text(it, color = Color.White, fontSize = tsp(16)) }
                    }
                    if (isWatchedTitle) Icon(Icons.Default.CheckCircle, null, tint = Theme.green, modifier = Modifier.size(tvs(18)))
                }

                // MARK: knoppen
                Column(
                    Modifier.widthIn(max = if (tv) 460.dp else 700.dp).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(tvs(12))
                ) {
                    Box(
                        Modifier.fillMaxWidth()
                            .focusRequester(playFocus)
                            .focusLift(1.04f) { play() }
                            .height(tvs(52)).clip(RoundedCornerShape(50)).background(Color.White),
                        contentAlignment = Alignment.Center
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.PlayArrow, null, tint = Color.Black, modifier = Modifier.size(tvs(22)))
                            Spacer(Modifier.width(6.dp))
                            Text(playTitle, color = Color.Black, fontSize = tsp(16), fontWeight = FontWeight.SemiBold, maxLines = 1)
                        }
                        val p = resumeFraction ?: 0.0
                        if (p > 0.02) {
                            Box(
                                Modifier.align(Alignment.BottomCenter).padding(start = 24.dp, end = 24.dp, bottom = 6.dp)
                                    .fillMaxWidth().height(3.dp)
                            ) {
                                Box(Modifier.fillMaxWidth(p.toFloat().coerceIn(0f, 1f)).fillMaxHeight().clip(RoundedCornerShape(50)).background(Theme.red))
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(tvs(12)), verticalAlignment = Alignment.CenterVertically) {
                        DetailCircleButton(
                            if (inMyList) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                            tint = if (inMyList) Theme.red else Color.White
                        ) { toggleMyList() }
                        if (trailerID != null) DetailCircleButton(Icons.Default.Theaters) { Trailer.open(ctx, trailerID) }
                        if (isMovie) DetailCircleButton(if (isWatchedTitle) Icons.Default.CheckCircle else Icons.Default.Check) { toggleWatchedMovie() }
                        DetailCapsule(L("Other sources"), Modifier.weight(1f), busy = sourcesLoading) { openSources() }
                    }
                }

                val overview = screensText(details?.overview) ?: when (target) {
                    is DetailTarget.MovieT -> target.movie.plot
                    is DetailTarget.SeriesT -> target.series.plot
                }
                if (!overview.isNullOrBlank()) {
                    Text(
                        overview, color = Color.White.copy(alpha = 0.92f), fontSize = tsp(16),
                        modifier = Modifier.widthIn(max = 700.dp).fillMaxWidth()
                    )
                } else if (loading) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(tvs(24)))
                }
                val genres = screensText(details?.genres)
                val director = screensText(details?.director)
                if (genres != null || director != null) {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        genres?.let { CreditLine(L("Genres"), it) }
                        director?.let { CreditLine(L("Director"), it) }
                    }
                }
            }

            // MARK: afleveringen
            if (target is DetailTarget.SeriesT) {
                val s = target.series
                val list = episodes.filter { it.season == season }
                Column(verticalArrangement = Arrangement.spacedBy(tvs(14))) {
                    DetailSectionTitle(L("Episodes"))
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = Theme.edge),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (seasons.isNotEmpty()) {
                            Box {
                                Row(
                                    Modifier.focusLift(1.05f) { if (seasons.size > 1) seasonMenu = true }
                                        .clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.12f))
                                        .padding(horizontal = 16.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(L("Season %d", season), color = Color.White, fontSize = tsp(16), fontWeight = FontWeight.SemiBold)
                                    if (seasons.size > 1) {
                                        Spacer(Modifier.width(6.dp))
                                        Icon(Icons.Default.KeyboardArrowDown, null, tint = Color.White, modifier = Modifier.size(tvs(18)))
                                    }
                                }
                                DropdownMenu(expanded = seasonMenu, onDismissRequest = { seasonMenu = false }) {
                                    seasons.forEach { n ->
                                        DropdownMenuItem(
                                            text = { Text(L("Season %d", n)) },
                                            onClick = { seasonMenu = false; season = n }
                                        )
                                    }
                                }
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        if (list.isNotEmpty()) {
                            val all = list.all { Playables.isWatched(it, imdb) }
                            Box(
                                Modifier.size(tvs(40)).focusLift(1.12f) {
                                    list.forEach { Store.setLocalWatched(it.id, !all) }
                                    if (imdb != null) AppScope.launch {
                                        list.forEach { e -> screensSafe { Trakt.setWatched(Playables.episode(e, s, imdb), !all) } }
                                    }
                                },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    if (all) Icons.Default.CheckCircle else Icons.Default.Check, null,
                                    tint = if (all) Theme.red else Theme.secondary, modifier = Modifier.size(tvs(24))
                                )
                            }
                        }
                    }
                    if (loading && episodes.isEmpty()) {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(tvs(24)))
                        }
                    }
                    val rowState = rememberLazyListState()
                    LaunchedEffect(season, episodes) {
                        val n = nextEpisode
                        val idx = if (n != null && n.season == season) list.indexOfFirst { it.id == n.id } else -1
                        if (idx > 0) rowState.scrollToItem(idx)
                    }
                    LazyRow(
                        state = rowState,
                        contentPadding = PaddingValues(horizontal = Theme.edge, vertical = if (tv) 14.dp else 0.dp),
                        horizontalArrangement = Arrangement.spacedBy(tvs(14))
                    ) {
                        items(list) { e ->
                            val info = seasonInfo["${e.season}-${e.number}"] ?: details?.episodeInfo?.get("${e.season}-${e.number}")
                            EpisodeCard(
                                e = e, s = s, info = info, imdb = imdb,
                                fallbackStill = screensText(details?.backdrop) ?: s.poster,
                                onPlay = { ageChecked { AppState.play(Playables.episode(e, s, imdb)) } }
                            )
                        }
                    }
                }
            }

            // MARK: beoordelingen
            val ratings = details?.ratings.orEmpty()
            if (ratings.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(tvs(12))) {
                    DetailSectionTitle(L("Ratings"))
                    Row(
                        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Theme.edge),
                        horizontalArrangement = Arrangement.spacedBy(tvs(40))
                    ) {
                        ratings.forEach { r ->
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    when (r.source) {
                                        "IMDb" -> Text(
                                            "IMDb", color = Color.Black, fontSize = tsp(9), fontWeight = FontWeight.Black,
                                            modifier = Modifier.clip(RoundedCornerShape(3.dp)).background(Theme.imdb).padding(horizontal = 4.dp, vertical = 2.dp)
                                        )
                                        "Trakt" -> Icon(Icons.Default.CheckBox, null, tint = Color(0xFFED1C24), modifier = Modifier.size(tvs(16)))
                                        else -> Icon(Icons.Default.Star, null, tint = Theme.secondary, modifier = Modifier.size(tvs(13)))
                                    }
                                    Text(r.source, color = Theme.secondary, fontSize = tsp(16))
                                }
                                Text(r.value.toString(), color = Color.White, fontSize = tsp(22), fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }

            // MARK: cast
            val cast = details?.cast.orEmpty()
            if (cast.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(tvs(12))) {
                    DetailSectionTitle(L("Cast"))
                    LazyHorizontalGrid(
                        rows = GridCells.Fixed(2),
                        contentPadding = PaddingValues(horizontal = Theme.edge),
                        horizontalArrangement = Arrangement.spacedBy(tvs(26)),
                        verticalArrangement = Arrangement.spacedBy(tvs(14)),
                        modifier = Modifier.fillMaxWidth().height(tvs(76) * 2 + tvs(14))
                    ) {
                        items(cast) { c ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Box(
                                    Modifier.size(tvs(70)).clip(CircleShape).background(Theme.elevated),
                                    contentAlignment = Alignment.Center
                                ) {
                                    val photo = screensText(c.photo)
                                    if (photo != null) RemoteImage(photo, Modifier.matchParentSize())
                                    else Text(
                                        c.name.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1) },
                                        color = Theme.secondary, fontSize = tsp(18), fontWeight = FontWeight.Bold
                                    )
                                }
                                Column(Modifier.width(tvs(170))) {
                                    Text(c.name, color = Color.White, fontSize = tsp(16), fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    screensText(c.role)?.let {
                                        Text(it, color = Theme.secondary, fontSize = tsp(14), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // MARK: aanbevelingen
            val recs = details?.recommendations.orEmpty()
            if (recs.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(tvs(12))) {
                    DetailSectionTitle(L("Recommendations"))
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = Theme.edge, vertical = if (tv) 14.dp else 0.dp),
                        horizontalArrangement = Arrangement.spacedBy(tvs(14))
                    ) {
                        itemsIndexed(recs) { i, r ->
                            val match = recMatches[i]
                            Column(
                                Modifier.width(tvs(140)).focusLift {
                                    if (match != null) {
                                        ScreensNav.detail(match)
                                    } else {
                                        // niet in deze afspeellijst: toon de details (afspelen zoekt in andere bronnen / Stremio)
                                        val y = screensInt(r.year)
                                        val poster = screensText(r.poster)
                                        val rid = screensText(r.imdbID)
                                        ScreensNav.detail(
                                            if (r.isShow) DetailTarget.SeriesT(Series(id = "rec-${r.title}", title = r.title, year = y, poster = poster, imdbID = rid))
                                            else DetailTarget.MovieT(Movie(id = "rec-${r.title}", title = r.title, year = y, poster = poster, imdbID = rid))
                                        )
                                    }
                                },
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(tvs(12)))) {
                                    RemoteImage(screensText(r.poster), Modifier.matchParentSize(), placeholder = r.title)
                                    if (match != null) {
                                        Box(
                                            Modifier.align(Alignment.TopEnd).padding(6.dp).size(tvs(22)).clip(CircleShape).background(Theme.red),
                                            contentAlignment = Alignment.Center
                                        ) { Icon(Icons.Default.PlayArrow, null, tint = Color.White, modifier = Modifier.size(tvs(15))) }
                                    }
                                }
                                Text(r.title, color = Color.White, fontSize = tsp(14), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(40.dp))
        }

        // sluitknop (telefoon)
        if (!tv) {
            Box(
                Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 8.dp, end = 16.dp)
                    .size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f))
                    .focusLift { onClose() },
                contentAlignment = Alignment.Center
            ) { Icon(Icons.Default.Close, L("Close"), tint = Color.White, modifier = Modifier.size(20.dp)) }
        }

        toast?.let {
            Text(
                it, color = Color.White, fontSize = tsp(13), fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 40.dp)
                    .clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.8f))
                    .padding(horizontal = 16.dp, vertical = 10.dp)
            )
        }

        if (showSources) {
            SourcesPanel(
                sources = sources,
                currentPlaylistID = pid,
                onClose = { showSources = false },
                onPick = { h ->
                    showSources = false
                    if (h.playlist.id == pid) openLocal(h.itemID)
                    else { ScreensNav.clear(); AppState.open(h.playlist, thenShow = h.itemID) }
                }
            )
        }

        if (ageGate) {
            PinPad(
                title = L("This title is above the age limit of this profile. Enter PIN"),
                onDismiss = { ageGate = false; afterPIN = null },
                onSubmit = { pin ->
                    if (ParentalControl.verify(pin)) {
                        val run = afterPIN
                        afterPIN = null
                        ageGate = false
                        scope.launch { delay(300); run?.invoke() }
                        true
                    } else false
                }
            )
        }
    }
}

/** Zelfde volgorde als [DetailScreen]: eerst een half gekeken aflevering, anders de eerste onbekeken. */
private fun nextEpisodeOf(episodes: List<Episode>, imdb: String?): Episode? =
    episodes.firstOrNull { (Store.progress[it.id]?.fraction ?: 0.0) > 0.02 }
        ?: episodes.firstOrNull { !Playables.isWatched(it, imdb) } ?: episodes.firstOrNull()

@Composable
private fun DetailSectionTitle(t: String) {
    Text(
        t.uppercase(), color = Theme.secondary, fontSize = tsp(14), fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp,
        modifier = Modifier.padding(horizontal = Theme.edge)
    )
}

@Composable
private fun CreditLine(k: String, v: String) {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Theme.secondary)) { append("$k: ") }
            withStyle(SpanStyle(color = Color.White.copy(alpha = 0.85f))) { append(v) }
        },
        fontSize = tsp(13), maxLines = 2, overflow = TextOverflow.Ellipsis
    )
}

/** Ronde knop; op TV wit bij focus (zoals Netflix). */
@Composable
private fun DetailCircleButton(icon: ImageVector, tint: Color = Color.White, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val lit = AppState.isTV && focused
    Box(
        Modifier.onFocusChanged { focused = it.isFocused }
            .focusLift(1.1f, onClick = onClick)
            .size(tvs(50)).clip(CircleShape)
            .background(if (lit) Color.White else Color.White.copy(alpha = 0.12f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, null, tint = if (lit) Color.Black else tint, modifier = Modifier.size(tvs(22)))
    }
}

@Composable
private fun DetailCapsule(text: String, modifier: Modifier, busy: Boolean = false, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val lit = AppState.isTV && focused
    Box(
        modifier.onFocusChanged { focused = it.isFocused }
            .focusLift(1.05f, onClick = onClick)
            .height(tvs(50)).clip(RoundedCornerShape(50))
            .background(if (lit) Color.White else Color.White.copy(alpha = 0.12f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(50)),
        contentAlignment = Alignment.Center
    ) {
        if (busy) CircularProgressIndicator(color = if (lit) Color.Black else Color.White, strokeWidth = 2.dp, modifier = Modifier.size(tvs(18)))
        else Text(text, color = if (lit) Color.Black else Color.White, fontSize = tsp(15), fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun EpisodeCard(
    e: Episode,
    s: Series,
    info: TitleDetails.EpisodeInfo?,
    imdb: String?,
    fallbackStill: String?,
    onPlay: () -> Unit,
) {
    val tv = AppState.isTV
    val w = if (tv) 300.dp else 290.dp
    val watched = Playables.isWatched(e, imdb)
    val progress = Store.progress[e.id]?.fraction
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier.width(w).focusLift(1.05f, onLongClick = { menu = true }, onClick = onPlay)
                .clip(RoundedCornerShape(tvs(14))).background(Color.White.copy(alpha = 0.06f))
                .padding(bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(tvs(12)))) {
                RemoteImage(screensText(info?.still) ?: e.still ?: fallbackStill, Modifier.matchParentSize())
                if (progress != null && progress > 0) {
                    Box(
                        Modifier.align(Alignment.BottomCenter).padding(start = 16.dp, end = 16.dp, bottom = 12.dp)
                            .fillMaxWidth().height(5.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.3f))
                    ) {
                        Box(Modifier.fillMaxWidth(progress.toFloat().coerceIn(0f, 1f)).fillMaxHeight().clip(RoundedCornerShape(50)).background(Color.White))
                    }
                }
                if (watched) {
                    Box(
                        Modifier.align(Alignment.TopEnd).padding(8.dp).size(tvs(22)).clip(CircleShape).background(Theme.red),
                        contentAlignment = Alignment.Center
                    ) { Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(tvs(14))) }
                }
            }
            Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(String.format(java.util.Locale.US, "S%02dE%02d", e.season, e.number), color = Theme.secondary, fontSize = tsp(13))
                Text(
                    screensText(info?.title) ?: Playables.cleanEpisodeTitle(e),
                    color = Color.White, fontSize = tsp(16), fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                val o = screensText(info?.overview) ?: e.plot
                if (!o.isNullOrBlank()) {
                    Text(o, color = Theme.secondary, fontSize = tsp(13), maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
                val air = screensDate(info?.airDate)
                val minutes = screensInt(info?.runtime) ?: e.durationSeconds?.let { it / 60 }
                if (air != null || (minutes != null && minutes > 0)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        air?.let { Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = tsp(12)) }
                        if (minutes != null && minutes > 0) Text(L("%d min", minutes), color = Color.White.copy(alpha = 0.8f), fontSize = tsp(12))
                    }
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(L("Play")) },
                leadingIcon = { Icon(Icons.Default.PlayArrow, null) },
                onClick = { menu = false; onPlay() }
            )
            DropdownMenuItem(
                text = { Text(if (watched) L("Mark as unwatched") else L("Mark as watched")) },
                leadingIcon = { Icon(if (watched) Icons.Default.VisibilityOff else Icons.Default.CheckCircle, null) },
                onClick = {
                    menu = false
                    Store.setLocalWatched(e.id, !watched)
                    AppScope.launch { screensSafe { Trakt.setWatched(Playables.episode(e, s, imdb), !watched) } }
                }
            )
        }
    }
}

/** "Andere bronnen": dezelfde titel in andere groepen of afspeellijsten. */
@Composable
private fun SourcesPanel(
    sources: List<OtherHit>,
    currentPlaylistID: String?,
    onClose: () -> Unit,
    onPick: (OtherHit) -> Unit,
) {
    val first = rememberInitialFocus()
    Box(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.7f)).pointerInput(Unit) { detectTapGestures { onClose() } },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier.padding(Theme.edge).widthIn(max = 560.dp).fillMaxWidth()
                .clip(RoundedCornerShape(16.dp)).background(Theme.elevated)
                .pointerInput(Unit) { detectTapGestures { } }
                .padding(vertical = 14.dp)
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(L("Other sources"), color = Color.White, fontSize = tsp(18), fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(
                    L("Close"), color = Theme.red, fontSize = tsp(15), fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.then(if (sources.isEmpty()) Modifier.focusRequester(first) else Modifier)
                        .focusLift(1.08f) { onClose() }.padding(6.dp)
                )
            }
            if (sources.isEmpty()) {
                Text(
                    L("This title isn't available in your other groups or playlists."),
                    color = Theme.secondary, fontSize = tsp(14), modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp)
                )
            }
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                sources.forEachIndexed { i, h ->
                    Row(
                        Modifier.fillMaxWidth()
                            .then(if (i == 0) Modifier.focusRequester(first) else Modifier)
                            .focusLift(1.03f) { onPick(h) }
                            .padding(horizontal = 18.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        AvatarCircle(h.playlist, tvs(34))
                        Column(Modifier.weight(1f)) {
                            Text(
                                if (h.playlist.id == currentPlaylistID) "${h.playlist.name} · ${h.title}" else h.playlist.name,
                                color = Color.White, fontSize = tsp(15), maxLines = 1, overflow = TextOverflow.Ellipsis
                            )
                            Text(h.subtitle, color = Theme.secondary, fontSize = tsp(12), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.Default.PlayCircle, null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(tvs(20)))
                    }
                }
            }
        }
    }
}
