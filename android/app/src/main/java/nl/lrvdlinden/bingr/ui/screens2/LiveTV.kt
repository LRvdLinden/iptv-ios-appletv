package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CalendarViewDay
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private const val S2_FAV_KEY = "★"
private const val S2_RECENT_KEY = "◷"
private const val S2_ALL_KEY = "*"

private fun s2LiveGroupTitle(g: String): String = when (g) {
    S2_FAV_KEY -> "★ " + L("Favorites")
    S2_RECENT_KEY -> "◷ " + L("Recent")
    S2_ALL_KEY -> L("All channels")
    else -> g
}

/**
 * Zoeken gaat altijd door álle zenders (los van de gekozen groep): eerst op naam/nummer,
 * dan op groep en wat er nu speelt (= visibleChannels in LiveTVView.swift).
 */
private fun s2SearchChannels(lib: Library, q: String): List<Channel> {
    val byName = lib.channels.filter { it.name.contains(q, ignoreCase = true) || (it.number?.toString() == q) }
    val nameIDs = byName.mapTo(HashSet()) { it.id }
    val byOther = lib.channels.filter { c ->
        c.id !in nameIDs && (c.group.contains(q, ignoreCase = true) ||
            (lib.nowPlaying(c)?.title?.contains(q, ignoreCase = true) ?: false))
    }
    return byName + byOther
}

