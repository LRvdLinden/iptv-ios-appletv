import SwiftUI

/// Pagina's van Mijn Bingr die vanuit het profielmenu (of de lijst zelf) geopend worden.
enum MyBingrRoute: Hashable {
    case settings, account, profiles, trakt, history, collections, stats, homeLayout, network, categories
    #if os(iOS)
    case downloads
    #endif
}

/// Verzoek om Mijn Bingr te openen (nieuw id per verzoek, zodat hetzelfde verzoek nog eens werkt).
struct MyBingrRequest: Equatable {
    let id = UUID()
    let route: MyBingrRoute?
}

extension CloudStore {
    /// Hoofdprofiel (of nog geen profielen): mag profielen, server en de rest beheren — zoals in Mijn Bingr.
    var isMainOrSolo: Bool { isMainActive || profiles.isEmpty || activeProfileID == nil }
}

/// Wat je in het profielmenu kunt kiezen (build 72, zoals op bingr.online).
enum ProfileMenuAction {
    case profile(ViewerProfile)
    case switchProfile, manageProfiles, myBingr, settings, account, support, signOut
}

/// Profielmenu achter de avatar: andere profielen (direct wisselen, met pincode als die er is),
/// Wissel van profiel, Profielen beheren (alleen hoofdprofiel), Mijn Bingr, Instellingen,
/// Account en apparaten, Support (build 75) en Uitloggen. iPhone, iPad en Mac: een gewoon menu; Apple TV: een focusbaar scherm.
struct ProfileMenuButton<MenuLabel: View>: View {
    let label: () -> MenuLabel
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @ObservedObject private var account = AccountService.shared
    @State private var pinFor: ViewerProfile?
    @State private var confirmSignOut = false
    @State private var showSupport = false
    #if os(tvOS)
    @State private var showMenu = false
    #endif

    init(@ViewBuilder label: @escaping () -> MenuLabel) { self.label = label }

    private var others: [ViewerProfile] { store.profiles.filter { $0.id != store.activeProfileID } }
    private var signedIn: Bool { Secrets.accountsConfigured && account.isSignedIn }

