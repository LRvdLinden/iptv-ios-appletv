package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Verified
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

private val sheetBG = Color(0xFF141414)

// MARK: - Bouwstenen voor de spelerpanelen ------------------------------------------------

/** Paneel boven de speler (dialoog met titel, "Klaar"-knop en een lijst). Werkt met tik en D-pad. */
@Composable
fun PlayerSheet(
    title: String,
    onDismiss: () -> Unit,
    doneLabel: String = L("Done"),
    content: LazyListScope.() -> Unit,
) {
    val cfg = LocalConfiguration.current
    val done = remember { FocusRequester() }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .widthIn(max = if (AppState.isTV) 640.dp else 560.dp)
                .fillMaxWidth(if (AppState.isTV) 0.5f else 0.94f)
                .heightIn(max = (cfg.screenHeightDp * 0.86f).dp)
                .clip(RoundedCornerShape(14.dp))
                .background(sheetBG)
        ) {
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 8.dp, top = 10.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = tsp(18), modifier = Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                PlayerFocusText(doneLabel, Modifier.focusRequester(done), bold = true, color = Theme.red, onClick = onDismiss)
            }
            LazyColumn(Modifier.fillMaxWidth().padding(bottom = 12.dp), content = content)
        }
    }
    LaunchedEffect(Unit) {
        if (AppState.isTV) { delay(120); runCatching { done.requestFocus() } }
    }
}

/** Kleine klikbare tekst (bijv. "Klaar") met focusrand op TV. */
@Composable
fun PlayerFocusText(text: String, modifier: Modifier = Modifier, bold: Boolean = false, color: Color = Color.White, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Text(
        text, color = if (focused) Color.Black else color,
        fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal, fontSize = tsp(15),
        modifier = modifier
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.05f, onClick = onClick)
            .clip(RoundedCornerShape(6.dp))
            .background(if (focused) Color.White else Color.Transparent)
            .padding(horizontal = 12.dp, vertical = 8.dp)
    )
}

/** Een regel in een paneel; op TV licht de regel op bij focus. */
@Composable
fun PlayerSheetItem(enabled: Boolean = true, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 1.dp)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.02f) { if (enabled) onClick() }
            .clip(RoundedCornerShape(8.dp))
            .background(if (focused) Color.White.copy(alpha = 0.16f) else Color.Transparent)
            .padding(horizontal = 12.dp, vertical = if (AppState.isTV) 12.dp else 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        content = content
    )
}

@Composable
fun PlayerSheetRow(
    text: String,
    selected: Boolean = false,
    enabled: Boolean = true,
    destructive: Boolean = false,
    icon: ImageVector? = null,
    onClick: () -> Unit,
) {
    PlayerSheetItem(enabled = enabled, onClick = onClick) {
        if (icon != null) Icon(icon, null, tint = Color.White, modifier = Modifier.size(tvs(20)))
        Text(text, color = if (destructive) Theme.red else if (enabled) Color.White else Theme.secondary,
            fontSize = tsp(15), modifier = Modifier.weight(1f), maxLines = 3, overflow = TextOverflow.Ellipsis)
        if (selected) Icon(Icons.Filled.Check, null, tint = Theme.red, modifier = Modifier.size(tvs(20)))
    }
}

@Composable
fun PlayerSheetHeader(text: String) {
    Text(text.uppercase(Localizer.locale), color = Theme.secondary, fontSize = tsp(12), fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 6.dp))
}

@Composable
fun PlayerSheetNote(text: String) {
    Text(text, color = Theme.secondary, fontSize = tsp(12), modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp))
}

// MARK: - Audio & ondertitels ---------------------------------------------------------------

/** Spoornaam met vlag als de taal herkend wordt. */
fun flaggedTrackName(t: MediaTrack): String {
    val l = t.lang
    if (!l.isNullOrEmpty()) return "${TrackPreferences.flag(l)} ${t.name}"
    val code = TrackPreferences.languages.map { it.first }.firstOrNull { TrackPreferences.matches(t, it) }
    return if (code != null) "${TrackPreferences.flag(code)} ${t.name}" else t.name
}

