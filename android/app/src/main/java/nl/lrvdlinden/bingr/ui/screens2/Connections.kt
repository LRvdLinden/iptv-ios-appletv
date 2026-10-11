package nl.lrvdlinden.bingr

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private const val S2_TRAKT_NEW_APP = "https://trakt.tv/oauth/applications/new"
private const val S2_OS_CONSUMERS = "https://www.opensubtitles.com/consumers"
private const val S2_TRAKT_REDIRECT = "https://github.com/LRvdLinden/iptv-ios-appletv"

internal fun s2OpenURL(ctx: Context, url: String) {
    runCatching {
        ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

internal fun s2Copy(ctx: Context, text: String) {
    runCatching {
        (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Bingr", text))
    }
}

/**
 * Eenmalig instellen: de app-sleutels die Trakt en OpenSubtitles vereisen (en optioneel OMDb/TMDB).
 * [focus] = "trakt" | "opensubtitles" | "all".
 */
@Composable
fun ConnectionsSetupScreen(focus: String, onClose: () -> Unit) {
    val ctx = LocalContext.current
    var traktID by remember { mutableStateOf(Secrets.traktClientID) }
    var traktSecret by remember { mutableStateOf(Secrets.traktClientSecret) }
    var osKey by remember { mutableStateOf(Secrets.openSubtitlesAPIKey) }
    var omdb by remember { mutableStateOf(Secrets.omdbAPIKey) }
    var tmdb by remember { mutableStateOf(Secrets.tmdbAPIKey) }

    fun save() {
        Secrets.set(Secrets.Key.TRAKT_CLIENT_ID, traktID)
        Secrets.set(Secrets.Key.TRAKT_CLIENT_SECRET, traktSecret)
        Secrets.set(Secrets.Key.OPENSUBTITLES_API_KEY, osKey)
        Secrets.set(Secrets.Key.OMDB_API_KEY, omdb)
        Secrets.set(Secrets.Key.TMDB_API_KEY, tmdb)
        onClose()
    }

    S2FullDialog(onClose) {
        S2Page(L("Set up connections"), onClose = onClose, actions = {
            Text(L("Save"), color = Color.White, fontSize = tsp(16), fontWeight = FontWeight.Bold,
                modifier = Modifier.focusLift(1.08f) { save() }.clip(RoundedCornerShape(50)).background(Theme.red)
                    .padding(horizontal = 16.dp, vertical = 8.dp))
        }) {
            if (focus != "opensubtitles") item {
                S2Section("Trakt", L("Trakt requires every app to register once. After that you simply sign in with your Trakt account.")) {
                    S2Step(1, L("Open the Trakt page below and sign in with your Trakt account."))
                    S2Link(ctx, S2_TRAKT_NEW_APP)
                    S2Step(2, L("Name: Bingr. Redirect URI: paste the text below. Leave the rest empty and save."))
                    S2CopyRow(ctx, S2_TRAKT_REDIRECT)
                    S2Step(3, L("Copy the Client ID and Client Secret into the fields below."))
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        S2TextField(traktID, { traktID = it }, "Client ID")
                        S2TextField(traktSecret, { traktSecret = it }, L("Client Secret (optional)"))
                    }
                }
            }
            if (focus != "trakt") item {
                S2Section("OpenSubtitles", L("Then sign in with your OpenSubtitles username and password.")) {
                    S2Step(1, L("Open the OpenSubtitles page below and sign in with your account."))
                    S2Link(ctx, S2_OS_CONSUMERS)
                    S2Step(2, L("Create a new consumer called Bingr and copy the API key into the field below."))
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
                        S2TextField(osKey, { osKey = it }, "API key")
                    }
                }
            }
            if (focus == "all") item {
                S2Section(L("Optional")) {
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
                        S2TextField(omdb, { omdb = it }, L("OMDb key (IMDb scores)"))
                    }
                    S2Link(ctx, "https://www.omdbapi.com/apikey.aspx")
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
                        S2TextField(tmdb, { tmdb = it }, L("TMDB key (cast photos, logos)"))
                    }
                    S2Link(ctx, "https://www.themoviedb.org/settings/api")
                }
            }
        }
    }
}

/** Link: op telefoon een knop die de browser opent, op TV een QR-code met het adres. */
@Composable
private fun S2Link(ctx: Context, url: String) {
    val short = url.removePrefix("https://")
    if (AppState.isTV) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            QrCodeImage(url, 140.dp)
            Spacer(Modifier.width(20.dp))
            Text(short, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        }
    } else {
        S2Row(short, icon = Icons.Default.OpenInBrowser, onClick = { s2OpenURL(ctx, url) })
    }
}