    var body: some View {
        menu
            .accessibilityLabel(L("Profile menu"))
            .sheet(item: $pinFor) { p in
                PINPad(title: L("PIN for %@", p.name)) { pin in
                    guard ParentalControl.shared.verify(pin, profile: p.id) else { return false }
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 80_000_000); app.open(profile: p) }
                    return true
                }
            }
            .confirmationDialog(L("Sign out of Bingr on this device?"), isPresented: $confirmSignOut,
                                titleVisibility: .visible) {
                Button(L("Sign out"), role: .destructive) { Task { await account.signOut() } }
                Button(L("Cancel"), role: .cancel) {}
            }
            .supportPage(isPresented: $showSupport)
    }

    #if os(tvOS)
    private var menu: some View {
        Button { showMenu = true } label: { label() }
            .plainTVButton()
            .sheet(isPresented: $showMenu) {
                TVProfileMenu(others: others, canManage: store.isMainOrSolo && !store.profiles.isEmpty,
                              signedIn: signedIn) { action in
                    showMenu = false
                    // eerst het menu laten sluiten, dan pas een volgend scherm (pincode, bevestiging) tonen
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        perform(action)
                    }
                }
            }
    }
    #else
    private var menu: some View {
        Menu {
            if !others.isEmpty {
                Section {
                    ForEach(others) { p in
                        Button { perform(.profile(p)) } label: {
                            Label { Text(p.name) } icon: { ProfileMenuImage.image(for: p, store: store) }
                        }
                    }
                }
            }
            Section {
                Button { perform(.switchProfile) } label: { Label(L("Switch profile"), systemImage: "person.2") }
                if store.isMainOrSolo && !store.profiles.isEmpty {
                    Button { perform(.manageProfiles) } label: { Label(L("Manage profiles"), systemImage: "pencil") }
                }
                Button { perform(.myBingr) } label: { Label(L("My Bingr"), systemImage: "person") }
                Button { perform(.settings) } label: { Label(L("Settings"), systemImage: "gearshape") }
                if signedIn {
                    Button { perform(.account) } label: { Label(L("Account and devices"), systemImage: "person.crop.circle") }
                }
                Button { perform(.support) } label: { Label(L("Support"), systemImage: "questionmark.circle") }
            }
            if signedIn {
                Section {
                    Button(role: .destructive) { perform(.signOut) } label: {
                        Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        } label: { label() }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
    #endif

    private func perform(_ action: ProfileMenuAction) {
        // build 140: vanuit een kinderprofiel eerst de rekensom (KidsGate); Mijn Bingr vraagt hem zelf
        switch action {
        case .profile(let p):
            // profiel met pincode: eerst de pincode vragen (zoals bij "Wie kijkt er?")
            let go = { if ParentalControl.shared.hasPIN(profile: p.id) { pinFor = p } else { app.open(profile: p) } }
            if p.kids { go() } else { KidsGate.shared.require(go) }
        case .switchProfile: KidsGate.shared.requireSwitch { app.switchPlaylist() }
        case .manageProfiles: app.showMyBingr(.profiles)
        case .myBingr: app.showMyBingr()
        case .settings: app.showMyBingr(.settings)
        case .account: app.showMyBingr(.account)
        case .support: showSupport = true
        case .signOut: KidsGate.shared.require { confirmSignOut = true }
        }
    }
}

#if !os(tvOS)
/// Ronde avatar als afbeelding, voor in een (systeem)menu: daar passen alleen `Image`s.
@MainActor
enum ProfileMenuImage {
    private static var cache: [String: Image] = [:]

    static func image(for p: ViewerProfile, store: CloudStore) -> Image {
        let photo = store.photos[p.id]
        let key = "\(p.id.uuidString)|\(p.avatar.symbol)|\(p.avatar.colorIndex)|\(photo?.count ?? 0)"
        if let hit = cache[key] { return hit }
        let view = ZStack {
            Circle().fill(p.avatar.gradient)
            if let photo, let img = UIImage(data: photo) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                AvatarGlyph(avatar: p.avatar, size: 11)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        let r = ImageRenderer(content: view)
        r.scale = 3
        #if os(macOS)
        guard let ns = r.nsImage else { return Image(systemName: "person.crop.circle") }
        let img = Image(nsImage: ns).renderingMode(.original)
        #else
        guard let ui = r.uiImage else { return Image(systemName: "person.crop.circle") }
        let img = Image(uiImage: ui.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
        #endif
        cache[key] = img
        return img
    }
}
#endif

#if os(tvOS)
/// Apple TV: profielmenu als focusbaar scherm (afstandsbediening: omhoog/omlaag, Menu = terug).
private struct TVProfileMenu: View {
    let others: [ViewerProfile]
    let canManage: Bool
    let signedIn: Bool
    let onPick: (ProfileMenuAction) -> Void
    @EnvironmentObject var store: CloudStore
    @FocusState private var focus: Target?

    enum Target: Hashable { case profile(UUID), first }

    var body: some View {
        VStack(spacing: 34) {
            HStack(spacing: 18) {
                ProfileAvatar(size: 64)
                Text(store.activeProfile?.name ?? L("My Bingr"))
                    .font(.system(size: 34, weight: .bold))
            }
            if !others.isEmpty {
                HStack(spacing: 44) {
                    ForEach(others) { p in
                        Button { onPick(.profile(p)) } label: {
                            AvatarTile(name: p.name, avatar: p.avatar, photo: store.photos[p.id],
                                       locked: ParentalControl.shared.hasPIN(profile: p.id))
                                .frame(width: 130)
                        }
                        .profileButton()
                        .focused($focus, equals: .profile(p.id))
                    }
                }
                .padding(.vertical, 10)
                .focusSection()
            }
            VStack(spacing: 10) {
                row(L("Switch profile"), "person.2", .switchProfile).focused($focus, equals: .first)
                if canManage { row(L("Manage profiles"), "pencil", .manageProfiles) }
                row(L("My Bingr"), "person", .myBingr)
                row(L("Settings"), "gearshape", .settings)
                if signedIn { row(L("Account and devices"), "person.crop.circle", .account) }
                row(L("Support"), "questionmark.circle", .support)
                if signedIn {
                    Divider().padding(.vertical, 6)
                    row(L("Sign out"), "rectangle.portrait.and.arrow.right", .signOut, destructive: true)
                }
            }
            .frame(width: 760)
            .focusSection()
        }
        .padding(60)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                focus = others.first.map { .profile($0.id) } ?? .first
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ action: ProfileMenuAction, destructive: Bool = false) -> some View {
        Button { onPick(action) } label: {
            HStack(spacing: 22) {
                Image(systemName: icon).font(.system(size: 28, weight: .medium)).frame(width: 40)
                    .foregroundStyle(destructive ? Theme.red : Color.primary)
                Text(title).font(.system(size: 30, weight: .medium))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVMenuRowStyle())
    }
}

/// Brede menuregel: bij focus wit met zwarte tekst (zoals de systeemmenu's van Apple TV).
private struct TVMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .environment(\.colorScheme, focused ? .light : .dark)
                .padding(.horizontal, 28).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(focused ? Color.white : Color.white.opacity(0.06)))
                .scaleEffect(configuration.isPressed ? 0.98 : (focused ? 1.03 : 1))
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
#endif
