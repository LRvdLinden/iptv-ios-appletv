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
    /// Standaardtaal voor OpenSubtitles (ISO 639-1, bijv. "nl"); "" = alle talen
    @Published var defaultLanguage: String {
        didSet { UserDefaults.standard.set(defaultLanguage, forKey: "os.language") }
    }

    private struct Session: Codable { var token: String; var baseURL: String; var username: String }
    private var session: Session? { didSet { Keychain.setCodable(session, for: "opensubtitles.session"); username = session?.username } }

    private init() {
        let prefs = UserDefaults.standard.stringArray(forKey: "os.languages") ?? ["nl", "en"]
        preferredLanguages = prefs
        if let d = UserDefaults.standard.string(forKey: "os.language") {
            defaultLanguage = d
        } else {
            let track = TrackPreferences.subtitle
            let first = prefs.first.map { String($0.prefix(2)).lowercased() }
            defaultLanguage = track.count == 2 ? track : (first ?? String(Localizer.shared.language.prefix(2)))
        }
        session = Keychain.getCodable(Session.self, "opensubtitles.session")
        username = session?.username
    }

    /// build 141: alleen een host van OpenSubtitles (api.opensubtitles.com, vip-api.opensubtitles.com …), ook als hij
    /// uit de login of de account-sync komt; anders api.opensubtitles.com. "https://" en een "/" aan het eind mogen.
    static func safeBase(_ raw: String?) -> String {
        let fallback = "api.opensubtitles.com"
        guard var h = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !h.isEmpty else { return fallback }
        if h.hasPrefix("https://") { h.removeFirst(8) }
        while h.hasSuffix("/") { h.removeLast() }
        let okChars = h.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
        guard okChars, h == "opensubtitles.com" || h.hasSuffix(".opensubtitles.com") else { return fallback }
        return h
    }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil,
                         base: String? = nil) async throws -> Data {
        // build 91: zonder app-sleutel (nog niet van de server) niet aanroepen: dat geeft een 401/403 die niets met je inlog te maken heeft
        guard Secrets.openSubtitlesReady else { throw OSError.notReady }
        var c = URLComponents(string: "https://\(Self.safeBase(base ?? session?.baseURL))/api/v1\(path)")!
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
        // build 91: alleen bij aanroepen die echt de inlog gebruiken de sessie wissen (dat logt via de account ook je
        // andere apparaten uit); een 401 bij zoeken zegt niets over het token. Er wordt geen wachtwoord bewaard,
        // dus opnieuw inloggen kan hier niet: dan moet de gebruiker zelf opnieuw inloggen.
        if h.statusCode == 401 && session != nil && Self.authenticatedPaths.contains(path) {
            session = nil
            remainingDownloads = nil
            throw OSError.notLoggedIn   // niet de melding over de afspeellijst (HTTPError 401)
        }
        guard (200..<300).contains(h.statusCode) else {
            struct E: Decodable { let message: String? }
            let msg = (try? JSONDecoder().decode(E.self, from: d).message) ?? String(decoding: d, as: UTF8.self)
            throw HTTPError.status(h.statusCode, msg)
        }
        return d
    }

    /// build 91: aanroepen waarbij een 401 betekent dat het token niet meer geldig is
    private static let authenticatedPaths: Set<String> = ["/download", "/infos/user"]

    // MARK: account

    func login(username: String, password: String) async throws {
        struct R: Decodable { struct U: Decodable { let allowed_downloads: Int?; let remaining_downloads: Int? }; let token: String; let base_url: String?; let user: U? }
        let d = try await request("/login", method: "POST", body: ["username": username, "password": password], base: "api.opensubtitles.com")
        let r = try JSONDecoder().decode(R.self, from: d)
        session = Session(token: r.token, baseURL: Self.safeBase(r.base_url), username: username)
        remainingDownloads = r.user?.remaining_downloads ?? r.user?.allowed_downloads
    }

    /// Wat de app bewaart om ingelogd te blijven (voor de Bingr-account, zie StateSync).
    var syncedSession: (token: String, baseURL: String, username: String)? {
        session.map { ($0.token, $0.baseURL, $0.username) }
    }

    /// Sessie uit de Bingr-account zetten of wissen (zonder uitloggen bij OpenSubtitles).
    func applySyncedSession(token: String, baseURL: String?, username: String) {
        let s = Session(token: token, baseURL: Self.safeBase(baseURL), username: username)   // build 141: vaste lijst
        guard session?.token != s.token || session?.baseURL != s.baseURL || session?.username != s.username else { return }
        session = s
        Task { await refreshUser() }
    }

    func forgetSession() {
        if session != nil { session = nil }
        remainingDownloads = nil
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
        /// Gemaakt voor precies dit bestand (hash komt overeen), build 59
        var hashMatch = false
    }

    private struct SearchR: Decodable {
        struct Item: Decodable {
            struct A: Decodable {
                struct F: Decodable { let file_id: Int; let file_name: String? }
                let language: String?; let release: String?; let download_count: Int?
                let hearing_impaired: Bool?; let from_trusted: Bool?; let files: [F]
                let moviehash_match: Bool?
            }
            let attributes: A
        }
        let data: [Item]
    }

    /// Taalcode(s) zoals OpenSubtitles ze gebruikt.
    static func apiCodes(_ code: String) -> [String] {
        switch code {
        case "pt": return ["pt-br", "pt-pt"]
        case "zh": return ["zh-cn", "zh-tw"]
        case "": return []
        default: return [code.lowercased()]
        }
    }
    /// Terug naar ISO 639-1 ("pt-PT" → "pt").
    static func baseCode(_ c: String) -> String { String(c.lowercased().prefix(2)) }

    /// Zoeken op IMDb-ID, anders TMDB-ID (build 59), anders op titel. `languages` leeg = alle talen.
    /// `movieHash`: OpenSubtitles-hash van het bestand; treffers die precies passen komen bovenaan.
    func search(imdbID: String?, tmdbID: Int? = nil, title: String? = nil, year: Int? = nil, season: Int? = nil, episode: Int? = nil,
                languages: [String], movieHash: String? = nil) async throws -> [Subtitle] {
        // build 157: alleen met Lifetime (een bestaande koppeling blijft bewaard, maar wordt bij Gratis niet gebruikt)
        guard EntitlementsService.shared.allows(.opensubtitles) else { throw FeatureLockedError(feature: "opensubtitles") }
        var q: [String: String] = [:]
        let langs = Array(Set(languages.flatMap(Self.apiCodes))).sorted()
        if !langs.isEmpty { q["languages"] = langs.joined(separator: ",") }
        if let movieHash { q["moviehash"] = movieHash }
        let numeric = (imdbID ?? "").replacingOccurrences(of: "tt", with: "")
        if let n = Int(numeric), n > 0 {
            if let season, let episode {
                q["parent_imdb_id"] = String(n)
                q["season_number"] = String(season); q["episode_number"] = String(episode)
            } else {
                q["imdb_id"] = String(n)
            }
        } else if let tmdbID, tmdbID > 0 {
            if let season, let episode {
                q["parent_tmdb_id"] = String(tmdbID)
                q["season_number"] = String(season); q["episode_number"] = String(episode)
            } else {
                q["tmdb_id"] = String(tmdbID)
            }
        } else if let title, !title.isEmpty {
            let parsed = TitleCleaner.parse(title)
            q["query"] = parsed.title.lowercased()
            if let season, let episode {
                q["type"] = "episode"; q["season_number"] = String(season); q["episode_number"] = String(episode)
            } else {
                q["type"] = "movie"
                if let y = year ?? parsed.year { q["year"] = String(y) }
            }
        } else {
            return []
        }
        let d = try await request("/subtitles", query: q)
        let r = try JSONDecoder().decode(SearchR.self, from: d)
        let subs = r.data.compactMap { i -> Subtitle? in
            guard let f = i.attributes.files.first else { return nil }
            return Subtitle(id: f.file_id, language: i.attributes.language ?? "?",
                            release: i.attributes.release ?? f.file_name ?? "Subtitle",
                            downloads: i.attributes.download_count ?? 0,
                            hearingImpaired: i.attributes.hearing_impaired ?? false,
                            fromTrusted: i.attributes.from_trusted ?? false,
                            hashMatch: i.attributes.moviehash_match ?? false)
        }
        // eerst gevraagde taal, dan betrouwbaar, dan populariteit
        let order = languages.map { $0.lowercased() }
        return subs.sorted {
            let a = order.firstIndex(of: Self.baseCode($0.language)) ?? 99, b = order.firstIndex(of: Self.baseCode($1.language)) ?? 99
            if a != b { return a < b }
            if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
            if $0.fromTrusted != $1.fromTrusted { return $0.fromTrusted }
            return $0.downloads > $1.downloads
        }
    }

    /// Oude aanroep (zoeken in de standaardtaal).
    func search(imdbID: String, season: Int? = nil, episode: Int? = nil, title: String? = nil) async throws -> [Subtitle] {
        try await search(imdbID: imdbID, title: title, season: season, episode: episode,
                         languages: defaultLanguage.isEmpty ? [] : [defaultLanguage])
    }

    /// OpenSubtitles-hash van een bestand (build 59): grootte + de eerste en laatste 64 kB als 64-bits getallen opgeteld.
    /// Bij http(s) met twee Range-verzoeken, alleen voor losse videobestanden (geen HLS/live); hooguit een paar seconden.
    nonisolated static func movieHash(_ url: URL?) async -> String? {
        guard let url else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["mkv", "mp4", "m4v", "avi", "mov", "ts", "wmv", "mpg", "mpeg"].contains(ext) else { return nil }
        let chunk = 65_536
        func sum(_ d: Data) -> UInt64 {
            var h: UInt64 = 0
            d.withUnsafeBytes { raw in
                let n = raw.count / 8
                for i in 0..<n { h &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
            }
            return h
        }
        let head: Data, tail: Data, size: UInt64
        if url.isFileURL {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? fh.close() }
            guard let end = try? fh.seekToEnd(), end >= UInt64(chunk) else { return nil }
            size = end
            try? fh.seek(toOffset: 0)
            head = (try? fh.read(upToCount: chunk)) ?? Data()
            try? fh.seek(toOffset: end - UInt64(chunk))
            tail = (try? fh.read(upToCount: chunk)) ?? Data()
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            func range(_ r: String) async -> (Data, HTTPURLResponse)? {
                var req = URLRequest(url: url, timeoutInterval: 4)
                req.setValue("bytes=\(r)", forHTTPHeaderField: "Range")
                req.setValue(Secrets.userAgent, forHTTPHeaderField: "User-Agent")
                guard let (d, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse,
                      h.statusCode == 206 else { return nil }
                return (d, h)
            }
            guard let first = await range("0-\(chunk - 1)"),
                  let total = (first.1.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap({ UInt64($0) }),
                  total >= UInt64(chunk),
                  let last = await range("\(total - UInt64(chunk))-\(total - 1)") else { return nil }
            head = first.0; tail = last.0; size = total
        } else {
            return nil
        }
        guard head.count == chunk, tail.count == chunk else { return nil }
        let h = size &+ sum(head) &+ sum(tail)
        return String(format: "%016llx", h)
    }

    /// Account-info (resterende downloads vandaag) verversen.
    func refreshUser() async {
        guard isLoggedIn else { return }
        struct R: Decodable { struct D: Decodable { let remaining_downloads: Int?; let allowed_downloads: Int? }; let data: D }
        if let d = try? await request("/infos/user"), let r = try? JSONDecoder().decode(R.self, from: d) {
            remainingDownloads = r.data.remaining_downloads ?? r.data.allowed_downloads
        }
    }

    /// Download → lokaal .srt-bestand dat de player kan inladen.
    func download(_ sub: Subtitle) async throws -> URL {
        guard isLoggedIn else { throw OSError.notLoggedIn }
        guard EntitlementsService.shared.allows(.opensubtitles) else { throw FeatureLockedError(feature: "opensubtitles") }
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
        ("nl", "Nederlands"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
        ("it", "Italiano"), ("pt-PT", "Português"), ("tr", "Türkçe"), ("ar", "العربية"), ("pl", "Polski"), ("zh-CN", "简体中文")
    ]
}

enum OSError: LocalizedError {
    case notLoggedIn
    /// build 91: de app-sleutel voor OpenSubtitles is er (nog) niet
    case notReady
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L("Sign in to OpenSubtitles first (My Bingr).")
        case .notReady: return L("OpenSubtitles isn't available yet. Try again in a moment.")
        }
    }
}
