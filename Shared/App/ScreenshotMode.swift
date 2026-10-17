import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Screenshotmodus (App Store)
//
// Alleen actief met het launch-argument `-BingrScreenshots YES` (workflow appstore-screenshots.yml); daarnaast
// kiest `-BingrScreen <naam>` het scherm: home, detail, live, guide, picker, top10 (= discover), categories,
// multiview. Gebruikers kunnen dit niet bereiken: zonder argument is `isActive` false en doet niets hieronder iets.
//
// In deze modus: een verzonnen demo-bibliotheek in het geheugen (geen echte titels, posters, zenders of merken),
// lokaal getekende afbeeldingen (geen externe URL's), geen netwerk (alle http(s)-verzoeken worden geweigerd), geen
// account, geen sync en niets opgeslagen in iCloud of op de server.

enum Screenshots {
    /// Alleen via het launch-argument (argumentdomein van UserDefaults, wordt nooit bewaard)
    static let isActive: Bool = UserDefaults.standard.bool(forKey: "BingrScreenshots")

    /// Het scherm dat direct open moet (`-BingrScreen`)
    static let screen: String = {
        let s = (UserDefaults.standard.string(forKey: "BingrScreen") ?? "home").lowercased()
        return s == "discover" ? "top10" : s
    }()

    /// Netwerk uit in deze modus: elke http(s)-aanvraag van deze sessie faalt meteen.
    static func configure(_ c: URLSessionConfiguration) {
        guard isActive else { return }
        c.protocolClasses = [ScreenshotNetworkBlock.self] + (c.protocolClasses ?? [])
    }
}

/// Weigert in de screenshotmodus elke aanvraag naar internet (TMDB, IMDb, Trakt, Bingr-server, streams…).
final class ScreenshotNetworkBlock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard Screenshots.isActive, let s = request.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "ws", "wss"].contains(s)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Gegevens voor `CloudStore.applyScreenshotDemo` (alleen in het geheugen).
struct ScreenshotStoreData {
    var playlists: [PlaylistSource]
    var profiles: [ViewerProfile]
    var mainProfile: UUID
    var active: UUID?
    var favorites: Set<String>
    var myList: Set<String>
    var progress: [String: ProgressEntry]
    var watched: Set<String>
    var recent: [String]
    var customizations: [UUID: Customization]
    var homeLayouts: [String: HomeLayout]
    var lastSync: Date
}

@MainActor
enum ScreenshotDemo {
    static let sourceID = UUID(uuidString: "B1A9E5C0-0000-4000-8000-000000000001")!
    static let alexID = UUID(uuidString: "B1A9E5C0-0000-4000-8000-0000000000A1")!
    static let samID = UUID(uuidString: "B1A9E5C0-0000-4000-8000-0000000000A2")!
    static let noorID = UUID(uuidString: "B1A9E5C0-0000-4000-8000-0000000000A3")!
    static let guestID = UUID(uuidString: "B1A9E5C0-0000-4000-8000-0000000000A4")!

    /// De demo-bibliotheek (gezet bij het starten in de screenshotmodus)
    private(set) static var library = Library()
    /// Extra's voor de detailpagina en het billboard
    private static var movieInfo: [String: DemoTitle] = [:]
    private static var seriesInfo: [String: DemoTitle] = [:]
    private static var byTitle: [String: DemoTitle] = [:]
    private static var backdrops: [String: URL] = [:]
    private static var stills: [URL] = []
    private(set) static var liveStills: [String: URL] = [:]
    static let heroMovieID = "m01"
    static let detailSeriesID = "s01"

    struct DemoTitle {
        var id: String
        var title: String
        var year: Int
        var genres: [String]
        var minutes: Int
        var rating: Double
        var plot: String
        var dark: UInt32
        var light: UInt32
        var motif: Int
        var group: String
        var certification: String
    }

    // MARK: verzonnen inhoud

