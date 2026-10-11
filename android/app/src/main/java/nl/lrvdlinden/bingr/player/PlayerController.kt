package nl.lrvdlinden.bingr

import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale
import kotlin.math.min
import kotlin.math.pow

/**
 * Stuurt één afspeelsessie aan: kiest de engine (ExoPlayer of VLC), herverbindt
 * automatisch, doet timeshift bij live, bewaart voortgang en scrobblet naar Trakt.
 * Alle aanroepen op de main thread.
 */
class PlayerController(item: PlayableItem) {
    enum class EngineChoice(val key: String) {
        AUTO("auto"), APPLE("apple"), VLC("vlc");
        val title: String
            get() = when (this) {
                AUTO -> L("Automatic")
                APPLE -> L("ExoPlayer (HDR, Chromecast)")
                VLC -> L("VLC (all formats)")
            }
        companion object { fun from(key: String?): EngineChoice = entries.firstOrNull { it.key == key } ?: AUTO }
    }

    enum class Aspect {
        FIT, FILL, R169, R43;
        val title: String
            get() = when (this) { FIT -> L("Fit"); FILL -> L("Fill"); R169 -> "16:9"; R43 -> "4:3" }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val ctx get() = AppState.appContext

    var item by mutableStateOf(item)
    var engine: PlaybackEngine by mutableStateOf<PlaybackEngine>(IdleEngine())
        private set
    /** true = ExoPlayer, false = VLC */
    var usingExo by mutableStateOf(false); private set
    var isPlaying by mutableStateOf(false); private set
    var isBuffering by mutableStateOf(true); private set
    var position by mutableStateOf(0.0); private set
    var currentTime by mutableStateOf(0.0); private set
    var duration by mutableStateOf(0.0); private set
    var errorText by mutableStateOf<String?>(null); private set
    var reconnecting by mutableStateOf(false); private set
    /** Hoeveel seconden achter live (timeshift) */
    var behindLive by mutableStateOf(0.0); private set
    var subtitleText by mutableStateOf<String?>(null); private set
    /** Telt op als de sporen veranderen (voor het sporenpaneel) */
    var tracksVersion by mutableStateOf(0); private set

    private var _rate by mutableStateOf(1f)
    var rate: Float
        get() = _rate
        set(v) { _rate = v; engine.rate = v }
    /** Slaaptimer: epoch-ms */
    var sleepAt by mutableStateOf<Long?>(null)
    private var _aspect by mutableStateOf(Aspect.FIT)
    var aspect: Aspect
        get() = _aspect
        set(v) { _aspect = v; engine.setAspect(v) }
    private var _muted by mutableStateOf(false)
    var muted: Boolean
        get() = _muted
        set(v) { _muted = v; engine.muted = v }
    /** Korte melding voor in beeld (bijv. "beeld-in-beeld niet beschikbaar") */
    var notice by mutableStateOf<String?>(null)

    private var stopped = false
    val isStopped: Boolean get() = stopped
    /** Spelerscherm is gesloten: een stream die daarna pas klaar is met laden niet meer starten. */
    var dismissed = false

    /** Echte afspeel-URL (na Stalker/Stremio-resolutie) */
    var url: String? = null; private set
    var catchupProvider: ((Long, Long) -> String?)? = null
    var onFinished: (() -> Unit)? = null
    /** Multiview-tegels: geen voortgang/scrobble */
    var isPreview = false
    /** De gewone live-URL (om na timeshift terug te keren) */
    var liveURL: String? = null

    private var timer: Job? = null
    private var lastSaved = 0L
    private var didScrobbleStart = false
    private var stallSince: Long? = null
    private var attempts = 0
    private var triedOtherEngine = false
    private var pausedAt: Long? = null
    private var timeshiftStart: Long? = null        // begin van de catch-up-stream die nu speelt (epoch-ms)
    private var externalCues: List<SubtitleCue> = emptyList()
    private var tracksApplied = false
    private var watchedSeconds = 0.0
    private var playingTicks = 0
    private var trackSignature = ""
    private var recordedHistory = false

    val isLive: Boolean get() = item.type == MediaType.LIVE
    val canTimeshift: Boolean
        get() = isLive && (catchupProvider != null || ((engine as? ExoEngine)?.liveWindow ?: 0.0) > 30)

    // MARK: engine kiezen

    private fun makeEngine(exo: Boolean) {
        engine.release()
        engine = if (exo) ExoEngine(ctx) else VlcEngine(ctx)
        usingExo = exo
        engine.rate = rate
        engine.muted = muted
        engine.setAspect(aspect)
    }

