import Foundation

/// Een titel van buiten (TMDB/Trakt) met jaar, om te koppelen aan je afspeellijst.
struct ExternalTitle: Codable, Sendable { var titles: [String]; var year: Int? }

/// Snelle titel-index van de afspeellijst. Wordt één keer per lijst op de achtergrond gebouwd
/// (het opschonen van tienduizenden IPTV-titels is te zwaar voor de hoofdthread) en gedeeld
/// door Home, Films en Series.
final class TitleMatcher: @unchecked Sendable {
    let movies: [Movie]
    let series: [Series]
    private let movieIndex: [String: Int]
    private let seriesIndex: [String: Int]

    static func norm(_ t: String) -> String {
        t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).nativeUTF8.filter { $0.isLetter || $0.isNumber }
    }

    init(movies: [Movie], series: [Series]) {
        self.movies = movies
        self.series = series
        func index(_ titles: [(String, Int?)]) -> [String: Int] {
            var d: [String: Int] = [:]
            d.reserveCapacity(titles.count * 3)
            for (i, (raw, year)) in titles.enumerated() {
                let parsed = TitleCleaner.parse(raw)
                for n in Set([Self.norm(parsed.title), Self.norm(raw)]) where n.count > 1 {
                    if d[n] == nil { d[n] = i }
                    if let y = year ?? parsed.year, d["\(n)|\(y)"] == nil { d["\(n)|\(y)"] = i }
                }
            }
            return d
        }
        movieIndex = index(movies.map { ($0.title, $0.year) })
        seriesIndex = index(series.map { ($0.title, $0.year) })
    }

    func movies(_ list: [ExternalTitle], limit: Int = 10) -> [Movie] { find(list, movieIndex, movies, limit) }
    func series(_ list: [ExternalTitle], limit: Int = 10) -> [Series] { find(list, seriesIndex, series, limit) }

    /// Eén titel strikt koppelen (persoonspagina): jaar ±1 als dat bekend is, anders alleen
    /// titels zonder jaar of met een jaar dat er dichtbij ligt (voorkomt "Home" → verkeerde film).
    func movie(_ t: ExternalTitle) -> Movie? { strict(t, movieIndex, movies, year: { $0.year ?? TitleCleaner.parse($0.title).year }) }
    func series(_ t: ExternalTitle) -> Series? { strict(t, seriesIndex, series, year: { $0.year ?? TitleCleaner.parse($0.title).year }) }

    private func strict<T>(_ t: ExternalTitle, _ idx: [String: Int], _ items: [T], year: (T) -> Int?) -> T? {
        for title in t.titles {
            let n = Self.norm(title)
            guard n.count > 1 else { continue }
            if let y = t.year {
                for yy in [y, y - 1, y + 1] { if let i = idx["\(n)|\(yy)"] { return items[i] } }
            }
            if let i = idx[n] {
                let item = items[i]
                guard let y = t.year, let iy = year(item) else { return item }
                if abs(iy - y) <= 1 { return item }
            }
        }
        return nil
    }

    private func find<T>(_ list: [ExternalTitle], _ idx: [String: Int], _ items: [T], _ limit: Int) -> [T] {
        var out: [T] = [], seen = Set<Int>()
        for t in list {
            for title in t.titles {
                let n = Self.norm(title)
                if let i = t.year.flatMap({ idx["\(n)|\($0)"] }) ?? idx[n] {
                    if seen.insert(i).inserted { out.append(items[i]) }
                    break
                }
            }
            if out.count >= limit { break }
        }
        return out
    }
}

/// Bewaart de index per afspeellijst-versie; bouwen gebeurt één keer, op de achtergrond.
@MainActor
final class MatcherCache {
    static let shared = MatcherCache()
    private var key = ""
    private var current: TitleMatcher?
    private var building: Task<TitleMatcher, Never>?

    func matcher(for lib: Library, key k: String) async -> TitleMatcher {
        if k == key, let current { return current }
        if k == key, let building { return await building.value }
        key = k
        let movies = lib.movies, series = lib.series
        let t = Task.detached(priority: .userInitiated) { TitleMatcher(movies: movies, series: series) }
        building = t
        let m = await t.value
        if key == k { current = m; building = nil }
        return m
    }
}

/// Trending vandaag (TMDB in de app-taal + Trakt), 6 uur bewaard en gedeeld door alle tabbladen.
actor TrendingStore {
    static let shared = TrendingStore()
    private var inFlight: [String: Task<[ExternalTitle], Never>] = [:]
    private struct Saved: Codable { var date: Date; var items: [ExternalTitle] }

    private static func key(_ shows: Bool, kids: Bool = false) -> String {
        "trending.\(kids ? "kids." : "")\(shows ? "tv" : "movie").\(Localizer.shared.language)"
    }

    /// Direct uit de cache (ook als die verlopen is), zonder netwerk.
    nonisolated static func cached(shows: Bool, kids: Bool = false) -> [ExternalTitle] {
        guard let d = UserDefaults.standard.data(forKey: key(shows, kids: kids)),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return [] }
        return s.items
    }
    nonisolated static func isFresh(shows: Bool, kids: Bool = false) -> Bool {
        guard let d = UserDefaults.standard.data(forKey: key(shows, kids: kids)),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return false }
        return Date().timeIntervalSince(s.date) < 6 * 3600 && !s.items.isEmpty
    }

    func get(shows: Bool, kids: Bool = false) async -> [ExternalTitle] {
        if Self.isFresh(shows: shows, kids: kids) { return Self.cached(shows: shows, kids: kids) }
        let k = Self.key(shows, kids: kids)
        if let t = inFlight[k] { return await t.value }
        let t = Task<[ExternalTitle], Never> {
            if kids {   // kids: populaire animatie/familie-titels (TMDB)
                return await TMDB.kidsTrending(shows: shows).map { ExternalTitle(titles: $0.titles, year: $0.year) }
            }
            let tmdb = await TMDB.trending(shows: shows).map { ExternalTitle(titles: $0.titles, year: $0.year) }
            let trakt = await TraktSync.shared.trending(shows: shows).compactMap { m in
                m.title.map { ExternalTitle(titles: [$0], year: m.year) }
            }
            return tmdb + trakt
        }
        inFlight[k] = t
        let items = await t.value
        inFlight[k] = nil
        if !items.isEmpty, let d = try? JSONEncoder().encode(Saved(date: Date(), items: items)) {
            UserDefaults.standard.set(d, forKey: k)
        }
        return items.isEmpty ? Self.cached(shows: shows, kids: kids) : items
    }
}
