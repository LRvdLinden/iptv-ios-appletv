package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date

private class ProgramHit(val channel: Channel, val p: EPGProgram)
private class GroupHit(val title: String, val items: List<DetailTarget>)

/** Zoekt in titels van de tv-gids: wat nu speelt, straks, en wat nog terug te kijken is. */
private fun searchGuide(q: String, lib: Library): List<ProgramHit> {
    val now = System.currentTimeMillis()
    val needle = screensFold(q)
    val hits = ArrayList<ProgramHit>()
    for (c in lib.channels) {
        val list = lib.epg[c.epgID ?: c.id] ?: continue
        val from = now - maxOf(c.catchupDays, 0) * 86_400_000L
        for (p in list) if (p.end > from && screensFold(p.title).contains(needle)) hits.add(ProgramHit(c, p))
        if (hits.size > 400) break
    }
    // eerst wat nu speelt, dan de toekomst, dan terugkijken
    fun rank(h: ProgramHit) = if (h.p.isNow) 0 else if (h.p.start > now) 1 else 2
    return hits.sortedWith { a, b ->
        val ra = rank(a); val rb = rank(b)
        if (ra != rb) ra - rb else if (ra == 2) b.p.start.compareTo(a.p.start) else a.p.start.compareTo(b.p.start)
    }.take(60)
}

/** Categorieën (films en series) waarvan de naam overeenkomt. */
private fun categoryHits(q: String, lib: Library): List<GroupHit> {
    val t = screensFold(q.trim())
    val out = ArrayList<GroupHit>()
    val mg = lib.movieGroups.filter { screensFold(it).contains(t) }.take(30).toSet()
    val sg = lib.seriesGroups.filter { screensFold(it).contains(t) }.take(30).toSet()
    if (mg.isNotEmpty()) {
        val by = lib.movies.filter { it.group in mg }.groupBy { it.group }
        for (g in lib.movieGroups) if (g in mg) out.add(GroupHit(g, by[g].orEmpty().map { DetailTarget.MovieT(it) }))
    }
    if (sg.isNotEmpty()) {
        val by = lib.series.filter { it.group in sg }.groupBy { it.group }
        for (g in lib.seriesGroups) if (g in sg) out.add(GroupHit(g, by[g].orEmpty().map { DetailTarget.SeriesT(it) }))
    }
    return out.take(30)
}

private fun programTime(ms: Long): String {
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(Localizer.locale, "EEEdMMMHHmm")
    return SimpleDateFormat(pattern, Localizer.locale).format(Date(ms))
}

