import Foundation

// Build 181 (1.1.0): Bingr Premium (docs/ACCOUNT.md, "Build 181: Bingr Premium"; gevallen in docs/build181_cases.json).
// Pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift). Gebruikt in
// Shared/Account/Entitlements.swift, Shared/Account/PremiumStore.swift (StoreKit 2) en
// Shared/UI/Components/PremiumPaywall.swift (Kies je plan, Instellingen > Abonnement).
//
// Apple-regels: geen webprijzen, geen codes, geen links of QR-codes naar het web. Prijzen alleen uit StoreKit.
// Alles staat uit tot de server het aanzet (`app_settings.premium`: `new_from_apple`, `existing_from`).

/// De vier plannen. `half` heet in StoreKit `halfyear`.
enum PremiumPlan181: String, Codable, CaseIterable, Equatable {
    case month, half, year, lifetime

    static let subscriptions: [PremiumPlan181] = [.month, .half, .year]

    var productID: String {
        switch self {
        case .month: return "nl.lrvdlinden.bingr.premium.month"
        case .half: return "nl.lrvdlinden.bingr.premium.halfyear"
        case .year: return "nl.lrvdlinden.bingr.premium.year"
        case .lifetime: return "nl.lrvdlinden.bingr.lifetime49"
        }
    }

    /// Maanden per termijn (0 = eenmalig).
    var months: Int {
        switch self {
        case .month: return 1
        case .half: return 6
        case .year: return 12
        case .lifetime: return 0
        }
    }

    var isSubscription: Bool { self != .lifetime }

    /// Alle product-id's die de Apple-app voor Premium laadt en naar `apple_verify` stuurt.
    static var productIDs: [String] { allCases.map(\.productID) }

    /// Product-id → plan; de oude Lifetime (`nl.lrvdlinden.bingr.lifetime`, build 167) is ook Lifetime.
    static func from(productID: String) -> PremiumPlan181? {
        if productID == "nl.lrvdlinden.bingr.lifetime" { return .lifetime }
        return allCases.first { $0.productID == productID }
    }

    /// Plan uit de server (`month`, `half`, `halfyear`, `year`, `lifetime`).
    static func parse(_ v: Any?) -> PremiumPlan181? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "month", "monthly": return .month
        case "half", "halfyear": return .half
        case "year", "yearly", "annual": return .year
        case "lifetime", "lifetime49": return .lifetime
        default: return nil
        }
    }
}

/// `entitlements.premium` (docs/ACCOUNT.md, Build 181 §4). Ontbreekt het blok (oudere server), dan nil: alles zoals
/// in build 180. `legacy_offer` en `prices` worden op Apple bewust niet gelezen (geen webprijzen of codes).
struct Premium181: Codable, Equatable {
    /// De groep Apple doet mee voor dit account; false = niets nieuws tonen
    var enabled: Bool
    var active: Bool
    /// legacy | admin | lifetime | stripe | apple (nil = nooit Premium gehad)
    var source: String?
    var plan: PremiumPlan181?
    /// lifetime | trialing | active | past_due | grace | canceled | expired | revoked
    var status: String?
    /// nil bij Lifetime
    var expiresAt: Date?
    var trialUntil: Date?
    var willRenew: Bool
    var required: Bool
    var trialEligible: Bool
    /// apple | stripe | nil
    var manage: String?
    var test: Bool

    init(enabled: Bool = true, active: Bool = false, source: String? = nil, plan: PremiumPlan181? = nil,
         status: String? = nil, expiresAt: Date? = nil, trialUntil: Date? = nil, willRenew: Bool = false,
         required: Bool = false, trialEligible: Bool = false, manage: String? = nil, test: Bool = false) {
        self.enabled = enabled; self.active = active; self.source = source; self.plan = plan; self.status = status
        self.expiresAt = expiresAt; self.trialUntil = trialUntil; self.willRenew = willRenew; self.required = required
        self.trialEligible = trialEligible; self.manage = manage; self.test = test
    }

    static func parse(_ v: Any?) -> Premium181? {
        guard let j = v as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            guard let s = (j[k] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
            return s
        }
        return Premium181(enabled: (j["enabled"] as? Bool) ?? false, active: (j["active"] as? Bool) ?? false,
                          source: str("source"), plan: PremiumPlan181.parse(j["plan"]), status: str("status"),
                          expiresAt: ISODate167.parse(j["expires_at"]), trialUntil: ISODate167.parse(j["trial_until"]),
                          willRenew: (j["will_renew"] as? Bool) ?? false, required: (j["required"] as? Bool) ?? false,
                          trialEligible: (j["trial_eligible"] as? Bool) ?? false, manage: str("manage"),
                          test: (j["test"] as? Bool) ?? false)
    }

    /// Lifetime (elke bron behalve een abonnement): nooit blokkeren, ook niet offline.
    var isLifetime: Bool {
        plan == .lifetime || ["legacy", "admin", "lifetime"].contains(source ?? "")
    }

    /// Een abonnement (Stripe of Apple)
    var isSubscription: Bool { !isLifetime && (source == "stripe" || source == "apple") }
}

/// Wat de paywall en Instellingen moeten laten zien (`premiumScreen`, gedeeld via docs/build181_cases.json `client`).
enum PremiumUI181 {
    enum Paywall: String, Equatable {
        /// Oud scherm (Activeer Lifetime, build 167): `access = activate` zonder `premium.enabled`
        case legacy
        /// Kies je plan, met de proef
        case trial
        /// Kies je plan, zonder proef
        case plans
    }

    struct Screen: Equatable {
        var blocked: Bool
        var paywall: Paywall?
        var trialBadge: Bool
        var manage: String?
    }

