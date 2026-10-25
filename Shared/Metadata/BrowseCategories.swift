import Foundation
import SwiftUI

// MARK: - Genres (build 85)

/// Een genre voor "Categorieën": TMDB-genre-ID's van films én series, de OMDb-namen (Engels) en woorden
/// waarmee IPTV-servers hun categorieën vaak noemen ("NL | Actie", "Kinderfilms", "Horror 4K").
struct BrowseGenre: Sendable {
    let key: String
    /// Engelse naam = sleutel voor L()
    let name: String
    let tmdb: Set<Int>
    let omdb: Set<String>
    /// Woordbegin in de categorienaam (genormaliseerd: kleine letters, zonder accenten)
    let stems: [String]
    /// Hele woorden (kort en anders te vaak raak, zoals "war")
    let words: Set<String>
    /// Stukjes tekst in de hele naam ("sci-fi", "science fiction")
    let phrases: [String]
    /// Kleurverloop van de tegel
    let colors: (UInt32, UInt32)

    /// Naam in de app-taal (letterlijke sleutels, zodat de vertaalcontrole ze ziet)
    var title: String {
        switch key {
        case "action": return L("Action")
        case "adventure": return L("Adventure")
        case "animation": return L("Animation")
        case "comedy": return L("Comedy")
        case "crime": return L("Crime")
        case "documentary": return L("Documentary")
        case "drama": return L("Drama")
        case "family": return L("Family")
        case "kids": return L("Kids")
        case "fantasy": return L("Fantasy")
        case "history": return L("History")
        case "horror": return L("Horror")
        case "music": return L("Music")
        case "mystery": return L("Mystery")
        case "romance": return L("Romance")
        case "scifi": return L("Science fiction")
        case "thriller": return L("Thriller")
        case "war": return L("War")
        case "western": return L("Western")
        case "reality": return L("Reality")
        default: return name
        }
    }

