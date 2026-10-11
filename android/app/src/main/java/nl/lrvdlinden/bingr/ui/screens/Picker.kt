package nl.lrvdlinden.bingr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

// MARK: profielkeuze ("Wie kijkt er?")

/** "Wat wil je kijken?" — ronde avatars, Toevoegen en Beheren (= PlaylistPickerView.swift). */
@Composable
fun PlaylistPickerScreen() {
    val tv = AppState.isTV
    val playlists = Store.playlists
    var managing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<PlaylistSource?>(null) }
    var adding by remember { mutableStateOf(false) }
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val overlay = adding || editing != null
    val firstFocus = rememberInitialFocus(enabled = tv && !overlay, key = overlay)

    if (playlists.isEmpty() && managing) managing = false
    BackHandler(enabled = managing && !overlay) { managing = false }

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().blockFocus(overlay),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Theme.edge).padding(top = tvs(8)),
                verticalAlignment = Alignment.CenterVertically
            ) {
                BingrLogo(tsp(26))
                Spacer(Modifier.weight(1f))
                if (playlists.isNotEmpty()) {
                    Text(
                        if (managing) L("Done") else L("Manage"), color = Color.White, fontSize = tsp(15),
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.focusLift(1.08f, dimWhenIdle = true) { managing = !managing }.padding(8.dp)
                    )
                }
            }

            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val minH = maxHeight
                val avatarSize: Dp = if (tv) 150.dp else 104.dp
                val gap: Dp = if (tv) 48.dp else 22.dp
                val usable = (maxWidth - Theme.edge * 2).coerceAtMost(if (tv) 900.dp else 620.dp)
                val perRow = ((usable + gap) / (avatarSize + 16.dp + gap)).toInt().coerceIn(1, 6)
                Column(
                    Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = minH)
                        .padding(vertical = tvs(16)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Text(
                        when {
                            playlists.isEmpty() -> L("Welcome to Bingr")
                            managing -> L("Manage playlists")
                            else -> L("What do you want to watch?")
                        },
                        color = Color.White, fontSize = tsp(26), fontWeight = FontWeight.Medium, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = Theme.edge)
                    )
                    if (playlists.isEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            L("Add your first playlist: M3U, Xtream Codes, a MAC portal, Plex, Jellyfin, Emby or Stremio."),
                            color = Theme.secondary, fontSize = tsp(14), textAlign = TextAlign.Center,
                            modifier = Modifier.padding(horizontal = Theme.edge)
                        )
                    }
                    Spacer(Modifier.height(tvs(26)))

                    // profielen + "Toevoegen" in rijen
                    val tiles: List<PlaylistSource?> = playlists + listOf<PlaylistSource?>(null)
                    tiles.chunked(perRow).forEachIndexed { rowIndex, row ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(gap, Alignment.CenterHorizontally),
                            modifier = Modifier.fillMaxWidth().padding(bottom = tvs(22))
                        ) {
                            row.forEachIndexed { col, p ->
                                val index = rowIndex * perRow + col
                                ProfileTile(
                                    playlist = p,
                                    size = avatarSize,
                                    editing = managing && p != null,
                                    index = index,
                                    appeared = appeared,
                                    requester = if (index == 0) firstFocus else null,
                                    onClick = {
                                        when {
                                            p == null -> adding = true
                                            managing -> editing = p
                                            else -> AppState.open(p)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }

            Row(
                Modifier.padding(bottom = tvs(10)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                val c = Theme.secondary.copy(alpha = 0.7f)
                Icon(if (tv) Icons.Default.Tv else Icons.Default.PhoneAndroid, null, tint = c, modifier = Modifier.size(tvs(13)))
                Text(L("On this device"), color = c, fontSize = tsp(11))
            }
        }

        if (adding) {
            FullLayer { AddPlaylistScreen(existing = null, onClose = { adding = false }) }
        }
        editing?.let { p ->
            FullLayer { AddPlaylistScreen(existing = p, onClose = { editing = null }) }
        }
    }
}

@Composable
private fun ProfileTile(
    playlist: PlaylistSource?,
    size: Dp,
    editing: Boolean,
    index: Int,
    appeared: Boolean,
    requester: FocusRequester?,
    onClick: () -> Unit,
) {
    val tv = AppState.isTV
    var focused by remember { mutableStateOf(false) }
    val a by animateFloatAsState(if (appeared) 1f else 0f, tween(450, delayMillis = index * 60), label = "appear")
    val lit = tv && focused
    Column(
        Modifier
            .width(size + 16.dp)
            .graphicsLayer { alpha = a; translationY = (1f - a) * 24.dp.toPx() }
            .then(if (requester != null) Modifier.focusRequester(requester) else Modifier)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(if (tv) 1.12f else 1.04f, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (playlist != null) {
            AvatarCircle(playlist, size, ring = lit, editing = editing)
        } else {
            Box(
                Modifier.size(size).clip(CircleShape)
                    .background(if (lit) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                    .border(if (lit) 3.dp else 2.dp, if (lit) Color.White else Theme.secondary.copy(alpha = 0.5f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.Add, null, tint = if (lit) Color.White else Theme.secondary, modifier = Modifier.size(size * 0.36f))
            }
        }
        Spacer(Modifier.height(tvs(10)))
        Text(
            playlist?.name ?: L("Add"),
            color = if (lit) Color.White else Theme.secondary,
            fontWeight = if (lit) FontWeight.Bold else FontWeight.Normal,
            fontSize = tsp(14), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center
        )
    }
}

// MARK: afspeellijst toevoegen / bewerken

private val PlaylistKind.icon: ImageVector
    get() = when (this) {
        PlaylistKind.M3U -> Icons.Default.Link
        PlaylistKind.XTREAM -> Icons.Default.Dns
        PlaylistKind.STALKER -> Icons.Default.Router
        PlaylistKind.PLEX -> Icons.Default.PlayCircle
        PlaylistKind.JELLYFIN -> Icons.Default.Storage
        PlaylistKind.EMBY -> Icons.Default.Cloud
        PlaylistKind.STREMIO -> Icons.Default.Extension
    }

private fun isUrl(s: String): Boolean = runCatching {
    val u = java.net.URI(s.trim())
    !u.scheme.isNullOrEmpty() && !u.host.isNullOrEmpty()
}.getOrDefault(false)

/** Vierkant uitsnijden en verkleinen tot ±400 px JPEG. */
private fun thumbnail(ctx: Context, uri: Uri): ByteArray? = runCatching<ByteArray?> {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    ctx.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= 400 && bounds.outHeight / (sample * 2) >= 400) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    val bmp = ctx.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return@runCatching null
    val side = minOf(bmp.width, bmp.height)
    val square = Bitmap.createBitmap(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side)
    val target = minOf(400, side)
    val scaled = Bitmap.createScaledBitmap(square, target, target, true)
    val out = ByteArrayOutputStream()
    scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
    out.toByteArray()
}.getOrNull()

/** Afspeellijst toevoegen/bewerken — naam, avatar (emoji + kleur), foto en verbindingsgegevens (= AddPlaylistView.swift). */
@Composable
fun AddPlaylistScreen(existing: PlaylistSource?, onClose: () -> Unit) {
    val tv = AppState.isTV
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var kind by remember { mutableStateOf(existing?.kind ?: PlaylistKind.M3U) }
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var avatar by remember { mutableStateOf(existing?.avatar ?: PlaylistAvatar.random()) }
    var m3uURL by remember { mutableStateOf(existing?.m3uURL ?: "") }
    var epgURL by remember { mutableStateOf(existing?.epgURL ?: "") }
    var server by remember { mutableStateOf(existing?.serverURL ?: "") }
    var username by remember { mutableStateOf(existing?.username ?: "") }
    var password by remember {
        mutableStateOf(
            existing?.takeIf { it.kind != PlaylistKind.STREMIO && it.kind != PlaylistKind.PLEX }
                ?.let { Store.secret(it.passwordKey) } ?: ""
        )
    }
    var plexToken by remember {
        mutableStateOf(existing?.takeIf { it.kind == PlaylistKind.PLEX }?.let { Store.secret(it.passwordKey) } ?: "")
    }
    var mac by remember { mutableStateOf(existing?.macAddress?.ifEmpty { null } ?: "00:1A:79:") }
    var preferHLS by remember { mutableStateOf(existing?.preferHLS ?: false) }
    var testing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    val originalPhoto = remember { existing?.let { p -> runCatching { Store.photoFile(p.id).takeIf { it.exists() }?.readBytes() }.getOrNull() } }
    var photo by remember { mutableStateOf(originalPhoto) }
    val photoBitmap = remember(photo) { photo?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            val bytes = withContext(Dispatchers.IO) { thumbnail(ctx, uri) }
            if (bytes != null) photo = bytes
        }
    }

    BackHandler(enabled = !confirmDelete) { onClose() }
    val firstFocus = rememberInitialFocus()

    val canSave = name.isNotBlank() && when (kind) {
        PlaylistKind.M3U -> isUrl(m3uURL)
        PlaylistKind.XTREAM -> isUrl(server) && username.isNotEmpty() && password.isNotEmpty()
        PlaylistKind.STALKER -> isUrl(server) && mac.trim().length >= 17
        PlaylistKind.JELLYFIN, PlaylistKind.EMBY -> isUrl(server) && username.isNotEmpty()
        PlaylistKind.PLEX -> plexToken.isNotBlank() && (server.isBlank() || isUrl(server))
        PlaylistKind.STREMIO -> true
    }

    fun save() {
        if (!canSave || testing) return
        val base = existing ?: PlaylistSource(name = name.trim(), kind = kind, avatar = avatar)
        val p = base.copy(
            name = name.trim(), kind = kind, avatar = avatar,
            m3uURL = m3uURL.trim(), epgURL = epgURL.trim(), serverURL = server.trim(),
            username = username.trim(), macAddress = mac.trim().uppercase(), preferHLS = preferHLS,
        )
        val secret = when (kind) {
            PlaylistKind.PLEX -> plexToken.trim()
            PlaylistKind.M3U, PlaylistKind.STALKER -> ""
            else -> password
        }
        testing = true; error = null
        scope.launch {
            val before = Store.secret(p.passwordKey)
            val err: String? = try {
                Playlists.test(p, secret)
            } catch (c: CancellationException) {
                throw c
            } catch (e: Exception) {
                e.localizedMessage ?: e.toString()
            }
            testing = false
            if (err != null) { error = err; return@launch }
            // wachtwoord/token bewaren (tenzij de test zelf al een sessie/sleutel heeft opgeslagen)
            if (secret.isNotEmpty() && Store.secret(p.passwordKey) == before) Store.setSecret(p.passwordKey, secret)
            Store.upsert(p)
            if (!(photo contentEquals originalPhoto)) Store.setPhoto(p.id, photo)
            onClose()
        }
    }

    Column(Modifier.fillMaxSize().background(Color(0xFF141414)).statusBarsPadding()) {
        // kopbalk
        Box(Modifier.fillMaxWidth().padding(horizontal = Theme.edge, vertical = tvs(10))) {
            Text(
                L("Cancel"), color = Color.White, fontSize = tsp(16),
                modifier = Modifier.align(Alignment.CenterStart).focusLift(1.08f, dimWhenIdle = true) { onClose() }.padding(6.dp)
            )
            Text(
                if (existing == null) L("Add playlist") else L("Edit playlist"),
                color = Color.White, fontSize = tsp(17), fontWeight = FontWeight.Bold,
                modifier = Modifier.align(Alignment.Center)
            )
        }

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Column(
                Modifier.widthIn(max = if (tv) 720.dp else 640.dp).fillMaxWidth().padding(Theme.edge),
                verticalArrangement = Arrangement.spacedBy(tvs(18))
            ) {
                // voorbeeld
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    val pal = PlaylistAvatar.palettes[avatar.colorIndex % PlaylistAvatar.palettes.size]
                    Box(
                        Modifier.size(tvs(96)).clip(CircleShape)
                            .background(Brush.linearGradient(listOf(Color(pal.first), Color(pal.second)))),
                        contentAlignment = Alignment.Center
                    ) {
                        if (photoBitmap != null) {
                            Image(photoBitmap.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                        } else {
                            Text(avatar.symbol, fontSize = (tvs(96).value * 0.42f).sp)
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(name.ifBlank { L("New playlist") }, color = Theme.secondary, fontSize = tsp(14), maxLines = 1)
                }

                FormSection(L("Choose the playlist type")) {
                    val perRow = if (tv) 4 else 3
                    Column(verticalArrangement = Arrangement.spacedBy(tvs(10))) {
                        PlaylistKind.entries.chunked(perRow).forEachIndexed { r, row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(tvs(10))) {
                                row.forEachIndexed { c, k ->
                                    val selected = kind == k
                                    Column(
                                        Modifier.weight(1f)
                                            .then(if (r == 0 && c == 0) Modifier.focusRequester(firstFocus) else Modifier)
                                            .focusLift(1.06f) { kind = k; error = null }
                                            .clip(RoundedCornerShape(tvs(12)))
                                            .background(if (selected) Theme.red else Theme.elevated)
                                            .padding(vertical = tvs(12)),
                                        horizontalAlignment = Alignment.CenterHorizontally
                                    ) {
                                        Icon(k.icon, null, tint = Color.White, modifier = Modifier.size(tvs(20)))
                                        Spacer(Modifier.height(6.dp))
                                        Text(k.title, color = Color.White, fontSize = tsp(12), fontWeight = FontWeight.SemiBold, maxLines = 1)
                                    }
                                }
                                repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }

                FormSection(L("Name this playlist")) { FormField(name, { name = it }, L("e.g. My playlist")) }

                FormSection(L("Identify with an icon")) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(tvs(10)), contentPadding = PaddingValues(vertical = 6.dp)) {
                        items(PlaylistAvatar.symbols) { s ->
                            val pal = PlaylistAvatar.palettes[avatar.colorIndex % PlaylistAvatar.palettes.size]
                            Box(
                                Modifier.size(tvs(44)).focusLift(1.1f) { avatar = avatar.copy(symbol = s) }
                                    .clip(RoundedCornerShape(tvs(12)))
                                    .background(
                                        if (avatar.symbol == s) Brush.linearGradient(listOf(Color(pal.first), Color(pal.second)))
                                        else Brush.linearGradient(listOf(Theme.elevated, Theme.elevated))
                                    ),
                                contentAlignment = Alignment.Center
                            ) { Text(s, fontSize = tsp(20)) }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(tvs(12))) {
                        PlaylistAvatar.palettes.forEachIndexed { i, pal ->
                            Box(
                                Modifier.size(tvs(28)).focusLift(1.15f) { avatar = avatar.copy(colorIndex = i) }
                                    .clip(CircleShape)
                                    .background(Brush.linearGradient(listOf(Color(pal.first), Color(pal.second))))
                                    .then(if (avatar.colorIndex == i) Modifier.border(3.dp, Color.White, CircleShape) else Modifier)
                            )
                        }
                    }
                }

                FormSection(L("Profile photo")) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Row(
                            Modifier.focusLift(1.05f) {
                                runCatching {
                                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                                }.onFailure { error = it.localizedMessage }
                            }
                                .clip(RoundedCornerShape(50)).background(Theme.elevated)
                                .padding(horizontal = 16.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.PhotoLibrary, null, tint = Color.White, modifier = Modifier.size(tvs(18)))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                if (photo == null) L("Choose from Photos") else L("Change photo"),
                                color = Color.White, fontSize = tsp(15), fontWeight = FontWeight.SemiBold
                            )
                        }
                        if (photo != null) {
                            Row(
                                Modifier.focusLift(1.05f) { photo = null }.padding(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Delete, null, tint = Theme.red, modifier = Modifier.size(tvs(18)))
                                Spacer(Modifier.width(6.dp))
                                Text(L("Remove photo"), color = Theme.red, fontSize = tsp(15))
                            }
                        }
                    }
                    Text(L("A photo replaces the icon."), color = Theme.secondary, fontSize = tsp(12))
                }

                // velden per type
                when (kind) {
                    PlaylistKind.M3U -> {
                        FormSection(L("URL to your M3U8 file")) { FormField(m3uURL, { m3uURL = it }, "http://your-domain:port/path/file", url = true) }
                        FormSection(L("URL to your EPG file")) { FormField(epgURL, { epgURL = it }, L("http://your-domain/epg.xml (optional)"), url = true) }
                    }
                    PlaylistKind.XTREAM -> {
                        FormSection(L("Server")) { FormField(server, { server = it }, "http://your-server:8080", url = true) }
                        FormSection(L("Username")) { FormField(username, { username = it }, L("username")) }
                        FormSection(L("Password")) { FormField(password, { password = it }, L("password"), secure = true) }
                        FormSection(L("EPG (optional)")) { FormField(epgURL, { epgURL = it }, L("empty = EPG from the server"), url = true) }
                        Row(
                            Modifier.fillMaxWidth().focusLift(1.02f) { preferHLS = !preferHLS }.padding(horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(L("Live TV as HLS (.m3u8) instead of .ts"), color = Color.White, fontSize = tsp(14), modifier = Modifier.weight(1f))
                            Switch(
                                checked = preferHLS, onCheckedChange = { preferHLS = it },
                                colors = SwitchDefaults.colors(checkedTrackColor = Theme.red, checkedThumbColor = Color.White)
                            )
                        }
                    }
                    PlaylistKind.STALKER -> {
                        FormSection(L("Portal URL")) { FormField(server, { server = it }, "http://portal.example.com/c/", url = true) }
                        FormSection(L("MAC address")) { FormField(mac, { mac = it }, "00:1A:79:XX:XX:XX") }
                        FormSection(L("EPG (optional)")) { FormField(epgURL, { epgURL = it }, "http://…/epg.xml", url = true) }
                    }
                    PlaylistKind.JELLYFIN, PlaylistKind.EMBY -> {
                        FormSection(L("Server")) {
                            FormField(server, { server = it }, if (kind == PlaylistKind.EMBY) "http://192.168.1.10:8096/emby" else "http://192.168.1.10:8096", url = true)
                        }
                        FormSection(L("Username")) { FormField(username, { username = it }, L("username")) }
                        FormSection(L("Password")) { FormField(password, { password = it }, L("password"), secure = true) }
                    }
                    PlaylistKind.PLEX -> {
                        if (existing != null && existing.kind == PlaylistKind.PLEX && Store.secret(existing.passwordKey) != null) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.CheckCircle, null, tint = Theme.green, modifier = Modifier.size(tvs(18)))
                                Spacer(Modifier.width(6.dp))
                                Text(L("Signed in with Plex"), color = Theme.green, fontSize = tsp(14))
                            }
                        }
                        FormSection(L("Server")) { FormField(server, { server = it }, "http://192.168.1.10:32400", url = true) }
                        FormSection(L("Plex token")) { FormField(plexToken, { plexToken = it }, "X-Plex-Token", secure = true) }
                        Text(
                            L("Leave the server empty to use your first Plex server automatically."),
                            color = Theme.secondary, fontSize = tsp(11)
                        )
                    }
                    PlaylistKind.STREMIO -> {
                        FormSection(L("Stremio account (optional)")) {
                            FormField(username, { username = it }, L("e-mail"))
                            Spacer(Modifier.height(8.dp))
                            FormField(password, { password = it }, L("password"), secure = true)
                        }
                        FormSection(L("Extra add-ons (one manifest URL per line)")) {
                            FormField(m3uURL, { m3uURL = it }, "https://…/manifest.json", url = true, singleLine = false)
                        }
                        Text(
                            L("Cinemeta is always added for catalogs. Only add-ons that return direct http(s) streams can be played."),
                            color = Theme.secondary, fontSize = tsp(11)
                        )
                    }
                }

                error?.let {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Warning, null, tint = Theme.red, modifier = Modifier.size(tvs(16)))
                        Spacer(Modifier.width(6.dp))
                        Text(it, color = Theme.red, fontSize = tsp(13))
                    }
                }

                Row(
                    Modifier.fillMaxWidth().focusLift(1.03f) { save() }
                        .clip(RoundedCornerShape(50))
                        .background(if (canSave) Theme.red else Theme.elevated)
                        .padding(vertical = tvs(14)),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (testing) {
                        CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(tvs(18)))
                        Spacer(Modifier.width(10.dp))
                    }
                    Text(
                        if (testing) L("Testing connection…") else L("Save"),
                        color = if (canSave) Color.White else Theme.secondary, fontSize = tsp(17), fontWeight = FontWeight.Bold
                    )
                }

                if (existing != null) {
                    Text(
                        L("Delete playlist"), color = Theme.red, fontSize = tsp(15), textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().focusLift(1.03f) { confirmDelete = true }.padding(10.dp)
                    )
                }
                Spacer(Modifier.height(20.dp))
            }
        }
    }

    if (confirmDelete && existing != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(L("Delete?")) },
            text = { Text(existing.name) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    Store.delete(existing)
                    onClose()
                }) { Text(L("Delete"), color = Theme.red) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("Cancel"), color = Color.White) } },
            containerColor = Theme.elevated,
        )
    }
}

