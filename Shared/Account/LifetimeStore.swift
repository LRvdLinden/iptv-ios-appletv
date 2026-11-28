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
    /// Aanvulling 1: publieke `billing config` (ook zonder inloggen), bewaard in de cache.
    @Published private(set) var publicConfig: PublicConfig167?
    /// Aanvulling 1: er is een Lifetime-aankoop die nog door geen account geclaimd is (niet afgerond). Niet ingelogd:
    /// "Je aankoop is gelukt, maak nu je account"; na het inloggen claimt de app hem stil (`apple_verify`).
    @Published private(set) var unclaimedPurchase = false

    /// Willekeurige `appAccountToken` voor een aankoop zonder account; in de eigen sleutelopslag van de app
    /// (`Keychain`, bestand op dit toestel), tot een account de aankoop geclaimd heeft.
    static let pendingTokenKey = "lifetime.pendingAccountToken"
    private static let publicConfigKey = "lifetime167.publicConfig"

    /// Welkomstscherm met eerst Koop Lifetime (na de overgang)
    /// build 181: niet als Premium voor Apple aan staat (dan eerst het account, daarna "Kies je plan")
    var buyFirst: Bool { premiumPublic?.enabled != true && Welcome167.buyFirst(publicConfig, now: Date()) }
    /// build 181: publieke `billing config` → `premium` (bewaard in de cache)
    @Published private(set) var premiumPublic: PremiumPublic181?
    private static let premiumPublicKey = "premium181.publicConfig"

    enum Message: String, Identifiable {
        case purchased, restored, nothingToRestore, pending, otherAccount, failed, unavailable
        /// aanvulling 1: gekocht zonder account
        case createAccount
        var id: String { rawValue }

        var text: String {
            switch self {
            case .purchased: return L("Thank you! Your account now has Lifetime.")
            case .restored: return L("Your purchase has been restored.")
            case .nothingToRestore: return L("No purchase found to restore.")
            case .pending: return L("Your purchase is waiting for approval.")
            case .otherAccount: return L("Sign in with the account you used to buy Bingr.")
            case .createAccount: return L("Your purchase was successful. Now create your Bingr account, or sign in.")
            case .failed: return L("The purchase could not be completed. Try again later.")
            case .unavailable: return L("Purchases are not available yet. Try again later.")
            }
        }
    }

    private var started = false
    private var updates: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var loading = false
    /// build 193: ging de laatste aankoop of het laatste herstel van de gebruiker naar de server? (foutcode van de trechter)
    private var askedServer = false
    /// build 193: in deze sessie zonder account gekocht; `purchase_ok` zodra een account de aankoop claimt
    private var awaitingClaim = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.publicConfigKey) {
            publicConfig = try? JSONDecoder().decode(PublicConfig167.self, from: d)
        }
        if let d = UserDefaults.standard.data(forKey: Self.premiumPublicKey) {
            premiumPublic = try? JSONDecoder().decode(PremiumPublic181.self, from: d)
        }
    }

    /// Publieke config ophalen (zonder inloggen). Zonder netwerk blijft de bewaarde stand staan.
    func refreshPublicConfig() async {
        guard let j = await AccountService.shared.billingConfig() else { return }
        let c = PublicConfig167.parse(j)
        if c != publicConfig { publicConfig = c }
        let pp = PremiumPublic181.parse(j)
        if pp != premiumPublic { premiumPublic = pp }
        if let pp, let d = try? JSONEncoder().encode(pp) {
            UserDefaults.standard.set(d, forKey: Self.premiumPublicKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.premiumPublicKey)
        }
        if let c, let d = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(d, forKey: Self.publicConfigKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.publicConfigKey)
        }
        await prepare()
    }

    /// Koopknop aan? Ingelogd volgens `entitlements.iap`, anders volgens de publieke config.
    private var iapOn: Bool {
        AccountService.shared.isSignedIn ? state.iap.apple : (publicConfig?.iapApple ?? false)
    }

    /// Eén keer bij het starten van de app.
    func start() {
        guard !started else { return }
        started = true
        updates = Task.detached(priority: .utility) {
            for await v in StoreKit.Transaction.updates {
                await LifetimeStore.shared.handle(v, userInitiated: false)
            }
        }
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                Task {
                    if signedIn {
                        await self?.claimAll()
                    } else {
                        // aanvulling 1: welkomstscherm (na de overgang eerst kopen) en ongeclaimde aankopen
                        await self?.checkUnclaimed()
                        await self?.refreshPublicConfig()
                    }
                }
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
        if iapOn && product == nil && !loading {
            loading = true
            defer { loading = false }
            product = try? await Product.products(for: [IAP167.productID]).first
        }
        await checkEULink(flag: s.linkEUApple)
    }

    // MARK: kopen

    func purchase(origin: String) async {
        guard !busy else { return }
        // build 193: de betaaltrechter (alleen stap, soort product en een korte foutcode)
        let funnel = PurchaseFunnel193.shared
        let kind = "lifetime"
        funnel.send(.purchaseStarted, product: kind)
        guard iapOn else { funnel.failed(.unavailable, purchase: kind); show(.unavailable, origin); return }
        if product == nil { await prepare() }
        // ingelogd: de account-id; zonder account (aanvulling 1): een bewaarde willekeurige token
        let signedIn = AccountService.shared.isSignedIn
        guard let product,
              let pick = Welcome167.purchaseToken(userID: signedIn ? (AccountService.shared.accountID ?? "") : nil,
                                                  pending: Keychain.getLocalOnly(Self.pendingTokenKey), make: { UUID() }) else {
            funnel.failed(product == nil ? .noProduct : .notSignedIn, purchase: kind)
            show(.unavailable, origin)
            return
        }
        if pick.store { Keychain.setLocalOnly(pick.token.uuidString, for: Self.pendingTokenKey) }
        let token = pick.token
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case .success(let v):
                guard signedIn else {
                    // niet afronden: StoreKit houdt de transactie vast tot een account hem claimt
                    if case .verified = v {
                        // build 193: betaald, maar nog van geen account; `purchase_ok` volgt als een account hem claimt
                        awaitingClaim = true
                        unclaimedPurchase = true   // AuthView toont meteen Account maken (met de melding)
                    } else {
                        funnel.failed(.unverified, purchase: kind)
                        show(.failed, origin)
                    }
                    return
                }
                let o = await handle(v, userInitiated: true)
                if o == .lifetime {
                    funnel.send(.purchaseOK, product: kind)
                } else {
                    funnel.send(.purchaseFailed, product: kind, error: funnelError(o, v))
                }
                show(o == .lifetime ? .purchased : Self.message(for: o), origin)
            case .pending:
                funnel.failed(.pending, purchase: kind)
                show(.pending, origin)
            case .userCancelled:
                funnel.send(.purchaseCancelled, product: kind)
            @unknown default:
                funnel.failed(.unknown, purchase: kind)
            }
        } catch {
            funnel.failed(PurchaseFunnel193.storeFailure(error), purchase: kind)
            show(.failed, origin)
        }
    }

    /// build 193: foutcode voor de betaaltrechter als een aankoop niet op het account kwam.
    private func funnelError(_ o: AppleVerify167.Outcome, _ v: VerificationResult<StoreKit.Transaction>) -> String {
        if case .unverified = v { return Funnel193.code(.unverified) }
        if o == .otherAccount { return "other_account" }
        guard askedServer else {
            return Funnel193.code(AccountService.shared.isSignedIn ? .unknown : .notSignedIn)
        }
        let last = AccountService.shared.lastAppleVerify
        return Funnel193.verifyError(status: last.status, error: last.error)
    }

    /// Herstel aankopen: `AppStore.sync()` en alle huidige aankopen van ons product naar de server.
    func restore(origin: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let funnel = PurchaseFunnel193.shared   // build 193
        funnel.send(.restoreStarted)
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            funnel.restore(.failed("cancelled"))
            return
        } catch {
            // zonder sync (bijv. offline) toch de bekende aankopen proberen
        }
        guard AccountService.shared.isSignedIn else {
            // aanvulling 1: zonder account kan de app niet claimen; nog niet afgerond = nog van niemand
            let unfinished = await unfinishedIDs()
            var found = false, open = false
            for await v in StoreKit.Transaction.currentEntitlements {
                guard case .verified(let t) = v, AppleVerify167.relevant(productID: t.productID, revoked: t.revocationDate != nil) else { continue }
                found = true
                if unfinished.contains(t.id) { open = true }
            }
            if !open, !unfinished.isEmpty { found = true; open = true }   // Ask to Buy e.d.: wel onafgerond
            switch Welcome167.restoreSignedOut(found: found, unfinished: open) {
            case .createAccount:
                funnel.restore(.createAccount)
                unclaimedPurchase = true   // AuthView toont meteen Account maken
            case .signIn:
                funnel.restore(.signInFirst)
                show(.otherAccount, origin)
            case .nothing:
                funnel.restore(.nothing)
                show(.nothingToRestore, origin)
            }
            return
        }
        var best: AppleVerify167.Outcome?
        for await v in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = v, AppleVerify167.relevant(productID: t.productID, revoked: t.revocationDate != nil) else { continue }
            let o = await handle(v, userInitiated: true)
            if best == nil || o == .lifetime { best = o }
            if o == .lifetime { break }
        }
        await EntitlementsService.shared.refresh(force: true)
        if let best {
            switch best {
            case .lifetime: funnel.restore(.restored)
            case .otherAccount: funnel.restore(.otherAccount)
            case .unavailable: funnel.restore(.unavailable)
            case .failed:
                let last = AccountService.shared.lastAppleVerify
                funnel.restore(.failed(askedServer ? Funnel193.verifyError(status: last.status, error: last.error)
                                                   : Funnel193.code(.unknown)))
            }
            show(best == .lifetime ? .restored : Self.message(for: best), origin)
        } else {
            let has = EntitlementsService.shared.lifetimeState.isLifetime
            funnel.restore(has ? .restored : .nothing)
            show(has ? .restored : .nothingToRestore, origin)
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

    /// Na het inloggen (en bij de start als er iemand ingelogd is): onafgeronde aankopen claimen, en als het account
    /// nog geen Lifetime heeft ook de huidige aankopen stil naar `apple_verify` (aanvulling 1, punt 4).
    private func claimAll() async {
        for await v in StoreKit.Transaction.unfinished {
            let o = await handle(v, userInitiated: false)
            // build 193: de aankoop van vóór het account is nu gekoppeld
            if awaitingClaim, o == .lifetime {
                awaitingClaim = false
                PurchaseFunnel193.shared.send(.purchaseOK, product: "lifetime")
            }
        }
        let stillOpen = await hasUnfinished()
        if !stillOpen { unclaimedPurchase = false }
        guard AccountService.shared.isSignedIn else { return }
        await EntitlementsService.shared.refreshUnlessRecent(30)
        guard !EntitlementsService.shared.lifetimeState.isLifetime, EntitlementsService.shared.current != nil else { return }
        for await v in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = v, AppleVerify167.relevant(productID: t.productID, revoked: t.revocationDate != nil) else { continue }
            if await handle(v, userInitiated: false) == .lifetime { break }
        }
    }

    /// Niet ingelogd: staat er een geverifieerde, onafgeronde Lifetime-aankoop (nog van niemand)?
    private func checkUnclaimed() async {
        unclaimedPurchase = await hasUnfinished()
    }

    private func hasUnfinished() async -> Bool {
        !(await unfinishedIDs()).isEmpty
    }

    private func unfinishedIDs() async -> Set<UInt64> {
        var ids = Set<UInt64>()
        for await v in StoreKit.Transaction.unfinished {
            if case .verified(let t) = v, AppleVerify167.relevant(productID: t.productID, revoked: t.revocationDate != nil) {
                ids.insert(t.id)
            }
        }
        return ids
    }

    /// Eén transactie: alleen een geverifieerde van ons product gaat naar de server; `finish()` pas als de server hem
    /// verwerkt heeft. Een ingetrokken aankoop (terugbetaald) wordt afgerond; de server haalt Lifetime er zelf af
    /// (`apple-notify`), dus alleen opnieuw ophalen.
    @discardableResult
    private func handle(_ v: VerificationResult<StoreKit.Transaction>, userInitiated: Bool) async -> AppleVerify167.Outcome {
        if userInitiated { askedServer = false }
        guard case .verified(let t) = v, t.productID == IAP167.productID else { return .failed }
        if t.revocationDate != nil {
            await t.finish()
            await EntitlementsService.shared.refresh(force: true)
            return .failed
        }
        guard AccountService.shared.isSignedIn else { return .failed }   // blijft staan tot er iemand ingelogd is
        if userInitiated { askedServer = true }
        let o = await AccountService.shared.appleVerify(signedTransaction: v.jwsRepresentation)
        if AppleVerify167.shouldFinish(o) {
            await t.finish()
            // geclaimd (door dit of een ander account): geen open aankoop en geen bewaarde token meer
            unclaimedPurchase = false
            Keychain.setLocalOnly(nil, for: Self.pendingTokenKey)
        }
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
