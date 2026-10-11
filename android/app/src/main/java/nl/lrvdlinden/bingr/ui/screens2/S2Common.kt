package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date

// Gedeelde bouwstenen voor de schermen in screens2/ (Live TV, gids, Mijn Bingr, beheren, …).
// Alles met voorvoegsel S2 om botsingen met andere bestanden in dezelfde package te voorkomen.

/** Achtergrondkleur van sheets (iOS 0x141414). */
val S2SheetBg = Color(0xFF141414)
val S2Grey = Color(0xFF8E8E93)

/** Maximale breedte van lijsten op TV/tablet (zoals de smalle lijsten op tvOS). */
val S2MaxWidth: Dp get() = if (AppState.isTV) 900.dp else 720.dp

fun s2Time(ms: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT, Localizer.locale).format(Date(ms))
fun s2DateTime(ms: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, Localizer.locale).format(Date(ms))
fun s2DateShort(ms: Long): String = SimpleDateFormat("EEE d MMM", Localizer.locale).format(Date(ms))

fun s2StartOfDay(ms: Long): Long = Calendar.getInstance().apply {
    timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

/** Een menu-actie (lang indrukken / menuknop). */
data class S2Action(val label: String, val icon: ImageVector? = null, val destructive: Boolean = false, val run: () -> Unit)

/**
 * Volledig scherm met terugknop en titel (tegenhanger van een NavigationStack-pagina).
 * Systeem-terug sluit het scherm.
 */
@Composable
fun S2Page(
    title: String,
    onClose: (() -> Unit)?,
    actions: @Composable RowScope.() -> Unit = {},
    state: LazyListState = rememberLazyListState(),
    content: LazyListScope.() -> Unit,
) {
    if (onClose != null) BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding()) {
        S2TopBar(title, onClose, actions)
        LazyColumn(
            Modifier.fillMaxSize(),
            state = state,
            horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(bottom = 40.dp),
            content = content
        )
    }
}

@Composable
fun S2TopBar(title: String, onClose: (() -> Unit)?, actions: @Composable RowScope.() -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Theme.edge - 4.dp, vertical = tvs(10)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (onClose != null) {
            S2IconButton(Icons.AutoMirrored.Filled.ArrowBack, L("Back"), onClick = onClose)
            Spacer(Modifier.width(8.dp))
        }
        Text(title, color = Color.White, fontSize = tsp(24), fontWeight = FontWeight.Bold, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        actions()
    }
}

/** Rond icoon-knopje (focusbaar, wit bij focus op TV). */
@Composable
fun S2IconButton(icon: ImageVector, description: String?, tint: Color = Color.White, size: Dp = tvs(22), onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        Modifier.onFocusChanged { focused = it.isFocused }
            .focusLift(1.12f, onClick = onClick)
            .clip(CircleShape)
            .background(if (focused && AppState.isTV) Color.White else Color.Transparent)
            .padding(tvs(8)),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, description, tint = if (focused && AppState.isTV) Color.Black else tint, modifier = Modifier.size(size))
    }
}

/** Sectiekop + afgeronde kaart met rijen (iOS inset grouped) + voettekst. */
@Composable
fun S2Section(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge)) {
        if (header != null) {
            Text(header.uppercase(), color = S2Grey, fontSize = tsp(12),
                modifier = Modifier.padding(start = 16.dp, top = 22.dp, bottom = 6.dp))
        } else Spacer(Modifier.height(18.dp))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Theme.card), content = content)
        if (footer != null) {
            Text(footer, color = S2Grey, fontSize = tsp(12), modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

/** Kop boven een lange lijst die als losse LazyColumn-items getekend wordt (zie [s2Cell]). */
@Composable
fun S2Header(text: String) {
    Text(text.uppercase(), color = S2Grey, fontSize = tsp(12),
        modifier = Modifier.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge)
            .padding(start = 16.dp, top = 22.dp, bottom = 6.dp))
}

@Composable
fun S2Footer(text: String) {
    Text(text, color = S2Grey, fontSize = tsp(12),
        modifier = Modifier.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge)
            .padding(start = 16.dp, end = 16.dp, top = 6.dp))
}

/** Eén cel van een lange gegroepeerde lijst: afgeronde hoeken alleen bovenaan/onderaan. */
fun Modifier.s2Cell(index: Int, count: Int): Modifier {
    val top = if (index == 0) 12.dp else 0.dp
    val bottom = if (index == count - 1) 12.dp else 0.dp
    return this.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge)
        .clip(RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom))
        .background(Theme.card)
}

