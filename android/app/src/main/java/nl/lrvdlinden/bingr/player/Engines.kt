package nl.lrvdlinden.bingr

import android.content.Context
import android.graphics.Color as AndroidColor
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout
import java.io.File
import java.util.Locale
import java.util.concurrent.TimeUnit

enum class EngineState { IDLE, OPENING, BUFFERING, PLAYING, PAUSED, ENDED, ERROR }

/**
 * Gemeenschappelijke interface voor de twee afspeel-engines:
 * - **ExoPlayer (Media3)**: HDR, HLS/DASH/MP4/TS — tegenhanger van AVPlayer op iOS
 * - **VLC**: alles daarbuiten (.mkv met DTS/AC3, smb://, rtmp, MAC-portals)
 * Alle aanroepen op de main thread.
 */
interface PlaybackEngine {
    val state: EngineState
    val isPlaying: Boolean
    /** 0...1 (0 bij live) */
    val position: Double
    /** seconden */
    val time: Double
    /** seconden (0 = live) */
    val duration: Double
    var rate: Float
    var muted: Boolean
    val supportsExternalSubtitles: Boolean

    fun load(url: String, live: Boolean, startFraction: Double?)
    fun play()
    fun pause()
    fun stop()
    /** Speler vrijgeven (daarna niet meer gebruiken). */
    fun release()
    fun seekToFraction(f: Double)
    fun jump(seconds: Double)

    val audioTracks: List<MediaTrack>
    val subtitleTracks: List<MediaTrack>
    val currentAudio: String?
    val currentSubtitle: String?
    fun selectAudio(t: MediaTrack)
    fun selectSubtitle(t: MediaTrack?)
    fun addSubtitle(file: File)
    fun setAspect(a: PlayerController.Aspect)
    /** Ondertitels verschuiven (seconden); bij ExoPlayer gaat dit via de eigen overlay. */
    fun setSubtitleDelay(seconds: Double)
}

// MARK: - ExoPlayer -------------------------------------------------------------------

@androidx.annotation.OptIn(UnstableApi::class)
class ExoEngine(ctx: Context) : PlaybackEngine {
    val player: ExoPlayer
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var failed = false
    private var loaded = false
    private var live = false
    private var released = false
    /** Huidige beeldvullingsstand (wordt door [EngineView] op de PlayerView gezet). */
    var resizeMode: Int = AspectRatioFrameLayout.RESIZE_MODE_FIT
        private set
    var view: PlayerView? = null
        set(v) { field = v; v?.resizeMode = resizeMode }

