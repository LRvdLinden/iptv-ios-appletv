import Foundation
import Combine

/// Abonnementen (build 88): Gratis of Lifetime, zie docs/ACCOUNT.md (device-auth `entitlements`).
///
/// De server is leidend. Ophalen na het inloggen, bij terugkeer naar de voorgrond en met de heartbeat
/// (en overnemen als `entitlements` in het antwoord van `config` of `heartbeat` staat). Per account bewaard
/// in UserDefaults, zodat de app offline dezelfde stand toont. Nog nooit opgehaald en geen netwerk:
/// geen slotjes (Lifetime-gedrag), zodat een fout nooit iets op slot zet.
@MainActor
final class EntitlementsService: ObservableObject {
    static let shared = EntitlementsService()

    enum Plan: String, Codable { case free, lifetime }

    enum Feature: String, CaseIterable, Identifiable {
        case stats, nowWatching = "now_watching", trakt, multiServer = "multi_server", themes
        var id: String { rawValue }

        var title: String {
            switch self {
            case .stats: return L("Statistics")
            case .nowWatching: return L("Watching now and watch history")
            case .trakt: return "Trakt"
            case .multiServer: return L("More than one server")
            case .themes: return L("Accent colors")
            }
        }

        var icon: String {
            switch self {
            case .stats: return "chart.bar.xaxis"
            case .nowWatching: return "play.tv"
            case .trakt: return "checkmark.rectangle.stack.fill"
            case .multiServer: return "server.rack"
            case .themes: return "paintpalette"
            }
        }
    }

    struct Limits: Codable, Equatable {
        var streams: Int?
        var devices: Int?
        /// nil = onbeperkt
        var servers: Int?
    }

    struct Features: Codable, Equatable {
        var stats = true
        var nowWatching = true
        var trakt = true
        var multiServer = true
        var themes = true
    }

    struct Upgrade: Codable, Equatable {
        var url: String?
        /// Mag de app naar de website linken (knop, link of QR)? Standaard niet (App Store-regels 3.1.1/3.1.3).
        /// build 97: op Apple genegeerd (zie `externalPurchaseAllowed`).
        var link = false
        var price: String?
        var priceEN: String?
    }

    struct Entitlements: Codable, Equatable {
        var plan: Plan
        var limits: Limits
        var features: Features
        var upgrade: Upgrade
    }

    /// Standaardlimieten per abonnement (als de server een veld niet meestuurt; de vergelijking toont deze).
    static let freeLimits = Limits(streams: 1, devices: 8, servers: 1)
    static let lifetimeLimits = Limits(streams: 3, devices: 15, servers: nil)

    /// nil = (nog) onbekend: alles toegestaan.
    @Published private(set) var current: Entitlements?

    /// Accentkleuren toegestaan? Ook buiten de main actor leesbaar (`AccentChoice.current`), daarom in UserDefaults.
    nonisolated static let themesKey = "entitlements.themes"
    nonisolated static var themesAllowed: Bool {
        UserDefaults.standard.object(forKey: themesKey) as? Bool ?? true
    }

    private var task: Task<Void, Never>?
    private var lastFetch: Date = .distantPast
    private var bag = Set<AnyCancellable>()
    private var started = false

    private init() {}

    // MARK: Afgeleide waarden

    var plan: Plan? { current?.plan }
    var isFree: Bool { current?.plan == .free }
    var limits: Limits { current?.limits ?? Self.lifetimeLimits }
    var upgrade: Upgrade { current?.upgrade ?? Upgrade() }

    func allows(_ f: Feature) -> Bool {
        guard let c = current else { return true }
        switch f {
        case .stats: return c.features.stats
        case .nowWatching: return c.features.nowWatching
        case .trakt: return c.features.trakt
        case .multiServer: return c.features.multiServer
        case .themes: return c.features.themes
        }
    }

    /// Mag er nog een server bij (bij `count` servers)? Bestaande extra servers blijven bruikbaar.
    func canAddServer(count: Int) -> Bool {
        guard let c = current, !c.features.multiServer else { return true }
        guard let max = c.limits.servers else { return true }
        return count < max
    }

    /// build 97: Apple-apps tonen nooit een prijs, een externe aankooplink, een knop of een QR-code om te kopen,
    /// wat de server ook in `upgrade` (link, url, price) zet (App Store-regels 3.1.1/3.1.3). Het veld wordt nog
    /// gelezen (zelfde contract als Android), maar hier bewust niet gebruikt; daarom ook geen prijsopmaak meer.
    static let externalPurchaseAllowed = false

    // MARK: Ophalen