/** Live TV: groepen (Alle zenders, Favorieten, Recent, …), zoeken door alle zenders, zenderlijst of tv-gids-raster, multiview. */
@Composable
fun LiveTVScreen() {
    val lib = Playlists.library
    val libKey = System.identityHashCode(lib)
    val pid = Playlists.source?.id ?: ""
    var group by rememberSaveable { mutableStateOf(S2_ALL_KEY) }
    var gridMode by rememberSaveable { mutableStateOf(false) }
    var filter by rememberSaveable { mutableStateOf("") }
    var guideFor by remember { mutableStateOf<Channel?>(null) }
    var program by remember { mutableStateOf<Pair<Channel, EPGProgram>?>(null) }
    var menuFor by remember { mutableStateOf<Channel?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); tick++ } }

    val groups = remember(libKey) { listOf(S2_ALL_KEY, S2_FAV_KEY, S2_RECENT_KEY) + lib.channelGroups }
    val current = if (group in groups) group else S2_ALL_KEY
    val favorites = Store.favorites
    val recents = Store.recentChannels
    val channels: List<Channel> = remember(libKey, current, favorites, recents, pid) {
        when (current) {
            S2_FAV_KEY -> lib.channels.filter { Store.key(pid, it.id) in favorites }
            S2_RECENT_KEY -> {
                val byKey = HashMap<String, Channel>()
                lib.channels.forEach { byKey.putIfAbsent(Store.key(pid, it.id), it) }
                recents.mapNotNull { byKey[it] }
            }
            S2_ALL_KEY -> lib.channels
            else -> lib.channels.filter { it.group == current }
        }
    }
    val query = filter.trim()
    val searching = query.isNotEmpty()
    // zoeken door alle zenders op de achtergrond (grote lijsten), oude resultaten niet tonen
    var found by remember { mutableStateOf<Pair<String, List<Channel>>?>(null) }
    LaunchedEffect(query, libKey) {
        if (query.isEmpty()) { found = null; return@LaunchedEffect }
        delay(150)
        val q = query
        val list = withContext(Dispatchers.Default) { s2SearchChannels(lib, q) }
        found = q to list
    }
    val visible: List<Channel> = if (searching) found?.takeIf { it.first == query }?.second ?: emptyList() else channels
    val searchPending = searching && found?.first != query

    fun play(c: Channel) {
        Store.pushRecentChannel(pid, c.id)
        AppState.play(Playables.channel(c, Playlists.library.nowPlaying(c)), zap = visible)
    }
    fun pickGroup(g: String) { group = g; filter = "" }

    val tv = AppState.isTV
    Column(Modifier.fillMaxSize().background(Theme.bg).then(if (tv) Modifier else Modifier.statusBarsPadding())) {
        // kop: titel + tv-gids/lijst + multiview
        Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edge - 4.dp, vertical = tvs(8)),
            verticalAlignment = Alignment.CenterVertically) {
            Text(L("Live TV"), color = Color.White, fontSize = tsp(if (tv) 22 else 26), fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f).padding(start = 4.dp))
            S2LiveHeaderButton(if (gridMode) L("List") else L("TV guide"),
                if (gridMode) Icons.AutoMirrored.Filled.List else Icons.Default.CalendarViewDay) { gridMode = !gridMode }
            Spacer(Modifier.width(tvs(8)))
            S2LiveHeaderButton("Multiview", Icons.Default.GridView, enabled = lib.channels.isNotEmpty()) {
                AppState.openMultiview(visible.take(1), visible)
            }
        }
        // telefoon: zoekbalk altijd zichtbaar bovenaan (zoals .searchable op iOS)
        if (!tv) {
            S2TextField(filter, { filter = it }, L("Search channel or program"),
                modifier = Modifier.padding(horizontal = Theme.edge, vertical = 4.dp),
                plain = false,
                leading = { Icon(Icons.Default.Search, null, tint = Theme.secondary) },
                trailing = {
                    if (filter.isNotEmpty()) {
                        S2IconButton(Icons.Default.Close, L("Clear search"), tint = Theme.secondary, size = 18.dp) { filter = "" }
                    }
                })
        }

        val area: @Composable (Modifier) -> Unit = { m ->
            Box(m) {
                if (gridMode) {
                    GuideGrid(visible, onPlay = { play(it) }, onProgram = { c, p -> program = c to p })
                } else {
                    S2ChannelList(visible, current, pid, tick, searching = searching, query = query, pending = searchPending,
                        onPlay = { play(it) }, onMenu = { menuFor = it })
                }
            }
        }

        if (tv) {
            Row(Modifier.fillMaxSize().padding(start = Theme.edge)) {
                LazyColumn(Modifier.width(280.dp).fillMaxHeight(), contentPadding = PaddingValues(vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    // zoekveld bovenaan de groepenkolom
                    item {
                        S2TextField(filter, { filter = it }, L("Search channel"),
                            plain = false, leading = { Icon(Icons.Default.Search, null, tint = Theme.secondary) })
                    }
                    if (searching) item {
                        S2TVGroupItem("✕  " + L("Clear search"), selected = false) { filter = "" }
                    }
                    item { Box(Modifier.fillMaxWidth().padding(vertical = 6.dp).height(1.dp).background(Color.White.copy(alpha = 0.12f))) }
                    items(groups) { g -> S2TVGroupItem(s2LiveGroupTitle(g), g == current && !searching) { pickGroup(g) } }
                }
                Spacer(Modifier.width(28.dp))
                area(Modifier.weight(1f).fillMaxHeight())
            }
        } else {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(groups) { g ->
                    val sel = g == current && !searching
                    Text(s2LiveGroupTitle(g), color = if (sel) Color.Black else Color.White, fontSize = tsp(13),
                        fontWeight = FontWeight.SemiBold, maxLines = 1,
                        modifier = Modifier.focusLift(1.05f) { pickGroup(g) }.clip(RoundedCornerShape(50))
                            .background(if (sel) Color.White else Theme.elevated)
                            .padding(horizontal = 14.dp, vertical = 7.dp))
                }
            }
            area(Modifier.fillMaxSize())
        }
    }

    menuFor?.let { c ->
        val fav = Store.isFavorite(pid, c.id)
        S2ActionDialog(c.name, listOf(
            S2Action(if (fav) L("Remove from favorites") else L("Add to favorites"), if (fav) Icons.Default.StarBorder else Icons.Default.Star) {
                Store.toggleFavorite(pid, c.id)
            },
            S2Action(if (c.catchupDays > 0) L("Guide & catch-up") else L("Guide"), Icons.Default.Schedule) { guideFor = c },
            S2Action(L("Open in Multiview"), Icons.Default.GridView) { AppState.openMultiview(listOf(c), visible) },
        ), onDismiss = { menuFor = null })
    }
    guideFor?.let { c -> GuideSheet(c, onDismiss = { guideFor = null }) }
    program?.let { (c, p) -> ProgramSheet(c, p, onDismiss = { program = null }) }
}