    init {
        val client = Http.client.newBuilder().readTimeout(30, TimeUnit.SECONDS).build()
        val http = OkHttpDataSource.Factory(client).setUserAgent(Http.USER_AGENT)
        val dataSource = DefaultDataSource.Factory(ctx, http)
        player = ExoPlayer.Builder(ctx)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) { failed = true }
        })
    }

    override val state: EngineState
        get() {
            if (released) return EngineState.IDLE
            if (failed || player.playerError != null) return EngineState.ERROR
            return when (player.playbackState) {
                Player.STATE_ENDED -> EngineState.ENDED
                Player.STATE_BUFFERING -> EngineState.BUFFERING
                Player.STATE_READY -> if (player.isPlaying) EngineState.PLAYING else EngineState.PAUSED
                else -> if (loaded) EngineState.OPENING else EngineState.IDLE
            }
        }
    override val isPlaying: Boolean get() = !released && player.isPlaying
    override val duration: Double
        get() {
            if (released || live || player.isCurrentMediaItemLive) return 0.0
            val d = player.duration
            return if (d == C.TIME_UNSET || d <= 0) 0.0 else d / 1000.0
        }
    override val time: Double get() = if (released) 0.0 else player.currentPosition.coerceAtLeast(0) / 1000.0
    override val position: Double get() { val d = duration; return if (d > 0) (time / d).coerceIn(0.0, 1.0) else 0.0 }
    override var rate: Float = 1f
        set(v) { field = v; if (!released) player.setPlaybackSpeed(v) }
    override var muted: Boolean = false
        set(v) { field = v; if (!released) player.volume = if (v) 0f else 1f }
    override val supportsExternalSubtitles: Boolean get() = false   // via eigen overlay

    /** Hoeveel seconden er bij live terug gespoeld kan worden (HLS-DVR-venster). */
    val liveWindow: Double
        get() {
            if (released) return 0.0
            val tl = player.currentTimeline
            if (tl.isEmpty) return 0.0
            val w = Timeline.Window()
            tl.getWindow(player.currentMediaItemIndex, w)
            return if (w.isSeekable && w.isDynamic && w.durationMs != C.TIME_UNSET) w.durationMs / 1000.0 else 0.0
        }
    val behindLive: Double
        get() { val w = liveWindow; return if (w > 0) (w - time).coerceAtLeast(0.0) else 0.0 }

    override fun load(url: String, live: Boolean, startFraction: Double?) {
        if (released) return
        failed = false; loaded = true; this.live = live
        val lower = url.lowercase(Locale.ROOT)
        val b = androidx.media3.common.MediaItem.Builder().setUri(url)
        when {
            lower.contains(".m3u8") -> b.setMimeType(MimeTypes.APPLICATION_M3U8)
            lower.contains(".mpd") -> b.setMimeType(MimeTypes.APPLICATION_MPD)
        }
        player.setMediaItem(b.build())
        player.setPlaybackSpeed(rate)
        player.volume = if (muted) 0f else 1f
        player.prepare()
        player.playWhenReady = true
        if (startFraction != null && startFraction > 0.01) {
            scope.launch {
                repeat(40) {   // wachten tot de lengte bekend is
                    delay(250)
                    if (duration > 0) { seekToFraction(startFraction); return@launch }
                }
            }
        }
    }

    override fun play() { if (!released) { if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition(); player.play() } }
    override fun pause() { if (!released) player.pause() }
    override fun stop() { if (!released) player.stop() }
    override fun release() {
        if (released) return
        released = true
        scope.cancel()
        view?.player = null
        player.release()
    }
    override fun seekToFraction(f: Double) {
        val d = duration
        if (d <= 0 || released) return
        player.seekTo((d * f.coerceIn(0.0, 1.0) * 1000).toLong())
    }
    override fun jump(seconds: Double) {
        if (released) return
        val target = ((time + seconds) * 1000).toLong().coerceAtLeast(0)
        player.seekTo(target)
    }
    fun goLive() { if (!released) { player.seekToDefaultPosition(); play() } }

    // sporen
    private fun tracks(type: Int): List<MediaTrack> {
        if (released) return emptyList()
        val out = mutableListOf<MediaTrack>()
        for ((gi, g) in player.currentTracks.groups.withIndex()) {
            if (g.type != type) continue
            for (ti in 0 until g.length) {
                if (!g.isTrackSupported(ti)) continue
                val f = g.getTrackFormat(ti)
                val lang = f.language?.takeIf { it.isNotBlank() && it != "und" }
                var name = f.label?.takeIf { it.isNotBlank() } ?: lang?.let { TrackPreferences.name(it.split('-', '_').first()) }
                    ?: "${if (type == C.TRACK_TYPE_AUDIO) L("Audio") else L("Subtitles")} ${out.size + 1}"
                if (type == C.TRACK_TYPE_AUDIO && f.channelCount > 2) name += " ${if (f.channelCount == 6) "5.1" else if (f.channelCount == 8) "7.1" else "${f.channelCount}ch"}"
                out += MediaTrack("$gi:$ti", name, lang)
            }
        }
        return out
    }
    private fun current(type: Int): String? {
        if (released) return null
        if (type == C.TRACK_TYPE_TEXT && player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)) return null
        for ((gi, g) in player.currentTracks.groups.withIndex()) {
            if (g.type != type) continue
            for (ti in 0 until g.length) if (g.isTrackSelected(ti)) return "$gi:$ti"
        }
        return null
    }
    override val audioTracks: List<MediaTrack> get() = tracks(C.TRACK_TYPE_AUDIO)
    override val subtitleTracks: List<MediaTrack> get() = tracks(C.TRACK_TYPE_TEXT)
    override val currentAudio: String? get() = current(C.TRACK_TYPE_AUDIO)
    override val currentSubtitle: String? get() = current(C.TRACK_TYPE_TEXT)

    private fun select(type: Int, t: MediaTrack) {
        val parts = t.id.split(":")
        val gi = parts.getOrNull(0)?.toIntOrNull() ?: return
        val ti = parts.getOrNull(1)?.toIntOrNull() ?: return
        val groups = player.currentTracks.groups
        if (gi !in groups.indices) return
        val g = groups[gi]
        if (g.type != type || ti !in 0 until g.length) return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, ti))
            .build()
    }
    override fun selectAudio(t: MediaTrack) { if (!released) select(C.TRACK_TYPE_AUDIO, t) }
    override fun selectSubtitle(t: MediaTrack?) {
        if (released) return
        if (t == null) {
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
        } else select(C.TRACK_TYPE_TEXT, t)
    }
    override fun addSubtitle(file: File) {}
    override fun setSubtitleDelay(seconds: Double) {}   // externe ondertitels: via de eigen overlay

    override fun setAspect(a: PlayerController.Aspect) {
        resizeMode = when (a) {
            PlayerController.Aspect.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
            PlayerController.Aspect.FILL -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            else -> AspectRatioFrameLayout.RESIZE_MODE_FILL
        }
        view?.resizeMode = resizeMode
    }
}

