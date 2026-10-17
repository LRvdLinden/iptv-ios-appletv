import Foundation
import SwiftUI
import Combine
#if !os(tvOS)
import UserNotifications
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Systeem-pushmeldingen (APNs) voor iPhone, iPad en Mac, zie docs/PUSH.md.
///
/// - Toestemming pas na het inloggen (en het kiezen van een profiel) vragen, met een korte uitleg (`PushPromptView`),
///   of via de schakelaar "Push notifications" in de instellingen.
/// - Aanmelden bij de functie `push` (`register`) met het APNs-devicetoken; opnieuw bij een nieuwe token, een andere
///   app-taal, een nieuwe build, een ander account of een andere APNs-omgeving. Afmelden (`unregister`) als de
///   gebruiker push uitzet of de toestemming in het systeem intrekt; bij uitloggen doet `AccountService.signOut` dat.
/// - Is push voor dit account aangemeld én toegestaan, dan plant de app geen lokale herinneringen meer (die stuurt de
///   server); anders blijft het lokale gedrag (`ReminderCenter`).
/// - Tikken op een melding: `data.deeplink` (`bingr://changelog`, `bingr://live`) en `data.url`. Dedup op `data.msg_id`.
///
/// Apple TV toont geen meldingen: daar registreert de app niets en doet deze klasse niets.
@MainActor
final class PushService: NSObject, ObservableObject {
    static let shared = PushService()

    /// Toestemming in de systeeminstellingen.
    enum SystemStatus: Equatable { case unknown, notDetermined, denied, allowed }

    /// Iets om in de app te openen na een tik op een melding (wacht tot de app in het hoofdscherm is).
    enum Route: Equatable {
        /// Herinnering: zender openen, met dezelfde profielcontrole als de banner (`ReminderCenter.canWatch`).
        case reminder(channelID: String, profileID: UUID?, playlistID: UUID?)
        /// Build 120: film of serie uit een link (e-mail van Bingr, `bingr://title`): detailpagina of zoekscherm.
        case title(TitleLink)
    }

    @Published private(set) var status: SystemStatus = .unknown
    /// Uitleg-venster na het inloggen (eenmalig, alleen als het systeem nog niets gevraagd heeft).
    @Published var showPrompt = false
    /// Na een tik op een melding: wordt door `RootView` afgehandeld zodra de app in het hoofdscherm is.
    @Published var pendingRoute: Route?
    /// Wijzigt de schakelaar in de instellingen (zelfde waarde als `isOn`).
    @Published private(set) var revision = 0

    /// Push werkt op dit platform (iPhone, iPad, Mac; niet Apple TV).
    static var isSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    private enum K {
        /// Keuze van de gebruiker (schakelaar / uitleg-venster). Ontbreekt = nog niet gekozen: dan volgt het de systeemstatus.
        static let enabled = "push.enabled"
        /// Het uitleg-venster is al eens getoond.
        static let prompted = "push.prompted"
        /// APNs-devicetoken (hex) van dit apparaat.
        static let token = "push.token"
        /// Wat de server het laatst aannam: account|token|platform|taal|build|sandbox.
        static let registration = "push.registration"
        /// Account waarvoor dit apparaat bij `push` aangemeld is.
        static let registeredUser = "push.registered_user"
        /// Herinneringen komen nu via push (dan geen lokale meldingen plannen).
        static let reminderMode = "push.reminder_mode"
        /// Al getoonde / al afgehandelde msg_id's (dedup), elk hooguit 200.
        static let presented = "push.presented"
        static let handled = "push.handled"
        /// Laatst bekende systeemstatus, voor de start (de echte status komt asynchroon).
        static let lastAllowed = "push.last_allowed"
    }

    private let defaults = UserDefaults.standard
    private var started = false
    private var bag = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var resyncPending = false
    private var forcePending = false

    private override init() { super.init() }

    // MARK: - Stand

    /// Keuze van de gebruiker; zonder keuze: aan als het systeem Bingr al meldingen toestaat.
    private var wantsPush: Bool {
        if defaults.object(forKey: K.enabled) != nil { return defaults.bool(forKey: K.enabled) }
        return status == .allowed
    }

    /// Stand van de schakelaar "Push notifications".
    var isOn: Bool { wantsPush && status == .allowed }