@Composable
private fun S2LiveHeaderButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean = true,
                             onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val light = focused && AppState.isTV
    Row(
        Modifier.onFocusChanged { focused = it.isFocused }
            .then(if (enabled) Modifier.focusLift(1.06f, onClick = onClick) else Modifier)
            .clip(RoundedCornerShape(50))
            .background(if (light) Color.White else Theme.elevated)
            .padding(horizontal = tvs(12), vertical = tvs(7)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        val fg = (if (light) Color.Black else Color.White).copy(alpha = if (enabled) 1f else 0.4f)
        Icon(icon, null, tint = fg, modifier = Modifier.size(tvs(16)))
        if (AppState.isTV || title.length < 12) {
            Spacer(Modifier.width(6.dp))
            Text(title, color = fg, fontSize = tsp(13), fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

/** Groep in de linkerkolom op TV: geselecteerd = rode streep en wit (niet vet). */
@Composable
private fun S2TVGroupItem(title: String, selected: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused }
            .focusLift(1.04f, onClick = onClick)
            .clip(RoundedCornerShape(8.dp))
            .background(if (focused) Color.White else Color.Transparent)
            .padding(vertical = 8.dp, horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.width(5.dp).height(26.dp).clip(RoundedCornerShape(50))
            .background(if (selected) Theme.red else Color.Transparent))
        Spacer(Modifier.width(12.dp))
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = when { focused -> Color.Black; selected -> Color.White; else -> Theme.secondary })
    }
}

@Composable
private fun S2ChannelList(
    channels: List<Channel>,
    group: String,
    pid: String,
    tick: Int,
    searching: Boolean,
    query: String,
    pending: Boolean,
    onPlay: (Channel) -> Unit,
    onMenu: (Channel) -> Unit,
) {
    val state = rememberLazyListState()
    LaunchedEffect(group, query) { runCatching { state.scrollToItem(0) } }
    val lib = Playlists.library
    val favorites = Store.favorites
    LazyColumn(Modifier.fillMaxSize(), state = state,
        contentPadding = PaddingValues(horizontal = tvs(8), vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(tvs(2))) {
        if (searching && !pending) {
            item {
                Text(L("%d channels for “%@”", channels.size, query), color = Theme.secondary, fontSize = tsp(13),
                    fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = tvs(8)).padding(top = tvs(6)))
            }
        }
        if (channels.isEmpty() && !pending) {
            item {
                Text(when {
                    searching -> L("No channels found.")
                    group == S2_FAV_KEY -> L("No favorites yet. Hold a channel to add it.")
                    else -> L("No channels.")
                }, color = Theme.secondary, textAlign = TextAlign.Center, fontSize = tsp(14),
                    modifier = Modifier.fillMaxWidth().padding(top = 40.dp))
            }
        }
        items(channels) { c ->
            val refresh = tick   // elke 30 s opnieuw (nu/straks)
            val upcoming = if (refresh >= 0) lib.upcoming(c, 2) else emptyList()
            val now = lib.nowPlaying(c)
            val next = upcoming.firstOrNull { it.start >= (now?.end ?: Long.MAX_VALUE) } ?: upcoming.drop(1).firstOrNull()
            S2ChannelRow(c, now, next, Store.key(pid, c.id) in favorites, onClick = { onPlay(c) }, onLongClick = { onMenu(c) })
        }
    }
}

@Composable
private fun S2ChannelRow(
    channel: Channel,
    now: EPGProgram?,
    next: EPGProgram?,
    favorite: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth()
            .onKeyEvent { e ->
                if (e.type == KeyEventType.KeyUp && e.key == Key.Menu) { onLongClick(); true } else false
            }
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.02f, onLongClick = onLongClick, onClick = onClick)
            .clip(RoundedCornerShape(8.dp))
            .then(if (focused) Modifier.border(2.dp, Color.White, RoundedCornerShape(8.dp)) else Modifier)
            .padding(vertical = tvs(8), horizontal = tvs(8)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (channel.number != null) {
            Text("${channel.number}", color = Theme.secondary, fontSize = tsp(12), fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace, textAlign = TextAlign.End, maxLines = 1,
                modifier = Modifier.width(tvs(34)))
            Spacer(Modifier.width(tvs(12)))
        }
        RemoteImage(channel.logo, Modifier.width(tvs(64)).height(tvs(40)).clip(RoundedCornerShape(4.dp)),
            placeholder = channel.name.take(3), fit = true)
        Spacer(Modifier.width(tvs(12)))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(channel.name, color = Color.White, fontSize = tsp(15), fontWeight = FontWeight.SemiBold, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (favorite) {
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Default.Star, null, tint = Theme.imdb, modifier = Modifier.size(tvs(12)))
                }
                if (channel.catchupDays > 0) {
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Default.History, null, tint = Theme.secondary, modifier = Modifier.size(tvs(12)))
                }
            }
            if (now != null) {
                Text("${s2Time(now.start)}  ${now.title}", color = Color.White.copy(alpha = 0.8f), fontSize = tsp(12),
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(3.dp))
                Box(Modifier.widthIn(max = tvs(220)).clip(RoundedCornerShape(2.dp))) { ProgressBar(now.progress) }
            }
            if (next != null) {
                Spacer(Modifier.height(2.dp))
                Text(L("Next %@  %@", s2Time(next.start), next.title), color = Theme.secondary, fontSize = tsp(11),
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
