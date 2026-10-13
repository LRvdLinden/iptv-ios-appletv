import SwiftUI

/// Inlogscherm (verplicht), zie docs/ACCOUNT.md.
/// iPhone, iPad en Mac: Netflix-stijl kaart met e-mail en wachtwoord.
/// Apple TV: links inloggen met je telefoon (QR + code), rechts "Inloggen met e-mail".
struct AuthView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var account: AccountService
    @State private var welcome: String?
    @State private var showEmail = false
    @State private var registering = false

    var body: some View {
        ZStack {
            AuthBackdrop()
            if !Secrets.accountsConfigured {
                notConfigured
            } else if account.isSignedIn && account.deviceLimit != nil {
                // apparaatlimiet van de server (build 51: 15): eerst een apparaat verwijderen (of Cancel = uitloggen)
                TooManyDevicesView { proceed() }.transition(.opacity)
            } else if let welcome {
                signedInBanner(welcome)
            } else if registering {
                VStack(spacing: tvScaled(22)) {
                    BingrLogo(size: tvScaled(38))
                    ProgressView().tint(.white).scaleEffect(1.3)
                }
            } else {
                content
            }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            guard signedIn else { return }
            finish()
        }
        .onAppear {
            if Secrets.accountsConfigured && account.isSignedIn { finish() }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        tvLayout
            .fullScreenCover(isPresented: $showEmail) {
                ZStack {
                    AuthBackdrop()
                    ScrollView {
                        AuthForm()
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                    }
                }
                .environmentObject(account)
            }
        #else
        ScrollView {
            VStack(spacing: 28) {
                BingrLogo(size: 38).padding(.top, 24)
                AuthForm()
            }
            .padding(.horizontal, Theme.edge)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private func finish() {
        showEmail = false
        #if os(tvOS)
        account.stopTVLogin()
        #endif
        guard welcome == nil, !registering else { return }
        registering = true
        Task { @MainActor in
            // na elke geslaagde login: dit apparaat registreren (limiet van de server). Limiet → "Too many devices".
            // Een netwerkfout blokkeert niet: de registratie wordt dan bij de volgende heartbeat opnieuw geprobeerd.
            let r = await account.registerDevice()
            registering = false
            guard account.isSignedIn, r != .limit else { return }
            proceed()
        }
    }

    /// Apparaat geregistreerd → profielen synchroniseren, dan "Wie kijkt er?".
    private func proceed() {
        guard welcome == nil, account.isSignedIn else { return }
        withAnimation(.easeInOut(duration: 0.3)) { welcome = account.email ?? "" }
        Task { @MainActor in
            // profielen, servers en alle overige gegevens (Trakt, OpenSubtitles, instellingen, lijsten, voortgang,
            // pincodes, herinneringen) van de account ophalen/migreren (samen max. 8 s; fouten zijn stil), dan "Wie kijkt er?"
            let started = Date()
            let sync = Task { @MainActor in
                async let profiles: Void = ProfileSync.shared.syncNow()
                async let sources: Void = SourceSync.shared.syncNow()
                _ = await (profiles, sources)
                // na de profielen: per profiel staan de gegevens in `profile.<id>`
                await StateSync.shared.syncNow()
            }
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                sync.cancel()
            }
            await sync.value
            timeout.cancel()
            let left = 1.4 - Date().timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            app.authFinished()
        }
    }

    private func signedInBanner(_ mail: String) -> some View {
        VStack(spacing: tvScaled(18)) {
            BingrLogo(size: tvScaled(34))
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: tvScaled(44)))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.red)
            Text(L("Signed in as %@", mail))
                .font(.system(size: tvScaled(18), weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.edge)
        .transition(.opacity)
    }

    /// Build zonder SUPABASE_URL/SUPABASE_ANON_KEY: alleen dan zonder account verder.
    private var notConfigured: some View {
        VStack(spacing: tvScaled(22)) {
            BingrLogo(size: tvScaled(38))
            VStack(spacing: tvScaled(18)) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: tvScaled(40)))
                    .foregroundStyle(Theme.secondary)
                Text(L("Accounts are not configured in this build."))
                    .font(.system(size: tvScaled(17), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                AuthPrimaryButton(title: L("Continue without account"), busy: false) {
                    app.authFinished(skipped: true)
                }
            }
            .padding(tvScaled(28))
            .frame(maxWidth: tvScaled(440))
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        }
        .padding(Theme.edge)
    }

    // MARK: Apple TV

    #if os(tvOS)
    private var tvLayout: some View {
        VStack(spacing: 30) {
            HStack {
                BingrLogo(size: 48)
                Spacer()
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 70) {
                TVPhoneLogin()
                    .frame(maxWidth: .infinity)
                VStack(spacing: 24) {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2, height: 230)
                    Text(L("OR")).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.secondary)
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2, height: 230)
                }
                VStack(spacing: 30) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.secondary)
                    AuthPrimaryButton(title: L("Sign in with email"), busy: false) { showEmail = true }
                        .frame(width: 520)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }
    #endif
}