/** Audio- en ondertitelsporen die in de stream zitten. */
@Composable
fun TracksPanel(player: PlayerController, onDismiss: () -> Unit) {
    val audio = player.audioTracks
    val subs = player.subtitleTracks
    val curAudio = player.currentAudio
    val curSub = player.currentSubtitle
    val ext = player.externalSubtitleName
    val offset = player.subtitleDelay
    PlayerSheet(L("Audio & subtitles"), onDismiss) {
        item { PlayerSheetHeader(L("Audio")) }
        if (audio.isEmpty()) item { PlayerSheetNote(L("No alternative audio tracks")) }
        for (t in audio) item { PlayerSheetRow(flaggedTrackName(t), selected = t.id == curAudio) { player.selectAudio(t) } }

        item { PlayerSheetHeader(L("Subtitles")) }
        item { PlayerSheetRow(L("Off"), selected = curSub == null) { player.selectSubtitle(null) } }
        if (ext != null && player.hasExternalSubtitle) item { PlayerSheetRow("OpenSubtitles · $ext", selected = true) {} }
        for (t in subs) item { PlayerSheetRow(flaggedTrackName(t), selected = t.id == curSub) { player.selectSubtitle(t) } }

        item { PlayerSheetHeader(L("Subtitle timing")) }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    PlayerSheetItem(onClick = { player.subtitleDelay = offset - 0.5 }) {
                        Icon(Icons.Filled.RemoveCircle, null, tint = Color.White, modifier = Modifier.size(tvs(26)))
                    }
                }
                Text(
                    if (offset == 0.0) L("In sync") else String.format(Locale.ROOT, "%+.1f s", offset),
                    color = Color.White, fontSize = tsp(17), fontFamily = FontFamily.Monospace,
                    textAlign = TextAlign.Center, modifier = Modifier.weight(1.4f)
                )
                Box(Modifier.weight(1f)) {
                    PlayerSheetItem(onClick = { player.subtitleDelay = offset + 0.5 }) {
                        Spacer(Modifier.weight(1f))
                        Icon(Icons.Filled.AddCircle, null, tint = Color.White, modifier = Modifier.size(tvs(26)))
                    }
                }
            }
        }
        if (offset != 0.0) item { PlayerSheetRow(L("Reset")) { player.subtitleDelay = 0.0 } }
        item { PlayerSheetNote(L("Subtitles too early or too late? Shift them in steps of half a second.")) }
    }
}

// MARK: - OpenSubtitles ---------------------------------------------------------------------

/**
 * Ondertitels zoeken en inladen via OpenSubtitles (op IMDb-ID of titel, met seizoen/aflevering).
 * Taal kies je hier per keer; de standaardtaal stel je in onder Mijn Bingr → OpenSubtitles.
 */
