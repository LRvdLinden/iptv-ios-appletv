package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

private data class MainTab(val id: Int, val title: String, val icon: ImageVector)

/**
 * Hoofdscherm (= MainTabView.swift). Telefoon: onderbalk; TV: bovenbalk met tabbladen zoals Netflix op TV.
 * Tabbladen: 0 Home, 1 Live TV, 2 Films, 3 Series, 4 Zoeken, 5 Mijn Bingr.
 */
@Composable
fun MainScreen() {
    val tv = AppState.isTV
    val source = Playlists.source
    val lib = Playlists.library

    val hasLive = lib.channels.isNotEmpty() || !(source?.kind?.isMediaServer ?: false)
    val showLive = Prefs.bool("ui.showLive", true)
    val showMovies = Prefs.bool("ui.showMovies", true)
    val showSeries = Prefs.bool("ui.showSeries", true)
    val tabs = buildList {
        add(MainTab(0, L("Home"), Icons.Default.Home))
        if (hasLive && showLive) add(MainTab(1, L("Live TV"), Icons.Default.LiveTv))
        if (showMovies) add(MainTab(2, L("Movies"), Icons.Default.Movie))
        if (showSeries) add(MainTab(3, L("Series"), Icons.Default.VideoLibrary))
        add(MainTab(4, L("Search"), Icons.Default.Search))
        add(MainTab(5, L("My Bingr"), Icons.Default.AccountCircle))
    }
    var tab by rememberSaveable {
        val start = Prefs.int("ui.startTab", 0)
        mutableIntStateOf(if (start in 0..3 && tabs.any { it.id == start }) start else 0)
    }
    val current = if (tabs.any { it.id == tab }) tab else 0

    // terug: eerst naar Home, dan naar de profielkeuze (lagen erboven hebben hun eigen terug-afhandeling)
    BackHandler(enabled = ScreensNav.stack.isEmpty()) {
        if (current != 0) tab = 0 else AppState.switchPlaylist()
    }

    // item uit een andere afspeellijst (globaal zoeken / herinnering) openen zodra de lijst geladen is
    LaunchedEffect(AppState.pendingItemID, lib.channels.size, lib.movies.size, lib.series.size) {
        val id = AppState.pendingItemID ?: return@LaunchedEffect
        val l = Playlists.library
        val c = l.channels.firstOrNull { it.id == id }
        val m = if (c == null) l.movies.firstOrNull { it.id == id } else null
        val s = if (c == null && m == null) l.series.firstOrNull { it.id == id } else null
        when {
            c != null -> { AppState.pendingItemID = null; AppState.play(Playables.channel(c, l.nowPlaying(c)), l.channels) }
            m != null -> { AppState.pendingItemID = null; ScreensNav.detail(DetailTarget.MovieT(m)) }
            s != null -> { AppState.pendingItemID = null; ScreensNav.detail(DetailTarget.SeriesT(s)) }
        }
    }

    val holder = rememberSaveableStateHolder()
    val covered = ScreensNav.stack.isNotEmpty() || Playlists.isLoading

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        Column(Modifier.fillMaxSize().blockFocus(covered)) {
            if (tv) TvTabBar(tabs, current, focusEnabled = !covered) { tab = it }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                holder.SaveableStateProvider(current) {
                    when (current) {
                        0 -> HomeScreen(Filter.ALL)
                        1 -> Box(Modifier.fillMaxSize().then(if (tv) Modifier else Modifier.statusBarsPadding())) { LiveTVScreen() }
                        2 -> HomeScreen(Filter.MOVIES)
                        3 -> HomeScreen(Filter.SERIES)
                        4 -> SearchScreen(modal = false, onClose = {})
                        else -> Box(Modifier.fillMaxSize().then(if (tv) Modifier else Modifier.statusBarsPadding())) { SettingsScreen() }
                    }
                }
            }
            if (!tv) {
                NavigationBar(containerColor = Color.Black.copy(alpha = 0.92f), contentColor = Color.White, tonalElevation = 0.dp) {
                    tabs.forEach { t ->
                        NavigationBarItem(
                            selected = t.id == current,
                            onClick = { tab = t.id },
                            icon = { Icon(t.icon, contentDescription = t.title) },
                            label = { Text(t.title, maxLines = 1, fontSize = tsp(10)) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = Color.White, selectedTextColor = Color.White,
                                unselectedIconColor = Theme.secondary, unselectedTextColor = Theme.secondary,
                                indicatorColor = Color.Transparent,
                            )
                        )
                    }
                }
            }
        }

        AnimatedVisibility(Playlists.isLoading, enter = fadeIn(), exit = fadeOut()) {
            FullLayer { LoadingOverlay(Playlists.loadingText, source) }
        }

        ScreensStackHost()
    }

    val err = Playlists.error
    if (err != null) {
        AlertDialog(
            onDismissRequest = { Playlists.error = null },
            title = { Text(L("Couldn't load playlist")) },
            text = { Text(err) },
            confirmButton = {
                TextButton(onClick = {
                    Playlists.error = null
                    val s = Playlists.source
                    if (s != null) AppScope.launch { Playlists.select(s, forceRefresh = true) }
                }) { Text(L("Try again"), color = Theme.red) }
            },
            dismissButton = { TextButton(onClick = { Playlists.error = null }) { Text("OK", color = Color.White) } },
            containerColor = Theme.elevated,
        )
    }
}

