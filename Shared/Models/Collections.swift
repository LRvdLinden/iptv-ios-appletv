import Foundation
import SwiftUI

// MARK: - Collecties (build 51, zie docs/ACCOUNT.md → "Build 51") --------------------

/// Eén item in een handmatige collectie: soort en de lokale id zoals de app die gebruikt (`x123`, `xv456`, `xs789`).
struct CollectionItem: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case channel, movie, series }
    var type: Kind
    var id: String
    /// Build 128: server van het item (ontbreekt = `sourceID` van de collectie, anders de server waarop het staat)
    var sid: String? = nil

    init(type: Kind, id: String, sid: String? = nil) {
        self.type = type; self.id = id; self.sid = sid
    }

    /// Gelijk op soort + id + server (hoofdletterongevoelig); ontbreekt de server aan één kant, dan soort + id.
    static func == (a: CollectionItem, b: CollectionItem) -> Bool {
        guard a.type == b.type, a.id == b.id else { return false }
        guard let x = a.sid, let y = b.sid else { return true }
        return x.caseInsensitiveCompare(y) == .orderedSame
    }
    func hash(into h: inout Hasher) { h.combine(type); h.combine(id) }

    /// Hoort dit item bij deze server? (zonder `sid`: ja, zoals vóór build 128)
    func belongs(to source: UUID?) -> Bool {
        guard let sid, !sid.isEmpty else { return true }
        guard let source else { return false }
        return sid.caseInsensitiveCompare(source.uuidString) == .orderedSame
    }
}

/// Afbeelding van een collectie: symbool + kleur (zoals een avatar) of een eigen plaatje (`url`).
struct CollectionImage: Codable, Hashable {
    var symbol: String?
    var colorIndex: Int?
    var url: String?

    var avatar: PlaylistAvatar {
        PlaylistAvatar(symbol: (symbol?.isEmpty == false ? symbol! : "star"), colorIndex: max(0, colorIndex ?? 0))
    }
    var imageURL: URL? { url.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
}

/// Eigen rij van een profiel (state-section `collections`, per profiel sinds build 54).
struct BingrCollection: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case manual, smart }

    var id: String = UUID().uuidString
    var name: String
    var image = CollectionImage(symbol: "star", colorIndex: 0, url: nil)
    var kind: Kind = .manual
    /// Handmatig: de items in volgorde
    var items: [CollectionItem] = []
    /// Slim: zoekwoorden, gescheiden door komma's
    var query: String = ""
    /// Slim: welke soorten erin mogen ("channel", "movie", "series")
    var types: [String] = ["channel", "movie", "series"]
    /// Optioneel: alleen deze categorie
    var group: String? = nil
    /// Optioneel: alleen deze server
    var sourceID: String? = nil
    var order: Int = 0
    var updatedAt = Date()
    var deleted = false
    var deletedAt: Date? = nil
    /// Profiel waar deze collectie bij hoort (build 54). Alleen lokaal: op de server staat de collectie onder
    /// `collections.profiles.<profielID>.items`. nil = van vóór build 54 (nog niet gemigreerd).
    var owner: UUID? = nil

    /// Sleutel van de rij op het startscherm
    var homeKey: String { HomeLayout.collectionPrefix + id }

    var keywords: [String] {
        query.split(separator: ",")
            .map { PlaylistService.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    func allows(_ kind: CollectionItem.Kind) -> Bool { types.contains(kind.rawValue) }

    func contains(_ item: CollectionItem) -> Bool { items.contains(item) }
}

/// Wat er van een collectie in de geladen bibliotheek staat.
struct CollectionContent: Equatable {
    var channels: [Channel] = []
    var movies: [Movie] = []
    var series: [Series] = []
    var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }
    var count: Int { channels.count + movies.count + series.count }
}

/// Zoekt de inhoud van een collectie op in een bibliotheek.
enum CollectionResolver {
    static let limit = 200

    /// Hoort deze collectie bij de geladen server? (`sourceID` leeg = alle servers)
    static func matchesSource(_ c: BingrCollection, _ source: UUID?) -> Bool {
        guard let s = c.sourceID, !s.isEmpty else { return true }
        guard let source else { return false }
        return SourceSync.uuid(for: s) == source
    }

