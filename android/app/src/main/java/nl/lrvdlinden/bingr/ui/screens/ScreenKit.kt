package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.text.Normalizer

// Gedeelde hulpmiddelen voor de schermen van deel C (navigatie-lagen, focus, tekst).

/** Eén scherm dat over het hoofdscherm heen ligt (detail, categorie, zoeken). */
sealed class ScreenEntry {
    data class Detail(val target: DetailTarget) : ScreenEntry()
    data class Category(val target: CategoryTarget) : ScreenEntry()
    data object Search : ScreenEntry()
}

/**
 * Stapel schermen boven [MainScreen] (tegenhanger van sheets/fullScreenCovers op iOS).
 * Wordt getekend door [ScreensStackHost]; terug-knop sluit de bovenste.
 */
object ScreensNav {
    data class Item(val id: Long, val entry: ScreenEntry)

    val stack = mutableStateListOf<Item>()
    private var counter = 0L

    fun push(e: ScreenEntry) { counter += 1; stack.add(Item(counter, e)) }
    fun detail(t: DetailTarget) = push(ScreenEntry.Detail(t))
    fun category(t: CategoryTarget) = push(ScreenEntry.Category(t))
    fun search() = push(ScreenEntry.Search)
    fun close(id: Long) { stack.removeAll { it.id == id } }
    fun clear() { stack.clear() }
}

/** Tekent de schermstapel volledig over het scherm; alleen de bovenste krijgt focus. */
@Composable
fun ScreensStackHost() {
    val items = ScreensNav.stack.toList()
    items.forEachIndexed { i, item ->
        key(item.id) {
            FullLayer(Modifier.blockFocus(i < items.size - 1)) {
                when (val e = item.entry) {
                    is ScreenEntry.Detail -> DetailScreen(e.target, onClose = { ScreensNav.close(item.id) })
                    is ScreenEntry.Category -> CategoryScreen(e.target, onClose = { ScreensNav.close(item.id) })
                    ScreenEntry.Search -> SearchScreen(modal = true, onClose = { ScreensNav.close(item.id) })
                }
            }
        }
    }
}

/** Volledig scherm, zwart, en tikken gaan niet door naar wat eronder ligt. */
@Composable
fun FullLayer(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier
            .fillMaxSize()
            .background(Theme.bg)
            .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent() } },
        content = content
    )
}

/** Afstandsbediening: focus kan niet in deze groep komen zolang [blocked] (iets ligt erover). */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.blockFocus(blocked: Boolean): Modifier =
    this.focusProperties { if (blocked) enter = { FocusRequester.Cancel } }.focusGroup()

/** Op TV meteen focus op dit element (een paar pogingen, lazy lijsten komen iets later). */
@Composable
fun rememberInitialFocus(enabled: Boolean = AppState.isTV, key: Any? = Unit): FocusRequester {
    val r = remember { FocusRequester() }
    LaunchedEffect(key, enabled) {
        if (!enabled) return@LaunchedEffect
        repeat(8) {
            delay(90)
            if (runCatching { r.requestFocus() }.isSuccess) return@LaunchedEffect
        }
    }
    return r
}

/** Laat een element (rij) buiten de horizontale padding van zijn ouder uitsteken. */
fun Modifier.bleedHorizontal(h: Dp): Modifier = this.layout { measurable, constraints ->
    val extra = h.roundToPx() * 2
    val maxW = if (constraints.hasBoundedWidth) constraints.maxWidth + extra else constraints.maxWidth
    val p = measurable.measure(constraints.copy(minWidth = maxW.coerceAtMost(constraints.minWidth + extra), maxWidth = maxW))
    val w = if (constraints.hasBoundedWidth) constraints.maxWidth else p.width
    layout(w, p.height) { p.place(-extra / 2, 0) }
}

/** Netwerk/diensten aanroepen zonder dat een fout het scherm laat crashen (annuleren gaat wel door). */
suspend fun <T> screensSafe(block: suspend () -> T): T? = try {
    block()
} catch (c: kotlinx.coroutines.CancellationException) {
    throw c
} catch (_: Throwable) {
    null
}

/** Zoeken zonder accenten/hoofdletters. */
fun screensFold(s: String): String =
    Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()

/** Titel vergelijken: zonder accenten, leestekens en spaties. */
fun screensNormTitle(s: String): String = screensFold(s).filter { it.isLetterOrDigit() }

/** Waarde van onbekend type (String/Int/List) als tekst. */
fun screensText(v: Any?): String? = when (v) {
    null -> null
    is String -> v.ifBlank { null }
    is Collection<*> -> v.filterNotNull().joinToString(", ").ifBlank { null }
    is java.util.Date -> DateFormat.getDateInstance(DateFormat.LONG, Localizer.locale).format(v)
    else -> v.toString().ifBlank { null }
}

fun screensInt(v: Any?): Int? = when (v) {
    null -> null
    is Number -> v.toInt()
    is String -> v.trim().take(4).toIntOrNull() ?: v.filter { it.isDigit() }.toIntOrNull()
    else -> null
}

/** Datum (epoch-ms, Date of tekst) leesbaar. */
fun screensDate(v: Any?): String? = when (v) {
    null -> null
    is Long -> if (v <= 0) null else DateFormat.getDateInstance(DateFormat.LONG, Localizer.locale).format(java.util.Date(v))
    is java.util.Date -> DateFormat.getDateInstance(DateFormat.LONG, Localizer.locale).format(v)
    is String -> v.ifBlank { null }
    else -> v.toString()
}
