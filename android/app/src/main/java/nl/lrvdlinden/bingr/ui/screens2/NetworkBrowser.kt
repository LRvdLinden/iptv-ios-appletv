package nl.lrvdlinden.bingr

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.MediaBrowser

/** Item op het netwerk: map of bestand. */
data class S2NetEntry(val name: String, val uri: String, val isFolder: Boolean) {
    val ext: String get() = Uri.parse(uri).lastPathSegment?.substringAfterLast('.', "")?.lowercase() ?: ""
    val isVideo: Boolean get() = !isFolder && (ext.isEmpty() || ext in videoExtensions)

    companion object {
        val videoExtensions = setOf("mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "wmv", "mpg",
            "mpeg", "webm", "flv", "vob", "iso", "3gp", "ogv", "divx", "rmvb")

        fun from(media: IMedia): S2NetEntry? {
            val u = media.uri ?: return null
            val title = runCatching { media.getMeta(IMedia.Meta.Title) }.getOrNull()
            val last = u.lastPathSegment ?: u.host ?: u.toString()
            val name = if (!title.isNullOrBlank()) title else last
            val s = u.toString()
            val folder = media.type == IMedia.Type.Directory ||
                (media.type == IMedia.Type.Unknown && s.endsWith("/"))
            return S2NetEntry(name, s, folder)
        }
    }
}

/** smb://gebruiker:wachtwoord@host/share/ */
fun s2NASUri(s: NASServer): String {
    val host = s.host.trim()
    val share = s.share.trim().trim('/', ' ')
    val cred = if (s.username.isNotBlank()) {
        val pw = Store.secret(s.passwordKey)
        Uri.encode(s.username.trim()) + (if (!pw.isNullOrEmpty()) ":" + Uri.encode(pw) else "") + "@"
    } else ""
    return "smb://$cred$host/" + (if (share.isEmpty()) "" else "${Uri.encode(share, "/")}/")
}

/** Inloggegevens van de map-URL ook aan het bestand meegeven (VLC vraagt er anders opnieuw om). */
private fun s2WithCredentials(file: String, base: String): String {
    val f = Uri.parse(file)
    val b = Uri.parse(base)
    if (f.userInfo != null || b.userInfo == null || f.host != b.host) return file
    return f.buildUpon().encodedAuthority(b.encodedUserInfo + "@" + f.encodedAuthority).build().toString()
}

/** Gedeelde LibVLC voor het bladeren (wordt pas na het sluiten van alle bladers vrijgegeven). */
private class S2BrowseSession(ctx: Context) {
    val libVLC: LibVLC? = runCatching { LibVLC(ctx.applicationContext, arrayListOf("--no-sub-autodetect-file")) }.getOrNull()
    fun release() { Handler(Looper.getMainLooper()).post { runCatching { libVLC?.release() } } }
}

/**
 * Bladert via LibVLC's [MediaBrowser]; [uri] = null → netwerk afzoeken (UPnP/DLNA, SMB …).
 * Resultaten komen in [items]; [loading] wordt false bij onBrowseEnd.
 */
private class S2Browser(libVLC: LibVLC, private val uri: String?) {
    val items = mutableStateListOf<S2NetEntry>()
    var loading by mutableStateOf(true)
    private val main = Handler(Looper.getMainLooper())
    private var browser: MediaBrowser? = null

    init {
        val listener = object : MediaBrowser.EventListener {
            override fun onMediaAdded(index: Int, media: IMedia) {
                val e = S2NetEntry.from(media) ?: return
                main.post { if (items.none { it.uri == e.uri }) items.add(e) }
            }
            override fun onMediaRemoved(index: Int, media: IMedia) {
                val u = media.uri?.toString() ?: return
                main.post { items.removeAll { it.uri == u } }
            }
            override fun onBrowseEnd() { main.post { loading = false } }
        }
        browser = runCatching { MediaBrowser(libVLC, listener) }.getOrNull()
        runCatching {
            if (uri == null) browser?.discoverNetworkShares()
            else browser?.browse(Uri.parse(uri), MediaBrowser.Flag.NoSlavesAutodetect)
        }.onFailure { loading = false }
        if (browser == null) loading = false
        if (uri != null) main.postDelayed({ loading = false }, 20_000)
    }

    fun release() {
        main.removeCallbacksAndMessages(null)
        runCatching { browser?.release() }
        browser = null
    }
}

private data class S2Folder(val title: String, val uri: String)

