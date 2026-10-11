package nl.lrvdlinden.bingr

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.util.Locale

/** Bouwt afspeelbare items en combineert "bekeken"-status van Trakt + lokaal (= Playables.swift). */
object Playables {
    fun movie(m: Movie, imdb: String?): PlayableItem {
        val id = m.imdbID ?: imdb
        val stremio = if (m.streamURL == null && m.stalkerCmd == null && id != null) "movie|$id" else null
        return PlayableItem(
            id = m.id, title = m.title, subtitle = m.year?.toString(), url = m.streamURL, type = MediaType.MOVIE,
            imdbID = imdb, artwork = m.poster, stalkerCmd = m.stalkerCmd, resumeAt = resume(m.id, imdb), stremio = stremio,
        )
    }

    fun episode(e: Episode, s: Series, imdb: String?): PlayableItem {
        val stremio = if (e.streamURL == null && e.id.startsWith("se")) "series|${e.id.drop(2)}" else null
        return PlayableItem(
            id = e.id, title = s.title,
            subtitle = L("S%d:E%d · %@", e.season, e.number, cleanEpisodeTitle(e)),
            url = e.streamURL, type = MediaType.EPISODE, imdbID = imdb, season = e.season, episode = e.number,
            artwork = e.still ?: s.poster, resumeAt = resume(e.id, null), stremio = stremio,
            seriesID = s.id,
        )
    }

    fun channel(c: Channel, now: EPGProgram?): PlayableItem = PlayableItem(
        id = c.id, title = c.name, subtitle = now?.title, url = c.streamURL, type = MediaType.LIVE,
        artwork = c.logo, stalkerCmd = c.stalkerCmd, channelID = c.id,
    )

    fun resume(id: String, imdb: String?): Double =
        Store.progress[id]?.fraction ?: runCatching { Trakt.playbackProgress(imdb) }.getOrNull() ?: 0.0

    fun isWatched(m: Movie, imdb: String?): Boolean = Trakt.isWatched(imdb) || m.id in Store.localWatched

    /** Trakt, of lokaal (per profiel) via aflevering-id of seizoen-aflevering-sleutel. */
    fun isWatched(e: Episode, imdb: String?): Boolean =
        Trakt.isWatched(imdb, e.season, e.number) || Store.isEpisodeWatched(e)

    fun cleanEpisodeTitle(e: Episode): String {
        val parts = e.title.split(" - ")
        if (parts.size >= 3) {
            val last = parts.last()
            if (TitleCleaner.parse(last).season == null) return last.trim()
        }
        val p = TitleCleaner.parse(e.title)
        return if (p.season != null || p.title.isEmpty()) L("Episode %d", e.number) else p.title
    }

    /** Afspeelpositie (seconden) leesbaar: 1:02:03 of 4:05. */
    fun formatPosition(s: Double): String {
        if (!s.isFinite() || s < 0) return "0:00"
        val t = s.toInt(); val h = t / 3600; val m = (t % 3600) / 60; val sec = t % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, sec) else String.format(Locale.ROOT, "%d:%02d", m, sec)
    }
}

/** Een aangetikte titel uit "Verder kijken": kiezen tussen hervatten en opnieuw kijken (= ResumeChoice in ContinueWatching.swift). */
data class ResumeChoice(
    /** voortgangssleutel (film- of aflevering-id) */
    val id: String,
    val title: String,
    val fraction: Double,
    /** seconden (null = onbekend) */
    val position: Double? = null,
    val detail: DetailTarget? = null,
)

/** Speelt een film of aflevering af op basis van de voortgangssleutel (= ResumePlayer in ContinueWatching.swift). */
object ResumePlayer {
    /** Lukt afspelen niet, dan de serie/film om te openen (anders null). */
    suspend fun play(key: String, title: String, restart: Boolean): DetailTarget? {
        val lib = Playlists.library
        val m = lib.movies.firstOrNull { it.id == key }
        if (m != null) {
            var item = Playables.movie(m, Trakt.imdb(m))
            if (restart) item = item.copy(resumeAt = 0.0)
            AppState.play(item)
            return null
        }
        // aflevering: eerst de serie met dezelfde titel, anders de serie waar de aflevering in zit
        var candidates = lib.series.filter { it.title == title }
        if (candidates.isEmpty()) candidates = lib.series.filter { s -> s.episodes.any { it.id == key } }
        for (s in candidates) {
            val eps = if (s.episodes.any { it.id == key }) s.episodes
            else screensSafe { Playlists.episodes(s) } ?: emptyList()
            val e = eps.firstOrNull { it.id == key } ?: continue
            var item = Playables.episode(e, s, Trakt.imdb(s))
            if (restart) item = item.copy(resumeAt = 0.0)
            AppState.play(item)
            return null
        }
        return candidates.firstOrNull()?.let { DetailTarget.SeriesT(it) }
    }
}

/** Trailers (YouTube): eerst de YouTube-app (ook op Android TV), anders de browser. */
object Trailer {
    fun open(ctx: Context, youtubeID: String) {
        val app = Intent(Intent.ACTION_VIEW, Uri.parse("vnd.youtube:$youtubeID")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$youtubeID")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(app)
        } catch (_: ActivityNotFoundException) {
            runCatching { ctx.startActivity(web) }
        } catch (_: Exception) {
            runCatching { ctx.startActivity(web) }
        }
    }
}

/** Delen via het Android-deelmenu (WhatsApp, Berichten, …). */
object ShareSheet {
    fun share(ctx: Context, subject: String, text: String, url: String?): Boolean = runCatching {
        val body = if (url != null) "$text\n$url" else text
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
        }
        ctx.startActivity(Intent.createChooser(send, L("Share")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    }.getOrDefault(false)
}
