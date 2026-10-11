package nl.lrvdlinden.bingr

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri

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
        )
    }

    fun channel(c: Channel, now: EPGProgram?): PlayableItem = PlayableItem(
        id = c.id, title = c.name, subtitle = now?.title, url = c.streamURL, type = MediaType.LIVE,
        artwork = c.logo, stalkerCmd = c.stalkerCmd, channelID = c.id,
    )

    fun resume(id: String, imdb: String?): Double =
        Store.progress[id]?.fraction ?: runCatching { Trakt.playbackProgress(imdb) }.getOrNull() ?: 0.0

    fun isWatched(m: Movie, imdb: String?): Boolean = Trakt.isWatched(imdb) || m.id in Store.localWatched

    fun isWatched(e: Episode, imdb: String?): Boolean =
        Trakt.isWatched(imdb, e.season, e.number) || e.id in Store.localWatched

    fun cleanEpisodeTitle(e: Episode): String {
        val parts = e.title.split(" - ")
        if (parts.size >= 3) {
            val last = parts.last()
            if (TitleCleaner.parse(last).season == null) return last.trim()
        }
        val p = TitleCleaner.parse(e.title)
        return if (p.season != null || p.title.isEmpty()) L("Episode %d", e.number) else p.title
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