    private static let movies: [DemoTitle] = [
        .init(id: "m01", title: "The Last Signal", year: 2026, genres: ["Thriller", "Sci-Fi"], minutes: 124, rating: 8.7,
              plot: "When a deep-space relay goes silent, a lone engineer races to decode its final transmission before the message reaches Earth.",
              dark: 0x3A0A0A, light: 0xC0392B, motif: 5, group: "Thriller", certification: "12"),
        .init(id: "m02", title: "Night Harbor", year: 2025, genres: ["Crime", "Drama"], minutes: 112, rating: 8.4,
              plot: "A harbor pilot is drawn into a smuggling ring that runs on the night tide.",
              dark: 0x0F2027, light: 0x2C5364, motif: 6, group: "Drama", certification: "16"),
        .init(id: "m03", title: "Ember Road", year: 2024, genres: ["Adventure", "Drama"], minutes: 118, rating: 8.2,
              plot: "Two estranged sisters drive across a burning desert to keep a promise to their father.",
              dark: 0x4B1D06, light: 0xF39C12, motif: 0, group: "Drama", certification: "12"),
        .init(id: "m04", title: "Glass Kingdom", year: 2026, genres: ["Fantasy", "Adventure"], minutes: 131, rating: 8.6,
              plot: "Beneath a frozen lake lies a kingdom made of glass, and only one girl can hear it singing.",
              dark: 0x0B3D3A, light: 0x16A085, motif: 3, group: "Family", certification: "6"),
        .init(id: "m05", title: "Polar Line", year: 2025, genres: ["Thriller"], minutes: 104, rating: 7.9,
              plot: "A night train through the Arctic stops in the middle of nowhere. Nobody is allowed to leave.",
              dark: 0x1C2541, light: 0x5BC0BE, motif: 3, group: "Thriller", certification: "12"),
        .init(id: "m06", title: "Midnight Docket", year: 2024, genres: ["Crime", "Mystery"], minutes: 109, rating: 8.0,
              plot: "A night-court judge notices the same defendant on her docket, every night, with a different name.",
              dark: 0x1A1A2E, light: 0x6C3483, motif: 4, group: "Thriller", certification: "16"),
        .init(id: "m07", title: "Wildfire Season", year: 2026, genres: ["Action", "Drama"], minutes: 121, rating: 8.1,
              plot: "A rookie smokejumper and a veteran crew make a last stand against the fire of the century.",
              dark: 0x421B04, light: 0xE67E22, motif: 3, group: "Action", certification: "12"),
        .init(id: "m08", title: "Paper Comets", year: 2025, genres: ["Comedy", "Romance"], minutes: 97, rating: 7.6,
              plot: "Two rival kite makers are forced to share one tiny workshop for an entire summer.",
              dark: 0x2D1E3E, light: 0xA569BD, motif: 1, group: "Comedy", certification: "AL"),
        .init(id: "m09", title: "Neon Saints", year: 2026, genres: ["Action", "Crime"], minutes: 116, rating: 8.3,
              plot: "In a city that never switches off its lights, four outcasts plan one perfect blackout.",
              dark: 0x2B0233, light: 0xFF2E93, motif: 4, group: "Action", certification: "16"),
        .init(id: "m10", title: "Cobalt Harbour", year: 2023, genres: ["Drama"], minutes: 102, rating: 7.4,
              plot: "A retired lighthouse keeper takes in a runaway who claims to come from the sea.",
              dark: 0x0D1B2A, light: 0x415A77, motif: 6, group: "Drama", certification: "6"),
        .init(id: "m11", title: "Silent Orbit", year: 2026, genres: ["Sci-Fi", "Drama"], minutes: 128, rating: 8.5,
              plot: "Stranded on a dark space station, a crew of three discovers they are not alone in orbit.",
              dark: 0x000814, light: 0x003566, motif: 5, group: "Sci-Fi", certification: "12"),
        .init(id: "m12", title: "Iron & Ash", year: 2024, genres: ["Action", "War"], minutes: 133, rating: 7.8,
              plot: "A blacksmith's daughter leads a rebellion with nothing but a forge and a stubborn heart.",
              dark: 0x3C1414, light: 0xA04000, motif: 7, group: "Action", certification: "16"),
        .init(id: "m13", title: "Velvet Hour", year: 2025, genres: ["Romance", "Drama"], minutes: 106, rating: 7.7,
              plot: "Every evening at dusk, a jazz pianist and a night nurse meet in the same empty café.",
              dark: 0x3D0B1F, light: 0xC0392B, motif: 1, group: "Drama", certification: "12"),
        .init(id: "m14", title: "Kingsgate", year: 2023, genres: ["History", "Drama"], minutes: 141, rating: 7.5,
              plot: "Two brothers fight over a crown neither of them really wants.",
              dark: 0x2A1A05, light: 0xD4A017, motif: 7, group: "Drama", certification: "12"),
        .init(id: "m15", title: "Deep Current", year: 2026, genres: ["Adventure", "Thriller"], minutes: 113, rating: 8.0,
              plot: "A cave-diving team follows an underground river that does not appear on any map.",
              dark: 0x002B36, light: 0x268BD2, motif: 6, group: "Thriller", certification: "12"),
        .init(id: "m16", title: "Amber Orchard", year: 2024, genres: ["Family", "Comedy"], minutes: 94, rating: 7.3,
              plot: "Three cousins spend a chaotic autumn saving their grandmother's apple farm.",
              dark: 0x1E3D14, light: 0x7DBB3A, motif: 0, group: "Family", certification: "AL"),
        .init(id: "m17", title: "Hollow Pines", year: 2025, genres: ["Horror", "Mystery"], minutes: 99, rating: 7.2,
              plot: "Campers in a quiet forest find a trail that only appears after midnight.",
              dark: 0x13311F, light: 0x27AE60, motif: 3, group: "Thriller", certification: "16"),
        .init(id: "m18", title: "Sundown Protocol", year: 2026, genres: ["Action", "Sci-Fi"], minutes: 119, rating: 7.9,
              plot: "An AI security system decides the city is safest when everybody stays home.",
              dark: 0x3B1E08, light: 0xFF8C42, motif: 2, group: "Sci-Fi", certification: "12"),
        .init(id: "m19", title: "Lantern Bay", year: 2023, genres: ["Animation", "Family"], minutes: 88, rating: 7.6,
              plot: "A little fox sets out to light every lantern in the bay before the winter storm.",
              dark: 0x102A43, light: 0xF0B429, motif: 1, group: "Family", certification: "AL"),
        .init(id: "m20", title: "Quiet Static", year: 2025, genres: ["Mystery", "Sci-Fi"], minutes: 101, rating: 7.1,
              plot: "A late-night radio host receives calls from listeners who haven't been born yet.",
              dark: 0x1B1B1B, light: 0x7F8C8D, motif: 2, group: "Sci-Fi", certification: "12")
    ]