    /// Herinneringen komen via de server (push voor dit account aangemeld en toegestaan): geen lokale meldingen plannen.
    var handlesReminders: Bool {
        guard Self.isSupported else { return false }
        return defaults.bool(forKey: K.reminderMode)
    }

    private var token: String? {
        get { defaults.string(forKey: K.token) }
        set { defaults.set(newValue, forKey: K.token) }
    }

    // MARK: - Starten

    /// Bij het starten van de app (app-delegate). Zet de delegate van het meldingencentrum, zodat ook een tik op een
    /// melding die de app start aankomt.
    func start() {
        guard Self.isSupported, !started else { return }
        started = true
        #if !os(tvOS)
        UNUserNotificationCenter.current().delegate = self
        // oude in-app mededelingen (build 62) zijn vervallen
        defaults.removeObject(forKey: "announcements.seen")
        if defaults.bool(forKey: K.lastAllowed) { status = .allowed }

        // inloggen → aanmelden; uitloggen (ook ingetrokken of geblokkeerd) → lokaal vergeten
        // (de server ruimt het apparaat op bij `remove_device`; `signOut` meldt zich ook expliciet af)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                guard let self else { return }
                if signedIn {
                    self.sync(force: true)
                } else {
                    self.forgetRegistration()
                    self.pendingRoute = nil
                    self.showPrompt = false
                    self.applyReminderMode()
                }
            }
            .store(in: &bag)
        // andere app-taal → opnieuw aanmelden (meldingen in de nieuwe taal)
        Localizer.shared.$language
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)

        Task { @MainActor in
            await self.refreshStatus()
            // Apple raadt aan bij elke start opnieuw te registreren: dan komt de (eventueel nieuwe) token binnen
            if self.wantsPush && self.status == .allowed { self.registerWithSystem() }
            self.sync()
            await self.removeDuplicateDelivered()
        }
        #endif
    }

    /// App weer actief: systeemstatus opnieuw lezen (kan in Instellingen gewijzigd zijn) en zo nodig bijwerken.
    func appBecameActive() {
        guard Self.isSupported, started else { return }
        Task { @MainActor in
            let before = self.status
            await self.refreshStatus()
            if self.status == .allowed && before != .allowed && self.wantsPush { self.registerWithSystem() }
            self.sync()
            await self.removeDuplicateDelivered()
        }
    }

    // MARK: - Toestemming en schakelaar

    /// Na het inloggen en het kiezen van een profiel: de uitleg tonen als het systeem nog niets gevraagd heeft
    /// en de gebruiker nog niet gekozen heeft. Niet meteen bij de eerste start (dan is er nog geen account).
    func offerPromptIfNeeded() {
        guard Self.isSupported, Secrets.accountsConfigured, AccountService.shared.isSignedIn,
              !defaults.bool(forKey: K.prompted), defaults.object(forKey: K.enabled) == nil else { return }
        Task { @MainActor in
            await self.refreshStatus()
            guard self.status == .notDetermined else {
                // al eerder gevraagd (bijv. door een download of een herinnering): niets tonen, de status volgen
                self.defaults.set(true, forKey: K.prompted)
                self.sync()
                return
            }
            // eerst het hoofdscherm laten verschijnen
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard AccountService.shared.isSignedIn, !self.defaults.bool(forKey: K.prompted) else { return }
            self.showPrompt = true
        }
    }

    /// Uitleg-venster: "Turn on notifications" (true) of "Not now" (false).
    func answerPrompt(_ allow: Bool) {
        defaults.set(true, forKey: K.prompted)
        showPrompt = false
        if allow {
            setEnabled(true)
        } else {
            defaults.set(false, forKey: K.enabled)
            revision += 1
        }
    }

    /// Schakelaar in de instellingen.
    func setEnabled(_ on: Bool) {
        guard Self.isSupported else { return }
        defaults.set(true, forKey: K.prompted)
        defaults.set(on, forKey: K.enabled)
        revision += 1
        #if !os(tvOS)
        guard on else {
            sync()   // afmelden bij de server, lokale herinneringen weer plannen
            return
        }
        Task { @MainActor in
            await self.refreshStatus()
            if self.status == .notDetermined {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                await self.refreshStatus()
                if !granted { self.defaults.set(false, forKey: K.enabled) }
            }
            if self.status == .allowed { self.registerWithSystem() }
            self.revision += 1
            self.sync(force: true)
        }
        #endif
    }

    /// De meldingeninstellingen van Bingr in het systeem openen (als het systeem meldingen weigert).
    func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        let id = Bundle.main.bundleIdentifier ?? "nl.lrvdlinden.bingr"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"),
           NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { _ = NSWorkspace.shared.open(url) }
        #endif
    }

    private func refreshStatus() async {
        #if !os(tvOS)
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let new: SystemStatus
        switch s.authorizationStatus {
        case .notDetermined: new = .notDetermined
        case .denied: new = .denied
        case .authorized, .provisional: new = .allowed
        default: new = .allowed   // iOS: .ephemeral (App Clips)
        }
        if new != status { status = new; revision += 1 }
        defaults.set(new == .allowed, forKey: K.lastAllowed)
        #endif
    }

    private func registerWithSystem() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    // MARK: - Devicetoken (app-delegate)

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        if hex != token { token = hex }
        sync()
    }

    func didFailToRegister(_ error: Error) {
        // bijv. geen push-capability in een ontwikkelbuild of geen netwerk: stil, het lokale gedrag blijft
        applyReminderMode()
    }

    // MARK: - Aanmelden bij de server

    /// Platform voor `push`: `ios`, `ipados` of `macos`.
    private static var platform: String { AccountService.entitlementsPlatform }

    private static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    private static var appBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// APNs-omgeving: development (sandbox) voor debug-builds en alles wat met een ontwikkelprofiel ondertekend is;
    /// production voor TestFlight en de App Store.
    static let sandbox: Bool = {
        #if DEBUG
        return true
        #else
        return ProvisioningProfile.apsEnvironment == "development"
        #endif
    }()

    /// Bijwerken: aanmelden als het moet (nieuwe token, taal, build, account, omgeving), afmelden als push uit staat
    /// of niet meer toegestaan is. Daarna de herinneringen op het juiste spoor zetten (push of lokaal).
    func sync(force: Bool = false) {
        guard Self.isSupported, started else { return }
        if force { forcePending = true }
        guard syncTask == nil else { resyncPending = true; return }
        syncTask = Task { @MainActor in
            repeat {
                self.resyncPending = false
                let f = self.forcePending
                self.forcePending = false
                await self.performSync(force: f)
            } while self.resyncPending
            self.syncTask = nil
        }
    }

    private func performSync(force: Bool) async {
        await refreshStatus()
        let account = AccountService.shared
        guard Secrets.accountsConfigured, account.isSignedIn, let uid = account.currentUserID, !uid.isEmpty else {
            forgetRegistration()
            applyReminderMode()
            return
        }
        // een ander account dan waarvoor dit apparaat aangemeld was: dat geldt niet meer
        if let reg = defaults.string(forKey: K.registeredUser), reg != uid { forgetRegistration() }

        if wantsPush && status == .allowed {
            guard let token else {
                registerWithSystem()   // de token komt via de app-delegate, die roept sync() opnieuw aan
                applyReminderMode()
                return
            }
            let lang = Localizer.shared.language
            let signature = [uid, token, Self.platform, lang, String(Self.appBuild), Self.sandbox ? "sandbox" : "production"]
                .joined(separator: "|")
            if force || defaults.string(forKey: K.registration) != signature {
                let ok = await account.pushRegister(token: token, platform: Self.platform, lang: lang,
                                                    appVersion: Self.appVersion, appBuild: Self.appBuild, sandbox: Self.sandbox)
                // intussen uitgelogd of van account gewisseld: niets onthouden
                if ok, account.currentUserID == uid {
                    defaults.set(signature, forKey: K.registration)
                    defaults.set(uid, forKey: K.registeredUser)
                }
            }
        } else if defaults.string(forKey: K.registeredUser) != nil {
            // uitgezet of toestemming ingetrokken: afmelden (lukt het niet, dan bij de volgende keer opnieuw)
            if await account.pushUnregister() { forgetRegistration() }
        }
        applyReminderMode()
    }

    private func forgetRegistration() {
        defaults.removeObject(forKey: K.registration)
        defaults.removeObject(forKey: K.registeredUser)
    }

    /// Herinneringen via push of lokaal; bij een overstap de lokale meldingen opruimen of opnieuw plannen.
    private func applyReminderMode() {
        let account = AccountService.shared
        let active = Self.isSupported && wantsPush && status == .allowed && account.isSignedIn
            && account.currentUserID != nil && defaults.string(forKey: K.registeredUser) == account.currentUserID
        guard active != defaults.bool(forKey: K.reminderMode) else { return }
        defaults.set(active, forKey: K.reminderMode)
        ReminderCenter.shared.pushModeChanged(active)
    }

    // MARK: - Dedup (data.msg_id)

    private func remember(_ id: String, in key: String) -> Bool {
        var list = defaults.stringArray(forKey: key) ?? []
        guard !list.contains(id) else { return false }
        list.append(id)
        defaults.set(Array(list.suffix(200)), forKey: key)
        return true
    }

    /// Dezelfde melding (zelfde msg_id) twee keer in het meldingencentrum: de extra exemplaren weghalen.
    private func removeDuplicateDelivered() async {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        var seen = Set<String>()
        var extra: [String] = []
        // nieuwste eerst: het nieuwste exemplaar blijft staan
        for n in delivered.sorted(by: { $0.date > $1.date }) {
            guard let id = Self.payload(n.request.content.userInfo).msgID else { continue }
            if !seen.insert(id).inserted { extra.append(n.request.identifier) }
        }
        if !extra.isEmpty { center.removeDeliveredNotifications(withIdentifiers: extra) }
        #endif
    }

    // MARK: - Payload en tikken

    struct Payload {
        var kind: String?
        var url: URL?
        var deeplink: URL?
        var msgID: String?
        /// Lokale herinnering (ReminderCenter): zender, server en profiel uit de userInfo
        var channelID: String?
        var playlistID: UUID?
        var profileID: UUID?
    }

    /// `data` uit de push (genest onder `data` of plat naast `aps`), of de userInfo van een lokale herinnering.
    nonisolated static func payload(_ info: [AnyHashable: Any]) -> Payload {
        var d: [String: Any] = [:]
        for (k, v) in info { if let k = k as? String { d[k] = v } }
        if let inner = info["data"] as? [String: Any] {
            d.merge(inner) { _, new in new }
        } else if let s = info["data"] as? String, let data = s.data(using: .utf8),
                  let inner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            d.merge(inner) { _, new in new }
        }
        func str(_ k: String) -> String? {
            if let s = d[k] as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
            if let n = d[k] as? NSNumber { return n.stringValue }
            return nil
        }
        var p = Payload()
        p.kind = str("kind")?.lowercased()
        if let u = str("url").flatMap(URL.init(string:)), u.scheme?.lowercased() == "https" { p.url = u }
        if let u = str("deeplink").flatMap(URL.init(string:)), u.scheme?.lowercased() == "bingr" { p.deeplink = u }
        p.msgID = str("msg_id")
        p.channelID = str("channelID")
        p.playlistID = str("playlistID").flatMap(UUID.init(uuidString:))
        p.profileID = str("profileID").flatMap(UUID.init(uuidString:))
        return p
    }

    /// Tik op een melding (push of lokale herinnering).
    func handleTap(_ p: Payload) {
        if let id = p.msgID, !remember(id, in: K.handled) { return }   // al afgehandeld
        // lokale herinnering (ReminderCenter.scheduleNotification)
        if p.kind == nil, p.deeplink == nil, let ch = p.channelID {
            pendingRoute = .reminder(channelID: ch, profileID: p.profileID, playlistID: p.playlistID)
            return
        }
        if let link = p.deeplink, handle(deeplink: link, fallback: p.url) { return }
        switch p.kind {
        case "admin":
            // link van het beheer, anders alleen de app openen
            if let u = p.url { open(u) }
        case "release":
            if let u = p.url { open(u) }
        default:
            if let u = p.url { open(u) }
        }
    }

    /// Build 120: een link die de app opent (`onOpenURL` / universele link `https://bingr.online/titel/…`, of
    /// `bingr://…`). Wordt net als een tik op een melding via `pendingRoute` uitgevoerd zodra de app in het hoofdscherm
    /// is (dus ook na inloggen en "Wie kijkt er?"). `true` als de app er iets mee doet.
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        // onOpenURL én onContinueUserActivity kunnen dezelfde link geven: maar één keer uitvoeren
        let now = Date()
        if url == lastOpenedURL, now.timeIntervalSince(lastOpenedAt) < 3 { return true }
        lastOpenedURL = url
        lastOpenedAt = now
        if let link = TitleLink.parse(url) {
            pendingRoute = .title(link)
            return true
        }
        if url.scheme?.lowercased() == "bingr" { return handle(deeplink: url, fallback: nil) }
        return false
    }
    private var lastOpenedURL: URL?
    private var lastOpenedAt = Date.distantPast

    /// `bingr://changelog?p=<platform>&b=<build>`, `bingr://live?channel=<id>&profile=<profiel-id>` en (build 120)
    /// `bingr://title?type=movie|tv&id=<tmdb-id>&q=<titel>&y=<jaar>`.
    private func handle(deeplink: URL, fallback: URL?) -> Bool {
        guard let c = URLComponents(url: deeplink, resolvingAgainstBaseURL: false) else { return false }
        func q(_ name: String) -> String? {
            c.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // bingr://changelog?… (host) of bingr:changelog?… (pad)
        let target = (c.host?.isEmpty == false ? c.host! : c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch target {
        case "changelog":
            // de app heeft geen eigen changelogscherm: de changelog van precies die build op bingr.online
            if let u = Self.changelogURL(platform: q("p"), build: q("b")) ?? fallback { open(u) }
            return true
        case "title", "titel":
            guard let link = TitleLink.parse(deeplink) else { return false }
            pendingRoute = .title(link)
            return true
        case "live":
            guard let ch = q("channel"), !ch.isEmpty else { return false }
            let profile = q("profile").flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
            pendingRoute = .reminder(channelID: ch, profileID: profile, playlistID: nil)
            return true
        default:
            return false
        }
    }

    /// `https://bingr.online/changelog/?p=<platform>#build-<build>` (platform/build gecontroleerd).
    static func changelogURL(platform: String?, build: String?) -> URL? {
        let allowed = CharacterSet.alphanumerics
        let p = (platform ?? "").lowercased()
        let b = build ?? ""
        guard !b.isEmpty, b.allSatisfy(\.isNumber) else { return nil }
        var s = "https://bingr.online/changelog/"
        if !p.isEmpty, p.unicodeScalars.allSatisfy({ allowed.contains($0) }) { s += "?p=\(p)" }
        return URL(string: s + "#build-\(b)")
    }

    private func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        _ = NSWorkspace.shared.open(url)
        #endif
    }

    /// Voorgrond: pushmeldingen ook als banner tonen, maar elke msg_id maar één keer. Lokale meldingen (herinneringen,
    /// downloads) blijven zoals ze waren: in de app geen systeembanner (de app toont zelf de herinneringsbanner).
    fileprivate func presentationAllowed(msgID: String?, isPush: Bool) -> Bool {
        guard isPush else { return false }
        guard let id = msgID else { return true }
        return remember(id, in: K.presented)
    }
}

