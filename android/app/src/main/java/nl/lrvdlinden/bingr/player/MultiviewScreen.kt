package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

private class MultiviewTile(val channel: Channel, val controller: PlayerController) {
    val id: String = UUID.randomUUID().toString()
}

private fun multiviewPlayable(c: Channel): PlayableItem = PlayableItem(
    id = c.id, title = c.name, subtitle = Playlists.library.nowPlaying(c)?.title, url = c.streamURL,
    type = MediaType.LIVE, artwork = c.logo, stalkerCmd = c.stalkerCmd, channelID = c.id
)

/** Tot 4 live-streams tegelijk (2×2). Het geselecteerde beeld heeft geluid; nogmaals kiezen = volledig scherm. */
@Composable
fun MultiviewScreen(onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val tiles = remember { mutableStateListOf<MultiviewTile>() }
    var active by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    val firstTile = remember { FocusRequester() }
    val isTV = AppState.isTV

    fun focus(t: MultiviewTile) {
        active = t.id
        for (x in tiles) x.controller.muted = x.id != t.id
    }

    fun add(c: Channel) {
        if (tiles.size >= 4) return
        val ctrl = PlayerController(multiviewPlayable(c))
        ctrl.isPreview = true
        val t = MultiviewTile(c, ctrl)
        tiles.add(t)
        if (active == null) active = t.id else ctrl.muted = true
        scope.launch {
            val u = runCatching { Playlists.resolve(ctrl.item) }.getOrNull()
            if (t !in tiles) return@launch   // intussen weggehaald of multiview gesloten
            if (u != null) ctrl.start(u) else ctrl.fail(L("No stream address available."))
            ctrl.muted = active != t.id
        }
    }

    fun remove(t: MultiviewTile) {
        t.controller.stop()
        tiles.remove(t)
        if (active == t.id) { active = null; tiles.firstOrNull()?.let { focus(it) } }
    }

    fun closeAll() {
        tiles.forEach { it.controller.stop() }
        tiles.clear()
        AppState.showMultiview = false
        onClose()
    }

    fun fullscreen(t: MultiviewTile) {
        val zap = AppState.liveZapList
        val ch = t.channel
        closeAll()
        AppScope.launch {
            delay(400)
            AppState.play(multiviewPlayable(ch), zap)
        }
    }

    fun select(t: MultiviewTile) { if (active == t.id) fullscreen(t) else focus(t) }

    LaunchedEffect(Unit) {
        if (tiles.isEmpty()) {
            for (c in AppState.multiviewStart.take(4)) add(c)
            if (tiles.isEmpty()) picking = true
        }
    }
    DisposableEffect(Unit) {
        MainActivity.current?.keepScreenOn(true)
        onDispose {
            tiles.forEach { it.controller.stop() }
            MainActivity.current?.keepScreenOn(false)
        }
    }
    LaunchedEffect(tiles.size) {
        if (isTV && tiles.isNotEmpty() && !picking) { delay(150); runCatching { firstTile.requestFocus() } }
    }
    BackHandler { if (menuFor != null) menuFor = null else closeAll() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val cols = if (tiles.size <= 1) 1 else 2
        val rows = tiles.chunked(cols)
        Column(Modifier.fillMaxSize()) {
            for ((ri, row) in rows.withIndex()) {
                Row(Modifier.fillMaxWidth().weight(1f)) {
                    for ((ci, t) in row.withIndex()) {
                        val isFirst = ri == 0 && ci == 0
                        Box(Modifier.weight(1f).fillMaxSize()) {
                            MultiviewTileView(
                                t, selected = active == t.id,
                                modifier = if (isFirst) Modifier.focusRequester(firstTile) else Modifier,
                                onClick = { select(t) },
                                onLongClick = { menuFor = t.id },
                            )
                            DropdownMenu(expanded = menuFor == t.id, onDismissRequest = { menuFor = null }) {
                                DropdownMenuItem(
                                    text = { Text(L("Full screen")) },
                                    leadingIcon = { Icon(Icons.Filled.Fullscreen, null) },
                                    onClick = { menuFor = null; fullscreen(t) }
                                )
                                DropdownMenuItem(
                                    text = { Text(L("Remove"), color = Theme.red) },
                                    leadingIcon = { Icon(Icons.Filled.Close, null, tint = Theme.red) },
                                    onClick = { menuFor = null; remove(t) }
                                )
                            }
                        }
                    }
                    // oneven aantal: lege halve tegel zodat alles even groot blijft
                    if (row.size < cols) Spacer(Modifier.weight(1f).fillMaxSize())
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().safeDrawingPadding().padding(horizontal = Theme.edge, vertical = tvs(8)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            if (!isTV) {
                Box(Modifier.size(40.dp).clip(CircleShape).focusLift { closeAll() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, L("Close"), tint = Color.White, modifier = Modifier.size(22.dp))
                }
            }
            Text("Multiview", color = Color.White, fontSize = tsp(15), fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            if (tiles.size < 4) {
                var focused by remember { mutableStateOf(false) }
                Row(
                    Modifier
                        .onFocusChanged { focused = it.isFocused }
                        .focusLift(1.06f) { picking = true }
                        .clip(CircleShape)
                        .background(if (focused) Color.White else Color.Black.copy(alpha = 0.6f))
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val fg = if (focused) Color.Black else Color.White
                    Icon(Icons.Filled.Add, null, tint = fg, modifier = Modifier.size(tvs(16)))
                    Spacer(Modifier.width(6.dp))
                    Text(L("Add channel"), color = fg, fontSize = tsp(13), fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    if (picking) {
        val list = AppState.liveZapList.ifEmpty { Playlists.library.channels }
        MultiviewChannelPicker(list, onDismiss = {
            picking = false
            if (tiles.isEmpty()) closeAll()
        }) { c ->
            picking = false
            add(c)
        }
    }
}

@Composable
private fun MultiviewTileView(t: MultiviewTile, selected: Boolean, modifier: Modifier, onClick: () -> Unit, onLongClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val p = t.controller
    Box(
        modifier
            .fillMaxSize()
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.0f, onLongClick = onLongClick, onClick = onClick)
            .background(Color.Black)
            .border(
                width = if (selected || focused) 3.dp else 0.dp,
                color = if (focused) Color.White else if (selected) Theme.red else Color.Transparent
            )
    ) {
        EngineView(p, Modifier.fillMaxSize())
        if ((p.isBuffering || p.reconnecting) && p.errorText == null) {
            CircularProgressIndicator(color = Color.White, modifier = Modifier.align(Alignment.Center).size(tvs(32)), strokeWidth = 2.5.dp)
        }
        p.errorText?.let {
            Text(it, color = Theme.secondary, fontSize = tsp(12), modifier = Modifier.align(Alignment.Center).padding(12.dp))
        }
        Row(
            Modifier.align(Alignment.BottomStart).padding(8.dp)
                .clip(CircleShape).background(Color.Black.copy(alpha = 0.6f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                if (selected) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff, null,
                tint = Color.White, modifier = Modifier.size(tvs(14))
            )
            Spacer(Modifier.width(6.dp))
            Text(t.channel.name, color = Color.White, fontSize = tsp(12), fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Zender kiezen (met zoeken). */
@Composable
private fun MultiviewChannelPicker(channels: List<Channel>, onDismiss: () -> Unit, onPick: (Channel) -> Unit) {
    var q by remember { mutableStateOf("") }
    val cfg = LocalConfiguration.current
    val filtered = remember(q, channels) {
        (if (q.isBlank()) channels else channels.filter { it.name.contains(q.trim(), ignoreCase = true) }).take(300)
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth(if (AppState.isTV) 0.55f else 0.94f)
                .heightIn(max = (cfg.screenHeightDp * 0.86f).dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF141414))
        ) {
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 8.dp, top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(L("Add channel"), color = Color.White, fontWeight = FontWeight.Bold, fontSize = tsp(18), modifier = Modifier.weight(1f))
                PlayerFocusText(L("Cancel"), onClick = onDismiss)
            }
            OutlinedTextField(
                value = q, onValueChange = { q = it }, singleLine = true,
                placeholder = { Text(L("Search channel")) },
                leadingIcon = { Icon(Icons.Filled.Search, null) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.White, unfocusedBorderColor = Theme.elevated,
                    focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = Theme.red
                ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
            )
            LazyColumn(Modifier.fillMaxWidth().padding(bottom = 10.dp)) {
                items(filtered, key = { it.id }) { c ->
                    PlayerSheetItem(onClick = { onPick(c) }) {
                        RemoteImage(c.logo, Modifier.width(tvs(48)).height(tvs(30)).clip(RoundedCornerShape(4.dp)),
                            placeholder = c.name.take(3), fit = true)
                        Column(Modifier.weight(1f)) {
                            Text(c.name, color = Color.White, fontSize = tsp(15), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (c.group.isNotEmpty()) Text(c.group, color = Theme.secondary, fontSize = tsp(12), maxLines = 1)
                        }
                    }
                }
            }
        }
    }
}