    private static let series: [DemoTitle] = [
        .init(id: "s01", title: "Harbor Nine", year: 2026, genres: ["Crime", "Drama"], minutes: 52, rating: 8.9,
              plot: "Nine detectives, one coastal city and a case that refuses to stay buried. Season 3 now streaming from your own library.",
              dark: 0x0B2545, light: 0x13A4C9, motif: 6, group: "Crime Series", certification: "16"),
        .init(id: "s02", title: "The Cartographers", year: 2025, genres: ["Adventure", "Drama"], minutes: 48, rating: 8.6,
              plot: "A family of mapmakers discovers an island that moves every night.",
              dark: 0x2E1F0F, light: 0xC8963E, motif: 0, group: "Drama Series", certification: "12"),
        .init(id: "s03", title: "Static Hearts", year: 2026, genres: ["Romance", "Comedy"], minutes: 32, rating: 8.1,
              plot: "Two radio hosts who hate each other on air fall for each other off air.",
              dark: 0x3D0B2F, light: 0xE84393, motif: 1, group: "Comedy Series", certification: "12"),
        .init(id: "s04", title: "Brightwell Manor", year: 2024, genres: ["Drama", "History"], minutes: 55, rating: 8.4,
              plot: "Upstairs, downstairs and every secret in between at a crumbling country estate.",
              dark: 0x1F2A1A, light: 0x8DA65B, motif: 7, group: "Drama Series", certification: "12"),
        .init(id: "s05", title: "Orbit Station", year: 2026, genres: ["Sci-Fi", "Drama"], minutes: 50, rating: 8.7,
              plot: "Life, love and politics on the first city in orbit around the moon.",
              dark: 0x050A30, light: 0x3D5AFE, motif: 5, group: "Sci-Fi Series", certification: "12"),
        .init(id: "s06", title: "Second Sunrise", year: 2025, genres: ["Drama"], minutes: 46, rating: 8.0,
              plot: "After a blackout that lasted a year, a small town learns to start over.",
              dark: 0x402010, light: 0xFFA552, motif: 0, group: "Drama Series", certification: "12"),
        .init(id: "s07", title: "Copper Valley", year: 2024, genres: ["Crime", "Western"], minutes: 49, rating: 8.2,
              plot: "A sheriff with a past keeps the peace in a mining town that wants none.",
              dark: 0x3A1C0B, light: 0xB87333, motif: 3, group: "Crime Series", certification: "16"),
        .init(id: "s08", title: "Little Comets", year: 2026, genres: ["Animation", "Kids"], minutes: 22, rating: 8.3,
              plot: "Five tiny comets learn to fly in formation across the night sky.",
              dark: 0x0A2E4A, light: 0x4DD0E1, motif: 1, group: "Kids Series", certification: "AL"),
        .init(id: "s09", title: "The Long Field", year: 2025, genres: ["Sport", "Drama"], minutes: 44, rating: 7.9,
              plot: "A small-town football club gets one last season to avoid relegation.",
              dark: 0x0E3B1E, light: 0x43A047, motif: 2, group: "Drama Series", certification: "6"),
        .init(id: "s10", title: "Signal & Noise", year: 2026, genres: ["Thriller", "Tech"], minutes: 47, rating: 8.5,
              plot: "A whistleblower and a hacker uncover what a city's smart grid is really listening to.",
              dark: 0x1A1A2E, light: 0x00B894, motif: 4, group: "Sci-Fi Series", certification: "16"),
        .init(id: "s11", title: "Marlow Street", year: 2023, genres: ["Comedy"], minutes: 28, rating: 7.8,
              plot: "Neighbours, noise complaints and one very shared garden.",
              dark: 0x2B2D42, light: 0xEF8354, motif: 4, group: "Comedy Series", certification: "AL"),
        .init(id: "s12", title: "Tidewater", year: 2025, genres: ["Mystery", "Drama"], minutes: 51, rating: 8.0,
              plot: "Every low tide reveals another clue on the beach of a seaside village.",
              dark: 0x003D5B, light: 0x30638E, motif: 6, group: "Crime Series", certification: "12")
    ]

    private static let episodeTitles = [
        "Low Tide", "The Ninth Bell", "Fog Line", "Undertow", "Breakwater", "Salt and Iron", "Signal Fire", "The Long Night",
        "Harbor Lights Out", "Dead Reckoning", "North Pier", "Riptide", "Ghost Net", "Slack Water", "Mooring", "Lantern Watch",
        "Crosscurrent", "Shipping Forecast", "High Water", "The Ninth Wave", "Ebb", "Driftwood", "Last Ferry", "Homecoming"
    ]

    struct DemoChannel {
        var id: String; var name: String; var group: String; var color: UInt32; var glyph: String; var catchup: Int
    }

