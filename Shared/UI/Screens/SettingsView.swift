import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @EnvironmentObject var subs: OpenSubtitles
    @EnvironmentObject var localizer: Localizer
    @EnvironmentObject var parental: ParentalControl
    @AppStorage("autoSubtitles") private var autoSubtitles = false
    @AppStorage("trakt.scrobble") private var traktScrobble = true
    @AppStorage("trakt.askRating") private var traktAskRating = true
    @AppStorage("playlist.refresh") private var refreshPolicy = RefreshPolicy.daily.rawValue
    @AppStorage("player.engine") private var engine = PlayerController.EngineChoice.auto.rawValue
    @AppStorage(TrackPreferences.audioKey) private var audioLanguage = ""
    @AppStorage(TrackPreferences.subtitleKey) private var subtitleLanguage = ""
    @AppStorage("ui.startTab") private var startTab = 0
    @AppStorage("ui.showLive") private var showLive = true
    @AppStorage("ui.showMovies") private var showMovies = true
    @AppStorage("ui.showSeries") private var showSeries = true
    @State private var showTraktLogin = false
    @State private var showOSLogin = false
    @State private var editing: PlaylistSource?
    @State private var editingProfile: ViewerProfile?
    @State private var addingServer = false
    @State private var addingProfile = false
    @State private var deletingServer: PlaylistSource?
    @State private var pinMode: PinMode?
    @State private var setup: SetupTarget?

    enum SetupTarget: String, Identifiable { case trakt, openSubtitles, all; var id: String { rawValue } }

    enum PinMode: String, Identifiable { case set, unlock, disable; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            List {
                Section { MyBingrHeader() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                playlistSection
                if isMain {
                    serverSection
                    profilesSection
                }
                librarySection
                if isMain {
                    refreshSection
                    traktSection
                }
                openSubtitlesSection
                playerSection
                parentalSection
                interfaceSection
                languageSection
                if isMain { adminFooterSections }
                Section(L("About")) {
                    LabeledContent(L("Version"), value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                    LabeledContent(L("IMDb data"), value: Secrets.isSet(Secrets.omdbAPIKey) ? L("Active (OMDb)") : L("No OMDb key"))
                }
            }
            .navigationTitle(store.activeProfile?.name ?? L("My Bingr"))
            // persoonlijke kijkvoorkeuren horen bij het profiel
            .onChange(of: autoSubtitles) { _, v in store.updateActivePreferences { $0.autoSubtitles = v } }
            .onChange(of: audioLanguage) { _, v in store.updateActivePreferences { $0.audioLanguage = v } }
            .onChange(of: subtitleLanguage) { _, v in store.updateActivePreferences { $0.streamSubtitleLanguage = v } }
            .onChange(of: subs.defaultLanguage) { _, v in store.updateActivePreferences { $0.subtitleLanguage = v } }
        }

        .sheet(isPresented: $showTraktLogin) { TraktLoginView() }
        .sheet(isPresented: $showOSLogin) { OpenSubtitlesLoginView() }
        .sheet(item: $editing) { AddPlaylistView(existing: $0) }
        .sheet(item: $editingProfile) { ProfileEditView(existing: $0) }
        .sheet(isPresented: $addingServer) { AddPlaylistView(existing: nil) }
        .sheet(isPresented: $addingProfile) { ProfileEditView(existing: nil) }
        .confirmationDialog(L("Delete server"), isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } }),
                            presenting: deletingServer) { src in
            Button(L("Delete %@", src.name), role: .destructive) { deleteServer(src) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in Text(L("Profiles keep their own lists. Channels, movies and series of this server disappear from the app.")) }
        .sheet(item: $setup) { t in
            switch t {
            case .trakt:
                ConnectionsSetupView(focus: .trakt) {
                    if Secrets.traktReady { Task { try? await Task.sleep(nanoseconds: 500_000_000); showTraktLogin = true } }
                }
            case .openSubtitles:
                ConnectionsSetupView(focus: .openSubtitles) {
                    if Secrets.openSubtitlesReady { Task { try? await Task.sleep(nanoseconds: 500_000_000); showOSLogin = true } }
                }
            case .all:
                ConnectionsSetupView(focus: .all)
            }
        }
        .sheet(item: $pinMode) { mode in
            if let prof = store.activeProfile {
                switch mode {
                case .set:
                    PINSetupView(profileID: prof.id)
                case .unlock:
                    PINPad(title: L("Enter PIN")) { parental.verify($0, profile: prof.id) }
                case .disable:
                    PINPad(title: L("Enter PIN to turn off")) { pin in
                        guard parental.verify(pin, profile: prof.id) else { return false }
                        parental.setPIN(nil, profile: prof.id)
                        if store.isMain(prof) { store.updateParental { $0.enabled = false } }
                        return true
                    }
                }
            }
        }
    }

    private func deleteServer(_ src: PlaylistSource) {
        let wasActive = playlists.source?.id == src.id
        store.delete(src)
        deletingServer = nil
        if wasActive {
            if let next = store.mainSource { app.open(next) } else { app.switchPlaylist() }
        }
    }

    /// Hoofdaccount (of nog geen profielen): mag de server en alles instellen.
    private var isMain: Bool { store.isMainActive || store.profiles.isEmpty || store.activeProfileID == nil }

    @ViewBuilder private var adminFooterSections: some View {
                Section {
                    LabeledContent(L("Playlists"), value: "\(store.playlists.count)")
                    LabeledContent(L("Watch progress"), value: L("%d titles", store.progress.count))
                    if let d = store.lastSync { LabeledContent(L("Last sync"), value: d.formatted(date: .omitted, time: .shortened)) }
                } header: { Text("iCloud") } footer: {
                    Text(L("Playlists, avatars, favorites, My List, watch progress, reminders, your changes and your Trakt/OpenSubtitles sign-in are shared via iCloud between iPhone, iPad, Mac and Apple TV."))
                }
                Section {
                    Button { setup = .all } label: { Label(L("Set up connections"), systemImage: "key.horizontal") }
                } footer: {
                    Text(L("Trakt and OpenSubtitles require a one-time app registration. Saved in iCloud Keychain, so your other devices have it too."))
                }
    }

    // MARK: secties

    /// Kijkprofiel (per persoon) en de server van het hoofdaccount (voor iedereen).
    private var playlistSection: some View {
        Group {
            Section {
                if let p = store.activeProfile {
                    HStack(spacing: 14) {
                        ProfileAvatar(size: tvScaled(44))
                        VStack(alignment: .leading) {
                            Text(p.name).font(.headline)
                            if let a = p.ageLimit { Text(L("Up to %d years", a)).font(.caption).foregroundStyle(Theme.secondary) }
                        }
                    }
                    Button { editingProfile = p } label: { Label(L("Edit profile"), systemImage: "pencil") }
                }
                Button { app.switchPlaylist() } label: { Label(L("Switch profile"), systemImage: "person.2.circle") }
            } header: { Text(L("Profile")) } footer: {
                if !isMain { Text(L("The server and all settings are managed in the main account.")) }
            }
        }
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

    private var serverSection: some View {
        Group {
            Section {
                ForEach(store.playlists) { src in
                    Button {
                        if src.id != playlists.source?.id { app.open(src) }
                    } label: {
                        HStack {
                            Label(src.name, systemImage: src.kind.symbol)
                            Spacer()
                            if src.id == playlists.source?.id { Image(systemName: "checkmark").foregroundStyle(Theme.red) }
                        }
                    }
                    .contextMenu {
                        Button { editing = src } label: { Label(L("Edit"), systemImage: "pencil") }
                        Button(role: .destructive) { deletingServer = src } label: { Label(L("Delete"), systemImage: "trash") }
                    }
                    #if !os(tvOS)
                    .swipeActions {
                        Button(role: .destructive) { deletingServer = src } label: { Label(L("Delete"), systemImage: "trash") }
                        Button { editing = src } label: { Label(L("Edit"), systemImage: "pencil") }.tint(.blue)
                    }
                    #endif
                }
                if let s = playlists.source {
                    Text(L("%@ · %d channels · %d movies · %d series", s.kind.title,
                           playlists.library.channels.count, playlists.library.movies.count, playlists.library.series.count))
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Button { editing = s } label: { Label(L("Edit server"), systemImage: "server.rack") }
                    NavigationLink { CategoriesView() } label: {
                        Label(L("Categories on/off (NL, BE, DE…)"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    NavigationLink { ManageView() } label: {
                        Label(L("Manage groups and channels"), systemImage: "slider.horizontal.below.rectangle")
                    }
                    Button { Task { await playlists.select(s, forceRefresh: true) } } label: {
                        Label(L("Refresh now"), systemImage: "arrow.clockwise")
                    }
                }
                Button { addingServer = true } label: { Label(L("Add server"), systemImage: "plus") }
                if let s = playlists.source {
                    Button(role: .destructive) { deletingServer = s } label: { Label(L("Delete server"), systemImage: "trash") }
                }
            } header: { Text(L("Server")) } footer: {
                Text(L("The server, Trakt and OpenSubtitles belong to the main account and are used by all profiles."))
            }
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
                Button { Task { await trakt.refresh(force: true) } } label: { Label(L("Sync now"), systemImage: "arrow.triangle.2.circlepath") }
                Button(role: .destructive) { Task { await trakt.logout() } } label: { Label(L("Sign out of Trakt"), systemImage: "rectangle.portrait.and.arrow.right") }
            } else {
                Button { if Secrets.traktReady { showTraktLogin = true } else { setup = .trakt } } label: {
                    Label(L("Connect Trakt"), systemImage: "link")
                }
            }
            if let e = trakt.lastError { Text(e).font(.caption).foregroundStyle(Theme.red) }
        } header: { Text("Trakt") } footer: {
            Text(L("What you watch in Bingr is scrobbled automatically. What you've watched on Trakt (or in another app) is checked off here."))
        }
    }

    private var openSubtitlesSection: some View {
        Section {
            if subs.isLoggedIn {
                LabeledContent(L("Signed in as"), value: subs.username ?? "")
                if let r = subs.remainingDownloads { LabeledContent(L("Downloads left today"), value: "\(r)") }
                if isMain {
                    Button(role: .destructive) { Task { await subs.logout() } } label: { Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right") }
                }
            } else if isMain {
                Button { if Secrets.openSubtitlesReady { showOSLogin = true } else { setup = .openSubtitles } } label: {
                    Label(L("Sign in to OpenSubtitles"), systemImage: "captions.bubble")
                }
            }
            Picker(L("Default language"), selection: $subs.defaultLanguage) {
                Text(L("All languages")).tag("")
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle(L("Load subtitles automatically when playing"), isOn: $autoSubtitles)
        } header: { Text("OpenSubtitles") } footer: {
            Text(L("While playing, choose OpenSubtitles to pick another subtitle or language. Automatically uses a subtitle track in the stream first; otherwise the best match from OpenSubtitles is loaded (requires sign-in).") + " " + L("These choices apply to this profile only."))
        }
        .task { await subs.refreshUser() }
    }

    private var refreshSection: some View {
        Section {
            Picker(L("Update playlists"), selection: $refreshPolicy) {
                ForEach(RefreshPolicy.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Button {
                Task { await playlists.refreshAll() }
            } label: {
                HStack {
                    Label(L("Refresh all playlists now"), systemImage: "arrow.clockwise.circle")
                    if playlists.refreshingAll { Spacer(); ProgressView() }
                }
            }
            .disabled(playlists.refreshingAll)
        } header: { Text(L("Update playlists")) } footer: {
            Text(L("Channels, movies, series and the TV guide are refreshed in the background at this interval."))
        }
    }

    private var playerSection: some View {
        Section {
            Picker(L("Player engine"), selection: $engine) {
                ForEach(PlayerController.EngineChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Picker(L("Default audio language"), selection: $audioLanguage) {
                Text(L("As in the stream")).tag("")
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker(L("Default subtitle language"), selection: $subtitleLanguage) {
                Text(L("As in the stream")).tag("")
                Text(L("Off")).tag("off")
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
        } header: { Text(L("Player")) } footer: {
            Text(L("Automatic uses the Apple player for HLS and MP4 (HDR, Dolby Vision, Atmos, AirPlay, Picture in Picture) and VLC for everything else. If a stream fails, Bingr switches over and reconnects automatically. The default languages are chosen automatically when a stream has them."))
        }
    }

    /// Pincode: elk profiel kan zich met een eigen pincode afschermen. Het hoofdaccount regelt daarnaast
    /// met zijn pincode het kinderslot (volwassenengroepen, leeftijdsgrenzen).
    private var parentalSection: some View {
        Section {
            if let prof = store.activeProfile {
                let has = parental.hasPIN(profile: prof.id)
                Label(has ? L("This profile is protected with a PIN") : L("No PIN on this profile"),
                      systemImage: has ? "lock.fill" : "lock.open")
                    .foregroundStyle(has ? Theme.green : Theme.secondary)
                if has {
                    Button(L("Change PIN")) { pinMode = .set }
                    Button(L("Remove PIN"), role: .destructive) { pinMode = .disable }
                } else {
                    Button { pinMode = .set } label: { Label(L("Set PIN"), systemImage: "lock") }
                }
            }
            if isMain, store.activeProfile.map({ parental.hasPIN(profile: $0.id) }) ?? false {
                Toggle(L("Lock adult content with this PIN"), isOn: Binding(
                    get: { store.parental.enabled },
                    set: { v in store.updateParental { $0.enabled = v } }))
                if store.parental.enabled {
                    Toggle(L("Lock adult groups automatically"), isOn: Binding(
                        get: { store.parental.autoLockAdult },
                        set: { v in store.updateParental { $0.autoLockAdult = v } }))
                    Label(parental.isUnlocked ? L("Unlocked for 30 minutes") : L("Locked"), systemImage: parental.isUnlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(parental.isUnlocked ? Theme.imdb : Theme.green)
                    if parental.isUnlocked { Button(L("Lock now")) { parental.lock() } }
                    else { Button(L("Unlock with PIN")) { pinMode = .unlock } }
                    Text(L("Lock individual groups under Manage groups and channels (hold a group). Set age limits per profile under Profiles."))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        } header: { Text(L("PIN code")) } footer: {
            Text(L("With a PIN, the profile asks for the code when it is chosen in “Who's watching?”."))
        }
    }

    private var librarySection: some View {
        Section {
            NavigationLink { HistoryView() } label: { Label(L("Watch history"), systemImage: "clock.arrow.circlepath") }
            if isMain {
                NavigationLink { NetworkBrowserView() } label: {
                    Label(L("NAS & network (SMB/DLNA)"), systemImage: "externaldrive.connected.to.line.below")
                }
            }
        } header: { Text(L("Library")) } footer: {
            Text(L("Watch history is kept per profile. Plex, Jellyfin and Emby can be added as a playlist."))
        }
    }

    private var interfaceSection: some View {
        Section {
            Picker(L("Start screen"), selection: $startTab) {
                Text(L("Home")).tag(0)
                Text(L("Live TV")).tag(1)
                Text(L("Movies")).tag(2)
                Text(L("Series")).tag(3)
            }
            .pickerStyle(.menu)
            if isMain {
                NavigationLink { CategoriesView() } label: {
                    Label(L("Categories on/off (NL, BE, DE…)"), systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            Toggle(L("Intro sound"), isOn: Binding(get: { SplashTune.enabled }, set: { SplashTune.enabled = $0 }))
            Toggle(L("Show Live TV"), isOn: $showLive)
            Toggle(L("Show Movies"), isOn: $showMovies)
            Toggle(L("Show Series"), isOn: $showSeries)
            if isMain {
                NavigationLink { ManageView() } label: {
                    Label(L("Rename, hide and reorder"), systemImage: "slider.horizontal.below.rectangle")
                }
            }
        } header: { Text(L("Interface")) }
    }

    private var languageSection: some View {
        Section(L("Language")) {
            Picker(L("App language"), selection: $localizer.override) {
                Text(L("System")).tag("")
                ForEach(Localizer.supported, id: \.code) { Text($0.name).tag($0.code) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// Nieuwe pincode instellen (2× invoeren).
struct PINSetupView: View {
    var profileID: UUID? = nil
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var step = 0

    var body: some View {
        if step == 0 {
            PINPad(title: L("Choose a 4-digit PIN")) { pin in first = pin; step = 1; return false }
                .id("a")
        } else {
            PINPad(title: L("Enter the PIN again")) { pin in
                guard pin == first else { step = 0; return false }
                if let id = profileID ?? store.activeProfileID ?? store.mainProfileID {
                    ParentalControl.shared.setPIN(pin, profile: id)
                } else {
                    ParentalControl.shared.setPIN(pin)
                }
                ParentalControl.shared.lock()
                dismiss()
                return true
            }
            .id("b")
        }
    }
}

struct TraktLoginView: View {
    @EnvironmentObject var trakt: TraktSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TraktDeviceCode?
    @State private var error: String?

    var body: some View {
        VStack(spacing: tvScaled(20)) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: tvScaled(54))).foregroundStyle(Theme.red)
            Text(L("Connect your Trakt account")).font(.system(size: tvScaled(22), weight: .bold))
            if let code {
                Text(L("On your phone or computer, go to")).foregroundStyle(Theme.secondary)
                Text(code.verification_url).font(.system(size: tvScaled(18), weight: .semibold))
                Text(L("and enter this code:")).foregroundStyle(Theme.secondary)
                Text(code.user_code).font(.system(size: tvScaled(40), weight: .heavy, design: .monospaced)).kerning(6)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                if let qr = QRCode.image(code.verification_url) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: tvScaled(140), height: tvScaled(140))
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
                #if !os(tvOS)
                Button(L("Open trakt.tv/activate")) {
                    UIPasteboard.general.string = code.user_code
                    if let u = URL(string: code.verification_url) { openURL(u) }
                }
                Text(L("The code is already on your clipboard.")).font(.caption).foregroundStyle(Theme.secondary)
                #endif
                ProgressView(L("Waiting for confirmation…")).tint(Theme.red)
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.red).multilineTextAlignment(.center) }
            Button(L("Cancel")) { dismiss() }.padding(.top)
        }
        .padding(Theme.edge)
        .task {
            do {
                let c = try await trakt.startLogin()
                code = c
                try await trakt.finishLogin(c)
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct OpenSubtitlesLoginView: View {
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Username"), text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L("Password"), text: $pass)
                } footer: { Text(L("No account yet? Create one for free at opensubtitles.com.")) }
                if let error { Text(error).foregroundStyle(Theme.red) }
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await subs.login(username: user, password: pass); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { if busy { ProgressView() } else { Text(L("Sign in")) } }
                .disabled(user.isEmpty || pass.isEmpty || busy)
            }
            .navigationTitle("OpenSubtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }
}

private struct LanguagePicker: View {
    @EnvironmentObject var subs: OpenSubtitles
    var body: some View {
        List(OpenSubtitles.languages, id: \.code) { l in
            Button {
                if let i = subs.preferredLanguages.firstIndex(of: l.code) { subs.preferredLanguages.remove(at: i) }
                else { subs.preferredLanguages.append(l.code) }
            } label: {
                HStack {
                    Text(l.name)
                    Spacer()
                    if let i = subs.preferredLanguages.firstIndex(of: l.code) {
                        Text("\(i + 1)").font(.caption.bold()).padding(6).background(Theme.red, in: Circle())
                    }
                }
            }
        }
        .navigationTitle(L("Subtitle languages"))
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
