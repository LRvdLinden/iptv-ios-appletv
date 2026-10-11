package nl.lrvdlinden.bingr

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.MergeType
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

enum class S2Kind { LIVE, MOVIES, SERIES }

private val s2KindOptions: List<Pair<S2Kind, String>>
    get() = listOf(S2Kind.LIVE to L("Live TV"), S2Kind.MOVIES to L("Movies"), S2Kind.SERIES to L("Series"))

private fun s2RawGroups(kind: S2Kind): List<String> {
    val raw = Playlists.rawLibrary
    return when (kind) {
        S2Kind.LIVE -> raw.channels.map { it.group }
        S2Kind.MOVIES -> raw.movies.map { it.group }
        S2Kind.SERIES -> raw.series.map { it.group }
    }.distinct()
}

private val s2PrefixRE = Regex("""^\s*[|\[({]?\s*([A-Z]{2,4}|[A-Z]{2}\+)\s*(?:[|\])}:\-–•]|\s+\|)""")
private val s2PrefixSkip = setOf("THE", "AND", "FOR", "ALL", "NEW", "TOP", "VOD", "TV")

/** Land-/taalvoorvoegsel van een categorie ("NL | Sport" → "NL"). */
fun s2GroupPrefix(g: String): String? {
    val p = s2PrefixRE.find(g)?.groupValues?.getOrNull(1)?.uppercase() ?: return null
    return if (p in s2PrefixSkip) null else p
}

/** Categorieën aan/uit per onderdeel, met snelknoppen per land/taal (NL, BE, DE …). */
@Composable
fun CategoriesScreen(onClose: () -> Unit) {
    var kind by remember { mutableStateOf(S2Kind.LIVE) }
    var filter by remember { mutableStateOf("") }
    val pid = Playlists.source?.id
    val c = pid?.let { Store.customizations[it] } ?: Customization()
    val all = remember(kind, Playlists.rawLibrary) { s2RawGroups(kind) }
    val groups = if (filter.isBlank()) all else all.filter { it.contains(filter.trim(), ignoreCase = true) }
    val prefixes = remember(groups) {
        groups.mapNotNull { g -> s2GroupPrefix(g)?.let { it to g } }.groupBy({ it.first }, { it.second })
            .entries.sortedWith(compareByDescending<Map.Entry<String, List<String>>> { it.value.size }.thenBy { it.key })
            .map { it.key to it.value }
    }
    fun isOn(g: String) = Customization.groupKey(g) !in c.hidden
    fun set(list: List<String>, on: Boolean) {
        val id = pid ?: return
        Store.updateCustomization(id) { cu ->
            val keys = list.map { Customization.groupKey(it) }.toSet()
            cu.copy(hidden = if (on) cu.hidden - keys else cu.hidden + keys)
        }
    }

    S2Page(L("Categories"), onClose = onClose) {
        item { S2Segments(s2KindOptions, kind) { kind = it; filter = "" } }
        if (!AppState.isTV) item {
            S2TextField(filter, { filter = it }, L("Search category"),
                modifier = Modifier.widthIn(max = S2MaxWidth).padding(horizontal = Theme.edge),
                leading = { Icon(Icons.Default.Search, null, tint = Theme.secondary) })
        }
        if (prefixes.isNotEmpty()) {
            item { S2Header(L("Countries & languages")) }
            item {
                LazyRow(Modifier.widthIn(max = S2MaxWidth).fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = Theme.edge, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(tvs(10))) {
                    items(prefixes) { (code, list) ->
                        val onCount = list.count { isOn(it) }
                        val allOn = onCount == list.size
                        S2PrefixChip(code, onCount, list.size, allOn) { set(list, !allOn) }
                    }
                }
            }
            item { S2Footer(L("Tap a code to turn all its categories on or off at once.")) }
        }
        item { S2Header(L("Categories (%d)", groups.size)) }
        item {
            Row(Modifier.s2Cell(0, 2).padding(horizontal = 4.dp)) {
                Box(Modifier.weight(1f)) { S2Row(L("All on"), tint = Theme.red, onClick = { set(groups, true) }) }
                Box(Modifier.weight(1f)) { S2Row(L("All off"), tint = Theme.red, onClick = { set(groups, false) }) }
            }
        }
        itemsIndexed(groups) { i, g ->
            Column(Modifier.s2Cell(i + 1, groups.size + 1)) {
                S2Toggle(c.renamed[Customization.groupKey(g)] ?: g, isOn(g)) { set(listOf(g), it) }
            }
        }
        item { S2Footer(L("Categories that are off don't appear anywhere in the app. Saved per playlist.")) }
    }
}