    private static let channels: [DemoChannel] = [
        .init(id: "c01", name: "News 24", group: "EN | News", color: 0xFF6D00, glyph: "globe", catchup: 7),
        .init(id: "c02", name: "Actua", group: "EN | News", color: 0x00A0E9, glyph: "mic.fill", catchup: 7),
        .init(id: "c03", name: "Prime One", group: "EN | Entertainment", color: 0xE3001B, glyph: "star.fill", catchup: 7),
        .init(id: "c04", name: "Family+", group: "EN | Entertainment", color: 0xD50000, glyph: "house.fill", catchup: 3),
        .init(id: "c05", name: "Comedy Lane", group: "EN | Entertainment", color: 0xF7B500, glyph: "face.smiling", catchup: 0),
        .init(id: "c06", name: "Cinema Nights", group: "EN | Movies", color: 0x8E44AD, glyph: "film", catchup: 0),
        .init(id: "c07", name: "Stadium 1", group: "EN | Sports", color: 0xFF7F00, glyph: "sportscourt.fill", catchup: 3),
        .init(id: "c08", name: "Matchday", group: "EN | Sports", color: 0x2ECC71, glyph: "figure.run", catchup: 0),
        .init(id: "c09", name: "Motor Max", group: "EN | Sports", color: 0x6A1B9A, glyph: "flag.checkered", catchup: 0),
        .init(id: "c10", name: "Explore", group: "EN | Documentary", color: 0x1565C0, glyph: "binoculars.fill", catchup: 7),
        .init(id: "c11", name: "Planet Wild", group: "EN | Documentary", color: 0xFBC02D, glyph: "leaf.fill", catchup: 0),
        .init(id: "c12", name: "Time Travel", group: "EN | Documentary", color: 0xA0522D, glyph: "hourglass", catchup: 0),
        .init(id: "c13", name: "Kids Club", group: "EN | Kids", color: 0x00BCD4, glyph: "balloon.fill", catchup: 0),
        .init(id: "c14", name: "Little Stars", group: "EN | Kids", color: 0xFF4081, glyph: "sparkles", catchup: 0),
        .init(id: "c15", name: "Tune Up", group: "EN | Music", color: 0xE91E63, glyph: "music.note", catchup: 0),
        .init(id: "c16", name: "Weather Now", group: "EN | News", color: 0x26A69A, glyph: "cloud.sun.fill", catchup: 0),
        // categorieën die in de demo uit staan (scherm Categorieën)
        .init(id: "c17", name: "Info Sept", group: "FR | Info", color: 0x3949AB, glyph: "globe", catchup: 0),
        .init(id: "c18", name: "Sportwelt", group: "DE | Sport", color: 0x43A047, glyph: "sportscourt.fill", catchup: 0),
        .init(id: "c19", name: "Deportes Uno", group: "ES | Deportes", color: 0xF4511E, glyph: "figure.run", catchup: 0),
        .init(id: "c20", name: "Cine Classique", group: "FR | Cinéma", color: 0x6D4C41, glyph: "film", catchup: 0)
    ]
    /// Uitgezette categorieën in de demo
    private static let hiddenGroups = ["FR | Info", "DE | Sport", "ES | Deportes", "FR | Cinéma"]

    private static let programTitles: [String: [String]] = [
        "EN | News": ["Evening Journal", "World Tonight", "Behind the Headlines", "Morning Brief", "Market Watch", "The Daily Wrap", "Newsroom Live"],
        "EN | Entertainment": ["Showbiz Today", "Our Village", "Late Night Talk", "Kitchen Heroes", "The Big Quiz", "Home Makeover", "Stand-Up Night"],
        "EN | Movies": ["Friday Feature", "Classic Cinema", "Midnight Movie", "Director's Cut", "Double Bill"],
        "EN | Sports": ["Match Day Live", "Speed Week", "Goal Rush", "Qualifying Live", "Grand Final", "Sports Desk", "Extra Time"],
        "EN | Documentary": ["Gold Hunters", "Wild Planet", "Ocean Giants", "Lost Cities", "Engineering Marvels", "Life in the Ice"],
        "EN | Kids": ["Tiny Explorers", "Robo Pals", "Story Time", "Bubble Bay", "Doodle Club", "Space Pups"],
        "EN | Music": ["Top Tracks", "Live Sessions", "Throwback Hits", "Acoustic Hour", "Chart Show"]
    ]

    // MARK: starten

