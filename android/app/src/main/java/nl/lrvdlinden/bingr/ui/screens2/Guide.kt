package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import java.util.Calendar

private const val S2_HALF_HOUR = 1_800_000L
private const val S2_GUIDE_HOURS = 14
/** Het raster toont maximaal zoveel zenders (anders wordt het op een tv-box te zwaar). */
private const val S2_GUIDE_LIMIT = 150

/** Begin van het raster: een uur geleden, afgerond op een half uur. */
private fun s2GuideStart(now: Long): Long = Calendar.getInstance().apply {
    timeInMillis = now - 3_600_000L
    val m = get(Calendar.MINUTE)
    add(Calendar.MINUTE, -(m % 30))
    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

private fun s2ReminderID(channel: Channel, p: EPGProgram) = "${channel.id}-${p.start / 1000}"

/** TV-gids als raster: zenders verticaal, tijd horizontaal (14 uur), rode "nu"-lijn; maximaal 150 zenders. */
@Composable
fun GuideGrid(channels: List<Channel>, onPlay: (Channel) -> Unit, onProgram: (Channel, EPGProgram) -> Unit) {
    val shown = if (channels.size > S2_GUIDE_LIMIT) channels.take(S2_GUIDE_LIMIT) else channels
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = System.currentTimeMillis() } }
    val start = remember(now / S2_HALF_HOUR) { s2GuideStart(now) }
    val pxPerMinute: Dp = tvs(5)
    val rowHeight: Dp = tvs(62)
    val channelWidth: Dp = tvs(130)
    val totalWidth: Dp = pxPerMinute * (S2_GUIDE_HOURS * 60).toFloat()
    val end = start + S2_GUIDE_HOURS * 3_600_000L
    fun x(t: Long): Dp = pxPerMinute * ((t - start) / 60_000f)

    val scroll = rememberScrollState()
    val density = LocalDensity.current
    // bij openen naar "nu" scrollen
    LaunchedEffect(Unit) {
        runCatching {
            snapshotFlow { scroll.maxValue }.first { it > 0 && it != Int.MAX_VALUE }
            val target = with(density) { (x(System.currentTimeMillis()) - tvs(120)).coerceAtLeast(0.dp).roundToPx() }
            scroll.scrollTo(target)
        }
    }
    val epg = Playlists.library.epg
    Column(Modifier.fillMaxSize().background(Color.Black)) {
        // tijdlijn
        Row(Modifier.fillMaxWidth().height(tvs(30))) {
            Spacer(Modifier.width(channelWidth))
            Box(Modifier.weight(1f).fillMaxHeight().horizontalScroll(scroll)) {
                Box(Modifier.width(totalWidth).fillMaxHeight()) {
                    for (i in 0 until S2_GUIDE_HOURS * 2) {
                        val t = start + i * S2_HALF_HOUR
                        val midnight = Calendar.getInstance().apply { timeInMillis = t }.get(Calendar.HOUR_OF_DAY) == 0
                        val label = if (i == 0 || midnight) "${s2DateShort(t)} ${s2Time(t)}" else s2Time(t)
                        Text(label, color = Theme.secondary, fontSize = tsp(11), fontWeight = FontWeight.SemiBold, maxLines = 1,
                            modifier = Modifier.offset(x = x(t) + 4.dp).align(Alignment.CenterStart))
                    }
                    Box(Modifier.offset(x = x(now)).width(2.dp).fillMaxHeight().background(Theme.red))
                }
            }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            itemsIndexed(shown) { _, c ->
                val progs = remember(epg, c.id, start) {
                    (epg[c.epgID ?: c.id] ?: emptyList()).filter { it.end > start && it.start < end }
                }
                Row(Modifier.fillMaxWidth().height(rowHeight)) {
                    S2GuideChannelCell(c, channelWidth, rowHeight) { onPlay(c) }
                    Box(Modifier.weight(1f).fillMaxHeight().horizontalScroll(scroll)) {
                        Box(Modifier.width(totalWidth).fillMaxHeight().background(Color(0xFF101010))) {
                            if (progs.isEmpty()) {
                                Text(L("No guide information"), color = Theme.secondary, fontSize = tsp(11),
                                    modifier = Modifier.offset(x = x(now) + 8.dp).align(Alignment.CenterStart))
                            }
                            progs.forEach { p ->
                                val x0 = maxOf(x(p.start), 0.dp)
                                val x1 = minOf(x(p.end), totalWidth)
                                if (x1 > x0 + 2.dp) {
                                    S2GuideProgramCell(c, p, x0, x1 - x0 - 2.dp, rowHeight - 4.dp) { onProgram(c, p) }
                                }
                            }
                            Box(Modifier.offset(x = x(now)).width(2.dp).fillMaxHeight().background(Theme.red))
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Color.Black))
            }
            if (channels.size > S2_GUIDE_LIMIT) {
                item {
                    Text(L("Showing %d of %d channels. Choose a group or search to see the rest.", S2_GUIDE_LIMIT, channels.size),
                        color = Theme.secondary, fontSize = tsp(12), textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(tvs(16)))
                }
            }
        }
    }
}

