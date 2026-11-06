import Foundation
import Combine
import StoreKit
import SwiftUI

/// Build 167: Lifetime kopen in de app (StoreKit 2, non-consumable `nl.lrvdlinden.bingr.lifetime`), zie
/// docs/ACCOUNT.md ("Build 167: alleen Lifetime") en docs/APPLE-LIFETIME.md.
///
/// - Kopen met `appAccountToken` = de account-id, daarna `jwsRepresentation` naar `billing` `apple_verify` en pas
///   dan `transaction.finish()`.
/// - `Transaction.updates` vanaf de start (ook aankopen van buiten de app, Ask to Buy, terugbetalingen) en
///   `Transaction.unfinished` na het inloggen.
/// - Herstel aankopen: `AppStore.sync()` + `Transaction.currentEntitlements`, alles naar `apple_verify`.
/// - De prijs komt alleen uit StoreKit (`displayPrice`); nooit een vaste prijs, nooit een code of korting.
/// - De koopknop alleen als de server `iap.apple` meldt (zie `LifetimeUI167`).
/// - EU External Purchase Link (alleen iPhone/iPad) achter de flag `upgrade.link_eu_apple`, en alleen als
///   `ExternalPurchaseLink.canOpen` en een EU-storefront. Zonder de entitlement (nog niet aangevraagd) is `canOpen`
///   false en verschijnt er niets.
@MainActor
final class LifetimeStore: ObservableObject {
    static let shared = LifetimeStore()

    /// Het product uit StoreKit (nil = nog niet geladen, of niet beschikbaar).
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    /// Uitkomst van een actie van de gebruiker (kopen, herstellen), getoond door het scherm waar die begon
    /// (`origin`), zodat er nooit twee meldingen tegelijk open willen.
    @Published private(set) var message: Message?
    private(set) var messageOrigin: String?
    /// EU-link mag getoond worden (flag + canOpen + EU-storefront).
    @Published private(set) var euLinkAvailable = false

    enum Message: String, Identifiable {
        case purchased, restored, nothingToRestore, pending, otherAccount, failed, unavailable
        var id: String { rawValue }

        var text: String {
            switch self {
            case .purchased: return L("Thank you! Your account now has Lifetime.")
            case .restored: return L("Your purchase has been restored.")
            case .nothingToRestore: return L("No purchase found to restore.")
            case .pending: return L("Your purchase is waiting for approval.")
            case .otherAccount: return L("This purchase belongs to another Bingr account. Sign in with that account to use it.")
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

    /// Eén keer bij het starten van de app.
    func start() {
        guard !started else { return }
        started = true
        updates = Task.detached(priority: .utility) {
            for await v in Transaction.updates {
                await LifetimeStore.shared.handle(v, userInitiated: false)
            }
        }
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                Task { await self?.processUnfinished() }
            }
            .store(in: &bag)
        // koopknop of EU-link aangezet: product laden en de EU-link controleren
        EntitlementsService.shared.$current
            .map { e -> String in "\(e?.iap.apple ?? false)|\(e?.upgrade.linkEUApple ?? false)" }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.prepare() } }
            .store(in: &bag)
    }

    var state: LifetimeState167 { EntitlementsService.shared.lifetimeState }

    /// De melding alleen voor het scherm `origin` (Activeer Lifetime, Home of Instellingen).
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
    var productLoaded: Bool { product != nil }

    /// Product laden (als de koopknop aan mag) en de EU-link controleren.
    func prepare() async {
        let s = state
        if s.iap.apple && product == nil && !loading {
            loading = true
            defer { loading = false }
            product = try? await Product.products(for: [IAP167.productID]).first
        }
        await checkEULink(flag: s.linkEUApple)
    }

    // MARK: kopen

    func purchase(origin: String) async {
        guard !busy else { return }
        guard state.iap.apple else { show(.unavailable, origin); return }
        if product == nil { await prepare() }
        guard let product, let token = AppleVerify167.appAccountToken(AccountService.shared.accountID) else {
            show(.unavailable, origin)
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case .success(let v):
                let o = await handle(v, userInitiated: true)
                show(o == .lifetime ? .purchased : Self.message(for: o), origin)
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

    /// Herstel aankopen: `AppStore.sync()` en alle huidige aankopen van ons product naar de server.
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
        var best: AppleVerify167.Outcome?
        for await v in Transaction.currentEntitlements {
            guard case .verified(let t) = v, AppleVerify167.relevant(productID: t.productID, revoked: t.revocationDate != nil) else { continue }
            let o = await handle(v, userInitiated: true)
            if best == nil || o == .lifetime { best = o }
            if o == .lifetime { break }
        }
        await EntitlementsService.shared.refresh(force: true)
        if let best {
            show(best == .lifetime ? .restored : Self.message(for: best), origin)
        } else {
            show(EntitlementsService.shared.lifetimeState.isLifetime ? .restored : .nothingToRestore, origin)
        }
    }

    private static func message(for o: AppleVerify167.Outcome) -> Message {
        switch o {
        case .lifetime: return .restored
        case .otherAccount: return .otherAccount
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    // MARK: transacties

    private func processUnfinished() async {
        for await v in Transaction.unfinished {
            await handle(v, userInitiated: false)
        }
    }

    /// Eén transactie: alleen een geverifieerde van ons product gaat naar de server; `finish()` pas als de server hem
    /// verwerkt heeft. Een ingetrokken aankoop (terugbetaald) wordt afgerond; de server haalt Lifetime er zelf af
    /// (`apple-notify`), dus alleen opnieuw ophalen.
    @discardableResult
    private func handle(_ v: VerificationResult<Transaction>, userInitiated: Bool) async -> AppleVerify167.Outcome {
        guard case .verified(let t) = v, t.productID == IAP167.productID else { return .failed }
        if t.revocationDate != nil {
            await t.finish()
            await EntitlementsService.shared.refresh(force: true)
            return .failed
        }
        guard AccountService.shared.isSignedIn else { return .failed }   // blijft staan tot er iemand ingelogd is
        let o = await AccountService.shared.appleVerify(signedTransaction: v.jwsRepresentation)
        if AppleVerify167.shouldFinish(o) { await t.finish() }
        if !userInitiated, o == .lifetime, !EntitlementsService.shared.lifetimeState.isLifetime {
            await EntitlementsService.shared.refresh(force: true)
        }
        return o
    }

    // MARK: EU External Purchase Link (alleen iPhone en iPad)

    private func checkEULink(flag: Bool) async {
        #if os(iOS)
        guard flag else { euLinkAvailable = false; return }
        if #available(iOS 17.4, *) {
            let can = await ExternalPurchaseLink.canOpen
            let storefront = await Storefront.current?.countryCode
            euLinkAvailable = EUStorefront167.linkAvailable(serverFlag: flag, canOpen: can, storefront: storefront)
        } else {
            euLinkAvailable = false
        }
        #else
        euLinkAvailable = false
        #endif
    }

    /// Opent de link uit Info.plist (`SKExternalPurchaseLink`); StoreKit toont eerst het verplichte informatieblad.
    /// Terug in de app: het abonnement opnieuw ophalen (de webhook zet Lifetime op het account).
    func openEULink() async {
        #if os(iOS)
        guard euLinkAvailable else { return }
        if #available(iOS 17.4, *) {
            try? await ExternalPurchaseLink.open()
        }
        await EntitlementsService.shared.refresh(force: true)
        #endif
    }
}
