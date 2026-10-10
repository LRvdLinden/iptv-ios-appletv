import Foundation

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

    func startDeviceLogin() async throws -> TraktDeviceCode {
        try await post("/oauth/device/code", body: ["client_id": Secrets.traktClientID], auth: false)
    }

    /// Pollt tot de gebruiker de code heeft bevestigd op trakt.tv/activate.
    func pollForToken(_ code: TraktDeviceCode) async throws -> TraktTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        var interval = UInt64(max(code.interval, 5))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            var req = URLRequest(url: base.appendingPathComponent("/oauth/device/token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code.device_code, "client_id": Secrets.traktClientID, "client_secret": Secrets.traktClientSecret])
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
            Task { _ = try? await self.postRaw("/oauth/revoke", body: ["token": t.accessToken,
                "client_id": Secrets.traktClientID, "client_secret": Secrets.traktClientSecret], auth: false) }
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

    private func validToken() async throws -> String {
        guard var t = tokens else { throw TraktError.notLoggedIn }
        if t.expiresAt.timeIntervalSinceNow < 24 * 3600 {
            var req = URLRequest(url: base.appendingPathComponent("/oauth/token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "refresh_token": t.refreshToken, "client_id": Secrets.traktClientID,
                "client_secret": Secrets.traktClientSecret,
                "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"])
            let (d, r) = try await HTTP.data(req)
            if r.statusCode == 200, let n = try? JSONDecoder().decode(TokenResponse.self, from: d) {
                let user = t.username; t = n.tokens; t.username = user
                Keychain.setCodable(t, for: tokenKey)
            } else if r.statusCode == 401 {
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

    func post<T: Decodable>(_ path: String, body: Any, auth: Bool = true) async throws -> T {
        let d = try await postRaw(path, body: body, auth: auth)
        return try JSONDecoder.lenient.decode(T.self, from: d)
    }
}

enum TraktError: LocalizedError {
    case notLoggedIn, expired, denied(Int)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Niet ingelogd bij Trakt."
        case .expired: return "De koppelcode is verlopen. Probeer opnieuw."
        case .denied(let c): return "Trakt weigerde de koppeling (\(c))."
        }
    }
}
