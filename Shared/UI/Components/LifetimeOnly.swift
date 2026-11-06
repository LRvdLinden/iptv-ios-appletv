import SwiftUI

/// Build 167: Bingr wordt alleen Lifetime (zie Shared/Account/Build167.swift en docs/ACCOUNT.md).
/// - `ActivateLifetimeView`: schermvullend bij `access == "activate"`; gegevens blijven bewaard.
/// - `LifetimeAnnouncementCard`: "Bingr wordt Lifetime op <datum>" vóór de overgang (Home en Instellingen).
/// - `LifetimePurchaseRows`: Koop Lifetime en Herstel aankopen in Instellingen > Abonnement.
/// Apple: nooit een kortingscode, korting, prijs van het web, link of QR-code naar de betaalpagina. Alleen StoreKit
/// (`displayPrice`) en, achter de flag, de EU External Purchase Link met het informatieblad van Apple.

enum LifetimeDate {
    /// De overgang is 00:00 Europe/Amsterdam; zo staat de datum ook in de mail en op de site.
    static func text(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        f.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return f.string(from: d)
    }
}

/// Een brede knop zoals op de inlogschermen.
private struct WideButton: View {
    let title: String
    let icon: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: tvScaled(16), weight: .semibold))
                .foregroundStyle(prominent ? Theme.onAccent : (destructive ? Theme.alert : .white))
                .frame(maxWidth: .infinity)
                .padding(.vertical, tvScaled(12))
                .background(prominent ? Theme.red : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: tvScaled(6)))
                .contentShape(Rectangle())
        }
        .cardButton()
    }
}

/// "Koop Lifetime · € 4,99" (prijs alleen uit StoreKit).
@MainActor private func buyTitle(_ store: LifetimeStore) -> String {
    if let p = store.product?.displayPrice { return L("Buy Lifetime · %@", p) }
    return L("Buy Lifetime")
}

// MARK: - Activeer Lifetime

struct ActivateLifetimeView: View {
    @EnvironmentObject var account: AccountService
    @ObservedObject private var ent = EntitlementsService.shared
    @ObservedObject private var store = LifetimeStore.shared
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    /// H1: huidig wachtwoord voor "Account verwijderen" (alleen in het geheugen)
    @State private var deletePassword = ""
    @State private var error: String?
    @State private var showSupport = false

    private var buttons: LifetimeUI167.ActivateButtons {
        LifetimeUI167.activateButtons(ent.lifetimeState, productLoaded: store.productLoaded,
                                      euLinkAvailable: store.euLinkAvailable)
    }

