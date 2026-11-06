import Foundation

// Build 167: Bingr wordt alleen Lifetime (docs/ACCOUNT.md, "Build 167: alleen Lifetime"). Pure logica (alleen
// Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift). Gebruikt in
// Shared/Account/Entitlements.swift, Shared/Account/LifetimeStore.swift (StoreKit 2) en
// Shared/UI/Components/LifetimeOnly.swift (Activeer Lifetime, aankondiging, Instellingen > Abonnement).
//
// Apple-regels: de Apple-apps tonen nooit een kortingscode, een prijs van het web, een link of een QR-code naar de
// betaalpagina. Alleen de koopknop van StoreKit (prijs uit `displayPrice`) en, achter de flag, de EU External
// Purchase Link (met het informatieblad van Apple).

/// `entitlements.access`: `full` (normaal gebruik) of `activate` (alleen het scherm Activeer Lifetime).
/// Ontbreekt het veld (oudere server) of is het onbekend, dan `full`.
enum Access167: String, Codable, Equatable {
    case full, activate

    static func parse(_ v: Any?) -> Access167 {
        (v as? String)?.lowercased() == "activate" ? .activate : .full
    }
}

/// ISO-tijden van de server (`2026-12-07T00:00:00+01:00`, ook met fracties of `Z`).
enum ISODate167 {
    static func parse(_ v: Any?) -> Date? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        if let d = b.date(from: s) { return d }
        // Postgres: "2026-12-07 00:00:00+01" (spatie, korte offset)
        var t = s.replacingOccurrences(of: " ", with: "T")
        if let r = t.range(of: #"[+-]\d{2}$"#, options: .regularExpression) {
            let off = String(t[r]) + ":00"
            t.replaceSubrange(r, with: off)
        }
        return a.date(from: t) ?? b.date(from: t)
    }
}

/// `entitlements.lifetime_only` (alleen aanwezig als de overgang aan staat). De code en `code_valid_until` worden
/// op Apple bewust niet gelezen of bewaard: korting buiten Apple om tonen mag hier niet.
struct LifetimeOnly167: Codable, Equatable {
    var enabled: Bool
    /// nu ≥ `announce_at` (de server rekent)
    var announced: Bool
    var cutoverAt: Date?
    /// Proefperiode na de overgang (nil = geen)
    var trialUntil: Date?

    init(enabled: Bool, announced: Bool, cutoverAt: Date?, trialUntil: Date? = nil) {
        self.enabled = enabled; self.announced = announced; self.cutoverAt = cutoverAt; self.trialUntil = trialUntil
    }

    static func parse(_ v: Any?) -> LifetimeOnly167? {
        guard let j = v as? [String: Any] else { return nil }
        let enabled = (j["enabled"] as? Bool) ?? true   // het blok staat er alleen als het aan staat
        guard enabled else { return nil }
        return LifetimeOnly167(enabled: true, announced: (j["announced"] as? Bool) ?? false,
                               cutoverAt: ISODate167.parse(j["cutover_at"]), trialUntil: ISODate167.parse(j["trial_until"]))
    }
}

/// `entitlements.iap`: mag de Apple-app de koopknop (StoreKit) tonen?
struct IAP167: Codable, Equatable {
    static let productID = "nl.lrvdlinden.bingr.lifetime"

    var apple: Bool

    init(apple: Bool) { self.apple = apple }

    /// Alleen aan als de server `apple: true` meldt én (als hij een product noemt) precies ons product.
    static func parse(_ v: Any?) -> IAP167 {
        guard let j = v as? [String: Any] else { return IAP167(apple: false) }
        let on = (j["apple"] as? Bool) ?? false
        if let p = j["product_id"] as? String, !p.isEmpty, p != productID { return IAP167(apple: false) }
        return IAP167(apple: on)
    }
}

/// EU-storefronts (StoreKit `Storefront.countryCode` is ISO 3166-1 alpha-3; alpha-2 mag ook).
enum EUStorefront167 {
    static let alpha3: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN", "IRL",
        "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE"
    ]
    static let alpha2: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE"
    ]

    static func contains(_ code: String?) -> Bool {
        guard let c = code?.trimmingCharacters(in: .whitespaces).uppercased(), !c.isEmpty else { return false }
        return alpha3.contains(c) || alpha2.contains(c)
    }

    /// De EU-link mag alleen als de server hem aanzet, `ExternalPurchaseLink.canOpen` true is en de storefront in de
    /// EU ligt.
    static func linkAvailable(serverFlag: Bool, canOpen: Bool, storefront: String?) -> Bool {
        serverFlag && canOpen && contains(storefront)
    }
}

/// Wat de app over de overgang weet (uit `entitlements`).
struct LifetimeState167: Equatable {
    var isLifetime: Bool
    var access: Access167
    var lifetimeOnly: LifetimeOnly167?
    var iap: IAP167
    var linkEUApple: Bool

    init(isLifetime: Bool, access: Access167 = .full, lifetimeOnly: LifetimeOnly167? = nil,
         iap: IAP167 = IAP167(apple: false), linkEUApple: Bool = false) {
        self.isLifetime = isLifetime; self.access = access; self.lifetimeOnly = lifetimeOnly
        self.iap = iap; self.linkEUApple = linkEUApple
    }
}

