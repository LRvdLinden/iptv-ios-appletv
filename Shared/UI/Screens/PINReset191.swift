import SwiftUI

/// Build 191: "Pincode vergeten?" met een echte reset. Het wachtwoord van het Bingr-account wordt gecontroleerd met de
/// bestaande inlogroute (`AccountService.signIn`); daarna gaat de pincode van dat profiel weg (gelijk aan "Pincode
/// verwijderen"). Het wachtwoord wordt nergens bewaard of gelogd en na gebruik meteen gewist.
struct PINResetView191: View {
    let profileID: UUID?
    /// Sluit ook het pincodescherm eronder
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var account = AccountService.shared
    @ObservedObject private var store = CloudStore.shared
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    private var target: UUID? { PINReset191.target(profile: profileID, main: store.mainProfileID) }
    private var isMain: Bool { target == nil || target == store.mainProfileID }
    private var canReset: Bool {
        PINReset191.available(signedIn: Secrets.accountsConfigured && account.isSignedIn, email: account.email)
    }

    var body: some View {
        VStack(spacing: tvScaled(18)) {
            Image(systemName: done ? "checkmark.circle.fill" : "lock.open").font(.system(size: tvScaled(44)))
                .foregroundStyle(done ? Theme.green : Theme.red)
            Text(L("Forgot your PIN?")).font(.system(size: tvScaled(22), weight: .bold)).multilineTextAlignment(.center)
            if done {
                Text(isMain
                     ? L("The PIN is removed and parental controls are off. Choose a new PIN in Settings.")
                     : L("The PIN of this profile is removed. Choose a new PIN in Settings."))
                    .foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button(L("OK")) { dismiss(); onFinished() }.padding(.top, 8)
            } else if canReset {
                Text(isMain
                     ? L("Enter the password of your Bingr account. The PIN is then removed and parental controls are turned off. Choose a new PIN in Settings.")
                     : L("Enter the password of your Bingr account. The PIN of this profile is then removed. Choose a new PIN in Settings."))
                    .foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                SecureField(L("Password"), text: $password)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .textContentType(.password)
                    .frame(maxWidth: tvScaled(420))
                    .onSubmit { reset() }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.red).multilineTextAlignment(.center) }
                if busy { ProgressView() }
                Button(L("Remove PIN")) { reset() }
                    .disabled(!PINReset191.canSubmit(password: password, busy: busy))
                Button(L("Cancel")) { dismiss() }.foregroundStyle(Theme.secondary)
            } else {
                Text(L("A PIN cannot be recovered in the app. Contact Bingr Support at support.bingr.online and we will help you further."))
                    .foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                #if !os(tvOS)
                Button(L("Open Support")) { openURL(Support.url) }
                #endif
                Button(L("OK")) { dismiss() }
            }
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        .interactiveDismissDisabled(busy)
    }

    private func reset() {
        guard PINReset191.canSubmit(password: password, busy: busy), let mail = account.email else { return }
        let typed = password
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await account.signIn(email: mail, password: typed)
                password = ""
                if let id = target { ParentalControl.shared.setPIN(nil, profile: id) } else { ParentalControl.shared.setPIN(nil) }
                if PINReset191.turnsOffParentalLock(isMain: isMain) { store.updateParental { $0.enabled = false } }
                ParentalControl.shared.clearAttempts()
                ParentalControl.shared.lock()
                done = true
            } catch {
                password = ""
                self.error = error.localizedDescription
            }
        }
    }
}