    // MARK: afspelen

    /** Nieuwe titel/zender: niets meenemen van de vorige (timeshift, pauze, herverbind-pogingen, fout). */
    fun prepareNew() {
        timeshiftStart = null; behindLive = 0.0; pausedAt = null
        attempts = 0; triedOtherEngine = false; reconnecting = false; errorText = null; isBuffering = true
        stallSince = null
    }

    /** Kan niet afspelen (geen stream gevonden): foutmelding met "Try again" in plaats van een eindeloze spinner. */
    fun fail(message: String) {
        errorText = message; isBuffering = false; reconnecting = false
    }

    /** Nieuwe ondertitelgrootte meteen toepassen (Opties tijdens het afspelen). */
    fun applySubtitleSize() {
        engine.setSubtitleSize(SubtitleSize.current)
        tracksVersion++
    }

    fun start(url: String, forceExo: Boolean? = null) {
        if (dismissed) return
        this.url = url
        errorText = null; didScrobbleStart = false; stallSince = null
        tracksApplied = false; playingTicks = 0
        if (stopped || timer == null) { watchedSeconds = 0.0; recordedHistory = false; attempts = 0; triedOtherEngine = false }
        stopped = false
        val exo = forceExo ?: prefersExo(url)
        if (exo != usingExo || timer == null) makeEngine(exo)
        engine.load(url, live = isLive && timeshiftStart == null, startFraction = startFraction())
        timer?.cancel()
        timer = scope.launch {
            while (isActive) {
                delay(500)
                tick()
            }
        }
    }

    /** Hervatpunt (0 = vanaf het begin; bijna uitgekeken = ook vanaf het begin). */
    private fun startFraction(): Double? {
        if (isLive) return null
        val r = item.resumeAt
        return if (r > 0.01 && r < 0.97) r else null
    }

    /** Wisselt naar ExoPlayer op dezelfde positie. */
    fun switchToExo() {
        val u = url ?: return
        if (usingExo || !canUseExo(u)) return
        item = item.copy(resumeAt = position)
        start(u, forceExo = true)
    }

    /** Wisselt naar VLC op dezelfde positie. */
    fun switchToVLC() {
        val u = url ?: return
        if (!usingExo) return
        item = item.copy(resumeAt = position)
        start(u, forceExo = false)
    }

    private fun tick() {
        val st = engine.state
        isPlaying = engine.isPlaying
        isBuffering = st == EngineState.BUFFERING || st == EngineState.OPENING
        duration = engine.duration
        currentTime = engine.time
        position = engine.position
        val exo = engine as? ExoEngine
        if (exo != null && isLive && timeshiftStart == null) behindLive = if (exo.behindLive > 8) exo.behindLive else 0.0

        if (externalCues.isNotEmpty()) {
            val t = currentTime - subtitleDelay
            val cue = externalCues.lastOrNull { it.start <= t }
            subtitleText = if (cue != null && cue.end >= t) cue.text else null
        }

        // automatisch herverbinden
        if (st == EngineState.ERROR || (isLive && st == EngineState.ENDED)) {
            reconnect()
        } else if (isBuffering && isLive) {
            val now = System.currentTimeMillis()
            if (stallSince == null) stallSince = now
            stallSince?.let { if (now - it > 15_000) reconnect() }
        } else if (st == EngineState.PLAYING) {
            stallSince = null; attempts = 0; reconnecting = false
        }

        if (isPlaying && !didScrobbleStart && duration > 0 && !isPreview) {
            didScrobbleStart = true
            scrobble(Trakt.Scrobble.START, position, announce = true)
        }
        if (st == EngineState.PLAYING) watchedSeconds += 0.5
        if (!tracksApplied && st == EngineState.PLAYING) {
            playingTicks += 1
            // sporen zijn er meestal na een paar tellen; daarna niet meer ingrijpen (jouw eigen keuze blijft staan)
            if (engine.audioTracks.isNotEmpty() || playingTicks > 12) applyTrackPreferences()
        }
        // sporenpaneel bijwerken als er sporen bijkomen of wisselen
        val sig = "${engine.audioTracks.size}|${engine.subtitleTracks.size}|${engine.currentAudio}|${engine.currentSubtitle}"
        if (sig != trackSignature) { trackSignature = sig; tracksVersion++ }

        sleepAt?.let { if (System.currentTimeMillis() >= it) { sleepAt = null; pause() } }
        if (System.currentTimeMillis() - lastSaved > 15_000) saveProgress()
        if (!isLive && st == EngineState.ENDED) finish()
    }