    /// Vanuit `AppState.init`: demo opbouwen en het gevraagde scherm openen.
    static func start(_ app: AppState) {
        URLProtocol.registerClass(ScreenshotNetworkBlock.self)
        let d = UserDefaults.standard
        d.set(false, forKey: Trailer.autoplayKey)
        d.set(true, forKey: PlayerSettings.previewKey)
        d.set(0, forKey: "ui.startTab")
        buildLibrary()
        let source = PlaylistSource(id: sourceID, name: "Alex", kind: .m3u, avatar: PlaylistAvatar(symbol: "tv", colorIndex: 0),
                                    m3uURL: "http://demo.invalid/playlist.m3u")
        let profiles = [
            ViewerProfile(id: alexID, name: "Alex", avatar: PlaylistAvatar(symbol: "tv", colorIndex: 0)),
            ViewerProfile(id: samID, name: "Sam", avatar: PlaylistAvatar(symbol: "globe", colorIndex: 1)),
            ViewerProfile(id: noorID, name: "Noor", avatar: PlaylistAvatar(symbol: "kid03", colorIndex: 2), isKids: true),
            ViewerProfile(id: guestID, name: "Guest", avatar: PlaylistAvatar(symbol: "crown", colorIndex: 4))
        ]
        let key = { (item: String) in "\(sourceID.uuidString)|\(item)" }
        let now = Date()
        func entry(_ title: String, _ art: URL?, _ fraction: Double, _ minutes: Int, ago: Double) -> ProgressEntry {
            ProgressEntry(fraction: fraction, position: Double(minutes * 60) * fraction, updated: now.addingTimeInterval(-ago),
                          title: title, artwork: art, playlistID: sourceID, profileID: alexID)
        }
        let poster = { (id: String) in library.movies.first { $0.id == id }?.poster ?? library.series.first { $0.id == id }?.poster }
        var progress: [String: ProgressEntry] = [:]
        progress["m02"] = entry("Night Harbor", poster("m02"), 0.62, 112, ago: 3600)
        progress["s01-2-4"] = entry("Harbor Nine", poster("s01"), 0.41, 52, ago: 1800)
        progress["m08"] = entry("Paper Comets", poster("m08"), 0.25, 97, ago: 7200)
        progress["s05-1-3"] = entry("Orbit Station", poster("s05"), 0.7, 50, ago: 86400)
        progress["m11"] = entry("Silent Orbit", poster("m11"), 0.8, 128, ago: 2 * 86400)
        progress["s03-1-5"] = entry("Static Hearts", poster("s03"), 0.33, 32, ago: 3 * 86400)
        var watched: Set<String> = []
        for e in 1...8 { watched.insert("s01-1-\(e)"); watched.insert(CloudStore.episodeKey(series: "s01", season: 1, episode: e)) }
        for e in 1...3 { watched.insert("s01-2-\(e)"); watched.insert(CloudStore.episodeKey(series: "s01", season: 2, episode: e)) }
        var custom = Customization()
        for g in hiddenGroups { custom.hidden.insert(Customization.groupKey(g)) }
        let data = ScreenshotStoreData(
            playlists: [source], profiles: profiles, mainProfile: alexID, active: alexID,
            favorites: Set(["c01", "c03", "c07", "c10", "c13", "c06", "c02"].map(key)),
            myList: Set(["m04", "m09", "s02", "m15", "s10", "m13", "s04"].map(key)),
            progress: progress, watched: watched,
            recent: ["c03", "c07", "c01"].map(key),
            customizations: [sourceID: custom],
            homeLayouts: [alexID.uuidString: layout()],
            lastSync: Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: now) ?? now)
        CloudStore.shared.applyScreenshotDemo(data)

