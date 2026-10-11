package nl.lrvdlinden.bingr

import kotlinx.serialization.Serializable
import java.util.UUID

// Alle code van de Android-app staat in één package (nl.lrvdlinden.bingr); mappen zijn alleen ordening.
// Tijden zijn epoch-milliseconden (Long), URL's zijn Strings.

@Serializable
enum class PlaylistKind(val raw: String) {
    M3U("M3U / M3U8"), XTREAM("Xtream Codes"), STALKER("Stalker / MAC-portal"),
    PLEX("Plex"), JELLYFIN("Jellyfin"), EMBY("Emby"), STREMIO("Stremio");

    val title: String
        get() = when (this) {
            M3U -> "M3U"; XTREAM -> "Xtream"; STALKER -> L("MAC portal"); else -> raw
        }
    val isMediaServer: Boolean get() = this in setOf(PLEX, JELLYFIN, EMBY, STREMIO)
}

/**
 * Avatar van een profiel/bron: emoji op een kleurverloop (Netflix-stijl), of een getekend figuurtje
 * ([symbol] begint met "kid": res/drawable-nodpi/kid01.png … kid16.png, zie [avatarDrawable]).
 */
@Serializable
data class PlaylistAvatar(val symbol: String = "📺", val colorIndex: Int = 0) {
    /** Getekend figuurtje (kid01…kid16) in plaats van een emoji */
    val isIllustration: Boolean get() = symbol.startsWith("kid")

    companion object {
        /** Getekende figuurtjes (res/drawable-nodpi/kid01.png …), te kiezen als profielafbeelding. */
        val illustrations: List<String> = (1..16).map { String.format(java.util.Locale.ROOT, "kid%02d", it) }
        val symbols = listOf("📺", "🌐", "⚽", "👑", "🔥", "🎬", "🍿", "⭐", "🎮", "🌙", "⚡", "❤️", "🎵", "🏆", "🐰", "🦁", "🚀", "🌈", "🎭", "🧸", "🦄", "🐼", "☕", "🎧")
        val palettes: List<Pair<Long, Long>> = listOf(
            0xFFE50914 to 0xFF7A0008, 0xFF2563EB to 0xFF1E1B4B, 0xFF10B981 to 0xFF064E3B, 0xFFF59E0B to 0xFF9A3412,
            0xFFA855F7 to 0xFF3B0764, 0xFFEC4899 to 0xFF831843, 0xFF14B8A6 to 0xFF0C4A6E, 0xFF64748B to 0xFF0F172A
        )
        fun random() = PlaylistAvatar(symbols.random(), palettes.indices.random())
        /** Willekeurig getekend figuurtje (kinderprofiel). */
        fun randomIllustration() = PlaylistAvatar(illustrations.random(), palettes.indices.random())
    }
}

/**
 * Kijkprofiel ("Wie kijkt er?"). Alle profielen gebruiken dezelfde server(s) van het hoofdaccount,
 * maar hebben elk hun eigen Mijn lijst, favorieten, voortgang, bekeken, recente zenders, geschiedenis,
 * kijkvoorkeuren, pincode en leeftijdsgrens (= ViewerProfile in Models.swift).
 * Foto: [Store.photo] met [id]. Pincode: [ParentalControl.hasPIN] (profiel).
 */
@Serializable
data class ViewerProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val avatar: PlaylistAvatar = PlaylistAvatar.random(),
    /** Leeftijdsfilter (null = geen), bijv. 12 voor een kinderprofiel */
    val ageLimit: Int? = null,
    val createdAt: Long = System.currentTimeMillis(),
    // Persoonlijke kijkvoorkeuren (null = nog niet ingesteld)
    val autoSubtitles: Boolean? = null,
    /** OpenSubtitles-standaardtaal ("" = alle talen) */
    val subtitleLanguage: String? = null,
    /** standaard audiotaal in de stream ("" = zoals de stream) */
    val audioLanguage: String? = null,
    /** standaard ondertitelspoor in de stream ("" / "off" / code) */
    val streamSubtitleLanguage: String? = null,
    /** Kinderprofiel: alleen kinderinhoud (standaard t/m 12 jaar) */
    val isKids: Boolean? = null,
) {
    val kids: Boolean get() = isKids ?: false
    /** Leeftijdsgrens die echt geldt (kinderprofiel zonder grens = t/m 12) */
    val effectiveAgeLimit: Int? get() = ageLimit ?: if (kids) 12 else null
    /** Streng filteren (alleen zeker geschikte titels): kinderprofiel of grens t/m 12 */
    val strictAgeFilter: Boolean get() = kids || (effectiveAgeLimit ?: 99) <= 12
}

