import SwiftUI
import StoreKit

/// Build 181: Bingr Premium (zie Shared/Account/Build181.swift, Shared/Account/PremiumStore.swift en docs/ACCOUNT.md).
/// - `PremiumPaywallView`: schermvullend "Kies je plan" bij `access == "activate"` met `premium.enabled`;
///   gegevens blijven bewaard. Schakelaar Maand / Halfjaar / Jaar (jaar uitgelicht), kaart Premium, kaart Lifetime,
///   Herstel aankopen, Gebruiksvoorwaarden en Privacy. Op Apple TV met de focus van de afstandsbediening.
/// - `PremiumStatusRows`: Instellingen > Abonnement (plan, verlengt op, beheren).
/// Apple: alleen StoreKit-prijzen (`displayPrice`), nooit een webprijs, code, link of QR-code naar het web.

enum PremiumText {
    static func planName(_ p: PremiumPlan181) -> String {
        switch p {
        case .month: return L("Premium monthly")
        case .half: return L("Premium 6 months")
        case .year: return L("Premium yearly")
        case .lifetime: return L("Lifetime")
        }
    }

    /// Kort voor de schakelaar.
    static func switchTitle(_ p: PremiumPlan181) -> String {
        switch p {
        case .month: return L("Month")
        case .half: return L("6 months")
        case .year: return L("Year")
        case .lifetime: return L("Lifetime")
        }
    }

    static func period(_ p: PremiumPlan181) -> String {
        switch p {
        case .month: return L("per month")
        case .half: return L("per 6 months")
        case .year: return L("per year")
        case .lifetime: return L("one-time")
        }
    }

    /// Naam van het plan voor de regel "Abonnement" (nil = geen Premium-naam, dan de gewone naam).
    @MainActor static func current(_ p: Premium181?) -> String? {
        guard let p, p.active else { return nil }
        if p.isSubscription, let plan = p.plan { return planName(plan) }
        return nil
    }

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://bingr.online/privacy.html")!
}

// MARK: - Kies je plan

struct PremiumPaywallView: View {
    @EnvironmentObject var account: AccountService
    @ObservedObject private var ent = EntitlementsService.shared
    @ObservedObject private var store = PremiumStore.shared
    @ObservedObject private var lifetime = LifetimeStore.shared
    @State private var selected: PremiumPlan181 = PremiumUI181.defaultPlan
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    /// H1: huidig wachtwoord voor "Account verwijderen" (alleen in het geheugen)
    @State private var deletePassword = ""
    @State private var error: String?
    @State private var showSupport = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    private var screen: PremiumUI181.Screen { ent.premiumScreen }

    /// "3 dagen gratis": de server (`trial_eligible`) én StoreKit
    private func trial(_ p: PremiumPlan181) -> Bool {
        PremiumUI181.showTrial(plan: p, serverEligible: screen.paywall == .trial, storeEligible: store.introEligible)
    }

    private var busy: Bool { store.busy || lifetime.busy || account.isBusy }