    private fun reconnect() {
        val u = url ?: return
        if (attempts >= 6) {
            errorText = L("This stream can't be played right now."); reconnecting = false
            timer?.cancel(); timer = null
            return
        }
        // eerste fout: de andere engine proberen (VLC kan meer formaten aan, ExoPlayer soms HLS/DASH beter)
        if (!triedOtherEngine && attempts == 0 && engine.state == EngineState.ERROR && (usingExo || canUseExo(u))) {
            triedOtherEngine = true
            attempts += 1
            start(u, forceExo = !usingExo)
            return
        }
        attempts += 1
        reconnecting = true
        stallSince = System.currentTimeMillis() + attempts * 2000L  // backoff
        val resume = position
        val delayMs = (min(2.0.pow(attempts - 1), 8.0) * 1000).toLong()
        scope.launch {
            delay(delayMs)
            if (stopped || dismissed) return@launch
            if (!isLive) item = item.copy(resumeAt = resume)
            engine.load(u, live = isLive && timeshiftStart == null, startFraction = if (isLive) null else resume)
        }
    }

    /** Opnieuw proberen na een fout ("Try again"). */
    fun retry() {
        val u = url ?: return
        attempts = 0; triedOtherEngine = false; reconnecting = false
        start(u)
    }

    fun togglePlay() { if (engine.isPlaying) pause() else resume() }

    fun pause() {
        engine.pause()
        if (isLive) pausedAt = System.currentTimeMillis()
        saveProgress()
        if (!isPreview) scrobble(Trakt.Scrobble.PAUSE, position)
    }

    fun resume() {
        // Live gepauzeerd met catch-up: verder kijken waar je was (timeshift)
        val p = pausedAt
        val provider = catchupProvider
        val now = System.currentTimeMillis()
        if (isLive && p != null && now - p > 10_000 && provider != null && !(engine is ExoEngine && (engine as ExoEngine).liveWindow > 30)) {
            val from = timeshiftStart?.let { it + (currentTime * 1000).toLong() } ?: p
            val u = provider(from, now + 3 * 3600_000L)
            if (u != null) {
                timeshiftStart = from
                behindLive = (now - from) / 1000.0
                pausedAt = null
                start(u)
                return
            }
        }
        pausedAt = null
        engine.play()
        if (!isPreview) scrobble(Trakt.Scrobble.START, position)
    }

    /** Spoelen. Bij live: binnen het HLS-venster, of via catch-up (timeshift). */
    fun seek(seconds: Double) {
        if (!isLive) { engine.jump(seconds); return }
        val exo = engine as? ExoEngine
        if (exo != null && timeshiftStart == null && exo.liveWindow > 30) { exo.jump(seconds); return }
        val provider = catchupProvider ?: return
        val now = System.currentTimeMillis()
        val currentWall = timeshiftStart?.let { it + (currentTime * 1000).toLong() } ?: now
        val target = min(currentWall + (seconds * 1000).toLong(), now)
        if (now - target < 10_000) { goLive(); return }
        val u = provider(target, now + 3 * 3600_000L) ?: return
        timeshiftStart = target
        behindLive = (now - target) / 1000.0
        start(u)
    }

    fun goLive() {
        val exo = engine as? ExoEngine
        if (exo != null && timeshiftStart == null) { exo.goLive(); behindLive = 0.0; return }
        if (timeshiftStart == null) return
        val u = liveURL ?: item.url ?: return
        timeshiftStart = null; behindLive = 0.0
        start(u)
    }

    fun seekTo(fraction: Double) { if (!isLive) engine.seekToFraction(fraction) }

    fun stop() {
        if (stopped) return
        stopped = true
        recordHistory()
        timer?.cancel(); timer = null
        saveProgress()
        if (!isPreview) scrobble(Trakt.Scrobble.STOP, position)
        engine.release()
        isPlaying = false
        if (current === this) current = null
    }

    private fun finish() {
        recordHistory()
        timer?.cancel(); timer = null
        position = 1.0
        saveProgress()
        if (!isPreview) scrobble(Trakt.Scrobble.STOP, 1.0)
        onFinished?.invoke()
    }