    /// Volgorde bij gelijke aantallen; de tegels staan op aantal titels.
    static let all: [BrowseGenre] = [
        .init(key: "action", name: "Action", tmdb: [28, 10759], omdb: ["action"],
              stems: ["action", "actie", "aktion", "accion", "azione", "acao", "aksiyon", "akcja"], words: [], phrases: [],
              colors: (0xE50914, 0x4A0306)),
        .init(key: "adventure", name: "Adventure", tmdb: [12, 10759], omdb: ["adventure"],
              stems: ["adventure", "avontuur", "abenteuer", "aventure", "aventura", "avventura", "macera", "przygod"], words: [], phrases: [],
              colors: (0xF97316, 0x5C1D02)),
        .init(key: "animation", name: "Animation", tmdb: [16], omdb: ["animation"],
              stems: ["animation", "animatie", "animated", "animacion", "animazione", "animacao", "animasyon", "animacj", "anime", "cartoon", "tekenfilm", "zeichentrick"],
              words: [], phrases: ["dessin anime", "dessins animes"], colors: (0x22D3EE, 0x0B3B60)),
        .init(key: "comedy", name: "Comedy", tmdb: [35], omdb: ["comedy"],
              stems: ["comedy", "comedie", "komedie", "komodie", "comedia", "commedia", "komedi", "humor", "humour"], words: [], phrases: [],
              colors: (0xFACC15, 0x6B3F00)),
        .init(key: "crime", name: "Crime", tmdb: [80], omdb: ["crime"],
              stems: ["crime", "misdaad", "krimi", "crimen", "crimine", "policier", "kryminal", "gangster"], words: ["suc", "polar"], phrases: [],
              colors: (0x64748B, 0x0F172A)),
        .init(key: "documentary", name: "Documentary", tmdb: [99], omdb: ["documentary"],
              stems: ["documentar", "documentair", "docu", "dokumentar", "dokument", "belgesel"], words: [], phrases: [],
              colors: (0x10B981, 0x053B2C)),
        .init(key: "drama", name: "Drama", tmdb: [18], omdb: ["drama"],
              stems: ["drama", "dramat"], words: ["dram"], phrases: [],
              colors: (0x8B5CF6, 0x2A0E5E)),
        .init(key: "family", name: "Family", tmdb: [10751], omdb: ["family"],
              stems: ["family", "familie", "famille", "familia", "famiglia", "rodzin", "familien"], words: ["aile"], phrases: [],
              colors: (0x38BDF8, 0x113A66)),
        .init(key: "kids", name: "Kids", tmdb: [10762], omdb: [],
              stems: ["kids", "kinder", "children", "enfant", "ninos", "bambini", "cocuk", "dzieci", "jeugd", "junior", "infantil", "kinderfilm"],
              words: ["kid", "jr"], phrases: [], colors: (0xF472B6, 0x6D1A47)),
        .init(key: "fantasy", name: "Fantasy", tmdb: [14, 10765], omdb: ["fantasy"],
              stems: ["fantasy", "fantasie", "fantastique", "fantasia", "fantastik", "fantastyk"], words: [], phrases: [],
              colors: (0xA855F7, 0x3B0764)),
        .init(key: "history", name: "History", tmdb: [36], omdb: ["history", "biography"],
              stems: ["historisch", "historie", "historical", "geschicht", "histoire", "historia", "storico", "storia", "tarih", "historyczn", "biograf"],
              words: ["history"], phrases: [], colors: (0xB45309, 0x3A1A03)),
        .init(key: "horror", name: "Horror", tmdb: [27], omdb: ["horror"],
              stems: ["horror", "horreur", "terror", "korku", "griezel"], words: [], phrases: [],
              colors: (0x7F1D1D, 0x0A0A0A)),
        .init(key: "music", name: "Music", tmdb: [10402], omdb: ["music", "musical"],
              stems: ["music", "muziek", "musik", "musique", "musica", "muzik", "muzyk", "concert", "konzert"], words: [], phrases: [],
              colors: (0xEC4899, 0x4C0A2E)),
        .init(key: "mystery", name: "Mystery", tmdb: [9648], omdb: ["mystery"],
              stems: ["mystery", "mysterie", "mystere", "misterio", "mistero", "gizem", "tajemnic"], words: [], phrases: [],
              colors: (0x6366F1, 0x1E1B4B)),
        .init(key: "romance", name: "Romance", tmdb: [10749], omdb: ["romance"],
              stems: ["romance", "romantic", "romantiek", "romantisch", "romantik", "romantico", "romantique", "romantyczn", "romant", "liefde"],
              words: [], phrases: [], colors: (0xFB7185, 0x5F1022)),
        .init(key: "scifi", name: "Science fiction", tmdb: [878, 10765], omdb: ["sci-fi"],
              stems: ["scifi", "sciencefiction", "fantascienza", "bilimkurgu"], words: [],
              phrases: ["sci-fi", "sci fi", "science fiction", "science-fiction", "ciencia ficcion", "ficcao cientifica", "bilim kurgu"],
              colors: (0x0EA5E9, 0x062F4F)),
        .init(key: "thriller", name: "Thriller", tmdb: [53], omdb: ["thriller"],
              stems: ["thriller", "gerilim", "suspense", "spannung"], words: [], phrases: [],
              colors: (0x334155, 0x020617)),
        .init(key: "war", name: "War", tmdb: [10752, 10768], omdb: ["war"],
              stems: ["oorlog", "krieg", "guerre", "guerra", "savas", "wojen", "military"], words: ["war", "wars"], phrases: [],
              colors: (0x65A30D, 0x1A2E05)),
        .init(key: "western", name: "Western", tmdb: [37], omdb: ["western"],
              stems: ["western"], words: [], phrases: [], colors: (0xD97706, 0x431407)),
        .init(key: "reality", name: "Reality", tmdb: [10764], omdb: ["reality-tv"],
              stems: ["reality", "realiteit"], words: [], phrases: ["reality tv"], colors: (0x14B8A6, 0x0C3B3A)),
    ]

    static let byKey: [String: BrowseGenre] = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    /// Kleine letters, zonder accenten; alles behalve letters/cijfers/-/spatie wordt een spatie
    static func normalize(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased().nativeUTF8
        return String(f.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " })
    }

    /// Genres die uit een categorienaam van de server volgen ("NL | Actie & Avontuur" → actie, avontuur).
    static func fromGroup(_ group: String) -> [Int] {
        let n = normalize(group)
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        var out: [Int] = []
        for (i, g) in all.enumerated() {
            if g.phrases.contains(where: { n.contains($0) })
                || words.contains(where: { w in g.words.contains(w) || g.stems.contains { w.hasPrefix($0) } }) {
                out.append(i)
            }
        }
        return out
    }

    /// OMDb-genres ("Action, Sci-Fi") → genres
    static func fromOMDb(_ s: String?) -> [Int] {
        guard let s, !s.isEmpty else { return [] }
        let parts = Set(s.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return all.indices.filter { !all[$0].omdb.isDisjoint(with: parts) }
    }

    /// TMDB-genre-ID's → genres
    static func fromTMDB(_ ids: [Int]) -> [Int] {
        guard !ids.isEmpty else { return [] }
        let set = Set(ids)
        return all.indices.filter { !all[$0].tmdb.isDisjoint(with: set) }
    }
}

// MARK: - Index

/// Eén titel in een categorie, met wat nodig is om te sorteren (vooraf berekend, buiten de hoofdthread).
struct BrowseEntry: Identifiable, Sendable {
    let target: DetailTarget
    /// Titel zoals op de poster (zonder taallabel)
    let title: String
    /// Aantal IMDb-stemmen (maat voor populariteit); 0 = onbekend
    let votes: Int
    let rating: Double
    let added: Date?
    let year: Int
    /// Volgorde op de server (bij gelijke populariteit)
    let order: Int
    var id: String { target.id }
    var isSeries: Bool { target.isSeries }
    var poster: URL? { switch target { case .movie(let m): return m.poster; case .series(let s): return s.poster } }
}

/// Een tegel in "Categorieën": een genre of een categorie van je server.
struct BrowseCategory: Identifiable, Sendable {
    enum Source: Sendable { case genre, server }
    let id: String
    let title: String
    let source: Source
    let entries: [BrowseEntry]
    let movieCount: Int
    let seriesCount: Int
    /// Kleurverloop van de tegel
    let colors: (UInt32, UInt32)
    /// Populairste posters per soort (voor de collage)
    let coverMovies: [URL]
    let coverSeries: [URL]
    let coverAll: [URL]

    func count(_ scope: BrowseScope) -> Int {
        switch scope { case .all: return movieCount + seriesCount; case .movies: return movieCount; case .series: return seriesCount }
    }
    func covers(_ scope: BrowseScope) -> [URL] {
        switch scope { case .all: return coverAll; case .movies: return coverMovies; case .series: return coverSeries }
    }
}

/// Alles / Films / Series
enum BrowseScope: String, CaseIterable, Identifiable, Sendable {
    case all, movies, series
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return L("All"); case .movies: return L("Movies"); case .series: return L("Series") }
    }
    func includes(_ e: BrowseEntry) -> Bool {
        switch self { case .all: return true; case .movies: return !e.isSeries; case .series: return e.isSeries }
    }
}

