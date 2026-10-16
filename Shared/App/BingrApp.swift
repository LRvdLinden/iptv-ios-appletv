import SwiftUI
import Combine

@main
struct BingrApp: App {
    @StateObject private var app = AppState()
    @StateObject private var localizer = Localizer.shared
    // Gedeelde objecten die alleen worden doorgegeven: niet als @StateObject, anders rekent de hele app-scene
    // opnieuw bij elke wijziging (bijv. elke nieuwe IMDb-score of sync-ronde). De schermen volgen ze zelf.
    private let store = CloudStore.shared
    private let trakt = TraktSync.shared
    private let meta = MetadataService.shared
    private let subs = OpenSubtitles.shared
    private let parental = ParentalControl.shared
    private let reminders = ReminderCenter.shared
    private let account = AccountService.shared
    @Environment(\.scenePhase) private var phase
    /// Accentkleur van het actieve profiel (build 54): wisselen (ook door een ander profiel te kiezen) → alles opnieuw tekenen
    @AppStorage(AccentChoice.key) private var accent = AccentChoice.current.rawValue
    /// De accentkleur waarmee nu getekend is; een wijziging (ook via de account) pas toepassen als er niets speelt
    @State private var shownAccent = AccentChoice.current.rawValue
    /// Build 88: accentkleuren alleen met Lifetime (Gratis tekent met de standaardkleur)
    @AppStorage(EntitlementsService.themesKey) private var themesAllowed = true
    #if os(iOS)
    /// Downloads op de achtergrond (build 52): het systeem maakt de app wakker als ze klaar zijn
    @UIApplicationDelegateAdaptor(BingrAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    /// Pushmeldingen op de Mac (APNs-devicetoken via AppKit)
    @NSApplicationDelegateAdaptor(BingrMacAppDelegate.self) private var appDelegate
    #endif

    init() {
        // grotere beeldcache: posters (ook in de intro) laden direct
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(localizer.language + "|" + shownAccent)     // taal of accentkleur wisselen → alles opnieuw opbouwen
                .environmentObject(app)
                .environmentObject(app.playlists)
                .environmentObject(store)
                .environmentObject(trakt)
                .environmentObject(meta)
                .environmentObject(subs)
                .environmentObject(localizer)
                .environmentObject(parental)
                .environmentObject(reminders)
                .environmentObject(account)
                .environment(\.locale, localizer.locale)
                .environment(\.layoutDirection, localizer.isRTL ? .rightToLeft : .leftToRight)
                .preferredColorScheme(.dark)
                .tint(Theme.red)
                .onAppear {
                    reminders.start()
                    #if os(iOS)
                    ExternalDisplay.shared.start()   // extern scherm: video daar, bediening hier
                    DownloadManager.shared.start()   // downloads hervatten (build 52)
                    #endif
                    // gekozen app-icoon na een update gelijktrekken; Mac: in het Dock (build 52/54)
                    AppIconChoice.reconcile()
                }
                .onChange(of: accent) { _, _ in
                    if app.playing == nil && !app.showMultiview { shownAccent = AccentChoice.current.rawValue }
                }
                .onChange(of: themesAllowed) { _, _ in
                    if app.playing == nil && !app.showMultiview { shownAccent = AccentChoice.current.rawValue }
                }
                .onChange(of: app.playing) { _, p in
                    if p == nil && shownAccent != AccentChoice.current.rawValue { shownAccent = AccentChoice.current.rawValue }
                }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .onChange(of: phase) { _, p in
            if p == .active {
                Secrets.reload()
                store.load(mergeProgress: true)
                // build 97: Trakt en de account-sync hooguit eens per minuut (op de Mac wordt de app bij elke
                // wissel tussen apps weer actief)
                if app.traktRefreshDue() { Task { await trakt.refresh() } }
                Task { await app.playlists.refreshIfDue() }
                // gekoppelde apparaten: heartbeat (of registreren) bij terugkeer naar de voorgrond
                if app.accountRefreshDue() {
                    Task {
                        await account.checkDevice()
                        await ProfileSync.shared.syncNow()
                        await SourceSync.shared.syncNow()
                        await StateSync.shared.syncNow()
                        // app-sleutels: alleen opnieuw als het nog niet gelukt is (bijv. offline gestart)
                        await account.fetchConfig(force: false)
                        // abonnement (build 88): bij terugkeer naar de voorgrond; build 97: niet als de heartbeat
                        // hierboven het abonnement net al meestuurde
                        await EntitlementsService.shared.refreshUnlessRecent(60)
                    }
                }
                // pushmeldingen: toestemming kan in de systeeminstellingen gewijzigd zijn; token/taal/build bijwerken
                PushService.shared.appBecameActive()
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Stage { case splash, auth, picker, main }
    @Published var stage: Stage = .splash
    @Published var playing: PlayableItem?
    @Published var liveZapList: [Channel] = []
    @Published var showMultiview = false
    @Published var multiviewStart: [Channel] = []
    /// Na wisselen van afspeellijst (globaal zoeken): dit item openen
    @Published var pendingItemID: String?
    /// Build 52 "Start bij laatste zender": na het kiezen van een profiel de laatste zender openen zodra de lijst er is
    @Published var resumeLastChannelPending = false
    /// Gekozen tabblad (blijft staan als de interface opnieuw wordt opgebouwd, bijv. na een andere accentkleur)
    @Published var selectedTab: Int?
    /// Profielmenu (build 72): Mijn Bingr openen, eventueel meteen op een pagina (Instellingen, Account…)
    @Published var myBingrRequest: MyBingrRequest?
    /// build 97: laatste keer dat Trakt en de account-sync bij het actief worden van de app liepen (of bij het starten)
    var lastTraktRefresh: Date = .distantPast
    var lastAccountRefresh: Date = .distantPast

    /// build 97: minstens 60 seconden geleden? Dan nu (en het tijdstip bijwerken).
    func traktRefreshDue() -> Bool {
        guard Date().timeIntervalSince(lastTraktRefresh) >= 60 else { return false }
        lastTraktRefresh = Date()
        return true
    }
    func accountRefreshDue() -> Bool {
        guard Date().timeIntervalSince(lastAccountRefresh) >= 60 else { return false }
        lastAccountRefresh = Date()
        return true
    }
    let playlists = PlaylistService()

    private let lastKey = "lastPlaylistID"

    private var bag = Set<AnyCancellable>()
    private let skipKey = "account.skipped"

    init() {
        PiPCenter.shared.present = { [weak self] item in self?.playing = item }
        // Bingr-account: sessie op de achtergrond vernieuwen; ongeldig, uitgelogd of verwijderd → inlogscherm
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                guard let self, !signedIn else { return }
                // build 82: account geblokkeerd → speler/multiview sluiten, zodat de melding op het inlogscherm te zien is.
                // build 97: ook bij een ingetrokken apparaat (en elk ander uitloggen) alles stoppen, inclusief
                // beeld-in-beeld (dat speelde anders gewoon door)
                self.playing = nil
                self.showMultiview = false
                PiPCenter.shared.stopActive()
                self.showAuthIfNeeded()
            }
            .store(in: &bag)
        ProfileSync.shared.start()
        SourceSync.shared.start()
        // abonnement (build 88): ophalen na het inloggen, bij de heartbeat en op de voorgrond
        EntitlementsService.shared.start()
        StateSync.shared.start()
        // servers uit de Bingr-account geïmporteerd, gewijzigd of verwijderd → bibliotheek laden of verversen
        SourceSync.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in self?.sourcesChanged(change) }
            .store(in: &bag)
        // het actieve profiel is op een ander apparaat verwijderd → terug naar "Wie kijkt er?"
        ProfileSync.shared.activeProfileRemoved
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.stage == .main else { return }
                self.playing = nil
                self.showMultiview = false
                PiPCenter.shared.stopActive()
                self.switchPlaylist()
            }
            .store(in: &bag)
        // met een sessie meteen door naar "Wie kijkt er?" en op de achtergrond vernieuwen + profielen synchroniseren
        // build 97: de start telt als volledige ronde (het eerste "actief" vlak daarna slaat de account-sync over)
        if Secrets.accountsConfigured, AccountService.shared.isSignedIn { lastAccountRefresh = Date() }
        Task {
            guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
            let r = await AccountService.shared.refresh()
            guard r == .ok || r == .offline else { return }
            // app-sleutels (Trakt, OpenSubtitles, OMDb, TMDB) van de server op de achtergrond
            Task { await AccountService.shared.fetchConfig() }
            // heartbeat bij het starten (sessies van vóór build 39: eerst registreren, met de limiet-afhandeling)
            await AccountService.shared.checkDevice(force: true)
            await ProfileSync.shared.syncNow()
            await SourceSync.shared.syncNow()
            // Trakt, OpenSubtitles, instellingen, lijsten, voortgang, pincodes en herinneringen
            await StateSync.shared.syncNow()
        }
        // elke 5 minuten zolang de app open is
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                await AccountService.shared.checkDevice(force: true)
                // account_data opnieuw lezen: nieuwe of verwijderde profielfoto's van andere apparaten
                await ProfileSync.shared.syncNow()
                await SourceSync.shared.syncNow()
                await StateSync.shared.syncNow()
                await AccountService.shared.fetchConfig(force: false)
            }
        }
        // "Too many devices" bij het starten: spelers sluiten zodat het scherm zichtbaar is
        AccountService.shared.$deviceLimit
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hit in
                guard let self, hit, self.stage == .picker || self.stage == .main else { return }
                self.playing = nil
                self.showMultiview = false
                PiPCenter.shared.stopActive()
            }
            .store(in: &bag)
    }

    /// Zonder sleutels in deze build kan de gebruiker "Doorgaan zonder account" kiezen (onthouden).
    var skippedAccounts: Bool {
        get { UserDefaults.standard.bool(forKey: skipKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipKey) }
    }

    private var needsAuth: Bool {
        if Secrets.accountsConfigured { return !AccountService.shared.isSignedIn }
        return !skippedAccounts
    }

    private func showAuthIfNeeded() {
        guard stage != .splash, stage != .auth, needsAuth else { return }
        playing = nil
        showMultiview = false
        PiPCenter.shared.stopActive()
        withAnimation(.easeInOut(duration: 0.4)) { stage = .auth }
    }

    /// Ingelogd (of zonder account verder) → "Wie kijkt er?"
    func authFinished(skipped: Bool = false) {
        if skipped { skippedAccounts = true }
        withAnimation(.easeInOut(duration: 0.5)) { stage = .picker }
    }

    var lastPlaylistID: UUID? {
        get { UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastKey) }
    }

    func splashFinished() {
        withAnimation(.easeInOut(duration: 0.5)) { stage = needsAuth ? .auth : .picker }
    }

    /// Profiel gekozen ("Wie kijkt er?") → de server van het hoofdaccount openen.
    func open(profile: ViewerProfile) {
        let store = CloudStore.shared
        store.selectProfile(profile)
        resumeLastChannelPending = PlayerSettings.resumeLastChannel
        selectedTab = nil
        if !store.isMain(profile) { ParentalControl.shared.lock() }   // ontgrendeling van het hoofdaccount niet meenemen
        Task { await TraktSync.shared.applyProfile(isMain: store.isMain(profile)) }
        guard let src = store.mainSource else { return }
        // al geladen, of al aan het laden (bijv. na het importeren uit de account)
        if playlists.source?.id == src.id && (!playlists.library.isEmptyLibrary || playlists.isLoading) {
            withAnimation(.easeInOut(duration: 0.4)) { stage = .main }
            playlists.applyCustomizations()
            return
        }
        open(src)
    }

    func open(_ p: PlaylistSource, thenShow itemID: String? = nil) {
        lastPlaylistID = p.id
        if CloudStore.shared.mainSourceID != p.id { CloudStore.shared.setMainSource(p.id) }
        pendingItemID = itemID
        withAnimation(.easeInOut(duration: 0.4)) { stage = .main }
        Task { await playlists.select(p) }
    }

    /// SourceSync heeft servers uit de Bingr-account toegepast. In de app: is de open server verwijderd of
    /// gewijzigd, of is de hoofdserver veranderd, dan de (nieuwe) hoofdserver laden. Daarbuiten (inloggen,
    /// "Wie kijkt er?"): de bibliotheek van de hoofdserver alvast laden.
    private func sourcesChanged(_ change: SourceSync.Change) {
        let store = CloudStore.shared
        let current = playlists.source?.id
        if stage == .main {
            guard let cur = current else {
                if let src = store.mainSource { open(src) }
                return
            }
            if change.removed.contains(cur) || !store.playlists.contains(where: { $0.id == cur }) {
                if let src = store.mainSource { open(src) } else { switchPlaylist() }
            } else if change.mainChanged, let src = store.mainSource, src.id != cur {
                open(src)
            } else if change.updated.contains(cur), let src = store.playlists.first(where: { $0.id == cur }) {
                // instellingen of inloggegevens gewijzigd: op de achtergrond opnieuw ophalen
                Task { await playlists.refresh(src, showSpinner: false) }
            }
            return
        }
        guard let src = store.mainSource else { return }
        if current != src.id {
            Task { await playlists.select(src) }
        } else if change.updated.contains(src.id) {
            Task { await playlists.refresh(src, showSpinner: false) }
        }
    }

    /// Naar het tabblad Mijn Bingr, en daar (optioneel) meteen een pagina openen.
    func showMyBingr(_ route: MyBingrRoute? = nil) {
        selectedTab = 5
        myBingrRequest = MyBingrRequest(route: route)
    }

    func switchPlaylist() {
        withAnimation(.easeInOut(duration: 0.35)) { stage = .picker }
    }

    func play(_ item: PlayableItem, zap: [Channel] = []) {
        // build 59: tijdmeting van het startpad (al begonnen op de detailpagina? dan alleen een tussenstap)
        PlaybackTiming.begin(item.title, step: "app.play", keepRecent: true)
        PiPCenter.shared.stopActive()
        ChannelPreview.shared.stop(release: true)
        liveZapList = zap
        playing = item
    }

    func openMultiview(start: [Channel], candidates: [Channel]) {
        PiPCenter.shared.stopActive()
        ChannelPreview.shared.stop(release: true)
        multiviewStart = start
        liveZapList = candidates
        showMultiview = true
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var reminders: ReminderCenter
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var account: AccountService
    /// Pushmeldingen (docs/PUSH.md): uitleg na het inloggen en tikken op een melding. Beheerberichten komen als push;
    /// de in-app mededelingen (build 62) zijn vervallen.
    @ObservedObject private var push = PushService.shared

    /// Uitleg over pushmeldingen alleen in de app zelf, niet tijdens het kijken of op andere schermen.
    private var showPushPrompt: Binding<Bool> {
        Binding(get: {
            guard app.stage == .main, app.playing == nil, !app.showMultiview, account.deviceLimit == nil else { return false }
            return push.showPrompt
        }, set: { _ in
            // alleen de knoppen sluiten het venster (answerPrompt); verdwijnt het omdat er iets gaat spelen,
            // dan komt het daarna terug
        })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if account.isSignedIn && account.deviceLimit != nil && (app.stage == .picker || app.stage == .main) {
                    // limiet bereikt (sessie van vóór build 39): eerst een apparaat verwijderen, of Cancel = uitloggen
                    TooManyDevicesView().transition(.opacity)
                } else {
                switch app.stage {
                case .splash:
                    SplashView { app.splashFinished() }.transition(.opacity)
                case .auth:
                    AuthView().transition(.opacity)
                case .picker:
                    PlaylistPickerView().transition(.asymmetric(insertion: .scale(scale: 1.08).combined(with: .opacity),
                                                                removal: .opacity))
                case .main:
                    MainTabView().transition(.opacity)
                }
                }
            }
            .fullScreenCover(isPresented: $app.showMultiview) { MultiviewScreen() }
            #if !os(tvOS)
            .sheet(isPresented: showPushPrompt) { PushPromptView() }
            #endif
            .onChange(of: app.stage) { _, stage in
                // na inloggen en het kiezen van een profiel: uitleg over pushmeldingen (eenmalig), en een melding
                // waarop getikt is terwijl de app nog niet in het hoofdscherm was
                guard stage == .main else { return }
                push.offerPromptIfNeeded()
                handlePushRoute()
            }
            .onChange(of: push.pendingRoute) { _, _ in handlePushRoute() }
            .onChange(of: account.deviceLimit) { _, _ in handlePushRoute() }

            if let r = reminders.due { reminderBanner(r) }
        }
        .fullScreenCover(item: $app.playing) { item in
            PlayerScreen(item: item, existing: PiPCenter.shared.takeReuse(for: item))
        }
    }

    /// Tik op een herinnering (push of lokale melding): de zender openen, zoals de knop "Watch" van de banner en
    /// met dezelfde profielcontrole. Wacht tot de app in het hoofdscherm is (na "Wie kijkt er?").
    private func handlePushRoute() {
        guard let route = push.pendingRoute, app.stage == .main, account.deviceLimit == nil else { return }
        push.pendingRoute = nil
        switch route {
        case let .reminder(channelID, profileID, playlistID):
            let store = CloudStore.shared
            // profiel-id van het hoofdprofiel telt als hoofdprofiel (nil), net als bij de herinneringen zelf
            let owner = profileID == store.mainProfileID ? nil : profileID
            guard reminders.canWatch(owner: owner) else { return }
            let known = store.reminders.first { $0.channelID == channelID && $0.owner == owner }
            if let c = playlists.library.channels.first(where: { $0.id == channelID }) {
                app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)))
            } else if let p = (playlistID ?? known?.playlistID).flatMap({ id in store.playlists.first { $0.id == id } })
                        ?? store.mainSource {
                // bibliotheek nog aan het laden, of een andere server: openen zodra de zender er is (MainTabView)
                if playlists.source?.id == p.id { app.pendingItemID = channelID } else { app.open(p, thenShow: channelID) }
            }
        }
    }

    private func reminderBanner(_ r: ProgramReminder) -> some View {
        VStack {
            HStack(spacing: tvScaled(14)) {
                Image(systemName: "bell.fill").foregroundStyle(Theme.red)
                VStack(alignment: .leading, spacing: 2) {
                    // herinnering van een ander profiel: met de naam van dat profiel ("Voor Emma: …")
                    Text(reminders.displayTitle(r)).font(.system(size: tvScaled(15), weight: .bold)).lineLimit(1)
                    Text(L("Starts now on %@", r.channelName)).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                Spacer()
                // niet via de banner langs het leeftijdsfilter: een herinnering van een ander profiel opent
                // de zender alleen als het actieve profiel geen leeftijdsgrens heeft
                if reminders.canWatch(r) {
                    Button {
                        reminders.due = nil
                        if let c = playlists.library.channels.first(where: { $0.id == r.channelID }) {
                            app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)))
                        } else if let p = CloudStore.shared.playlists.first(where: { $0.id == r.playlistID }) {
                            app.open(p, thenShow: r.channelID)
                        }
                    } label: {
                        Text(L("Watch")).onAccentLabel()   // goud: donkere tekst op de knop
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button { reminders.due = nil } label: { Image(systemName: "xmark") }.plainTVButton()
            }
            .padding(tvScaled(14))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, Theme.edge)
            Spacer()
        }
        .padding(.top, tvScaled(10))
        .transition(.move(edge: .top))
    }
}