        // het gevraagde scherm
        let screen = Screenshots.screen
        if screen == "picker" {
            app.stage = .picker
            return
        }
        guard let alex = CloudStore.shared.profiles.first(where: { $0.id == alexID }) else { return }
        CloudStore.shared.selectProfile(alex)
        app.resumeLastChannelPending = false
        switch screen {
        case "live", "guide": app.selectedTab = 1
        default: app.selectedTab = 0
        }
        app.open(source, thenShow: screen == "detail" ? detailSeriesID : nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let lib = app.playlists.library
            switch screen {
            case "multiview":
                let ids = ["c07", "c01", "c10", "c03"]
                let start = ids.compactMap { id in lib.channels.first { $0.id == id } }
                app.openMultiview(start: start, candidates: lib.channels)
            case "live":
                #if os(tvOS)
                if let c = lib.channels.first(where: { $0.id == "c03" }) {
                    ChannelPreview.shared.select(c, playlists: app.playlists, delay: 0)
                }
                #endif
            default: break
            }
        }
    }

    /// Rijen op Home (per scherm een andere volgorde, zonder TMDB-rijen)
    private static func layout() -> HomeLayout {
        let order: [(String, Bool)]
        if Screenshots.screen == "top10" {
            order = [("top10", true), ("mylist", true), ("foryou", true), ("browse", true), ("live", true), ("continue", false)]
        } else {
            order = [("continue", true), ("top10", true), ("mylist", true), ("live", true), ("foryou", true), ("browse", true)]
        }
        var rows = order.map { HomeLayout.Row(key: $0.0, visible: $0.1) }
        for k in HomeLayout.knownKeys where !rows.contains(where: { $0.key == k }) { rows.append(.init(key: k, visible: false)) }
        return HomeLayout(rows: rows, updatedAt: Date())
    }

    // MARK: bibliotheek

    private static func buildLibrary() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BingrScreenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func art<V: View>(_ name: String, _ size: CGSize, _ view: V) -> URL? { render(view, size: size, to: dir.appendingPathComponent(name + ".png")) }

        var lib = Library()
        let now = Date()
        for (i, t) in movies.enumerated() {
            let p = art("poster-\(t.id)", CGSize(width: 600, height: 900),
                        DemoArt(title: t.title, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: i))
            backdrops[t.id] = art("backdrop-\(t.id)", CGSize(width: 1600, height: 900),
                                  DemoArt(title: nil, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: i, wide: true))
            lib.movies.append(Movie(id: t.id, title: t.title, year: t.year, poster: p, group: t.group,
                                    streamURL: URL(string: "http://demo.invalid/movie/\(t.id).mp4"), imdbID: nil, rating: t.rating,
                                    plot: t.plot, addedAt: now.addingTimeInterval(-Double(i) * 86400 * 3)))
            movieInfo[t.id] = t
            byTitle["m|" + t.title.lowercased()] = t
        }
        // stills voor afleveringen
        let stillPalette: [(UInt32, UInt32, Int)] = [(0x0B2545, 0x13A4C9, 6), (0x102A43, 0x486581, 3), (0x1A1A2E, 0x6C3483, 4),
                                                     (0x0F2027, 0x2C5364, 0), (0x002B36, 0x268BD2, 6), (0x13311F, 0x27AE60, 3),
                                                     (0x2A1A05, 0xD4A017, 0), (0x3A0A0A, 0xC0392B, 4)]
        stills = stillPalette.enumerated().compactMap { i, p in
            art("still-\(i)", CGSize(width: 800, height: 450),
                DemoArt(title: nil, dark: Color(hex: p.0), light: Color(hex: p.1), motif: p.2, seed: i + 40, wide: true))
        }
        for (i, t) in series.enumerated() {
            let p = art("poster-\(t.id)", CGSize(width: 600, height: 900),
                        DemoArt(title: t.title, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: i + 20))
            backdrops[t.id] = art("backdrop-\(t.id)", CGSize(width: 1600, height: 900),
                                  DemoArt(title: nil, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: i + 20, wide: true))
            var eps: [Episode] = []
            for s in 1...3 {
                for e in 1...8 {
                    let n = (s - 1) * 8 + (e - 1)
                    eps.append(Episode(id: "\(t.id)-\(s)-\(e)", seriesID: t.id, season: s, number: e,
                                       title: episodeTitles[(n + i * 5) % episodeTitles.count],
                                       streamURL: URL(string: "http://demo.invalid/series/\(t.id)/\(s)/\(e).mp4"),
                                       still: stills.isEmpty ? nil : stills[(n + i) % stills.count],
                                       plot: episodePlot(n), durationSeconds: t.minutes * 60))
                }
            }
            lib.series.append(Series(id: t.id, title: t.title, year: t.year, poster: p, group: t.group, imdbID: nil, plot: t.plot,
                                     rating: t.rating, episodes: eps, addedAt: now.addingTimeInterval(-Double(i) * 86400 * 2)))
            seriesInfo[t.id] = t
            byTitle["s|" + t.title.lowercased()] = t
        }
        // zenders, logo's, beeld per zender en een gids rond "nu"
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let start0 = hourStart.addingTimeInterval(-5 * 3600)
        let durations = [30, 60, 45, 90, 60, 30, 120, 60]
        for (i, c) in channels.enumerated() {
            let logo = art("logo-\(c.id)", CGSize(width: 480, height: 270), DemoLogo(name: c.name, glyph: c.glyph, color: Color(hex: c.color)))
            liveStills[c.id] = art("live-\(c.id)", CGSize(width: 1280, height: 720),
                                   DemoArt(title: nil, dark: Color(hex: c.color).opacity(0.35), light: Color(hex: c.color), motif: i % 8,
                                           seed: i + 60, wide: true))
            lib.channels.append(Channel(id: c.id, name: c.name, logo: logo, group: c.group,
                                        streamURL: URL(string: "http://demo.invalid/live/\(c.id).ts"), epgID: c.id, number: i + 1,
                                        catchupDays: c.catchup))
            let titles = programTitles[c.group] ?? programTitles["EN | Entertainment"]!
            var t = start0.addingTimeInterval(Double((i * 15) % 60) * 60 - 1800)
            var k = i
            var list: [EPGProgram] = []
            while t < now.addingTimeInterval(14 * 3600) {
                let dur = durations[k % durations.count]
                let title = titles[k % titles.count]
                list.append(EPGProgram(channelID: c.id, title: title, description: programDescription(title),
                                       start: t, end: t.addingTimeInterval(Double(dur * 60))))
                t = t.addingTimeInterval(Double(dur * 60))
                k += 1
            }
            lib.epg[c.id] = list
        }
        library = lib
    }

    private static func episodePlot(_ n: Int) -> String {
        let p = ["A storm cuts the harbor off from the mainland, and an old case resurfaces.",
                 "The team follows a lead to an abandoned cannery on the north shore.",
                 "A witness changes her story, and the detectives start to doubt each other.",
                 "An anonymous message points to someone inside the station.",
                 "The night ferry returns without its captain.",
                 "Old maps reveal a tunnel under the fish market."]
        return p[n % p.count]
    }

    private static func programDescription(_ t: String) -> String {
        "\(t): fresh episode with highlights, guests and the stories everyone will be talking about tomorrow."
    }

    // MARK: voor de app

    /// Billboard op Home: altijd dezelfde titel
    static func hero(_ lib: Library, filter: HomeView.Filter) -> DetailTarget? {
        switch filter {
        case .series: return lib.series.first { $0.id == detailSeriesID }.map { .series($0) }
        case .movies, .all: return lib.movies.first { $0.id == heroMovieID }.map { .movie($0) }
        }
    }

    /// "IMDb"-achtige gegevens zonder score (geen merknamen in beeld): jaar, genres, duur en beschrijving
    static func metadata(title: String, isShow: Bool) -> TitleMetadata? {
        guard let t = byTitle[(isShow ? "s|" : "m|") + title.lowercased()] else { return nil }
        return TitleMetadata(imdbID: "", title: t.title, year: String(t.year), rated: t.certification,
                             runtime: isShow ? nil : runtime(t.minutes), genre: t.genres.joined(separator: ", "),
                             plot: t.plot, poster: nil, type: isShow ? "series" : "movie", totalSeasons: isShow ? 3 : nil)
    }

    private static func runtime(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

    /// Detailpagina: achtergrond, genres, duur en afleveringsinfo
    static func enrich(_ d: inout TitleDetails, target: DetailTarget) {
        let t: DemoTitle?
        switch target {
        case .movie(let m): t = movieInfo[m.id]
        case .series(let s): t = seriesInfo[s.id]
        }
        guard let t else { return }
        d.backdrop = backdrops[t.id]
        d.backdrops = []
        d.genres = t.genres
        d.certification = t.certification
        d.runtime = target.isSeries ? "\(t.minutes) min" : runtime(t.minutes)
        d.seasonCount = target.isSeries ? 3 : nil
        if case .series(let s) = target {
            for e in s.episodes {
                d.episodeInfo["\(e.season)-\(e.number)"] = .init(title: e.title, overview: e.plot, still: e.still, airDate: nil,
                                                                runtime: t.minutes)
            }
        }
    }

    // MARK: tekenen

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) -> URL? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}

