import Foundation
import Combine

/// OpenSubtitles.com REST API: inloggen met je eigen account, zoeken op IMDb-ID, .srt downloaden.
@MainActor
final class OpenSubtitles: ObservableObject {
    static let shared = OpenSubtitles()

    @Published private(set) var username: String?
    @Published private(set) var remainingDownloads: Int?
    @Published var preferredLanguages: [String] {
        didSet { UserDefaults.standard.set(preferredLanguages, forKey: "os.languages") }
    }
    var isLoggedIn: Bool { session != nil }

    private struct Session: Codable { var token: String; var baseURL: String; var username: String }
    private var session: Session? { didSet { Keychain.setCodable(session, for: "opensubtitles.session"); username = session?.username } }

    private init() {
        preferredLanguages = UserDefaults.standard.stringArray(forKey: "os.languages") ?? ["nl", "en"]
        session = Keychain.getCodable(Session.self, "opensubtitles.session")
        username = session?.username
    }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil,
                         base: String? = nil) async throws -> Data {
        var c = URLComponents(string: "https://\(base ?? session?.baseURL ?? "api.opensubtitles.com")/api/v1\(path)")!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue(Secrets.openSubtitlesAPIKey, forHTTPHeaderField: "Api-Key")
        r.setValue(Secrets.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = session?.token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, h) = try await HTTP.data(r)
        if h.statusCode == 401 && session != nil && path != "/login" { session = nil }
        guard (200..<300).contains(h.statusCode) else {
            struct E: Decodable { let message: String? }
            let msg = (try? JSONDecoder().decode(E.self, from: d).message) ?? String(decoding: d, as: UTF8.self)
            throw HTTPError.status(h.statusCode, msg)
        }
        return d
    }

    // MARK: account

    func login(username: String, password: String) async throws {
        struct R: Decodable { struct U: Decodable { let allowed_downloads: Int?; let remaining_downloads: Int? }; let token: String; let base_url: String?; let user: U? }
        let d = try await request("/login", method: "POST", body: ["username": username, "password": password], base: "api.opensubtitles.com")
        let r = try JSONDecoder().decode(R.self, from: d)
        session = Session(token: r.token, baseURL: r.base_url ?? "api.opensubtitles.com", username: username)
        remainingDownloads = r.user?.remaining_downloads ?? r.user?.allowed_downloads
    }

    func logout() async {
        _ = try? await request("/logout", method: "DELETE")
        session = nil
    }

    // MARK: zoeken

    struct Subtitle: Identifiable, Hashable {
        var id: Int            // file_id
        var language: String
        var release: String
        var downloads: Int
        var hearingImpaired: Bool
        var fromTrusted: Bool
    }

    private struct SearchR: Decodable {
        struct Item: Decodable {
            struct A: Decodable {
                struct F: Decodable { let file_id: Int; let file_name: String? }
                let language: String?; let release: String?; let download_count: Int?
                let hearing_impaired: Bool?; let from_trusted: Bool?; let files: [F]
            }
            let attributes: A
        }
        let data: [Item]
    }

    func search(imdbID: String, season: Int? = nil, episode: Int? = nil, title: String? = nil) async throws -> [Subtitle] {
        let numeric = imdbID.replacingOccurrences(of: "tt", with: "")
        var q = ["languages": preferredLanguages.sorted().joined(separator: ",")]
        if let season, let episode {
            q["parent_imdb_id"] = String(Int(numeric) ?? 0)
            q["season_number"] = String(season); q["episode_number"] = String(episode)
        } else {
            q["imdb_id"] = String(Int(numeric) ?? 0)
        }
        let d = try await request("/subtitles", query: q)
        let r = try JSONDecoder().decode(SearchR.self, from: d)
        let subs = r.data.compactMap { i -> Subtitle? in
            guard let f = i.attributes.files.first else { return nil }
            return Subtitle(id: f.file_id, language: i.attributes.language ?? "?",
                            release: i.attributes.release ?? f.file_name ?? "Ondertitel",
                            downloads: i.attributes.download_count ?? 0,
                            hearingImpaired: i.attributes.hearing_impaired ?? false,
                            fromTrusted: i.attributes.from_trusted ?? false)
        }
        // eerst voorkeurstaal, dan populariteit
        return subs.sorted {
            let a = preferredLanguages.firstIndex(of: $0.language) ?? 99, b = preferredLanguages.firstIndex(of: $1.language) ?? 99
            return a != b ? a < b : $0.downloads > $1.downloads
        }
    }

    /// Download → lokaal .srt-bestand dat de player kan inladen.
    func download(_ sub: Subtitle) async throws -> URL {
        guard isLoggedIn else { throw OSError.notLoggedIn }
        struct R: Decodable { let link: String; let file_name: String?; let remaining: Int? }
        let d = try await request("/download", method: "POST", body: ["file_id": sub.id, "sub_format": "srt"])
        let r = try JSONDecoder().decode(R.self, from: d)
        remainingDownloads = r.remaining
        guard let link = URL(string: r.link) else { throw HTTPError.badURL }
        let data = try await HTTP.get(link)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(sub.id).srt")
        try data.write(to: file)
        return file
    }

    static let languages: [(code: String, name: String)] = [
        ("nl", "Nederlands"), ("en", "Engels"), ("de", "Duits"), ("fr", "Frans"), ("es", "Spaans"),
        ("it", "Italiaans"), ("pt-PT", "Portugees"), ("tr", "Turks"), ("ar", "Arabisch"), ("pl", "Pools")
    ]
}

enum OSError: LocalizedError {
    case notLoggedIn
    var errorDescription: String? { "Log eerst in bij OpenSubtitles (Instellingen)." }
}