    /// `access` = `entitlements.access` (`full` of `activate`). `offline`: de stand komt uit de cache en de server
    /// heeft (nog) niet geantwoord. `storeEligible`: StoreKit `isEligibleForIntroOffer` (Apple; nil = niet gevraagd).
    static func screen(access: Access167, premium p: Premium181?, now: Date, offline: Bool,
                       storeEligible: Bool? = nil) -> Screen {
        let manage = p?.manage
        var blocked = access == .activate
        // offline: een bekend, opgezegd abonnement dat voorbij `expires_at` is, blokkeert tot de server antwoordt
        if !blocked, offline, let p, p.enabled, p.isSubscription, !p.willRenew, let e = p.expiresAt, e <= now {
            blocked = true
        }
        guard blocked else { return Screen(blocked: false, paywall: nil, trialBadge: false, manage: manage) }
        guard let p, p.enabled else { return Screen(blocked: true, paywall: .legacy, trialBadge: false, manage: manage) }
        let wall: Paywall = p.trialEligible ? .trial : .plans
        let badge = wall == .trial && (storeEligible ?? true)
        return Screen(blocked: true, paywall: wall, trialBadge: badge, manage: manage)
    }

    /// "3 dagen gratis" op een plan: alleen op een abonnement, als de server én StoreKit het zeggen.
    static func showTrial(plan: PremiumPlan181, serverEligible: Bool, storeEligible: Bool) -> Bool {
        plan.isSubscription && serverEligible && storeEligible
    }

    /// "33% voordeliger": de besparing van een termijn ten opzichte van maandelijks, uit de StoreKit-prijzen
    /// (afgerond op hele procenten). nil als er niets te besparen valt of een prijs ontbreekt.
    static func savings(monthPrice: Decimal?, price: Decimal?, months: Int) -> Int? {
        guard let m = monthPrice, let p = price, months > 1, m > 0 else { return nil }
        let full = NSDecimalNumber(decimal: m * Decimal(months)).doubleValue
        let pay = NSDecimalNumber(decimal: p).doubleValue
        guard full > 0, pay < full else { return nil }
        let pct = Int(((full - pay) / full * 100).rounded())
        return pct > 0 ? pct : nil
    }

    /// Standaardkeuze op de schakelaar: jaar (aanbevolen).
    static let defaultPlan: PremiumPlan181 = .year

    /// Volgorde van de schakelaar.
    static let switchOrder: [PremiumPlan181] = [.month, .half, .year]

    enum Status: Equatable {
        /// Lifetime (voor altijd)
        case lifetime
        /// In de proef tot <datum>
        case trial(PremiumPlan181, until: Date, renews: Bool)
        /// Verlengt op <datum>
        case renews(PremiumPlan181, on: Date)
        /// Opgezegd of betaling mislukt: loopt af op <datum>
        case ends(PremiumPlan181, on: Date)
        /// Verlopen of geen plan
        case none
    }

    /// De regel in Instellingen > Abonnement (alleen als `premium.enabled` of er een abonnement is).
    static func status(_ p: Premium181?, now: Date) -> Status {
        guard let p else { return .none }
        if p.isLifetime && p.active { return .lifetime }
        guard p.active, let plan = p.plan, plan.isSubscription else { return .none }
        if let t = p.trialUntil, now < t { return .trial(plan, until: t, renews: p.willRenew) }
        guard let e = p.expiresAt else { return .none }
        return p.willRenew ? .renews(plan, on: e) : .ends(plan, on: e)
    }

    /// Toont Instellingen > Abonnement de Premium-regels? Alleen als de groep meedoet of er een abonnement is.
    static func showStatus(_ p: Premium181?) -> Bool {
        guard let p else { return false }
        return p.enabled || p.isSubscription
    }
}

/// `billing` `apple_verify` voor Premium (abonnementen en Lifetime 49,99).
enum PremiumVerify181 {
    enum Outcome: Equatable {
        case premium(PremiumPlan181)
        case otherAccount
        case unavailable
        case failed
    }

    static func outcome(status: Int?, error: String?, plan: String?) -> Outcome {
        guard let status else { return .failed }
        if status == 409 || error == "owned_by_other_account" { return .otherAccount }
        if status == 400 && error == "unknown_action" { return .unavailable }
        // oudere functie zonder Premium-producten
        if status == 400 && error == "bad_transaction" { return .unavailable }
        if status == 200, let p = PremiumPlan181.parse(plan) { return .premium(p) }
        return .failed
    }

    /// `finish()` alleen als de server de transactie verwerkt heeft.
    static func shouldFinish(_ o: Outcome) -> Bool {
        switch o {
        case .premium, .otherAccount: return true
        case .unavailable, .failed: return false
        }
    }

    /// Hoort een transactie bij Premium (de vier nieuwe producten)?
    static func relevant(productID: String, revoked: Bool) -> Bool {
        !revoked && PremiumPlan181.productIDs.contains(productID)
    }
}

/// Publieke `billing config` → `premium` (zonder inloggen): doet de groep Apple nu mee?
struct PremiumPublic181: Codable, Equatable {
    var enabled: Bool
    var trialDays: Int

    static func parse(_ raw: [String: Any]) -> PremiumPublic181? {
        guard let p = raw["premium"] as? [String: Any] else { return nil }
        let on = ((p["enabled"] as? Bool) ?? false) && ((p["apple"] as? Bool) ?? true)
        let trial = (p["trial_days"] as? NSNumber)?.intValue ?? 0
        return PremiumPublic181(enabled: on, trialDays: on ? max(0, trial) : 0)
    }
}

