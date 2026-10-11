package nl.lrvdlinden.bingr

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.text.Collator

/** Een categorie die volledig getoond wordt ("Bekijk allemaal"). */
data class CategoryTarget(val title: String, val items: List<DetailTarget>)

private enum class CategorySort(val raw: String) {
    STANDARD("standard"), AZ("az"), ZA("za"), NEWEST("newest"), RATING("rating");

    val title: String
        get() = when (this) {
            STANDARD -> L("Default")
            AZ -> L("Title (A–Z)")
            ZA -> L("Title (Z–A)")
            NEWEST -> L("Recently added")
            RATING -> L("Highest rated")
        }
}

private fun categoryRating(t: DetailTarget): Double? {
    val imdb = when (t) {
        is DetailTarget.MovieT -> Metadata.cached(t.movie)?.imdbRating
        is DetailTarget.SeriesT -> Metadata.cached(t.series)?.imdbRating
    }
    imdb?.toDoubleOrNull()?.let { return it }
    return t.rating?.takeIf { it > 0 }
}

private fun categoryPoster(t: DetailTarget): String? = when (t) {
    is DetailTarget.MovieT -> t.movie.poster ?: Metadata.cached(t.movie)?.poster
    is DetailTarget.SeriesT -> t.series.poster ?: Metadata.cached(t.series)?.poster
}

/** Categoriepagina zoals in UHF: terug, titel in hoofdletters, sorteren en een raster met score (= CategoryView.swift). */
@Composable
fun CategoryScreen(target: CategoryTarget, onClose: () -> Unit) {
    val tv = AppState.isTV
    BackHandler { onClose() }
    var sortRaw by remember { mutableStateOf(Prefs.string("category.sort") ?: CategorySort.STANDARD.raw) }
    val sort = CategorySort.entries.firstOrNull { it.raw == sortRaw } ?: CategorySort.STANDARD
    var menu by remember { mutableStateOf(false) }
    val metaVersion = Metadata.version
    val sorted = remember(target, sort, metaVersion) {
        val items = target.items
        val collator = Collator.getInstance(Localizer.locale).apply { strength = Collator.PRIMARY }
        when (sort) {
            CategorySort.STANDARD -> items
            CategorySort.AZ -> items.sortedWith { a, b -> collator.compare(a.title, b.title) }
            CategorySort.ZA -> items.sortedWith { a, b -> collator.compare(b.title, a.title) }
            CategorySort.NEWEST -> items.sortedByDescending { (it as? DetailTarget.MovieT)?.movie?.addedAt ?: Long.MIN_VALUE }
            CategorySort.RATING -> items.sortedByDescending { categoryRating(it) ?: -1.0 }
        }
    }
    val firstFocus = rememberInitialFocus()

    Column(Modifier.fillMaxSize().background(Theme.bg).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(start = Theme.edge - tvs(6), end = Theme.edge - tvs(6), top = tvs(6)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tvs(12))
        ) {
            if (!tv) {
                Box(Modifier.size(40.dp).focusLift { onClose() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, L("Back"), tint = Color.White, modifier = Modifier.size(24.dp))
                }
            }
            Text(
                target.title.uppercase(), color = Color.White, fontSize = Theme.titleSize, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f)
            )
            Box {
                Box(
                    Modifier.size(tvs(40)).focusLift(1.12f) { menu = true }.clip(CircleShape)
                        .background(if (tv) Color.White.copy(alpha = 0.1f) else Color.Transparent),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Default.SwapVert, L("Sort"), tint = Color.White, modifier = Modifier.size(tvs(22)))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    CategorySort.entries.forEach { s ->
                        DropdownMenuItem(
                            text = { Text(s.title) },
                            leadingIcon = {
                                if (s == sort) Icon(Icons.Default.Check, null) else Spacer(Modifier.size(24.dp))
                            },
                            onClick = {
                                menu = false
                                sortRaw = s.raw
                                Prefs.put("category.sort", s.raw)
                            }
                        )
                    }
                }
            }
        }

        LazyVerticalGrid(
            columns = if (tv) GridCells.Fixed(6) else GridCells.Adaptive(150.dp),
            contentPadding = PaddingValues(horizontal = Theme.edge, vertical = tvs(12)),
            horizontalArrangement = Arrangement.spacedBy(if (tv) 28.dp else 14.dp),
            verticalArrangement = Arrangement.spacedBy(tvs(18)),
            modifier = Modifier.fillMaxSize()
        ) {
            itemsIndexed(sorted) { i, t ->
                CategoryCell(
                    t,
                    Modifier
                        .then(if (i == 0) Modifier.focusRequester(firstFocus) else Modifier)
                        .focusLift(1.06f) { ScreensNav.detail(t) }
                )
            }
        }
    }
}

@Composable
private fun CategoryCell(t: DetailTarget, modifier: Modifier) {
    val watched = (t as? DetailTarget.MovieT)?.let { Playables.isWatched(it.movie, Trakt.imdb(it.movie)) } ?: false
    val rating = categoryRating(t)
    Column(modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(tvs(6)))) {
            RemoteImage(categoryPoster(t), Modifier.matchParentSize(), placeholder = t.title)
            if (watched) {
                Box(
                    Modifier.align(Alignment.TopStart).padding(6.dp).size(tvs(20)).clip(CircleShape).background(Theme.red),
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(tvs(13))) }
            }
            if (rating != null) {
                Row(
                    Modifier.align(Alignment.TopEnd).padding(6.dp).clip(RoundedCornerShape(4.dp)).background(Theme.imdb)
                        .padding(horizontal = 6.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Default.Star, null, tint = Color.Black, modifier = Modifier.size(tvs(10)))
                    Spacer(Modifier.width(3.dp))
                    Text(String.format(java.util.Locale.US, "%.1f", rating), color = Color.Black, fontSize = tsp(11), fontWeight = FontWeight.Bold)
                }
            }
        }
        Spacer(Modifier.height(tvs(6)))
        Text(
            t.title, color = Color.White, fontSize = tsp(13), fontWeight = FontWeight.SemiBold,
            maxLines = 2, overflow = TextOverflow.Ellipsis
        )
    }
}