@Composable
private fun FormSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(tvs(8))) {
        Text(title, color = Theme.secondary, fontSize = tsp(14), fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = tvs(14)))
        content()
    }
}

@Composable
private fun FormField(
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    url: Boolean = false,
    secure: Boolean = false,
    singleLine: Boolean = true,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = if (singleLine) RoundedCornerShape(50) else RoundedCornerShape(18.dp)
    TextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, color = Theme.secondary.copy(alpha = 0.7f), fontSize = tsp(15)) },
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 3,
        maxLines = if (singleLine) 1 else 6,
        textStyle = androidx.compose.ui.text.TextStyle(
            color = Color.White, fontSize = tsp(16),
            fontFamily = if (!singleLine) FontFamily.Monospace else FontFamily.Default
        ),
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            keyboardType = when {
                secure -> KeyboardType.Password
                url -> KeyboardType.Uri
                else -> KeyboardType.Text
            }
        ),
        shape = shape,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Theme.elevated, unfocusedContainerColor = Theme.elevated,
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
            cursorColor = Theme.red, focusedTextColor = Color.White, unfocusedTextColor = Color.White,
        ),
        modifier = Modifier.fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .then(if (focused && AppState.isTV) Modifier.border(2.dp, Color.White, shape) else Modifier)
    )
}