@Composable
fun S2Divider() {
    Box(Modifier.fillMaxWidth().padding(start = 16.dp).height(0.5.dp).background(Color.White.copy(alpha = 0.12f)))
}

/**
 * Focusbare rij (afstandsbediening): bij focus iets groter met witte rand; geen grijze vlakken.
 */
@Composable
fun S2Row(
    title: String,
    icon: ImageVector? = null,
    value: String? = null,
    subtitle: String? = null,
    tint: Color = Color.White,
    enabled: Boolean = true,
    strike: Boolean = false,
    focusRequester: FocusRequester? = null,
    onLongClick: (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    var focused by remember { mutableStateOf(false) }
    val clickable = onClick != null && enabled
    val base = Modifier.fillMaxWidth().heightIn(min = tvs(48))
    val mod = if (clickable) {
        base.then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .onFocusChanged { focused = it.isFocused }
            .focusLift(1.02f, onLongClick = onLongClick, onClick = { onClick?.invoke() })
            .clip(RoundedCornerShape(10.dp))
            .then(if (focused) Modifier.border(2.dp, Color.White, RoundedCornerShape(10.dp)) else Modifier)
    } else base
    val alpha = if (enabled) 1f else 0.4f
    Row(mod.padding(horizontal = 16.dp, vertical = tvs(10)), verticalAlignment = Alignment.CenterVertically) {
        if (leading != null) { leading(); Spacer(Modifier.width(tvs(12))) }
        if (icon != null) {
            Icon(icon, null, tint = (if (tint == Color.White) Theme.red else tint).copy(alpha = alpha), modifier = Modifier.size(tvs(20)))
            Spacer(Modifier.width(tvs(12)))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = tint.copy(alpha = alpha * (if (strike) 0.6f else 1f)), fontSize = tsp(15), maxLines = if (onClick == null) 8 else 2,
                overflow = TextOverflow.Ellipsis, textDecoration = if (strike) TextDecoration.LineThrough else null)
            if (subtitle != null) Text(subtitle, color = Theme.secondary, fontSize = tsp(12), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (value != null) {
            Spacer(Modifier.width(8.dp))
            Text(value, color = Theme.secondary.copy(alpha = alpha), fontSize = tsp(14), maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = tvs(260)))
        }
        if (trailing != null) { Spacer(Modifier.width(8.dp)); trailing() }
    }
}

/** Rij met schakelaar; de hele rij is klikbaar/focusbaar. */
@Composable
fun S2Toggle(title: String, checked: Boolean, icon: ImageVector? = null, subtitle: String? = null, enabled: Boolean = true,
             onChange: (Boolean) -> Unit) {
    S2Row(title, icon = icon, subtitle = subtitle, enabled = enabled, onClick = { onChange(!checked) }, trailing = {
        Switch(checked = checked, onCheckedChange = null, enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = Theme.red, checkedThumbColor = Color.White,
                uncheckedTrackColor = Theme.elevated, uncheckedBorderColor = Theme.elevated, uncheckedThumbColor = Theme.secondary))
    })
}

/** Keuzelijst als dropdown (alle pickers in de app zijn dropdowns). */
@Composable
fun <T> S2Dropdown(
    title: String,
    options: List<Pair<T, String>>,
    selected: T,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    onSelect: (T) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.first == selected }?.second ?: ""
    Box {
        S2Row(title, icon = icon, value = current, enabled = enabled, onClick = { open = true }, trailing = {
            Icon(Icons.Default.ArrowDropDown, null, tint = Theme.secondary, modifier = Modifier.size(tvs(20)))
        })
        S2Menu(open, options, selected, onDismiss = { open = false }, onSelect = { open = false; onSelect(it) })
    }
}