#if os(tvOS)
/// Links op de tv: QR-code + code, ververst vanzelf als de code verloopt.
private struct TVPhoneLogin: View {
    @EnvironmentObject var account: AccountService

    var body: some View {
        VStack(spacing: 22) {
            Text(L("Sign in with your phone"))
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            Text(L("Scan the QR code with your phone's camera"))
                .font(.system(size: 26))
                .foregroundStyle(Theme.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.white)
                if let url = account.tvURL, let qr = QRCode.image(url) {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().padding(16)
                } else {
                    ProgressView().tint(.black)
                }
            }
            .frame(width: 300, height: 300)
            (Text(L("Or go to")) + Text(" bingr.online/koppelen ").bold().foregroundColor(.white) + Text(L("and enter this code:")))
                .font(.system(size: 26))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Text(account.tvCode.map { AccountService.displayCode($0) } ?? "–––-–––")
                .font(.system(size: 64, weight: .heavy, design: .monospaced))
                .kerning(8)
                .foregroundStyle(.white)
                .padding(.horizontal, 30).padding(.vertical, 8)
                .background(Theme.elevated.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 14) {
                ProgressView().tint(Theme.red)
                Text(account.tvError ?? L("Waiting for confirmation…"))
                    .font(.system(size: 24))
                    .foregroundStyle(account.tvError == nil ? Theme.secondary : AuthForm.errorColor)
            }
        }
        .onAppear { account.startTVLogin() }
        .onDisappear { account.stopTVLogin() }
    }
}
#endif

/// Kaart met e-mail en wachtwoord: inloggen, account maken, wachtwoord vergeten.
struct AuthForm: View {
    enum Mode { case signIn, signUp, reset }
    enum Field: Hashable { case email, password }

    @EnvironmentObject var account: AccountService
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var error: String?
    @State private var info: String?
    @FocusState private var focus: Field?

    static let errorColor = Color(hex: 0xE87C03)

    private var title: String {
        switch mode {
        case .signIn: return L("Sign In")
        case .signUp: return L("Create account")
        case .reset: return L("Reset password")
        }
    }

