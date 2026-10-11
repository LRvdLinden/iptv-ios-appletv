import Foundation
import Combine

/// IMDb-gegevens via OMDb (score, poster, plot, cast) + IMDb-ID en trailer via Trakt.
/// Resultaten worden op schijf gecachet zodat elke titel maar één keer opgezocht wordt.
@MainActor
final class MetadataService: ObservableObject {
    static let shared = MetadataService()

    @Published private(set) var cache: [String: TitleMetadata] = [:]   // key: "m|title|year" of "s|title|year"
    private var inFlight: [String: Task<TitleMetadata?, Never>] = [:]
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("imdb-metadata.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: TitleMetadata].self, from: d) { cache = c }
    }

    nonisolated static func key(title: String, year: Int?, isShow: Bool) -> String {
        "\(isShow ? "s" : "m")|\(title.lowercased())|\(year.map(String.init) ?? "")"
    }

    func cached(_ m: Movie) -> TitleMetadata? { cache[Self.key(title: m.title, year: m.year, isShow: false)] }
    func cached(_ s: Series) -> TitleMetadata? { cache[Self.key(title: s.title, year: s.year, isShow: true)] }

    func metadata(_ m: Movie, knownIMDb: String? = nil) async -> TitleMetadata? {
        await fetch(title: m.title, year: m.year, isShow: false, imdb: knownIMDb ?? m.imdbID)
    }
    func metadata(_ s: Series) async -> TitleMetadata? {
        await fetch(title: s.title, year: s.year, isShow: true, imdb: s.imdbID)
    }

    func fetch(title: String, year: Int?, isShow: Bool, imdb: String?) async -> TitleMetadata? {
        let k = Self.key(title: title, year: year, isShow: isShow)
        if let c = cache[k] { return c }
        if let t = inFlight[k] { return await t.value }
        let task = Task<TitleMetadata?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.resolve(title: title, year: year, isShow: isShow, imdb: imdb)
        }
        inFlight[k] = task
        let r = await task.value
        inFlight[k] = nil
        if let r { cache[k] = r; scheduleSave() }
        return r
    }

    private func resolve(title: String, year: Int?, isShow: Bool, imdb: String?) async -> TitleMetadata? {
        // 1. IMDb-ID + trailer via Trakt
        var trakt: TraktSync.TraktMedia?
        if let imdb { trakt = await TraktSync.shared.lookup(imdb: imdb) }
        if trakt == nil { trakt = await TraktSync.shared.lookup(title: title, year: year, isShow: isShow) }
        let imdbID = imdb ?? trakt?.ids.imdb

        // 2. IMDb-details via OMDb
        var meta = await OMDb.fetch(imdbID: imdbID, title: title, year: year, isShow: isShow)
        if meta == nil, let imdbID {
            meta = TitleMetadata(imdbID: imdbID, title: trakt?.title ?? title, year: trakt?.year.map(String.init))
        }
        meta?.trailerYouTubeID = trakt?.trailer.flatMap { Self.youtubeID($0) }
        meta?.traktSlug = trakt?.ids.slug
        return meta
    }

    static func youtubeID(_ url: String) -> String? {
        guard let c = URLComponents(string: url) else { return nil }
        if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        if c.host?.contains("youtu.be") == true { return String(c.path.dropFirst()) }
        return nil
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = cache, url = cacheURL
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }
}

enum OMDb {
    private struct R: Decodable {
        let Title: String?; let Year: String?; let Rated: String?; let Runtime: String?; let Genre: String?
        let Director: String?; let Actors: String?; let Plot: String?; let Poster: String?
        let imdbRating: String?; let imdbVotes: String?; let imdbID: String?; let `Type`: String?
        let totalSeasons: String?; let Response: String?
    }

    static func fetch(imdbID: String?, title: String, year: Int?, isShow: Bool) async -> TitleMetadata? {
        guard Secrets.isSet(Secrets.omdbAPIKey) else { return nil }
        var c = URLComponents(string: "https://www.omdbapi.com/")!
        var q = [URLQueryItem(name: "apikey", value: Secrets.omdbAPIKey), URLQueryItem(name: "plot", value: "full")]
        if let imdbID { q.append(URLQueryItem(name: "i", value: imdbID)) }
        else {
            q.append(URLQueryItem(name: "t", value: title))
            q.append(URLQueryItem(name: "type", value: isShow ? "series" : "movie"))
            if let year { q.append(URLQueryItem(name: "y", value: String(year))) }
        }
        c.queryItems = q
        guard let url = c.url, let r = try? await HTTP.json(R.self, url), r.Response == "True", let id = r.imdbID else { return nil }
        func clean(_ s: String?) -> String? { (s == nil || s == "N/A") ? nil : s }
        return TitleMetadata(imdbID: id, title: r.Title ?? title, year: clean(r.Year), rated: clean(r.Rated),
                             runtime: clean(r.Runtime), genre: clean(r.Genre), director: clean(r.Director),
                             actors: clean(r.Actors), plot: clean(r.Plot), poster: clean(r.Poster)?.urlValue,
                             imdbRating: clean(r.imdbRating), imdbVotes: clean(r.imdbVotes), type: clean(r.`Type`),
                             totalSeasons: clean(r.totalSeasons).flatMap(Int.init))
    }
}
