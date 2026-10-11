package nl.lrvdlinden.bingr

import android.content.Context
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.images.WebImage
import java.util.Locale

/** Chromecast: standaard media-ontvanger (CC1AD845). Staat in AndroidManifest als OPTIONS_PROVIDER_CLASS_NAME. */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
            .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/**
 * Chromecast via de Google Cast SDK. Zodra een Cast-sessie start (apparaat gekozen in [CastDevicesDialog]),
 * wordt wat er nu speelt ([PlayerController.current]) op de Chromecast gezet en lokaal gepauzeerd.
 */
object Casting {
    var connected by mutableStateOf(false); private set
    var deviceName by mutableStateOf<String?>(null); private set
    var status by mutableStateOf(""); private set
    var isPlaying by mutableStateOf(false); private set

    private var initialized = false
    private var client: RemoteMediaClient? = null

    private val clientCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() { updateStatus() }
    }

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {
            status = L("Connecting to %@…", session.castDevice?.friendlyName ?: "Chromecast")
        }
        override fun onSessionStarted(session: CastSession, sessionId: String) { attach(session, castCurrent = true) }
        override fun onSessionStartFailed(session: CastSession, error: Int) {
            detach(); status = L("Chromecast error: %@", error.toString())
        }
        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionEnded(session: CastSession, error: Int) { detach() }
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) { attach(session, castCurrent = false) }
        override fun onSessionResumeFailed(session: CastSession, error: Int) { detach() }
        override fun onSessionSuspended(session: CastSession, reason: Int) {}
    }

    @Suppress("DEPRECATION")
    fun castContext(ctx: Context): CastContext? =
        runCatching { CastContext.getSharedInstance() ?: CastContext.getSharedInstance(ctx.applicationContext) }.getOrNull()

    /** Chromecast mogelijk? (telefoon/tablet met Google Play-services; niet op TV/Fire TV) */
    fun isAvailable(ctx: Context): Boolean {
        if (AppState.isTV) return false
        val gms = runCatching {
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS
        }.getOrDefault(false)
        return gms && castContext(ctx) != null
    }

    /** Eenmalig luisteren naar Cast-sessies (aanroepen vanaf het spelerscherm). */
    fun init(ctx: Context) {
        if (initialized || !isAvailable(ctx)) return
        val cc = castContext(ctx) ?: return
        initialized = true
        cc.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        cc.sessionManager.currentCastSession?.let { if (it.isConnected) attach(it, castCurrent = false) }
    }

    private fun attach(session: CastSession, castCurrent: Boolean) {
        connected = true
        deviceName = session.castDevice?.friendlyName
        client?.unregisterCallback(clientCallback)
        client = session.remoteMediaClient
        client?.registerCallback(clientCallback)
        updateStatus()
        if (castCurrent) {
            val p = PlayerController.current
            val u = p?.url
            if (p != null && u != null && !p.isStopped) {
                if (cast(p.item, u, (p.currentTime * 1000).toLong())) p.pause()
            }
        }
    }

    private fun detach() {
        client?.unregisterCallback(clientCallback)
        client = null
        connected = false; deviceName = null; isPlaying = false; status = ""
    }

    private fun updateStatus() {
        val c = client ?: return
        isPlaying = c.isPlaying
        status = when {
            c.playerState == MediaStatus.PLAYER_STATE_IDLE && c.idleReason == MediaStatus.IDLE_REASON_ERROR ->
                L("This stream can't be played on Chromecast.")
            c.isPlaying -> L("Playing on Chromecast")
            c.isPaused -> L("Paused on Chromecast")
            c.isBuffering -> L("Connecting to %@…", deviceName ?: "Chromecast")
            else -> deviceName ?: "Chromecast"
        }
    }

    private fun contentType(url: String): String {
        val s = url.lowercase(Locale.ROOT)
        return when {
            s.contains(".m3u8") -> "application/x-mpegurl"
            s.contains(".mpd") -> "application/dash+xml"
            s.contains(".mp4") || s.contains(".m4v") -> "video/mp4"
            else -> "video/mp2t"
        }
    }

    /** Zet [item] op de verbonden Chromecast. false = geen sessie. */
    fun cast(item: PlayableItem, url: String, positionMs: Long): Boolean {
        val c = client ?: castContext(AppState.appContext)?.sessionManager?.currentCastSession?.remoteMediaClient ?: return false
        val type = when (item.type) {
            MediaType.MOVIE -> MediaMetadata.MEDIA_TYPE_MOVIE
            MediaType.EPISODE, MediaType.SERIES -> MediaMetadata.MEDIA_TYPE_TV_SHOW
            else -> MediaMetadata.MEDIA_TYPE_GENERIC
        }
        val md = MediaMetadata(type)
        md.putString(MediaMetadata.KEY_TITLE, item.title)
        item.subtitle?.let { md.putString(MediaMetadata.KEY_SUBTITLE, it) }
        item.artwork?.takeIf { it.startsWith("http") }?.let { md.addImage(WebImage(Uri.parse(it))) }
        val live = item.type == MediaType.LIVE
        val info = MediaInfo.Builder(url)
            .setContentUrl(url)
            .setStreamType(if (live) MediaInfo.STREAM_TYPE_LIVE else MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(contentType(url))
            .setMetadata(md)
            .build()
        val req = MediaLoadRequestData.Builder()
            .setMediaInfo(info)
            .setAutoplay(true)
            .setCurrentTime(if (live) 0L else positionMs.coerceAtLeast(0))
            .build()
        return runCatching { c.load(req); true }.getOrDefault(false)
    }

    fun togglePause() { client?.togglePlayback() }

    fun stop() {
        runCatching { castContext(AppState.appContext)?.sessionManager?.endCurrentSession(true) }
        detach()
    }

    fun selector(ctx: Context): MediaRouteSelector =
        castContext(ctx)?.mergedSelector ?: MediaRouteSelector.Builder()
            .addControlCategory(CastMediaControlIntent.categoryForCast(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID))
            .build()
}