    private var buttonTitle: String {
        switch mode {
        case .signIn: return L("Sign In")
        case .signUp: return L("Create account")
        case .reset: return L("Send reset link")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(16)) {
            Text(title)
                .font(.system(size: tvScaled(28), weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, tvScaled(4))

            emailField
            if mode != .reset { passwordField }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: tvScaled(13), weight: .medium))
                    .foregroundStyle(Self.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let info {
                Label(info, systemImage: "envelope.badge")
                    .font(.system(size: tvScaled(13), weight: .medium))
                    .foregroundStyle(Theme.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AuthPrimaryButton(title: buttonTitle, busy: account.isBusy) { submit() }
                .padding(.top, tvScaled(8))

            if mode == .signIn {
                Button { switchMode(.reset) } label: {
                    Text(L("Forgot password?"))
                        .font(.system(size: tvScaled(14)))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .plainTVButton()
                .frame(maxWidth: .infinity)
            }

            Group {
                if mode == .signIn {
                    Button { switchMode(.signUp) } label: {
                        footerLabel(L("New to Bingr?"), L("Sign up now."))
                    }
                } else {
                    Button { switchMode(.signIn) } label: {
                        footerLabel(L("Already have an account?"), L("Sign in."))
                    }
                }
            }
            .plainTVButton()
            .padding(.top, tvScaled(10))
        }
        .padding(tvScaled(30))
        .frame(maxWidth: tvScaled(440))
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .disabled(account.isBusy)
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private func footerLabel(_ lead: String, _ action: String) -> some View {
        (Text(lead + " ").foregroundColor(Theme.secondary) + Text(action).bold().foregroundColor(.white))
            .font(.system(size: tvScaled(15)))
            .multilineTextAlignment(.leading)
    }

    // MARK: velden

    private var emailField: some View {
        TextField(L("Email"), text: $email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .authContentType(password: false, newPassword: false)
            .focused($focus, equals: .email)
            .submitLabel(.next)
            .onSubmit { if mode == .reset { submit() } else { focus = .password } }
            .modifier(AuthFieldStyle())
    }

    private var passwordField: some View {
        HStack(spacing: tvScaled(10)) {
            Group {
                if showPassword {
                    TextField(L("Password"), text: $password)
                } else {
                    SecureField(L("Password"), text: $password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .authContentType(password: true, newPassword: mode == .signUp)
            .focused($focus, equals: .password)
            .submitLabel(.go)
            .onSubmit { submit() }
            #if os(tvOS)
            .modifier(AuthFieldStyle())
            #endif

            Button { showPassword.toggle() } label: {
                Text(showPassword ? L("Hide") : L("Show"))
                    .font(.system(size: tvScaled(13), weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .plainTVButton()
        }
        #if !os(tvOS)
        .modifier(AuthFieldStyle())
        #endif
    }

    // MARK: acties

    private func switchMode(_ m: Mode) {
        error = nil
        info = nil
        mode = m
    }

    private func submit() {
        guard !account.isBusy else { return }
        error = nil
        info = nil
        let m = mode
        Task { @MainActor in
            do {
                switch m {
                case .signIn:
                    try await account.signIn(email: email, password: password)
                case .signUp:
                    let r = try await account.signUp(email: email, password: password)
                    if r == .confirmEmail {
                        mode = .signIn
                        info = L("Check your inbox to confirm your email address, then sign in.")
                    }
                case .reset:
                    info = try await account.recover(email: email)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Rode volle knop met spinner tijdens het laden.
struct AuthPrimaryButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(.white) }
            }
            .font(.system(size: tvScaled(16), weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, tvScaled(13))
            .background(Theme.red, in: RoundedRectangle(cornerRadius: tvScaled(6)))
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(TVLiftStyle(scale: 1.05))
        #else
        .buttonStyle(PressableStyle())
        #endif
    }
}

/// Donker invoerveld zoals bij Netflix (op Apple TV het systeemveld).
private struct AuthFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .font(.system(size: 30))
        #else
        content
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(Color(hex: 0x333333), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
        #endif
    }
}

private extension View {
    /// Laat de wachtwoordbeheerder meedoen (e-mail als gebruikersnaam).
    @ViewBuilder func authContentType(password: Bool, newPassword: Bool) -> some View {
        #if os(macOS)
        self.textContentType(password ? NSTextContentType.password : NSTextContentType.username)
        #else
        self.textContentType(password ? (newPassword ? UITextContentType.newPassword : UITextContentType.password)
                                      : UITextContentType.username)
        #endif
    }
}

/// Achtergrond: gedimde, licht vervaagde collage van covers uit de bibliotheek, anders een donker verloop met rood.
struct AuthBackdrop: View {
    @State private var posters: [URL] = SplashPosters.load().compactMap { $0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !posters.isEmpty {
                    collage(geo.size)
                        .rotationEffect(.degrees(-8))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 3)
                        .opacity(0.5)
                }
                RadialGradient(colors: [Theme.red.opacity(0.38), .clear], center: .top,
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.7)
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.4), .black.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func collage(_ size: CGSize) -> some View {
        let columns = max(4, Int(size.width / tvScaled(100)))
        let w = size.width * 1.35 / CGFloat(columns)
        let rows = Int(size.height * 1.35 / (w * 1.5)) + 2
        let gap = tvScaled(6)
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { c in
                        RemoteImage(url: posters[(r * columns + c) % posters.count], maxPixel: 300)
                            .frame(width: w, height: w * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: tvScaled(4)))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