@Composable
fun OpenSubtitlesPanel(player: PlayerController, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var results by remember { mutableStateOf(listOf<OpenSubtitles.Subtitle>()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var downloading by remember { mutableStateOf<Int?>(null) }
    var language by remember { mutableStateOf(OpenSubtitles.defaultLanguage) }
    var menuOpen by remember { mutableStateOf(false) }
    var userVersion by remember { mutableIntStateOf(0) }
    val checkIcon: @Composable () -> Unit = { Icon(Icons.Filled.Check, null, tint = Theme.red) }
    val signInHint = L("Sign in to OpenSubtitles under My Bingr → OpenSubtitles to download subtitles.")

    LaunchedEffect(Unit) { runCatching { OpenSubtitles.refreshUser() }; userVersion++ }
    LaunchedEffect(language) {
        loading = true; error = null; results = emptyList()
        val it = player.item
        try {
            results = OpenSubtitles.search(
                imdbID = it.imdbID, title = it.title, year = it.subtitle?.toIntOrNull(),
                season = it.season, episode = it.episode,
                languages = if (language.isEmpty()) emptyList() else listOf(language)
            )
            if (results.isEmpty()) {
                error = if (language.isEmpty()) L("No subtitles found for this title.")
                else L("No subtitles found in %@.", TrackPreferences.name(language))
            }
        } catch (e: Exception) {
            error = e.message ?: e.toString()
        }
        loading = false
    }

    fun load(s: OpenSubtitles.Subtitle) {
        if (!OpenSubtitles.isLoggedIn) { error = signInHint; return }
        if (downloading != null) return
        downloading = s.id
        scope.launch {
            try {
                val file = OpenSubtitles.download(s)
                player.addSubtitle(file, "${TrackPreferences.flag(s.language)} ${s.release}")
                onDismiss()
            } catch (e: Exception) {
                error = e.message ?: e.toString()
            }
            downloading = null
        }
    }

    PlayerSheet("OpenSubtitles", onDismiss, doneLabel = L("Close")) {
        item {
            Box {
                PlayerSheetItem(onClick = { menuOpen = true }) {
                    Text(L("Language"), color = Color.White, fontSize = tsp(15), modifier = Modifier.weight(1f))
                    Text(if (language.isEmpty()) "🌐 ${L("All languages")}" else TrackPreferences.label(language),
                        color = Theme.secondary, fontSize = tsp(15))
                    Icon(Icons.Filled.ArrowDropDown, null, tint = Theme.secondary)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("🌐 ${L("All languages")}") },
                        trailingIcon = if (language.isEmpty()) checkIcon else null,
                        onClick = { language = ""; menuOpen = false }
                    )
                    for (code in TrackPreferences.sortedCodes) {
                        DropdownMenuItem(
                            text = { Text(TrackPreferences.label(code)) },
                            trailingIcon = if (language == code) checkIcon else null,
                            onClick = { language = code; menuOpen = false }
                        )
                    }
                }
            }
        }
        item {
            userVersion
            if (!OpenSubtitles.isLoggedIn) {
                PlayerSheetHeader(L("Sign in to OpenSubtitles to download"))
                PlayerSheetNote(signInHint)
            } else {
                OpenSubtitles.remainingDownloads?.let { r ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
                        Text(L("Downloads left today"), color = Color.White, fontSize = tsp(15), modifier = Modifier.weight(1f))
                        Text("$r", color = Theme.secondary, fontSize = tsp(15))
                    }
                }
            }
        }
        if (loading) item {
            Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(28.dp), strokeWidth = 2.5.dp)
            }
        }
        error?.let { e -> item { PlayerSheetNote(e) } }
        for (s in results) {
            item(key = s.id) {
                PlayerSheetItem(enabled = downloading == null, onClick = { load(s) }) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(min = tvs(34))) {
                        Text(TrackPreferences.flag(s.language), fontSize = tsp(24))
                        Text(s.language.uppercase(Locale.ROOT), color = Theme.secondary, fontSize = tsp(9), fontWeight = FontWeight.Bold)
                    }
                    Column(Modifier.weight(1f)) {
                        Text(s.release, color = Color.White, fontSize = tsp(14), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.Download, null, tint = Theme.secondary, modifier = Modifier.size(tvs(14)))
                            Text("${s.downloads}", color = Theme.secondary, fontSize = tsp(12))
                            if (s.hearingImpaired) Icon(Icons.Filled.Hearing, null, tint = Theme.secondary, modifier = Modifier.size(tvs(14)))
                            if (s.fromTrusted) Icon(Icons.Filled.Verified, null, tint = Theme.green, modifier = Modifier.size(tvs(14)))
                        }
                    }
                    if (downloading == s.id) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
        }
    }
}

// MARK: - Opties ------------------------------------------------------------------------------

