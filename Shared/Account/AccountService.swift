import Foundation
import CryptoKit
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
    /// Build 82: het account is door de beheerder geblokkeerd (Supabase `user_banned`). Het inlogscherm toont
    /// dan een melding; wordt weer `false` als die gesloten is.
    @Published var blockedNotice = false

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
        /// Abonnement (build 88): `free` of `lifetime`; nil bij oudere servers
        var plan: String? = nil
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
        Screenshots.configure(c)   // App Store-screenshots: geen verbinding met de Bingr-server
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

    /// Melding bij een geblokkeerd account (build 82).
    nonisolated static var bannedMessage: String {
        L("Your account has been blocked. You received an email with the reason and until when. Questions? Go to support.bingr.online.")
    }

    /// Geblokkeerd account? Supabase Auth: `error_code` `user_banned` (400/403, oudere versies "User is banned"
    /// of "User Banned" in de tekst); eigen functies mogen `error: "user_banned"` of `banned: true` geven.
    private static func isBanned(_ r: Response) -> Bool {
        guard r.status >= 400 || (r.json["banned"] as? Bool) == true else { return false }
        if (r.json["banned"] as? Bool) == true { return true }
        let codes = [r.string("error_code"), r.string("error"), r.string("code"), r.string("reason")]
            .compactMap { $0?.lowercased() }
        if codes.contains(where: { $0 == "user_banned" || $0 == "banned" || $0 == "account_blocked" }) { return true }
        let msg = (r.string("msg") ?? r.string("message") ?? r.string("error_description") ?? "").lowercased()
        return msg.contains("banned")
    }

    /// Geblokkeerd tijdens een sessie: lokaal uitloggen (zonder logout-aanroep, die mag toch niet meer) en de melding tonen.
    private func blockedLocally() {
        stopTVLogin()
        clearLocal()
        blockedNotice = true
    }

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
        static var banned: AccountError { .message(AccountService.bannedMessage) }
    }

    /// build 97: serverklok − apparaatklok in seconden (uit de Date-header van het laatste antwoord); nil = onbekend
    private(set) var serverClockOffset: TimeInterval?
    /// build 97: "Wed, 15 Oct 2026 12:00:00 GMT"
    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

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
        guard password.count >= 8 else { throw AccountError.message(L("Password must be at least 8 characters.")) }   // build 141: server eist 8
    }

    /// Max. lengte van voor- en achternaam (user_metadata `first_name` / `last_name`).
    static let nameMax = 50

    /// Voor- of achternaam opschonen: stuurtekens en < > weg, witruimte samengevoegd en getrimd, max. 50 tekens
    /// (gelijk aan `personName()` in supabase/functions/_shared/mail.ts en de websites/Android).
    static func cleanName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != "<" && $0 != ">" }
        let joined = String(String.UnicodeScalarView(kept))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(String.UnicodeScalarView(joined.unicodeScalars.prefix(nameMax)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Account maken. Zonder sessie in het antwoord moet het e-mailadres eerst bevestigd worden.
    /// Voor- en achternaam zijn verplicht en gaan mee als user_metadata (aanhef "Hoi <voornaam>," in de e-mails).
    func signUp(email: String, password: String, firstName: String, lastName: String) async throws -> SignUpResult {
        let first = Self.cleanName(firstName), last = Self.cleanName(lastName)
        guard !first.isEmpty else { throw AccountError.message(L("Enter your first name.")) }
        guard !last.isEmpty else { throw AccountError.message(L("Enter your last name.")) }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try validate(email: mail, password: password)
        isBusy = true; defer { isBusy = false }
        // `lang` = huidige app-taal: bepaalt de taal van de e-mails; `first_name` / `last_name` voor de aanhef
        let body: [String: Any] = ["email": mail, "password": password,
                                   "data": ["lang": Localizer.shared.language, "first_name": first, "last_name": last]]
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
        // build 141: via de functie `login` (blokkade per account, docs/ACCOUNT.md "Inloggen via de functie login");
        // 200 = hetzelfde antwoord als /auth/v1/token. Functie (nog) niet uitgerold (404): direct naar /auth/v1/token.
        var r = try await post("/functions/v1/login", ["email": mail, "password": password,
                                                       "device_id": deviceID, "platform": Self.platform])
        if r.status == 404 {
            r = try await post("/auth/v1/token?grant_type=password", ["email": mail, "password": password])
        }
        guard r.status == 200 else { throw Self.authError(r) }
        guard storeSession(r.json, fallbackEmail: mail) else { throw AccountError.generic }
    }

    /// Wachtwoord vergeten: altijd dezelfde melding (verklapt niet of het adres bestaat).
    func recover(email: String) async throws -> String {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(mail) else { throw AccountError.message(L("Enter a valid email address.")) }
        isBusy = true; defer { isBusy = false }
        let r = try await post("/auth/v1/recover?redirect_to=https%3A%2F%2Fbingr.online%2Freset", ["email": mail])
        if r.status == 429 { throw AccountError.message(L("Too many attempts. Wait a few minutes and try again.")) }   // build 141
        if r.status >= 500 { throw AccountError.generic }
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
            // build 82: account geblokkeerd → uitloggen met melding
            if Self.isBanned(r) {
                blockedLocally()
                return .invalid
            }
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
            throw blockedNotice ? AccountError.banned : AccountError.generic
        }
    }

    /// Uitloggen: eerst dit apparaat loskoppelen (best effort), dan de server op de hoogte brengen,
    /// en daarna altijd lokaal wissen.
    func signOut() async {
        stopTVLogin()
        isBusy = true; defer { isBusy = false }
        if accessToken != nil, let token = try? await validAccessToken() {
            #if !os(tvOS)
            // pushmeldingen voor dit apparaat stoppen (remove_device ruimt push_devices ook op, dit is de expliciete afmelding)
            _ = try? await post("/functions/v1/push", ["action": "unregister", "device_id": deviceID], bearer: token)
            #endif
            _ = try? await post("/functions/v1/device-auth", ["action": "remove_device", "device_id": deviceID], bearer: token)
        }
        if let a = accessToken {
            // alleen de sessie van dit apparaat; zonder scope=local (standaard global) zou Supabase het account
            // op alle apparaten uitloggen
            _ = try? await post("/auth/v1/logout?scope=local", [:], bearer: a)
        }
        clearLocal()
    }

    /// Account verwijderen (App Store-eis), daarna lokaal uitloggen.
    /// H1: alleen met het huidige wachtwoord; de server controleert het (403 `wrong_password`, 429 `rate_limited`).
    func deleteAccount(password: String) async throws {
        guard !password.isEmpty else { throw AccountError.message(L("Incorrect password.")) }
        isBusy = true; defer { isBusy = false }
        let token = try await validAccessToken()
        let r = try await post("/functions/v1/device-auth", ["action": "delete_account", "password": password], bearer: token)
        if r.status == 403, r.string("error") == "wrong_password" { throw AccountError.message(L("Incorrect password.")) }
        if r.status == 429 { throw AccountError.message(L("Too many attempts. Wait a few minutes and try again.")) }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        clearLocal()
    }

    /// build 141: wat de server bij een tv-code weet (device-auth `code_info`), voor de bevestiging vóór het koppelen.
    struct TVCodeInfo {
        /// Wat het apparaat zelf opgaf ("Samsung TV", "Apple TV" …)
        var device: String
        /// Soort apparaat volgens de server ("Apple TV", "Android TV" …)
        var label: String
        /// Seconden sinds de code is aangemaakt (door de server berekend)
        var ageSeconds: Int
    }

    /// build 141: eerst opvragen bij welk apparaat de code hoort (nog niets goedkeuren).
    func tvCodeInfo(code: String) async throws -> TVCodeInfo {
        let c = Self.normalizeCode(code)
        guard c.count >= 4 else { throw AccountError.message(L("That code is invalid or has expired.")) }
        isBusy = true; defer { isBusy = false }
        let token = try await validAccessToken()
        let r = try await post("/functions/v1/device-auth", ["action": "code_info", "code": c], bearer: token)
        if r.status == 404 || r.string("error") == "invalid_code" {
            throw AccountError.message(L("That code is invalid or has expired."))
        }
        if r.status == 429 { throw AccountError.message(L("Too many attempts. Wait a few minutes and try again.")) }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        let device = String((r.string("device") ?? "TV").prefix(60))
        let age = (r.json["age_s"] as? NSNumber)?.intValue ?? 0
        return TVCodeInfo(device: device, label: String((r.string("label") ?? device).prefix(60)), ageSeconds: max(0, age))
    }

    /// Een tv koppelen met de code op het tv-scherm. Geeft de apparaatnaam terug.
    /// build 141: alleen na de bevestiging in `LinkTVView` (eerst `tvCodeInfo`).
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
                deviceLimit = DeviceLimit(limit: limit, devices: list, plan: r.string("plan"))
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
                                                                         "app_version": Self.appVersion, "os_version": Self.osVersion,
                                                                         "platform": Self.entitlementsPlatform], bearer: token)
            }
            // build 88: abonnement meegestuurd met de heartbeat → overnemen, anders apart ophalen (hooguit eens per 10 min)
            if let e = r.json["entitlements"] as? [String: Any] {
                EntitlementsService.shared.apply(e)
            } else if r.status == 200, (r.json["revoked"] as? Bool) != true {
                Task { @MainActor in await EntitlementsService.shared.refresh() }
            }
            if (r.json["revoked"] as? Bool) == true {
                // build 82: ingetrokken omdat het account geblokkeerd is → met melding
                if (r.json["banned"] as? Bool) == true || r.string("reason")?.lowercased() == "banned" { blockedLocally() }
                else { revokedLocally() }
            } else if r.status == 200 {
                // build 146: ongelezen supportantwoorden (badge), ook zonder push (Apple TV)
                Task { @MainActor in await SupportCenter.shared.refresh(quiet: true) }
            }
        } catch {
            // offline of tijdelijke fout: niets doen (de app blijft werken)
        }
    }

    // Mededelingen van de beheerder (device-auth `announcements`, build 62) zijn vervallen: berichten uit het beheer
    // komen voortaan als pushmelding (docs/PUSH.md). De app vraagt `announcements` niet meer op.

    // MARK: - Pushmeldingen (docs/PUSH.md, functie `push`)

    /// Dit apparaat aanmelden voor pushmeldingen (APNs). `true` als de server het aannam; een fout, offline of een
    /// server zonder `push` geeft `false` (stil, PushService probeert het later opnieuw).
    func pushRegister(token apnsToken: String, platform: String, lang: String, appVersion: String, appBuild: Int,
                      sandbox: Bool) async -> Bool {
        guard Secrets.accountsConfigured, isSignedIn else { return false }
        var body: [String: Any] = ["action": "register", "device_id": deviceID, "platform": platform, "channel": "apns",
                                   "token": apnsToken, "lang": lang, "app_version": appVersion, "app_build": appBuild]
        if sandbox { body["sandbox"] = true }
        do {
            let r = try await authorized { bearer in
                try await self.post("/functions/v1/push", body, bearer: bearer)
            }
            return (200..<300).contains(r.status) && (r.json["ok"] as? Bool) != false
        } catch {
            return false
        }
    }

    /// Dit apparaat afmelden voor pushmeldingen (push uitgezet of toestemming ingetrokken). `true` als het gelukt is.
    func pushUnregister() async -> Bool {
        guard Secrets.accountsConfigured, isSignedIn else { return false }
        do {
            let r = try await authorized { bearer in
                try await self.post("/functions/v1/push", ["action": "unregister", "device_id": self.deviceID], bearer: bearer)
            }
            return (200..<300).contains(r.status)
        } catch {
            return false
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
        /// Abonnement (build 88): `free` of `lifetime`; nil bij oudere servers
        var plan: String? = nil
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
    /// Build 68: bij een aflevering ook `series_id` en `series_title` (voor de statistieken), en altijd `tz`.
    func streamStart(profileID: String?, profileName: String?, title: String, kind: String, contentID: String,
                     seriesID: String? = nil, seriesTitle: String? = nil) async -> StreamStartResult {
        guard Secrets.accountsConfigured, isSignedIn else { return .offline }
        var body: [String: Any] = ["action": "stream_start", "device_id": deviceID, "title": title,
                                   "kind": kind, "content_id": contentID, "tz": TimeZone.current.identifier]
        if let profileID { body["profile_id"] = profileID }
        if let profileName { body["profile_name"] = profileName }
        if let seriesID, !seriesID.isEmpty { body["series_id"] = seriesID }
        if let seriesTitle, !seriesTitle.isEmpty { body["series_title"] = String(seriesTitle.prefix(200)) }
        do {
            let r = try await authorized { token in try await self.post("/functions/v1/device-auth", body, bearer: token) }
            if r.status == 403 || r.string("error") == "stream_limit" {
                let streams = (r.json["streams"] as? [[String: Any]] ?? []).compactMap(Self.stream)
                return .limit(StreamLimit(limit: Int(r.number("limit") ?? Double(streams.count)), streams: streams,
                                          plan: r.string("plan")))
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

    /// `stream_stop` bij het afsluiten van de app: zonder tokenvernieuwing (alleen met een nog geldig token) en hooguit
    /// `wait` seconden blokkerend, zodat de stream niet nog tot de TTL (90 s) blijft meetellen. Lukt het niet, dan
    /// ruimt de server hem na 90 s zonder ping alsnog op.
    func streamStopNow(wait: TimeInterval) {
        guard Secrets.accountsConfigured, isSignedIn, let token = accessToken, expiresAt > Date().timeIntervalSince1970 + 5,
              let url = URL(string: Secrets.supabaseURL + "/functions/v1/device-auth") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "stream_stop", "device_id": deviceID])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        if wait > 0 { _ = done.wait(timeout: .now() + wait) }
    }

    /// Wie kijkt er nu (alleen voor het hoofdprofiel in Mijn Bingr → Account).
    func listStreams() async throws -> StreamLimit {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "list_streams"], bearer: token)
        }
        try checkFeatureLocked(r)
        guard r.status == 200 else { throw AccountError.generic }
        let streams = (r.json["streams"] as? [[String: Any]] ?? []).compactMap(Self.stream)
        return StreamLimit(limit: Int(r.number("limit") ?? Double(streams.count)), streams: streams)
    }

    /// Kijkgeschiedenis van de laatste `days` dagen, nieuwste eerst.
    func watchLog(days: Int = 7) async throws -> [WatchLogEntry] {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "watch_log", "days": days], bearer: token)
        }
        try checkFeatureLocked(r)
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

    // MARK: - Kijkstatistieken (build 68), zie docs/ACCOUNT.md

    enum StatsPeriod: String, CaseIterable, Identifiable {
        case week, month, year
        var id: String { rawValue }
    }

    /// Antwoord van `watch_stats`. Ontbrekende velden worden 0 of leeg.
    struct WatchStats: Equatable {
        struct Bucket: Equatable {
            let key: String
            let minutes: Int
            let movieMinutes: Int
            let episodeMinutes: Int
            let liveMinutes: Int
        }
        struct TopItem: Identifiable, Equatable {
            let title: String
            let itemKey: String
            let minutes: Int
            let episodes: Int
            var id: String { itemKey.isEmpty ? title : itemKey }
        }
        struct ProfileShare: Identifiable, Equatable {
            let profileID: String?
            let profileName: String
            let minutes: Int
            var id: String { profileID ?? profileName }
        }
        var from: Date? = nil
        var to: Date? = nil
        var totalMinutes = 0
        var movieCount = 0, movieMinutes = 0
        var seriesShows = 0, seriesEpisodes = 0, seriesMinutes = 0
        var liveChannels = 0, liveMinutes = 0
        var buckets: [Bucket] = []
        var topSeries: [TopItem] = []
        var topMovies: [TopItem] = []
        var topChannels: [TopItem] = []
        var profiles: [ProfileShare] = []
        var since: Date? = nil

        var isEmpty: Bool {
            totalMinutes == 0 && movieMinutes == 0 && seriesMinutes == 0 && liveMinutes == 0
                && !buckets.contains { $0.minutes > 0 } && topSeries.isEmpty && topMovies.isEmpty && topChannels.isEmpty
        }
    }

    /// Fout als de server `watch_stats` nog niet kent (oude backend).
    struct StatsUnavailable: LocalizedError {
        var errorDescription: String? { L("Statistics are not available yet. Please try again later.") }
    }

    /// `watch_stats`: statistieken voor een week, maand of jaar (`offset` 0 = nu, -1 = vorige …).
    /// `profileID` nil = alle profielen (alleen het hoofdprofiel).
    func watchStats(period: StatsPeriod, offset: Int, profileID: String?) async throws -> WatchStats {
        var body: [String: Any] = ["action": "watch_stats", "period": period.rawValue, "offset": offset,
                                   "tz": TimeZone.current.identifier]
        if let profileID { body["profile_id"] = profileID }
        let r = try await authorized { token in try await self.post("/functions/v1/device-auth", body, bearer: token) }
        if r.string("error") == "unknown_action" || r.status == 404 { throw StatsUnavailable() }
        try checkFeatureLocked(r)
        guard r.status == 200 else { throw AccountError.generic }
        return Self.parseStats(r.json)
    }

    /// `delete_watch_stats`: statistieken wissen (`profileID` nil = alle profielen).
    func deleteWatchStats(profileID: String?) async throws {
        var body: [String: Any] = ["action": "delete_watch_stats"]
        if let profileID { body["profile_id"] = profileID }
        let r = try await authorized { token in try await self.post("/functions/v1/device-auth", body, bearer: token) }
        if r.string("error") == "unknown_action" || r.status == 404 { throw StatsUnavailable() }
        guard r.status == 200 else { throw AccountError.generic }
    }

    nonisolated static func parseStats(_ j: [String: Any]) -> WatchStats {
        func int(_ v: Any?) -> Int {
            if let n = v as? NSNumber { return max(0, Int(n.doubleValue.rounded())) }
            if let s = v as? String, let d = Double(s) { return max(0, Int(d.rounded())) }
            return 0
        }
        func obj(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
        func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }
        func str(_ v: Any?) -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        func top(_ v: Any?) -> [WatchStats.TopItem] {
            list(v).map { WatchStats.TopItem(title: str($0["title"]), itemKey: str($0["item_key"]),
                                             minutes: int($0["minutes"]), episodes: int($0["episodes"])) }
                .filter { !$0.title.isEmpty || !$0.itemKey.isEmpty }
        }
        var s = WatchStats()
        s.from = parseDay(j["from"])
        s.to = parseDay(j["to"])
        let totals = obj(j["totals"])
        let movies = obj(totals["movies"]), series = obj(totals["series"]), live = obj(totals["live"])
        s.movieCount = int(movies["count"]); s.movieMinutes = int(movies["minutes"])
        s.seriesShows = int(series["shows"]); s.seriesEpisodes = int(series["episodes"]); s.seriesMinutes = int(series["minutes"])
        s.liveChannels = int(live["channels"]); s.liveMinutes = int(live["minutes"])
        s.totalMinutes = totals["minutes"] != nil ? int(totals["minutes"]) : s.movieMinutes + s.seriesMinutes + s.liveMinutes
        s.buckets = list(j["by_bucket"]).compactMap { b in
            let key = str(b["key"])
            guard !key.isEmpty else { return nil }
            let mv = int(b["movie_minutes"]), ep = int(b["episode_minutes"]), lv = int(b["live_minutes"])
            return WatchStats.Bucket(key: key, minutes: b["minutes"] != nil ? int(b["minutes"]) : mv + ep + lv,
                                     movieMinutes: mv, episodeMinutes: ep, liveMinutes: lv)
        }
        let t = obj(j["top"])
        s.topSeries = top(t["series"]); s.topMovies = top(t["movies"]); s.topChannels = top(t["channels"])
        s.profiles = list(j["profiles"]).map {
            let id = str($0["profile_id"])
            return WatchStats.ProfileShare(profileID: id.isEmpty ? nil : id, profileName: str($0["profile_name"]),
                                           minutes: int($0["minutes"]))
        }
        s.since = parseDay(j["since"])
        return s
    }

    /// "2026-10-13" of een volledige tijdstempel → Date.
    nonisolated private static func parseDay(_ v: Any?) -> Date? {
        if let d = parseDate(v) { return d }
        guard let s = v as? String, s.utf8.count >= 10 else { return nil }
        return FastISO.day(s)   // build 149: geen DateFormatter per regel
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
        if let t = FastISO.date(s) { return t }   // build 149: snel, zonder opmaker
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        if !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") }
        if s.hasSuffix("+00") { s += ":00" }
        return FastISO.date(s) ?? ISO8601DateFormatter.plain.date(from: s)
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
                try await self.post("/functions/v1/device-auth", ["action": "config", "platform": Self.entitlementsPlatform,
                                                                  "device_id": self.deviceID], bearer: token)
            }
            guard r.status == 200, isSignedIn else { return false }
            var values: [Secrets.Key: String] = [:]
            for k in [Secrets.Key.traktClientID, .traktClientSecret, .openSubtitlesAPIKey, .omdbAPIKey, .tmdbAPIKey] {
                // ontbreekt het veld, dan de opgeslagen waarde laten staan; "" = geen sleutel
                if let v = r.json[k.rawValue] as? String { values[k] = v }
            }
            lastConfigFetch = Date()
            if let e = r.json["entitlements"] as? [String: Any] { EntitlementsService.shared.apply(e) }
            Secrets.reload()
            if Secrets.setServerValues(values) { configRevision += 1 }
            return true
        } catch {
            return false   // offline: de eerder opgehaalde sleutels blijven werken
        }
    }

    // MARK: - Abonnement (build 88)

    /// User-id van het ingelogde account (cache per account van het abonnement).
    var accountID: String? { userID }

    /// Platform voor `entitlements`: `ios`, `ipados`, `tvos` of `macos`.
    static var entitlementsPlatform: String {
        #if os(tvOS)
        return "tvos"
        #elseif os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// device-auth `entitlements`: het antwoord (of nil bij een fout, offline of een oudere server).
    func fetchEntitlements() async -> [String: Any]? {
        guard Secrets.accountsConfigured, isSignedIn else { return nil }
        do {
            let r = try await authorized { token in
                try await self.post("/functions/v1/device-auth", ["action": "entitlements", "platform": Self.entitlementsPlatform,
                                                                     "device_id": self.deviceID], bearer: token)
            }
            guard r.status == 200, isSignedIn else { return nil }
            return r.json
        } catch {
            return nil
        }
    }

    /// 403 `feature_locked` (Gratis-account): abonnement bijwerken en `FeatureLockedError` gooien.
    private func checkFeatureLocked(_ r: Response) throws {
        guard r.string("error") == "feature_locked" else { return }
        EntitlementsService.shared.serverLocked(r.string("feature"))
        throw FeatureLockedError(feature: r.string("feature"))
    }

    // MARK: - Profielen per account (build 146: versleuteld via device-auth `get_profiles`/`put_profiles`)

    /// De profielenlijst van het account, met tombstones (nil = nog geen rij op de server). Build 146: device-auth
    /// `get_profiles`; alleen als de functie die actie nog niet kent (400 `unknown_action`, terugrol) stil de oude
    /// REST-route op `account_data`.
    func fetchAccountProfiles() async throws -> [[String: Any]]? {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "get_profiles"], bearer: token)
        }
        if r.status == 400, r.string("error") == "unknown_action" { return try await legacyFetchProfiles() }
        guard r.status == 200, r.json["error"] == nil, let list = r.json["profiles"] as? [Any] else { throw AccountError.generic }
        let profiles = list.compactMap { $0 as? [String: Any] }
        if profiles.isEmpty, r.json["updatedAt"] == nil || r.json["updatedAt"] is NSNull { return nil }
        return profiles
    }

    /// De hele profielenlijst opslaan (build 146: device-auth `put_profiles`). Geeft de samengevoegde lijst van de server
    /// terug (die de app direct toepast); nil bij de oude REST-route.
    @discardableResult
    func saveAccountProfiles(_ profiles: [[String: Any]]) async throws -> [[String: Any]]? {
        let r = try await authorized { token in
            try await self.post("/functions/v1/device-auth", ["action": "put_profiles", "profiles": profiles], bearer: token)
        }
        if r.status == 400, r.string("error") == "unknown_action" {
            try await legacySaveProfiles(profiles)
            return nil
        }
        guard r.status == 200, (r.json["ok"] as? Bool) == true else { throw AccountError.generic }
        return (r.json["profiles"] as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    /// Tot build 145 (alleen nog als terugval): `account_data` rechtstreeks via PostgREST.
    private func legacyFetchProfiles() async throws -> [[String: Any]]? {
        let r = try await authorized { token in
            try await self.send("GET", "/rest/v1/account_data?select=profiles,updated_at", body: nil, bearer: token)
        }
        guard r.status == 200 else { throw AccountError.generic }
        guard let rows = (try? JSONSerialization.jsonObject(with: r.data)) as? [[String: Any]],
              let first = rows.first else { return nil }
        return first["profiles"] as? [[String: Any]] ?? []
    }

    private func legacySaveProfiles(_ profiles: [[String: Any]]) async throws {
        let r = try await authorized { token in
            guard let uid = self.userID else { throw AccountError.generic }
            let body: [String: Any] = ["user_id": uid, "profiles": profiles, "updated_at": FastISO.string(Date())]
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
        if Self.isBanned(r) { blockedLocally(); throw AccountError.banned }
        guard r.status == 401 else { return r }
        expiresAt = 0
        let again = try await make(try await validAccessToken())
        if Self.isBanned(again) { blockedLocally(); throw AccountError.banned }
        return again
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
                tvURL = start.string("url") ?? "https://bingr.online/koppelen?code=\(code)"
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
                    // build 82: geblokkeerd account (de koppeling of het inloggen geeft `user_banned`)
                    if p.string("status") == "banned" || Self.isBanned(p) {
                        tvBlocked()
                        try await Task.sleep(nanoseconds: 8_000_000_000)
                        break poll
                    }
                    switch p.string("status") {
                    case "approved":
                        guard let hash = p.string("token_hash") else { break poll }
                        let v = try await post("/auth/v1/verify", ["type": "magiclink", "token_hash": hash])
                        if v.status == 200, storeSession(v.json, fallbackEmail: p.string("email")) {
                            tvCode = nil
                            return
                        }
                        if Self.isBanned(v) {
                            tvBlocked()
                            try await Task.sleep(nanoseconds: 8_000_000_000)
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

    /// Apple TV: het account dat de code goedkeurde is geblokkeerd. Melding onder de code én als venster.
    private func tvBlocked() {
        tvError = Self.bannedMessage
        blockedNotice = true
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
        SupportCenter.shared.reset()   // build 146: geen tickets of badge van een vorig account
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
        // build 97: serverklok uit de Date-header onthouden (tegen een apparaatklok die voorloopt, zie StateSync)
        if let h = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"), let d = Self.httpDate.date(from: h) {
            serverClockOffset = d.timeIntervalSinceNow
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: status, data: data, json: json)
    }

    /// Supabase-foutcodes → teksten uit het contract.
    private static func authError(_ r: Response) -> AccountError {
        if isBanned(r) { return .banned }
        // build 141: te veel pogingen (functie login met retry_after in seconden, of de Auth-limiet van /auth/v1/token)
        if r.status == 429 {
            if let secs = (r.json["retry_after"] as? NSNumber)?.doubleValue, secs > 0 {
                return .message(L("Too many attempts. Try again in %d minutes.", max(1, Int((secs / 60).rounded(.up)))))
            }
            return .message(L("Too many attempts. Wait a few minutes and try again."))
        }
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
            return .message(L("Password must be at least 8 characters."))
        case "email_address_invalid", "validation_failed":
            return .message(L("Enter a valid email address."))
        default:
            if msg.contains("already registered") || msg.contains("already exists") {
                return .message(L("An account with this email already exists."))
            }
            if msg.contains("invalid login") { return .message(L("Incorrect email or password.")) }
            if msg.contains("not confirmed") { return .message(L("Confirm your email address first. Check your inbox.")) }
            if msg.contains("password") && (msg.contains("8") || msg.contains("weak")) { return .message(L("Password must be at least 8 characters.")) }
            return .generic
        }
    }
}

// MARK: - Build 146: support vanuit de app (functie `support`, acties `app_*`) en de netwerkcheck

extension AccountService {
    /// Eén aanroep van de functie `support` met de sessie van het account (`Authorization: Bearer`). Bij 401 één keer
    /// vernieuwen en opnieuw (`authorized`); `user_banned` → melding zoals bij "Geblokkeerd account".
    func supportCall(_ action: String, _ body: [String: Any] = [:]) async throws -> (status: Int, json: [String: Any]) {
        guard Secrets.accountsConfigured, isSignedIn else { throw AccountError.generic }
        var b = body
        b["action"] = action
        let r = try await authorized { token in
            try await self.post("/functions/v1/support", b, bearer: token)
        }
        return (r.status, r.json)
    }

    /// Netwerkcheck voor de diagnose: device-auth `ping` (zonder inloggen). `ms` = tijd tot het antwoord.
    func backendPing() async -> (ok: Bool, ms: Int) {
        let t0 = Date()
        do {
            let r = try await post("/functions/v1/device-auth", ["action": "ping"])
            return ((200..<300).contains(r.status), Int(Date().timeIntervalSince(t0) * 1000))
        } catch {
            return (false, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }
}
