import Foundation
import SwiftUI

/// Bingr-account (Supabase), zie docs/ACCOUNT.md. Gewone REST-aanvragen, geen SDK.
///
/// De sessie staat **alleen op dit apparaat** (sleutelhanger zonder iCloud-sync en buiten de
/// iCloud-spiegel van `Keychain`): refresh tokens zijn eenmalig, dus delen tussen apparaten werkt niet.
@MainActor
final class AccountService: ObservableObject {
    static let shared = AccountService()

    @Published private(set) var isSignedIn: Bool
    @Published private(set) var email: String?
    @Published private(set) var isBusy = false

    // Tv-koppeling (Apple TV): code + QR, pollen tot de telefoon het goedkeurt
    @Published private(set) var tvCode: String?
    @Published private(set) var tvURL: String?
    @Published private(set) var tvError: String?

    enum RefreshResult { case ok, invalid, offline, noSession }
    enum SignUpResult { case signedIn, confirmEmail }

    private enum K {
        static let refresh = "account.refresh_token"
        static let access = "account.access_token"
        static let expires = "account.expires_at"
        static let email = "account.email"
        static let user = "account.user_id"
    }

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Double = 0
    private var userID: String?
    private var refreshTask: Task<RefreshResult, Never>?
    private var tvTask: Task<Void, Never>?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private init() {
        let rt = Keychain.getLocalOnly(K.refresh)
        isSignedIn = rt != nil
        refreshToken = rt
        accessToken = Keychain.getLocalOnly(K.access)
        expiresAt = Double(Keychain.getLocalOnly(K.expires) ?? "") ?? 0
        email = Keychain.getLocalOnly(K.email)
        userID = Keychain.getLocalOnly(K.user)
    }

    // MARK: - Fouten

    enum AccountError: LocalizedError {
        case offline
        case message(String)

        var errorDescription: String? {
            switch self {
            case .offline: return L("No internet connection.")
            case .message(let m): return m
            }
        }

        static var generic: AccountError { .message(L("Something went wrong. Please try again.")) }
    }

    struct Response {
        let status: Int
        let data: Data
        let json: [String: Any]
        func string(_ k: String) -> String? { json[k] as? String }
        func number(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
    }

    // MARK: - Inloggen en account

    static func isValidEmail(_ s: String) -> Bool {
        let e = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = e.firstIndex(of: "@"), e.filter({ $0 == "@" }).count == 1, !e.contains(" ") else { return false }
        let local = e[..<at], domain = e[e.index(after: at)...]
        guard !local.isEmpty, let dot = domain.lastIndex(of: ".") else { return false }
        return dot != domain.startIndex && domain.distance(from: dot, to: domain.endIndex) > 2
    }

    private func validate(email: String, password: String) throws {
        guard Self.isValidEmail(email) else { throw AccountError.message(L("Enter a valid email address.")) }
        guard password.count >= 6 else { throw AccountError.message(L("Password must be at least 6 characters.")) }
    }

    /// Account maken. Zonder sessie in het antwoord moet het e-mailadres eerst bevestigd worden.
    func signUp(email: String, password: String) async throws -> SignUpResult {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try validate(email: mail, password: password)
        isBusy = true; defer { isBusy = false }
        // `lang` = huidige app-taal: bepaalt de taal van de e-mails
        let body: [String: Any] = ["email": mail, "password": password,
                                   "data": ["lang": Localizer.shared.language]]
        let r = try await post("/auth/v1/signup", body)
        guard r.status == 200 || r.status == 201 else { throw Self.authError(r) }
        if storeSession(r.json, fallbackEmail: mail) { return .signedIn }
        return .confirmEmail
    }

    func signIn(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(mail) else { throw AccountError.message(L("Enter a valid email address.")) }
        guard !password.isEmpty else { throw AccountError.message(L("Incorrect email or password.")) }
        isBusy = true; defer { isBusy = false }
        let r = try await post("/auth/v1/token?grant_type=password", ["email": mail, "password": password])
        guard r.status == 200 else { throw Self.authError(r) }
        guard storeSession(r.json, fallbackEmail: mail) else { throw AccountError.generic }
    }

    /// Wachtwoord vergeten: altijd dezelfde melding (verklapt niet of het adres bestaat).
    func recover(email: String) async throws -> String {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(mail) else { throw AccountError.message(L("Enter a valid email address.")) }
        isBusy = true; defer { isBusy = false }
        let r = try await post("/auth/v1/recover?redirect_to=https%3A%2F%2Fbingr.online%2Freset", ["email": mail])
        if r.status == 429 || r.status >= 500 { throw AccountError.generic }
        return L("If an account exists, you'll receive an email to reset your password.")
    }

    /// Sessie vernieuwen. Alleen 400/401 betekent uitloggen; zonder internet blijft de sessie staan.
    @discardableResult
    func refresh() async -> RefreshResult {
        if let t = refreshTask { return await t.value }
        let t = Task { await self.performRefresh() }
        refreshTask = t
        let r = await t.value
        refreshTask = nil
        return r
    }

