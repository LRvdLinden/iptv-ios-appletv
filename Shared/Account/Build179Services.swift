import Foundation
import Combine

// Build 179: beoordelingen (MDBList via de server-functie `ratings`), intro/samenvatting/aftiteling (IntroDB via de
// server-functie `introdb`) en de duimen per profiel (`profile.<id>.ratings`). Pure regels: Build179 (Build179Media.swift).
// Contract: docs/ACCOUNT.md → "Build 179", punten 9, 10 en 11.

/// Kleine cache op schijf (Caches/Bingr179/<naam>.json): sleutel → (tijd, JSON). Wordt alleen op de hoofdthread gebruikt.
@MainActor
final class Cache179 {
    private struct Entry: Codable { var at: Double; var data: Data? }
    private let url: URL
    private var entries: [String: Entry]
    private var saveTask: Task<Void, Never>?
    private let limit: Int

    init(_ name: String, limit: Int = 3000) {
        let dir = AppDirs.caches.appendingPathComponent("Bingr179", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name + ".json")
        self.limit = limit
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// (tijd, inhoud) of nil; inhoud nil = "niet gevonden" bewaard
    func get(_ key: String) -> (at: Double, data: Data?)? { entries[key].map { ($0.at, $0.data) } }

    /// Alle bewaarde inhoud (sleutel → JSON)
    func allData() -> [String: Data] { entries.compactMapValues { $0.data } }

    func set(_ key: String, _ data: Data?) {
        entries[key] = Entry(at: Date().timeIntervalSince1970, data: data)
        if entries.count > limit {
            for k in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - limit).map(\.key) { entries[k] = nil }
        }
        saveTask?.cancel()
        let snapshot = entries, url = self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let d = try? JSONEncoder().encode(snapshot) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }
}

// MARK: - 9. Beoordelingen

@MainActor
final class Ratings179 {
    static let shared = Ratings179()
    static let maxAge: Double = 7 * 86400
    private let cache = Cache179("ratings")
    private var running: [String: Task<[(source: String, value: Double)]?, Never>] = [:]

    private struct Stored: Codable { var source: String; var value: Double }

    /// Beoordelingen van een titel (7 dagen bewaard), of nil als de server ze niet heeft (niet ingelogd, geen sleutel, fout).
    func ratings(tmdb: Int?, isShow: Bool, imdb: String?) async -> [(source: String, value: Double)]? {
        let key: String
        var body: [String: Any] = [:]
        if let t = tmdb, t > 0 {
            key = (isShow ? "show:" : "movie:") + String(t)
            body = ["type": isShow ? "show" : "movie", "tmdb": t]
            if let imdb, imdb.hasPrefix("tt") { body["imdb"] = imdb }
        } else if let imdb, imdb.hasPrefix("tt") {
            key = "imdb:" + imdb
            body = ["imdb": imdb, "type": isShow ? "show" : "movie"]
        } else {
            return nil
        }
        if let hit = cache.get(key), Date().timeIntervalSince1970 - hit.at < Self.maxAge, let d = hit.data,
           let list = try? JSONDecoder().decode([Stored].self, from: d) {
            return list.map { ($0.source, $0.value) }
        }
        if let r = running[key] { return await r.value }
        let task = Task<[(source: String, value: Double)]?, Never> {
            guard let r = await AccountService.shared.callFunction("ratings", body), r.status == 200 else { return nil }
            return Build179.parseRatings(r.json)
        }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if let result, let d = try? JSONEncoder().encode(result.map { Stored(source: $0.source, value: $0.value) }) {
            cache.set(key, d)
        }
        return result
    }
}

// MARK: - 10. IntroDB

@MainActor
final class IntroDB179 {
    static let shared = IntroDB179()
    static let maxAge: Double = 30 * 86400
    static let missAge: Double = 86400
    private let cache = Cache179("introdb")

    /// Tijden van een aflevering (30 dagen bewaard, niet gevonden 1 dag), of nil.
    func segments(tmdb: Int, imdb: String?, season: Int, episode: Int) async -> Build179.Segments? {
        let key = "\(tmdb):\(season):\(episode)"
        let now = Date().timeIntervalSince1970
        if let hit = cache.get(key) {
            if let d = hit.data, now - hit.at < Self.maxAge { return try? JSONDecoder().decode(Build179.Segments.self, from: d) }
            if hit.data == nil, now - hit.at < Self.missAge { return nil }
        }
        var body: [String: Any] = ["tmdb": tmdb, "season": season, "episode": episode]
        if let imdb, imdb.hasPrefix("tt") { body["imdb"] = imdb }
        guard let r = await AccountService.shared.callFunction("introdb", body), r.status == 200 else { return nil }
        let seg = Build179.parseIntro(r.json)
        if let seg { cache.set(key, try? JSONEncoder().encode(seg)) }
        else if (r.json["error"] as? String) == "not_found" { cache.set(key, nil) }
        return seg
    }

