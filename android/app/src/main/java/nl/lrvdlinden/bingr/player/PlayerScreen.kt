package nl.lrvdlinden.bingr

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.CastConnected
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private enum class PlayerPanel { AUDIO_SUBS, OPENSUBS, OPTIONS, CAST, SOURCES, RATE }

/** Zender → afspeelbaar item (zoals Playables.channel op iOS). */
private fun livePlayable(c: Channel): PlayableItem = PlayableItem(
    id = c.id, title = c.name, subtitle = Playlists.library.nowPlaying(c)?.title, url = c.streamURL,
    type = MediaType.LIVE, artwork = c.logo, stalkerCmd = c.stalkerCmd, channelID = c.id
)

/**
 * Volledige speler: video, eigen bediening (tik/D-pad), timeline, ±10 s, zappen bij live,
 * timeshift/catch-up, panelen voor audio/ondertitels/OpenSubtitles/opties/bronnen, Chromecast en beeld-in-beeld.
 */
@Composable
fun PlayerScreen(item: PlayableItem, onClose: () -> Unit) {
    val player = remember(item.id) { PlayerController(item) }
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val isTV = AppState.isTV
    val inPiP = AppState.inPiP

    var showControls by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf<PlayerPanel?>(null) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    var toastID by remember { mutableIntStateOf(0) }
    var pokeID by remember { mutableIntStateOf(0) }
    var stremioChoices by remember { mutableStateOf(listOf<StremioStream>()) }
    val rootFocus = remember { FocusRequester() }
    val firstButton = remember { FocusRequester() }
    val swallowUp = remember { mutableSetOf<Int>() }
    val castAvailable = remember { Casting.isAvailable(ctx) }

    fun flash(text: String) { toast = text; toastID++ }
    fun poke() { showControls = true; pokeID++ }
    fun toggleControls() { showControls = !showControls; if (showControls) poke() }
    fun close() { player.stop(); onClose() }

    fun bind() {
        player.onFinished = {
            val cur = player.item
            if (Trakt.askRating && Trakt.isLoggedIn && cur.imdbID != null && cur.type != MediaType.LIVE) panel = PlayerPanel.RATE
            else close()
        }
    }

    /** Standaard ondertitels: eerst een spoor in de stream in je standaardtaal, anders de beste van OpenSubtitles. */
    suspend fun autoLoadSubtitles(itm: PlayableItem) {
        val lang = OpenSubtitles.defaultLanguage
        if (lang.isEmpty()) return
        for (i in 0 until 40) { if (player.isPlaying) break; delay(500) }
        delay(2500)   // sporen laten binnenkomen
        if (player.item.id != itm.id || player.hasExternalSubtitle || player.isStopped) return
        val t = player.subtitleTracks.firstOrNull { tr -> TrackPreferences.matches(tr, lang) }
        if (t != null) {
            player.selectSubtitle(t)
            flash(L("Subtitles: %@", TrackPreferences.label(lang)))
            return
        }
        if (!OpenSubtitles.isLoggedIn) return
        try {
            val found = OpenSubtitles.search(
                imdbID = itm.imdbID, title = itm.title, year = itm.subtitle?.toIntOrNull(),
                season = itm.season, episode = itm.episode, languages = listOf(lang)
            )
            val best = found.firstOrNull() ?: return
            if (player.item.id != itm.id || player.isStopped) return
            val file = OpenSubtitles.download(best)
            player.addSubtitle(file, "${TrackPreferences.flag(best.language)} ${best.release}")
            flash(L("Subtitles: %@", "${TrackPreferences.label(lang)} · OpenSubtitles"))
        } catch (e: Exception) {}
    }

    suspend fun start(itm: PlayableItem) {
        player.item = itm
        PlayerController.current = player
        bind()
        val cid = itm.channelID
        player.catchupProvider =
            if (itm.type == MediaType.LIVE && cid != null) ({ from: Long, to: Long -> Playlists.catchupURL(cid, from, to) }) else null
        if (itm.stremio != null) {
            stremioChoices = runCatching { Playlists.stremioStreams(itm) }.getOrDefault(emptyList())
            val first = stremioChoices.firstOrNull()
            if (first == null) { flash(L("No playable streams found for this title.")); return }
            player.start(first.url)
        } else {
            val url = runCatching { Playlists.resolve(itm) }.getOrNull()
            if (url == null) { flash(L("No stream address available.")); return }
            player.liveURL = url
            player.start(url)
        }
        poke()
        if (Prefs.bool("autoSubtitles") && itm.type != MediaType.LIVE) scope.launch { autoLoadSubtitles(itm) }
    }

    fun zap(step: Int) {
        val list = AppState.liveZapList
        if (!player.isLive || list.isEmpty()) return
        val cur = player.item.channelID ?: player.item.id
        val i = list.indexOfFirst { it.id == cur }
        if (i < 0) return
        val next = list[((i + step) % list.size + list.size) % list.size]
        Playlists.source?.id?.let { Store.pushRecentChannel(it, next.id) }
        val nextItem = livePlayable(next)
        flash("${next.number?.let { n -> "$n  " } ?: ""}${next.name}")
        scope.launch { player.stop(); start(nextItem) }
    }

    fun openMultiview() {
        val current = Playlists.library.channels.firstOrNull { it.id == player.item.channelID }
        val zapList = AppState.liveZapList
        close()
        AppScope.launch {
            delay(400)
            AppState.openMultiview(listOfNotNull(current), zapList)
        }
    }

    fun seekBy(s: Double) {
        if (player.isLive && !player.canTimeshift) return
        player.seek(s)
        flash(if (s < 0) "−${(-s).toInt()} s" else "+${s.toInt()} s")
    }

    // MARK: levenscyclus

    LaunchedEffect(player) {
        Casting.init(ctx)
        start(item)
    }
    DisposableEffect(player) {
        val obs = LifecycleEventObserver { _, e ->
            // app naar de achtergrond zonder beeld-in-beeld (bijv. TV-thuisknop): pauzeren
            if (e == Lifecycle.Event.ON_STOP && !AppState.inPiP && player.isPlaying) player.pause()
        }
        val lc = ProcessLifecycleOwner.get().lifecycle
        lc.addObserver(obs)
        onDispose {
            lc.removeObserver(obs)
            player.stop()
            if (PlayerController.current === player) PlayerController.current = null
            MainActivity.current?.keepScreenOn(false)
        }
    }
    LaunchedEffect(player.isPlaying) { MainActivity.current?.keepScreenOn(player.isPlaying) }
    LaunchedEffect(pokeID, panel, player.isPlaying, showControls) {
        if (showControls) {
            delay(5000)
            if (panel == null && player.isPlaying && scrubbing == null) showControls = false
        }
    }
    LaunchedEffect(toastID) {
        if (toast != null) { delay(1800); toast = null }
    }
    LaunchedEffect(player.notice) {
        player.notice?.let { flash(it); player.notice = null }
    }
    LaunchedEffect(showControls, panel, inPiP) {
        if (panel != null || inPiP) return@LaunchedEffect
        delay(60)
        runCatching { if (isTV && showControls) firstButton.requestFocus() else rootFocus.requestFocus() }
    }

    BackHandler {
        when {
            panel != null -> panel = null
            isTV && showControls -> showControls = false
            else -> close()
        }
    }

    // MARK: afstandsbediening

    fun handleKey(code: Int, down: Boolean, repeat: Int): Boolean {
        if (!down) return swallowUp.remove(code)
        if (panel != null) return false
        var handled = true
        when (code) {
            AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { player.togglePlay(); poke() }
            AndroidKeyEvent.KEYCODE_MEDIA_PLAY -> { player.resume(); poke() }
            AndroidKeyEvent.KEYCODE_MEDIA_PAUSE -> { player.pause(); poke() }
            AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> seekBy(10.0)
            AndroidKeyEvent.KEYCODE_MEDIA_REWIND -> seekBy(-10.0)
            AndroidKeyEvent.KEYCODE_CHANNEL_UP -> zap(-1)
            AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> zap(1)
            else -> handled = false
        }
        if (handled) { swallowUp += code; return true }
        if (showControls) { poke(); return false }
        when (code) {
            AndroidKeyEvent.KEYCODE_DPAD_LEFT -> seekBy(-10.0)
            AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> seekBy(10.0)
            AndroidKeyEvent.KEYCODE_DPAD_UP -> if (repeat == 0) { if (player.isLive) zap(-1) else poke() }
            AndroidKeyEvent.KEYCODE_DPAD_DOWN -> if (repeat == 0) { if (player.isLive) zap(1) else poke() }
            AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER, AndroidKeyEvent.KEYCODE_NUMPAD_ENTER -> poke()
            else -> return false
        }
        swallowUp += code
        return true
    }

    // MARK: opbouw

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPreviewKeyEvent { ev ->
                val down = ev.type == KeyEventType.KeyDown
                if (!down && ev.type != KeyEventType.KeyUp) return@onPreviewKeyEvent false
                handleKey(ev.nativeKeyEvent.keyCode, down, ev.nativeKeyEvent.repeatCount)
            }
            .focusRequester(rootFocus)
            .focusable()
    ) {
        EngineView(player, Modifier.fillMaxSize())

        if (!inPiP && !isTV) {
            Box(
                Modifier.fillMaxSize().pointerInput(player) {
                    detectTapGestures(
                        onTap = { toggleControls() },
                        onDoubleTap = { off ->
                            val w = size.width
                            when {
                                off.x < w * 0.35f -> { seekBy(-10.0); poke() }
                                off.x > w * 0.65f -> { seekBy(10.0); poke() }
                                else -> toggleControls()
                            }
                        }
                    )
                }
            )
        }

        player.subtitleText?.let { s ->
            Box(
                Modifier.fillMaxSize().padding(
                    start = 24.dp, end = 24.dp,
                    bottom = if (inPiP) 8.dp else if (showControls) tvs(120) else tvs(40)
                ),
                contentAlignment = Alignment.BottomCenter
            ) {
                Text(
                    s, color = Color.White, fontSize = if (inPiP) tsp(11) else tsp(20), fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 10.dp, vertical = 4.dp)
                )
            }
        }

        if (!inPiP) {
            if ((player.isBuffering || player.reconnecting) && player.errorText == null) {
                Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(tvs(48)), strokeWidth = 3.dp)
                    if (player.reconnecting) {
                        Spacer(Modifier.height(10.dp))
                        Text(L("Reconnecting…"), color = Theme.secondary, fontSize = tsp(13))
                    }
                }
            }
            player.errorText?.let { e ->
                Column(Modifier.align(Alignment.Center).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Filled.Warning, null, tint = Theme.red, modifier = Modifier.size(tvs(40)))
                    Text(e, color = Color.White, fontSize = tsp(16), textAlign = TextAlign.Center)
                    NetflixButton(L("Try again"), Icons.Filled.Refresh) { scope.launch { start(player.item) } }
                }
            }
            if (Casting.connected) {
                Box(Modifier.align(Alignment.Center)) { CastingOverlay { player.resume() } }
            }

            AnimatedVisibility(showControls, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
                PlayerControls(
                    player = player,
                    isTV = isTV,
                    castAvailable = castAvailable,
                    firstButton = firstButton,
                    scrubbing = scrubbing,
                    hasSources = stremioChoices.isNotEmpty(),
                    onScrub = { scrubbing = it; poke() },
                    onScrubEnd = { scrubbing?.let { player.seekTo(it.toDouble()) }; scrubbing = null; poke() },
                    onClose = { close() },
                    onPoke = { poke() },
                    onSeek = { seekBy(it) },
                    onZap = { zap(it) },
                    onPanel = { panel = it },
                    onMultiview = { openMultiview() },
                )
            }

            AnimatedVisibility(
                toast != null, enter = fadeIn() + slideInVertically { -it }, exit = fadeOut() + slideOutVertically { -it },
                modifier = Modifier.align(Alignment.TopCenter).padding(top = tvs(40))
            ) {
                Text(
                    toast ?: "", color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.75f))
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                )
            }
        }
    }

    // MARK: panelen

    when (panel) {
        PlayerPanel.AUDIO_SUBS -> TracksPanel(player) { panel = null }
        PlayerPanel.OPENSUBS -> OpenSubtitlesPanel(player) { panel = null }
        PlayerPanel.OPTIONS -> OptionsPanel(player) { panel = null }
        PlayerPanel.CAST -> CastDevicesDialog { panel = null }
        PlayerPanel.SOURCES -> StremioSourcesPanel(stremioChoices, player.url, onPick = { s ->
            panel = null
            player.start(s.url)
        }, onDismiss = { panel = null })
        PlayerPanel.RATE -> RatingPanel(player.item) { panel = null; close() }
        null -> {}
    }
}