    var body: some View {
        ZStack {
            AuthBackdrop()
            ScrollView {
                VStack(spacing: tvScaled(24)) {
                    BingrLogo(size: tvScaled(34)).padding(.top, tvScaled(24))
                    card
                }
                .padding(.horizontal, Theme.edge)
                .padding(.bottom, tvScaled(32))
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            await store.prepare()
            await ent.refreshUnlessRecent(60)
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
        .alert(item: store.binding(for: "activate")) { m in
            Alert(title: Text(m.text), dismissButton: .default(Text(L("OK"))))
        }
    }

    private var card: some View {
        let b = buttons
        return VStack(alignment: .leading, spacing: tvScaled(16)) {
            HStack(spacing: tvScaled(12)) {
                LifetimeBadge(size: tvScaled(34))
                Text(L("Activate Lifetime"))
                    .font(.system(size: tvScaled(28), weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Bingr is now Lifetime only. Your servers, lists, profiles and settings are saved and come back as soon as your account has Lifetime."))
                .font(.system(size: tvScaled(15)))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if b.notActivatedOnly {
                Label(L("Your account has not been activated yet."), systemImage: "info.circle")
                    .font(.system(size: tvScaled(15), weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = account.email {
                Text(L("Signed in as %@", email))
                    .font(.system(size: tvScaled(13)))
                    .foregroundStyle(Theme.secondary)
            }

            VStack(spacing: tvScaled(10)) {
                if b.buy {
                    WideButton(title: buyTitle(store), icon: "cart", prominent: true) {
                        Task { await store.purchase(origin: "activate") }
                    }
                }
                #if os(iOS)
                if b.euLink {
                    WideButton(title: L("Continue to bingr.online"), icon: "safari") {
                        Task { await store.openEULink() }
                    }
                }
                #endif
                if b.restore {
                    WideButton(title: L("Restore purchases"), icon: "arrow.clockwise") {
                        Task { await store.restore(origin: "activate") }
                    }
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
            }
            .disabled(store.busy || account.isBusy)
            .padding(.top, tvScaled(6))

            if store.busy || account.isBusy {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: tvScaled(13), weight: .medium))
                    .foregroundStyle(AuthForm.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(tvScaled(30))
        .frame(maxWidth: tvScaled(560))
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.08), lineWidth: 1))
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

// MARK: - Aankondiging

/// "Bingr wordt Lifetime op <datum>" (of, na de overgang in de proefperiode, "Je proefperiode loopt tot <datum>"),
/// met de koopknop als `iap.apple`. Geen code en geen korting. `dismissible`: op Home te verbergen (per datum).
/// `buyButton`: false in Instellingen (daar staan Koop en Herstel als eigen rijen).
struct LifetimeAnnouncementCard: View {
    var dismissible = false
    var buyButton = true
    @ObservedObject private var ent = EntitlementsService.shared
    @ObservedObject private var store = LifetimeStore.shared
    @AppStorage("lifetime167.hidden") private var hidden = ""

    var body: some View {
        if let a = LifetimeUI167.announcement(ent.lifetimeState, now: Date()), !(dismissible && hidden == key(a)) {
            card(a)
                .task { await store.prepare() }
                .alert(item: store.binding(for: "card")) { m in
                    Alert(title: Text(m.text), dismissButton: .default(Text(L("OK"))))
                }
        }
    }

    private func key(_ a: LifetimeUI167.Announcement) -> String {
        switch a {
        case .cutover(let d): return "c\(Int(d.timeIntervalSince1970))"
        case .trial(let d): return "t\(Int(d.timeIntervalSince1970))"
        }
    }

    private func card(_ a: LifetimeUI167.Announcement) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            HStack(alignment: .top, spacing: tvScaled(10)) {
                LifetimeBadge(size: tvScaled(26))
                VStack(alignment: .leading, spacing: tvScaled(4)) {
                    Text(title(a))
                        .font(.system(size: tvScaled(16), weight: .bold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(a))
                        .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: tvScaled(10)) {
                if buyButton && LifetimeUI167.showBuy(ent.lifetimeState, productLoaded: store.productLoaded) {
                    NetflixButton(title: buyTitle(store), icon: "cart", kind: .accent) {
                        Task { await store.purchase(origin: "card") }
                    }
                    .disabled(store.busy)
                }
                if dismissible {
                    NetflixButton(title: L("Hide"), icon: "xmark", kind: .secondary) { hidden = key(a) }
                }
            }
        }
        .padding(tvScaled(14))
        .frame(maxWidth: tvScaled(640), alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color(hex: 0xF5C451).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func title(_ a: LifetimeUI167.Announcement) -> String {
        switch a {
        case .cutover(let d): return L("Bingr is going Lifetime on %@", LifetimeDate.text(d))
        case .trial(let d): return L("Your trial runs until %@", LifetimeDate.text(d))
        }
    }

    private func subtitle(_ a: LifetimeUI167.Announcement) -> String {
        switch a {
        case .cutover: return L("After that, you need Lifetime to keep watching. Your servers, lists and profiles stay saved.")
        case .trial: return L("Then you need Lifetime to keep watching. Your servers, lists and profiles stay saved.")
        }
    }
}

// MARK: - Instellingen > Abonnement

/// Koop Lifetime en Herstel aankopen (alleen als de server `iap.apple` meldt, op een gratis account). Rijen voor een
/// `List`-sectie; de melding hangt aan de rij Herstel (die er altijd is als er een koopknop is).
struct LifetimePurchaseRows: View {
    @ObservedObject private var ent = EntitlementsService.shared
    @ObservedObject private var store = LifetimeStore.shared

    var body: some View {
        if LifetimeUI167.showRestore(ent.lifetimeState) {
            if LifetimeUI167.showBuy(ent.lifetimeState, productLoaded: store.productLoaded) {
                Button { Task { await store.purchase(origin: "settings") } } label: {
                    Label { Text(buyTitle(store)) } icon: { LifetimeBadge(size: tvScaled(22)) }
                }
                .disabled(store.busy)
            }
            Button { Task { await store.restore(origin: "settings") } } label: {
                HStack {
                    Label(L("Restore purchases"), systemImage: "arrow.clockwise")
                    Spacer(minLength: 8)
                    if store.busy { ProgressView() }
                }
            }
            .disabled(store.busy)
            .task { await store.prepare() }
            .alert(item: store.binding(for: "settings")) { m in
                Alert(title: Text(m.text), dismissButton: .default(Text(L("OK"))))
            }
        }
    }
}