/** Een bron/profiel. Wachtwoord staat apart in [Store.secret] onder [passwordKey]. */
@Serializable
data class PlaylistSource(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val kind: PlaylistKind,
    val avatar: PlaylistAvatar = PlaylistAvatar.random(),
    val m3uURL: String = "",
    val epgURL: String = "",
    val serverURL: String = "",
    val username: String = "",
    val macAddress: String = "",
    val preferHLS: Boolean = false,
    /** Verouderd (van vóór de kijkprofielen): leeftijdsfilter staat nu op [ViewerProfile.ageLimit]. Alleen nog voor migratie. */
    val ageLimit: Int? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val passwordKey: String get() = "playlist.$id.password"
}

@Serializable
enum class MediaType { LIVE, MOVIE, SERIES, EPISODE }

@Serializable
data class Channel(
    val id: String,
    val name: String,
    val logo: String? = null,
    val group: String = "",
    val streamURL: String? = null,
    val epgID: String? = null,
    val number: Int? = null,
    val catchupDays: Int = 0,
    /** Stalker: commando om een link te genereren */
    val stalkerCmd: String? = null,
)

@Serializable
data class Movie(
    val id: String,
    val title: String,
    val year: Int? = null,
    val poster: String? = null,
    val group: String = "",
    val streamURL: String? = null,
    val imdbID: String? = null,
    val rating: Double? = null,
    val plot: String? = null,
    val addedAt: Long? = null,
    val stalkerCmd: String? = null,
    val xtreamVodID: Int? = null,
)

@Serializable
data class Series(
    val id: String,
    val title: String,
    val year: Int? = null,
    val poster: String? = null,
    val group: String = "",
    val imdbID: String? = null,
    val plot: String? = null,
    val rating: Double? = null,
    /** ID bij Plex/Jellyfin/Emby/Stremio (afleveringen worden later opgehaald) */
    val remoteID: String? = null,
    val xtreamSeriesID: Int? = null,
    /** Bij M3U zitten afleveringen al in de lijst */
    val episodes: List<Episode> = emptyList(),
)

@Serializable
data class Episode(
    val id: String,
    val seriesID: String,
    val season: Int,
    val number: Int,
    val title: String,
    val streamURL: String? = null,
    val still: String? = null,
    val plot: String? = null,
    val durationSeconds: Int? = null,
)

@Serializable
data class EPGProgram(
    val channelID: String,
    val title: String,
    val description: String? = null,
    val start: Long,
    val end: Long,
) {
    val id: String get() = "$channelID-${start / 1000}"
    val isNow: Boolean get() { val n = System.currentTimeMillis(); return start <= n && n < end }
    val progress: Double get() {
        val total = (end - start).toDouble(); if (total <= 0) return 0.0
        return ((System.currentTimeMillis() - start) / total).coerceIn(0.0, 1.0)
    }
}

/** Inhoud van één geladen afspeellijst. */
@Serializable
data class Library(
    val channels: List<Channel> = emptyList(),
    val movies: List<Movie> = emptyList(),
    val series: List<Series> = emptyList(),
    /** key = epgID of channel.id */
    val epg: Map<String, List<EPGProgram>> = emptyMap(),
) {
    val channelGroups: List<String> get() = channels.map { it.group }.distinct()
    val movieGroups: List<String> get() = movies.map { it.group }.distinct()
    val seriesGroups: List<String> get() = series.map { it.group }.distinct()

    fun nowPlaying(c: Channel): EPGProgram? = epg[c.epgID ?: c.id]?.firstOrNull { it.isNow }
    fun upcoming(c: Channel, count: Int = 6): List<EPGProgram> {
        val now = System.currentTimeMillis()
        return (epg[c.epgID ?: c.id] ?: emptyList()).filter { it.end > now }.take(count)
    }
    val isEmpty: Boolean get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}

