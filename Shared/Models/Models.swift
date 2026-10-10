import Foundation
import SwiftUI

// MARK: - Playlist (bron) ---------------------------------------------------

enum PlaylistKind: String, Codable, CaseIterable, Identifiable {
    case m3u = "M3U / M3U8"
    case xtream = "Xtream Codes"
    case stalker = "Stalker / MAC-portal"
    var id: String { rawValue }
}

/// Avatar van een afspeellijst: een SF Symbol op een kleurverloop (Netflix-profielstijl).
struct PlaylistAvatar: Codable, Hashable {
    var symbol: String
    var colorIndex: Int

    static let symbols = ["link", "bubble.left", "globe", "hare", "waveform.path.ecg",
                          "sportscourt", "wifi", "crown", "flame", "umbrella", "play",
                          "heart", "book.closed", "person", "film", "forward", "paintbrush",
                          "sparkle", "tv", "popcorn", "star", "bolt", "moon.stars", "gamecontroller"]

    static let palettes: [[Color]] = [
        [Color(hex: 0xE50914), Color(hex: 0x7A0008)],
        [Color(hex: 0x2563EB), Color(hex: 0x1E1B4B)],
        [Color(hex: 0x10B981), Color(hex: 0x064E3B)],
        [Color(hex: 0xF59E0B), Color(hex: 0x9A3412)],
        [Color(hex: 0xA855F7), Color(hex: 0x3B0764)],
        [Color(hex: 0xEC4899), Color(hex: 0x831843)],
        [Color(hex: 0x14B8A6), Color(hex: 0x0C4A6E)],
        [Color(hex: 0x64748B), Color(hex: 0x0F172A)]
    ]

    var gradient: LinearGradient {
        let c = Self.palettes[colorIndex % Self.palettes.count]
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func random() -> PlaylistAvatar {
        PlaylistAvatar(symbol: symbols.randomElement()!, colorIndex: Int.random(in: 0..<palettes.count))
    }
}

/// Configuratie van een bron. Wordt via iCloud (KV-store) gesynchroniseerd;
/// wachtwoorden staan los in de iCloud-sleutelhanger.
struct PlaylistSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: PlaylistKind
    var avatar: PlaylistAvatar
    // M3U
    var m3uURL: String = ""
    var epgURL: String = ""
    // Xtream / Stalker
    var serverURL: String = ""
    var username: String = ""
    var macAddress: String = ""
    var preferHLS: Bool = false          // Xtream live als .m3u8 i.p.v. .ts
    var createdAt = Date()
    var updatedAt = Date()

    var passwordKey: String { "playlist.\(id.uuidString).password" }
}

// MARK: - Content ------------------------------------------------------------

enum MediaType: String, Codable { case live, movie, series, episode }

struct Channel: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var logo: URL?
    var group: String
    var streamURL: URL?
    var epgID: String?
    var number: Int?
    var catchupDays: Int = 0
    /// Stalker: commando om een link te genereren
    var stalkerCmd: String?
}

struct Movie: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var year: Int?
    var poster: URL?
    var group: String
    var streamURL: URL?
    var imdbID: String?
    var rating: Double?
    var plot: String?
    var addedAt: Date?
    var stalkerCmd: String?
    var xtreamVodID: Int?
}

struct Series: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var year: Int?
    var poster: URL?
    var group: String
    var imdbID: String?
    var plot: String?
    var rating: Double?
    var xtreamSeriesID: Int?
    /// Bij M3U zitten afleveringen al in de lijst
    var episodes: [Episode] = []
}

struct Episode: Identifiable, Hashable, Codable {
    var id: String
    var seriesID: String
    var season: Int
    var number: Int
    var title: String
    var streamURL: URL?
    var still: URL?
    var plot: String?
    var durationSeconds: Int?
}

struct EPGProgram: Identifiable, Hashable, Codable {
    var id: String { "\(channelID)-\(start.timeIntervalSince1970)" }
    var channelID: String
    var title: String
    var description: String?
    var start: Date
    var end: Date
    var isNow: Bool { let n = Date(); return start <= n && n < end }
    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / total, 0), 1)
    }
}

struct Category: Identifiable, Hashable { var id: String; var name: String }

/// Inhoud van één geladen afspeellijst.
struct Library: Codable {
    var channels: [Channel] = []
    var movies: [Movie] = []
    var series: [Series] = []
    var epg: [String: [EPGProgram]] = [:]   // key = epgID of channel.id

    var channelGroups: [String] { orderedUnique(channels.map(\.group)) }
    var movieGroups: [String] { orderedUnique(movies.map(\.group)) }
    var seriesGroups: [String] { orderedUnique(series.map(\.group)) }

    func nowPlaying(_ c: Channel) -> EPGProgram? {
        epg[c.epgID ?? c.id]?.first(where: { $0.isNow })
    }
    func upcoming(_ c: Channel, count: Int = 6) -> [EPGProgram] {
        let now = Date()
        return Array((epg[c.epgID ?? c.id] ?? []).filter { $0.end > now }.prefix(count))
    }
}

func orderedUnique<T: Hashable>(_ xs: [T]) -> [T] {
    var seen = Set<T>(); return xs.filter { seen.insert($0).inserted }
}

// MARK: - Wat er afgespeeld wordt -------------------------------------------

/// Eén afspeelbaar item, met alles wat Trakt/OpenSubtitles nodig hebben.
struct PlayableItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var url: URL?
    var type: MediaType
    var imdbID: String?          // film of serie
    var season: Int?
    var episode: Int?
    var artwork: URL?
    var stalkerCmd: String?
    var resumeAt: Double = 0     // 0...1
}

// MARK: - Metadata -----------------------------------------------------------

struct TitleMetadata: Codable, Hashable {
    var imdbID: String
    var title: String
    var year: String?
    var rated: String?
    var runtime: String?
    var genre: String?
    var director: String?
    var actors: String?
    var plot: String?
    var poster: URL?
    var imdbRating: String?
    var imdbVotes: String?
    var type: String?
    var totalSeasons: Int?
    var trailerYouTubeID: String?
    var traktSlug: String?
}

// MARK: - Helpers ------------------------------------------------------------

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
