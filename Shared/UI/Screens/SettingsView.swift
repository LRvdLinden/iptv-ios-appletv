import SwiftUI
import CoreImage.CIFilterBuiltins

/// Mijn Bingr → Instellingen (build 72): alles wat niet in Bibliotheek of Profiel past.
struct AppSettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var subs: OpenSubtitles
    @EnvironmentObject var localizer: Localizer
    @EnvironmentObject var parental: ParentalControl
    /// App-sleutels van de server (build 41): opnieuw tekenen zodra ze binnen zijn
    @ObservedObject private var account = AccountService.shared
    /// Build 88: een tweede server hoort bij Lifetime (bestaande extra servers blijven bruikbaar)
    @ObservedObject private var ent = EntitlementsService.shared
    /// Pushmeldingen (docs/PUSH.md): schakelaar met de systeemstatus (niet op Apple TV)
    @ObservedObject private var push = PushService.shared
    @AppStorage(TrackPreferences.subtitleModeKey) private var subtitleMode = TrackPreferences.SubtitleMode.whenNeeded.rawValue
    /// Build 145: "Servers laden bij openen" (per apparaat, niet gesynct)
    @AppStorage(StartLoad.key) private var startLoad = StartLoad.Mode.ask.rawValue
    @AppStorage("player.engine") private var engine = PlayerController.EngineChoice.auto.rawValue
    @AppStorage(SubtitleSize.key) private var subtitleSize = SubtitleSize.small.rawValue
    @AppStorage(TrackPreferences.audioKey) private var audioLanguage = ""
    @AppStorage(TrackPreferences.subtitleKey) private var subtitleLanguage = ""
    @AppStorage("ui.startTab") private var startTab = 0
    @AppStorage("ui.showLive") private var showLive = true
    @AppStorage("ui.showMovies") private var showMovies = true
    @AppStorage("ui.showSeries") private var showSeries = true
    @AppStorage(PlayerSettings.zapDelayKey) private var zapDelay = 0.0
    @AppStorage(PlayerSettings.previewKey) private var channelPreview = true
    @AppStorage(PlayerSettings.matchKey) private var matchFrameRate = true
    @AppStorage(PlayerSettings.externalKey) private var externalDisplay = true
    @AppStorage(DeinterlaceMode.key) private var deinterlace = DeinterlaceMode.auto.rawValue
    @AppStorage(PlayerSettings.resumeLastChannelKey) private var resumeLastChannel = false
    @AppStorage(Trailer.autoplayKey) private var autoplayTrailers = true
    @State private var showOSLogin = false
    @State private var editing: PlaylistSource?
    @State private var editingProfile: ViewerProfile?
    @State private var addingServer = false
    @State private var deletingServer: PlaylistSource?
    @State private var pinMode: PinMode?
    @State private var setup: SetupTarget?

    enum SetupTarget: String, Identifiable { case openSubtitles, all; var id: String { rawValue } }

    /// build 141: `change`, `lockOff` en `autoLockOff` vragen eerst de huidige pincode (net als Samsung TV)
    enum PinMode: String, Identifiable { case set, change, unlock, disable, lockOff, autoLockOff; var id: String { rawValue } }


    var body: some View {
        List {
            playlistSection
            // build 130: de servers van het account zijn er voor elk profiel (kiezen, vernieuwen, controleren);
            // toevoegen, wijzigen en verwijderen blijft bij het hoofdaccount (zie serverSection)
            serverSection
            refreshSection
            openSubtitlesSection
            playerSection
            parentalSection
            interfaceSection
            #if !os(tvOS)
            if Secrets.accountsConfigured && account.isSignedIn { notificationsSection }
            #endif
            languageSection
            if isMain { adminFooterSections }
            Section(L("About")) {
                LabeledContent(L("IMDb data"), value: Secrets.isSet(Secrets.omdbAPIKey) ? L("Active (OMDb)") : L("No OMDb key"))
                // build 112: verplichte bronvermelding van TMDB en JustWatch (stond eerder onder de Home-rijen)
                Text(DiscoverKind.attribution)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // build 143: rapport van de vorige start (crash, hang of niet klaar), als supportticket te sturen
            StartDiagnosticsSection()
            if isMain { advancedSection }
        }
        .navigationTitle(L("Settings"))
        // persoonlijke kijkvoorkeuren horen bij het profiel
        .onChange(of: subtitleMode) { _, v in store.updateActivePreferences { $0.subtitleMode = v } }
        .onAppear(perform: migrateSubtitlePreferences)
        .onChange(of: audioLanguage) { _, v in store.updateActivePreferences { $0.audioLanguage = v } }
        .onChange(of: subtitleLanguage) { _, v in store.updateActivePreferences { $0.streamSubtitleLanguage = v } }
        .onChange(of: subs.defaultLanguage) { _, v in store.updateActivePreferences { $0.subtitleLanguage = v } }

        .sheet(isPresented: $showOSLogin) { OpenSubtitlesLoginView() }
        .sheet(item: $editing) { AddPlaylistView(existing: $0) }
        .sheet(item: $editingProfile) { ProfileEditView(existing: $0) }
        .sheet(isPresented: $addingServer) { AddPlaylistView(existing: nil) }
        .confirmationDialog(L("Delete server"), isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } }),
                            presenting: deletingServer) { src in
            Button(L("Delete %@", src.name), role: .destructive) { deleteServer(src) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in Text(L("Profiles keep their own lists. Channels, movies and series of this server disappear from the app.")) }
        .sheet(item: $setup) { t in
            switch t {
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
                case .change:
                    PINSetupView(profileID: prof.id, requireCurrent: true)
                case .lockOff:
                    PINPad(title: L("Enter PIN to turn off")) { pin in
                        guard parental.verify(pin, profile: prof.id) else { return false }
                        store.updateParental { $0.enabled = false }
                        return true
                    }
                case .autoLockOff:
                    PINPad(title: L("Enter PIN to turn off")) { pin in
                        guard parental.verify(pin, profile: prof.id) else { return false }
                        store.updateParental { $0.autoLockAdult = false }
                        return true
                    }
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
    }

    /// Geavanceerd, helemaal onderaan: eigen app-sleutels. Normaal komen die van de Bingr-server.
    private var advancedSection: some View {
        Section {
            Button { setup = .all } label: { Label(L("Set up connections"), systemImage: "key.horizontal") }
        } header: { Text(L("Advanced")) } footer: {
            Text(L("Only needed if you want to use your own API keys. Bingr normally gets the keys for Trakt and OpenSubtitles securely from the Bingr server."))
        }
    }

    /// OpenSubtitles: gewoon inloggen met gebruikersnaam en wachtwoord (zie `TraktSettingsView.signIn`).
    private func signInToOpenSubtitles() {
        if Secrets.openSubtitlesReady { showOSLogin = true; return }
        Task { @MainActor in
            await account.fetchConfig()
            if Secrets.openSubtitlesReady { showOSLogin = true } else { setup = .openSubtitles }
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
                        if isMain {
                            Button { editing = src } label: { Label(L("Edit"), systemImage: "pencil") }
                            Button(role: .destructive) { deletingServer = src } label: { Label(L("Delete"), systemImage: "trash") }
                        }
                    }
                    #if !os(tvOS)
                    .swipeActions {
                        if isMain {
                            Button(role: .destructive) { deletingServer = src } label: { Label(L("Delete"), systemImage: "trash") }
                            Button { editing = src } label: { Label(L("Edit"), systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    #endif
                }
                if let s = playlists.source {
                    Text(L("%@ · %d channels · %d movies · %d series", s.kind.title,
                           playlists.library.channels.count, playlists.library.movies.count, playlists.library.series.count))
                        .font(.caption).foregroundStyle(Theme.secondary)
                    if isMain {
                        Button { editing = s } label: { Label(L("Edit server"), systemImage: "server.rack") }
                    }
                    // categorieën aan/uit gelden per profiel (build 128)
                    NavigationLink { CategoriesView() } label: {
                        Label(L("Categories on/off (NL, BE, DE…)"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    // groepen en zenders beheren (hernoemen, samenvoegen, volgorde) geldt voor het hele account
                    if isMain {
                        NavigationLink { ManageView() } label: {
                            Label(L("Manage groups and channels"), systemImage: "slider.horizontal.below.rectangle")
                        }
                    }
                    NavigationLink { SourceCheckView() } label: {
                        Label(L("Check source"), systemImage: "stethoscope")
                    }
                    // build 130: alle servers van het account, de actieve eerst (met het laadscherm), de andere daarna
                    // één voor één op de achtergrond
                    Button { Task { await playlists.refreshAll(forceActive: true) } } label: {
                        Label(L("Refresh now"), systemImage: "arrow.clockwise")
                    }
                    .disabled(playlists.refreshingAll)
                    if store.playlists.count > 1 { refreshStatus }
                }
                if isMain {
                    if ent.canAddServer(count: store.playlists.count) {
                        Button { addingServer = true } label: { Label(L("Add server"), systemImage: "plus") }
                    } else {
                        LifetimeLockRow(title: L("Add server"), icon: "plus", feature: .multiServer)
                    }
                    if let s = playlists.source {
                        Button(role: .destructive) { deletingServer = s } label: { Label(L("Delete server"), systemImage: "trash") }
                    }
                }
            } header: { Text(L("Server")) } footer: {
                Text(L("The server, Trakt and OpenSubtitles belong to the main account and are used by all profiles."))
            }
        }
    }

    /// Oude instellingen (t/m build 58) omzetten: ondertitelspoor "Uit" → automatisch uit; oude schakelaar → modus.
    private func migrateSubtitlePreferences() {
        // zonder gekozen modus telt het oude "Uit" als automatisch uit (dat doet `TrackPreferences.subtitleMode`);
        // met een modus wint die
        if UserDefaults.standard.string(forKey: TrackPreferences.subtitleModeKey) == nil {
            subtitleMode = TrackPreferences.subtitleMode.rawValue
        }
        if subtitleLanguage == "off" { subtitleLanguage = "" }
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
                Button { signInToOpenSubtitles() } label: {
                    Label(L("Sign in to OpenSubtitles"), systemImage: "captions.bubble")
                }
            }
            Picker(L("Default language"), selection: $subs.defaultLanguage) {
                Text(L("All languages")).tag("")
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
        } header: { Text("OpenSubtitles") } footer: {
            Text(L("While playing, choose OpenSubtitles to pick another subtitle or language. Automatically uses a subtitle track in the stream first; otherwise the best match from OpenSubtitles is loaded (requires sign-in).") + " " + L("These choices apply to this profile only."))
        }
        .task { await subs.refreshUser() }
    }

    /// Build 130: voortgang van alle servers verversen ("Server 1 van 3") en welke servers niet lukten
    @ViewBuilder private var refreshStatus: some View {
        if let p = playlists.refreshProgress, p.total > 1 {
            Text(L("Refreshing server %d of %d…", p.current, p.total))
                .font(.caption).foregroundStyle(Theme.secondary)
        } else if !playlists.refreshingAll, !playlists.refreshFailed.isEmpty {
            Text(L("Couldn't refresh: %@", playlists.refreshFailed.joined(separator: ", ")))
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private var refreshSection: some View {
        Section {
            Picker(L("Load servers on open"), selection: $startLoad) {
                ForEach(StartLoad.Mode.allCases) { Text($0.title).tag($0.rawValue) }
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
            refreshStatus
        } header: { Text(L("Update playlists")) } footer: {
            Text(L("Applies to this device only. Ask: after you choose a profile, Bingr asks whether to update your servers. You can always update manually."))
        }
    }

    private var playerSection: some View {
        Section {
            Picker(L("Player engine"), selection: $engine) {
                ForEach(PlayerController.EngineChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Picker(L("Subtitle size"), selection: $subtitleSize) {
                ForEach(SubtitleSize.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            // build 59: voorkeurstaal (standaard de app-taal) en automatische ondertitels
            Picker(L("Preferred audio language"), selection: $audioLanguage) {
                Text(L("App language (%@)", TrackPreferences.name(TrackPreferences.appLanguage))).tag("")
                // build 60: geen audiospoor kiezen, zoals Android ("stream")
                Text(L("As in the stream")).tag(TrackPreferences.streamAudio)
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker(L("Subtitles automatically"), selection: $subtitleMode) {
                ForEach(TrackPreferences.SubtitleMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Picker(L("Preferred subtitle language"), selection: $subtitleLanguage) {
                Text(L("App language (%@)", TrackPreferences.name(TrackPreferences.appLanguage))).tag("")
                ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker(L("Zap delay"), selection: $zapDelay) {
                ForEach(PlayerSettings.zapDelays, id: \.self) { Text(PlayerSettings.zapDelayTitle($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker(L("Deinterlacing"), selection: $deinterlace) {
                ForEach(DeinterlaceMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Toggle(L("Start with last channel"), isOn: $resumeLastChannel)
            Toggle(L("Channel preview"), isOn: $channelPreview)
            #if os(iOS)
            if PlayerSettings.isPhone && channelPreview {
                Text(L("Not over mobile data, to save your data.")).font(.caption).foregroundStyle(Theme.secondary)
            }
            #endif
            #if os(iOS)
            Toggle(L("Show on external display"), isOn: $externalDisplay)
            #endif
            #if os(tvOS)
            Toggle(L("Match frame rate"), isOn: $matchFrameRate)
            Text(L("Also turn on Settings → Video and Audio → Match Content (Dynamic Range and Frame Rate) on your Apple TV."))
                .font(.caption).foregroundStyle(Theme.secondary)
            #endif
        } header: { Text(L("Player")) } footer: {
            Text(L("Automatic uses the Apple player for HLS and MP4 (HDR, Dolby Vision, Atmos, AirPlay, Picture in Picture) and VLC for everything else. If a stream fails, Bingr switches over and reconnects automatically. The default languages are chosen automatically when a stream has them.") + " " + L("Subtitles automatically: when needed shows subtitles in your preferred language only if the audio is in another language, using a track in the stream or else the best match from OpenSubtitles (requires sign-in); always shows them for every movie and episode.") + " " + L("With a zap delay, quickly zapping only shows the channel banner; the stream starts once you stop.") + " " + L("Deinterlacing applies to the VLC player and removes comb lines from interlaced TV channels. Start with last channel opens the channel you watched last right after choosing your profile."))
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
                    Button(L("Change PIN")) { pinMode = .change }
                    Button(L("Remove PIN"), role: .destructive) { pinMode = .disable }
                } else {
                    Button { pinMode = .set } label: { Label(L("Set PIN"), systemImage: "lock") }
                }
            }
            if isMain, store.activeProfile.map({ parental.hasPIN(profile: $0.id) }) ?? false {
                Toggle(L("Lock adult content with this PIN"), isOn: Binding(
                    get: { store.parental.enabled },
                    set: { v in if v { store.updateParental { $0.enabled = true } } else { pinMode = .lockOff } }))
                if store.parental.enabled {
                    Toggle(L("Lock adult groups automatically"), isOn: Binding(
                        get: { store.parental.autoLockAdult },
                        set: { v in if v { store.updateParental { $0.autoLockAdult = true } } else { pinMode = .autoLockOff } }))
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

    private var interfaceSection: some View {
        Section {
            NavigationLink { AppearanceView() } label: {
                Label(L("Appearance"), systemImage: "paintpalette")
            }
            Picker(L("Start screen"), selection: $startTab) {
                Text(L("Home")).tag(0)
                Text(L("Live TV")).tag(1)
                Text(L("Movies")).tag(2)
                Text(L("Series")).tag(3)
            }
            .pickerStyle(.menu)
            // build 128: categorieën aan/uit per profiel (elk profiel zijn eigen keuze)
            NavigationLink { CategoriesView() } label: {
                Label(L("Categories on/off (NL, BE, DE…)"), systemImage: "line.3.horizontal.decrease.circle")
            }
            #if !os(tvOS)
            // build 82: trailer zonder geluid in de kop van film- en seriepagina's
            Toggle(L("Play trailers automatically"), isOn: $autoplayTrailers)
            if autoplayTrailers {
                Text(L("Muted, on movie and series pages. Not in Low Data Mode or with Reduce Motion on."))
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            #endif
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

    #if !os(tvOS)
    /// Pushmeldingen: nieuwe versies, herinneringen en berichten van Bingr. Weigert het systeem meldingen, dan een
    /// knop naar de systeeminstellingen.
    private var notificationsSection: some View {
        Section {
            Toggle(L("Push notifications"), isOn: Binding(get: { push.isOn }, set: { push.setEnabled($0) }))
                .disabled(push.status == .denied)
            LabeledContent(L("System setting"), value: systemStatusText)
            if push.status == .denied {
                Text(L("Notifications for Bingr are turned off in your system settings."))
                    .font(.caption).foregroundStyle(Theme.secondary)
                Button { push.openSystemSettings() } label: {
                    Label(L("Open system settings"), systemImage: "gear")
                }
            }
        } header: { Text(L("Notifications")) } footer: {
            Text(L("Get a notification when a new version of Bingr is available, when a program you set a reminder for is about to start, and for news from Bingr."))
        }
        .onAppear { push.appBecameActive() }
    }

    private var systemStatusText: String {
        switch push.status {
        case .allowed: return L("Allowed")
        case .denied: return L("Not allowed")
        case .notDetermined: return L("Not asked yet")
        case .unknown: return "…"
        }
    }
    #endif

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

/// Nieuwe pincode instellen (2× invoeren). build 141: met `requireCurrent` eerst de huidige pincode (wijzigen).
struct PINSetupView: View {
    var profileID: UUID? = nil
    var requireCurrent = false
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var step = 0
    @State private var verified = false

    var body: some View {
        if requireCurrent && !verified {
            PINPad(title: L("Enter your current PIN")) { pin in
                let ok: Bool
                if let id = profileID ?? store.activeProfileID ?? store.mainProfileID {
                    ok = ParentalControl.shared.verify(pin, profile: id)
                } else {
                    ok = ParentalControl.shared.verify(pin)
                }
                if ok { verified = true }
                return false   // niet sluiten: door naar de nieuwe pincode
            }
            .id("current")
        } else if step == 0 {
            PINPad(title: L("Choose a 4-digit PIN"), limited: false) { pin in first = pin; step = 1; return false }
                .id("a")
        } else {
            PINPad(title: L("Enter the PIN again"), limited: false) { pin in
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
                        Text("\(i + 1)").font(.caption.bold()).foregroundStyle(Theme.onAccent).padding(6).background(Theme.red, in: Circle())
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

/// Footer onderaan Mijn Bingr: app-icoon, versie (build) en copyright.
/// `BingrIcon` is een gewone afbeelding: het AppIcon is op tvOS een gelaagde stapel.
struct AboutFooter: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    #if os(tvOS)
    private let iconSize: CGFloat = 90
    #else
    private let iconSize: CGFloat = 56
    #endif

    var body: some View {
        VStack(spacing: 8) {
            Image("BingrIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous))
                .accessibilityHidden(true)
            Text(L("Version: %@ (%@)", version, build))
            Text(verbatim: "© 2026 Bingr")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
    }
}