    static func resolve(_ c: BingrCollection, lib: Library, source: UUID?, index: LibrarySearchIndex? = nil) -> CollectionContent {
        guard matchesSource(c, source) else { return CollectionContent() }
        var out = CollectionContent()
        switch c.kind {
        case .manual:
            // build 128: items van een andere server komen via CrossServer (niet uit deze bibliotheek)
            let mine = c.items.filter { $0.belongs(to: source) }
            let wantedChannels = Set(mine.filter { $0.type == .channel }.map(\.id))
            let wantedMovies = Set(mine.filter { $0.type == .movie }.map(\.id))
            let wantedSeries = Set(mine.filter { $0.type == .series }.map(\.id))
            var ch: [String: Channel] = [:], mv: [String: Movie] = [:], se: [String: Series] = [:]
            if !wantedChannels.isEmpty { for x in lib.channels where wantedChannels.contains(x.id) { ch[x.id] = x } }
            if !wantedMovies.isEmpty { for x in lib.movies where wantedMovies.contains(x.id) { mv[x.id] = x } }
            if !wantedSeries.isEmpty { for x in lib.series where wantedSeries.contains(x.id) { se[x.id] = x } }
            for item in mine {
                switch item.type {
                case .channel: if let x = ch[item.id] { out.channels.append(x) }
                case .movie: if let x = mv[item.id] { out.movies.append(x) }
                case .series: if let x = se[item.id] { out.series.append(x) }
                }
            }
        case .smart:
            let words = c.keywords
            guard !words.isEmpty else { return out }
            let group = c.group.flatMap { $0.isEmpty ? nil : $0 }
            // met een index: de titels en groepen zijn al één keer per lijst gevouwen (kleine letters, zonder
            // accenten) in plaats van bij elke collectie en elke wijziging opnieuw voor tienduizenden titels
            let ix = index.flatMap { $0.matches(lib) ? $0 : nil }
            func hit(_ title: String, _ g: String, _ folded: (String, String)?) -> Bool {
                if let group, g != group { return false }
                let (t, gf) = folded ?? (PlaylistService.fold(title), PlaylistService.fold(g))
                return words.contains { t.contains($0) || gf.contains($0) }
            }
            if c.allows(.channel) {
                for (i, x) in lib.channels.enumerated() where hit(x.name, x.group, ix.map { ($0.channelNames[i], $0.channelGroups[i]) }) {
                    out.channels.append(x)
                    if out.channels.count >= limit { break }
                }
            }
            if c.allows(.movie) {
                for (i, x) in lib.movies.enumerated() where hit(x.title, x.group, ix.map { ($0.movieTitles[i], $0.movieGroups[i]) }) {
                    out.movies.append(x)
                    if out.movies.count >= limit { break }
                }
            }
            if c.allows(.series) {
                for (i, x) in lib.series.enumerated() where hit(x.title, x.group, ix.map { ($0.seriesTitles[i], $0.seriesGroups[i]) }) {
                    out.series.append(x)
                    if out.series.count >= limit { break }
                }
            }
        }
        return out
    }

    /// Alleen de zenders (Live TV).
    static func channels(_ c: BingrCollection, lib: Library, source: UUID?) -> [Channel] {
        guard c.kind == .smart ? c.allows(.channel) : c.items.contains(where: { $0.type == .channel }) else { return [] }
        var only = c
        if c.kind == .smart { only.types = ["channel"] } else { only.items = c.items.filter { $0.type == .channel } }
        return resolve(only, lib: lib, source: source).channels
    }
}

/// Gevouwen titels en groepen van één bibliotheek (per item op dezelfde plek), voor slimme collecties.
/// Eén keer per lijst gebouwd, op de achtergrond; groepen worden per unieke groep maar één keer gevouwen.
final class LibrarySearchIndex: @unchecked Sendable {
    let version: Int
    let channelNames: [String], channelGroups: [String]
    let movieTitles: [String], movieGroups: [String]
    let seriesTitles: [String], seriesGroups: [String]