/** NAS & netwerk: gevonden servers, eigen SMB-servers, bladeren en afspelen. */
@Composable
fun NetworkBrowserScreen(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val session = remember { S2BrowseSession(ctx) }
    DisposableEffect(Unit) { onDispose { session.release() } }
    var stack by remember { mutableStateOf(listOf<S2Folder>()) }
    var editing by remember { mutableStateOf<NASServer?>(null) }
    var menuFor by remember { mutableStateOf<NASServer?>(null) }

    val lib = session.libVLC
    val top = stack.lastOrNull()
    if (top != null && lib != null) {
        S2NetworkFolder(lib, top, onBack = { stack = stack.dropLast(1) }, onOpen = { stack = stack + it })
    } else {
        val discovery = remember(lib) { lib?.let { S2Browser(it, null) } }
        DisposableEffect(discovery) { onDispose { discovery?.release() } }
        val found = discovery?.items?.sortedBy { it.name.lowercase() } ?: emptyList()
        val servers = Store.nasServers
        S2Page(L("NAS & network"), onClose = onClose) {
            item { S2Header(L("Found on your network")) }
            if (found.isEmpty()) item {
                Column(Modifier.s2Cell(0, 1)) {
                    S2Row(L("Searching your network…"), tint = Theme.secondary, leading = {
                        CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    })
                }
            }
            itemsIndexed(found) { i, e ->
                Column(Modifier.s2Cell(i, found.size)) {
                    S2Row(e.name, icon = if (e.uri.startsWith("smb")) Icons.Default.Storage else Icons.Default.Dns,
                        onClick = { stack = stack + S2Folder(e.name, e.uri) })
                }
            }
            item { S2Footer(L("Media servers (DLNA/UPnP) and shared folders (SMB) on your Wi-Fi network.")) }

            item { S2Header(L("Your servers")) }
            itemsIndexed(servers) { i, s ->
                Column(Modifier.s2Cell(i, servers.size + 1)) {
                    S2Row(s.name, subtitle = "smb://${s.host}/${s.share}", icon = Icons.Default.Storage,
                        onLongClick = { menuFor = s },
                        onClick = { stack = stack + S2Folder(s.name, s2NASUri(s)) },
                        trailing = { S2MoreButton { menuFor = s } })
                }
            }
            item {
                Column(Modifier.s2Cell(servers.size, servers.size + 1)) {
                    S2Row(L("Add SMB server"), icon = Icons.Default.Add, tint = Theme.red,
                        onClick = { editing = NASServer(name = "", host = "") })
                }
            }
        }
    }

    menuFor?.let { s ->
        S2ActionDialog(s.name, listOf(
            S2Action(L("Edit"), Icons.Default.Edit) { editing = s },
            S2Action(L("Delete"), Icons.Default.Delete, destructive = true) {
                Store.setSecret(s.passwordKey, null)
                Store.saveNAS(Store.nasServers.filterNot { it.id == s.id })
            },
        ), onDismiss = { menuFor = null })
    }
    editing?.let { s ->
        S2NASServerForm(s, onDismiss = { editing = null }) { saved ->
            val list = Store.nasServers
            Store.saveNAS(if (list.any { it.id == saved.id }) list.map { if (it.id == saved.id) saved else it } else list + saved)
        }
    }
}

@Composable
private fun S2NetworkFolder(lib: LibVLC, folder: S2Folder, onBack: () -> Unit, onOpen: (S2Folder) -> Unit) {
    val browser = remember(folder.uri) { S2Browser(lib, folder.uri) }
    DisposableEffect(browser) { onDispose { browser.release() } }
    val items = browser.items.filter { it.isFolder || it.isVideo }.sortedWith(
        compareBy<S2NetEntry> { !it.isFolder }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    val loading = browser.loading && items.isEmpty()

    fun play(e: S2NetEntry) {
        val u = s2WithCredentials(e.uri, folder.uri)
        val name = e.name.substringBeforeLast('.', e.name)
        AppState.play(PlayableItem(id = "nas-${e.uri}", title = name, subtitle = folder.title, url = u, type = MediaType.MOVIE))
    }

    S2Page(folder.title, onClose = onBack) {
        item { Spacer(Modifier.padding(top = 8.dp)) }
        when {
            loading -> item {
                Column(Modifier.s2Cell(0, 1)) {
                    S2Row(L("Loading…"), tint = Theme.secondary, leading = {
                        CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    })
                }
            }
            items.isEmpty() && !browser.loading -> item {
                Column(Modifier.s2Cell(0, 1)) {
                    S2Row(if (browser.items.isEmpty()) L("This folder couldn't be opened. Check the address, username and password.")
                        else L("No videos in this folder."), tint = Theme.secondary)
                }
            }
        }
        itemsIndexed(items) { i, e ->
            Column(Modifier.s2Cell(i, items.size)) {
                S2Row(e.name, icon = if (e.isFolder) Icons.Default.Folder else Icons.Default.PlayCircle, onClick = {
                    if (e.isFolder) onOpen(S2Folder(e.name, s2WithCredentials(e.uri, folder.uri))) else play(e)
                })
            }
        }
    }
}

/** Eigen SMB-server toevoegen/bewerken. */
@Composable
private fun S2NASServerForm(server: NASServer, onDismiss: () -> Unit, onSave: (NASServer) -> Unit) {
    var name by remember { mutableStateOf(server.name) }
    var host by remember { mutableStateOf(server.host) }
    var share by remember { mutableStateOf(server.share) }
    var user by remember { mutableStateOf(server.username) }
    var password by remember { mutableStateOf(Store.secret(server.passwordKey) ?: "") }
    S2FullDialog(onDismiss) {
        S2Page(L("SMB server"), onClose = onDismiss) {
            item {
                S2Section {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        S2TextField(name, { name = it }, L("Name"), plain = false)
                        S2TextField(host, { host = it }, L("Address (e.g. 192.168.1.10)"))
                        S2TextField(share, { share = it }, L("Share / folder (optional)"))
                    }
                }
            }
            item {
                S2Section(footer = L("Leave empty for guest access.")) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        S2TextField(user, { user = it }, L("Username (optional)"))
                        S2TextField(password, { password = it }, L("Password"), password = true)
                    }
                }
            }
            item {
                S2Section {
                    val ok = host.isNotBlank()
                    S2Row(L("Save"), tint = if (ok) Theme.red else Theme.secondary, enabled = ok, onClick = {
                        val saved = server.copy(name = name.trim().ifEmpty { host.trim() }, host = host.trim(),
                            share = share.trim(), username = user.trim())
                        Store.setSecret(saved.passwordKey, if (password.isEmpty()) null else password)
                        onSave(saved)
                        onDismiss()
                    })
                }
            }
        }
    }
}
