import SwiftUI
import Combine

@main
struct BingrApp: App {
    @StateObject private var app = AppState()
    @StateObject private var store = CloudStore.shared
    @StateObject private var trakt = TraktSync.shared
    @StateObject private var meta = MetadataService.shared
    @StateObject private var subs = OpenSubtitles.shared
    @StateObject private var localizer = Localizer.shared
    @StateObject private var parental = ParentalControl.shared
    @StateObject private var reminders = ReminderCenter.shared
    @StateObject private var account = AccountService.shared
    @Environment(\.scenePhase) private var phase

    init() {
        // grotere beeldcache: posters (ook in de intro) laden direct
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(localizer.language)     // taal wisselen → alles opnieuw opbouwen
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
                .onAppear { reminders.start() }
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
                Task { await trakt.refresh() }
                Task { await app.playlists.refreshIfDue() }
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
                self.showAuthIfNeeded()
            }
            .store(in: &bag)
        Task { await AccountService.shared.refresh() }
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
        if !store.isMain(profile) { ParentalControl.shared.lock() }   // ontgrendeling van het hoofdaccount niet meenemen
        Task { await TraktSync.shared.applyProfile(isMain: store.isMain(profile)) }
        guard let src = store.mainSource else { return }
        if playlists.source?.id == src.id && !playlists.library.isEmptyLibrary {
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

    func switchPlaylist() {
        withAnimation(.easeInOut(duration: 0.35)) { stage = .picker }
    }

    func play(_ item: PlayableItem, zap: [Channel] = []) {
        PiPCenter.shared.stopActive()
        liveZapList = zap
        playing = item
    }

    func openMultiview(start: [Channel], candidates: [Channel]) {
        PiPCenter.shared.stopActive()
        multiviewStart = start
        liveZapList = candidates
        showMultiview = true
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var reminders: ReminderCenter
    @EnvironmentObject var playlists: PlaylistService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
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
            .fullScreenCover(isPresented: $app.showMultiview) { MultiviewScreen() }

            if let r = reminders.due { reminderBanner(r) }
        }
        .fullScreenCover(item: $app.playing) { item in
            PlayerScreen(item: item, existing: PiPCenter.shared.takeReuse(for: item))
        }
    }

    private func reminderBanner(_ r: ProgramReminder) -> some View {
        VStack {
            HStack(spacing: tvScaled(14)) {
                Image(systemName: "bell.fill").foregroundStyle(Theme.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.system(size: tvScaled(15), weight: .bold)).lineLimit(1)
                    Text(L("Starts now on %@", r.channelName)).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(L("Watch")) {
                    reminders.due = nil
                    if let c = playlists.library.channels.first(where: { $0.id == r.channelID }) {
                        app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)))
                    } else if let p = CloudStore.shared.playlists.first(where: { $0.id == r.playlistID }) {
                        app.open(p, thenShow: r.channelID)
                    }
                }
                .buttonStyle(.borderedProminent)
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
