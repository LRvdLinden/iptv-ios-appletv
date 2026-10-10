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
    @State private var showTraktLogin = false
    @State private var showOSLogin = false
    @State private var editing: PlaylistSource?
    @State private var pinMode: PinMode?
    @State private var setup: SetupTarget?

    enum SetupTarget: String, Identifiable { case trakt, openSubtitles, all; var id: String { rawValue } }

    enum PinMode: String, Identifiable { case set, unlock, disable; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            List {
                playlistSection
                refreshSection
                traktSection
                openSubtitlesSection
                playerSection
                parentalSection
                languageSection
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
                Section(L("About")) {
                    LabeledContent(L("Version"), value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                    LabeledContent(L("IMDb data"), value: Secrets.isSet(Secrets.omdbAPIKey) ? L("Active (OMDb)") : L("No OMDb key"))
                }
            }
            .navigationTitle(L("My Bingr"))
        }
        .sheet(isPresented: $showTraktLogin) { TraktLoginView() }
        .sheet(isPresented: $showOSLogin) { OpenSubtitlesLoginView() }
        .sheet(item: $editing) { AddPlaylistView(existing: $0) }
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
            switch mode {
            case .set:
                PINSetupView()
            case .unlock:
                PINPad(title: L("Enter PIN")) { parental.verify($0) }
            case .disable:
                PINPad(title: L("Enter PIN to turn off")) { pin in
                    guard parental.verify(pin) else { return false }
                    store.updateParental { $0.enabled = false }
                    return true
                }
            }
        }
    }

    // MARK: secties

    private var playlistSection: some View {
        Section(L("Playlist")) {
            if let s = playlists.source {
                HStack(spacing: 14) {
                    AvatarTile(name: "", avatar: s.avatar, photo: store.photos[s.id]).frame(width: tvScaled(44))
                    VStack(alignment: .leading) {
                        Text(s.name).font(.headline)
                        Text(L("%@ · %d channels · %d movies · %d series", s.kind.title,
                               playlists.library.channels.count, playlists.library.movies.count, playlists.library.series.count))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Button { editing = s } label: { Label(L("Edit (name, avatar, details)"), systemImage: "pencil") }
                NavigationLink { ManageView() } label: {
                    Label(L("Manage groups and channels"), systemImage: "slider.horizontal.below.rectangle")
                }
                Button { Task { await playlists.select(s, forceRefresh: true) } } label: {
                    Label(L("Refresh now"), systemImage: "arrow.clockwise")
                }
            }
            Button { app.switchPlaylist() } label: { Label(L("Choose another playlist"), systemImage: "rectangle.stack.person.crop") }
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
        Section("OpenSubtitles") {
            if subs.isLoggedIn {
                LabeledContent(L("Signed in as"), value: subs.username ?? "")
                if let r = subs.remainingDownloads { LabeledContent(L("Downloads left today"), value: "\(r)") }
                Button(role: .destructive) { Task { await subs.logout() } } label: { Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right") }
            } else {
                Button { if Secrets.openSubtitlesReady { showOSLogin = true } else { setup = .openSubtitles } } label: {
                    Label(L("Sign in to OpenSubtitles"), systemImage: "captions.bubble")
                }
            }
            Toggle(L("Search subtitles automatically when playing"), isOn: $autoSubtitles)
            NavigationLink(L("Languages: %@", subs.preferredLanguages.joined(separator: ", "))) { LanguagePicker() }
        }
    }

    private var refreshSection: some View {
        Section {
            Picker(L("Update playlists"), selection: $refreshPolicy) {
                ForEach(RefreshPolicy.allCases) { Text($0.title).tag($0.rawValue) }
            }
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
        } header: { Text(L("Player")) } footer: {
            Text(L("Automatic uses the Apple player for HLS and MP4 (HDR, Dolby Vision, Atmos, AirPlay) and VLC for everything else. If a stream fails, Bingr switches over and reconnects automatically."))
        }
    }

    private var parentalSection: some View {
        Section {
            if store.parental.enabled {
                Label(parental.isUnlocked ? L("Unlocked for 30 minutes") : L("Locked"), systemImage: parental.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(parental.isUnlocked ? Theme.imdb : Theme.green)
                if parental.isUnlocked {
                    Button(L("Lock now")) { parental.lock() }
                } else {
                    Button(L("Unlock with PIN")) { pinMode = .unlock }
                }
                Toggle(L("Lock adult groups automatically"), isOn: Binding(
                    get: { store.parental.autoLockAdult },
                    set: { v in store.updateParental { $0.autoLockAdult = v } }))
                Text(L("Lock individual groups under Manage groups and channels (hold a group)."))
                    .font(.caption).foregroundStyle(Theme.secondary)
                Button(L("Change PIN")) { pinMode = .set }
                Button(L("Turn off parental lock"), role: .destructive) { pinMode = .disable }
            } else {
                Button { pinMode = .set } label: { Label(L("Turn on parental lock"), systemImage: "lock") }
            }
        } header: { Text(L("Parental lock")) }
    }

    private var languageSection: some View {
        Section(L("Language")) {
            Picker(L("App language"), selection: $localizer.override) {
                Text(L("System")).tag("")
                ForEach(Localizer.supported, id: \.code) { Text($0.name).tag($0.code) }
            }
        }
    }
}

/// Nieuwe pincode instellen (2× invoeren).
struct PINSetupView: View {
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
                ParentalControl.shared.setPIN(pin)
                store.updateParental { $0.enabled = true }
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
                #if os(iOS)
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