/// Wanneer welk scherm en welke knop.
enum LifetimeUI167 {
    /// Schermvullend Activeer Lifetime: de server zegt `activate` (een Lifetime-account nooit).
    static func showActivate(_ s: LifetimeState167) -> Bool {
        s.access == .activate && !s.isLifetime
    }

    enum Announcement: Equatable {
        /// "Bingr wordt Lifetime op <datum>" (vóór de overgang)
        case cutover(Date)
        /// Na de overgang nog in de proefperiode: "Je proefperiode loopt tot <datum>"
        case trial(Date)
    }

    /// De kaart (Home en Instellingen > Abonnement), alleen voor een gratis account dat nog gewoon kan kijken.
    static func announcement(_ s: LifetimeState167, now: Date) -> Announcement? {
        guard !s.isLifetime, s.access == .full, let lo = s.lifetimeOnly, lo.enabled else { return nil }
        if let c = lo.cutoverAt, now < c {
            return lo.announced ? .cutover(c) : nil
        }
        if let t = lo.trialUntil, now < t { return .trial(t) }
        return nil
    }

    struct ActivateButtons: Equatable {
        var buy: Bool
        var restore: Bool
        var euLink: Bool
        /// Geen koopknop en geen EU-link: alleen "Je account is nog niet geactiveerd" (met Herstel, Uitloggen, Support)
        var notActivatedOnly: Bool
    }

    /// `productLoaded`: StoreKit heeft het product (en dus `displayPrice`) geleverd.
    /// `euLinkAvailable`: uitkomst van `EUStorefront167.linkAvailable`.
    static func activateButtons(_ s: LifetimeState167, productLoaded: Bool, euLinkAvailable: Bool) -> ActivateButtons {
        let buy = s.iap.apple && productLoaded
        let eu = s.linkEUApple && euLinkAvailable
        return ActivateButtons(buy: buy, restore: true, euLink: eu, notActivatedOnly: !buy && !eu)
    }

    /// Koopknop op de aankondigingskaart en in Instellingen > Abonnement: alleen als de server het aanzet.
    static func showBuy(_ s: LifetimeState167, productLoaded: Bool) -> Bool {
        !s.isLifetime && s.iap.apple && productLoaded
    }

    /// Herstel aankopen in Instellingen > Abonnement (als `iap.apple`); op het activatiescherm altijd.
    static func showRestore(_ s: LifetimeState167) -> Bool {
        !s.isLifetime && s.iap.apple
    }

    /// De vergelijking: "Gratis (tot <datum>)" zolang de overgang aan staat en de datum bekend is.
    static func freeUntil(_ s: LifetimeState167) -> Date? {
        guard let lo = s.lifetimeOnly, lo.enabled else { return nil }
        return lo.cutoverAt
    }
}

/// `stream_start` van device-auth: wat het antwoord betekent.
enum StreamStart167 {
    enum Outcome: Equatable { case ok, limit, activation, offline }

    /// `status` nil = geen antwoord (netwerk).
    static func outcome(status: Int?, error: String?) -> Outcome {
        guard let status else { return .offline }
        if error == "activation_required" { return .activation }
        if status == 403 || error == "stream_limit" { return .limit }
        return status == 200 ? .ok : .offline
    }
}

/// `billing` `apple_verify` en wat er daarna met de StoreKit-transactie gebeurt.
enum AppleVerify167 {
    enum Outcome: Equatable {
        /// Lifetime staat op dit account
        case lifetime
        /// 409 `owned_by_other_account`: de aankoop hoort bij een ander Bingr-account
        case otherAccount
        /// De server kent `apple_verify` nog niet (oudere functie)
        case unavailable
        /// Netwerk of een andere fout: later opnieuw
        case failed
    }

    static func outcome(status: Int?, error: String?, plan: String?) -> Outcome {
        guard let status else { return .failed }
        if status == 409 || error == "owned_by_other_account" { return .otherAccount }
        if status == 400 && error == "unknown_action" { return .unavailable }
        if status == 200 && plan?.lowercased() == "lifetime" { return .lifetime }
        return .failed
    }

    /// `transaction.finish()` alleen als de server de aankoop verwerkt heeft (ook als hij bij een ander account hoort:
    /// dan is hij afgehandeld). Bij een fout blijft hij staan en komt hij via `Transaction.updates`/`unfinished` terug.
    static func shouldFinish(_ o: Outcome) -> Bool {
        o == .lifetime || o == .otherAccount
    }

    /// `appAccountToken` = de account-id (uuid) van de ingelogde gebruiker; geen geldige uuid = niet kopen.
    static func appAccountToken(_ userID: String?) -> UUID? {
        guard let s = userID?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return UUID(uuidString: s)
    }

    /// Hoort een transactie bij ons product en is hij niet ingetrokken?
    static func relevant(productID: String, revoked: Bool) -> Bool {
        productID == IAP167.productID && !revoked
    }
}
