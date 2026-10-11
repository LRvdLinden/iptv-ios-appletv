package nl.lrvdlinden.bingr

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date

private fun s2HistoryDayTitle(day: Long): String {
    val today = s2StartOfDay(System.currentTimeMillis())
    val yesterday = s2StartOfDay(today - 12 * 3_600_000L)
    return when (day) {
        today -> L("Today")
        yesterday -> L("Yesterday")
        else -> SimpleDateFormat("EEEE d MMMM", Localizer.locale).format(Date(day))
    }
}

/** Kijkgeschiedenis van het huidige profiel: films, afleveringen en zenders, per dag. */
@Composable
fun HistoryScreen(onClose: () -> Unit) {
    var detail by remember { mutableStateOf<DetailTarget?>(null) }
    var menuFor by remember { mutableStateOf<HistoryEntry?>(null) }
    var confirmClear by remember { mutableStateOf(false) }

    val shownDetail = detail
    if (shownDetail != null) {
        DetailScreen(shownDetail, { detail = null })
        return
    }

    val pid = Playlists.source?.id
    val entries = Store.history.filter { it.playlistID == pid }
    val days = entries.groupBy { s2StartOfDay(it.date) }.entries.sortedByDescending { it.key }
        .map { en -> en.key to en.value.sortedByDescending { it.date } }

    fun open(e: HistoryEntry) {
        val lib = Playlists.library
        val ch = if (e.type == MediaType.LIVE) lib.channels.firstOrNull { it.id == (e.channelID ?: e.itemID) } else null
        if (ch != null) {
            AppState.play(Playables.channel(ch, lib.nowPlaying(ch)), zap = lib.channels)
            return
        }
        val m = lib.movies.firstOrNull { it.id == e.itemID }
        if (m != null) { detail = DetailTarget.MovieT(m); return }
        val s = lib.series.firstOrNull { s -> s.id == e.itemID || s.episodes.any { it.id == e.itemID } }
            ?: lib.series.firstOrNull { it.title == e.title }
        if (s != null) detail = DetailTarget.SeriesT(s)
    }

    S2Page(L("Watch history"), onClose = onClose) {
        if (entries.isEmpty()) {
            item { S2Section { S2Row(L("Nothing watched yet on this profile."), tint = Theme.secondary) } }
        }
        days.forEach { (day, list) ->
            item { S2Header(s2HistoryDayTitle(day)) }
            itemsIndexed(list) { i, e ->
                Column(Modifier.s2Cell(i, list.size)) {
                    val live = e.type == MediaType.LIVE
                    S2Row(
                        title = e.title,
                        subtitle = e.subtitle,
                        onLongClick = { menuFor = e },
                        onClick = { open(e) },
                        leading = {
                            RemoteImage(e.artwork,
                                Modifier.width(tvs(if (live) 56 else 40)).height(tvs(if (live) 36 else 60)).clip(RoundedCornerShape(4.dp)),
                                placeholder = e.title.take(2), fit = live)
                        },
                        trailing = {
                            Column(horizontalAlignment = Alignment.End) {
                                Icon(when (e.type) {
                                    MediaType.LIVE -> Icons.Default.LiveTv
                                    MediaType.MOVIE -> Icons.Default.Movie
                                    else -> Icons.Default.VideoLibrary
                                }, null, tint = Theme.secondary, modifier = Modifier.size(tvs(16)))
                                Text(s2Time(e.date), color = Theme.secondary, fontSize = tsp(11))
                            }
                            S2MoreButton { menuFor = e }
                        }
                    )
                }
            }
        }
        if (entries.isNotEmpty()) {
            item { S2Section { S2Row(L("Clear watch history"), tint = Theme.red, onClick = { confirmClear = true }) } }
        }
    }

    menuFor?.let { e ->
        S2ActionDialog(e.title, listOf(
            S2Action(L("Remove from history"), Icons.Default.Delete, destructive = true) { Store.removeHistory(e) }
        ), onDismiss = { menuFor = null })
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            containerColor = Theme.elevated,
            title = { Text(L("Clear watch history"), color = Color.White) },
            confirmButton = {
                TextButton(onClick = { confirmClear = false; Store.clearHistory(pid) }) { Text(L("Clear watch history"), color = Theme.red) }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(L("Cancel"), color = Color.White) } }
        )
    }
}
