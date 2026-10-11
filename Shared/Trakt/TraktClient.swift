import Foundation
import CryptoKit

struct TraktTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var username: String?
}

struct TraktDeviceCode: Decodable {
    let device_code: String
    let user_code: String
    let verification_url: String
    let expires_in: Int
    let interval: Int
}

struct TraktIDs: Codable, Hashable { var trakt: Int?; var slug: String?; var imdb: String?; var tmdb: Int?; var tvdb: Int? }

/// Trakt API v2 — inloggen via koppelcode (werkt ook op Apple TV), daarna Bearer-token.
actor TraktClient {
    static let shared = TraktClient()
    private let base = URL(string: "https://api.trakt.tv")!
    private let tokenKey = "trakt.tokens"

    var tokens: TraktTokens? { Keychain.getCodable(TraktTokens.self, tokenKey) }
    var isLoggedIn: Bool { tokens != nil }

    // MARK: inloggen (device flow)

    /// Host voor /oauth: Trakt verhuist dit naar auth.trakt.tv; api.trakt.tv blijft als terugval.
    private var oauthBase: URL {
        get { URL(string: UserDefaults.standard.string(forKey: "trakt.oauthHost") ?? "https://api.trakt.tv")! }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "trakt.oauthHost") }
    }
    private static let oauthHosts = ["https://api.trakt.tv", "https://auth.trakt.tv"]
    /// PKCE-verifier voor deze koppelpoging (nieuwe Trakt-apps hebben geen client secret meer).
    private var verifier = ""

    /// Body met client_secret alleen als de app er (nog) een heeft.
    private func oauthBody(_ b: [String: Any]) -> [String: Any] {
        var b = b
        b["client_id"] = Secrets.traktClientID
        if Secrets.isSet(Secrets.traktClientSecret) { b["client_secret"] = Secrets.traktClientSecret }
        return b
    }

    private func oauthRequest(_ path: String, _ body: [String: Any], host: URL? = nil) throws -> URLRequest {
        var req = URLRequest(url: (host ?? oauthBase).appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(Secrets.traktClientID, forHTTPHeaderField: "trakt-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func randomVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in chars.randomElement()! })
    }
    private static func challenge(_ v: String) -> String {
        Data(SHA256.hash(data: Data(v.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func startDeviceLogin() async throws -> TraktDeviceCode {
        verifier = Self.randomVerifier()
        let body: [String: Any] = ["client_id": Secrets.traktClientID,
                                   "code_challenge": Self.challenge(verifier), "code_challenge_method": "S256"]
        var lastStatus = 0
        for h in Self.oauthHosts {
            guard let host = URL(string: h) else { continue }
            let (d, r) = try await HTTP.data(try oauthRequest("/oauth/device/code", body, host: host))
            if (200..<300).contains(r.statusCode), let c = try? JSONDecoder().decode(TraktDeviceCode.self, from: d) {
                oauthBase = host
                return c
            }
            lastStatus = r.statusCode
        }
        throw HTTPError.status(lastStatus, "Trakt")
    }

    /// Pollt tot de gebruiker de code heeft bevestigd op trakt.tv/activate.
    func pollForToken(_ code: TraktDeviceCode) async throws -> TraktTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        var interval = UInt64(max(code.interval, 5))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            let req = try oauthRequest("/oauth/device/token", oauthBody(["code": code.device_code, "code_verifier": verifier]))
            let (d, r) = try await HTTP.data(req)
            switch r.statusCode {
            case 200:
                let t = try JSONDecoder().decode(TokenResponse.self, from: d)
                var tok = t.tokens
                tok.username = try? await fetchUsername(tok.accessToken)
                Keychain.setCodable(tok, for: tokenKey)
                return tok
            case 400: continue                    // nog niet bevestigd
            case 429: interval += 1               // te snel
            case 404, 409, 410, 418: throw TraktError.denied(r.statusCode)
            default: continue
            }
        }
        throw TraktError.expired
    }

    func logout() {
        if let t = tokens {
            Task {
                if let req = try? await self.oauthRequest("/oauth/revoke", self.oauthBody(["token": t.accessToken])) {
                    _ = try? await HTTP.data(req)
                }
            }
        }
        Keychain.set(nil, for: tokenKey)
    }

    private struct TokenResponse: Decodable {
        let access_token: String, refresh_token: String, expires_in: Int, created_at: Int
        var tokens: TraktTokens {
            TraktTokens(accessToken: access_token, refreshToken: refresh_token,
                        expiresAt: Date(timeIntervalSince1970: TimeInterval(created_at + expires_in)))
        }
    }

    private func fetchUsername(_ token: String) async throws -> String? {
        struct S: Decodable { struct U: Decodable { let username: String? }; let user: U? }
        var r = URLRequest(url: base.appendingPathComponent("/users/settings"))
        headers(token).forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, _) = try await HTTP.data(r)
        return try JSONDecoder().decode(S.self, from: d).user?.username
    }

    /// Redirect-URI's zoals ze bij de Trakt-app geregistreerd kunnen zijn.
    static let redirectURIs = ["https://github.com/LRvdLinden/iptv-ios-appletv", "urn:ietf:wg:oauth:2.0:oob"]

    private func validToken() async throws -> String {
        guard var t = tokens else { throw TraktError.notLoggedIn }
        if t.expiresAt.timeIntervalSinceNow < 24 * 3600 {
            // Inloggen gaat met een apparaatcode (geen redirect). Bij verversen eist Trakt wel een
            // geregistreerde redirect-URI; we proberen de veilige https-variant en de oude "oob".
            var refreshed = false, unauthorized = 0
            for redirect in Self.redirectURIs {
                let req = try oauthRequest("/oauth/token", oauthBody([
                    "refresh_token": t.refreshToken, "redirect_uri": redirect, "grant_type": "refresh_token"]))
                let (d, r) = try await HTTP.data(req)
                if r.statusCode == 200, let n = try? JSONDecoder().decode(TokenResponse.self, from: d) {
                    let user = t.username; t = n.tokens; t.username = user
                    Keychain.setCodable(t, for: tokenKey)
                    refreshed = true; break
                }
                if r.statusCode == 401 || r.statusCode == 400 { unauthorized += 1 }
            }
            if !refreshed && unauthorized == Self.redirectURIs.count && t.expiresAt < Date() {
                Keychain.set(nil, for: tokenKey); throw TraktError.notLoggedIn
            }
        }
        return t.accessToken
    }

    // MARK: requests

    private func headers(_ token: String?) -> [String: String] {
        var h = ["Content-Type": "application/json", "trakt-api-version": "2", "trakt-api-key": Secrets.traktClientID]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], auth: Bool = true) async throws -> T {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0, value: $1) } }
        var r = URLRequest(url: c.url!)
        var token: String?
        if auth { token = try await validToken() }
        headers(token).forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, h) = try await HTTP.data(r)
        guard (200..<300).contains(h.statusCode) else { throw HTTPError.status(h.statusCode, String(decoding: d, as: UTF8.self)) }
        return try JSONDecoder.lenient.decode(T.self, from: d)
    }

    @discardableResult
    func postRaw(_ path: String, body: Any, auth: Bool = true) async throws -> Data {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        var token: String?
        if auth { token = try await validToken() }
        headers(token).forEach { r.setValue($1, forHTTPHeaderField: $0) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, h) = try await HTTP.data(r)
        guard (200..<300).contains(h.statusCode) || h.statusCode == 409 else {
            throw HTTPError.status(h.statusCode, String(decoding: d, as: UTF8.self))
        }
        return d
    }

    func delete(_ path: String) async throws {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "DELETE"
        let token = try await validToken()
        headers(token).forEach { r.setValue($1, forHTTPHeaderField: $0) }
        _ = try await HTTP.data(r)
    }

    func post<T: Decodable>(_ path: String, body: Any, auth: Bool = true) async throws -> T {
        let d = try await postRaw(path, body: body, auth: auth)
        return try JSONDecoder.lenient.decode(T.self, from: d)
    }
}

enum TraktError: LocalizedError {
    case notLoggedIn, expired, denied(Int)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L("Not signed in to Trakt.")
        case .expired: return L("The code has expired. Please try again.")
        case .denied(let c): return L("Trakt refused the connection (%d).", c)
        }
    }
}
