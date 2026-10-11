package nl.lrvdlinden.bingr

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Theaters
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import androidx.compose.runtime.withFrameMillis

/** Splash → profielkeuze → hoofdscherm; speler en multiview volledig erboven. */
@Composable
fun BingrRoot() {
    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        val covered = AppState.playing != null || AppState.showMultiview
        Box(Modifier.fillMaxSize().blockFocus(covered)) {
            Crossfade(targetState = AppState.stage, animationSpec = tween(450), label = "stage") { stage ->
                when (stage) {
                    AppState.Stage.SPLASH -> SplashScreen(onFinished = { AppState.splashFinished() })
                    AppState.Stage.PICKER -> PlaylistPickerScreen()
                    AppState.Stage.MAIN -> MainScreen()
                }
            }
        }
        if (AppState.showMultiview) {
            FullLayer(Modifier.blockFocus(AppState.playing != null)) {
                MultiviewScreen(onClose = { AppState.showMultiview = false })
            }
        }
        val item = AppState.playing
        if (item != null) {
            FullLayer { PlayerScreen(item = item, onClose = { AppState.playing = null }) }
        }
    }
}

// MARK: splash

private class SplashTile(
    val url: String?, val seed: Int, val x: Float, val width: Float,
    val delayMs: Float, val durationMs: Float, val startRotation: Float, val endRotation: Float,
)

/** Voorspelbare "willekeur" zodat de compositie elke keer mooi verdeeld is. */
private class SeededRandom(seed: ULong) {
    private var state: ULong = seed * 6364136223846793005UL + 1442695040888963407UL
    fun next(): Float {
        state = state * 6364136223846793005UL + 1442695040888963407UL
        return ((state shr 11).toDouble() / (1L shl 53).toDouble()).toFloat()
    }
}

/**
 * Intro: covers uit je afspeellijst regenen naar beneden, daarna springen de letters
 * van BINGR één voor één omhoog en verschijnt de rode streep (= SplashView.swift).
 */
@Composable
fun SplashScreen(onFinished: () -> Unit) {
    val tv = AppState.isTV
    val posters = remember { runCatching { Playlists.splashPosters() }.getOrDefault(emptyList()).shuffled() }
    var elapsed by remember { mutableLongStateOf(0L) }
    var dim by remember { mutableStateOf(false) }
    var lettersIn by remember { mutableIntStateOf(0) }
    var shine by remember { mutableStateOf(false) }
    var out by remember { mutableStateOf(false) }
    val fallStart = 100f

    LaunchedEffect(Unit) {
        launch {
            val start = withFrameMillis { it }
            while (isActive) {
                val now = withFrameMillis { it }
                elapsed = now - start
                if (elapsed > 3500) break
            }
        }
        delay(1050); dim = true
        delay(200)
        for (i in 1..5) { lettersIn = i; delay(80) }
        delay(120); shine = true
        delay(650); out = true
        delay(300); onFinished()
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val density = LocalDensity.current
        val wPx = with(density) { maxWidth.toPx() }
        val hPx = with(density) { maxHeight.toPx() }
        val tiles = remember(wPx, posters) {
            val columns = if (tv) 9 else 5
            val perColumn = 3
            val colW = wPx / columns
            val g = SeededRandom(42UL)
            val list = ArrayList<SplashTile>()
            for (c in 0 until columns) for (r in 0 until perColumn) {
                val i = c * perColumn + r
                val url = if (posters.isEmpty()) null else posters[i % posters.size]
                val w = colW * (0.82f + g.next() * 0.25f)
                list.add(
                    SplashTile(
                        url = url, seed = i,
                        x = colW * (c + 0.5f) + (g.next() - 0.5f) * colW * 0.3f,
                        width = w,
                        delayMs = (r * 0.32f + g.next() * 0.35f) * 1000f,
                        durationMs = (1.15f + g.next() * 0.55f) * 1000f,
                        startRotation = (g.next() - 0.5f) * 16f,
                        endRotation = (g.next() - 0.5f) * 30f,
                    )
                )
            }
            list
        }

        // vallende covers
        tiles.forEach { t ->
            val wDp = with(density) { t.width.toDp() }
            Box(
                Modifier
                    .size(wDp, wDp * 1.5f)
                    .graphicsLayer {
                        val p = ((elapsed - fallStart - t.delayMs) / t.durationMs).coerceIn(0f, 1f)
                        val e = p * p
                        val h = t.width * 1.5f
                        val y = -t.width * 1.6f + (hPx + t.width * 3.2f) * e
                        translationX = t.x - t.width / 2f
                        translationY = y - h / 2f
                        rotationZ = t.startRotation + (t.endRotation - t.startRotation) * e
                        shadowElevation = 16f
                        shape = RoundedCornerShape(8.dp)
                        clip = true
                    }
            ) { FallingCover(t.url, t.seed) }
        }

        // donker worden zodat de naam eruit springt
        val dimAlpha by animateFloatAsState(if (dim) 1f else 0f, tween(500), label = "dim")
        Box(
            Modifier.fillMaxSize().graphicsLayer { alpha = dimAlpha }.background(
                Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.2f), Color.Black.copy(alpha = 0.95f), Color.Black.copy(alpha = 0.2f)))
            )
        )

        // app-naam
        val letterSize = if (tv) 64f else 70f
        val outScale by animateFloatAsState(if (out) 1.15f else 1f, tween(300), label = "outS")
        val outAlpha by animateFloatAsState(if (out) 0f else 1f, tween(300), label = "outA")
        val lineW by animateDpAsState(if (shine) (letterSize * 3.4f).dp else 0.dp, spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessLow), label = "line")
        Column(
            Modifier.align(Alignment.Center).graphicsLayer { scaleX = outScale; scaleY = outScale; alpha = outAlpha },
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy((letterSize * 0.02f).dp)) {
                "BINGR".forEachIndexed { i, ch ->
                    val a by animateFloatAsState(
                        if (lettersIn > i) 1f else 0f,
                        spring(dampingRatio = 0.55f, stiffness = 380f), label = "l$i"
                    )
                    Text(
                        ch.toString(), color = Color.White, fontWeight = FontWeight.Black, fontSize = letterSize.sp,
                        modifier = Modifier.graphicsLayer {
                            transformOrigin = TransformOrigin(0.5f, 1f)
                            translationY = (1f - a) * (letterSize * 0.9f).dp.toPx()
                            alpha = a.coerceIn(0f, 1f)
                            val s = 0.6f + 0.4f * a
                            scaleX = s; scaleY = s
                        }
                    )
                }
            }
            Box(
                Modifier.padding(top = 2.dp).width(lineW).height((letterSize * 0.08f).dp)
                    .clip(RoundedCornerShape(50)).background(Theme.red)
            )
        }
    }
}

/** Eén cover; zonder afbeelding een kleurige kaart met filmicoon. */
@Composable
private fun FallingCover(url: String?, seed: Int) {
    val p = PlaylistAvatar.palettes[seed % PlaylistAvatar.palettes.size]
    val icons = listOf(Icons.Default.Movie, Icons.Default.Tv, Icons.Default.Theaters, Icons.Default.LiveTv, Icons.Default.PlayCircle)
    Box(
        Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Color(p.first), Color(p.second)))),
        contentAlignment = Alignment.Center
    ) {
        Icon(icons[seed % icons.size], null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(tvs(26)))
        if (url != null) {
            coil.compose.AsyncImage(
                model = url, contentDescription = null, modifier = Modifier.fillMaxSize(),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop
            )
        }
    }
}
