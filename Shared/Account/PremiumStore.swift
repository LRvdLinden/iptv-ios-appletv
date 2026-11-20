import Foundation
import Combine
import StoreKit
import SwiftUI

/// Build 181: Bingr Premium kopen in de app (StoreKit 2), zie docs/ACCOUNT.md ("Build 181: Bingr Premium") en
/// docs/PREMIUM_APPLE.md.
///
/// - Drie abonnementen (groep "Bingr Premium") en Lifetime 49,99 (`PremiumPlan181`).
/// - Kopen met `appAccountToken` = de account-id, daarna `jwsRepresentation` (en de `signed_renewal_info`) naar
///   `billing` `apple_verify`, en pas dan `transaction.finish()`.
/// - `Transaction.updates` vanaf de start (verlengingen, Ask to Buy, aankopen van buiten de app) en
///   `Transaction.unfinished` na het inloggen. De oude Lifetime (`nl.lrvdlinden.bingr.lifetime`) blijft bij
///   `LifetimeStore`.
/// - Prijzen alleen uit StoreKit (`displayPrice`); nooit een webprijs, code of link.
/// - Alles alleen als de server `premium.enabled` meldt (schakelaars `new_from_apple` / `existing_from`).
@MainActor
final class PremiumStore: ObservableObject {
    static let shared = PremiumStore()

    @Published private(set) var products: [PremiumPlan181: Product] = [:]
    /// StoreKit: mag dit Apple ID de introductieproef nog (per abonnementsgroep)?
    @Published private(set) var introEligible = false
    @Published private(set) var busy = false
    @Published private(set) var loadFailed = false
    @Published private(set) var message: Message?
    private(set) var messageOrigin: String?

    enum Message: String, Identifiable {
        case purchased, restored, nothingToRestore, pending, otherAccount, failed, unavailable
        var id: String { rawValue }

        var text: String {
            switch self {
            case .purchased: return L("Thank you! Your account now has Bingr Premium.")
            case .restored: return L("Your purchase has been restored.")
            case .nothingToRestore: return L("No purchase found to restore.")
            case .pending: return L("Your purchase is waiting for approval.")
            case .otherAccount: return L("Sign in with the account you used to buy Bingr.")
            case .failed: return L("The purchase could not be completed. Try again later.")
            case .unavailable: return L("Purchases are not available yet. Try again later.")
            }
        }
    }

    private var started = false
    private var updates: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var loading = false

    private init() {}

    var productsLoaded: Bool { PremiumPlan181.allCases.allSatisfy { products[$0] != nil } }

    func product(_ p: PremiumPlan181) -> Product? { products[p] }