@Composable
private fun S2PrefixChip(code: String, on: Int, total: Int, allOn: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.onFocusChanged { focused = it.isFocused }
            .focusLift(1.08f, onClick = onClick)
            .clip(RoundedCornerShape(50))
            .background(if (allOn) Theme.red.copy(alpha = 0.85f) else Theme.elevated)
            .then(if (focused) Modifier.border(2.dp, Color.White, RoundedCornerShape(50)) else Modifier)
            .padding(horizontal = tvs(12), vertical = tvs(7)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(if (allOn) Icons.Default.CheckCircle else if (on == 0) Icons.Default.RadioButtonUnchecked else Icons.Default.RemoveCircle,
            null, tint = Color.White, modifier = Modifier.size(tvs(14)))
        Spacer(Modifier.width(6.dp))
        Text(code, color = Color.White, fontWeight = FontWeight.Bold, fontSize = tsp(14))
        Spacer(Modifier.width(6.dp))
        Text("$on/$total", color = Theme.secondary, fontSize = tsp(14))
    }
}

/** Hernoemen: leeg laten = oorspronkelijke naam. */
@Composable
fun S2RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(current) }
    val fr = remember { FocusRequester() }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Theme.elevated,
        title = { Text(L("Rename"), color = Color.White) },
        text = {
            Column {
                S2TextField(text, { text = it }, current, plain = false, modifier = Modifier.focusRequester(fr))
                Spacer(Modifier.height(8.dp))
                Text(L("Leave empty to restore the original name."), color = Theme.secondary, fontSize = tsp(12))
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text.trim()); onDismiss() }) { Text(L("Save"), color = Theme.red) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(L("Cancel"), color = Color.White) } }
    )
    LaunchedEffect(Unit) { runCatching { fr.requestFocus() } }
}

private fun <T> List<T>.swapped(i: Int, j: Int): List<T> {
    if (i !in indices || j !in indices) return this
    val m = toMutableList(); val t = m[i]; m[i] = m[j]; m[j] = t; return m
}