/// Sorteren op de categoriepagina: Populair, Nieuwste, A–Z, Beoordeling.
enum BrowseSort: String, CaseIterable, Identifiable, Sendable {
    case popular, newest, az, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .popular: return L("Popular")
        case .newest: return L("Newest")
        case .az: return L("A–Z")
        case .rating: return L("Rating")
        }
    }

    func sorted(_ list: [BrowseEntry]) -> [BrowseEntry] {
        switch self {
        case .popular:
            return list.sorted { a, b in
                if a.votes != b.votes { return a.votes > b.votes }
                if (a.rating > 0) != (b.rating > 0) { return a.rating > 0 }
                return a.order < b.order
            }
        case .newest:
            return list.sorted { a, b in
                let x = a.added ?? .distantPast, y = b.added ?? .distantPast
                if x != y { return x > y }
                if a.year != b.year { return a.year > b.year }
                return a.order < b.order
            }
        case .az:
            return list.sorted { a, b in
                let r = a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                                        range: nil, locale: .current)
                return r == .orderedSame ? a.order < b.order : r == .orderedAscending
            }
        case .rating:
            return list.sorted { a, b in
                if a.rating != b.rating { return a.rating > b.rating }
                if a.votes != b.votes { return a.votes > b.votes }
                return a.order < b.order
            }
        }
    }
}

struct BrowseIndex: Sendable {
    var genres: [BrowseCategory] = []
    var server: [BrowseCategory] = []
    var isEmpty: Bool { genres.isEmpty && server.isEmpty }

    /// Kleuren voor de categorieën van je server (op naam, dus elke keer dezelfde kleur)
    static let serverPalette: [(UInt32, UInt32)] = [
        (0xE50914, 0x4A0306), (0x2563EB, 0x1E1B4B), (0x10B981, 0x064E3B), (0xF59E0B, 0x7C2D12),
        (0xA855F7, 0x3B0764), (0xEC4899, 0x831843), (0x14B8A6, 0x0C4A6E), (0x64748B, 0x0F172A),
    ]