    init(_ lib: Library, version: Int) {
        self.version = version
        var groups: [String: String] = [:]
        func g(_ s: String) -> String {
            if let f = groups[s] { return f }
            let f = PlaylistService.fold(s)
            groups[s] = f
            return f
        }
        channelNames = lib.channels.map { PlaylistService.fold($0.name) }
        channelGroups = lib.channels.map { g($0.group) }
        movieTitles = lib.movies.map { PlaylistService.fold($0.title) }
        movieGroups = lib.movies.map { g($0.group) }
        seriesTitles = lib.series.map { PlaylistService.fold($0.title) }
        seriesGroups = lib.series.map { g($0.group) }
    }

    /// Hoort deze index bij deze lijst (zelfde aantallen)? Anders zonder index zoeken.
    func matches(_ lib: Library) -> Bool {
        channelNames.count == lib.channels.count && movieTitles.count == lib.movies.count && seriesTitles.count == lib.series.count
    }
}

/// Uitkomsten van collecties, buiten de hoofdthread berekend en bewaard per (bibliotheekversie, bron, collectie).
/// Een collectie telt als gewijzigd zodra iets ervan verandert (o.a. `updatedAt`, eigenaar/profiel, zoekwoorden).
actor CollectionCache {
    static let shared = CollectionCache()

    private struct Key: Hashable {
        let version: Int
        let source: UUID?
        let collection: BingrCollection
    }
    private var index: LibrarySearchIndex?
    private var results: [Key: CollectionContent] = [:]
    private var cachedVersion: Int?

    /// Inhoud van een reeks collecties (collectie-id → inhoud).
    func content(for list: [BingrCollection], lib: Library, version: Int, source: UUID?) -> [String: CollectionContent] {
        var out: [String: CollectionContent] = [:]
        for c in list { out[c.id] = content(c, lib: lib, version: version, source: source) }
        return out
    }

    /// Alleen de zenders (Live TV).
    func channels(_ c: BingrCollection, lib: Library, version: Int, source: UUID?) -> [Channel] {
        content(c, lib: lib, version: version, source: source).channels
    }

    private func content(_ c: BingrCollection, lib: Library, version: Int, source: UUID?) -> CollectionContent {
        if cachedVersion != version {
            // nieuwe lijst: oude uitkomsten en index weg
            cachedVersion = version
            results = [:]
            index = nil
        }
        let key = Key(version: version, source: source, collection: c)
        if let hit = results[key] { return hit }
        if c.kind == .smart && index == nil && CollectionResolver.matchesSource(c, source) && !c.keywords.isEmpty {
            index = LibrarySearchIndex(lib, version: version)
        }
        let r = CollectionResolver.resolve(c, lib: lib, source: source, index: index)
        if results.count > 200 { results = [:] }   // oude versies van gewijzigde collecties niet eindeloos bewaren
        results[key] = r
        return r
    }
}

// MARK: - Startscherm per profiel -----------------------------------------------------

/// Volgorde en zichtbaarheid van de rijen op Home (in `profile.<id>` als `homeLayout`).
struct HomeLayout: Codable, Hashable {
    struct Row: Codable, Hashable { var key: String; var visible: Bool }

    var rows: [Row] = []
    var updatedAt: Date = .distantPast

    static let collectionPrefix = "collection:"
    /// Vaste rijen, in de standaardvolgorde. "browse" (build 86) = de rij Categorieën met tegels; staat hij direct na
    /// "live", dan zet Home hem vanzelf 5 rijen onder Nu live (zie `HomeView.homeSlots`). Zelfde sleutel op web en
    /// Android/Samsung TV; de oudere sleutels "genres" (web) en "categorytiles" (Android) lezen we als "browse".
    /// Build 111: "upcoming" (Binnenkort) en "streaming" (Nieuw op streamingdiensten), TMDB; standaard aan, na "recent".
    /// Build 141: de rij "recent" (Nieuw toegevoegd) staat niet meer op Home; Nieuw op Bingr ("streaming") staat op zijn
    /// plek. De opgeslagen sleutel "recent" blijft bewaard voor andere apps (zie `effective` en `applying`).
    static let knownKeys = ["continue", "mylist", "streaming", "upcoming", "foryou", "top10", "live", "browse", "categories", "movies", "series"]
    /// Oudere sleutels van andere apps → huidige sleutel (plek en aan/uit blijven; dubbele vervallen)
    static let keyAliases = ["genres": "browse", "categorytiles": "browse"]
    /// Build 86: precies 5 getoonde rijen tussen Nu live (de rij "live") en de rij Categorieën (= de 6e rij eronder)
    static let browseOffset = 5
    /// Nieuw en standaard uit (Home ziet er na de update hetzelfde uit)
    static let defaultHidden: Set<String> = ["movies", "series"]

