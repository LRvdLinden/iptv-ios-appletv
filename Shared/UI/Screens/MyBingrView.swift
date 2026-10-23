import SwiftUI

/// Mijn Bingr (build 72, zoals op bingr.online): bovenaan je profiel, Verder kijken en Mijn lijst;
/// daaronder de groepen Bibliotheek en Profiel. Alle andere instellingen staan onder Instellingen.
struct MyBingrView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @ObservedObject private var account = AccountService.shared
    /// Build 88: abonnement (Gratis/Lifetime) voor de slotjes
    @ObservedObject private var ent = EntitlementsService.shared
    /// Build 86: Categorieën (aantal in de rij bij Bibliotheek)
    @ObservedObject private var browse = BrowseIndexStore.shared
    @AppStorage("ui.showMovies") private var showMovies = true
    @AppStorage("ui.showSeries") private var showSeries = true
    @State private var path: [MyBingrRoute] = []
    @State private var showSupport = false
    #if os(tvOS)
    /// De footer is niet focusbaar: bij de laatste rij er zelf naartoe scrollen
    @FocusState private var lastRowFocused: Bool
    #endif
    private static let footerID = "bingr.footer"

    private var isMain: Bool { store.isMainOrSolo }
    private var signedIn: Bool { Secrets.accountsConfigured && account.isSignedIn }
    /// Build 140: als blad geopend (iPhone, iPad en Mac; daar is Mijn Bingr geen tabblad meer): met sluitknop
    var modal = false
    @Environment(\.dismiss) private var dismiss
    /// Build 140: kinderprofiel: de rekensom is voor dit bezoek opgelost
    @State private var unlocked = false

    private var gated: Bool { (store.activeProfile?.kids ?? false) && !unlocked && !Screenshots.isActive }

    var body: some View {
        Group {
            if gated {
                KidsGateInline {
                    unlocked = true
                    KidsGate.shared.adultSession = true
                }
                .overlay(alignment: .topTrailing) { closeButton }
            } else {
                content
            }
        }
        .onChange(of: store.activeProfileID) { _, _ in
            unlocked = false
            KidsGate.shared.adultSession = false
        }
        .onDisappear {
            unlocked = false
            KidsGate.shared.adultSession = false
        }
    }

    @ViewBuilder private var closeButton: some View {
        #if !os(tvOS)
        if modal {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close"))
            .padding(16)
        }
        #endif
    }

    private var content: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    Section { MyBingrHeader() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    librarySection
                    profileSection
                    // Build 47: app-icoon, versie en copyright helemaal onderaan
                    Section { AboutFooter() }
                        .id(Self.footerID)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                #if os(tvOS)
                .onChange(of: lastRowFocused) { _, f in
                    guard f else { return }
                    withAnimation { proxy.scrollTo(Self.footerID, anchor: .bottom) }
                }
                #endif
            }
            .navigationTitle(store.activeProfile?.name ?? L("My Bingr"))
            .navigationDestination(for: MyBingrRoute.self) { destination($0) }
            #if !os(tvOS)
            .toolbar {
                if modal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Done")) { dismiss() }
                    }
                }
            }
            #endif
        }
        .supportPage(isPresented: $showSupport)
        .task(id: playlists.libraryVersion) { browse.refresh(playlists) }
        .onAppear(perform: applyRequest)
        .onChange(of: app.myBingrRequest) { _, _ in applyRequest() }
    }

    /// Verzoek uit het profielmenu: terug naar Mijn Bingr, of meteen naar een pagina.
    private func applyRequest() {
        guard let r = app.myBingrRequest else { return }
        app.myBingrRequest = nil
        path = r.route.map { [$0] } ?? []
    }

    // MARK: Bibliotheek

    private var librarySection: some View {
        Section {
            #if os(iOS)
            row(.downloads, L("Downloads"), "arrow.down.circle")
            #endif
            row(.history, L("Watch history"), "clock.arrow.circlepath", count: store.history.filter { store.belongsToActive($0.profileID) }.count)
            row(.collections, L("Collections"), "rectangle.stack", count: store.activeCollections.count)
            // build 86: Categorieën (genres en de categorieën van je server), eerder een eigen tabblad
            if showMovies || showSeries {
                let n = browse.index.genres.count + browse.index.server.count
                row(.categories, L("Categories"), "square.grid.2x2", count: n > 0 ? n : nil)
            }
            // kijkstatistieken (build 68): per week, maand of jaar, via de Bingr-account
            if signedIn { row(.stats, L("Statistics"), "chart.bar.xaxis", locked: !ent.allows(.stats)) }
            if isMain {
                traktRow
                row(.network, L("NAS & network (SMB/DLNA)"), "externaldrive.connected.to.line.below")
            }
        } header: { Text(L("Library")) } footer: {
            Text(L("Watch history is kept per profile. Plex, Jellyfin and Emby can be added as a playlist."))
        }
    }

    private var traktRow: some View {
        NavigationLink(value: MyBingrRoute.trakt) {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Trakt")
                        if trakt.isLoggedIn, let u = trakt.username {
                            Text(u).font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.rectangle.stack.fill").foregroundStyle(Color.purple)
                }
                Spacer(minLength: 8)
                if !ent.allows(.trakt) { LifetimePill() }
                else { Text(traktStatus).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
        }
    }

    private var traktStatus: String {
        if !trakt.isLoggedIn { return L("Not connected") }
        if trakt.isSyncing { return L("Syncing…") }
        if trakt.lastError != nil { return L("Sync failed") }
        return trakt.lastRefresh.map { L("Trakt synced %@", $0.formatted(date: .omitted, time: .shortened)) } ?? ""
    }

    // MARK: Profiel

    private var profileSection: some View {
        Section {
            if isMain {
                row(.profiles, L("Manage profiles"), "person.2", count: store.profiles.count)
            }
            row(.homeLayout, L("Home screen"), "rectangle.grid.1x2")
            row(.settings, L("Settings"), "gearshape")
            if signedIn {
                row(.account, L("Account and devices"), "person.crop.circle")
                // build 88: abonnement (Gratis of Lifetime) met de limieten
                PlanRow()
            }
            // build 75: support.bingr.online, onder Account en apparaten (ook zonder Bingr-account)
            markLast(supportRow)
        } header: { Text(L("Profile")) }
    }

    private var supportRow: some View {
        Button { showSupport = true } label: {
            HStack {
                Label { Text(L("Support")).foregroundStyle(Color.primary) } icon: { Image(systemName: "questionmark.circle") }
                Spacer(minLength: 8)
                #if !os(tvOS)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                #endif
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private func markLast<V: View>(_ v: V) -> some View {
        #if os(tvOS)
        v.focused($lastRowFocused)
        #else
        v
        #endif
    }

    private func row(_ route: MyBingrRoute, _ title: String, _ icon: String, count: Int? = nil, locked: Bool = false) -> some View {
        NavigationLink(value: route) {
            HStack {
                Label(title, systemImage: icon)
                Spacer(minLength: 8)
                if locked { LifetimePill() }
                if let count { Text(verbatim: "\(count)").foregroundStyle(Theme.secondary) }
            }
        }
    }

    @ViewBuilder private func destination(_ r: MyBingrRoute) -> some View {
        switch r {
        case .settings: AppSettingsView()
        case .account: AccountDevicesView()
        case .profiles: ProfilesManageView()
        case .trakt: TraktSettingsView()
        case .history: HistoryView()
        case .collections: CollectionsView()
        case .stats: StatsView()
        case .homeLayout: HomeLayoutView()
        case .network: NetworkBrowserView()
        case .categories: BrowseCategoriesView(pushed: true)
        #if os(iOS)
        case .downloads: DownloadsView()
        #endif
        }
    }
}

/// Mijn Bingr → Profielen beheren (alleen het hoofdaccount maakt profielen aan en beheert ze).
struct ProfilesManageView: View {
    @EnvironmentObject var store: CloudStore
    @State private var editingProfile: ViewerProfile?
    @State private var addingProfile = false

    var body: some View {
        List { profilesSection }
            .navigationTitle(L("Manage profiles"))
            .sheet(item: $editingProfile) { ProfileEditView(existing: $0) }
            .sheet(isPresented: $addingProfile) { ProfileEditView(existing: nil) }
    }

    /// Alle kijkprofielen (alleen het hoofdaccount maakt ze aan en beheert ze).
    private var profilesSection: some View {
        Section {
            ForEach(store.profiles) { p in
                Button { editingProfile = p } label: {
                    HStack(spacing: 12) {
                        AvatarTile(name: "", avatar: p.avatar, photo: store.photos[p.id]).frame(width: tvScaled(34))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(.white)
                            Text(store.isMain(p) ? L("Main account") : (p.ageLimit.map { L("Up to %d years", $0) } ?? L("Profile")))
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(Theme.secondary)
                    }
                }
            }
            if store.profiles.count < 8 {
                Button { addingProfile = true } label: { Label(L("Add profile"), systemImage: "person.badge.plus") }
            }
        } header: { Text(L("Profiles")) } footer: {
            Text(L("Each profile uses the same server, with its own My List, Continue watching, favorites, history and age limit."))
        }
    }
}

/// Mijn Bingr → Trakt: inloggen, synchroniseren en de Trakt-instellingen.
struct TraktSettingsView: View {
    @EnvironmentObject var trakt: TraktSync
    @ObservedObject private var account = AccountService.shared
    /// Build 88: Trakt hoort bij Lifetime
    @ObservedObject private var ent = EntitlementsService.shared
    @AppStorage("trakt.scrobble") private var traktScrobble = true
    @AppStorage("trakt.askRating") private var traktAskRating = true
    @State private var showTraktLogin = false
    @State private var setup = false

    var body: some View {
        List { traktSection }
            .navigationTitle(Text(verbatim: "Trakt"))
            .sheet(isPresented: $showTraktLogin) { TraktLoginView() }
            .sheet(isPresented: $setup) {
                ConnectionsSetupView(focus: .trakt) {
                    if Secrets.traktReady { Task { try? await Task.sleep(nanoseconds: 500_000_000); showTraktLogin = true } }
                }
            }
    }

    /// Trakt: gewoon inloggen (koppelcode en QR). Ontbreekt de sleutel, dan eerst de server
    /// proberen; alleen als hij er dan nog niet is "Koppelingen instellen".
    private func signIn() {
        if Secrets.traktReady { showTraktLogin = true; return }
        Task { @MainActor in
            await account.fetchConfig()
            if Secrets.traktReady { showTraktLogin = true } else { setup = true }
        }
    }

    private var traktSection: some View {
        Section {
            if trakt.isLoggedIn {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.elevated)
                        if let a = trakt.avatar { RemoteImage(url: a).clipShape(Circle()) }
                        else { Image(systemName: "person.fill").foregroundStyle(Theme.secondary) }
                    }
                    .frame(width: tvScaled(52), height: tvScaled(52))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trakt.displayName ?? trakt.username ?? "Trakt").font(.headline)
                        if let u = trakt.username { Text(u).font(.subheadline).foregroundStyle(Theme.secondary) }
                    }
                }
                Toggle(isOn: $traktScrobble) { Label(L("Sync playback progress"), systemImage: "playpause") }
                Toggle(isOn: $traktAskRating) { Label(L("Ask for ratings"), systemImage: "star") }
                LabeledContent(L("Watched"), value: L("%d movies · %d episodes", trakt.watchedMovies.count,
                                                      trakt.watchedEpisodes.values.reduce(0) { $0 + $1.count }))
                if let d = trakt.lastRefresh {
                    LabeledContent(L("Last synced"), value: d.formatted(date: .omitted, time: .shortened))
                }
                if let m = trakt.lastScrobble {
                    LabeledContent(L("Last sent"), value: m + (trakt.lastScrobbleDate.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                }
                Button { Task { await trakt.refresh(force: true) } } label: {
                    HStack {
                        Label(trakt.isSyncing ? L("Syncing…") : trakt.justSynced ? L("Up to date") : L("Sync now"),
                              systemImage: trakt.justSynced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        Spacer()
                        if trakt.isSyncing { ProgressView() }
                    }
                }
                .disabled(trakt.isSyncing)
                Button(role: .destructive) { Task { await trakt.logout() } } label: { Label(L("Sign out of Trakt"), systemImage: "rectangle.portrait.and.arrow.right") }
            } else if !ent.allows(.trakt) {
                // build 88: Gratis → geen Trakt koppelen, alleen de uitleg
                LifetimeLockRow(title: L("Sign in to Trakt"), icon: "person.crop.circle.badge.checkmark", feature: .trakt)
            } else {
                Button { signIn() } label: {
                    Label(L("Sign in to Trakt"), systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            if trakt.isLoggedIn && !ent.allows(.trakt) {
                // al gekoppeld op een Gratis-account: synchroniseren staat stil, ontkoppelen kan wel
                Text(L("Trakt sync is paused: Trakt is a Lifetime feature."))
                    .font(.caption).foregroundStyle(Theme.secondary)
                LifetimeLockRow(title: L("Compare plans"), icon: "info.circle", feature: .trakt)
            }
            if let e = trakt.lastError { Text(e).font(.caption).foregroundStyle(Theme.red) }
        } header: { Text("Trakt") } footer: {
            Text(L("What you watch in Bingr is scrobbled automatically. What you've watched on Trakt (or in another app) is checked off here."))
        }
    }
}

/// Mijn Bingr → Account en apparaten (Bingr-account, apparaten, tv koppelen, uitloggen).
struct AccountDevicesView: View {
    var body: some View {
        List { AccountSettingsSection() }
            .navigationTitle(L("Account and devices"))
    }
}