@Composable
private fun S2GuideChannelCell(c: Channel, width: Dp, height: Dp, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.width(width).height(height)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.04f, onClick = onClick)
            .background(if (focused) Color.White else Theme.card)
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RemoteImage(c.logo, Modifier.width(tvs(40)).height(tvs(26)), placeholder = c.name.take(3), fit = true)
        Spacer(Modifier.width(8.dp))
        Text(c.name, color = if (focused) Color.Black else Color.White, fontSize = tsp(11), fontWeight = FontWeight.SemiBold,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun S2GuideProgramCell(c: Channel, p: EPGProgram, x: Dp, width: Dp, height: Dp, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val reminder = Store.hasReminder(s2ReminderID(c, p))
    Box(
        Modifier.offset(x = x + 1.dp, y = 2.dp).width(width).height(height)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.03f, onClick = onClick)
            .clip(RoundedCornerShape(4.dp))
            .background(if (focused) Color.White else if (p.isNow) Color(0xFF3A1418) else Theme.elevated)
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Column {
            Text(p.title, color = if (focused) Color.Black else Color.White, fontSize = tsp(12), fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${s2Time(p.start)} – ${s2Time(p.end)}", color = if (focused) Color.DarkGray else Theme.secondary,
                fontSize = tsp(10), maxLines = 1, overflow = TextOverflow.Clip)
        }
        if (reminder) {
            Icon(Icons.Default.Notifications, null, tint = Theme.imdb,
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 4.dp).size(tvs(10)))
        }
    }
}

/** EPG van één zender (incl. terugkijkbereik): kiezen → kijken, terugkijken of herinnering. */
@Composable
fun GuideSheet(channel: Channel, onDismiss: () -> Unit) {
    var programs by remember { mutableStateOf<List<EPGProgram>?>(null) }
    var selected by remember { mutableStateOf<EPGProgram?>(null) }
    LaunchedEffect(channel.id) {
        val all = Playlists.library.epg[channel.epgID ?: channel.id] ?: emptyList()
        val from = System.currentTimeMillis() - maxOf(channel.catchupDays, 0) * 86_400_000L
        programs = if (all.isEmpty()) runCatching { Playlists.shortEPG(channel) }.getOrDefault(emptyList())
        else all.filter { it.end > from }
    }
    S2FullDialog(onDismiss) {
        val list = programs
        val state = rememberLazyListState()
        LaunchedEffect(list) {
            val i = list?.indexOfFirst { it.isNow } ?: -1
            if (i > 0) runCatching { state.scrollToItem((i - 1).coerceAtLeast(0)) }
        }
        S2Page(channel.name, onClose = onDismiss, state = state) {
            if (list == null) {
                item { Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.red) } }
            } else if (list.isEmpty()) {
                item { S2Section { S2Row(L("No guide information"), tint = Theme.secondary) } }
            } else {
                item { Spacer(Modifier.height(8.dp)) }
                itemsIndexed(list) { i, p ->
                    val n = System.currentTimeMillis()
                    Box(Modifier.s2Cell(i, list.size)) {
                        S2Row(
                            title = p.title,
                            subtitle = p.description,
                            onClick = { selected = p },
                            leading = {
                                Column(Modifier.width(tvs(96))) {
                                    Text(s2DateShort(p.start), color = Theme.secondary, fontSize = tsp(11), maxLines = 1)
                                    Text(s2Time(p.start), color = Theme.secondary, fontSize = tsp(12), maxLines = 1)
                                }
                            },
                            trailing = {
                                if (p.isNow) Text(L("NOW"), color = Theme.red, fontSize = tsp(11), fontWeight = FontWeight.Bold)
                                if (p.end < n && channel.catchupDays > 0) {
                                    Icon(Icons.Default.History, null, tint = Theme.secondary, modifier = Modifier.size(tvs(14)))
                                }
                                if (Store.hasReminder(s2ReminderID(channel, p))) {
                                    Icon(Icons.Default.Notifications, null, tint = Theme.imdb, modifier = Modifier.size(tvs(14)))
                                }
                            }
                        )
                    }
                }
            }
        }
    }
    selected?.let { p ->
        S2ProgramSheetImpl(channel, p, onDismiss = { selected = null }, onPlayed = { selected = null; onDismiss() })
    }
}