@Composable
private fun S2CopyRow(ctx: Context, text: String) {
    S2Row(text, onClick = if (AppState.isTV) null else ({ s2Copy(ctx, text) }), trailing = {
        if (!AppState.isTV) Icon(Icons.Default.ContentCopy, L("Copy"), tint = Theme.secondary, modifier = Modifier.size(tvs(18)))
    })
}

/** Trakt koppelen met een apparaatcode: code + adres + QR-code; wacht op bevestiging. */
@Composable
fun TraktLoginScreen(onClose: () -> Unit) {
    val ctx = LocalContext.current
    var code by remember { mutableStateOf<Trakt.DeviceCode?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try {
            val c = Trakt.startLogin()
            code = c
            Trakt.finishLogin(c)
            onClose()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: e.toString()
        }
    }
    S2FullDialog(onClose) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Theme.edge),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tvs(14), Alignment.CenterVertically)
        ) {
            Icon(Icons.Default.Sync, null, tint = Theme.red, modifier = Modifier.size(tvs(54)))
            Text(L("Connect your Trakt account"), color = Color.White, fontSize = tsp(22), fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center)
            val c = code
            if (c != null) {
                if (AppState.isTV) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            S2TraktCodeTexts(c)
                        }
                        Spacer(Modifier.width(40.dp))
                        QrCodeImage(c.verificationUrl, 180.dp)
                    }
                } else {
                    S2TraktCodeTexts(c)
                    QrCodeImage(c.verificationUrl, 140.dp)
                    NetflixButton(L("Open trakt.tv/activate"), Icons.Default.OpenInBrowser) {
                        s2Copy(ctx, c.userCode)
                        s2OpenURL(ctx, c.verificationUrl)
                    }
                    Text(L("The code is already on your clipboard."), color = Theme.secondary, fontSize = tsp(12))
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(color = Theme.red, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(L("Waiting for confirmation…"), color = Theme.secondary, fontSize = tsp(14))
                }
            } else if (error == null) {
                CircularProgressIndicator(color = Theme.red)
            }
            error?.let { Text(it, color = Theme.red, textAlign = TextAlign.Center, fontSize = tsp(14)) }
            Text(L("Cancel"), color = Theme.secondary, fontSize = tsp(16),
                modifier = Modifier.padding(top = 8.dp).focusLift(1.08f, onClick = onClose).padding(12.dp))
        }
    }
}

@Composable
private fun S2TraktCodeTexts(c: Trakt.DeviceCode) {
    Text(L("On your phone or computer, go to"), color = Theme.secondary, fontSize = tsp(15))
    Text(c.verificationUrl, color = Color.White, fontSize = tsp(18), fontWeight = FontWeight.SemiBold)
    Text(L("and enter this code:"), color = Theme.secondary, fontSize = tsp(15))
    Text(c.userCode, color = Color.White, fontSize = tsp(40), fontWeight = FontWeight.Black, fontFamily = FontFamily.Monospace,
        letterSpacing = 6.sp,
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Theme.elevated).padding(horizontal = 24.dp, vertical = 10.dp))
}

/** Inloggen bij OpenSubtitles met gebruikersnaam en wachtwoord. */
@Composable
fun OpenSubtitlesLoginScreen(onClose: () -> Unit) {
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    S2FullDialog(onClose) {
        S2Page("OpenSubtitles", onClose = onClose) {
            item {
                S2Section(footer = L("No account yet? Create one for free at opensubtitles.com.")) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        S2TextField(user, { user = it }, L("Username"))
                        S2TextField(pass, { pass = it }, L("Password"), password = true)
                    }
                }
            }
            error?.let { e -> item { Text(e, color = Theme.red, fontSize = tsp(13), modifier = Modifier.padding(16.dp)) } }
            item {
                Box(Modifier.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge, vertical = 16.dp)) {
                    if (busy) CircularProgressIndicator(color = Theme.red, modifier = Modifier.align(Alignment.Center))
                    else {
                        val ok = user.isNotBlank() && pass.isNotEmpty()
                        NetflixButton(L("Sign in"), kind = if (ok) NetflixKind.ACCENT else NetflixKind.SECONDARY,
                            modifier = Modifier.fillMaxWidth()) {
                            if (!ok) return@NetflixButton
                            busy = true; error = null
                            scope.launch {
                                try {
                                    OpenSubtitles.login(user.trim(), pass)
                                    onClose()
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    error = e.message ?: e.toString()
                                } finally {
                                    busy = false
                                }
                            }
                        }
                    }
                }
            }
            item { Spacer(Modifier.height(8.dp)) }
        }
    }
}
