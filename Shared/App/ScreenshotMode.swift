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
// In deze modus: een demo-bibliotheek in het geheugen met echte films met een vrije licentie (Blender open movies, CC BY;
// stille films die wereldwijd publiek domein zijn), met lokale afbeeldingen die de workflow vooraf van Wikimedia Commons
// haalt en in de app-bundel zet (map ScreenshotMedia, alleen in die workflow; anders zelfgetekend). Zenders, gids en
// profielen zijn verzonnen (geen echte zenders of merken). Geen netwerk (alle http(s)-verzoeken worden geweigerd), geen
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
    /// Staande afbeelding zonder titel (billboard op Home en de kop van de detailpagina tekenen de titel zelf)
    private static var keyArt: [String: URL] = [:]
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
        var director: String
        var plot: String
        var group: String
        /// Kleuren/motief voor de zelfgetekende reserve-afbeelding (als er geen vrije afbeelding is)
        var dark: UInt32 = 0x1A1A1A
        var light: UInt32 = 0x7F8C8D
        var motif: Int = 2
        /// Afleveringen (series): titel per aflevering, één seizoen
        var episodes: [String] = []
    }

    // MARK: echte films met een vrije licentie (zie docs/appstore/free_media.json)
    //
    // Blender open movies (CC BY, © Blender Foundation | blender.org) en films die in de EU én de VS publiek domein
    // zijn (vóór 1931 verschenen, alle makers meer dan 70 jaar overleden). Geen scores of leeftijdsclassificaties
    // (die zouden verzonnen zijn); de volgorde van Top 10 volgt `addedAt`.

    private static let movies: [DemoTitle] = [
        .init(id: "m01", title: "Sintel", year: 2010, genres: ["Fantasy", "Animation"], minutes: 15, director: "Colin Levy",
              plot: "A lonely young woman befriends a baby dragon she calls Scales. When he is taken from her, she sets out on a long and dangerous quest to find him again.",
              group: "Animation", dark: 0x2A1A05, light: 0xD4A017, motif: 3),
        .init(id: "m02", title: "Tears of Steel", year: 2012, genres: ["Sci-Fi", "Action"], minutes: 12, director: "Ian Hubert",
              plot: "In a future Amsterdam, a group of warriors and scientists gathers at the Oude Kerk for a desperate attempt to save the world from destructive robots.",
              group: "Sci-Fi", dark: 0x0F2027, light: 0x2C5364, motif: 4),
        .init(id: "m03", title: "Big Buck Bunny", year: 2008, genres: ["Comedy", "Animation"], minutes: 10, director: "Sacha Goedegebure",
              plot: "A big, gentle rabbit enjoys a sunny day in the forest, until three bullying rodents push him too far and he plans a comic revenge.",
              group: "Family", dark: 0x1E3D14, light: 0x7DBB3A, motif: 0),
        .init(id: "m04", title: "Cosmos Laundromat", year: 2015, genres: ["Sci-Fi", "Animation"], minutes: 12, director: "Mathieu Auvray",
              plot: "On a desolate island, a suicidal sheep named Franck meets a quirky salesman who offers him the gift of a lifetime: many lives.",
              group: "Sci-Fi", dark: 0x102A43, light: 0xF0B429, motif: 5),
        .init(id: "m05", title: "Spring", year: 2019, genres: ["Fantasy", "Animation"], minutes: 8, director: "Andy Goralczyk",
              plot: "A shepherd girl and her dog face ancient spirits in order to continue the cycle of life.",
              group: "Animation", dark: 0x13311F, light: 0x27AE60, motif: 3),
        .init(id: "m06", title: "Sprite Fright", year: 2021, genres: ["Horror", "Comedy"], minutes: 10, director: "Matthew Luhn",
              plot: "When a group of rowdy teenagers trek into an isolated forest, they discover peaceful mushroom creatures that turn out to be an unexpected force of nature.",
              group: "Family", dark: 0x3C1414, light: 0xA04000, motif: 3),
        .init(id: "m07", title: "Coffee Run", year: 2020, genres: ["Drama", "Animation"], minutes: 3, director: "Hjalti Hjálmarsson",
              plot: "Fuelled by caffeine, a young woman runs through the bittersweet memories of her past relationship.",
              group: "Animation", dark: 0x3D0B1F, light: 0xC0392B, motif: 4),
        .init(id: "m08", title: "Charge", year: 2022, genres: ["Action", "Animation"], minutes: 4, director: "Hjalti Hjálmarsson",
              plot: "In an energy-starved future, an old man breaks into a heavily guarded facility to steal fuel, and finds out he is not alone.",
              group: "Action", dark: 0x421B04, light: 0xE67E22, motif: 2),
        .init(id: "m09", title: "Elephants Dream", year: 2006, genres: ["Sci-Fi", "Animation"], minutes: 11, director: "Bassam Kurdali",
              plot: "Old Proog guides young Emo through the endless rooms and machines of a strange world that only one of them seems to understand.",
              group: "Sci-Fi", dark: 0x1A1A2E, light: 0x6C3483, motif: 1),
        .init(id: "m11", title: "Nosferatu", year: 1922, genres: ["Horror", "Silent"], minutes: 94, director: "F. W. Murnau",
              plot: "Estate agent Thomas Hutter travels to the Carpathian mountains to sell a house to the mysterious Count Orlok, who brings death and plague to the town of Wisborg.",
              group: "Silent Classics", dark: 0x1B1B1B, light: 0x7F8C8D, motif: 7),
        .init(id: "m12", title: "A Trip to the Moon", year: 1902, genres: ["Sci-Fi", "Silent"], minutes: 13, director: "Georges Méliès",
              plot: "A group of astronomers is fired from a giant cannon to the Moon, where they meet the strange Selenites. Georges Méliès' famous fantasy.",
              group: "Silent Classics", dark: 0x050A30, light: 0x3D5AFE, motif: 5),
        .init(id: "m13", title: "The Great Train Robbery", year: 1903, genres: ["Western", "Silent"], minutes: 12, director: "Edwin S. Porter",
              plot: "A gang of outlaws holds up a steam train and robs its passengers, with a posse in hot pursuit.",
              group: "Silent Classics", dark: 0x3A1C0B, light: 0xB87333, motif: 3)
    ]

    private static let series: [DemoTitle] = [
        .init(id: "s01", title: "Les Vampires", year: 1915, genres: ["Crime", "Mystery", "Silent"], minutes: 45, director: "Louis Feuillade",
              plot: "Journalist Philippe Guérande takes on the Vampires, a secret gang of criminals led by the Grand Vampire and the mysterious Irma Vep, who hold Paris in their grip. Louis Feuillade's serial in ten episodes.",
              group: "Silent Serials", dark: 0x3D0B1F, light: 0x8E2F3C, motif: 7,
              episodes: ["The Severed Head", "The Ring That Kills", "The Red Codebook", "The Spectre", "Dead Man's Escape",
                         "Hypnotic Eyes", "Satanas", "The Thunder Master", "The Poisoner", "The Terrible Wedding"]),
        .init(id: "s02", title: "Judex", year: 1916, genres: ["Crime", "Adventure", "Silent"], minutes: 45, director: "Louis Feuillade",
              plot: "The masked avenger Judex sets out to punish the ruthless banker Favraux, and falls in love with his daughter Jacqueline. Louis Feuillade's serial in twelve parts.",
              group: "Silent Serials", dark: 0x1A1A2E, light: 0x415A77, motif: 4,
              episodes: ["The Mysterious Shadow", "The Atonement", "The Fantastic Hounds", "The Secret of the Tomb",
                         "The Tragic Mill", "The Licorice Kid", "The Woman in Black", "The Underground Passages of Château-Rouge",
                         "When the Child Appeared", "Jacqueline's Heart", "The Water Sprite", "Love's Forgiveness"])
    ]

    private static let episodePlots: [String: [String]] = [
        "s01": ["Philippe Guérande, a reporter at a Paris newspaper, starts to investigate the gang that calls itself the Vampires.",
                "The Vampires strike again, and Guérande and his friend Mazamette follow a trail across Paris.",
                "A coded notebook falls into the wrong hands, and the gang will do anything to get it back.",
                "Irma Vep and the Vampires plan their boldest move yet.",
                "Guérande sets a trap, but the Vampires are always one step ahead.",
                "A new rival enters the game and the gang is forced to change its plans."],
        "s02": ["A mysterious figure in a black cloak watches the banker Favraux.",
                "Favraux receives a warning: he has until midnight to make amends.",
                "Jacqueline learns the truth about her father's past.",
                "Judex and his brother follow the kidnappers through the countryside.",
                "The adventuress Diana Monti spins a web of her own.",
                "A young street urchin turns out to be an unexpected ally."]
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
        progress["s01-1-4"] = entry("Les Vampires", poster("s01"), 0.41, 45, ago: 1800)
        progress["m02"] = entry("Tears of Steel", poster("m02"), 0.62, 12, ago: 3600)
        progress["m11"] = entry("Nosferatu", poster("m11"), 0.35, 94, ago: 7200)
        progress["m05"] = entry("Spring", poster("m05"), 0.7, 8, ago: 86400)
        progress["s02-1-3"] = entry("Judex", poster("s02"), 0.25, 45, ago: 2 * 86400)
        progress["m03"] = entry("Big Buck Bunny", poster("m03"), 0.8, 10, ago: 3 * 86400)
        var watched: Set<String> = []
        for e in 1...3 { watched.insert("s01-1-\(e)"); watched.insert(CloudStore.episodeKey(series: "s01", season: 1, episode: e)) }
        var custom = Customization()
        for g in hiddenGroups { custom.hidden.insert(Customization.groupKey(g)) }
        let data = ScreenshotStoreData(
            playlists: [source], profiles: profiles, mainProfile: alexID, active: alexID,
            favorites: Set(["c01", "c03", "c07", "c10", "c13", "c06", "c02"].map(key)),
            myList: Set(["m04", "m06", "s02", "m12", "m09", "m13", "m08"].map(key)),
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

    // MARK: vrije afbeeldingen

    /// Map met de vrije film-afbeeldingen (JPEG, `<id>.jpg`): `-BingrMediaDir <pad>` of `ScreenshotMedia/` in de
    /// app-bundel. Die zet alleen de workflow appstore-screenshots.yml erin (tools/fetch_free_media.py); in gewone
    /// builds ontbreekt de map en tekent de demo zelf reserve-afbeeldingen.
    private static let mediaDir: URL? = {
        let fm = FileManager.default
        if let p = UserDefaults.standard.string(forKey: "BingrMediaDir"), fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ScreenshotMedia"), fm.fileExists(atPath: r.path) { return r }
        return nil
    }()

    private static func media(_ id: String) -> URL? {
        guard let dir = mediaDir else { return nil }
        let u = dir.appendingPathComponent(id + ".jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Alle beschikbare afbeeldingen met dit voorvoegsel (bv. "s01-still"), gesorteerd
    private static func mediaList(_ prefix: String) -> [URL] {
        guard let dir = mediaDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }.sorted().map { dir.appendingPathComponent($0) }
    }

    // MARK: bibliotheek

    private static func buildLibrary() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BingrScreenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func art<V: View>(_ name: String, _ size: CGSize, _ view: V) -> URL? { render(view, size: size, to: dir.appendingPathComponent(name + ".png")) }

        /// Poster, achtergrond en staande kop-afbeelding: de vrije afbeelding als die er is (poster = echte poster, of een
        /// beeld uit de film met de titel erop), anders zelfgetekend.
        func artwork(_ t: DemoTitle, seed: Int) -> URL? {
            let back = media("\(t.id)-backdrop")
            let key = media("\(t.id)-keyart") ?? media("\(t.id)-poster")
            backdrops[t.id] = back ?? art("backdrop-\(t.id)", CGSize(width: 1600, height: 900),
                                          DemoArt(title: nil, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif,
                                                  seed: seed, wide: true))
            if let k = media("\(t.id)-keyart") {
                keyArt[t.id] = k
            } else if let b = back {
                keyArt[t.id] = art("keyart-\(t.id)", CGSize(width: 800, height: 1140), PhotoArt(url: b, title: nil))
            } else {
                keyArt[t.id] = art("keyart-\(t.id)", CGSize(width: 800, height: 1140),
                                   DemoArt(title: nil, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: seed))
            }
            if let p = media("\(t.id)-poster") { return p }
            if let k = key ?? back { return art("poster-\(t.id)", CGSize(width: 600, height: 900), PhotoArt(url: k, title: t.title)) }
            return art("poster-\(t.id)", CGSize(width: 600, height: 900),
                       DemoArt(title: t.title, dark: Color(hex: t.dark), light: Color(hex: t.light), motif: t.motif, seed: seed))
        }

        var lib = Library()
        let now = Date()
        for (i, t) in movies.enumerated() {
            let p = artwork(t, seed: i)
            // ouder dan een maand: geen "Recently added"-labels over de posters; geen score (volgorde Top 10 = addedAt)
            lib.movies.append(Movie(id: t.id, title: t.title, year: t.year, poster: p, group: t.group,
                                    streamURL: URL(string: "http://demo.invalid/movie/\(t.id).mp4"), imdbID: nil, rating: nil,
                                    plot: t.plot, addedAt: now.addingTimeInterval(-Double(60 + i * 3) * 86400)))
            movieInfo[t.id] = t
            byTitle["m|" + t.title.lowercased()] = t
        }
        // reserve-stills voor afleveringen (zonder vrije afbeeldingen)
        let stillPalette: [(UInt32, UInt32, Int)] = [(0x0B2545, 0x13A4C9, 6), (0x102A43, 0x486581, 3), (0x1A1A2E, 0x6C3483, 4),
                                                     (0x0F2027, 0x2C5364, 0), (0x002B36, 0x268BD2, 6), (0x13311F, 0x27AE60, 3)]
        stills = stillPalette.enumerated().compactMap { i, p in
            art("still-\(i)", CGSize(width: 800, height: 450),
                DemoArt(title: nil, dark: Color(hex: p.0), light: Color(hex: p.1), motif: p.2, seed: i + 40, wide: true))
        }
        for (i, t) in series.enumerated() {
            let p = artwork(t, seed: i + 20)
            let own = mediaList("\(t.id)-still")
            let pool = own.isEmpty ? stills : own
            let plots = episodePlots[t.id] ?? []
            var eps: [Episode] = []
            for (n, title) in t.episodes.enumerated() {
                eps.append(Episode(id: "\(t.id)-1-\(n + 1)", seriesID: t.id, season: 1, number: n + 1, title: title,
                                   streamURL: URL(string: "http://demo.invalid/series/\(t.id)/1/\(n + 1).mp4"),
                                   still: pool.isEmpty ? nil : pool[n % pool.count],
                                   plot: plots.isEmpty ? nil : plots[n % plots.count], durationSeconds: nil))
            }
            lib.series.append(Series(id: t.id, title: t.title, year: t.year, poster: p, group: t.group, imdbID: nil, plot: t.plot,
                                     rating: nil, episodes: eps, addedAt: now.addingTimeInterval(-Double(60 + i * 2) * 86400)))
            seriesInfo[t.id] = t
            byTitle["s|" + t.title.lowercased()] = t
        }
        // zenders (verzonnen), logo's, beeld per zender en een gids rond "nu"
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let start0 = hourStart.addingTimeInterval(-5 * 3600)
        let durations = [30, 60, 45, 90, 60, 30, 120, 60]
        for (i, c) in channels.enumerated() {
            let logo = art("logo-\(c.id)", CGSize(width: 480, height: 270), DemoLogo(name: c.name, glyph: c.glyph, color: Color(hex: c.color)))
            liveStills[c.id] = media("live-\(c.id)") ?? art("live-\(c.id)", CGSize(width: 1280, height: 720),
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

    /// "IMDb"-achtige gegevens zonder score en zonder leeftijd (geen merknamen in beeld): jaar, genres, duur, regie en beschrijving
    static func metadata(title: String, isShow: Bool) -> TitleMetadata? {
        guard let t = byTitle[(isShow ? "s|" : "m|") + title.lowercased()] else { return nil }
        return TitleMetadata(imdbID: "", title: t.title, year: String(t.year), rated: nil,
                             runtime: isShow ? nil : runtime(t.minutes), genre: t.genres.joined(separator: ", "),
                             director: t.director, plot: t.plot, poster: keyArt[t.id], type: isShow ? "series" : "movie",
                             totalSeasons: isShow ? 1 : nil)
    }

    private static func runtime(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

    /// Detailpagina: achtergrond, genres, duur, regie en afleveringsinfo
    static func enrich(_ d: inout TitleDetails, target: DetailTarget) {
        let t: DemoTitle?
        switch target {
        case .movie(let m): t = movieInfo[m.id]
        case .series(let s): t = seriesInfo[s.id]
        }
        guard let t else { return }
        d.backdrop = backdrops[t.id]
        d.poster = keyArt[t.id] ?? d.poster
        d.backdrops = []
        d.genres = t.genres
        d.certification = nil
        d.director = t.director
        d.runtime = target.isSeries ? nil : runtime(t.minutes)
        d.seasonCount = target.isSeries ? 1 : nil
        if case .series(let s) = target {
            for e in s.episodes {
                d.episodeInfo["\(e.season)-\(e.number)"] = .init(title: e.title, overview: e.plot, still: e.still, airDate: nil,
                                                                runtime: nil)
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
        // de maat komt van het vak zelf (Color.clear), niet van de afbeelding: anders loopt een gevulde afbeelding over
        Color.clear
            .overlay { RemoteImage(url: ScreenshotDemo.liveStills[channel.id], contentMode: .fill, maxPixel: 1280) }
            .clipped()
            .overlay(alignment: .topTrailing) {
                RemoteImage(url: channel.logo, contentMode: .fit)
                    .frame(width: tvScaled(70), height: tvScaled(40))
                    .opacity(0.85)
                    .padding(tvScaled(10))
            }
            .clipped()
    }
}

/// Poster of staande afbeelding uit een vrije filmafbeelding (lokaal bestand): gevuld en bijgesneden, met (bij posters)
/// de titel eronder. Bewerking volgens de licentie vermeld in CREDITS.txt (bijgesneden, titel toegevoegd).
private struct PhotoArt: View {
    let url: URL
    let title: String?

    private var image: Image? {
        #if os(macOS)
        NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Color.black
                if let image {
                    image.resizable().scaledToFill().frame(width: w, height: h).clipped()
                }
                if let title {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
                    VStack(spacing: h * 0.012) {
                        Spacer()
                        Capsule().fill(Color(red: 0.9, green: 0.04, blue: 0.08)).frame(width: w * 0.12, height: max(2, h * 0.005))
                        Text(title.uppercased())
                            .font(.system(size: w * 0.105, weight: .black))
                            .kerning(w * 0.003)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: w * 0.02)
                            .padding(.horizontal, w * 0.07)
                            .padding(.bottom, h * 0.06)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
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
            // past het niet (klein scherm), dan zo groot mogelijk in dezelfde verhouding
            let f = min(1, screen.width / parts[0], screen.height / parts[1])
            let width = (parts[0] * f).rounded(), height = (parts[1] * f).rounded()
            w.setFrame(NSRect(x: screen.minX, y: screen.maxY - height, width: width, height: height), display: true)
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