    static func title(_ key: String, collections: [BingrCollection]) -> String {
        switch key {
        case "continue": return L("Continue watching")
        case "mylist": return L("My List")
        case "recent": return L("Recently added")
        case "upcoming": return L("Coming soon to Bingr")   // build 112: was "Binnenkort"
        case "streaming": return L("New on Bingr")          // build 112: was "Nieuw op streamingdiensten"
        case "foryou": return L("For you")
        case "top10": return L("Top 10")
        case "live": return L("Favorite channels")
        case "browse": return L("Categories")
        case "categories": return L("Rows per category")
        case "movies": return L("Movies")
        case "series": return L("Series")
        default:
            if key.hasPrefix(collectionPrefix) {
                let id = String(key.dropFirst(collectionPrefix.count))
                return collections.first { $0.id == id }?.name ?? L("Collection")
            }
            return key
        }
    }

    /// De rijen zoals Home ze toont: bekende sleutels en bestaande collecties; ontbrekende vaste rijen en nieuwe
    /// collecties komen erbij (collecties zichtbaar, onderaan). Onbekende sleutels worden genegeerd.
    func effective(collections: [BingrCollection]) -> [Row] {
        let collectionKeys = collections.map(\.homeKey)
        let valid = Set(Self.knownKeys).union(collectionKeys)
        var out: [Row] = []
        var seen = Set<String>()
        for var r in Self.newOnBingrAtRecent(rows) {
            r.key = Self.keyAliases[r.key] ?? r.key
            if valid.contains(r.key) && seen.insert(r.key).inserted { out.append(r) }
        }
        for k in Self.knownKeys where !seen.contains(k) {
            seen.insert(k)
            // een vaste rij die ontbreekt op zijn standaardplek (na de vorige vaste rij) invoegen
            let row = Row(key: k, visible: !Self.defaultHidden.contains(k))
            if let i = Self.knownKeys.firstIndex(of: k), i > 0,
               let prev = out.lastIndex(where: { Self.knownKeys.prefix(i).contains($0.key) }) {
                out.insert(row, at: prev + 1)
            } else if Self.knownKeys.first == k {
                out.insert(row, at: 0)
            } else {
                out.append(row)
            }
        }
        for k in collectionKeys where seen.insert(k).inserted { out.append(Row(key: k, visible: true)) }
        return out
    }

    /// Build 141: "Nieuw toegevoegd" weg; Nieuw op Bingr verhuist naar die plek (met zijn eigen aan/uit, of dat van
    /// "Nieuw toegevoegd" als Nieuw op Bingr nog niet in de indeling stond). Er is daarna één rij Nieuw op Bingr.
    static func newOnBingrAtRecent(_ rows: [Row]) -> [Row] {
        HomeRowOrder.newOnBingrAtRecent(rows, key: \.key, visible: \.visible, make: { Row(key: $0, visible: $1) })
    }

