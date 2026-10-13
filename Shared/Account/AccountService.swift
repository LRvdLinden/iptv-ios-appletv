import Foundation
import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

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
    enum RegisterResult { case ok, limit, failed }

    /// Gekoppeld apparaat (device-auth `list_devices`), zie "Gekoppelde apparaten" in docs/ACCOUNT.md.
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let platform: String
        let createdAt: Date?
        let lastSeenAt: Date?
        let current: Bool
        /// Ingelogd sinds (`signed_in_at`, build 51); nil bij oudere servers.
        var signedInAt: Date? = nil
    }

    /// Valt alleen terug op dit getal als de server geen `limit` meestuurt; de server is leidend (build 51: 15).
    static let fallbackDeviceLimit = 15

    /// Limiet bereikt bij `register_device`: dan toont de app "Too many devices".
    struct DeviceLimit: Equatable {
        let limit: Int
        let devices: [Device]
    }

    /// Gezet als `register_device` 403 `device_limit` gaf; leeg zodra het apparaat alsnog geregistreerd is of na uitloggen.
    @Published private(set) var deviceLimit: DeviceLimit?
    /// Dit apparaat is (sinds deze login) geregistreerd; lokaal onthouden.
    @Published private(set) var deviceRegistered: Bool
    /// Telt op zodra de app-sleutels van de server (device-auth `config`) veranderd zijn, zodat
    /// Trakt- en OpenSubtitles-schermen opnieuw tekenen (zie "App-sleutels van de server (build 41)").
    @Published private(set) var configRevision = 0

    private enum K {
        static let refresh = "account.refresh_token"
        static let access = "account.access_token"
        static let expires = "account.expires_at"
        static let email = "account.email"
        static let user = "account.user_id"
        static let registered = "account.device_registered"
        /// Vaste apparaat-ID: blijft bestaan na uitloggen (dus niet in `clearLocal`).
        static let deviceID = "account.device_id"
        /// User-id van het laatst ingelogde account: blijft bestaan na uitloggen (dus niet in `clearLocal`),
        /// zodat een **ander** account op dit apparaat herkend wordt.
        static let lastUser = "account.last_user_id"
    }

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Double = 0
    private var userID: String?
    private var refreshTask: Task<RefreshResult, Never>?
    private var tvTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var lastDeviceCheck: Date = .distantPast
    private var configTask: Task<Bool, Never>?
    private var lastConfigFetch: Date?

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
        deviceRegistered = Keychain.getLocalOnly(K.registered) == "1"
        // sessie van vóór build 43: dit account is het laatst ingelogde
        if let uid = userID, !uid.isEmpty, Keychain.getLocalOnly(K.lastUser) == nil {
            Keychain.setLocalOnly(uid, for: K.lastUser)
        }
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

    /// Uitloggen: eerst dit apparaat loskoppelen (best effort), dan de server op de hoogte brengen,
    /// en daarna altijd lokaal wissen.
    func signOut() async {
        stopTVLogin()
        isBusy = true; defer { isBusy = false }
        if accessToken != nil, let token = try? await validAccessToken() {
            _ = try? await post("/functions/v1/device-auth", ["action": "remove_device", "device_id": deviceID], bearer: token)
        }
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

    // MARK: - Gekoppelde apparaten (limiet van de server, build 51: 15)

    /// Vaste, alleen lokale apparaat-ID (UUID). Eén keer aangemaakt; blijft bestaan na uitloggen.
    let deviceID: String = {
        if let id = Keychain.getLocalOnly(K.deviceID), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        Keychain.setLocalOnly(id, for: K.deviceID)
        return id
    }()

    /// `iPhone`, `iPad`, `Apple TV` of `Mac`.
    static var platform: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// Naam van dit apparaat (iOS/tvOS: `UIDevice.current.name`, Mac: de computernaam).
    static var currentDeviceName: String {
        #if os(macOS)
        let n = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return n.isEmpty ? "Mac" : n
        #else
        let n = UIDevice.current.name
        return n.isEmpty ? platform : n
        #endif
    }

    /// App-versie voor `register_device` en `heartbeat` (build 62), bv. "1.0.0 (62)". Oudere servers negeren het veld.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Systeemversie (build 62), bv. "iOS 26.1", "iPadOS 26.1", "tvOS 26.0" of "macOS 26.0".
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        #if os(tvOS)
        let name = "tvOS"
        #elseif os(macOS)
        let name = "macOS"
        #else
        let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return "\(name) \(number)"
    }

    /// Dit apparaat registreren (na elke login, of voor sessies van vóór build 39).
    /// Bij 403 `device_limit` wordt `deviceLimit` gezet; de app toont dan "Too many devices".
    @discardableResult
    func registerDevice() async -> RegisterResult {
        guard Secrets.accountsConfigured, isSignedIn else { return .failed }
        do {
            let body: [String: Any] = ["action": "register_device", "device_id": deviceID,
                                       "name": Self.currentDeviceName, "platform": Self.platform,
                                       "app_version": Self.appVersion, "os_version": Self.osVersion]
            let r = try await authorized { token in
                try await self.post("/functions/v1/device-auth", body, bearer: token)
            }
            guard isSignedIn else { return .failed }
            if r.status == 403 || r.string("error") == "device_limit" {
                let limit = Int(r.number("limit") ?? Double(Self.fallbackDeviceLimit))
                let list = (r.json["devices"] as? [[String: Any]] ?? []).compactMap(Self.device)
                deviceLimit = DeviceLimit(limit: limit, devices: list)
                return .limit
            }
            guard r.status == 200, (r.json["ok"] as? Bool) == true else { return .failed }
            setRegistered(true)
            deviceLimit = nil
            lastDeviceCheck = Date()
            return .ok
        } catch {
            return .failed
        }
    }

    /// Bij het starten, bij terugkeer naar de voorgrond en elke 5 minuten: `heartbeat`
    /// (of `register_device` als dit apparaat nog niet geregistreerd is). `revoked` → lokaal uitloggen.
    func checkDevice(force: Bool = false) async {
        guard Secrets.accountsConfigured, isSignedIn, deviceLimit == nil else { return }
        if !force && Date().timeIntervalSince(lastDeviceCheck) < 20 { return }
        if let t = deviceTask { return await t.value }
        let t = Task { @MainActor in
            if self.deviceRegistered {
                await self.heartbeat()
            } else {
                _ = await self.registerDevice()
            }
        }
        deviceTask = t
        await t.value
        deviceTask = nil
        lastDeviceCheck = Date()
    }

    private func heartbeat() async {
        do {
            let r = try await authorized { token in
                try await self.post("/functions/v1/device-auth", ["action": "heartbeat", "device_id": self.deviceID,
                                                                         "app_version": Self.appVersion, "os_version": Self.osVersion], bearer: token)
            }
            if (r.json["revoked"] as? Bool) == true { revokedLocally() }
        } catch {
            // offline of tijdelijke fout: niets doen (de app blijft werken)
        }
    }

    /// Mededeling van de beheerder (device-auth `announcements`, build 62).
    struct Announcement: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        let createdAt: Date?
    }

    /// Mededelingen in de taal van de app (`nl`, anders `en`). nil bij een fout of een oudere server zonder deze actie.
    func fetchAnnouncements() async -> [Announcement]? {
        guard Secrets.accountsConfigured, isSignedIn else { return nil }
        let lang = Localizer.shared.language == "nl" ? "nl" : "en"
        do {
            let r = try await authorized { token in
                try await self.post("/functions/v1/device-auth", ["action": "announcements", "device_id": self.deviceID, "lang": lang], bearer: token)
            }
            guard r.status == 200, let items = r.json["items"] as? [[String: Any]] else { return nil }
            return items.compactMap { j in
                guard let id = (j["id"] as? String) ?? (j["id"] as? NSNumber)?.stringValue, !id.isEmpty else { return nil }
                let title = (j["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (j["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty || !body.isEmpty else { return nil }
                return Announcement(id: id, title: title, body: body, createdAt: Self.parseDate(j["created_at"]))
            }
        } catch {
            return nil
        }
    }

    /// Het apparaat is verwijderd (op een ander apparaat of de website): lokaal uitloggen, zonder logout-aanroep.
    private func revokedLocally() {
        stopTVLogin()
        clearLocal()
    }

    /// Alle gekoppelde apparaten, nieuwste gebruik eerst.
    func listDevices() async throws -> DeviceLimit {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "list_devices", "device_id": self.deviceID], bearer: token)
        }
        guard r.status == 200 else { throw AccountError.generic }
        let list = (r.json["devices"] as? [[String: Any]] ?? []).compactMap(Self.device)
        return DeviceLimit(limit: Int(r.number("limit") ?? Double(Self.fallbackDeviceLimit)), devices: list)
    }

    /// Een apparaat verwijderen (de sessie ervan wordt ingetrokken). Het eigen apparaat = uitloggen.
    func removeDevice(_ id: String) async throws {
        if id == deviceID {
            await signOut()
            return
        }
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "remove_device", "device_id": id], bearer: token)
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        if let l = deviceLimit {
            deviceLimit = DeviceLimit(limit: l.limit, devices: l.devices.filter { $0.id != id })
        }
    }

    /// Een apparaat (ook het eigen) een eigen naam geven, max. 60 tekens. Daarna overschrijft `register_device` die niet meer.
    func renameDevice(_ id: String, name: String) async throws {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !clean.isEmpty else { throw AccountError.generic }
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "rename_device", "device_id": id, "name": clean], bearer: token)
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        if let l = deviceLimit {
            deviceLimit = DeviceLimit(limit: l.limit, devices: l.devices.map {
                $0.id == id ? Device(id: $0.id, name: clean, platform: $0.platform, createdAt: $0.createdAt,
                                     lastSeenAt: $0.lastSeenAt, current: $0.current, signedInAt: $0.signedInAt) : $0
            })
        }
    }

    /// "Too many devices" → een apparaat verwijderd: opnieuw registreren. `.ok` = door naar "Wie kijkt er?".
    func removeDeviceAndRetry(_ id: String) async throws -> RegisterResult {
        try await removeDevice(id)
        guard isSignedIn else { return .failed }
        let r = await registerDevice()
        if r == .failed { throw AccountError.generic }
        return r
    }

    // MARK: - Tegelijk kijken (build 51), zie docs/ACCOUNT.md

    /// Een stream die nu loopt (`list_streams`, of de lijst bij 403 `stream_limit`).
    struct ActiveStream: Identifiable, Equatable {
        let deviceID: String
        let deviceName: String
        let platform: String
        /// Profiel-id (build 57); oudere regels hebben er geen
        var profileID: String? = nil
        let profileName: String
        let title: String
        let kind: String
        let startedAt: Date?
        let signedInAt: Date?
        var id: String { deviceID }
    }

    struct StreamLimit: Equatable {
        let limit: Int
        let streams: [ActiveStream]
    }

    /// Eén regel uit de kijkgeschiedenis (`watch_log`).
    struct WatchLogEntry: Identifiable, Equatable {
        let id = UUID()
        let deviceName: String
        let platform: String
        /// Profiel-id (build 57); oudere regels hebben er geen
        var profileID: String? = nil
        let profileName: String
        let title: String
        let kind: String
        let startedAt: Date
        let minutes: Int
    }

    enum StreamStartResult { case ok, limit(StreamLimit), offline }

    /// `stream_start`. Netwerkfouten en onverwachte antwoorden → `.offline` (afspelen gaat gewoon door).
    func streamStart(profileID: String?, profileName: String?, title: String, kind: String, contentID: String) async -> StreamStartResult {
        guard Secrets.accountsConfigured, isSignedIn else { return .offline }
        var body: [String: Any] = ["action": "stream_start", "device_id": deviceID, "title": title,
                                   "kind": kind, "content_id": contentID]
        if let profileID { body["profile_id"] = profileID }
        if let profileName { body["profile_name"] = profileName }
        do {
            let r = try await authorized { token in try await self.post("/functions/v1/device-auth", body, bearer: token) }
            if r.status == 403 || r.string("error") == "stream_limit" {
                let streams = (r.json["streams"] as? [[String: Any]] ?? []).compactMap(Self.stream)
                return .limit(StreamLimit(limit: Int(r.number("limit") ?? Double(streams.count)), streams: streams))
            }
            return r.status == 200 ? .ok : .offline
        } catch {
            return .offline
        }
    }

    /// `stream_ping`: `false` als de server zegt dat de stream niet meer telt (`stopped`); dan opnieuw `stream_start`.
    func streamPing(title: String?) async -> Bool {
        guard Secrets.accountsConfigured, isSignedIn else { return true }
        var body: [String: Any] = ["action": "stream_ping", "device_id": deviceID]
        if let title { body["title"] = title }
        do {
            let r = try await authorized { token in try await self.post("/functions/v1/device-auth", body, bearer: token) }
            return (r.json["stopped"] as? Bool) != true
        } catch {
            return true
        }
    }

    func streamStop() async {
        guard Secrets.accountsConfigured, isSignedIn else { return }
        _ = try? await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "stream_stop", "device_id": self.deviceID], bearer: token)
        }
    }

    /// Wie kijkt er nu (alleen voor het hoofdprofiel in Mijn Bingr → Account).
    func listStreams() async throws -> StreamLimit {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "list_streams"], bearer: token)
        }
        guard r.status == 200 else { throw AccountError.generic }
        let streams = (r.json["streams"] as? [[String: Any]] ?? []).compactMap(Self.stream)
        return StreamLimit(limit: Int(r.number("limit") ?? Double(streams.count)), streams: streams)
    }

    /// Kijkgeschiedenis van de laatste `days` dagen, nieuwste eerst.
    func watchLog(days: Int = 7) async throws -> [WatchLogEntry] {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "watch_log", "days": days], bearer: token)
        }
        guard r.status == 200 else { throw AccountError.generic }
        let rows = r.json["entries"] as? [[String: Any]] ?? []
        var out: [WatchLogEntry] = []
        for j in rows {
            guard let start = Self.parseDate(j["started_at"]) else { continue }
            var minutes = (j["minutes"] as? NSNumber)?.intValue
            if minutes == nil, let end = Self.parseDate(j["ended_at"]) { minutes = Int(end.timeIntervalSince(start) / 60) }
            let platform = j["platform"] as? String ?? ""
            out.append(WatchLogEntry(deviceName: (j["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? platform,
                                     platform: platform,
                                     profileID: Self.profileID(j),
                                     profileName: j["profile_name"] as? String ?? "",
                                     title: j["title"] as? String ?? "",
                                     kind: j["kind"] as? String ?? "",
                                     startedAt: start, minutes: max(0, minutes ?? 0)))
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// `profile_id` (build 57): string of ontbrekend/leeg bij oudere regels.
    private static func profileID(_ j: [String: Any]) -> String? {
        guard let v = j["profile_id"] as? String, !v.isEmpty else { return nil }
        return v
    }

    private static func stream(_ j: [String: Any]) -> ActiveStream? {
        guard let id = j["device_id"] as? String else { return nil }
        let platform = j["platform"] as? String ?? ""
        let name = (j["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (platform.isEmpty ? "?" : platform)
        return ActiveStream(deviceID: id, deviceName: name, platform: platform, profileID: profileID(j),
                            profileName: j["profile_name"] as? String ?? "", title: j["title"] as? String ?? "",
                            kind: j["kind"] as? String ?? "", startedAt: parseDate(j["started_at"]),
                            signedInAt: parseDate(j["signed_in_at"]))
    }

    private func setRegistered(_ v: Bool) {
        deviceRegistered = v
        Keychain.setLocalOnly(v ? "1" : nil, for: K.registered)
    }

    private static func device(_ j: [String: Any]) -> Device? {
        guard let id = j["device_id"] as? String else { return nil }
        let platform = j["platform"] as? String ?? ""
        let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (platform.isEmpty ? "?" : platform)
        return Device(id: id, name: name, platform: platform,
                      createdAt: parseDate(j["created_at"]), lastSeenAt: parseDate(j["last_seen_at"]),
                      current: (j["current"] as? Bool) ?? false, signedInAt: parseDate(j["signed_in_at"]))
    }

    /// Postgres-tijdstempel (`2026-10-12T10:15:30.123456+00:00`) → Date.
    nonisolated static func parseDate(_ v: Any?) -> Date? {
        guard var s = v as? String, !s.isEmpty else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        if !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") }
        if s.hasSuffix("+00") { s += ":00" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - App-sleutels van de server (build 41)

    /// device-auth `{"action":"config"}`: Trakt-, OpenSubtitles-, OMDb- en TMDB-sleutels ophalen en alleen
    /// lokaal bewaren (sleutelhanger zonder iCloud). Na elke login en bij het starten met een geldige sessie.
    /// `force: false` haalt alleen op als het nog niet gelukt is of langer dan een uur geleden is.
    /// Stil bij fouten; geeft `true` als de sleutels zijn opgehaald.
    @discardableResult
    func fetchConfig(force: Bool = true) async -> Bool {
        guard Secrets.accountsConfigured, isSignedIn else { return false }
        if !force, let last = lastConfigFetch, Date().timeIntervalSince(last) < 3600 { return true }
        if let t = configTask { return await t.value }
        let t = Task { @MainActor in await self.performFetchConfig() }
        configTask = t
        let ok = await t.value
        configTask = nil
        return ok
    }

    private func performFetchConfig() async -> Bool {
        do {
            let r = try await authorized { token in
                try await self.post("/functions/v1/device-auth", ["action": "config"], bearer: token)
            }
            guard r.status == 200, isSignedIn else { return false }
            var values: [Secrets.Key: String] = [:]
            for k in [Secrets.Key.traktClientID, .traktClientSecret, .openSubtitlesAPIKey, .omdbAPIKey, .tmdbAPIKey] {
                // ontbreekt het veld, dan de opgeslagen waarde laten staan; "" = geen sleutel
                if let v = r.json[k.rawValue] as? String { values[k] = v }
            }
            lastConfigFetch = Date()
            Secrets.reload()
            if Secrets.setServerValues(values) { configRevision += 1 }
            return true
        } catch {
            return false   // offline: de eerder opgehaalde sleutels blijven werken
        }
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

    // MARK: - Servers en afspeellijsten (build 43), versleuteld via device-auth

    /// device-auth `get_sources`: `{sources, mainSourceID, updatedAt}`. Een nieuw account geeft `sources: []`.
    func getSources() async throws -> (sources: [[String: Any]], mainSourceID: String?, updatedAt: String?) {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "get_sources"], bearer: token)
        }
        // een fout (bijv. decrypt_failed) mag nooit als "leeg" gelden: dan zou de app alles opnieuw uploaden
        guard r.status == 200, r.json["error"] == nil, let list = r.json["sources"] as? [Any] else { throw AccountError.generic }
        let sources = list.compactMap { $0 as? [String: Any] }
        let main = (r.json["mainSourceID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (sources, main, r.json["updatedAt"] as? String)
    }

    /// device-auth `put_sources`: altijd de **hele** lijst, inclusief tombstones. Geeft `updatedAt` terug.
    @discardableResult
    func putSources(_ sources: [[String: Any]], mainSourceID: String?) async throws -> String? {
        let body: [String: Any] = ["action": "put_sources", "sources": sources,
                                   "mainSourceID": mainSourceID.map { $0 as Any } ?? NSNull()]
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", body, bearer: token)
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        return r.json["updatedAt"] as? String
    }

    // MARK: - Alle overige gegevens (build 44), versleuteld per onderdeel via device-auth

    /// device-auth `get_state`: `{sections: {"<naam>": {data, updatedAt}}}`. `sections` nil = alles.
    func getState(sections: [String]? = nil) async throws -> [String: (data: Any, updatedAt: String?)] {
        var body: [String: Any] = ["action": "get_state"]
        if let sections { body["sections"] = sections }
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", body, bearer: token)
        }
        // een fout (bijv. decrypt_failed) mag nooit als "leeg" gelden: dan zou de app alles opnieuw uploaden
        guard r.status == 200, r.json["error"] == nil else { throw AccountError.generic }
        var out: [String: (data: Any, updatedAt: String?)] = [:]
        if let all = r.json["sections"] as? [String: Any] {
            for (name, v) in all {
                guard let row = v as? [String: Any], let data = row["data"], !(data is NSNull) else { continue }
                out[name] = (data, row["updatedAt"] as? String)
            }
        } else if r.json["sections"] == nil {
            throw AccountError.generic
        }
        return out
    }

    /// device-auth `put_state`: één onderdeel opslaan (max. 1 MB). Geeft `updatedAt` terug.
    @discardableResult
    func putState(section: String, data: Any) async throws -> String? {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "put_state", "section": section, "data": data], bearer: token)
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        return r.json["updatedAt"] as? String
    }

    /// device-auth `delete_state`: een onderdeel verwijderen (bijv. `profile.<id>` na een tombstone).
    func deleteState(section: String) async throws {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "delete_state", "section": section], bearer: token)
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
    }

    // MARK: - Profielfoto's (Storage-bucket `avatars`), zie "Profielfoto's delen (build 40)"

    /// User-id van de ingelogde gebruiker (map in de bucket `avatars`).
    var currentUserID: String? { isSignedIn ? userID : nil }

    /// `<user_id>/<profiel_id>.jpg`
    func photoPath(profileID: String) -> String? {
        guard let uid = currentUserID, !uid.isEmpty else { return nil }
        return "\(uid)/\(profileID).jpg"
    }

    /// Foto uploaden of vervangen (`x-upsert: true`). Geeft het pad in de bucket terug.
    @discardableResult
    func uploadPhoto(profileID: String, jpegData: Data) async throws -> String {
        guard let path = photoPath(profileID: profileID), let p = Self.safePhotoPath(path) else { throw AccountError.generic }
        let r = try await authorized { token in
            try await self.send("POST", "/storage/v1/object/avatars/\(p)", body: nil, bearer: token,
                                headers: ["Content-Type": "image/jpeg", "x-upsert": "true"], rawBody: jpegData)
        }
        guard (200..<300).contains(r.status) else { throw AccountError.generic }
        return path
    }

    /// Foto downloaden; nil bij een fout of als hij niet (meer) bestaat.
    func downloadPhoto(path: String) async -> Data? {
        guard let p = Self.safePhotoPath(path) else { return nil }
        do {
            let r = try await authorized { token in
                try await self.send("GET", "/storage/v1/object/authenticated/avatars/\(p)", body: nil, bearer: token,
                                    headers: ["Accept": "image/jpeg, */*"])
            }
            guard r.status == 200, !r.data.isEmpty else { return nil }
            return r.data
        } catch {
            return nil
        }
    }

    /// Foto verwijderen (fouten negeren).
    func deletePhoto(path: String) async {
        guard let p = Self.safePhotoPath(path) else { return }
        _ = try? await authorized { token in
            try await self.send("DELETE", "/storage/v1/object/avatars/\(p)", body: nil, bearer: token)
        }
    }

    /// Alleen een gewoon relatief pad (`map/bestand.jpg`), percent-gecodeerd per deel.
    private static func safePhotoPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let enc = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard enc.count == parts.count else { return nil }
        return enc.joined(separator: "/")
    }

    /// Vierkant (midden) uitsnijden, verkleinen tot max. `maxSide` pixels en als JPEG coderen.
    /// Alleen ImageIO/CoreGraphics, dus hetzelfde op iOS, tvOS en macOS.
    nonisolated static func squareJPEG(_ data: Data, maxSide: Int = 512, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // met de EXIF-oriëntatie toegepast
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let side = min(img.width, img.height)
        guard side > 0,
              let crop = img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2,
                                                 width: side, height: side)) else { return nil }
        let out = min(side, maxSide)
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let scaled = ctx.makeImage() else { return nil }
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return result as Data
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
        if !isSignedIn {
            // een ander account dan het vorige op dit apparaat: eerst de servers, profielen en gegevens
            // van het vorige account lokaal wissen; daarna importeren de syncs de stand van dit account
            if let uid, !uid.isEmpty {
                if let last = Keychain.getLocalOnly(K.lastUser), !last.isEmpty, last != uid {
                    CloudStore.shared.wipeAccountData()
                    // Trakt en OpenSubtitles van het vorige account ontkoppelen (anders scrobbelt dit account naar
                    // iemand anders' Trakt), en de sync-stand van de overige gegevens wissen; daarna importeert
                    // StateSync alles van dit account
                    StateSync.shared.accountSwitched()
                }
                Keychain.setLocalOnly(uid, for: K.lastUser)
            }
            isSignedIn = true
            // na elke login: de app-sleutels van de server op de achtergrond ophalen
            Task { @MainActor in await self.fetchConfig() }
        }
        return true
    }

    private func clearLocal() {
        accessToken = nil
        refreshToken = nil
        expiresAt = 0
        for k in [K.refresh, K.access, K.expires, K.email, K.user] { Keychain.setLocalOnly(nil, for: k) }
        email = nil
        userID = nil
        setRegistered(false)
        deviceLimit = nil
        isSignedIn = false
    }

    // MARK: - HTTP

    private func post(_ path: String, _ body: [String: Any], bearer: String? = nil) async throws -> Response {
        try await send("POST", path, body: body, bearer: bearer)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, bearer: String?,
                      headers: [String: String] = [:], rawBody: Data? = nil) async throws -> Response {
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
        if let rawBody { req.httpBody = rawBody }
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