    var body: some View {
        ZStack {
            AuthBackdrop()
            ScrollView {
                VStack(spacing: tvScaled(20)) {
                    BingrLogo(size: tvScaled(34)).padding(.top, tvScaled(24))
                    header
                    planSwitch
                    premiumCard
                    lifetimeCard
                    features
                    footer
                }
                .padding(.horizontal, Theme.edge)
                .padding(.bottom, tvScaled(32))
                .frame(maxWidth: tvScaled(600))
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            await ent.refreshUnlessRecent(60)
            await store.prepare()
        }
        .sheet(isPresented: $showSupport) {
            NavigationStack {
                SupportView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Done")) { showSupport = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
        .webPage(isPresented: $showTerms, url: PremiumText.termsURL, title: L("Terms of Use"))
        .webPage(isPresented: $showPrivacy, url: PremiumText.privacyURL, title: L("Privacy"))
        .alert(item: store.binding(for: "paywall")) { m in
            Alert(title: Text(m.text), dismissButton: .default(Text(L("OK"))))
        }
    }

    // MARK: onderdelen

    private var header: some View {
        VStack(spacing: tvScaled(8)) {
            Text(L("Choose your plan"))
                .font(.system(size: tvScaled(30), weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(screen.paywall == .trial && store.introEligible
                 ? L("Try Bingr Premium free for 3 days. Your servers, lists, profiles and settings are saved.")
                 : L("Choose a plan to keep watching. Your servers, lists, profiles and settings are saved."))
                .font(.system(size: tvScaled(15)))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let email = account.email {
                Text(L("Signed in as %@", email))
                    .font(.system(size: tvScaled(13)))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    /// Maand / Halfjaar / Jaar (op Apple TV met de focus).
    private var planSwitch: some View {
        HStack(spacing: tvScaled(6)) {
            ForEach(PremiumUI181.switchOrder, id: \.self) { p in
                Button { selected = p } label: {
                    VStack(spacing: tvScaled(2)) {
                        Text(PremiumText.switchTitle(p))
                            .font(.system(size: tvScaled(15), weight: .semibold))
                        if let s = savings(p) {
                            Text(L("Save %d%%", s))
                                .font(.system(size: tvScaled(11), weight: .bold))
                                .foregroundStyle(selected == p ? Theme.onAccent.opacity(0.85) : Color(hex: 0xF5C451))
                        }
                    }
                    .foregroundStyle(selected == p ? Theme.onAccent : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, tvScaled(10))
                    .background(selected == p ? Theme.red : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: tvScaled(8)))
                    .contentShape(Rectangle())
                }
                .cardButton()
                .accessibilityAddTraits(selected == p ? .isSelected : [])
            }
        }
        .padding(tvScaled(4))
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: tvScaled(11)))
    }

    private func savings(_ p: PremiumPlan181) -> Int? {
        PremiumUI181.savings(monthPrice: store.product(.month)?.price, price: store.product(p)?.price, months: p.months)
    }

    private var premiumCard: some View {
        let product = store.product(selected)
        let hasTrial = trial(selected)
        return VStack(alignment: .leading, spacing: tvScaled(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Bingr Premium")
                    .font(.system(size: tvScaled(20), weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 8)
                if selected == .year {
                    badge(savings(.year).map { L("Most popular · save %d%%", $0) } ?? L("Most popular"), gold: true)
                } else if let s = savings(selected) {
                    badge(L("Save %d%%", s), gold: true)
                }
            }
            if let product {
                HStack(alignment: .firstTextBaseline, spacing: tvScaled(6)) {
                    Text(product.displayPrice)
                        .font(.system(size: tvScaled(34), weight: .heavy)).foregroundStyle(.white)
                    Text(PremiumText.period(selected))
                        .font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                }
            } else if store.loadFailed {
                Text(L("Purchases are not available yet. Try again later."))
                    .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
            } else {
                ProgressView()
            }
            if hasTrial { badge(L("3 days free"), gold: false) }
            WideButton(title: hasTrial ? L("Start 3 days free") : L("Continue"), icon: "sparkles", prominent: true) {
                Task { await store.purchase(selected, origin: "paywall") }
            }
            .disabled(product == nil || busy)
            if hasTrial, let product {
                Text(L("Free for 3 days, then %@ %@. Cancel anytime in your Apple Account settings.",
                       product.displayPrice, PremiumText.period(selected)))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if product != nil {
                Text(L("Renews automatically. Cancel anytime in your Apple Account settings."))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(tvScaled(20))
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12))
            .stroke(selected == .year ? Color(hex: 0xF5C451).opacity(0.6) : Color.white.opacity(0.08), lineWidth: selected == .year ? 2 : 1))
    }

    private var lifetimeCard: some View {
        let product = store.product(.lifetime)
        return VStack(alignment: .leading, spacing: tvScaled(10)) {
            HStack(spacing: tvScaled(10)) {
                LifetimeBadge(size: tvScaled(26))
                VStack(alignment: .leading, spacing: tvScaled(2)) {
                    Text(L("Lifetime")).font(.system(size: tvScaled(18), weight: .bold)).foregroundStyle(.white)
                    Text(L("Pay once, Premium forever. No subscription."))
                        .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let product {
                    Text(product.displayPrice)
                        .font(.system(size: tvScaled(20), weight: .heavy)).foregroundStyle(.white)
                }
            }
            WideButton(title: L("Buy Lifetime"), icon: "cart") {
                Task { await store.purchase(.lifetime, origin: "paywall") }
            }
            .disabled(product == nil || busy)
        }
        .padding(tvScaled(20))
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("What you get")).font(.system(size: tvScaled(15), weight: .bold)).foregroundStyle(.white)
            ForEach([L("Live TV, movies and series from your own servers"),
                     L("All features: statistics, Trakt, kids profiles, continue watching and more"),
                     L("iPhone, iPad, Mac, Apple TV, Android, Windows and the web player"),
                     L("One account: your plan works on all your devices")], id: \.self) { t in
                Label { Text(t) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.red) }
                    .font(.system(size: tvScaled(14)))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(tvScaled(20))
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: tvScaled(12)))
    }

    private var footer: some View {
        VStack(spacing: tvScaled(10)) {
            WideButton(title: L("Restore purchases"), icon: "arrow.clockwise") {
                Task { await store.restore(origin: "paywall") }
            }
            HStack(spacing: tvScaled(10)) {
                WideButton(title: L("Terms of Use"), icon: "doc.text") { showTerms = true }
                WideButton(title: L("Privacy"), icon: "hand.raised") { showPrivacy = true }
            }
            WideButton(title: L("Support"), icon: "questionmark.circle") { showSupport = true }
            WideButton(title: L("Sign out"), icon: "rectangle.portrait.and.arrow.right") { confirmSignOut = true }
                .confirmationDialog(L("Sign out of Bingr on this device?"), isPresented: $confirmSignOut,
                                    titleVisibility: .visible) {
                    Button(L("Sign out"), role: .destructive) { Task { await account.signOut() } }
                    Button(L("Cancel"), role: .cancel) {}
                }
            WideButton(title: L("Delete account"), icon: "trash", destructive: true) {
                deletePassword = ""; confirmDelete = true
            }
            // bestaande flow (H1): bevestigen met het huidige wachtwoord
            .alert(L("Delete your Bingr account? This can't be undone."), isPresented: $confirmDelete) {
                SecureField(L("Password"), text: $deletePassword)
                Button(L("Delete account"), role: .destructive) { deleteAccount() }
                Button(L("Cancel"), role: .cancel) { deletePassword = "" }
            } message: {
                Text(L("Enter your password to confirm."))
            }
            if busy {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: tvScaled(13), weight: .medium))
                    .foregroundStyle(AuthForm.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(busy)
    }

    private func badge(_ text: String, gold: Bool) -> some View {
        Text(text)
            .font(.system(size: tvScaled(12), weight: .bold))
            .foregroundStyle(gold ? Color.black : Theme.onAccent)
            .padding(.horizontal, tvScaled(8))
            .padding(.vertical, tvScaled(4))
            .background(gold ? Color(hex: 0xF5C451) : Theme.red, in: Capsule())
    }

    private func deleteAccount() {
        error = nil
        let password = deletePassword
        deletePassword = ""
        Task { @MainActor in
            do { try await account.deleteAccount(password: password) } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Instellingen > Abonnement

/// Plan, proef, verlengt op / loopt af op, en beheren. Alleen als Premium voor dit account aan staat of er een
/// abonnement is. Beheren: `manage == "apple"` → het scherm van Apple; `stripe` → alleen een tekst (geen link).
struct PremiumStatusRows: View {
    @ObservedObject private var ent = EntitlementsService.shared
    @ObservedObject private var store = PremiumStore.shared
    @State private var showManage = false
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        if PremiumUI181.showStatus(ent.premium) {
            let p = ent.premium
            if let line = statusLine(PremiumUI181.status(p, now: Date())) {
                Label { Text(line).foregroundStyle(Color.primary) } icon: {
                    Image(systemName: "calendar").foregroundStyle(Theme.secondary)
                }
            }
            if p?.manage == "apple" {
                manageRow
            } else if p?.manage == "stripe" {
                Text(L("Manage your subscription on the device where you started it."))
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            if p?.active != true {
                Button { Task { await store.restore(origin: "settings") } } label: {
                    HStack {
                        Label(L("Restore purchases"), systemImage: "arrow.clockwise")
                        Spacer(minLength: 8)
                        if store.busy { ProgressView() }
                    }
                }
                .disabled(store.busy)
                .alert(item: store.binding(for: "settings")) { m in
                    Alert(title: Text(m.text), dismissButton: .default(Text(L("OK"))))
                }
            }
        }
    }

    @ViewBuilder private var manageRow: some View {
        #if os(iOS)
        Button { showManage = true } label: {
            Label(L("Manage subscription"), systemImage: "creditcard")
        }
        .manageSubscriptionsSheet(isPresented: $showManage)
        .onChange(of: showManage) { _, open in
            if !open { Task { await ent.refresh(force: true) } }
        }
        #elseif os(macOS)
        Button { openURL(PremiumStore.appleSubscriptionsURL) } label: {
            Label(L("Manage subscription"), systemImage: "creditcard")
        }
        #else
        Text(L("Manage your subscription in Settings > Users and Accounts on this Apple TV, or on your iPhone."))
            .font(.footnote).foregroundStyle(Theme.secondary)
        #endif
    }

    private func statusLine(_ s: PremiumUI181.Status) -> String? {
        switch s {
        case .lifetime: return nil   // PlanRow toont Lifetime al
        case .trial(let plan, let until, let renews):
            return renews ? L("%@: free trial until %@, then it renews", PremiumText.planName(plan), LifetimeDate.text(until))
                          : L("%@: free trial until %@, will not renew", PremiumText.planName(plan), LifetimeDate.text(until))
        case .renews(let plan, let on):
            return L("%@: renews on %@", PremiumText.planName(plan), LifetimeDate.text(on))
        case .ends(let plan, let on):
            return L("%@: ends on %@", PremiumText.planName(plan), LifetimeDate.text(on))
        case .none:
            return ent.premium?.enabled == true ? L("No active plan") : nil
        }
    }
}