/// Beeld van een zender in de screenshotmodus (voorbeeld in Live TV en Multiview), in plaats van een stream.
struct ScreenshotStill: View {
    let channel: Channel
    var body: some View {
        RemoteImage(url: ScreenshotDemo.liveStills[channel.id], contentMode: .fill, maxPixel: 1280)
            .overlay(alignment: .topTrailing) {
                RemoteImage(url: channel.logo, contentMode: .fit)
                    .frame(width: tvScaled(70), height: tvScaled(40))
                    .opacity(0.85)
                    .padding(tvScaled(10))
            }
            .clipped()
    }
}

/// Zelfgetekende poster/achtergrond: kleurverloop, een abstract motief en (bij posters) de titel.
private struct DemoArt: View {
    let title: String?
    let dark: Color
    let light: Color
    let motif: Int
    let seed: Int
    var wide = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(colors: [light, dark], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 0.8))
                RadialGradient(colors: [light.opacity(0.9), .clear], center: UnitPoint(x: wide ? 0.7 : 0.3, y: 0.22),
                               startRadius: 0, endRadius: max(w, h) * 0.6)
                motifView(w: w, h: h)
                LinearGradient(colors: [.clear, .black.opacity(title == nil ? 0.35 : 0.6)], startPoint: .center, endPoint: .bottom)
                if let title {
                    VStack(spacing: h * 0.012) {
                        Spacer()
                        Capsule().fill(.white.opacity(0.85)).frame(width: w * 0.12, height: max(2, h * 0.004))
                        Text(title.uppercased())
                            .font(.system(size: w * 0.115, weight: .black))
                            .kerning(w * 0.004)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: w * 0.02)
                            .padding(.horizontal, w * 0.07)
                            .padding(.bottom, h * 0.07)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private func rnd(_ k: Int) -> CGFloat {
        let x = sin(Double(seed * 97 + k * 31) * 12.9898) * 43758.5453
        return CGFloat(x - floor(x))
    }

    @ViewBuilder private func motifView(w: CGFloat, h: CGFloat) -> some View {
        let m = max(w, h)
        switch motif % 8 {
        case 0: // zon boven de horizon
            ZStack {
                Circle().fill(LinearGradient(colors: [.white.opacity(0.85), light.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                    .frame(width: m * 0.42, height: m * 0.42)
                    .position(x: w * (wide ? 0.68 : 0.5), y: h * 0.45)
                    .blur(radius: m * 0.004)
                Rectangle().fill(dark.opacity(0.92)).frame(width: w, height: h * 0.38).position(x: w / 2, y: h * 0.81)
            }
        case 1: // ringen
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    Circle().stroke(.white.opacity(0.10 + Double(i) * 0.04), lineWidth: m * 0.012)
                        .frame(width: m * (0.18 + CGFloat(i) * 0.14), height: m * (0.18 + CGFloat(i) * 0.14))
                }
            }
            .position(x: w * (wide ? 0.7 : 0.55), y: h * 0.38)
        case 2: // schuine banen
            ZStack {
                ForEach(0..<7, id: \.self) { i in
                    Rectangle().fill(.white.opacity(0.05 + Double(i % 3) * 0.04))
                        .frame(width: m * 0.07, height: m * 2)
                        .rotationEffect(.degrees(32))
                        .position(x: w * (0.05 + CGFloat(i) * 0.16), y: h / 2)
                }
            }
        case 3: // bergen
            ZStack {
                Mountains(peaks: [0.15, 0.45, 0.72, 0.95].map { $0 + (rnd(1) - 0.5) * 0.08 }, height: 0.5)
                    .fill(dark.opacity(0.65))
                Mountains(peaks: [0.3, 0.6, 0.88].map { $0 + (rnd(2) - 0.5) * 0.08 }, height: 0.38)
                    .fill(dark.opacity(0.95))
            }
        case 4: // stad met verlichte ramen
            ZStack(alignment: .bottom) {
                Color.clear
                HStack(alignment: .bottom, spacing: w * 0.012) {
                    ForEach(0..<9, id: \.self) { i in
                        let bh = h * (0.18 + rnd(i + 3) * 0.32)
                        ZStack(alignment: .top) {
                            Rectangle().fill(dark.opacity(0.95))
                            VStack(spacing: bh * 0.06) {
                                ForEach(0..<5, id: \.self) { r in
                                    HStack(spacing: w * 0.01) {
                                        ForEach(0..<2, id: \.self) { c in
                                            Rectangle().fill(light.opacity(rnd(i * 10 + r * 2 + c) > 0.45 ? 0.9 : 0.15))
                                                .frame(width: w * 0.018, height: bh * 0.05)
                                        }
                                    }
                                }
                            }
                            .padding(.top, bh * 0.08)
                        }
                        .frame(width: w * 0.1, height: bh)
                    }
                }
            }
        case 5: // planeet met baan
            ZStack {
                Ellipse().stroke(.white.opacity(0.35), lineWidth: m * 0.006)
                    .frame(width: m * 0.75, height: m * 0.2).rotationEffect(.degrees(-18))
                Circle().fill(RadialGradient(colors: [light, dark], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: m * 0.22))
                    .frame(width: m * 0.32, height: m * 0.32)
                Circle().fill(.white).frame(width: m * 0.03, height: m * 0.03).offset(x: m * 0.33, y: -m * 0.06)
                ForEach(0..<24, id: \.self) { i in
                    Circle().fill(.white.opacity(0.7)).frame(width: m * 0.004, height: m * 0.004)
                        .position(x: rnd(i + 50) * w, y: rnd(i + 80) * h)
                }
            }
            .frame(width: w, height: h)
            .offset(x: wide ? w * 0.18 : 0, y: -h * 0.08)
        case 6: // golven
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Waves(phase: rnd(i) * 6, amplitude: 0.025 + CGFloat(i) * 0.008, level: 0.55 + CGFloat(i) * 0.1)
                        .fill(dark.opacity(0.35 + Double(i) * 0.17))
                }
                Circle().fill(.white.opacity(0.8)).frame(width: m * 0.08, height: m * 0.08)
                    .position(x: w * (wide ? 0.78 : 0.7), y: h * 0.2)
            }
        default: // silhouet
            ZStack {
                Circle().fill(.white.opacity(0.22)).frame(width: m * 0.5, height: m * 0.5).position(x: w * (wide ? 0.68 : 0.5), y: h * 0.42)
                VStack(spacing: m * 0.01) {
                    Circle().fill(.black.opacity(0.85)).frame(width: m * 0.09, height: m * 0.09)
                    RoundedRectangle(cornerRadius: m * 0.05).fill(.black.opacity(0.85)).frame(width: m * 0.2, height: m * 0.36)
                }
                .position(x: w * (wide ? 0.68 : 0.5), y: h * 0.62)
            }
        }
    }
}

