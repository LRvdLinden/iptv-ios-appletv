import SwiftUI

/// Bouwt afspeelbare items en combineert "bekeken"-status van Trakt + lokaal (iCloud).
@MainActor
enum Playables {
    static func movie(_ m: Movie, imdb: String?) -> PlayableItem {
        var p = PlayableItem(id: m.id, title: m.title, subtitle: m.year.map(String.init), url: m.streamURL, type: .movie,
                             imdbID: imdb, artwork: m.poster, stalkerCmd: m.stalkerCmd,
                             resumeAt: resume(m.id, imdb: imdb))
        if m.streamURL == nil, m.stalkerCmd == nil, let id = m.imdbID ?? imdb { p.stremio = "movie|\(id)" }
        applyLanguage(ContentLanguage.of(m), to: &p)
        return p
    }

    /// Taal van de titel meegeven aan de speler (automatische ondertitels) en de hervatpositie in seconden (build 59).
    private static func applyLanguage(_ l: ContentLanguage?, to p: inout PlayableItem) {
        p.audioLanguage = (l?.multi ?? false) ? nil : l?.audioBase
        p.burnedSubtitles = l?.subtitlesBase
        if p.resumeAt > 0.01, let e = CloudStore.shared.progress[p.id], e.position > 0,
           abs(e.fraction - p.resumeAt) < 0.001 { p.resumeSeconds = e.position }
    }

    static func episode(_ e: Episode, of s: Series, imdb: String?) -> PlayableItem {
        var p = PlayableItem(id: e.id, title: s.title,
                             subtitle: L("S%d:E%d · %@", e.season, e.number, cleanEpisodeTitle(e)),
                             url: e.streamURL, type: .episode, imdbID: imdb, season: e.season, episode: e.number,
                             artwork: e.still ?? s.poster, resumeAt: resume(e.id, imdb: nil))
        if e.streamURL == nil, e.id.hasPrefix("se") { p.stremio = "series|\(e.id.dropFirst(2))" }
        p.seriesID = s.id
        applyLanguage(ContentLanguage.of(s), to: &p)
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

    /// Aantal bekeken afleveringen van een serie voor het label "N BEKEKEN" (build 75): Trakt (alleen het hoofdaccount;
    /// bij andere profielen is die leeg) samen met wat dit profiel in Bingr afvinkte of uitkeek, zonder dubbeltellingen.
    static func watchedEpisodeCount(_ s: Series, imdb: String?) -> Int {
        let store = CloudStore.shared
        var keys = TraktSync.shared.watchedEpisodeKeys(show: imdb)
        keys.formUnion(store.localWatchedEpisodes(series: s.id))
        // oudere markeringen op aflevering-id (van vóór de sleutel per serie)
        for e in s.episodes where store.localWatched.contains(e.id) { keys.insert("\(e.season)-\(e.number)") }
        return keys.count
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
