import Foundation

/// Build 143: covers (posters) voor Verder kijken.
///
/// In de voortgang staat het beeld waarmee het afspelen begon: bij een aflevering het beeld van de scène (still), en bij
/// voortgang van een ander apparaat wat dat apparaat meegaf. Ook de poster uit de bibliotheek ontbreekt vaak (veel
/// IPTV-aanbieders geven bij series geen cover, of een beeld uit de film). Daarom zoekt Verder kijken de echte poster
/// op bij TMDB (titel + jaar, film of serie), bewaard op dit apparaat (Caches, geen UserDefaults: op Apple TV is die
/// opslag klein). Volgorde in de tegel: TMDB-poster, anders de poster uit de bibliotheek, anders het opgeslagen beeld.
@MainActor
final class ContinueCovers: ObservableObject {
    static let shared = ContinueCovers()

    /// "m|<schone titel>|<jaar>" / "s|…" → poster-URL (lege tekst = gezocht, niets gevonden)
    @Published private(set) var posters: [String: String] = [:]
    private var loaded = false
    private var inFlight = Set<String>()
    private var saveTask: Task<Void, Never>?

    nonisolated static func key(title: String, year: Int?, isShow: Bool) -> String {
        let p = TitleCleaner.parse(title)
        return (isShow ? "s|" : "m|") + p.title.lowercased() + "|" + String(year ?? p.year ?? 0)
    }

    nonisolated private static var fileURL: URL {
        AppDirs.caches.appendingPathComponent("continuecovers.v143.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: Self.fileURL), let m = try? JSONDecoder().decode([String: String].self, from: d) {
            for (k, v) in m where posters[k] == nil { posters[k] = v }
        }
    }

    /// Bekende TMDB-poster (nil = niet bekend of niet gevonden).
    func cover(title: String, year: Int?, isShow: Bool) -> URL? {
        load()
        guard let s = posters[Self.key(title: title, year: year, isShow: isShow)], !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Ontbrekende posters op de achtergrond opzoeken (hooguit 12 per keer).
    func resolve(_ items: [(title: String, year: Int?, isShow: Bool)]) async {
        load()
        guard !Screenshots.isActive, Secrets.isSet(Secrets.tmdbAPIKey) else { return }
        var todo: [(String, String, Int?, Bool)] = []
        for i in items {
            let k = Self.key(title: i.title, year: i.year, isShow: i.isShow)
            guard posters[k] == nil, !inFlight.contains(k), !todo.contains(where: { $0.0 == k }) else { continue }
            let p = TitleCleaner.parse(i.title)
            guard !p.title.isEmpty else { continue }
            todo.append((k, p.title, i.year ?? p.year, i.isShow))
        }
        guard !todo.isEmpty else { return }
        for t in todo.prefix(12) { inFlight.insert(t.0) }
        struct R: Decodable { struct Hit: Decodable { let poster_path: String? }; let results: [Hit]? }
        var changed = false
        for (k, q, y, show) in todo.prefix(12) {
            var params = ["query": q, "language": TMDB.language, "include_adult": "false"]
            if let y, y > 0 { params[show ? "first_air_date_year" : "year"] = String(y) }
            let r: R? = await TMDB.get(show ? "/search/tv" : "/search/movie", params)
            inFlight.remove(k)
            guard let r else { continue }   // netwerkfout: later opnieuw
            let path = r.results?.first(where: { $0.poster_path != nil })?.poster_path
            posters[k] = TMDB.img(path, "w342")?.absoluteString ?? ""
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        saveTask?.cancel()
        let snapshot = posters, url = Self.fileURL
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let d = try? JSONEncoder().encode(snapshot) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }
}
