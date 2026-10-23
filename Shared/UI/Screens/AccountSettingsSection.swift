import SwiftUI

/// Mijn Bingr → "Account" (voor het hoofdaccount en alle profielen), zie docs/ACCOUNT.md.
struct AccountSettingsSection: View {
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var store: CloudStore
    /// Build 88: "Nu aan het kijken" en de kijkgeschiedenis horen bij Lifetime
    @ObservedObject private var ent = EntitlementsService.shared
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    /// H1: huidig wachtwoord voor "Account verwijderen" (alleen in het geheugen, wordt na gebruik gewist)
    @State private var deletePassword = ""
    @State private var error: String?

    var body: some View {
        if Secrets.accountsConfigured && account.isSignedIn {
            Section {
                Label(L("Signed in as %@", account.email ?? ""), systemImage: "person.crop.circle")
                    .foregroundStyle(.white)
                NavigationLink { DevicesView() } label: {
                    Label(L("Devices"), systemImage: "laptopcomputer.and.iphone")
                }
                // tegelijk kijken (build 51): alleen voor het hoofdprofiel
                if isMain {
                    if ent.allows(.nowWatching) {
                        WatchingNowRow()
                        NavigationLink { WatchLogView() } label: {
                            Label(L("Watch history (7 days)"), systemImage: "clock.arrow.circlepath")
                        }
                    } else {
                        LifetimeLockRow(title: L("Watching now"), icon: "play.tv", feature: .nowWatching)
                        LifetimeLockRow(title: L("Watch history (7 days)"), icon: "clock.arrow.circlepath", feature: .nowWatching)
                    }
                }
                #if !os(tvOS)
                NavigationLink { LinkTVView() } label: {
                    Label(L("Link a TV"), systemImage: "tv")
                }
                #endif
                Button { confirmSignOut = true } label: {
                    Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .confirmationDialog(L("Sign out of Bingr on this device?"), isPresented: $confirmSignOut,
                                    titleVisibility: .visible) {
                    Button(L("Sign out"), role: .destructive) {
                        Task { await account.signOut() }
                    }
                    Button(L("Cancel"), role: .cancel) {}
                }
                Button(role: .destructive) { deletePassword = ""; confirmDelete = true } label: {
                    Label(L("Delete account"), systemImage: "trash")
                        .foregroundStyle(Theme.red)
                }
                // H1: bevestigen met het huidige wachtwoord (een alert, omdat een confirmationDialog geen invoerveld kan hebben)
                .alert(L("Delete your Bingr account? This can't be undone."), isPresented: $confirmDelete) {
                    SecureField(L("Password"), text: $deletePassword)
                    Button(L("Delete account"), role: .destructive) { deleteAccount() }
                    Button(L("Cancel"), role: .cancel) { deletePassword = "" }
                } message: {
                    Text(L("Enter your password to confirm."))
                }
                if account.isBusy {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(AuthForm.errorColor)
                }
            } header: {
                Text(L("Account"))
            }
            .disabled(account.isBusy)
        }
    }

    /// Hoofdprofiel (of nog geen profielen), net als in Mijn Bingr.
    private var isMain: Bool { store.isMainActive || store.profiles.isEmpty || store.activeProfileID == nil }

    private func deleteAccount() {
        error = nil
        let password = deletePassword
        deletePassword = ""
        Task { @MainActor in
            do { try await account.deleteAccount(password: password) } catch { self.error = error.localizedDescription }
        }
    }
}

#if !os(tvOS)
/// "Link a TV": de code van de tv invoeren (hoofdletters, zonder `-` en spaties).
struct LinkTVView: View {
    @EnvironmentObject var account: AccountService
    @State private var code = ""
    @State private var result: String?
    @State private var failed = false
    /// build 141: apparaat bij de code, wacht op bevestiging
    @State private var pending: AccountService.TVCodeInfo?
    @State private var pendingCode = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(L("Enter the code shown on your TV"), text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { link() }
                    .onChange(of: code) { _, v in
                        let n = AccountService.normalizeCode(v)
                        let shown = n.count > 3 ? String(n.prefix(3)) + "-" + String(n.dropFirst(3).prefix(5)) : n
                        if shown != v { code = shown }
                    }
                Button { link() } label: {
                    HStack {
                        Text(L("Link")).bold()
                        Spacer()
                        if account.isBusy { ProgressView() }
                    }
                }
                .disabled(AccountService.normalizeCode(code).count < 4 || account.isBusy)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    // build 141: waarschuwing tegen doorgestuurde codes
                    Label(L("Only enter a code that is shown on your own TV."), systemImage: "exclamationmark.shield")
                        .foregroundStyle(Theme.secondary)
                    if let result {
                        Label(result, systemImage: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? AuthForm.errorColor : Theme.green)
                    }
                }
            }
        }
        .navigationTitle(L("Link a TV"))
        .onAppear { focused = true }
        .alert(L("Give this device access?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { _ in
            Button(L("Link")) { approve(pendingCode) }
            Button(L("Cancel"), role: .cancel) { pendingCode = "" }
        } message: { info in
            Text(L("“%@” (code created %@) gets full access to your Bingr account.", deviceName(info), ageText(info.ageSeconds))
                 + "\n\n" + L("Only enter a code that is shown on your own TV. Never enter a code someone else sent you."))
        }
    }

    private func deviceName(_ i: AccountService.TVCodeInfo) -> String {
        i.label.caseInsensitiveCompare(i.device) == .orderedSame ? i.device : "\(i.label) · \(i.device)"
    }

    private func ageText(_ s: Int) -> String { s < 60 ? L("just now") : L("%d min ago", s / 60) }

    /// build 141: eerst het apparaat bij de code opvragen en laten bevestigen, pas daarna goedkeuren.
    private func link() {
        guard !account.isBusy, AccountService.normalizeCode(code).count >= 4 else { return }
        result = nil
        let c = code
        Task { @MainActor in
            do {
                let info = try await account.tvCodeInfo(code: c)
                pendingCode = c
                pending = info
            } catch {
                failed = true
                result = error.localizedDescription
            }
        }
    }

    private func approve(_ c: String) {
        pendingCode = ""
        guard !c.isEmpty else { return }
        Task { @MainActor in
            do {
                let device = try await account.approveTV(code: c)
                failed = false
                result = L("%@ is now signed in.", device)
                code = ""
            } catch {
                failed = true
                result = error.localizedDescription
            }
        }
    }
}
#endif
