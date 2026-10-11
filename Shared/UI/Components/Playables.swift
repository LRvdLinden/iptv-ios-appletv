import SwiftUI

/// Bouwt afspeelbare items en combineert "bekeken"-status van Trakt + lokaal (iCloud).
@MainActor
enum Playables {
    static func movie(_ m: Movie, imdb: String?) -> PlayableItem {
        var p = PlayableItem(id: m.id, title: m.title, subtitle: m.year.map(String.init), url: m.streamURL, type: .movie,
                             imdbID: imdb, artwork: m.poster, stalkerCmd: m.stalkerCmd,
                             resumeAt: resume(m.id, imdb: imdb))
        if m.streamURL == nil, m.stalkerCmd == nil, let id = m.imdbID ?? imdb { p.stremio = "movie|\(id)" }
        return p
    }

    static func episode(_ e: Episode, of s: Series, imdb: String?) -> PlayableItem {
        var p = PlayableItem(id: e.id, title: s.title,
                             subtitle: L("S%d:E%d · %@", e.season, e.number, cleanEpisodeTitle(e)),
                             url: e.streamURL, type: .episode, imdbID: imdb, season: e.season, episode: e.number,
                             artwork: e.still ?? s.poster, resumeAt: resume(e.id, imdb: nil))
        if e.streamURL == nil, e.id.hasPrefix("se") { p.stremio = "series|\(e.id.dropFirst(2))" }
        p.seriesID = s.id
        return p
    }

    static func channel(_ c: Channel, now: EPGProgram?) -> PlayableItem {
        PlayableItem(id: c.id, title: c.name, subtitle: now?.title, url: c.streamURL, type: .live,
                     artwork: c.logo, stalkerCmd: c.stalkerCmd, channelID: c.id)
    }

    static func resume(_ id: String, imdb: String?) -> Double {
        if let p = CloudStore.shared.progress[id]?.fraction { return p }
        return TraktSync.shared.playbackProgress(movie: imdb) ?? 0
    }

    static func isWatched(movie m: Movie, imdb: String?) -> Bool {
        TraktSync.shared.isWatched(movie: imdb) || CloudStore.shared.localWatched.contains(m.id)
    }

    static func isWatched(_ e: Episode, imdb: String?) -> Bool {
        TraktSync.shared.isWatched(show: imdb, season: e.season, episode: e.number)
            || CloudStore.shared.localWatched.contains(e.id)
            || CloudStore.shared.localWatched.contains(CloudStore.episodeKey(series: e.seriesID, season: e.season, episode: e.number))
    }

    static func cleanEpisodeTitle(_ e: Episode) -> String {
        let parts = e.title.components(separatedBy: " - ")
        if parts.count >= 3, let last = parts.last, TitleCleaner.parse(last).season == nil {
            return last.trimmingCharacters(in: .whitespaces)
        }
        let p = TitleCleaner.parse(e.title)
        return (p.season != nil || p.title.isEmpty) ? L("Episode %d", e.number) : p.title
    }
}