/** Het uitklapmenu van [S2Dropdown]; het gekozen item krijgt focus (afstandsbediening). */
@Composable
fun <T> S2Menu(open: Boolean, options: List<Pair<T, String>>, selected: T, onDismiss: () -> Unit, onSelect: (T) -> Unit) {
    DropdownMenu(
        expanded = open,
        onDismissRequest = onDismiss,
        modifier = Modifier.background(Theme.elevated).heightIn(max = 460.dp)
    ) {
        val fr = remember { FocusRequester() }
        options.forEach { (v, label) ->
            val isSel = v == selected
            DropdownMenuItem(
                text = { Text(label, color = Color.White, fontSize = tsp(15), fontWeight = if (isSel) FontWeight.SemiBold else FontWeight.Normal) },
                trailingIcon = { if (isSel) Icon(Icons.Default.Check, null, tint = Theme.red) },
                onClick = { onSelect(v) },
                modifier = if (isSel) Modifier.focusRequester(fr) else Modifier
            )
        }
        LaunchedEffect(Unit) { runCatching { fr.requestFocus() } }
    }
}

/** Lijst met acties (lang indrukken / menuknop / ⋮), als dialoog zodat de focus erin blijft. */
@Composable
fun S2ActionDialog(title: String?, actions: List<S2Action>, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier.widthIn(min = 260.dp, max = 460.dp).clip(RoundedCornerShape(14.dp)).background(Theme.elevated)
                .verticalScroll(rememberScrollState()).padding(vertical = 8.dp)
        ) {
            if (title != null) {
                Text(title, color = Theme.secondary, fontSize = tsp(13), fontWeight = FontWeight.SemiBold, maxLines = 2,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp))
            }
            val fr = remember { FocusRequester() }
            actions.forEachIndexed { i, a ->
                S2Row(a.label, icon = a.icon, tint = if (a.destructive) Theme.red else Color.White,
                    focusRequester = if (i == 0) fr else null,
                    onClick = { onDismiss(); a.run() })
            }
            LaunchedEffect(Unit) { runCatching { fr.requestFocus() } }
        }
    }
}

/** Kleine "⋮"-knop rechts in een rij (zelfde acties als lang indrukken). */
@Composable
fun S2MoreButton(onClick: () -> Unit) {
    S2IconButton(Icons.Default.MoreVert, L("More"), tint = Theme.secondary, size = tvs(20), onClick = onClick)
}

/** Tekstveld in Netflix-stijl. */
@Composable
fun S2TextField(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    password: Boolean = false,
    plain: Boolean = true,
    leading: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        leadingIcon = leading,
        visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            capitalization = if (plain) KeyboardCapitalization.None else KeyboardCapitalization.Sentences,
            keyboardType = if (password) KeyboardType.Password else if (plain) KeyboardType.Uri else KeyboardType.Text
        ),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Color.White, unfocusedBorderColor = Color.White.copy(alpha = 0.25f),
            focusedLabelColor = Color.White, unfocusedLabelColor = Theme.secondary, cursorColor = Theme.red,
            focusedTextColor = Color.White, unfocusedTextColor = Color.White,
            focusedContainerColor = Theme.card, unfocusedContainerColor = Theme.card,
        ),
        modifier = modifier.fillMaxWidth()
    )
}

/** Segmenten (Live TV / Films / Series), zoals de iOS segmented picker. */
@Composable
fun <T> S2Segments(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Row(
        Modifier.widthIn(max = S2MaxWidth).fillMaxWidth().padding(horizontal = Theme.edge, vertical = 8.dp)
            .clip(RoundedCornerShape(10.dp)).background(Theme.card).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        options.forEach { (v, label) ->
            var focused by remember { mutableStateOf(false) }
            val sel = v == selected
            Box(
                Modifier.weight(1f).onFocusChanged { focused = it.isFocused }
                    .focusLift(1.04f) { onSelect(v) }
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (sel) Theme.elevated else Color.Transparent)
                    .then(if (focused) Modifier.border(2.dp, Color.White, RoundedCornerShape(8.dp)) else Modifier)
                    .padding(vertical = tvs(8)),
                contentAlignment = Alignment.Center
            ) {
                Text(label, color = if (sel) Color.White else Theme.secondary, fontSize = tsp(14), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** Volledig scherm als dialoog (eigen venster, dus focus blijft erin; terug sluit). */
@Composable
fun S2FullDialog(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
    ) {
        Box(Modifier.fillMaxSize().background(S2SheetBg).systemBarsPadding()) { content() }
    }
}

/** Genummerde stap (Koppelingen instellen). */
@Composable
fun S2Step(n: Int, text: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(22.dp).clip(CircleShape).background(Theme.red), contentAlignment = Alignment.Center) {
            Text("$n", color = Color.White, fontSize = tsp(12), fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.width(10.dp))
        Text(text, color = Color.White, fontSize = tsp(14), modifier = Modifier.weight(1f))
    }
}
