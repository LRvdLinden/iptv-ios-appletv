package nl.lrvdlinden.bingr

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Poster in 2:3 met "bekeken"-vinkje, label en voortgangsbalk. */
@Composable
fun PosterCard(
    title: String,
    poster: String?,
    modifier: Modifier = Modifier,
    width: Dp = Theme.posterWidth,
    watched: Boolean = false,
    progress: Double? = null,
    badge: String? = null,
    rating: Double? = null,
) {
    Box(modifier.width(width).height(width * 1.5f).clip(RoundedCornerShape(4.dp))) {
        RemoteImage(poster, Modifier.matchParentSize(), placeholder = title)
        if (watched) {
            Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(tvs(20)).clip(CircleShape).background(Theme.red),
                contentAlignment = Alignment.Center) { Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(tvs(13))) }
        }
        if (rating != null && rating > 0) {
            Row(Modifier.align(Alignment.TopEnd).padding(5.dp).clip(RoundedCornerShape(4.dp)).background(Theme.imdb)
                .padding(horizontal = 5.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Star, null, tint = Color.Black, modifier = Modifier.size(tvs(10)))
                Text(String.format("%.1f", rating), color = Color.Black, fontSize = tsp(10), fontWeight = FontWeight.Bold)
            }
        }
        if (badge != null) {
            Text(badge, color = Color.White, fontSize = tsp(9), fontWeight = FontWeight.Black,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = if (progress == null) 6.dp else 10.dp)
                    .clip(RoundedCornerShape(2.dp)).background(Theme.red).padding(horizontal = 5.dp, vertical = 2.dp))
        }
        if (progress != null && progress > 0) ProgressBar(progress, Modifier.align(Alignment.BottomCenter))
    }
}

/** Netflix-Top 10: groot zwart cijfer met grijze rand, poster schuift er half overheen. */
@Composable
fun Top10Card(rank: Int, title: String, poster: String?, watched: Boolean = false, badge: String? = null) {
    val w = Theme.posterWidth * 1.08f
    val h = w * 1.5f
    val measurer = rememberTextMeasurer()
    val numW = if (rank >= 10) h * 0.78f else h * 0.46f
    Row(verticalAlignment = Alignment.Bottom) {
        Box(Modifier.width(numW).height(h).drawWithContent {
            val style = TextStyle(fontSize = (h.value * 0.86f).sp, fontWeight = FontWeight.Black, letterSpacing = (-4).sp)
            val layout = measurer.measure("$rank", style)
            val x = size.width - layout.size.width + size.width * 0.12f
            val y = size.height - layout.size.height * 0.92f
            drawText(layout, color = Color.Black, topLeft = androidx.compose.ui.geometry.Offset(x, y))
            drawText(layout, color = Color(0xFF8C8C8C), topLeft = androidx.compose.ui.geometry.Offset(x, y),
                drawStyle = Stroke(width = (h.value / 45f).coerceAtLeast(3f)))
        })
        Box(Modifier.offset(x = -(h * 0.16f))) {
            PosterCard(title, poster, width = w, watched = watched, badge = badge)
            Column(Modifier.padding(5.dp).clip(RoundedCornerShape(2.dp)).background(Theme.red).padding(horizontal = 3.dp, vertical = 1.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Text("TOP", color = Color.White, fontSize = tsp(6), fontWeight = FontWeight.Black, lineHeight = tsp(7))
                Text("10", color = Color.White, fontSize = tsp(11), fontWeight = FontWeight.Black, lineHeight = tsp(11))
            }
        }
    }
}

/** Horizontale rij met titel en "Bekijk allemaal" (Netflix "rij"). */
@Composable
fun MediaRow(
    title: String,
    onSeeAll: (() -> Unit)? = null,
    content: LazyListScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edge), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = Color.White, fontSize = Theme.titleSize, fontWeight = FontWeight.Bold, maxLines = 1,
                modifier = Modifier.weight(1f))
            if (onSeeAll != null) {
                Text(L("See all"), color = Color.White, fontSize = tsp(14), fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.focusLift(1.06f, dimWhenIdle = true, onClick = onSeeAll).padding(6.dp))
            }
        }
        Spacer(Modifier.height(tvs(8)))
        LazyRow(
            contentPadding = PaddingValues(horizontal = Theme.edge, vertical = if (AppState.isTV) 14.dp else 0.dp),
            horizontalArrangement = Arrangement.spacedBy(Theme.rowSpacing),
            content = content
        )
    }
}