    private func performRefresh() async -> RefreshResult {
        guard Secrets.accountsConfigured, let token = refreshToken else { return .noSession }
        do {
            let r = try await post("/auth/v1/token?grant_type=refresh_token", ["refresh_token": token])
            if r.status == 200, storeSession(r.json, fallbackEmail: email) { return .ok }
            if r.status == 400 || r.status == 401 {
                // intussen al vernieuwd (bijv. door een andere aanvraag)? dan niet uitloggen
                if refreshToken != token { return .ok }
                clearLocal()
                return .invalid
            }
            return .offline
        } catch {
            return .offline
        }
    }

    /// Geldig access token (zo nodig eerst vernieuwen).
    private func validAccessToken() async throws -> String {
        if let a = accessToken, expiresAt > Date().timeIntervalSince1970 + 60 { return a }
        switch await refresh() {
        case .ok:
            if let a = accessToken { return a }
            throw AccountError.generic
        case .offline:
            throw AccountError.offline
        case .invalid, .noSession:
            throw AccountError.generic
        }
    }

    /// Uitloggen: de server op de hoogte brengen, en daarna altijd lokaal wissen.
    func signOut() async {
        stopTVLogin()
        isBusy = true; defer { isBusy = false }
        if let a = accessToken {
            _ = try? await post("/auth/v1/logout", [:], bearer: a)
        }
        clearLocal()
    }

    /// Account verwijderen (App Store-eis), daarna lokaal uitloggen.
    func deleteAccount() async throws {
        isBusy = true; defer { isBusy = false }
        let token = try await validAccessToken()
        let r = try await post("/functions/v1/device-auth", ["action": "delete_account"], bearer: token)
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        clearLocal()
    }