// MARK: - Bediening ---------------------------------------------------------------------------

@Composable
private fun PlayerControls(
    player: PlayerController,
    isTV: Boolean,
    castAvailable: Boolean,
    firstButton: FocusRequester,
    scrubbing: Float?,
    hasSources: Boolean,
    onScrub: (Float) -> Unit,
    onScrubEnd: () -> Unit,
    onClose: () -> Unit,
    onPoke: () -> Unit,
    onSeek: (Double) -> Unit,
    onZap: (Int) -> Unit,
    onPanel: (PlayerPanel) -> Unit,
    onMultiview: () -> Unit,
) {
    val live = player.isLive
    val canSeek = !live || player.canTimeshift
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.75f), 0.3f to Color.Transparent,
                    0.6f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f)
                )
            )
        )
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            // bovenbalk
            Row(
                Modifier.fillMaxWidth().padding(start = Theme.edge, end = Theme.edge, top = tvs(12)),
                verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                if (!isTV) PlayerRoundIcon(Icons.Filled.Close, L("Close"), 24) { onClose() }
                Column(Modifier.weight(1f).padding(top = if (isTV) 0.dp else 8.dp)) {
                    Text(player.item.title, color = Color.White, fontSize = tsp(17), fontWeight = FontWeight.Bold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    player.item.subtitle?.let {
                        Text(it, color = Theme.secondary, fontSize = tsp(13), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (!isTV) {
                    if (castAvailable) {
                        PlayerRoundIcon(if (Casting.connected) Icons.Filled.CastConnected else Icons.Filled.Cast, "Chromecast", 22) {
                            onPanel(PlayerPanel.CAST)
                        }
                    }
                    if (PlayerController.pipSupported) {
                        PlayerRoundIcon(Icons.Filled.PictureInPictureAlt, L("Picture in Picture"), 22) { player.startPiP() }
                    }
                }
                if (live) {
                    val behind = player.behindLive > 5
                    var focused by remember { mutableStateOf(false) }
                    Row(
                        Modifier
                            .padding(top = if (isTV) 0.dp else 8.dp)
                            .onFocusChanged { focused = it.isFocused }
                            .focusLift(1.08f) { player.goLive(); onPoke() }
                            .clip(CircleShape)
                            .background(if (focused) Color.White else if (behind) Theme.elevated else Theme.red)
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        val fg = if (focused) Color.Black else Color.White
                        Icon(Icons.Filled.Sensors, null, tint = fg, modifier = Modifier.size(tvs(14)))
                        Spacer(Modifier.width(5.dp))
                        Text(if (behind) "−${PlayerController.format(player.behindLive)}" else "LIVE",
                            color = fg, fontSize = tsp(12), fontWeight = FontWeight.Black)
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // midden (telefoon)
            if (!isTV) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(56.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (live && !player.canTimeshift) PlayerRoundIcon(Icons.Filled.KeyboardArrowUp, L("Previous channel"), 34) { onZap(-1) }
                    else PlayerRoundIcon(Icons.Filled.Replay10, "−10", 36) { onSeek(-10.0); onPoke() }
                    PlayerRoundIcon(if (player.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        if (player.isPlaying) L("Pause") else L("Play"), 52) { player.togglePlay(); onPoke() }
                    if (live && !player.canTimeshift) PlayerRoundIcon(Icons.Filled.KeyboardArrowDown, L("Next channel"), 34) { onZap(1) }
                    else PlayerRoundIcon(Icons.Filled.Forward10, "+10", 36) { onSeek(10.0); onPoke() }
                }
                Spacer(Modifier.weight(1f))
            }

            // onderbalk
            Column(
                Modifier.fillMaxWidth().padding(start = Theme.edge, end = Theme.edge, bottom = tvs(18)),
                verticalArrangement = Arrangement.spacedBy(tvs(10))
            ) {
                if (!live) PlayerTimeline(player, isTV, scrubbing, onScrub, onScrubEnd)
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = if (isTV) 12.dp else 0.dp),
                    horizontalArrangement = Arrangement.spacedBy(tvs(if (isTV) 14 else 22)),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val buttons = mutableListOf<Triple<ImageVector, String, () -> Unit>>()
                    if (isTV) {
                        buttons.add(Triple(if (player.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            if (player.isPlaying) L("Pause") else L("Play")) { player.togglePlay() })
                        if (canSeek) {
                            buttons.add(Triple(Icons.Filled.Replay10, "−10") { onSeek(-10.0) })
                            buttons.add(Triple(Icons.Filled.Forward30, "+30") { onSeek(30.0) })
                        }
                        if (live) {
                            buttons.add(Triple(Icons.Filled.KeyboardArrowUp, L("Previous channel")) { onZap(-1) })
                            buttons.add(Triple(Icons.Filled.KeyboardArrowDown, L("Next channel")) { onZap(1) })
                        }
                    }
                    buttons.add(Triple(Icons.Filled.Subtitles, L("Audio & subtitles")) { onPanel(PlayerPanel.AUDIO_SUBS) })
                    if (!live) buttons.add(Triple(Icons.Filled.ClosedCaption, "OpenSubtitles") { onPanel(PlayerPanel.OPENSUBS) })
                    if (hasSources) buttons.add(Triple(Icons.Filled.VideoLibrary, L("Sources")) { onPanel(PlayerPanel.SOURCES) })
                    if (live && Playlists.library.channels.isNotEmpty()) buttons.add(Triple(Icons.Filled.GridView, "Multiview") { onMultiview() })
                    buttons.add(Triple(Icons.Filled.Tune, L("Options")) { onPanel(PlayerPanel.OPTIONS) })
                    buttons.forEachIndexed { i, (icon, label, action) ->
                        PlayerBarButton(icon, label, isTV, if (i == 0) Modifier.focusRequester(firstButton) else Modifier) {
                            action(); onPoke()
                        }
                    }
                    player.sleepAt?.let { s ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Bedtime, null, tint = Theme.secondary, modifier = Modifier.size(tvs(14)))
                            Spacer(Modifier.width(4.dp))
                            Text(DateFormat.getTimeInstance(DateFormat.SHORT, Localizer.locale).format(Date(s)),
                                color = Theme.secondary, fontSize = tsp(12))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PlayerTimeline(player: PlayerController, isTV: Boolean, scrubbing: Float?, onScrub: (Float) -> Unit, onScrubEnd: () -> Unit) {
    val frac = scrubbing?.toDouble() ?: player.position
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(tvs(12))) {
        Text(PlayerController.format(player.duration * frac), color = Theme.secondary, fontSize = tsp(12),
            fontFamily = FontFamily.Monospace, modifier = Modifier.widthIn(min = 44.dp))
        if (isTV) {
            ProgressBar(frac, Modifier.weight(1f).height(6.dp).clip(CircleShape))
        } else {
            Slider(
                value = frac.toFloat().coerceIn(0f, 1f),
                onValueChange = onScrub,
                onValueChangeFinished = onScrubEnd,
                colors = SliderDefaults.colors(
                    thumbColor = Theme.red, activeTrackColor = Theme.red, inactiveTrackColor = Color.White.copy(alpha = 0.3f)
                ),
                modifier = Modifier.weight(1f)
            )
        }
        Text("-" + PlayerController.format(player.duration * (1 - frac)), color = Theme.secondary, fontSize = tsp(12),
            fontFamily = FontFamily.Monospace, textAlign = TextAlign.End, modifier = Modifier.widthIn(min = 50.dp))
    }
}

@Composable
private fun PlayerRoundIcon(icon: ImageVector, description: String, size: Int, onClick: () -> Unit) {
    Box(
        Modifier.size((size + 24).dp).clip(CircleShape).focusLift(1.12f, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, description, tint = Color.White, modifier = Modifier.size(size.dp))
    }
}

/** Knop in de onderbalk: op TV icoon + tekst (wit bij focus), op de telefoon alleen het icoon. */
@Composable
private fun PlayerBarButton(icon: ImageVector, label: String, isTV: Boolean, modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val fg = if (focused && isTV) Color.Black else Color.White
    Row(
        modifier
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.06f, onClick = onClick)
            .clip(RoundedCornerShape(8.dp))
            .background(if (focused && isTV) Color.White else Color.Transparent)
            .padding(horizontal = if (isTV) 14.dp else 6.dp, vertical = if (isTV) 8.dp else 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, label, tint = fg, modifier = Modifier.size(if (isTV) tvs(22) else 24.dp))
        if (isTV) {
            Spacer(Modifier.width(8.dp))
            Text(label, color = fg, fontSize = tsp(15), fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}
