import SwiftUI

/// Mijn Bingr → "Account" (voor het hoofdaccount en alle profielen), zie docs/ACCOUNT.md.
struct AccountSettingsSection: View {
    @EnvironmentObject var account: AccountService
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        if Secrets.accountsConfigured && account.isSignedIn {
            Section {
                Label(L("Signed in as %@", account.email ?? ""), systemImage: "person.crop.circle")
                    .foregroundStyle(.white)
                NavigationLink { DevicesView() } label: {
                    Label(L("Devices"), systemImage: "laptopcomputer.and.iphone")
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
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Delete account"), systemImage: "trash")
                        .foregroundStyle(Theme.red)
                }
                .confirmationDialog(L("Delete your Bingr account? This can't be undone."), isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button(L("Delete account"), role: .destructive) { deleteAccount() }
                    Button(L("Cancel"), role: .cancel) {}
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

    private func deleteAccount() {
        error = nil
        Task { @MainActor in
            do { try await account.deleteAccount() } catch { self.error = error.localizedDescription }
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
                if let result {
                    Label(result, systemImage: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? AuthForm.errorColor : Theme.green)
                }
            }
        }
        .navigationTitle(L("Link a TV"))
        .onAppear { focused = true }
    }

    private func link() {
        guard !account.isBusy, AccountService.normalizeCode(code).count >= 4 else { return }
        result = nil
        Task { @MainActor in
            do {
                let device = try await account.approveTV(code: code)
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