    /// Eén keer aanroepen bij het starten: volgt inloggen en uitloggen.
    func start() {
        guard !started else { return }
        started = true
        loadCache()
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                guard let self else { return }
                if signedIn {
                    self.loadCache()
                    Task { await self.refresh(force: true) }
                } else {
                    self.task?.cancel(); self.task = nil
                    self.lastFetch = .distantPast
                    self.set(nil, store: false)
                }
            }
            .store(in: &bag)
    }

    /// `force: false` haalt hooguit eens per 10 minuten op.
    func refresh(force: Bool = false) async {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        if !force && Date().timeIntervalSince(lastFetch) < 600 { return }
        if let t = task { return await t.value }
        let t = Task { @MainActor in
            if let j = await AccountService.shared.fetchEntitlements() {
                self.apply(j)
            }
        }
        task = t
        await t.value
        task = nil
    }

    /// build 97: geforceerd ophalen, behalve als er de laatste `seconds` al een abonnement binnenkwam
    /// (bijv. met de heartbeat).
    func refreshUnlessRecent(_ seconds: TimeInterval) async {
        if Date().timeIntervalSince(lastFetch) < seconds { return }
        await refresh(force: true)
    }

    /// `entitlements` uit een antwoord (`entitlements`, `config` of `heartbeat`) overnemen.
    func apply(_ j: [String: Any]) {
        guard let e = Self.parse(j) else { return }
        lastFetch = Date()
        set(e, store: true)
    }

    /// De server weigerde een functie (403 `feature_locked`). build 97: één 403 verandert het abonnement niet en
    /// wordt niet bewaard: alleen die functie tijdelijk (in het geheugen) op slot, en opnieuw ophalen. Alleen een
    /// geslaagd `entitlements`-antwoord (`apply`) mag het abonnement veranderen.
    func serverLocked(_ feature: String?) {
        if var e = current {
            switch feature {
            case "stats": e.features.stats = false
            case "now_watching", "watch_log", "list_streams": e.features.nowWatching = false
            case "trakt": e.features.trakt = false
            case "multi_server", "servers": e.features.multiServer = false
            case "themes": e.features.themes = false
            default: break
            }
            set(e, store: false)
        }
        Task { await refresh(force: true) }
    }

    private func set(_ e: Entitlements?, store: Bool) {
        if current != e { current = e }
        let themes = e?.features.themes ?? true
        if Self.themesAllowed != themes { UserDefaults.standard.set(themes, forKey: Self.themesKey) }
        guard store, let e, let key = cacheKey, let data = try? JSONEncoder().encode(e) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private var cacheKey: String? {
        guard let id = AccountService.shared.accountID, !id.isEmpty else { return nil }
        return "entitlements.cache." + id
    }

    private func loadCache() {
        guard AccountService.shared.isSignedIn else { set(nil, store: false); return }
        guard let key = cacheKey, let data = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode(Entitlements.self, from: data) else { return }
        set(e, store: false)
    }

    // MARK: JSON

    /// Contract: `{plan, limits:{streams, devices, servers}, features:{stats, now_watching, trakt, multi_server, themes},
    /// upgrade:{url, link, price, price_en}}`, eventueel genest onder `entitlements`. Ontbrekende features volgen het plan.
    static func parse(_ raw: [String: Any]) -> Entitlements? {
        let j = (raw["entitlements"] as? [String: Any]) ?? raw
        guard let p = (j["plan"] as? String)?.lowercased() else { return nil }
        let plan: Plan = p == "free" ? .free : .lifetime
        let base = plan == .free ? freeLimits : lifetimeLimits
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }
        let l = j["limits"] as? [String: Any] ?? [:]
        var limits = base
        if let v = int(l["streams"]) { limits.streams = v }
        if let v = int(l["devices"]) { limits.devices = v }
        if l.keys.contains("servers") { limits.servers = int(l["servers"]) }   // null = onbeperkt
        let f = j["features"] as? [String: Any] ?? [:]
        let dflt = plan == .lifetime
        func flag(_ k: String) -> Bool { (f[k] as? Bool) ?? (f[k] as? NSNumber)?.boolValue ?? dflt }
        let features = Features(stats: flag("stats"), nowWatching: flag("now_watching"), trakt: flag("trakt"),
                                multiServer: flag("multi_server"), themes: flag("themes"))
        let u = j["upgrade"] as? [String: Any] ?? [:]
        let upgrade = Upgrade(url: u["url"] as? String, link: (u["link"] as? Bool) ?? false,
                              price: u["price"] as? String, priceEN: u["price_en"] as? String)
        return Entitlements(plan: plan, limits: limits, features: features, upgrade: upgrade)
    }
}

/// 403 `feature_locked` van de server (bijv. statistieken of "Nu aan het kijken" op een Gratis-account).
struct FeatureLockedError: LocalizedError {
    let feature: String?
    var errorDescription: String? { L("This is a Lifetime feature") }
}