    /**
     * Scrobble naar Trakt. Bij [announce] kort laten zien dat Trakt meekijkt (of waarom niet), als
     * `Trakt.scrobble` een resultaat teruggeeft (enum OK / NOT_FOUND / FAILED / SKIPPED, zoals ScrobbleResult op iOS).
     * Geeft het Unit terug, dan wordt er niets getoond.
     */
    private fun scrobble(action: Trakt.Scrobble, progress: Double, announce: Boolean = false) {
        if (isPreview) return
        val itm = item
        AppScope.launch {
            if (!(Trakt.isLoggedIn && Trakt.scrobbleEnabled)) return@launch
            val result: Any? = try {
                Trakt.scrobble(action, itm, progress)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (!announce || stopped || item.id != itm.id) return@launch
            val key = result?.toString()?.lowercase(Locale.ROOT)?.replace("_", "") ?: return@launch
            when (key) {
                "ok" -> notice = L("Trakt: watching %@", itm.subtitle?.let { "${itm.title} · $it" } ?: itm.title)
                "notfound" -> notice = L("Trakt: title not found, not synced")
                "failed" -> notice = L("Trakt: could not connect")
                else -> {}
            }
        }
    }

    /** Na minstens een minuut kijken komt het in de kijkgeschiedenis van dit profiel. */
    private fun recordHistory() {
        if (isPreview || recordedHistory || watchedSeconds < 60) return
        recordedHistory = true
        val it = item
        Store.addHistory(
            HistoryEntry(
                itemID = it.channelID ?: it.id, playlistID = Store.activePlaylistID,
                title = it.title, subtitle = it.subtitle, artwork = it.artwork,
                type = it.type, channelID = it.channelID, date = System.currentTimeMillis(),
                profileID = Store.activeProfileID
            )
        )
    }

    private fun saveProgress() {
        lastSaved = System.currentTimeMillis()
        val it = item
        if (isPreview || it.type == MediaType.LIVE || it.channelID != null || it.id.contains("-cu-") || duration <= 60) return
        // gezien: bijna uitgekeken, of alleen de aftiteling nog over — per profiel, ook zonder Trakt
        val left = duration - currentTime
        if (position >= 0.85 || (duration > 600 && left < 180 && position > 0.7)) {
            Store.clearProgress(it.id)
            Store.setLocalWatched(it.id, true)
            val s = it.season; val e = it.episode
            if (it.type == MediaType.EPISODE && s != null && e != null) {
                seriesID(it)?.let { sid -> Store.setLocalWatched(Store.episodeKey(sid, s, e), true) }
            }
        } else if (position > 0.02) {
            Store.setProgress(
                it.id,
                ProgressEntry(
                    fraction = position, position = currentTime, updated = System.currentTimeMillis(),
                    title = it.title, artwork = it.artwork, playlistID = Store.activePlaylistID,
                    profileID = Store.activeProfileID
                )
            )
        }
    }

    /** Serie van een aflevering: uit het item, anders opzoeken in de bibliotheek. */
    private fun seriesID(p: PlayableItem): String? {
        p.seriesID?.let { sid -> return sid }
        val lib = Playlists.library
        return lib.series.firstOrNull { s -> s.episodes.any { e -> e.id == p.id } }?.id
            ?: lib.series.firstOrNull { s -> s.title == p.title }?.id
    }

    // MARK: beeld-in-beeld

    /** Start beeld-in-beeld (Android: de hele app gaat in het PiP-venster, beide engines werken). */
    fun startPiP() {
        val ok = MainActivity.current?.enterPiP() ?: false
        if (!ok) notice = L("Picture in Picture isn't available for this stream.")
    }

    // MARK: sporen & ondertitels

    /** Standaard audio-/ondertiteltaal uit de instellingen toepassen. */
    private fun applyTrackPreferences() {
        tracksApplied = true
        if (isPreview) return
        val audio = TrackPreferences.audio
        val sub = TrackPreferences.subtitle
        if (audio.isNotEmpty()) {
            val t = engine.audioTracks.filter { it.id != "-1" }.firstOrNull { TrackPreferences.matches(it, audio) }
            if (t != null && t.id != engine.currentAudio) engine.selectAudio(t)
        }
        if (sub == "off") {
            if (externalCues.isEmpty()) engine.selectSubtitle(null)
        } else if (sub.isNotEmpty() && externalCues.isEmpty()) {
            engine.subtitleTracks.firstOrNull { TrackPreferences.matches(it, sub) }?.let { engine.selectSubtitle(it) }
        }
        tracksVersion++
    }

    val audioTracks: List<MediaTrack> get() { tracksVersion; return engine.audioTracks }
    val subtitleTracks: List<MediaTrack> get() { tracksVersion; return engine.subtitleTracks }
    val currentAudio: String? get() { tracksVersion; return engine.currentAudio }
    val currentSubtitle: String? get() { tracksVersion; return if (externalCues.isEmpty()) engine.currentSubtitle else "ext" }
    val hasExternalSubtitle: Boolean get() = externalCues.isNotEmpty() || externalSubtitleName != null
    /** Naam van de laatst ingeladen OpenSubtitles-ondertitel (met vlag) */
    var externalSubtitleName by mutableStateOf<String?>(null); private set
    /** Verschuiving van de ondertitels in seconden (+ = later tonen) */
    private var _subtitleDelay by mutableStateOf(0.0)
    var subtitleDelay: Double
        get() = _subtitleDelay
        set(v) { _subtitleDelay = v; engine.setSubtitleDelay(v) }

    fun selectAudio(t: MediaTrack) { engine.selectAudio(t); tracksVersion++ }
    fun selectSubtitle(t: MediaTrack?) {
        externalCues = emptyList(); subtitleText = null; externalSubtitleName = null
        engine.selectSubtitle(t); tracksVersion++
    }

    fun addSubtitle(file: File, name: String? = null) {
        // altijd als UTF-8 aanbieden (OpenSubtitles levert soms Windows-1252/Latin-1 → rare tekens)
        val utf8 = SRT.normalizedFile(file) ?: file
        if (engine.supportsExternalSubtitles) {
            engine.addSubtitle(utf8)
        } else {
            val bytes = runCatching { utf8.readBytes() }.getOrNull()
            if (bytes != null) {
                engine.selectSubtitle(null)
                externalCues = SRT.parse(bytes)
                subtitleText = null
            }
        }
        externalSubtitleName = name ?: file.nameWithoutExtension
        engine.setSubtitleDelay(subtitleDelay)
        tracksVersion++
    }

    companion object {
        /** De speler van het open spelerscherm (voor beeld-in-beeld en MainActivity). */
        var current: PlayerController? = null

        val choice: EngineChoice get() = EngineChoice.from(Prefs.string("player.engine"))

        val pipSupported: Boolean
            get() = Build.VERSION.SDK_INT >= 26 && !AppState.isTV &&
                AppState.appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

        private fun scheme(url: String): String = Uri.parse(url).scheme?.lowercase(Locale.ROOT) ?: ""

        /** ExoPlayer kan alleen http(s)/file/content openen; smb://, ftp://, rtmp:// enz. alleen VLC. */
        fun canUseExo(url: String): Boolean = scheme(url) in setOf("http", "https", "file", "content")

        fun prefersExo(url: String): Boolean {
            if (!canUseExo(url)) return false
            return when (choice) {
                EngineChoice.APPLE -> true
                EngineChoice.VLC -> false
                EngineChoice.AUTO -> {
                    val path = Uri.parse(url).path ?: ""
                    val ext = path.substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
                    val s = url.lowercase(Locale.ROOT)
                    ext in setOf("m3u8", "mp4", "m4v", "mov", "mpd") || s.contains(".m3u8") || s.contains(".mpd")
                }
            }
        }

        fun format(s: Double): String {
            if (!s.isFinite() || s < 0) return "0:00"
            val t = s.toInt(); val h = t / 3600; val m = (t % 3600) / 60; val sec = t % 60
            return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, sec) else String.format(Locale.ROOT, "%d:%02d", m, sec)
        }
    }
}

/** Plaatshouder tot [PlayerController.start] de echte engine kiest. */
private class IdleEngine : PlaybackEngine {
    override val state: EngineState get() = EngineState.OPENING
    override val isPlaying: Boolean get() = false
    override val position: Double get() = 0.0
    override val time: Double get() = 0.0
    override val duration: Double get() = 0.0
    override var rate: Float = 1f
    override var muted: Boolean = false
    override val supportsExternalSubtitles: Boolean get() = false
    override fun load(url: String, live: Boolean, startFraction: Double?) {}
    override fun play() {}
    override fun pause() {}
    override fun stop() {}
    override fun release() {}
    override fun seekToFraction(f: Double) {}
    override fun jump(seconds: Double) {}
    override val audioTracks: List<MediaTrack> get() = emptyList()
    override val subtitleTracks: List<MediaTrack> get() = emptyList()
    override val currentAudio: String? get() = null
    override val currentSubtitle: String? get() = null
    override fun selectAudio(t: MediaTrack) {}
    override fun selectSubtitle(t: MediaTrack?) {}
    override fun addSubtitle(file: File) {}
    override fun setAspect(a: PlayerController.Aspect) {}
    override fun setSubtitleDelay(seconds: Double) {}
    override fun setSubtitleSize(size: SubtitleSize) {}
}