/** Zenderkaart (logo + wat er nu speelt). */
@Composable
fun ChannelCard(channel: Channel, now: EPGProgram?, favorite: Boolean = false, modifier: Modifier = Modifier) {
    Column(modifier.width(tvs(180)).clip(RoundedCornerShape(6.dp)).background(Theme.card).padding(10.dp)) {
        Box(Modifier.fillMaxWidth().height(tvs(60))) {
            RemoteImage(channel.logo, Modifier.matchParentSize(), placeholder = channel.name.take(3), fit = true)
            if (favorite) Icon(Icons.Default.Star, null, tint = Theme.imdb, modifier = Modifier.align(Alignment.TopEnd).size(14.dp))
        }
        Spacer(Modifier.height(6.dp))
        Text(channel.name, color = Color.White, fontSize = tsp(13), fontWeight = FontWeight.SemiBold, maxLines = 1)
        if (now != null) {
            Text(now.title, color = Theme.secondary, fontSize = tsp(11), maxLines = 1)
            Spacer(Modifier.height(4.dp)); ProgressBar(now.progress)
        }
    }
}

/** Sectiekop zoals in Instellingen. */
@Composable
fun SectionHeader(text: String) {
    Text(text.uppercase(), color = Color(0xFF8E8E93), fontSize = tsp(12),
        modifier = Modifier.padding(start = Theme.edge + 16.dp, top = 18.dp, bottom = 6.dp), textAlign = TextAlign.Start)
}

// MARK: avatars (profielen en servers)

/** Drawable-id van een getekend figuurtje ("kid01" … "kid16", res/drawable-nodpi), of null. */
fun avatarDrawable(symbol: String): Int? = when (symbol) {
    "kid01" -> R.drawable.kid01; "kid02" -> R.drawable.kid02; "kid03" -> R.drawable.kid03; "kid04" -> R.drawable.kid04
    "kid05" -> R.drawable.kid05; "kid06" -> R.drawable.kid06; "kid07" -> R.drawable.kid07; "kid08" -> R.drawable.kid08
    "kid09" -> R.drawable.kid09; "kid10" -> R.drawable.kid10; "kid11" -> R.drawable.kid11; "kid12" -> R.drawable.kid12
    "kid13" -> R.drawable.kid13; "kid14" -> R.drawable.kid14; "kid15" -> R.drawable.kid15; "kid16" -> R.drawable.kid16
    else -> null
}

/** Drawable-id van het figuurtje van deze avatar (null = emoji). */
val PlaylistAvatar.drawableRes: Int? get() = if (isIllustration) avatarDrawable(symbol) else null

/**
 * Ronde avatar: foto, getekend figuurtje of emoji op kleurverloop.
 * [ring] = witte rand (focus op TV), [editing] = potloodje erover, [badge] = rood rondje met poppetje rechtsonder
 * (hoofdaccount).
 */
@Composable
fun AvatarView(
    avatar: PlaylistAvatar,
    photo: Bitmap?,
    size: Dp,
    ring: Boolean = false,
    editing: Boolean = false,
    badge: Boolean = false,
) {
    val pal = PlaylistAvatar.palettes[Math.floorMod(avatar.colorIndex, PlaylistAvatar.palettes.size)]
    val image = remember(photo) { photo?.asImageBitmap() }
    Box(Modifier.size(size)) {
        Box(
            Modifier.matchParentSize().clip(CircleShape)
                .background(Brush.linearGradient(listOf(Color(pal.first), Color(pal.second)))),
            contentAlignment = Alignment.Center
        ) {
            val res = avatar.drawableRes
            when {
                image != null -> Image(image, null, Modifier.matchParentSize(), contentScale = ContentScale.Crop)
                res != null -> Image(painterResource(res), null, Modifier.matchParentSize(), contentScale = ContentScale.Crop)
                else -> Text(avatar.symbol, fontSize = (size.value * 0.42f).sp)
            }
            if (editing) {
                Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Edit, null, tint = Color.White, modifier = Modifier.size(size * 0.3f))
                }
            }
        }
        if (ring) Box(Modifier.matchParentSize().border(tvs(3), Color.White, CircleShape))
        if (badge) {
            val b = (size * 0.24f).coerceIn(16.dp, 36.dp)
            Box(
                Modifier.align(Alignment.BottomEnd).size(b).clip(CircleShape).background(Theme.red)
                    .border(2.dp, Color.Black, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.Person, null, tint = Color.White, modifier = Modifier.size(b * 0.6f))
            }
        }
    }
}

/**
 * Avatar van een kijkprofiel (standaard het actieve profiel): foto, figuurtje of emoji.
 * Zonder profiel een donkere cirkel.
 */
@Composable
fun ProfileAvatar(
    profile: ViewerProfile? = Store.activeProfile,
    size: Dp,
    ring: Boolean = false,
    editing: Boolean = false,
    badge: Boolean = false,
) {
    if (profile == null) {
        Box(Modifier.size(size).clip(CircleShape).background(Theme.elevated)
            .then(if (ring) Modifier.border(tvs(3), Color.White, CircleShape) else Modifier))
        return
    }
    val v = Store.photoVersion
    val photo = remember(profile.id, v) { Store.photo(profile.id) }
    AvatarView(profile.avatar, photo, size, ring = ring, editing = editing, badge = badge)
}