/** Beheren: groepen en zenders hernoemen, herschikken, samenvoegen, verbergen en op slot zetten. */
@Composable
fun ManageScreen(onClose: () -> Unit) {
    var kind by remember { mutableStateOf(S2Kind.LIVE) }
    var channelsOf by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<Pair<String, String>?>(null) }
    var merging by remember { mutableStateOf<String?>(null) }

    val openGroup = channelsOf
    if (openGroup != null) {
        S2ChannelsManageScreen(openGroup) { channelsOf = null }
        return
    }

    val pid = Playlists.source?.id
    val c = pid?.let { Store.customizations[it] } ?: Customization()
    val raw = remember(kind, Playlists.rawLibrary) { s2RawGroups(kind) }
    val groups: List<String> = run {
        val visible = raw.filter { c.merged[it] == null }
        if (kind != S2Kind.LIVE || c.groupOrder.isEmpty()) visible
        else {
            val idx = HashMap<String, Int>()
            c.groupOrder.forEachIndexed { i, g -> if (g !in idx) idx[g] = i }
            visible.withIndex().sortedBy { idx[it.value] ?: (10_000 + it.index) }.map { it.value }
        }
    }
    val merged = raw.filter { c.merged[it] != null }
    fun display(g: String) = c.renamed[Customization.groupKey(g)] ?: g
    fun update(change: (Customization) -> Customization) { pid?.let { Store.updateCustomization(it, change) } }
    fun moveGroup(g: String, step: Int) {
        val i = groups.indexOf(g); if (i < 0) return
        update { it.copy(groupOrder = groups.swapped(i, (i + step).coerceIn(0, groups.size - 1))) }
    }

    S2Page(L("Manage"), onClose = onClose) {
        item { S2Segments(s2KindOptions, kind) { kind = it } }
        item { S2Header(L("Groups")) }
        itemsIndexed(groups) { i, g ->
            val key = Customization.groupKey(g)
            val hidden = key in c.hidden
            val locked = pid != null && "$pid|$g" in Store.parental.lockedGroups
            Column(Modifier.s2Cell(i, groups.size)) {
                S2Row(
                    title = display(g),
                    subtitle = if (display(g) != g) g else null,
                    tint = if (hidden) Theme.secondary else Color.White,
                    strike = hidden,
                    onLongClick = { menuFor = g },
                    onClick = { if (kind == S2Kind.LIVE) channelsOf = g else menuFor = g },
                    trailing = {
                        if (locked) Icon(Icons.Default.Lock, null, tint = Theme.imdb, modifier = Modifier.size(tvs(16)))
                        if (hidden) Icon(Icons.Default.VisibilityOff, null, tint = Theme.secondary, modifier = Modifier.size(tvs(16)))
                        S2MoreButton { menuFor = g }
                    }
                )
            }
        }
        item { S2Footer(L("Hidden groups and channels don't appear anywhere in the app. Merged groups are shown as one.")) }
        if (merged.isNotEmpty()) {
            item { S2Header(L("Merged")) }
            itemsIndexed(merged) { i, g ->
                Column(Modifier.s2Cell(i, merged.size)) {
                    S2Row(g, value = "→ ${c.merged[g] ?: ""}", onClick = { update { it.copy(merged = it.merged - g) } }, trailing = {
                        Text(L("Undo"), color = Theme.red, fontSize = tsp(14), fontWeight = FontWeight.SemiBold)
                    })
                }
            }
        }
        item {
            S2Section {
                S2Row(L("Reset all changes"), tint = Theme.red, onClick = { pid?.let { Store.updateCustomization(it) { Customization() } } })
            }
        }
    }

    menuFor?.let { g ->
        val key = Customization.groupKey(g)
        val hidden = key in c.hidden
        val locked = pid != null && "$pid|$g" in Store.parental.lockedGroups
        val actions = buildList {
            add(S2Action(L("Rename"), Icons.Default.Edit) { renaming = key to display(g) })
            add(S2Action(if (hidden) L("Show") else L("Hide"), if (hidden) Icons.Default.Visibility else Icons.Default.VisibilityOff) {
                update { it.copy(hidden = if (hidden) it.hidden - key else it.hidden + key) }
            })
            add(S2Action(L("Merge into…"), Icons.Default.MergeType) { merging = g })
            if (Store.parental.enabled && pid != null) {
                add(S2Action(if (locked) L("Unlock") else L("Lock with PIN"), if (locked) Icons.Default.LockOpen else Icons.Default.Lock) {
                    ParentalControl.toggleLock(pid, g)
                })
            }
            if (kind == S2Kind.LIVE) {
                add(S2Action(L("Move up"), Icons.Default.KeyboardArrowUp) { moveGroup(g, -1) })
                add(S2Action(L("Move down"), Icons.Default.KeyboardArrowDown) { moveGroup(g, 1) })
            }
        }
        S2ActionDialog(display(g), actions, onDismiss = { menuFor = null })
    }
    merging?.let { m ->
        S2ActionDialog(L("Merge into…"), groups.filter { it != m }.map { target ->
            S2Action(display(target), Icons.AutoMirrored.Filled.ArrowForward) { update { it.copy(merged = it.merged + (m to target)) } }
        }, onDismiss = { merging = null })
    }
    renaming?.let { (id, current) ->
        S2RenameDialog(current, onDismiss = { renaming = null }) { new ->
            update { it.copy(renamed = if (new.isEmpty()) it.renamed - id else it.renamed + (id to new)) }
        }
    }
}