/**
 * Lijst met Chromecasts in het netwerk (eigen Compose-keuzelijst via MediaRouter; MediaRouteButton
 * vereist een FragmentActivity met AppCompat-thema, MainActivity is een ComponentActivity).
 */
@Composable
fun CastDevicesDialog(onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val router = remember { MediaRouter.getInstance(ctx) }
    val selector = remember { Casting.selector(ctx) }
    var routes by remember { mutableStateOf(listOf<MediaRouter.RouteInfo>()) }

    DisposableEffect(Unit) {
        fun refresh() {
            routes = router.routes.filter { !it.isDefaultOrBluetooth && it.isEnabled && it.matchesSelector(selector) }
                .sortedBy { it.name.lowercase() }
        }
        val cb = object : MediaRouter.Callback() {
            override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) { refresh() }
            override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) { refresh() }
            override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) { refresh() }
        }
        router.addCallback(selector, cb, MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN)
        refresh()
        onDispose { router.removeCallback(cb) }
    }

    PlayerSheet(title = "Chromecast", onDismiss = onDismiss, doneLabel = L("Close")) {
        if (routes.isEmpty() && !Casting.connected) {
            item {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(L("Searching for Chromecasts…"), color = Theme.secondary)
                }
            }
        }
        for (r in routes) {
            item(key = r.id) {
                PlayerSheetRow(r.name, selected = r.isSelected, icon = Icons.Filled.Cast) {
                    router.selectRoute(r)
                    onDismiss()
                }
            }
        }
        if (Casting.connected) {
            item {
                PlayerSheetRow(L("Stop casting"), destructive = true) { Casting.stop(); onDismiss() }
            }
        }
    }
}

/** Overlay in de speler zolang er naar een Chromecast gestuurd wordt. */
@Composable
fun CastingOverlay(onStop: () -> Unit) {
    Column(
        Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(Color.Black.copy(alpha = 0.85f))
            .padding(30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(Icons.Filled.Cast, null, tint = Color.White, modifier = Modifier.size(48.dp))
        Text(Casting.status.ifEmpty { Casting.deviceName ?: "Chromecast" }, color = Color.White, fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            NetflixButton(
                title = if (Casting.isPlaying) L("Pause") else L("Play"),
                icon = if (Casting.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
            ) { Casting.togglePause() }
            NetflixButton(title = L("Stop casting"), icon = Icons.Filled.Close, kind = NetflixKind.SECONDARY) {
                Casting.stop(); onStop()
            }
        }
    }
}
