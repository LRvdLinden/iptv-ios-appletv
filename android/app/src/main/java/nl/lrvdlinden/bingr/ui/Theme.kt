package nl.lrvdlinden.bingr

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Netflix-kleuren en maten (zelfde als iOS Theme). */
object Theme {
    val red = Color(0xFFE50914)
    val bg = Color.Black
    val card = Color(0xFF181818)
    val elevated = Color(0xFF232323)
    val secondary = Color(0xFFB3B3B3)
    val imdb = Color(0xFFF5C518)
    val green = Color(0xFF46D369)

    /** Op TV alles groter (zoals tvScaled op iOS) */
    val tv: Boolean get() = AppState.isTV
    val posterWidth: Dp get() = if (tv) 150.dp else 112.dp
    val edge: Dp get() = if (tv) 48.dp else 16.dp
    val rowSpacing: Dp get() = if (tv) 18.dp else 8.dp
    val titleSize: TextUnit get() = if (tv) 24.sp else 19.sp
}

/** Schaal voor TV (≈ tvScaled op iOS, maar Android-TV-dp's zijn al groot). */
fun tvs(v: Float): Float = if (AppState.isTV) v * 1.35f else v
fun tvs(v: Int): Dp = (if (AppState.isTV) v * 1.35f else v.toFloat()).dp
fun tsp(v: Int): TextUnit = (if (AppState.isTV) v * 1.35f else v.toFloat()).sp

@Composable
fun BingrTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Theme.red, onPrimary = Color.White, background = Color.Black, surface = Color(0xFF141414),
            onSurface = Color.White, onBackground = Color.White, secondary = Theme.secondary, surfaceVariant = Theme.elevated,
        ),
        content = content
    )
}

/**
 * Klikbaar + focusbaar (afstandsbediening) zonder grijze vlakken: bij focus iets groter met schaduw.
 * Gebruik dit voor posters, kaarten en knoppen overal in de app.
 */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.focusLift(
    scale: Float = 1.08f,
    dimWhenIdle: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
): Modifier = composed {
    var focused by remember { mutableStateOf(false) }
    val s by animateFloatAsState(if (focused) scale else 1f, spring(dampingRatio = 0.78f, stiffness = 500f), label = "lift")
    val alpha = if (dimWhenIdle && !focused && AppState.isTV) 0.75f else 1f
    this
        .onFocusChanged { focused = it.isFocused }
        .graphicsLayer {
            scaleX = s; scaleY = s; this.alpha = alpha
            shadowElevation = if (focused) 28f else 0f
            shape = RoundedCornerShape(6.dp); clip = false
        }
        .combinedClickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            onLongClick = onLongClick, onClick = onClick
        )
}

/** Lokaal: is het element waar dit in staat gefocust (voor witte knoppen op TV). */
@Composable
fun rememberFocus(): MutableState<Boolean> = remember { mutableStateOf(false) }

enum class NetflixKind { PRIMARY, SECONDARY, ACCENT }

/** Afspelen / Meer info: op TV wordt de geselecteerde knop wit (zoals Netflix). */
@Composable
fun NetflixButton(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    kind: NetflixKind = NetflixKind.PRIMARY,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val light = if (AppState.isTV) kind != NetflixKind.ACCENT && focused else kind == NetflixKind.PRIMARY
    val bg = when {
        kind == NetflixKind.ACCENT -> Theme.red
        light -> Color.White
        else -> Color.White.copy(alpha = 0.22f)
    }
    val fg = if (light) Color.Black else Color.White
    Row(
        modifier
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.06f, onClick = onClick)
            .clip(RoundedCornerShape(6.dp))
            .background(bg)
            .padding(horizontal = tvs(20), vertical = tvs(10)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center
    ) {
        if (icon != null) { Icon(icon, null, tint = fg, modifier = Modifier.size(tvs(18))); Spacer(Modifier.width(8.dp)) }
        Text(title, color = fg, fontWeight = FontWeight.Bold, fontSize = tsp(15), maxLines = 1)
    }
}

/** Afbeelding van internet (Coil), met tekst als placeholder. */
@Composable
fun RemoteImage(
    url: String?,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    fit: Boolean = false,
) {
    Box(modifier.background(Theme.card), contentAlignment = Alignment.Center) {
        if (placeholder.isNotEmpty()) {
            Text(placeholder, color = Theme.secondary, fontSize = 11.sp, textAlign = TextAlign.Center,
                maxLines = 3, modifier = Modifier.padding(6.dp))
        }
        if (!url.isNullOrBlank()) {
            coil.compose.AsyncImage(
                model = url, contentDescription = null, modifier = Modifier.matchParentSize(),
                contentScale = if (fit) androidx.compose.ui.layout.ContentScale.Fit else androidx.compose.ui.layout.ContentScale.Crop
            )
        }
    }
}

/** Ronde profielavatar: foto of emoji op kleurverloop. */
@Composable
fun AvatarCircle(playlist: PlaylistSource, size: Dp, ring: Boolean = false, editing: Boolean = false) {
    val v = Store.photoVersion
    val photo = remember(playlist.id, v) { Store.photo(playlist.id) }
    val pal = PlaylistAvatar.palettes[playlist.avatar.colorIndex % PlaylistAvatar.palettes.size]
    Box(
        Modifier.size(size).clip(CircleShape)
            .background(Brush.linearGradient(listOf(Color(pal.first), Color(pal.second))))
            .then(if (ring) Modifier.border(3.dp, Color.White, CircleShape) else Modifier),
        contentAlignment = Alignment.Center
    ) {
        if (photo != null) {
            androidx.compose.foundation.Image(photo.asImageBitmap(), null, Modifier.matchParentSize(),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        } else {
            Text(playlist.avatar.symbol, fontSize = (size.value * 0.42f).sp)
        }
        if (editing) {
            Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                Icon(androidx.compose.material.icons.Icons.Default.Edit, null, tint = Color.White, modifier = Modifier.size(size * 0.3f))
            }
        }
    }
}


/** Bingr-logo: witte afgeronde letters met rode streep eronder (zelfde als splash). */
@Composable
fun BingrLogo(size: TextUnit = 26.sp) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("BINGR", color = Color.White, fontWeight = FontWeight.Black, fontSize = size, letterSpacing = 1.sp)
        Box(Modifier.padding(top = 2.dp).width((size.value * 2.9f).dp).height((size.value * 0.12f).dp)
            .clip(RoundedCornerShape(50)).background(Theme.red))
    }
}

/** Dunne voortgangsbalk (rood op grijs). */
@Composable
fun ProgressBar(value: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.3f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(value.toFloat().coerceIn(0f, 1f)).background(Theme.red))
    }
}