    /// Een aangepaste lijst (van het scherm "Startscherm") terug in de opgeslagen rijen zetten; onbekende sleutels
    /// van andere apps blijven bewaard.
    func applying(_ edited: [Row]) -> HomeLayout {
        var l = self
        let editedKeys = Set(edited.map(\.key))
        var mine = edited
        // build 141: "recent" (voor andere apps) direct vóór Nieuw op Bingr houden, anders verhuist die rij bij het
        // lezen (`newOnBingrAtRecent`) naar waar "recent" toevallig stond
        if let old = rows.first(where: { $0.key == "recent" }), !editedKeys.contains("recent"),
           let si = mine.firstIndex(where: { $0.key == "streaming" }) {
            mine.insert(old, at: si)
        }
        l.rows = mine + rows.filter { !editedKeys.contains($0.key) && !Self.knownKeys.contains($0.key) && $0.key != "recent"
            && Self.keyAliases[$0.key] == nil && !$0.key.hasPrefix(Self.collectionPrefix) }
        l.updatedAt = Date()
        return l
    }
}

// MARK: - Evenementzenders (alleen lokaal) --------------------------------------------

/// Uitgelezen evenement uit een zendernaam: titel ("Ajax – PSV") en begintijd.
struct EventInfo: Hashable {
    var title: String
    var start: Date?

    /// Langer dan 6 uur geleden begonnen
    func isExpired(now: Date = Date()) -> Bool { start.map { now.timeIntervalSince($0) > 6 * 3600 } ?? false }
    func isLive(now: Date = Date()) -> Bool { start.map { $0 <= now && !isExpired(now: now) } ?? false }