/** Netflix-TV: bovenbalk met logo, tabbladen als "pillen" en het profiel rechts. */
@Composable
private fun TvTabBar(tabs: List<MainTab>, current: Int, focusEnabled: Boolean, onSelect: (Int) -> Unit) {
    val first = rememberInitialFocus(enabled = focusEnabled, key = focusEnabled)
    Row(
        Modifier.fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Black, Color.Black.copy(alpha = 0.85f))))
            .padding(horizontal = Theme.edge, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        BingrLogo(tsp(18))
        Spacer(Modifier.width(28.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            tabs.forEach { t ->
                var focused by remember { mutableStateOf(false) }
                val selected = t.id == current
                Text(
                    t.title,
                    color = when { focused -> Color.Black; selected -> Color.White; else -> Theme.secondary },
                    fontWeight = if (selected || focused) FontWeight.Bold else FontWeight.Medium,
                    fontSize = tsp(13),
                    maxLines = 1,
                    modifier = Modifier
                        .then(if (selected) Modifier.focusRequester(first) else Modifier)
                        .onFocusChanged { focused = it.isFocused }
                        .focusLift(1.06f) { onSelect(t.id) }
                        .clip(RoundedCornerShape(50))
                        .background(
                            when {
                                focused -> Color.White
                                selected -> Color.White.copy(alpha = 0.16f)
                                else -> Color.Transparent
                            }
                        )
                        .padding(horizontal = 14.dp, vertical = 6.dp)
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Playlists.source?.let { s ->
            Box(Modifier.focusLift(1.12f) { AppState.switchPlaylist() }) { AvatarCircle(s, 30.dp) }
        }
    }
}

/** Zwart scherm met kloppende avatar terwijl de afspeellijst laadt. */
@Composable
private fun LoadingOverlay(text: String, source: PlaylistSource?) {
    val pulse = rememberInfiniteTransition(label = "pulse")
    val s by pulse.animateFloat(0.97f, 1.05f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "s")
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (source != null) {
            Column(
                Modifier.graphicsLayer { scaleX = s; scaleY = s },
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                AvatarCircle(source, tvs(110))
                Spacer(Modifier.height(10.dp))
                Text(source.name, color = Theme.secondary, fontSize = tsp(14), maxLines = 1)
            }
            Spacer(Modifier.height(tvs(22)))
        }
        CircularProgressIndicator(color = Theme.red, modifier = Modifier.size(tvs(36)))
        Spacer(Modifier.height(tvs(22)))
        Text(text, color = Theme.secondary, fontSize = tsp(14))
    }
}
