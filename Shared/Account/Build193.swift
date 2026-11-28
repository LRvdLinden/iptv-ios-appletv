import Foundation

// Build 193 (versie 1.1.2): de betaaltrechter meten. Pure logica (alleen Foundation), ook los gebouwd in de zelftest
// van CI (tools/selftest/main.swift). Het versturen zelf staat in PurchaseFunnel193.swift.
//
// Contract: POST /functions/v1/billing {action:"funnel", step, platform, build, product?, error?}. Zonder inloggen,
// antwoord negeren, nooit blokkeren en nooit opnieuw proberen. Er gaat geen account-id, transactie-id, prijs of vrije
// tekst mee: alleen een stap, het platform, het buildnummer, het soort product en een korte foutcode.

enum Funnel193 {
    enum Step: String, CaseIterable, Equatable {
        case paywallShown = "paywall_shown"
        case purchaseStarted = "purchase_started"
        case purchaseOK = "purchase_ok"
        case purchaseFailed = "purchase_failed"
        case purchaseCancelled = "purchase_cancelled"
        case restoreStarted = "restore_started"
        case restoreOK = "restore_ok"
        case restoreFailed = "restore_failed"

        /// Alleen bij een fout hoort een foutcode.
        var carriesError: Bool { self == .purchaseFailed || self == .restoreFailed }
    }

    static let platforms: Set<String> = ["ios", "ipados", "tvos", "macos"]
    static let products: Set<String> = ["month", "half", "year", "lifetime"]
    static let maxError = 40

    /// Foutcode opschonen: kleine letters, alleen a-z, 0-9 en _, hooguit 40 tekens. Leeg = geen code.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var out = ""
        var lastUnderscore = true   // geen _ aan het begin
        for u in raw.lowercased().unicodeScalars {
            let ok = (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
            if ok {
                out.unicodeScalars.append(u)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
            if out.count >= maxError { break }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// De body van één melding, of nil als hij niet aan het contract voldoet (onbekend platform of geen build).
    static func body(step: Step, platform: String, build: Int?, product: String? = nil, error: String? = nil) -> [String: Any]? {
        guard platforms.contains(platform), let build, build > 0 else { return nil }
        var b: [String: Any] = ["action": "funnel", "step": step.rawValue, "platform": platform, "build": build]
        if let product, products.contains(product) { b["product"] = product }
        if step.carriesError { b["error"] = clean(error) ?? "unknown" }
        return b
    }

    // MARK: foutcodes

    /// Antwoord van `billing` `apple_verify` naar een foutcode. `status` nil = geen antwoord (netwerk).
    /// 200 zonder bruikbaar plan = de server gaf geen toegang.
    static func verifyError(status: Int?, error: String?) -> String {
        guard let status else { return "network" }
        if status == 409 || error == "owned_by_other_account" { return "other_account" }
        if status == 200 { return "not_entitled" }
        if status == 400 || status == 403, let e = clean(error) { return clean("server_\(e)") ?? "server_\(status)" }
        if status >= 500 { return status == 500 ? "server_error" : "server_\(status)" }
        return "server_\(status)"
    }

    /// Soorten StoreKit-fouten (los van StoreKit, zodat de zelftest ze kent).
    enum StoreFailure: Equatable {
        case unverified, pending, notSignedIn, noProduct, unavailable
        case network, notAllowed, notAvailableInStorefront, invalidOffer, system, unknown
    }

    static func code(_ f: StoreFailure) -> String {
        switch f {
        case .unverified: return "storekit_unverified"
        case .pending: return "pending"
        case .notSignedIn: return "not_signed_in"
        case .noProduct: return "no_product"
        case .unavailable: return "unavailable"
        case .network: return "network"
        case .notAllowed: return "storekit_not_allowed"
        case .notAvailableInStorefront: return "storekit_not_in_storefront"
        case .invalidOffer: return "storekit_invalid_offer"
        case .system: return "storekit_system"
        case .unknown: return "storekit_unknown"
        }
    }

    /// Uitkomst van "Herstel aankopen" naar stap en foutcode.
    enum RestoreResult: Equatable { case restored, nothing, otherAccount, signInFirst, createAccount, unavailable, failed(String) }

    static func restore(_ r: RestoreResult) -> (step: Step, error: String?) {
        switch r {
        case .restored: return (.restoreOK, nil)
        case .nothing: return (.restoreFailed, "nothing_found")
        case .otherAccount: return (.restoreFailed, "other_account")
        case .signInFirst: return (.restoreFailed, "not_signed_in")
        // gevonden, maar er is nog geen account: de aankoop wordt na het aanmaken geclaimd
        case .createAccount: return (.restoreFailed, "needs_account")
        case .unavailable: return (.restoreFailed, "unavailable")
        case .failed(let e): return (.restoreFailed, clean(e) ?? "unknown")
        }
    }

    // MARK: ontdubbelen

    /// `paywall_shown` één keer per keer dat een betaalscherm verschijnt: SwiftUI kan `onAppear` kort na elkaar
    /// herhalen (bijv. na een blad erover). Zelfde scherm binnen `window` seconden telt niet opnieuw.
    struct Dedupe: Equatable {
        var last: [String: TimeInterval] = [:]
        var window: TimeInterval = 20

        mutating func shouldSend(_ key: String, now: TimeInterval) -> Bool {
            if let t = last[key], now - t >= 0, now - t < window { return false }
            last[key] = now
            return true
        }
    }
}