    /// "Vandaag 20:45", "Morgen 20:45" of "za 14 okt. 20:45" (lokale tijd)
    var startText: String? {
        guard let start else { return nil }
        let cal = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(start) { return L("Today %@", time) }
        if cal.isDateInTomorrow(start) { return L("Tomorrow %@", time) }
        if cal.isDateInYesterday(start) { return L("Yesterday %@", time) }
        return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

enum EventChannels {
    private static let groupWords = ["PPV", "EVENT", "EVENTS", "LIVE EVENT", "SPORTS EVENT", "UFC/WWE/BOXING EVENTS"]

    /// Groep met PPV, EVENT(S), LIVE EVENT, SPORTS EVENT of UFC/WWE/BOXING EVENTS in de naam.
    static func isEventGroup(_ g: String) -> Bool {
        let u = " " + g.uppercased().replacingOccurrences(of: "_", with: " ") + " "
        return groupWords.contains { w in
            guard let r = u.range(of: w) else { return false }
            // los woord (niet midden in een ander woord, bijv. "PREVENTION")
            let before = u[u.index(before: r.lowerBound)]
            let after = r.upperBound < u.endIndex ? u[r.upperBound] : " "
            return !before.isLetter && !after.isLetter
        }
    }

    /// Is dit een evenementzender, en zo ja: titel en begintijd.
    static func info(for c: Channel, now: Date = Date()) -> EventInfo? {
        let inGroup = isEventGroup(c.group)
        let parsed = parse(c.name, now: now)
        if inGroup { return parsed ?? EventInfo(title: cleanTitle(c.name), start: nil) }
        // buiten een evenementgroep: alleen met een datum/tijd én twee namen ("A vs B")
        guard let p = parsed, p.start != nil, hasVersus(c.name) else { return nil }
        return p
    }

    static func hasVersus(_ name: String) -> Bool {
        name.range(of: #"\S\s+(?:vs\.?|v\.?|-|–)\s+\S"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Titel en begintijd uit een zendernaam. `nil` als er geen datum/tijd in staat.
    static func parse(_ name: String, now: Date = Date()) -> EventInfo? {
        guard let found = findDate(in: name, now: now) else { return nil }
        let (date, range) = found
        var rest = name
        rest.removeSubrange(range)
        return EventInfo(title: cleanTitle(rest), start: date)
    }

    // MARK: titel

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        // voorvoegsels zoals "PPV 01:", "EVENT 3 |", "UK:", "US |"
        s = s.replacingOccurrences(of: #"^\s*(?:PPV|EVENTS?|LIVE\s+EVENTS?|SPORTS?\s+EVENTS?)\s*\d*\s*[:|\-–]?\s*"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^\s*[A-Z]{2,3}\s*[:|]\s*"#, with: "", options: .regularExpression)
        // "A vs B" / "A v B" → "A – B"
        s = s.replacingOccurrences(of: #"\s+(?:vs\.?|v\.?)\s+"#, with: " – ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\s+-\s+"#, with: " – ", options: .regularExpression)
        // lege haakjes en losse tekens aan de randen
        s = s.replacingOccurrences(of: #"[\(\[]\s*[\)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let edge = CharacterSet(charactersIn: " -–|:@,/()[]•·").union(.whitespacesAndNewlines)
        s = s.trimmingCharacters(in: edge)
        return s.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : s
    }

    // MARK: datum en tijd

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
                                 "sep": 9, "oct": 10, "nov": 11, "dec": 12,
                                 // Nederlands en Duits waar het afwijkt
                                 "mrt": 3, "mei": 5, "okt": 10, "mai": 5, "dez": 12]

    private static let timePart = #"(\d{1,2})(?:[:.h](\d{2}))?\s*(am|pm)?"#
    private static let zonePart = #"(?:\s*\(?\s*(?:(UTC|GMT|BST|CEST|CET|EEST|EET|WEST|WET|EDT|EST|ET|CDT|CST|CT|MDT|MST|MT|PDT|PST|PT|UK|AEDT|AEST|IST)\b)?\s*([+-]\d{1,2}(?::?\d{2})?)?\s*\)?)"#

    private struct Pattern {
        let regex: NSRegularExpression
        let kind: Int   // 0 = ISO, 1 = d/m, 2 = maand d, 3 = d maand, 4 = alleen tijd
    }

    private static let patterns: [Pattern] = {
        let monthWord = #"(jan|feb|mar|mrt|apr|may|mei|mai|jun|jul|aug|sep|oct|okt|nov|dec|dez)[a-z]*\.?"#
        let sep = #"(?:\s*[@\-,|]\s*|\s+)"#
        let src: [(String, Int)] = [
            (#"(\d{4})-(\d{1,2})-(\d{1,2})[ T]+(\d{1,2})[:.](\d{2})\s*(am|pm)?"#, 0),
            (#"\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?"# + sep + #"(\d{1,2})[:.h](\d{2})\s*(am|pm)?"#, 1),
            (#"\b(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthWord + #"(?:\s+(\d{4}))?"# + sep + timePart, 3),
            (#"\b"# + monthWord + #"\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"# + sep + timePart, 2),
            (#"\b(\d{1,2})[:.](\d{2})\s*(am|pm)?"#, 4)
        ]
        return src.compactMap { s, k in
            (try? NSRegularExpression(pattern: s + zonePart, options: [.caseInsensitive])).map { Pattern(regex: $0, kind: k) }
        }
    }()

    private static func findDate(in name: String, now: Date) -> (Date, Range<String.Index>)? {
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)
        for p in patterns {
            guard let m = p.regex.firstMatch(in: name, range: full), let range = Range(m.range, in: name) else { continue }
            func g(_ i: Int) -> String? {
                guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
                return ns.substring(with: m.range(at: i))
            }
            func n(_ i: Int) -> Int? { g(i).flatMap { Int($0) } }
            var year: Int?, month: Int?, day: Int?, hour: Int?, minute = 0, ampm: String?
            let zoneIdx: Int
            switch p.kind {
            case 0:
                year = n(1); month = n(2); day = n(3); hour = n(4); minute = n(5) ?? 0; ampm = g(6); zoneIdx = 7
            case 1:
                var a = n(1), b = n(2)
                // dd/mm (Europees); is het tweede getal groter dan 12, dan mm/dd
                if let x = a, let y = b, y > 12, x <= 12 { swap(&a, &b) }
                day = a; month = b
                if let y = n(3) { year = y < 100 ? 2000 + y : y }
                hour = n(4); minute = n(5) ?? 0; ampm = g(6); zoneIdx = 7
            case 2:
                month = g(1).flatMap { months[String($0.lowercased().prefix(3))] }
                day = n(2); year = n(3); hour = n(4); minute = n(5) ?? 0; ampm = g(6); zoneIdx = 7
            case 3:
                day = n(1); month = g(2).flatMap { months[String($0.lowercased().prefix(3))] }
                year = n(3); hour = n(4); minute = n(5) ?? 0; ampm = g(6); zoneIdx = 7
            default:
                hour = n(1); minute = n(2) ?? 0; ampm = g(3); zoneIdx = 4
            }
            guard var h = hour, h <= 24, minute < 60 else { continue }
            if let ap = ampm?.lowercased() {
                if ap == "pm" && h < 12 { h += 12 }
                if ap == "am" && h == 12 { h = 0 }
            }
            // in de patronen met een maandwoord zonder ":" is alleen "8pm" een tijd; "12 Oct 2026" zonder tijd niet
            if (p.kind == 2 || p.kind == 3) && g(5) == nil && ampm == nil { continue }
            if p.kind == 4 && g(2) == nil { continue }
            let tz = zone(g(zoneIdx), offset: g(zoneIdx + 1))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            if let month { comps.month = month }
            if let day { comps.day = day }
            if let year { comps.year = year }
            comps.hour = h == 24 ? 0 : h
            comps.minute = minute
            guard (1...12).contains(comps.month ?? 0), (1...31).contains(comps.day ?? 0),
                  var date = cal.date(from: comps) else { continue }
            if h == 24 { date = date.addingTimeInterval(86400) }
            // zonder jaartal: het dichtstbijzijnde jaar
            if year == nil && month != nil {
                if date < now.addingTimeInterval(-180 * 86400), let d = cal.date(byAdding: .year, value: 1, to: date) { date = d }
                else if date > now.addingTimeInterval(180 * 86400), let d = cal.date(byAdding: .year, value: -1, to: date) { date = d }
            }
            return (date, range)
        }
        return nil
    }

    private static func zone(_ abbr: String?, offset: String?) -> TimeZone {
        if let o = offset, let tz = parseOffset(o) { return tz }
        guard let a = abbr?.uppercased() else { return .current }
        let ids: [String: String] = ["UK": "Europe/London", "BST": "Europe/London", "ET": "America/New_York",
                                     "CT": "America/Chicago", "MT": "America/Denver", "PT": "America/Los_Angeles",
                                     "IST": "Asia/Kolkata", "CET": "Europe/Amsterdam", "CEST": "Europe/Amsterdam",
                                     "EET": "Europe/Athens", "EEST": "Europe/Athens", "WET": "Europe/Lisbon",
                                     "WEST": "Europe/Lisbon", "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney"]
        let fixed: [String: Int] = ["UTC": 0, "GMT": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6,
                                    "PST": -8, "PDT": -7]
        if let id = ids[a], let tz = TimeZone(identifier: id) { return tz }
        if let h = fixed[a], let tz = TimeZone(secondsFromGMT: h * 3600) { return tz }
        return .current
    }

    private static func parseOffset(_ s: String) -> TimeZone? {
        let sign = s.hasPrefix("-") ? -1 : 1
        let digits = s.dropFirst().replacingOccurrences(of: ":", with: "")
        let h: Int, m: Int
        if digits.count <= 2 { h = Int(digits) ?? 0; m = 0 }
        else { h = Int(digits.prefix(digits.count - 2)) ?? 0; m = Int(digits.suffix(2)) ?? 0 }
        guard h <= 14, m < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
    }

    /// Evenementen van een lijst zenders, gesorteerd: komend en bezig op begintijd, zonder tijd daarna,
    /// verlopen (meer dan 6 uur oud) onderaan.
    static func events(_ channels: [Channel], now: Date = Date()) -> [(channel: Channel, info: EventInfo)] {
        let found = channels.compactMap { c in info(for: c, now: now).map { (channel: c, info: $0) } }
        func rank(_ e: EventInfo) -> Int { e.start == nil ? 1 : (e.isExpired(now: now) ? 2 : 0) }
        return found.enumerated().sorted { a, b in
            let ra = rank(a.element.info), rb = rank(b.element.info)
            if ra != rb { return ra < rb }
            if let x = a.element.info.start, let y = b.element.info.start, x != y { return ra == 2 ? x > y : x < y }
            return a.offset < b.offset
        }.map { $0.element }
    }
}