// MARK: - VLC -----------------------------------------------------------------------

/** Eén gedeelde LibVLC-instantie voor de hele app. */
object VLCRuntime {
    private var lib: LibVLC? = null
    fun get(ctx: Context): LibVLC =
        lib ?: LibVLC(ctx.applicationContext, arrayListOf("--http-reconnect", "--audio-time-stretch")).also { lib = it }
}

class VlcEngine(ctx: Context) : PlaybackEngine {
    private val lib = VLCRuntime.get(ctx)
    val player = MediaPlayer(lib)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var vstate = EngineState.IDLE
    private var layout: VLCVideoLayout? = null
    private var pendingPlay = false
    private var released = false
    private var aspect = PlayerController.Aspect.FIT

    init {
        player.setEventListener(MediaPlayer.EventListener { ev ->
            when (ev.type) {
                MediaPlayer.Event.Opening -> vstate = EngineState.OPENING
                MediaPlayer.Event.Buffering -> {
                    if (ev.buffering < 100f) { if (vstate != EngineState.PLAYING) vstate = EngineState.BUFFERING }
                    else if (!released && player.isPlaying) vstate = EngineState.PLAYING
                }
                MediaPlayer.Event.Playing -> vstate = EngineState.PLAYING
                MediaPlayer.Event.Paused -> vstate = EngineState.PAUSED
                MediaPlayer.Event.Stopped -> if (vstate != EngineState.ENDED && vstate != EngineState.ERROR) vstate = EngineState.IDLE
                MediaPlayer.Event.EndReached -> vstate = EngineState.ENDED
                MediaPlayer.Event.EncounteredError -> vstate = EngineState.ERROR
                MediaPlayer.Event.Vout -> if (aspect != PlayerController.Aspect.FIT) setAspect(aspect)
                else -> {}
            }
        })
    }

    override val state: EngineState
        get() = if (vstate == EngineState.BUFFERING && !released && player.isPlaying) EngineState.PLAYING else vstate
    override val isPlaying: Boolean get() = !released && player.isPlaying
    override val duration: Double get() = if (released) 0.0 else player.getLength().coerceAtLeast(0) / 1000.0
    override val time: Double get() = if (released) 0.0 else player.getTime().coerceAtLeast(0) / 1000.0
    override val position: Double get() = if (duration > 0) player.getPosition().toDouble().coerceIn(0.0, 1.0) else 0.0
    override var rate: Float = 1f
        set(v) { field = v; if (!released) player.setRate(v) }
    override var muted: Boolean = false
        set(v) { field = v; if (!released) player.setVolume(if (v) 0 else 100) }
    override val supportsExternalSubtitles: Boolean get() = true

    /** Koppelt het beeld; als er al iets klaarstaat begint het nu te spelen. */
    fun attach(v: VLCVideoLayout) {
        if (released) return
        if (layout != null) runCatching { player.detachViews() }
        layout = v
        player.attachViews(v, null, true, false)
        if (pendingPlay) { pendingPlay = false; player.play() }
    }
    fun detach(v: VLCVideoLayout) {
        if (released || layout !== v) return
        runCatching { player.detachViews() }
        layout = null
    }

