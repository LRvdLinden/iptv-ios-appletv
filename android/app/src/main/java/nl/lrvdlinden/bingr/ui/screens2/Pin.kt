package nl.lrvdlinden.bingr

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/**
 * Pincode-invoer (4 cijfers) — werkt met aanraken, afstandsbediening (D-pad) en cijfertoetsen.
 * Telefoon/tablet: compact 3×4-toetsenblok dat zich aan de schermhoogte aanpast.
 * TV: één rij cijfers 1–9, 0, ⌫ (zoals de tvOS-versie), past ook met overscan.
 * [onSubmit] geeft true bij een juiste code (dan sluit het scherm via [onDismiss]), anders schudt het en begint opnieuw.
 */
@Composable
fun PinPad(title: String, onDismiss: () -> Unit, onSubmit: (String) -> Boolean) {
    var pin by remember { mutableStateOf("") }
    val shake = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val tv = AppState.isTV

    fun tap(k: String) {
        if (k == "⌫") { if (pin.isNotEmpty()) pin = pin.dropLast(1); return }
        if (pin.length >= 4) return
        pin += k
        if (pin.length == 4) {
            val entered = pin
            if (onSubmit(entered)) onDismiss()
            else {
                pin = ""
                scope.launch {
                    repeat(3) { shake.animateTo(-10f, tween(40)); shake.animateTo(10f, tween(40)) }
                    shake.animateTo(0f, tween(40))
                }
            }
        }
    }

    S2FullDialog(onDismiss) {
        val first = remember { FocusRequester() }
        BoxWithConstraints(
            Modifier.fillMaxSize()
                .onPreviewKeyEvent { e ->
                    if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    val code = e.nativeKeyEvent.keyCode
                    when (code) {
                        in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 -> { tap("${code - AndroidKeyEvent.KEYCODE_0}"); true }
                        in AndroidKeyEvent.KEYCODE_NUMPAD_0..AndroidKeyEvent.KEYCODE_NUMPAD_9 -> { tap("${code - AndroidKeyEvent.KEYCODE_NUMPAD_0}"); true }
                        AndroidKeyEvent.KEYCODE_DEL -> { tap("⌫"); true }
                        else -> false
                    }
                },
            contentAlignment = Alignment.Center
        ) {
            val w = maxWidth
            val h = maxHeight
            if (tv) {
                // één rij: 11 toetsen over de breedte
                val gap = 12.dp
                val key: Dp = ((w - 96.dp - gap * 10) / 11).coerceIn(40.dp, 72.dp)
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Default.Lock, null, tint = Theme.red, modifier = Modifier.size(34.dp))
                    Spacer(Modifier.height(18.dp))
                    Text(title, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
                        maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 820.dp))
                    Spacer(Modifier.height(22.dp))
                    PinDots(pin.length, 18.dp, 18.dp, shake.value)
                    Spacer(Modifier.height(26.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "⌫").forEach { k ->
                            PinKey(k, key, if (k == "1") first else null) { tap(k) }
                        }
                    }
                    Spacer(Modifier.height(22.dp))
                    Text(L("Cancel"), color = Theme.secondary, fontSize = 20.sp,
                        modifier = Modifier.focusLift(1.08f, dimWhenIdle = true, onClick = onDismiss).padding(12.dp))
                }
            } else {
                // 3×4 toetsenblok, zo groot als past (kleine schermen / liggend)
                val gap = 12.dp
                val byHeight = (h - 230.dp - gap * 3) / 4
                val byWidth = (w - 48.dp - gap * 2) / 3
                val key: Dp = minOf(byHeight, byWidth).coerceIn(44.dp, 72.dp)
                Column(
                    Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = h)
                        .padding(horizontal = 24.dp, vertical = 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Default.Lock, null, tint = Theme.red, modifier = Modifier.size(30.dp))
                    Spacer(Modifier.height(12.dp))
                    Text(title, color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
                        modifier = Modifier.widthIn(max = 420.dp))
                    Spacer(Modifier.height(16.dp))
                    PinDots(pin.length, 14.dp, 14.dp, shake.value)
                    Spacer(Modifier.height(18.dp))
                    val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("", "0", "⌫"))
                    Column(verticalArrangement = Arrangement.spacedBy(gap)) {
                        rows.forEach { r ->
                            Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                                r.forEach { k ->
                                    if (k.isEmpty()) Spacer(Modifier.size(key))
                                    else PinKey(k, key, if (k == "1") first else null) { tap(k) }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Text(L("Cancel"), color = Theme.secondary, fontSize = 16.sp,
                        modifier = Modifier.focusLift(1.08f, onClick = onDismiss).padding(12.dp))
                }
            }
        }
        LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    }
}

@Composable
private fun PinDots(filled: Int, size: Dp, spacing: Dp, shake: Float) {
    Row(Modifier.offset(x = shake.dp), horizontalArrangement = Arrangement.spacedBy(spacing)) {
        for (i in 0 until 4) {
            Box(Modifier.size(size).clip(CircleShape)
                .background(if (i < filled) Color.White else Color.White.copy(alpha = 0.2f)))
        }
    }
}

@Composable
private fun PinKey(k: String, size: Dp, fr: FocusRequester?, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val tv = AppState.isTV
    Box(
        Modifier.size(size)
            .then(if (fr != null) Modifier.focusRequester(fr) else Modifier)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(if (tv) 1.15f else 1.06f, onClick = onClick)
            .clip(CircleShape)
            .background(if (focused && tv) Color.White else Theme.elevated)
            .then(if (focused && !tv) Modifier.border(2.dp, Color.White, CircleShape) else Modifier),
        contentAlignment = Alignment.Center
    ) {
        val fg = if (focused && tv) Color.Black else Color.White
        if (k == "⌫") {
            Icon(Icons.AutoMirrored.Filled.Backspace, L("Delete"), tint = fg, modifier = Modifier.size(size * 0.38f))
        } else {
            Text(k, color = fg, fontSize = (size.value * 0.4f).sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/**
 * Nieuwe pincode instellen (2× invoeren) voor een profiel (null = actief profiel, anders hoofdaccount).
 * Daarna is alles weer op slot. [enableParental] zet ook het kinderslot aan (hoofdaccount).
 */
@Composable
fun PinSetupScreen(profileID: String? = null, enableParental: Boolean = false, onClose: () -> Unit) {
    var step by remember { mutableIntStateOf(0) }
    var first by remember { mutableStateOf<String?>(null) }
    key(step) {
        if (step == 0) {
            PinPad(L("Choose a 4-digit PIN"), onDismiss = onClose) { pin -> first = pin; step = 1; false }
        } else {
            PinPad(L("Enter the PIN again"), onDismiss = onClose) { pin ->
                if (pin != first) { step = 0; false }
                else {
                    val id = profileID ?: Store.activeProfileID ?: Store.mainProfileID
                    if (id != null) ParentalControl.setPIN(pin, id) else ParentalControl.setPIN(pin)
                    if (enableParental) Store.updateParental { it.copy(enabled = true) }
                    ParentalControl.lock()
                    true
                }
            }
        }
    }
}