/** Zoeken in de huidige afspeellijst (alles, los van het tabblad) én in alle andere afspeellijsten (= SearchView.swift). */
@Composable
fun SearchScreen(modal: Boolean, onClose: () -> Unit) {
    val tv = AppState.isTV
    var query by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf(SearchResults()) }
    var programs by remember { mutableStateOf(emptyList<ProgramHit>()) }
    var groupHits by remember { mutableStateOf(emptyList<GroupHit>()) }
    var searching by remember { mutableStateOf(false) }
    var program by remember { mutableStateOf<ProgramHit?>(null) }
    val focusManager = LocalFocusManager.current

    BackHandler(enabled = modal && program == null) { onClose() }

    val fieldFocus = remember { FocusRequester() }
    LaunchedEffect(modal) {
        if (modal) {
            repeat(5) {
                delay(120)
                if (runCatching { fieldFocus.requestFocus() }.isSuccess) return@LaunchedEffect
            }
        }
    }

    LaunchedEffect(query) {
        delay(300)
        val q = query.trim()
        if (q.length < 2) {
            results = SearchResults(); programs = emptyList(); groupHits = emptyList(); searching = false
            return@LaunchedEffect
        }
        searching = true
        val lib = Playlists.library
        val r = screensSafe { Playlists.search(q) } ?: SearchResults()
        val p = withContext(Dispatchers.Default) { searchGuide(q, lib) }
        val g = withContext(Dispatchers.Default) { categoryHits(q, lib) }
        // intussen verder getypt → deze (oude) resultaten niet meer tonen
        if (q != query.trim()) return@LaunchedEffect
        results = r
        programs = p
        groupHits = g
        searching = false
    }

    val lib = Playlists.library
    val edge = Theme.edge

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().blockFocus(program != null)) {
            // zoekveld
            Row(
                Modifier.fillMaxWidth().padding(horizontal = edge, vertical = tvs(10)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                TextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    placeholder = { Text(L("Titles, channels, categories…"), color = Theme.secondary, fontSize = tsp(15), maxLines = 1) },
                    leadingIcon = { Icon(Icons.Default.Search, null, tint = Theme.secondary) },
                    trailingIcon = {
                        if (searching) {
                            CircularProgressIndicator(color = Theme.secondary, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                        } else if (query.isNotEmpty()) {
                            Box(Modifier.size(36.dp).focusLift { query = "" }, contentAlignment = Alignment.Center) {
                                Icon(Icons.Default.Cancel, L("Clear"), tint = Theme.secondary, modifier = Modifier.size(20.dp))
                            }
                        }
                    },
                    textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = tsp(16)),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
                    shape = RoundedCornerShape(12.dp),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Theme.elevated, unfocusedContainerColor = Theme.elevated,
                        focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                        cursorColor = Theme.red, focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                    ),
                    modifier = Modifier.weight(1f).focusRequester(fieldFocus)
                )
                if (modal) {
                    Text(
                        L("Close"), color = Color.White, fontSize = tsp(15), fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.focusLift(1.08f) { onClose() }.padding(6.dp)
                    )
                }
            }

            val q = query.trim()
            LazyVerticalGrid(
                columns = GridCells.Adaptive(Theme.posterWidth),
                contentPadding = PaddingValues(start = edge, end = edge, top = tvs(6), bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(Theme.rowSpacing),
                verticalArrangement = Arrangement.spacedBy(Theme.rowSpacing * 2),
                modifier = Modifier.fillMaxSize()
            ) {
                if (q.length < 2) {
                    full {
                        Column(
                            Modifier.fillMaxWidth().padding(top = 80.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(Icons.Default.Search, null, tint = Theme.secondary, modifier = Modifier.size(tvs(40)))
                            Spacer(Modifier.height(10.dp))
                            Text(
                                L("Search movies, series, channels and the TV guide in all your playlists"),
                                color = Theme.secondary, fontSize = tsp(15), textAlign = TextAlign.Center
                            )
                        }
                    }
                } else if (results.channels.isEmpty() && results.movies.isEmpty() && results.series.isEmpty() &&
                    (results.other.isEmpty() || !Store.isMainActive) && programs.isEmpty() && groupHits.isEmpty() && !searching) {
                    full {
                        Text(
                            L("Nothing found for “%@”.", q), color = Theme.secondary, fontSize = tsp(15), textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(top = 80.dp)
                        )
                    }
                }

                // zenders
                if (results.channels.isNotEmpty()) full {
                    Box(Modifier.bleedHorizontal(edge)) {
                        MediaRow(L("Channels")) {
                            items(results.channels) { c ->
                                val now = lib.nowPlaying(c)
                                ChannelCard(
                                    c, now,
                                    modifier = Modifier.focusLift { AppState.play(Playables.channel(c, now), results.channels) }
                                )
                            }
                        }
                    }
                }

                // categorieën
                if (groupHits.isNotEmpty()) full {
                    Column(Modifier.bleedHorizontal(edge), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SearchSectionTitle(L("Categories"), Modifier.padding(start = edge))
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = edge, vertical = if (tv) 8.dp else 0.dp),
                            horizontalArrangement = Arrangement.spacedBy(tvs(10))
                        ) {
                            items(groupHits) { g ->
                                Row(
                                    Modifier.focusLift(1.06f) { ScreensNav.category(CategoryTarget(g.title, g.items)) }
                                        .clip(RoundedCornerShape(50)).background(Theme.elevated)
                                        .padding(horizontal = tvs(14), vertical = tvs(8)),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    Text(g.title, color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.SemiBold, maxLines = 1)
                                    Text("${g.items.size}", color = Theme.secondary, fontSize = tsp(12))
                                }
                            }
                        }
                    }
                }

                // tv-gids
                if (programs.isNotEmpty()) {
                    full { SearchSectionTitle(L("TV guide")) }
                    items(programs, span = { GridItemSpan(maxLineSpan) }) { h ->
                        Row(
                            Modifier.fillMaxWidth().focusLift(1.02f) { program = h }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            RemoteImage(
                                h.channel.logo,
                                Modifier.width(tvs(56)).height(tvs(36)).clip(RoundedCornerShape(4.dp)),
                                placeholder = h.channel.name.take(3), fit = true
                            )
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    if (h.p.isNow) {
                                        Text(L("NOW"), color = Theme.red, fontSize = tsp(10), fontWeight = FontWeight.Black)
                                    } else if (h.p.end < System.currentTimeMillis()) {
                                        Icon(Icons.Default.History, null, tint = Theme.secondary, modifier = Modifier.size(tvs(12)))
                                    }
                                    Text(h.p.title, color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.SemiBold,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                Text(
                                    "${h.channel.name} · ${programTime(h.p.start)}", color = Theme.secondary, fontSize = tsp(11),
                                    maxLines = 1, overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }

                // films
                if (results.movies.isNotEmpty()) {
                    full { SearchSectionTitle(L("Movies")) }
                    items(results.movies) { m ->
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                            PosterCard(
                                m.title, m.poster,
                                modifier = Modifier.focusLift { ScreensNav.detail(DetailTarget.MovieT(m)) },
                                watched = Playables.isWatched(m, Trakt.imdb(m))
                            )
                        }
                    }
                }

                // series
                if (results.series.isNotEmpty()) {
                    full { SearchSectionTitle(L("Series")) }
                    items(results.series) { s ->
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                            PosterCard(
                                s.title, s.poster,
                                modifier = Modifier.focusLift { ScreensNav.detail(DetailTarget.SeriesT(s)) }
                            )
                        }
                    }
                }

                // andere afspeellijsten: tik → wissel van afspeellijst en open het item
                if (results.other.isNotEmpty() && Store.isMainActive) {
                    full { SearchSectionTitle(L("In your other playlists")) }
                    items(results.other, span = { GridItemSpan(maxLineSpan) }) { h ->
                        Row(
                            Modifier.fillMaxWidth().focusLift(1.02f) {
                                if (modal) onClose()
                                ScreensNav.clear()
                                AppState.open(h.playlist, thenShow = h.itemID)
                            }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            RemoteImage(
                                h.artwork,
                                Modifier.width(tvs(44)).height(tvs(62)).clip(RoundedCornerShape(4.dp)),
                                placeholder = h.title.take(2)
                            )
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(h.title, color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.SemiBold,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(h.subtitle, color = Theme.secondary, fontSize = tsp(11), maxLines = 1)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                AvatarCircle(h.playlist, tvs(22))
                                Text(h.playlist.name, color = Theme.secondary, fontSize = tsp(11), maxLines = 1)
                            }
                        }
                    }
                }
            }
        }

        program?.let { h ->
            ProgramSheet(channel = h.channel, program = h.p, onDismiss = { program = null })
        }
    }
}

/** Element over de volle breedte van het raster. */
private fun LazyGridScope.full(content: @Composable () -> Unit) {
    item(span = { GridItemSpan(maxLineSpan) }) { content() }
}

@Composable
private fun SearchSectionTitle(t: String, modifier: Modifier = Modifier) {
    Text(t, color = Color.White, fontSize = Theme.titleSize, fontWeight = FontWeight.Bold, modifier = modifier.padding(top = 6.dp))
}