    // Build 186: veel IPTV-series hebben geen TMDB-id van de server; zoek hem dan zelf op (IMDb-id, anders de
    // opgeschoonde titel + jaar), zodat IntroDB ook voor die afleveringen tijden geeft. Per sessie onthouden.
    private var showIDs: [String: Int?] = [:]
    private struct Find: Decodable { struct R: Decodable { let id: Int }; let tv_results: [R]? }
    private struct Search: Decodable { struct R: Decodable { let id: Int }; let results: [R]? }

    func showTMDB(title: String, year: Int?, imdb: String?) async -> Int? {
        let key = "\(imdb ?? "")|\(title.lowercased())|\(year ?? 0)"
        if let known = showIDs[key] { return known }
        guard Secrets.isSet(Secrets.tmdbAPIKey) else { return nil }
        var id: Int?
        if let imdb, imdb.hasPrefix("tt") {
            let f: Find? = await TMDB.get("/find/\(imdb)", ["external_source": "imdb_id"])
            id = f?.tv_results?.first?.id
        }
        if id == nil {
            let p = TitleCleaner.parse(title)
            let y = p.year ?? year
            var q: [String: String] = ["query": p.title, "include_adult": "false"]
            if let y { q["first_air_date_year"] = String(y) }
            let s: Search? = await TMDB.get("/search/tv", q)
            id = s?.results?.first?.id
            if id == nil, y != nil {
                q["first_air_date_year"] = nil
                let s2: Search? = await TMDB.get("/search/tv", q)
                id = s2?.results?.first?.id
            }
        }
        showIDs[key] = id
        return id
    }
}

// MARK: - 11. Duimen

@MainActor
final class Thumbs179: ObservableObject {
    static let shared = Thumbs179()

    /// Verandert bij elke wijziging (schermen tekenen opnieuw)
    @Published private(set) var revision = 0

    private let defaults = UserDefaults.standard
    private func key(_ id: UUID) -> String { "ratings.v179.\(id.uuidString)" }
    private var store: CloudStore { CloudStore.shared }
    private var current: UUID? { store.activeProfileID ?? store.mainProfileID }

    /// Alle duimen van een profiel (ook de weggehaalde, als tombstone met waarde 0)
    func all(_ id: UUID) -> [Build179.Thumb] {
        defaults.data(forKey: key(id)).flatMap { try? JSONDecoder().decode([Build179.Thumb].self, from: $0) } ?? []
    }

    /// Duim van het actieve profiel voor deze sleutel: 1, −1 of 0.
    func value(_ k: String) -> Int {
        _ = revision
        guard let id = current else { return 0 }
        return all(id).first { $0.key == k }?.value ?? 0
    }

    /// Sleutels met duim omhoog / omlaag van het actieve profiel
    func keys(_ v: Int) -> Set<String> {
        _ = revision
        guard let id = current else { return [] }
        return Set(all(id).filter { $0.value == v }.map(\.key))
    }

    /// Duim zetten; nog eens dezelfde = weghalen (0).
    func toggle(_ k: String, _ v: Int) {
        guard let id = current else { return }
        let now = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        let next = value(k) == v ? 0 : v
        let merged = Build179.mergeThumbs([Build179.Thumb(key: k, value: next, at: now)], all(id), now: now)
        setSynced(id, merged)
        store.stateEdited.send((id, .profile))
    }

    func setSynced(_ id: UUID, _ list: [Build179.Thumb]) {
        guard list != all(id) else { return }
        if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: key(id)) }
        revision += 1
    }
}

// MARK: - 11. Cast per titel (voor "Voor jou")

/// De top 5 van de cast per titel (sleutel zoals de duimen), bewaard zodra een detailpagina geladen is. Zo telt de cast
/// van titels met duim omhoog mee zonder extra netwerk.
@MainActor
final class Taste179 {
    static let shared = Taste179()
    private let cache = Cache179("taste", limit: 4000)
    private var memo: [String: [String]] = [:]

    func note(key: String, cast: [String]) {
        let top = Array(cast.prefix(5)).map { Build179.norm($0) }.filter { !$0.isEmpty }
        guard !top.isEmpty, memo[key] != top else { return }
        memo[key] = top
        cache.set(key, try? JSONEncoder().encode(top))
    }

    /// Alles (sleutel → cast), voor de berekening op de achtergrond
    func all() -> [String: [String]] {
        var out = cache.allData().compactMapValues { try? JSONDecoder().decode([String].self, from: $0) }
        for (k, v) in memo { out[k] = v }
        return out
    }

    func cast(_ key: String) -> [String] {
        if let m = memo[key] { return m }
        let v = cache.get(key)?.data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        memo[key] = v
        return v
    }
}