/** Snelheid, beeld, engine en slaaptimer. */
@Composable
fun OptionsPanel(player: PlayerController, onDismiss: () -> Unit) {
    PlayerSheet(L("Options"), onDismiss) {
        if (!player.isLive) {
            item { PlayerSheetHeader(L("Speed")) }
            for (r in listOf(0.75f, 1f, 1.25f, 1.5f, 2f)) {
                item {
                    val label = if (r == 1f) L("Normal") else "${if (r == r.toInt().toFloat()) r.toInt().toString() else r.toString()}×"
                    PlayerSheetRow(label, selected = player.rate == r) { player.rate = r }
                }
            }
        }
        item { PlayerSheetHeader(L("Picture")) }
        for (a in PlayerController.Aspect.entries) {
            item { PlayerSheetRow(a.title, selected = player.aspect == a) { player.aspect = a } }
        }
        item { PlayerSheetHeader(L("Player engine")) }
        item { PlayerSheetNote(if (player.usingExo) L("Now playing with: ExoPlayer") else L("Now playing with: VLC")) }
        val u = player.url
        if (!player.usingExo && u != null && PlayerController.canUseExo(u)) {
            item { PlayerSheetRow(L("Try ExoPlayer (HDR, Dolby Vision)")) { player.switchToExo(); onDismiss() } }
        }
        if (player.usingExo) {
            item { PlayerSheetRow(L("Try VLC (all formats)")) { player.switchToVLC(); onDismiss() } }
        }
        item { PlayerSheetHeader(L("Sleep timer")) }
        for (m in listOf(0, 15, 30, 45, 60, 90)) {
            item {
                PlayerSheetRow(if (m == 0) L("Off") else L("In %d minutes", m), selected = m == 0 && player.sleepAt == null) {
                    player.sleepAt = if (m == 0) null else System.currentTimeMillis() + m * 60_000L
                }
            }
        }
    }
}

// MARK: - Stremio-bronnen ---------------------------------------------------------------------

/** Stremio: kies een andere bron als de eerste niet werkt. */
@Composable
fun StremioSourcesPanel(streams: List<StremioStream>, current: String?, onPick: (StremioStream) -> Unit, onDismiss: () -> Unit) {
    PlayerSheet(L("Sources"), onDismiss, doneLabel = L("Close")) {
        for (s in streams) {
            item {
                PlayerSheetItem(onClick = { onPick(s) }) {
                    Column(Modifier.weight(1f)) {
                        Text(s.title, color = Color.White, fontSize = tsp(14), maxLines = 3, overflow = TextOverflow.Ellipsis)
                        Text(s.addon, color = Theme.secondary, fontSize = tsp(12))
                    }
                    if (s.url == current) Icon(Icons.Filled.Check, null, tint = Theme.red, modifier = Modifier.size(tvs(20)))
                }
            }
        }
    }
}

// MARK: - Beoordelen --------------------------------------------------------------------------

/** Na afloop: waardering (1–10) naar Trakt. */
@Composable
fun RatingPanel(item: PlayableItem, onDone: () -> Unit) {
    var rating by remember { mutableIntStateOf(0) }
    val first = remember { FocusRequester() }
    Dialog(onDismissRequest = onDone, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth(0.94f)
                .clip(RoundedCornerShape(16.dp))
                .background(sheetBG)
                .padding(Theme.edge),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tvs(16))
        ) {
            Text(L("What did you think?"), color = Color.White, fontSize = tsp(22), fontWeight = FontWeight.Bold)
            Text(item.title + (item.subtitle?.let { " · $it" } ?: ""), color = Theme.secondary, maxLines = 2,
                textAlign = TextAlign.Center, fontSize = tsp(14))
            Row(horizontalArrangement = Arrangement.spacedBy(tvs(4))) {
                for (n in 1..10) {
                    Icon(
                        if (n <= rating) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null,
                        tint = if (n <= rating) Theme.red else Theme.secondary,
                        modifier = Modifier
                            .then(if (n == 1) Modifier.focusRequester(first) else Modifier)
                            .focusLift(1.25f) { rating = n }
                            .padding(3.dp)
                            .size(tvs(24))
                    )
                }
            }
            if (rating > 0) Text("$rating/10", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = tsp(16))
            Row(horizontalArrangement = Arrangement.spacedBy(tvs(14))) {
                NetflixButton(L("Skip"), Icons.Filled.Close, NetflixKind.SECONDARY) { onDone() }
                NetflixButton(L("Rate on Trakt"), Icons.Filled.Check, NetflixKind.ACCENT) {
                    if (rating == 0) return@NetflixButton
                    val r = rating
                    AppScope.launch { runCatching { Trakt.rate(item, r) } }
                    onDone()
                }
            }
        }
    }
    LaunchedEffect(Unit) { if (AppState.isTV) { delay(150); runCatching { first.requestFocus() } } }
}