#if !os(tvOS)
extension PushService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isPush = notification.request.trigger is UNPushNotificationTrigger
        let msgID = Self.payload(notification.request.content.userInfo).msgID
        Task { @MainActor in
            let show = PushService.shared.presentationAllowed(msgID: msgID, isPush: isPush)
            completionHandler(show ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let p = Self.payload(response.notification.request.content.userInfo)
        Task { @MainActor in
            if isDefault { PushService.shared.handleTap(p) }
            completionHandler()
        }
    }
}
#endif

/// `aps-environment` uit het ingebedde provisioning-profiel (iOS: embedded.mobileprovision, Mac:
/// Contents/embedded.provisionprofile). nil als er geen profiel is (App Store) of als het niet te lezen is.
enum ProvisioningProfile {
    static let apsEnvironment: String? = {
        #if os(macOS)
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let key = "com.apple.developer.aps-environment"
        #else
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let key = "aps-environment"
        #endif
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let ent = dict["Entitlements"] as? [String: Any] else { return nil }
        return ent[key] as? String
    }()
}

#if !os(tvOS)
/// Uitleg vóór de systeemvraag (na het inloggen): waarom Bingr meldingen wil sturen.
struct PushPromptView: View {
    @ObservedObject private var push = PushService.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.red)
            Text(L("Stay up to date"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(L("Bingr can send you a notification when a new version is available, when a program you set a reminder for is about to start, and for important news about Bingr. You can change this anytime in Settings."))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button { push.answerPrompt(true) } label: {
                    Text(L("Turn on notifications"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .onAccentLabel()   // goud: donkere tekst op de knop
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .keyboardShortcut(.defaultAction)
                Button(L("Not now")) { push.answerPrompt(false) }
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: 320)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #elseif os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
#endif