/** Zenders binnen één groep: hernoemen, verbergen, volgorde. */
@Composable
private fun S2ChannelsManageScreen(group: String, onClose: () -> Unit) {
    var menuFor by remember { mutableStateOf<Channel?>(null) }
    var renaming by remember { mutableStateOf<Pair<String, String>?>(null) }
    val pid = Playlists.source?.id
    val c = pid?.let { Store.customizations[it] } ?: Customization()
    val channels: List<Channel> = run {
        val list = Playlists.rawLibrary.channels.filter { it.group == group || c.merged[it.group] == group }
        val order = c.channelOrder[group]
        if (order.isNullOrEmpty()) list
        else {
            val idx = HashMap<String, Int>()
            order.forEachIndexed { i, id -> if (id !in idx) idx[id] = i }
            list.withIndex().sortedBy { idx[it.value.id] ?: (10_000 + it.index) }.map { it.value }
        }
    }
    fun update(change: (Customization) -> Customization) { pid?.let { Store.updateCustomization(it, change) } }
    fun moveChannel(id: String, step: Int) {
        val ids = channels.map { it.id }
        val i = ids.indexOf(id); if (i < 0) return
        val n = ids.swapped(i, (i + step).coerceIn(0, ids.size - 1))
        update { it.copy(channelOrder = it.channelOrder + (group to n)) }
    }

    S2Page(group, onClose = onClose) {
        item { Spacer(Modifier.height(12.dp)) }
        itemsIndexed(channels) { i, ch ->
            val hidden = ch.id in c.hidden
            Column(Modifier.s2Cell(i, channels.size)) {
                S2Row(
                    title = c.renamed[ch.id] ?: ch.name,
                    tint = if (hidden) Theme.secondary else Color.White,
                    strike = hidden,
                    onLongClick = { menuFor = ch },
                    onClick = { menuFor = ch },
                    leading = {
                        RemoteImage(ch.logo, Modifier.width(tvs(44)).height(tvs(28)).clip(RoundedCornerShape(4.dp)),
                            placeholder = ch.name.take(3), fit = true)
                    },
                    trailing = {
                        if (hidden) Icon(Icons.Default.VisibilityOff, null, tint = Theme.secondary, modifier = Modifier.size(tvs(16)))
                    }
                )
            }
        }
    }

    menuFor?.let { ch ->
        val hidden = ch.id in c.hidden
        S2ActionDialog(c.renamed[ch.id] ?: ch.name, listOf(
            S2Action(L("Rename"), Icons.Default.Edit) { renaming = ch.id to (c.renamed[ch.id] ?: ch.name) },
            S2Action(if (hidden) L("Show") else L("Hide"), if (hidden) Icons.Default.Visibility else Icons.Default.VisibilityOff) {
                update { it.copy(hidden = if (hidden) it.hidden - ch.id else it.hidden + ch.id) }
            },
            S2Action(L("Move up"), Icons.Default.KeyboardArrowUp) { moveChannel(ch.id, -1) },
            S2Action(L("Move down"), Icons.Default.KeyboardArrowDown) { moveChannel(ch.id, 1) },
        ), onDismiss = { menuFor = null })
    }
    renaming?.let { (id, current) ->
        S2RenameDialog(current, onDismiss = { renaming = null }) { new ->
            update { it.copy(renamed = if (new.isEmpty()) it.renamed - id else it.renamed + (id to new)) }
        }
    }
}