    /// Een keer bij het starten van de app.
    func start() {
        guard !started else { return }
        started = true
        updates = Task.detached(priority: .utility) {
            for await v in StoreKit.Transaction.updates {
                await PremiumStore.shared.handle(v, userInitiated: false)
            }
        }
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                Task { await self?.claimUnfinished() }
            }
            .store(in: &bag)
    }

    /// De melding alleen voor het scherm `origin`.
    func binding(for origin: String) -> Binding<Message?> {
        Binding(get: { [weak self] in
            guard let self, self.messageOrigin == origin else { return nil }
            return self.message
        }, set: { [weak self] v in
            if v == nil { self?.message = nil; self?.messageOrigin = nil }
        })
    }

    private func show(_ m: Message, _ origin: String) {
        messageOrigin = origin
        message = m
    }

    /// Producten laden en de proef bij StoreKit nagaan (alleen als Premium aan staat voor dit account).
    func prepare() async {
        guard EntitlementsService.shared.premium?.enabled == true else { return }
        if !productsLoaded && !loading {
            loading = true
            defer { loading = false }
            do {
                let list = try await Product.products(for: PremiumPlan181.productIDs)
                var map: [PremiumPlan181: Product] = [:]
                for p in list {
                    if let plan = PremiumPlan181.from(productID: p.id), plan.productID == p.id { map[plan] = p }
                }
                products = map
                loadFailed = map.isEmpty
            } catch {
                loadFailed = true
            }
        }
        await checkIntro()
    }

    private func checkIntro() async {
        guard let sub = products[.month]?.subscription ?? products[.year]?.subscription else { introEligible = false; return }
        introEligible = await sub.isEligibleForIntroOffer
    }

    // MARK: kopen

    func purchase(_ plan: PremiumPlan181, origin: String) async {
        guard !busy else { return }
        guard EntitlementsService.shared.premium?.enabled == true else { show(.unavailable, origin); return }
        if products[plan] == nil { await prepare() }
        guard let product = products[plan],
              let token = AppleVerify167.appAccountToken(AccountService.shared.accountID) else {
            show(.unavailable, origin)
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case .success(let v):
                let o = await handle(v, userInitiated: true)
                show(Self.message(for: o, purchased: true), origin)
            case .pending:
                show(.pending, origin)
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            show(.failed, origin)
        }
    }

    /// Herstel aankopen: `AppStore.sync()` en alle huidige Premium-aankopen naar de server. De oude Lifetime gaat
    /// via `LifetimeStore` (zelfde knop).
    func restore(origin: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            // zonder sync (bijv. offline) toch de bekende aankopen proberen
        }
        guard AccountService.shared.isSignedIn else { show(.otherAccount, origin); return }
        var best: PremiumVerify181.Outcome?
        var oldLifetime = false
        for await v in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = v, t.revocationDate == nil else { continue }
            if AppleVerify167.relevant(productID: t.productID, revoked: false) {
                // de oude Lifetime (build 167)
                let o = await AccountService.shared.appleVerify(signedTransaction: v.jwsRepresentation)
                if AppleVerify167.shouldFinish(o) { await t.finish() }
                if o == .lifetime { oldLifetime = true }
                continue
            }
            guard PremiumVerify181.relevant(productID: t.productID, revoked: false) else { continue }
            let o = await handle(v, userInitiated: true)
            if case .premium = o { best = o } else if best == nil { best = o }
        }
        await EntitlementsService.shared.refresh(force: true)
        if oldLifetime { show(.restored, origin); return }
        if let best {
            show(Self.message(for: best, purchased: false), origin)
        } else {
            show(EntitlementsService.shared.premium?.active == true ? .restored : .nothingToRestore, origin)
        }
    }

    private static func message(for o: PremiumVerify181.Outcome, purchased: Bool) -> Message {
        switch o {
        case .premium: return purchased ? .purchased : .restored
        case .otherAccount: return .otherAccount
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    // MARK: transacties

    private func claimUnfinished() async {
        for await v in StoreKit.Transaction.unfinished {
            await handle(v, userInitiated: false)
        }
    }

    /// Eén transactie: alleen een geverifieerde Premium-transactie gaat naar de server; `finish()` pas als de server
    /// hem verwerkt heeft. Een ingetrokken transactie wordt afgerond; de server verwerkt de intrekking zelf
    /// (`apple-notify`), dus alleen opnieuw ophalen.
    @discardableResult
    private func handle(_ v: VerificationResult<StoreKit.Transaction>, userInitiated: Bool) async -> PremiumVerify181.Outcome {
        guard case .verified(let t) = v, PremiumPlan181.productIDs.contains(t.productID) else { return .failed }
        if t.revocationDate != nil {
            await t.finish()
            await EntitlementsService.shared.refresh(force: true)
            return .failed
        }
        guard AccountService.shared.isSignedIn else { return .failed }   // blijft staan tot er iemand ingelogd is
        let renewal = await renewalInfo(for: t)
        let o = await AccountService.shared.appleVerifyPremium(signedTransaction: v.jwsRepresentation,
                                                               signedRenewalInfo: renewal)
        if PremiumVerify181.shouldFinish(o) { await t.finish() }
        return o
    }

    /// De `signed_renewal_info` (JWS) van het abonnement van deze transactie, als StoreKit die heeft.
    private func renewalInfo(for t: StoreKit.Transaction) async -> String? {
        guard let group = t.subscriptionGroupID,
              let statuses = try? await Product.SubscriptionInfo.status(for: group) else { return nil }
        for s in statuses {
            if case .verified(let tx) = s.transaction, tx.originalID == t.originalID {
                return s.renewalInfo.jwsRepresentation
            }
        }
        return nil
    }

    // MARK: beheren

    /// Mac: de abonnementenpagina van Apple (geen betaalpagina van Bingr).
    static let appleSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
}