private struct Mountains: Shape {
    let peaks: [CGFloat]
    let height: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.maxY))
        var x0: CGFloat = 0
        for (i, x) in peaks.enumerated() {
            let peakY = r.maxY - r.height * height * (0.75 + CGFloat(i % 2) * 0.25)
            p.addLine(to: CGPoint(x: r.width * x, y: peakY))
            let next = i + 1 < peaks.count ? peaks[i + 1] : 1.1
            x0 = (x + next) / 2
            p.addLine(to: CGPoint(x: r.width * x0, y: r.maxY - r.height * height * 0.35))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Waves: Shape {
    let phase: CGFloat
    let amplitude: CGFloat
    let level: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.maxY))
        let steps = 60
        for s in 0...steps {
            let x = r.width * CGFloat(s) / CGFloat(steps)
            let y = r.height * level + sin(CGFloat(s) / CGFloat(steps) * .pi * 4 + phase) * r.height * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Zelfgetekend zenderlogo (verzonnen zender, geen bestaand merk).
private struct DemoLogo: View {
    let name: String
    let glyph: String
    let color: Color
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: glyph)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 110, height: 110)
                .background(color, in: RoundedRectangle(cornerRadius: 26))
            Text(name)
                .font(.system(size: 60, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
extension ScreenshotDemo {
    /// Mac: venster op een vaste maat (`-BingrWindowSize 1440x900`) linksboven op het scherm.
    static func sizeMacWindow() {
        guard Screenshots.isActive, let s = UserDefaults.standard.string(forKey: "BingrWindowSize") else { return }
        let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        for w in NSApp.windows where w.isVisible && w.canBecomeMain {
            let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            w.setFrame(NSRect(x: screen.minX, y: screen.maxY - parts[1], width: parts[0], height: parts[1]), display: true)
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