/** Details van een programma: kijken, terugkijken of herinnering zetten. */
@Composable
fun ProgramSheet(channel: Channel, program: EPGProgram, onDismiss: () -> Unit) {
    S2ProgramSheetImpl(channel, program, onDismiss, onPlayed = onDismiss)
}

@Composable
private fun S2ProgramSheetImpl(channel: Channel, program: EPGProgram, onDismiss: () -> Unit, onPlayed: () -> Unit) {
    val now = System.currentTimeMillis()
    val rid = s2ReminderID(channel, program)
    val canCatchup = program.end < now && channel.catchupDays > 0 &&
        program.start > now - channel.catchupDays * 86_400_000L
    val catchupURL = remember(channel.id, program.start) {
        if (channel.catchupDays > 0) Playlists.catchupURL(channel.id, program.start, program.end) else null
    }
    fun playCatchup(u: String) {
        onPlayed()
        AppState.play(PlayableItem(id = "${channel.id}-cu-${program.start / 1000}", title = program.title,
            subtitle = channel.name, url = u, type = MediaType.LIVE, artwork = channel.logo))
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val tv = AppState.isTV
        Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))
                .pointerInput(Unit) { detectTapGestures { onDismiss() } },
            contentAlignment = if (tv) Alignment.Center else Alignment.BottomCenter
        ) {
            val first = remember { FocusRequester() }
            Column(
                Modifier.widthIn(max = 760.dp).fillMaxWidth()
                    .clip(if (tv) RoundedCornerShape(16.dp) else RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                    .background(S2SheetBg)
                    .pointerInput(Unit) { detectTapGestures { } }
                    .verticalScroll(rememberScrollState())
                    .padding(Theme.edge)
                    .padding(bottom = if (tv) 0.dp else 24.dp),
                verticalArrangement = Arrangement.spacedBy(tvs(12))
            ) {
                Text(channel.name, color = Theme.secondary, fontSize = tsp(13), fontWeight = FontWeight.SemiBold)
                Text(program.title, color = Color.White, fontSize = tsp(24), fontWeight = FontWeight.Bold)
                Text("${s2DateTime(program.start)} – ${s2Time(program.end)}", color = Theme.secondary, fontSize = tsp(14))
                program.description?.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = Color.White.copy(alpha = 0.85f), fontSize = tsp(14))
                }
                Spacer(Modifier.height(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(tvs(14)), verticalAlignment = Alignment.CenterVertically) {
                    var hasFirst = false
                    fun firstMod(): Modifier = if (!hasFirst) { hasFirst = true; Modifier.focusRequester(first) } else Modifier
                    if (program.isNow) {
                        NetflixButton(L("Watch live"), Icons.Default.PlayArrow, modifier = firstMod()) {
                            onPlayed()
                            AppState.play(Playables.channel(channel, program), zap = Playlists.library.channels)
                        }
                    } else if (canCatchup && catchupURL != null) {
                        NetflixButton(L("Watch from the start"), Icons.Default.History, modifier = firstMod()) { playCatchup(catchupURL) }
                    } else if (program.start > now) {
                        val on = Store.hasReminder(rid)
                        NetflixButton(if (on) L("Reminder set") else L("Remind me"),
                            if (on) Icons.Default.NotificationsOff else Icons.Default.Notifications,
                            kind = if (on) NetflixKind.SECONDARY else NetflixKind.PRIMARY, modifier = firstMod()) {
                            if (on) Reminders.remove(rid)
                            else Playlists.source?.id?.let { pid -> Reminders.add(channel, program, pid) }
                        }
                    }
                    if (program.isNow && channel.catchupDays > 0 && catchupURL != null) {
                        NetflixButton(L("From the start"), Icons.Default.SkipPrevious, kind = NetflixKind.SECONDARY,
                            modifier = firstMod()) { playCatchup(catchupURL) }
                    }
                }
            }
            LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
        }
    }
}
