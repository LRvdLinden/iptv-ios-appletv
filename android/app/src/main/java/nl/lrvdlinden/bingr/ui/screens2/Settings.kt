package nl.lrvdlinden.bingr

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Text
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.PersonAdd
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

/**
 * "Mijn Bingr": zelfde secties en volgorde als SettingsView.swift.
 * Profiel (wisselen/bewerken) voor iedereen; server, profielen, Trakt, kinderslot en beheer alleen voor het hoofdaccount.
 * Persoonlijke kijkvoorkeuren (ondertitels, talen) worden bij het actieve profiel bewaard.
 */
@Composable
fun SettingsScreen() {
    val ctx = LocalContext.current
    val listState = rememberLazyListState()
    var sub by remember { mutableStateOf<S2SettingsSub?>(null) }
    var editing by remember { mutableStateOf<PlaylistSource?>(null) }
    var addingServer by remember { mutableStateOf(false) }
    var deletingServer by remember { mutableStateOf<PlaylistSource?>(null) }
    var editingProfile by remember { mutableStateOf<ViewerProfile?>(null) }
    var addingProfile by remember { mutableStateOf(false) }
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
    val profileKey = Store.activeProfileID
    // kijkvoorkeuren horen bij het profiel: opnieuw lezen na wisselen van profiel
    var autoSubtitles by remember(profileKey) { mutableStateOf(Prefs.bool("autoSubtitles", false)) }
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
    if (addingServer) {
        AddPlaylistScreen(existing = null, onClose = { addingServer = false })
        return
    }
    val editingProfileNow = editingProfile
    if (editingProfileNow != null) {
        ProfileEditScreen(existing = editingProfileNow, onClose = { editingProfile = null })
        return
    }
    if (addingProfile) {
        ProfileEditScreen(existing = null, onClose = { addingProfile = false })
        return
    }

    val source = Playlists.source
    val lib = Playlists.library
    val profile = Store.activeProfile
    /** Hoofdaccount (of nog geen profielen): mag de server en alles instellen. */
    val isMain = Store.canManage

    S2Page(profile?.name ?: L("My Bingr"), onClose = null, state = listState) {
        // MARK: zoals "Mijn Netflix": profiel, Verder kijken, Mijn lijst, favoriete zenders
        item { S2MyBingrHeader() }

        // MARK: profiel
        item {
            S2Section(L("Profile"), if (!isMain) L("The server and all settings are managed in the main account.") else null) {
                if (profile != null) {
                    S2Row(profile.name,
                        subtitle = when {
                            Store.isMain(profile) -> L("Main account")
                            profile.effectiveAgeLimit != null -> L("Up to %d years", profile.effectiveAgeLimit ?: 0)
                            else -> null
                        },
                        leading = { ProfileAvatar(profile, tvs(44)) })
                    S2Row(L("Edit profile"), icon = Icons.Default.Edit, onClick = { editingProfile = profile })
                }
                S2Row(L("Switch profile"), icon = Icons.Default.SwapHoriz, onClick = { AppState.switchPlaylist() })
            }
        }

        if (isMain) {
            // MARK: server
            item {
                S2Section(L("Server"), L("The server, Trakt and OpenSubtitles belong to the main account and are used by all profiles.")) {
                    Store.playlists.forEach { src ->
                        val active = src.id == source?.id
                        S2Row(src.name, subtitle = src.kind.title,
                            leading = { AvatarCircle(src, tvs(34)) },
                            onLongClick = { editing = src },
                            onClick = { if (!active) AppState.open(src) },
                            trailing = { if (active) Icon(Icons.Default.Check, null, tint = Theme.red, modifier = Modifier.size(tvs(20))) })
                    }
                    if (source != null) {
                        val current = Store.playlists.firstOrNull { it.id == source.id } ?: source
                        S2Row(L("%@ · %d channels · %d movies · %d series", current.kind.title,
                            lib.channels.size, lib.movies.size, lib.series.size), tint = Theme.secondary)
                        S2Row(L("Edit server"), icon = Icons.Default.Dns, onClick = { editing = current })
                        S2Row(L("Categories on/off (NL, BE, DE…)"), icon = Icons.Default.FilterList, onClick = { sub = S2SettingsSub.CATEGORIES })
                        S2Row(L("Manage groups and channels"), icon = Icons.Default.Tune, onClick = { sub = S2SettingsSub.MANAGE })
                        S2Row(L("Refresh now"), icon = Icons.Default.Refresh, onClick = {
                            AppScope.launch { runCatching { Playlists.select(current, forceRefresh = true) } }
                        })
                    }
                    S2Row(L("Add server"), icon = Icons.Default.Add, onClick = { addingServer = true })
                    if (source != null) {
                        val current = Store.playlists.firstOrNull { it.id == source.id } ?: source
                        S2Row(L("Delete server"), icon = Icons.Default.Delete, tint = Theme.red, onClick = { deletingServer = current })
                    }
                }
            }

            // MARK: profielen
            item {
                S2Section(L("Profiles"), L("Each profile uses the same server, with its own My List, Continue watching, favorites, history and age limit.")) {
                    Store.profiles.forEach { p ->
                        S2Row(p.name,
                            subtitle = if (Store.isMain(p)) L("Main account")
                                else p.effectiveAgeLimit?.let { L("Up to %d years", it) } ?: L("Profile"),
                            leading = { ProfileAvatar(p, tvs(34)) },
                            onClick = { editingProfile = p },
                            trailing = {
                                if (ParentalControl.hasPIN(p)) Icon(Icons.Default.Lock, null, tint = Theme.secondary, modifier = Modifier.size(tvs(16)))
                                Icon(Icons.Default.Edit, null, tint = Theme.secondary, modifier = Modifier.size(tvs(18)))
                            })
                    }
                    if (Store.profiles.size < 8) {
                        S2Row(L("Add profile"), icon = Icons.Default.PersonAdd, onClick = { addingProfile = true })
                    }
                }
            }
        }

        // MARK: bibliotheek
        item {
            S2Section(L("Library"), L("Watch history is kept per profile. Plex, Jellyfin and Emby can be added as a playlist.")) {
                S2Row(L("Watch history"), icon = Icons.Default.History, onClick = { sub = S2SettingsSub.HISTORY })
                if (isMain) S2Row(L("NAS & network (SMB/DLNA)"), icon = Icons.Default.Lan, onClick = { sub = S2SettingsSub.NAS })
            }
        }

        if (isMain) {
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
                        Trakt.lastScrobble?.let { m ->
                            S2Row(L("Last sent"), subtitle = m + (Trakt.lastScrobbleDate?.let { " · " + s2Time(it) } ?: ""))
                        }
                        val syncing = Trakt.isSyncing
                        S2Row(
                            when {
                                syncing -> L("Syncing…")
                                Trakt.justSynced -> L("Up to date")
                                else -> L("Sync now")
                            },
                            icon = if (Trakt.justSynced) Icons.Default.CheckCircle else Icons.Default.Sync,
                            enabled = !syncing,
                            onClick = { s2TraktSyncNow() },
                            trailing = {
                                if (syncing) CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                            })
                        S2Row(L("Sign out of Trakt"), icon = Icons.AutoMirrored.Filled.Logout, tint = Theme.red, onClick = { Trakt.logout() })
                    } else {
                        S2Row(L("Connect Trakt"), icon = Icons.Default.Link, onClick = {
                            if (Secrets.traktReady) showTraktLogin = true else setup = "trakt"
                        })
                    }
                    Trakt.lastError?.let { S2Row(it, tint = Theme.red) }
                }
            }
        }

        // MARK: OpenSubtitles
        item {
            S2Section("OpenSubtitles", L("While playing, choose OpenSubtitles to pick another subtitle or language. Automatically uses a subtitle track in the stream first; otherwise the best match from OpenSubtitles is loaded (requires sign-in).") +
                " " + L("These choices apply to this profile only.")) {
                if (OpenSubtitles.isLoggedIn) {
                    S2Row(L("Signed in as"), value = OpenSubtitles.username ?: "")
                    OpenSubtitles.remainingDownloads?.let { S2Row(L("Downloads left today"), value = "$it") }
                    if (isMain) {
                        S2Row(L("Sign out"), icon = Icons.AutoMirrored.Filled.Logout, tint = Theme.red, onClick = {
                            AppScope.launch { runCatching { OpenSubtitles.logout() } }
                        })
                    }
                } else if (isMain) {
                    S2Row(L("Sign in to OpenSubtitles"), icon = Icons.Default.Subtitles, onClick = {
                        if (Secrets.openSubtitlesReady) showOSLogin = true else setup = "opensubtitles"
                    })
                }
                S2Dropdown(L("Default language"),
                    listOf("" to L("All languages")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    OpenSubtitles.defaultLanguage) { v ->
                    OpenSubtitles.defaultLanguage = v
                    Store.updateActivePreferences { it.copy(subtitleLanguage = v) }
                }
                S2Toggle(L("Load subtitles automatically when playing"), autoSubtitles) { v ->
                    autoSubtitles = v; Prefs.put("autoSubtitles", v)
                    Store.updateActivePreferences { it.copy(autoSubtitles = v) }
                }
            }
        }

        // MARK: speler
        item {
            S2Section(L("Player"), L("Automatic uses ExoPlayer for HLS, DASH and MP4 and VLC for everything else. If a stream fails, Bingr switches over and reconnects automatically. The default languages are chosen automatically when a stream has them.")) {
                S2Dropdown(L("Player engine"), listOf("auto" to L("Automatic"), "apple" to "ExoPlayer", "vlc" to "VLC"), engine) {
                    engine = it; Prefs.put("player.engine", it)
                }
                // Prefs "subtitle.size": 0 klein, 1 middel, 2 groot (ook tijdens het afspelen bij Opties)
                S2Dropdown(L("Subtitle size"), SubtitleSize.entries.map { it to it.title }, SubtitleSize.current) {
                    SubtitleSize.current = it
                }
                S2Dropdown(L("Default audio language"),
                    listOf("" to L("As in the stream")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    TrackPreferences.audio) { v ->
                    TrackPreferences.audio = v
                    Store.updateActivePreferences { it.copy(audioLanguage = v) }
                }
                S2Dropdown(L("Default subtitle language"),
                    listOf("" to L("As in the stream"), "off" to L("Off")) + TrackPreferences.sortedCodes.map { it to TrackPreferences.label(it) },
                    TrackPreferences.subtitle) { v ->
                    TrackPreferences.subtitle = v
                    Store.updateActivePreferences { it.copy(streamSubtitleLanguage = v) }
                }
            }
        }

        // MARK: pincode (per profiel) + kinderslot (hoofdaccount)
        item {
            S2Section(L("PIN code"), L("With a PIN, the profile asks for the code when it is chosen in “Who's watching?”.")) {
                if (profile != null) {
                    val has = ParentalControl.hasPIN(profile)
                    S2Row(if (has) L("This profile is protected with a PIN") else L("No PIN on this profile"),
                        icon = if (has) Icons.Default.Lock else Icons.Default.LockOpen,
                        tint = if (has) Theme.green else Theme.secondary)
                    if (has) {
                        S2Row(L("Change PIN"), onClick = { pinMode = S2PinMode.SET })
                        S2Row(L("Remove PIN"), tint = Theme.red, onClick = { pinMode = S2PinMode.DISABLE })
                    } else {
                        S2Row(L("Set PIN"), icon = Icons.Default.Lock, onClick = { pinMode = S2PinMode.SET })
                    }
                }
                val mainHasPIN = profile?.let { ParentalControl.hasPIN(it) } ?: ParentalControl.hasPIN
                if (isMain && mainHasPIN) {
                    val parental = Store.parental
                    S2Toggle(L("Lock adult content with this PIN"), parental.enabled) { v ->
                        Store.updateParental { it.copy(enabled = v) }
                    }
                    if (parental.enabled) {
                        S2Toggle(L("Lock adult groups automatically"), parental.autoLockAdult) { v ->
                            Store.updateParental { it.copy(autoLockAdult = v) }
                        }
                        val unlocked = ParentalControl.isUnlocked
                        S2Row(if (unlocked) L("Unlocked for 30 minutes") else L("Locked"),
                            icon = if (unlocked) Icons.Default.LockOpen else Icons.Default.Lock,
                            tint = if (unlocked) Theme.imdb else Theme.green)
                        if (unlocked) S2Row(L("Lock now"), tint = Theme.red, onClick = { ParentalControl.lock() })
                        else S2Row(L("Unlock with PIN"), tint = Theme.red, onClick = { pinMode = S2PinMode.UNLOCK })
                        S2Row(L("Lock individual groups under Manage groups and channels (hold a group). Set age limits per profile under Profiles."),
                            tint = Theme.secondary)
                    }
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
                if (isMain) S2Row(L("Categories on/off (NL, BE, DE…)"), icon = Icons.Default.FilterList, onClick = { sub = S2SettingsSub.CATEGORIES })
                S2Toggle(L("Show Live TV"), showLive) { showLive = it; Prefs.put("ui.showLive", it) }
                S2Toggle(L("Show Movies"), showMovies) { showMovies = it; Prefs.put("ui.showMovies", it) }
                S2Toggle(L("Show Series"), showSeries) { showSeries = it; Prefs.put("ui.showSeries", it) }
                if (isMain) S2Row(L("Rename, hide and reorder"), icon = Icons.Default.Tune, onClick = { sub = S2SettingsSub.MANAGE })
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

        if (isMain) {
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
    deletingServer?.let { src ->
        S2ActionDialog(
            L("Profiles keep their own lists. Channels, movies and series of this server disappear from the app."),
            listOf(S2Action(L("Delete %@", src.name), Icons.Default.Delete, destructive = true) {
                val wasActive = Playlists.source?.id == src.id
                Playlists.forget(src)
                if (wasActive) {
                    val next = Store.mainSource
                    if (next != null) AppState.open(next) else AppState.switchPlaylist()
                }
            }),
            onDismiss = { deletingServer = null }
        )
    }
    val prof = Store.activeProfile
    when (pinMode) {
        S2PinMode.SET -> PinSetupScreen(profileID = prof?.id) { pinMode = null }
        S2PinMode.UNLOCK -> PinPad(L("Enter PIN"), onDismiss = { pinMode = null }) { pin ->
            if (prof != null) ParentalControl.verify(pin, prof) else ParentalControl.verify(pin)
        }
        S2PinMode.DISABLE -> PinPad(L("Enter PIN to turn off"), onDismiss = { pinMode = null }) { pin ->
            if (prof == null) {
                if (ParentalControl.verify(pin)) { ParentalControl.setPIN(null); Store.updateParental { it.copy(enabled = false) }; true } else false
            } else if (ParentalControl.verify(pin, prof)) {
                ParentalControl.setPIN(null, prof)
                if (Store.isMain(prof)) Store.updateParental { it.copy(enabled = false) }
                true
            } else false
        }
        null -> {}
    }
}

/** Trakt nu synchroniseren (draaiende pijltjes zolang [Trakt.isSyncing]). */
private fun s2TraktSyncNow() {
    if (Trakt.isSyncing) return
    AppScope.launch { runCatching { Trakt.refresh(force = true) } }
}

/** Verder kijken van dít profiel: per serie alleen de laatste aflevering (= MyBingrHeader.swift). */
private class S2ContinueEntry(val id: String, val target: DetailTarget, val entry: ProgressEntry)

/**
 * Bovenkant van Mijn Bingr, zoals "Mijn Netflix": je profiel (tik = wisselen), Trakt-status,
 * en daaronder Verder kijken, Mijn lijst en favoriete zenders (= MyBingrHeader.swift).
 */
@Composable
private fun S2MyBingrHeader() {
    val lib = Playlists.library
    val pid = Playlists.source?.id
    val index = rememberHomeIndex(lib)
    val profile = Store.activeProfile
    val progress = Store.progress
    var choice by remember { mutableStateOf<ResumeChoice?>(null) }

    val cont = remember(progress, index, pid, Store.activeProfileID) {
        val seen = HashSet<String>()
        progress.entries
            .filter { Store.belongsToActive(it.value.profileID) && (it.value.playlistID == null || it.value.playlistID == pid) }
            .sortedByDescending { it.value.updated }
            .mapNotNull { (k, e) ->
                val t: DetailTarget = index.movieByID[k]?.let { DetailTarget.MovieT(it) }
                    ?: index.seriesByTitle[e.title]?.let { DetailTarget.SeriesT(it) } ?: return@mapNotNull null
                if (!seen.add(t.id)) return@mapNotNull null
                S2ContinueEntry(k, t, e)
            }
            .take(20)
    }
    val myList = Store.myList
    val mine = remember(myList, index, pid) {
        if (pid == null) emptyList<DetailTarget>()
        else {
            val movies: List<DetailTarget> = myList.mapNotNull { k -> index.movie(k, pid) }.sortedBy { it.title }.map { DetailTarget.MovieT(it) }
            val series: List<DetailTarget> = myList.mapNotNull { k -> index.series(k, pid) }.sortedBy { it.title }.map { DetailTarget.SeriesT(it) }
            movies + series
        }
    }
    val favorites = Store.favorites
    val favs = remember(favorites, index, pid) {
        if (pid == null) emptyList<Channel>() else favorites.mapNotNull { index.channel(it, pid) }
    }

    Column(Modifier.fillMaxWidth().padding(vertical = tvs(8)), verticalArrangement = Arrangement.spacedBy(tvs(18))) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tvs(8))) {
            ProfileAvatar(profile, tvs(84))
            var focused by remember { mutableStateOf(false) }
            Row(
                Modifier.onFocusChanged { focused = it.isFocused }
                    .focusLift(1.06f) { AppState.switchPlaylist() }
                    .clip(RoundedCornerShape(50))
                    .background(if (focused && AppState.isTV) Color.White else Color.Transparent)
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val fg = if (focused && AppState.isTV) Color.Black else Color.White
                Text(profile?.name ?: L("My Bingr"), color = fg, fontSize = tsp(20), fontWeight = FontWeight.Bold, maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Icon(Icons.Default.KeyboardArrowDown, L("Switch profile"), tint = fg, modifier = Modifier.size(tvs(18)))
            }
            if (Trakt.isLoggedIn) S2TraktStatus()
        }

        if (cont.isNotEmpty()) {
            MediaRow(L("Continue watching")) {
                items(cont) { c ->
                    val e = c.entry
                    val left = maxOf(0.0, e.position / maxOf(e.fraction, 0.01) - e.position)
                    ContinueCard(
                        e.title, e.artwork ?: c.target.poster, e.fraction, L("%d min left", (left / 60).toInt()),
                        Modifier.focusLift {
                            choice = ResumeChoice(c.id, e.title, e.fraction, if (e.position > 0) e.position else null, c.target)
                        }
                    )
                }
            }
        }
        if (mine.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edge), verticalArrangement = Arrangement.spacedBy(tvs(8))) {
                Text(L("My List"), color = Color.White, fontSize = Theme.titleSize, fontWeight = FontWeight.Bold)
                Text(L("Add titles with + My List and they'll appear here."), color = Theme.secondary, fontSize = tsp(13))
            }
        } else {
            MediaRow(L("My List"), onSeeAll = { ScreensNav.category(CategoryTarget(L("My List"), mine)) }) {
                items(mine) { t ->
                    val watched = (t as? DetailTarget.MovieT)?.let { Playables.isWatched(it.movie, Trakt.imdb(it.movie)) } ?: false
                    PosterCard(t.title, t.poster, modifier = Modifier.focusLift { ScreensNav.detail(t) },
                        watched = watched, progress = progress[t.id]?.fraction)
                }
            }
        }
        if (favs.isNotEmpty()) {
            MediaRow(L("Favorite channels")) {
                items(favs) { c ->
                    val now = lib.nowPlaying(c)
                    ChannelCard(c, now, favorite = true,
                        modifier = Modifier.focusLift { AppState.play(Playables.channel(c, now), favs) })
                }
            }
        }
    }
    choice?.let { ResumeDialog(it) { choice = null } }
}

/** Trakt-status: draaiende pijltjes tijdens synchroniseren, anders de laatste sync; tik = nu synchroniseren. */
@Composable
private fun S2TraktStatus() {
    val syncing = Trakt.isSyncing
    var focused by remember { mutableStateOf(false) }
    val lit = focused && AppState.isTV
    Row(
        Modifier.onFocusChanged { focused = it.isFocused }
            .focusLift(1.05f) { s2TraktSyncNow() }
            .clip(RoundedCornerShape(50))
            .background(if (lit) Color.White else Color.Transparent)
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (syncing) {
            CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(tvs(14)))
        } else {
            val ok = Trakt.lastError == null
            Icon(if (ok) Icons.Default.CheckCircle else Icons.Default.Warning, null,
                tint = if (ok) Theme.green else Theme.red, modifier = Modifier.size(tvs(14)))
        }
        Spacer(Modifier.width(6.dp))
        val text = when {
            syncing -> L("Syncing with Trakt…")
            Trakt.justSynced -> L("Up to date")
            else -> Trakt.lastRefresh?.let { L("Trakt synced %@", s2Time(it)) } ?: L("Sync now")
        }
        Text(text, color = if (lit) Color.Black else Theme.secondary, fontSize = tsp(12), fontWeight = FontWeight.Medium, maxLines = 1)
    }
}