    /// Een tv koppelen met de code op het tv-scherm. Geeft de apparaatnaam terug.
    func approveTV(code: String) async throws -> String {
        let c = Self.normalizeCode(code)
        guard c.count >= 4 else { throw AccountError.message(L("That code is invalid or has expired.")) }
        isBusy = true; defer { isBusy = false }
        let token = try await validAccessToken()
        let r = try await post("/functions/v1/device-auth", ["action": "approve", "code": c], bearer: token)
        if r.status == 404 || r.string("error") == "invalid_code" {
            throw AccountError.message(L("That code is invalid or has expired."))
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        return r.string("device") ?? "TV"
    }

    // MARK: - Profielen per account (account_data via PostgREST)

    /// `profiles` uit `account_data` (nil = nog geen rij op de server).
    func fetchAccountProfiles() async throws -> [[String: Any]]? {
        let r = try await authorized { token in
            try await self.send("GET", "/rest/v1/account_data?select=profiles,updated_at", body: nil, bearer: token)
        }
        guard r.status == 200 else { throw AccountError.generic }
        guard let rows = (try? JSONSerialization.jsonObject(with: r.data)) as? [[String: Any]],
              let first = rows.first else { return nil }
        return first["profiles"] as? [[String: Any]] ?? []
    }

    /// De hele profielenlijst opslaan (upsert op user_id).
    func saveAccountProfiles(_ profiles: [[String: Any]]) async throws {
        let r = try await authorized { token in
            guard let uid = self.userID else { throw AccountError.generic }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let body: [String: Any] = ["user_id": uid, "profiles": profiles, "updated_at": f.string(from: Date())]
            return try await self.send("POST", "/rest/v1/account_data", body: body, bearer: token,
                                       headers: ["Prefer": "resolution=merge-duplicates,return=minimal"])
        }
        guard (200..<300).contains(r.status) else { throw AccountError.generic }
    }

    /// Aanvraag met een geldig access token; bij 401 één keer vernieuwen en opnieuw proberen.
    private func authorized(_ make: (String) async throws -> Response) async throws -> Response {
        let r = try await make(try await validAccessToken())
        guard r.status == 401 else { return r }
        expiresAt = 0
        return try await make(try await validAccessToken())
    }

    // MARK: - Tv: inloggen met je telefoon

    /// Start (of herstart) de tv-koppeling: code ophalen en pollen. Verloopt de code, dan komt er vanzelf een nieuwe.
    func startTVLogin() {
        tvTask?.cancel()
        tvTask = Task { [weak self] in await self?.runTVLogin() }
    }

    func stopTVLogin() {
        tvTask?.cancel()
        tvTask = nil
        tvCode = nil
        tvURL = nil
        tvError = nil
    }

    private func runTVLogin() async {
        while !Task.isCancelled && !isSignedIn {
            do {
                let start = try await post("/functions/v1/device-auth", ["action": "start", "device": Self.deviceName])
                guard start.status == 200, let code = start.string("code"), let secret = start.string("poll_secret") else {
                    throw AccountError.generic
                }
                tvCode = code
                tvURL = start.string("url") ?? "https://bingr.online/tv?code=\(code)"
                tvError = nil
                let interval = max(2, start.number("interval") ?? 3)
                let deadline = Date().addingTimeInterval(start.number("expires_in") ?? 600)

                poll: while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Date() > deadline { break poll }
                    let p: Response
                    do {
                        p = try await post("/functions/v1/device-auth", ["action": "poll", "code": code, "poll_secret": secret])
                    } catch AccountError.offline {
                        tvError = L("No internet connection.")
                        continue poll
                    }
                    switch p.string("status") {
                    case "approved":
                        guard let hash = p.string("token_hash") else { break poll }
                        let v = try await post("/auth/v1/verify", ["type": "magiclink", "token_hash": hash])
                        if v.status == 200, storeSession(v.json, fallbackEmail: p.string("email")) {
                            tvCode = nil
                            return
                        }
                        break poll   // mislukt: nieuwe code
                    case "expired":
                        break poll
                    default:
                        tvError = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                tvError = error.localizedDescription
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// `K7Q4MX` → `K7Q-4MX`
    static func displayCode(_ code: String) -> String {
        let c = normalizeCode(code)
        guard c.count == 6 else { return c }
        return String(c.prefix(3)) + "-" + String(c.suffix(3))
    }

    /// Hoofdletters, zonder `-` en spaties.
    static func normalizeCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static var deviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return "iPhone"
        #endif
    }

    /// `sub` (user id) uit een JWT, voor sessies zonder `user` in het antwoord.
    private static func subject(ofJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return j["sub"] as? String
    }

    // MARK: - Sessie (alleen op dit apparaat)

    @discardableResult
    private func storeSession(_ j: [String: Any], fallbackEmail: String?) -> Bool {
        guard let access = j["access_token"] as? String, !access.isEmpty,
              let refresh = j["refresh_token"] as? String, !refresh.isEmpty else { return false }
        let expiresIn = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let exp = Date().timeIntervalSince1970 + expiresIn
        let user = j["user"] as? [String: Any]
        let mail = (user?["email"] as? String) ?? fallbackEmail ?? email
        let uid = (user?["id"] as? String) ?? Self.subject(ofJWT: access) ?? userID
        accessToken = access
        refreshToken = refresh
        expiresAt = exp
        Keychain.setLocalOnly(refresh, for: K.refresh)
        Keychain.setLocalOnly(access, for: K.access)
        Keychain.setLocalOnly(String(exp), for: K.expires)
        Keychain.setLocalOnly(mail, for: K.email)
        Keychain.setLocalOnly(uid, for: K.user)
        userID = uid
        email = mail
        if !isSignedIn { isSignedIn = true }
        return true
    }

    private func clearLocal() {
        accessToken = nil
        refreshToken = nil
        expiresAt = 0
        for k in [K.refresh, K.access, K.expires, K.email, K.user] { Keychain.setLocalOnly(nil, for: k) }
        email = nil
        userID = nil
        isSignedIn = false
    }

    // MARK: - HTTP

    private func post(_ path: String, _ body: [String: Any], bearer: String? = nil) async throws -> Response {
        try await send("POST", path, body: body, bearer: bearer)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, bearer: String?,
                      headers: [String: String] = [:]) async throws -> Response {
        guard Secrets.accountsConfigured, let url = URL(string: Secrets.supabaseURL + path) else {
            throw AccountError.message(L("Accounts are not configured in this build."))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw AccountError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.offline
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: status, data: data, json: json)
    }

    /// Supabase-foutcodes → teksten uit het contract.
    private static func authError(_ r: Response) -> AccountError {
        let code = (r.string("error_code") ?? r.string("error") ?? "").lowercased()
        let msg = (r.string("msg") ?? r.string("message") ?? r.string("error_description") ?? "").lowercased()
        switch code {
        case "invalid_credentials", "invalid_grant":
            if msg.contains("confirm") { return .message(L("Confirm your email address first. Check your inbox.")) }
            return .message(L("Incorrect email or password."))
        case "email_not_confirmed":
            return .message(L("Confirm your email address first. Check your inbox."))
        case "user_already_exists", "email_exists":
            return .message(L("An account with this email already exists."))
        case "weak_password":
            return .message(L("Password must be at least 6 characters."))
        case "email_address_invalid", "validation_failed":
            return .message(L("Enter a valid email address."))
        default:
            if msg.contains("already registered") || msg.contains("already exists") {
                return .message(L("An account with this email already exists."))
            }
            if msg.contains("invalid login") { return .message(L("Incorrect email or password.")) }
            if msg.contains("not confirmed") { return .message(L("Confirm your email address first. Check your inbox.")) }
            if msg.contains("password") && msg.contains("6") { return .message(L("Password must be at least 6 characters.")) }
            return .generic
        }
    }
}