    /// Lidmaatschap uit de bibliotheek (al gefilterd: verborgen categorieën, kinderslot, leeftijd van het profiel)
    /// en de caches met metadata: TMDB-genres (leeftijdsclassificaties), OMDb-genres en de categorienaam.
    static func build(_ lib: Library, meta: [String: TitleMetadata], tmdb: [String: AgeInfo]) -> BrowseIndex {
        var entries: [BrowseEntry] = []
        entries.reserveCapacity(lib.movies.count + lib.series.count)
        var genreMembers = Array(repeating: [Int](), count: BrowseGenre.all.count)
        var groupGenres: [String: [Int]] = [:]
        var serverOrder: [String] = []
        var serverMembers: [String: [Int]] = [:]

        func votes(_ s: String?) -> Int { s.flatMap { Int($0.filter(\.isNumber)) } ?? 0 }
        func add(_ target: DetailTarget, title: String, year: Int?, group: String, rating: Double?, added: Date?, isShow: Bool) {
            let k = MetadataService.key(title: title, year: year, isShow: isShow)
            let md = meta[k]
            let i = entries.count
            entries.append(BrowseEntry(target: target, title: ContentLanguage.displayTitle(title), votes: votes(md?.imdbVotes),
                                       rating: md?.imdbRating.flatMap(Double.init) ?? (rating ?? 0), added: added,
                                       year: year ?? md?.year.flatMap { Int($0.prefix(4)) } ?? 0, order: i))
            let fromGroup: [Int]
            if let g = groupGenres[group] { fromGroup = g } else { fromGroup = BrowseGenre.fromGroup(group); groupGenres[group] = fromGroup }
            var gs = Set(fromGroup)
            gs.formUnion(BrowseGenre.fromOMDb(md?.genre))
            gs.formUnion(BrowseGenre.fromTMDB(tmdb[k]?.genres ?? []))
            for g in gs { genreMembers[g].append(i) }
            if serverMembers[group] == nil { serverOrder.append(group) }
            serverMembers[group, default: []].append(i)
        }
        for m in lib.movies {
            add(.movie(m), title: m.title, year: m.year, group: m.group, rating: m.rating, added: m.addedAt, isShow: false)
        }
        for s in lib.series {
            add(.series(s), title: s.title, year: s.year, group: s.group, rating: s.rating, added: nil, isShow: true)
        }

        func category(id: String, title: String, source: BrowseCategory.Source, members: [Int], colors: (UInt32, UInt32)) -> BrowseCategory {
            let list = members.map { entries[$0] }
            // collage: de populairste titels met poster (zonder alles te sorteren)
            func top(_ l: [BrowseEntry], _ n: Int) -> [URL] {
                var best: [BrowseEntry] = []
                for e in l where e.poster != nil {
                    if best.count < n { best.append(e); best.sort { $0.votes > $1.votes }; continue }
                    if e.votes > best[n - 1].votes { best[n - 1] = e; best.sort { $0.votes > $1.votes } }
                }
                return best.compactMap(\.poster)
            }
            let movies = list.filter { !$0.isSeries }, series = list.filter(\.isSeries)
            return BrowseCategory(id: id, title: title, source: source, entries: list,
                                  movieCount: movies.count, seriesCount: series.count, colors: colors,
                                  coverMovies: top(movies, 4), coverSeries: top(series, 4), coverAll: top(list, 4))
        }

        var x = BrowseIndex()
        x.genres = BrowseGenre.all.indices.compactMap { i -> BrowseCategory? in
            let members = genreMembers[i]
            guard !members.isEmpty else { return nil }
            let g = BrowseGenre.all[i]
            return category(id: "genre:\(g.key)", title: g.title, source: .genre, members: members, colors: g.colors)
        }
        .sorted { $0.entries.count > $1.entries.count }
        x.server = serverOrder.map { name in
            var h: UInt32 = 5381
            for u in name.unicodeScalars { h = (h &* 33) &+ u.value }
            let colors = serverPalette[Int(h % UInt32(serverPalette.count))]
            return category(id: "server:\(name)", title: name, source: .server, members: serverMembers[name] ?? [], colors: colors)
        }
        return x
    }
}

/// Houdt de index bij (één keer per bibliotheek en per portie nieuwe metadata), zodat Home, Films, Series en het
/// tabblad Categorieën hem delen. Rekent op de achtergrond.
@MainActor
final class BrowseIndexStore: ObservableObject {
    static let shared = BrowseIndexStore()
    @Published private(set) var index = BrowseIndex()
    @Published private(set) var isBuilding = false
    private var builtKey = ""
    private var task: Task<Void, Never>?

    /// Sleutel: bibliotheek + (afgerond) aantal titels met metadata + taal
    func key(_ playlists: PlaylistService) -> String {
        "\(playlists.source?.id.uuidString ?? "")-\(playlists.libraryVersion)-\(MetadataService.shared.cache.count / 50)-"
            + "\(AgeRatingService.shared.cache.count / 50)-\(Localizer.shared.language)"
    }

    func refresh(_ playlists: PlaylistService) {
        let k = key(playlists)
        guard k != builtKey else { return }
        builtKey = k
        let lib = playlists.library
        let meta = MetadataService.shared.cache, tmdb = AgeRatingService.shared.cache
        // genres aanvullen bij TMDB (gecachet, begrensd per sessie; zelfde werk als het leeftijdsfilter)
        AgeRatingService.shared.prefetch(lib)
        task?.cancel()
        if index.isEmpty { isBuilding = true }
        task = Task { [weak self] in
            // niet midden in het scrollen opnieuw rekenen
            if self?.index.isEmpty == false { await ScrollActivity.shared.waitUntilIdle() }
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .userInitiated) { BrowseIndex.build(lib, meta: meta, tmdb: tmdb) }.value
            guard !Task.isCancelled, let self else { return }
            self.index = built
            self.isBuilding = false
        }
    }
}
