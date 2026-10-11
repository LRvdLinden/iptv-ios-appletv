package nl.lrvdlinden.bingr

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Pincode-invoer (4 cijfers) — werkt met aanraken, afstandsbediening (D-pad) en cijfertoetsen.
 * [onSubmit] geeft true bij een juiste code (dan sluit het scherm), anders schudt het en begint opnieuw.
 */
@Composable
fun PinPad(title: String, onDismiss: () -> Unit, onSubmit: (String) -> Boolean) {
    var pin by remember { mutableStateOf("") }
    val shake = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()

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
        Column(
            Modifier.fillMaxSize().padding(Theme.edge)
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
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(Icons.Default.Lock, null, tint = Theme.red, modifier = Modifier.size(tvs(36)))
            Spacer(Modifier.height(tvs(18)))
            Text(title, color = Color.White, fontSize = tsp(20), fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(tvs(22)))
            Row(Modifier.offset(x = shake.value.dp), horizontalArrangement = Arrangement.spacedBy(tvs(14))) {
                for (i in 0 until 4) {
                    Box(Modifier.size(tvs(16)).clip(CircleShape)
                        .background(if (i < pin.length) Color.White else Color.White.copy(alpha = 0.2f)))
                }
            }
            Spacer(Modifier.height(tvs(22)))
            val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("", "0", "⌫"))
            Column(verticalArrangement = Arrangement.spacedBy(tvs(14))) {
                rows.forEach { r ->
                    Row(horizontalArrangement = Arrangement.spacedBy(tvs(14))) {
                        r.forEach { k ->
                            if (k.isEmpty()) Spacer(Modifier.size(tvs(70)))
                            else S2PinKey(k, if (k == "1") first else null) { tap(k) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(tvs(22)))
            Text(L("Cancel"), color = Theme.secondary, fontSize = tsp(16),
                modifier = Modifier.focusLift(1.08f, onClick = onDismiss).padding(12.dp))
        }
        LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    }
}

@Composable
private fun S2PinKey(k: String, fr: FocusRequester?, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        Modifier.size(tvs(70))
            .then(if (fr != null) Modifier.focusRequester(fr) else Modifier)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.12f, onClick = onClick)
            .clip(CircleShape)
            .background(if (focused && AppState.isTV) Color.White else Theme.elevated)
            .then(if (focused && !AppState.isTV) Modifier.border(2.dp, Color.White, CircleShape) else Modifier),
        contentAlignment = Alignment.Center
    ) {
        Text(k, color = if (focused && AppState.isTV) Color.Black else Color.White, fontSize = tsp(26), fontWeight = FontWeight.SemiBold)
    }
}

/** Nieuwe pincode instellen (2× invoeren); zet daarna het kinderslot aan. */
@Composable
fun PinSetupScreen(onClose: () -> Unit) {
    var step by remember { mutableIntStateOf(0) }
    var first by remember { mutableStateOf<String?>(null) }
    key(step) {
        if (step == 0) {
            PinPad(L("Choose a 4-digit PIN"), onDismiss = onClose) { pin -> first = pin; step = 1; false }
        } else {
            PinPad(L("Enter the PIN again"), onDismiss = onClose) { pin ->
                if (pin != first) { step = 0; false }
                else {
                    ParentalControl.setPIN(pin)
                    Store.updateParental { it.copy(enabled = true) }
                    ParentalControl.lock()
                    true
                }
            }
        }
    }
}