/** Eén afspeelbaar item, met alles wat Trakt/OpenSubtitles nodig hebben. */
data class PlayableItem(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val url: String? = null,
    val type: MediaType,
    val imdbID: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val artwork: String? = null,
    val stalkerCmd: String? = null,
    /** 0...1 */
    val resumeAt: Double = 0.0,
    /** Stremio: "movie|tt123" of "series|tt123:1:2" */
    val stremio: String? = null,
    /** Kanaal (catch-up/timeshift en zappen) */
    val channelID: String? = null,
    /** Afleveringen: id van de serie (voor "aflevering bekeken" per profiel en de volgende aflevering) */
    val seriesID: String? = null,
)

/** Wat op een detailpagina getoond wordt. */
sealed class DetailTarget {
    data class MovieT(val movie: Movie) : DetailTarget()
    data class SeriesT(val series: Series) : DetailTarget()
    val id: String get() = when (this) { is MovieT -> movie.id; is SeriesT -> series.id }
    val title: String get() = when (this) { is MovieT -> movie.title; is SeriesT -> series.title }
    val poster: String? get() = when (this) { is MovieT -> movie.poster; is SeriesT -> series.poster }
    val group: String get() = when (this) { is MovieT -> movie.group; is SeriesT -> series.group }
    val rating: Double? get() = when (this) { is MovieT -> movie.rating; is SeriesT -> series.rating }
    val year: Int? get() = when (this) { is MovieT -> movie.year; is SeriesT -> series.year }
    val isSeries: Boolean get() = this is SeriesT
}

@Serializable
data class TitleMetadata(
    val imdbID: String,
    val title: String,
    val year: String? = null,
    val rated: String? = null,
    val runtime: String? = null,
    val genre: String? = null,
    val director: String? = null,
    val actors: String? = null,
    val plot: String? = null,
    val poster: String? = null,
    val imdbRating: String? = null,
    val imdbVotes: String? = null,
    val type: String? = null,
    val totalSeasons: Int? = null,
    val trailerYouTubeID: String? = null,
    val traktSlug: String? = null,
)

// --- Opgeslagen gebruikersgegevens -------------------------------------------------

@Serializable
data class ProgressEntry(
    val fraction: Double,
    val position: Double,
    val updated: Long,
    val title: String,
    val artwork: String? = null,
    val playlistID: String? = null,
    /** Van welk kijkprofiel (null = van vóór de profielen → hoort bij het hoofdaccount) */
    val profileID: String? = null,
)

/** Aanpassingen van de gebruiker op een afspeellijst. */
@Serializable
data class Customization(
    /** item-id of "group:<naam>" → nieuwe naam */
    val renamed: Map<String, String> = emptyMap(),
    /** item-id of "group:<naam>" */
    val hidden: Set<String> = emptySet(),
    /** groepen in eigen volgorde (live) */
    val groupOrder: List<String> = emptyList(),
    /** groep → kanaal-id's */
    val channelOrder: Map<String, List<String>> = emptyMap(),
    /** groep → doelgroep */
    val merged: Map<String, String> = emptyMap(),
) {
    companion object { fun groupKey(g: String) = "group:$g" }
}

@Serializable
data class ParentalSettings(
    val enabled: Boolean = false,
    /** "<playlistID>|<groep>" */
    val lockedGroups: Set<String> = emptySet(),
    val autoLockAdult: Boolean = true,
)

@Serializable
data class ProgramReminder(
    val id: String,
    val playlistID: String,
    val channelID: String,
    val channelName: String,
    val title: String,
    val start: Long,
)

@Serializable
data class HistoryEntry(
    val itemID: String,
    val playlistID: String? = null,
    val title: String,
    val subtitle: String? = null,
    val artwork: String? = null,
    val type: MediaType,
    val channelID: String? = null,
    val date: Long,
    /** Van welk kijkprofiel (null = van vóór de profielen → hoort bij het hoofdaccount) */
    val profileID: String? = null,
) {
    val id: String get() = "${playlistID ?: "-"}|$itemID"
}

/** Zelf toegevoegde netwerkschijf (SMB). Wachtwoord in [Store.secret]. */
@Serializable
data class NASServer(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val share: String = "",
    val username: String = "",
) {
    val passwordKey: String get() = "nas.$id.password"
}
