package nl.lrvdlinden.bingr

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lan
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.launch
import java.io.File

private enum class S2SettingsSub { CATEGORIES, MANAGE, HISTORY, NAS }
private enum class S2PinMode { SET, UNLOCK, DISABLE }

private const val S2_FILE_AUTHORITY = "nl.lrvdlinden.bingr.files"

/** Alles (incl. wachtwoorden) als .json-bestand delen (deelmenu). */
private fun s2ExportBackup(ctx: Context): Boolean = runCatching {
    val f = File(ctx.cacheDir, "Bingr-backup.json")
    f.writeText(Store.exportJSON())
    val uri: Uri = FileProvider.getUriForFile(ctx, S2_FILE_AUTHORITY, f)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "application/json"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, "Bingr")
        clipData = ClipData.newRawUri("Bingr", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    ctx.startActivity(Intent.createChooser(send, L("Export to file")).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    true
}.getOrDefault(false)

/** "Mijn Bingr": zelfde secties en volgorde als SettingsView.swift. */
@Composable
fun SettingsScreen() {
    val ctx = LocalContext.current
    val listState = rememberLazyListState()
    var sub by remember { mutableStateOf<S2SettingsSub?>(null) }
    var editing by remember { mutableStateOf<PlaylistSource?>(null) }
    var showTraktLogin by remember { mutableStateOf(false) }
    var showOSLogin by remember { mutableStateOf(false) }
    var setup by remember { mutableStateOf<String?>(null) }
    var pinMode by remember { mutableStateOf<S2PinMode?>(null) }
    var shareStatus by remember { mutableStateOf<String?>(null) }

    // instellingen (Prefs) als Compose-state
    var startTab by remember { mutableIntStateOf(Prefs.int("ui.startTab", 0)) }
    var showLive by remember { mutableStateOf(Prefs.bool("ui.showLive", true)) }
    var showMovies by remember { mutableStateOf(Prefs.bool("ui.showMovies", true)) }
    var showSeries by remember { mutableStateOf(Prefs.bool("ui.showSeries", true)) }
    var autoSubtitles by remember { mutableStateOf(Prefs.bool("autoSubtitles", false)) }
    var engine by remember { mutableStateOf(Prefs.string("player.engine") ?: "auto") }
    var refreshPolicy by remember { mutableStateOf(RefreshPolicy.current) }

    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val text = runCatching { ctx.contentResolver.openInputStream(uri)?.use { it.bufferedReader().readText() } }.getOrNull()
            shareStatus = if (text != null && Store.importJSON(text)) L("Imported") else L("Import failed")
        }
    }

    LaunchedEffect(Unit) { runCatching { OpenSubtitles.refreshUser() } }

    // volledige subschermen (vervangen de lijst, zodat de focus erin blijft)
    when (sub) {
        S2SettingsSub.CATEGORIES -> { CategoriesScreen { sub = null }; return }
        S2SettingsSub.MANAGE -> { ManageScreen { sub = null }; return }
        S2SettingsSub.HISTORY -> { HistoryScreen { sub = null }; return }
        S2SettingsSub.NAS -> { NetworkBrowserScreen { sub = null }; return }
        null -> {}
    }
    val editingNow = editing
    if (editingNow != null) {
        AddPlaylistScreen(existing = editingNow, onClose = { editing = null })
        return
    }

    val source = Playlists.source
    val lib = Playlists.library

    S2Page(L("My Bingr"), onClose = null, state = listState) {
        // MARK: afspeellijst
        item {
            S2Section(L("Playlist")) {
                if (source != null) {
                    val current = Store.playlists.firstOrNull { it.id == source.id } ?: source
                    S2Row(current.name,
                        subtitle = L("%@ · %d channels · %d movies · %d series", current.kind.title,
                            lib.channels.size, lib.movies.size, lib.series.size),
                        leading = { AvatarCircle(current, tvs(44)) })
                    S2Row(L("Edit (name, avatar, details)"), icon = Icons.Default.Edit, onClick = { editing = current })
                    S2Row(L("Categories on/off (NL, BE, DE…)"), icon = Icons.Default.FilterList, onClick = { sub = S2SettingsSub.CATEGORIES })
                    S2Row(L("Manage groups and channels"), icon = Icons.Default.Tune, onClick = { sub = S2SettingsSub.MANAGE })
                    S2Row(L("Refresh now"), icon = Icons.Default.Refresh, onClick = {
                        AppScope.launch { runCatching { Playlists.select(current, forceRefresh = true) } }
                    })
                }
                S2Row(L("Choose another playlist"), icon = Icons.Default.SwapHoriz, onClick = { AppState.switchPlaylist() })
            }
        }

        // MARK: bibliotheek
        item {
            S2Section(L("Library"), L("Watch history is kept per profile. Plex, Jellyfin and Emby can be added as a playlist.")) {
                S2Row(L("Watch history"), icon = Icons.Default.History, onClick = { sub = S2SettingsSub.HISTORY })
                S2Row(L("NAS & network (SMB/DLNA)"), icon = Icons.Default.Lan, onClick = { sub = S2SettingsSub.NAS })
            }
        }

        // MARK: afspeellijsten bijwerken
        item {
            S2Section(L("Update playlists"), L("Channels, movies, series and the TV guide are refreshed in the background at this interval.")) {
                S2Dropdown(L("Update playlists"), RefreshPolicy.entries.map { it to it.title }, refreshPolicy) {
                    refreshPolicy = it; RefreshPolicy.current = it
                }
                val busy = Playlists.refreshingAll
                S2Row(L("Refresh all playlists now"), icon = Icons.Default.Refresh, enabled = !busy,
                    onClick = { AppScope.launch { runCatching { Playlists.refreshAll() } } },
                    trailing = { if (busy) CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(18.dp)) })
            }
        }

        // MARK: Trakt
        item {
            S2Section("Trakt", L("What you watch in Bingr is scrobbled automatically. What you've watched on Trakt (or in another app) is checked off here.")) {
                if (Trakt.isLoggedIn) {
                    S2Row(Trakt.displayName ?: Trakt.username ?: "Trakt", subtitle = Trakt.username, leading = {
                        Box(Modifier.size(tvs(52)).clip(CircleShape).background(Theme.elevated), contentAlignment = Alignment.Center) {
                            val a = Trakt.avatar
                            if (a != null) RemoteImage(a, Modifier.size(tvs(52)).clip(CircleShape))
                            else Icon(Icons.Default.Person, null, tint = Theme.secondary)
                        }
                    })
                    S2Toggle(L("Sync playback progress"), Trakt.scrobbleEnabled, icon = Icons.Default.Sync) { Trakt.scrobbleEnabled = it }
                    S2Toggle(L("Ask for ratings"), Trakt.askRating, icon = Icons.Default.Star) { Trakt.askRating = it }
                    S2Row(L("Watched"), value = L("%d movies · %d episodes", Trakt.watchedMovies.size,
                        Trakt.watchedEpisodes.values.sumOf { it.size }))
                    Trakt.lastRefresh?.let { S2Row(L("Last synced"), value = s2Time(it)) }
                    S2Row(L("Sync now"), icon = Icons.Default.Sync, onClick = { AppScope.launch { runCatching { Trakt.refresh(force = true) } } })
                    S2Row(L("Sign out of Trakt"), icon = Icons.AutoMirrored.Filled.Logout, tint = Theme.red, onClick = { Trakt.logout() })
                } else {
                    S2Row(L("Connect Trakt"), icon = Icons.Default.Link, onClick = {
                        if (Secrets.traktReady) showTraktLogin = true else setup = "trakt"
                    })
                }
                Trakt.lastError?.let { S2Row(it, tint = Theme.red) }
            }
        }

        // MARK: OpenSubtitles
        item {
            S2Section("OpenSubtitles", L("While playing, choose OpenSubtitles to pick another subtitle or language. Automatically uses a subtitle track in the stream first; otherwise the best match from OpenSubtitles is loaded (requires sign-in).")) {
                if (OpenSubtitles.isLoggedIn) {
                    S2Row(L("Signed in as"), value = OpenSubtitles.username ?: "")
                    OpenSubtitles.remainingDownloads?.let { S2Row(L("Downloads left today"), value = "$it") }
                    S2Row(L("Sign out"), icon = Icons.AutoMirrored.Filled.Logout, tint = Theme.red, onClick = {
                        AppScope.launch { runCatching { OpenSubtitles.logout() } }
                    })
                } else {
                    S2Row(L("Sign in to OpenSubtitles"), icon = Icons.Default.Subtitles, onClick = {
                        if (Secrets.openSubtitlesReady) showOSLogin = true else setup = "opensubtitles"
                    })
                }
                S2Dropdown(L("Default language"),
                    listOf("" to L("All languages")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    OpenSubtitles.defaultLanguage) { OpenSubtitles.defaultLanguage = it }
                S2Toggle(L("Load subtitles automatically when playing"), autoSubtitles) {
                    autoSubtitles = it; Prefs.put("autoSubtitles", it)
                }
            }
        }

        // MARK: speler
        item {
            S2Section(L("Player"), L("Automatic uses ExoPlayer for HLS, DASH and MP4 and VLC for everything else. If a stream fails, Bingr switches over and reconnects automatically. The default languages are chosen automatically when a stream has them.")) {
                S2Dropdown(L("Player engine"), listOf("auto" to L("Automatic"), "apple" to "ExoPlayer", "vlc" to "VLC"), engine) {
                    engine = it; Prefs.put("player.engine", it)
                }
                S2Dropdown(L("Default audio language"),
                    listOf("" to L("As in the stream")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    TrackPreferences.audio) { TrackPreferences.audio = it }
                S2Dropdown(L("Default subtitle language"),
                    listOf("" to L("As in the stream"), "off" to L("Off")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    TrackPreferences.subtitle) { TrackPreferences.subtitle = it }
            }
        }

        // MARK: kinderslot
        item {
            S2Section(L("Parental lock")) {
                val parental = Store.parental
                if (parental.enabled) {
                    val unlocked = ParentalControl.isUnlocked
                    S2Row(if (unlocked) L("Unlocked for 30 minutes") else L("Locked"),
                        icon = if (unlocked) Icons.Default.LockOpen else Icons.Default.Lock,
                        tint = if (unlocked) Theme.imdb else Theme.green)
                    if (unlocked) S2Row(L("Lock now"), tint = Theme.red, onClick = { ParentalControl.lock() })
                    else S2Row(L("Unlock with PIN"), tint = Theme.red, onClick = { pinMode = S2PinMode.UNLOCK })
                    if (source != null) {
                        val current = Store.playlists.firstOrNull { it.id == source.id } ?: source
                        S2Dropdown(L("Age limit for this profile"),
                            listOf(0 to L("None")) + ParentalControl.ageChoices.map { it to L("Up to %d years", it) },
                            current.ageLimit ?: 0, enabled = unlocked) { v ->
                            Store.upsert(current.copy(ageLimit = if (v == 0) null else v))
                        }
                        S2Row(if (unlocked) L("Titles above this age (IMDb rating) and adult groups are hidden on this profile. With the PIN you can still watch them.")
                            else L("Unlock with your PIN to change the age limit."), tint = Theme.secondary)
                    }
                    S2Toggle(L("Lock adult groups automatically"), parental.autoLockAdult) { v ->
                        Store.updateParental { it.copy(autoLockAdult = v) }
                    }
                    S2Row(L("Lock individual groups under Manage groups and channels (hold a group)."), tint = Theme.secondary)
                    S2Row(L("Change PIN"), tint = Theme.red, onClick = { pinMode = S2PinMode.SET })
                    S2Row(L("Turn off parental lock"), tint = Theme.red, onClick = { pinMode = S2PinMode.DISABLE })
                } else {
                    S2Row(L("Turn on parental lock"), icon = Icons.Default.Lock, onClick = { pinMode = S2PinMode.SET })
                }
            }
        }

        // MARK: weergave
        item {
            S2Section(L("Interface")) {
                S2Dropdown(L("Start screen"),
                    listOf(0 to L("Home"), 1 to L("Live TV"), 2 to L("Movies"), 3 to L("Series")), startTab) {
                    startTab = it; Prefs.put("ui.startTab", it)
                }
                S2Row(L("Categories on/off (NL, BE, DE…)"), icon = Icons.Default.FilterList, onClick = { sub = S2SettingsSub.CATEGORIES })
                S2Toggle(L("Show Live TV"), showLive) { showLive = it; Prefs.put("ui.showLive", it) }
                S2Toggle(L("Show Movies"), showMovies) { showMovies = it; Prefs.put("ui.showMovies", it) }
                S2Toggle(L("Show Series"), showSeries) { showSeries = it; Prefs.put("ui.showSeries", it) }
                S2Row(L("Rename, hide and reorder"), icon = Icons.Default.Tune, onClick = { sub = S2SettingsSub.MANAGE })
            }
        }

        // MARK: taal
        item {
            S2Section(L("Language")) {
                S2Dropdown(L("App language"), listOf("" to L("System")) + Localizer.supported, Localizer.override) {
                    Localizer.setOverride(it)
                }
            }
        }

        // MARK: delen tussen apparaten (vervangt iCloud)
        item {
            S2Section(L("Share between devices"),
                L("Export saves your playlists (incl. passwords), favorites, My List, watch progress, history and your changes to a file. Import it on another device to merge.")) {
                S2Row(L("Playlists"), value = "${Store.playlists.size}")
                S2Row(L("Watch progress"), value = L("%d titles", Store.progress.size))
                S2Row(L("Export to file"), icon = Icons.Default.Upload, onClick = {
                    if (!s2ExportBackup(ctx)) shareStatus = L("Export failed")
                })
                S2Row(L("Import from file"), icon = Icons.Default.Download, onClick = {
                    val ok = runCatching { importLauncher.launch(arrayOf("application/json", "text/*", "application/octet-stream")) }.isSuccess
                    if (!ok) shareStatus = L("Import failed")
                })
                shareStatus?.let { S2Row(it, tint = Theme.secondary) }
            }
        }

        // MARK: koppelingen
        item {
            S2Section(footer = L("Trakt and OpenSubtitles require a one-time app registration. Saved on this device; use Export to take them along.")) {
                S2Row(L("Set up connections"), icon = Icons.Default.Key, onClick = { setup = "all" })
            }
        }

        // MARK: over
        item {
            S2Section(L("About")) {
                S2Row(L("Version"), value = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                S2Row(L("IMDb data"), value = if (Secrets.isSet(Secrets.omdbAPIKey)) L("Active (OMDb)") else L("No OMDb key"))
            }
        }
    }

    // MARK: dialogen
    if (showTraktLogin) TraktLoginScreen { showTraktLogin = false }
    if (showOSLogin) OpenSubtitlesLoginScreen { showOSLogin = false }
    setup?.let { focus ->
        ConnectionsSetupScreen(focus) {
            setup = null
            when (focus) {
                "trakt" -> if (Secrets.traktReady && !Trakt.isLoggedIn) showTraktLogin = true
                "opensubtitles" -> if (Secrets.openSubtitlesReady && !OpenSubtitles.isLoggedIn) showOSLogin = true
            }
        }
    }
    when (pinMode) {
        S2PinMode.SET -> PinSetupScreen { pinMode = null }
        S2PinMode.UNLOCK -> PinPad(L("Enter PIN"), onDismiss = { pinMode = null }) { ParentalControl.verify(it) }
        S2PinMode.DISABLE -> PinPad(L("Enter PIN to turn off"), onDismiss = { pinMode = null }) { pin ->
            if (ParentalControl.verify(pin)) { Store.updateParental { it.copy(enabled = false) }; true } else false
        }
        null -> {}
    }
}