    override fun load(url: String, live: Boolean, startFraction: Double?) {
        if (released) return
        val media = Media(lib, Uri.parse(url))
        media.addOption(":network-caching=${if (live) 1500 else 3000}")
        media.addOption(":http-user-agent=${Http.USER_AGENT}")
        media.addOption(":http-reconnect")
        player.setMedia(media)
        media.release()
        vstate = EngineState.OPENING
        player.setRate(rate)
        if (layout != null) player.play() else pendingPlay = true
        player.setVolume(if (muted) 0 else 100)
        if (startFraction != null && startFraction > 0.01) {
            scope.launch {
                repeat(40) {   // wachten tot de lengte bekend is
                    delay(250)
                    if (released) return@launch
                    if (duration > 0 && player.isPlaying) { player.setPosition(startFraction.toFloat()); return@launch }
                }
            }
        }
    }
    override fun play() { if (!released) { if (layout != null) player.play() else pendingPlay = true } }
    override fun pause() { if (!released) { pendingPlay = false; player.pause() } }
    override fun stop() { if (!released) { pendingPlay = false; player.stop() } }
    override fun release() {
        if (released) return
        released = true
        scope.cancel()
        player.setEventListener(null as MediaPlayer.EventListener?)
        runCatching { player.stop() }
        runCatching { player.detachViews() }
        layout = null
        player.release()
    }
    override fun seekToFraction(f: Double) { if (!released) player.setPosition(f.coerceIn(0.0, 1.0).toFloat()) }
    override fun jump(seconds: Double) {
        if (released) return
        val t = (player.getTime() + (seconds * 1000).toLong()).coerceAtLeast(0)
        val len = player.getLength()
        player.setTime(if (len > 0) t.coerceAtMost(len - 1000) else t)
    }

    private fun list(arr: Array<MediaPlayer.TrackDescription>?): List<MediaTrack> =
        arr?.filter { it.id != -1 }?.map { MediaTrack(it.id.toString(), it.name ?: "#${it.id}") } ?: emptyList()

    override val audioTracks: List<MediaTrack> get() = if (released) emptyList() else list(player.getAudioTracks())
    override val subtitleTracks: List<MediaTrack> get() = if (released) emptyList() else list(player.getSpuTracks())
    override val currentAudio: String? get() = if (released) null else player.getAudioTrack().toString()
    override val currentSubtitle: String?
        get() = if (released) null else player.getSpuTrack().let { if (it == -1) null else it.toString() }
    override fun selectAudio(t: MediaTrack) { if (!released) t.id.toIntOrNull()?.let { player.setAudioTrack(it) } }
    override fun selectSubtitle(t: MediaTrack?) { if (!released) player.setSpuTrack(t?.id?.toIntOrNull() ?: -1) }
    override fun addSubtitle(file: File) {
        // 0 = IMedia.Slave.Type.Subtitle
        if (!released) player.addSlave(SLAVE_SUBTITLE, Uri.fromFile(file), true)
    }
    override fun setSubtitleDelay(seconds: Double) { if (!released) player.setSpuDelay((seconds * 1_000_000).toLong()) }

    override fun setAspect(a: PlayerController.Aspect) {
        aspect = a
        if (released) return
        when (a) {
            PlayerController.Aspect.FIT -> { player.setAspectRatio(null); player.setScale(0f) }
            PlayerController.Aspect.FILL -> {
                val w = layout?.width ?: 0; val h = layout?.height ?: 0
                player.setScale(0f)
                player.setAspectRatio(if (w > 0 && h > 0) "$w:$h" else "16:9")
            }
            PlayerController.Aspect.R169 -> { player.setScale(0f); player.setAspectRatio("16:9") }
            PlayerController.Aspect.R43 -> { player.setScale(0f); player.setAspectRatio("4:3") }
        }
    }

    companion object { private const val SLAVE_SUBTITLE = 0 }
}

// MARK: - Beeld -----------------------------------------------------------------------

/** Toont de video van de actieve engine van deze speler (wisselt mee bij terugval naar de andere engine). */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
fun EngineView(controller: PlayerController, modifier: Modifier = Modifier) {
    val engine = controller.engine
    key(engine) {
        when (engine) {
            is ExoEngine -> AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        setShutterBackgroundColor(AndroidColor.BLACK)
                        setBackgroundColor(AndroidColor.BLACK)
                        isFocusable = false
                        isClickable = false
                        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                        player = engine.player
                        engine.view = this
                    }
                },
                modifier = modifier,
                onRelease = { v -> if (engine.view === v) engine.view = null; v.player = null },
            )
            is VlcEngine -> AndroidView(
                factory = { ctx ->
                    VLCVideoLayout(ctx).apply {
                        setBackgroundColor(AndroidColor.BLACK)
                        isFocusable = false
                        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                        engine.attach(this)
                    }
                },
                modifier = modifier,
                onRelease = { v -> engine.detach(v) },
            )
            else -> {}
        }
    }
}
