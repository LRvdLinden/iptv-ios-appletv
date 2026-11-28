import Foundation
import StoreKit

/// Build 193: de betaaltrechter melden aan `billing` (`funnel`), zie `Funnel193`. Fire-and-forget: nooit wachten,
/// nooit opnieuw proberen, korte time-out; het antwoord wordt genegeerd. Geen account, geen id's, geen prijzen.
@MainActor
final class PurchaseFunnel193 {
    static let shared = PurchaseFunnel193()

    private var dedupe = Funnel193.Dedupe()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private init() {}

    private static var build: Int? { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } }

    /// Een betaalscherm verschijnt (`screen` = welk scherm, alleen om te ontdubbelen).
    func paywallShown(_ screen: String) {
        guard dedupe.shouldSend(screen, now: Date().timeIntervalSinceReferenceDate) else { return }
        send(.paywallShown)
    }

    func send(_ step: Funnel193.Step, product: String? = nil, error: String? = nil) {
        guard Secrets.accountsConfigured,
              let url = URL(string: Secrets.supabaseURL + "/functions/v1/billing"),
              let body = Funnel193.body(step: step, platform: AccountService.entitlementsPlatform, build: Self.build,
                                        product: product, error: error),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        session.dataTask(with: req).resume()   // antwoord en fouten bewust genegeerd
    }

    func failed(_ f: Funnel193.StoreFailure, purchase product: String?) {
        send(.purchaseFailed, product: product, error: Funnel193.code(f))
    }

    func restore(_ r: Funnel193.RestoreResult) {
        let m = Funnel193.restore(r)
        send(m.step, error: m.error)
    }

    /// Een fout van `Product.purchase` naar een soort (nooit de tekst van de fout).
    static func storeFailure(_ error: Error) -> Funnel193.StoreFailure {
        if let e = error as? Product.PurchaseError {
            switch e {
            case .productUnavailable: return .noProduct
            case .purchaseNotAllowed: return .notAllowed
            case .invalidOfferIdentifier, .invalidOfferPrice, .invalidOfferSignature, .missingOfferParameters:
                return .invalidOffer
            default: return .unknown
            }
        }
        if let e = error as? StoreKitError {
            switch e {
            case .networkError: return .network
            case .notAvailableInStorefront: return .notAvailableInStorefront
            case .systemError: return .system
            default: return .unknown
            }
        }
        if error is URLError { return .network }
        return .unknown
    }
}
