package nl.lrvdlinden.bingr

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** App-brede scope voor achtergrondwerk dat schermen overleeft. */
val AppScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

/** Globale navigatiestatus (tegenhanger van AppState op iOS). */
object AppState {
    enum class Stage { SPLASH, PICKER, MAIN }

    lateinit var appContext: Context
    /** true op Android TV / Google TV / Fire TV (bediening met afstandsbediening) */
    var isTV by mutableStateOf(false)

    var stage by mutableStateOf(Stage.SPLASH)
    /** Wat er nu speelt (niet-null = spelerscherm open) */
    var playing by mutableStateOf<PlayableItem?>(null)
    var liveZapList by mutableStateOf(listOf<Channel>())
    var showMultiview by mutableStateOf(false)
    var multiviewStart by mutableStateOf(listOf<Channel>())
    /** Na wisselen van afspeellijst (globaal zoeken / herinnering): dit item openen */
    var pendingItemID by mutableStateOf<String?>(null)
    /** Beeld-in-beeld actief (Android PiP): spelerscherm toont dan alleen video */
    var inPiP by mutableStateOf(false)

    var lastPlaylistID: String?
        get() = Prefs.string("lastPlaylistID")
        set(v) = Prefs.put("lastPlaylistID", v)

    fun splashFinished() { stage = Stage.PICKER }

    fun open(p: PlaylistSource, thenShow: String? = null) {
        lastPlaylistID = p.id
        pendingItemID = thenShow
        stage = Stage.MAIN
        AppScope.launch { Playlists.select(p) }
    }

    fun switchPlaylist() { stage = Stage.PICKER }

    fun play(item: PlayableItem, zap: List<Channel> = emptyList()) {
        liveZapList = zap
        playing = item
    }

    fun openMultiview(start: List<Channel>, candidates: List<Channel>) {
        multiviewStart = start
        liveZapList = candidates
        showMultiview = true
    }
}
