import SwiftUI

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
                .environment(\.locale, localizer.locale)
                .environment(\.layoutDirection, localizer.isRTL ? .rightToLeft : .leftToRight)
                .preferredColorScheme(.dark)
                .tint(Theme.red)
                .onAppear { reminders.start() }
        }
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
    enum Stage { case splash, picker, main }
    @Published var stage: Stage = .splash
    @Published var playing: PlayableItem?
    @Published var liveZapList: [Channel] = []
    @Published var showMultiview = false
    @Published var multiviewStart: [Channel] = []
    /// Na wisselen van afspeellijst (globaal zoeken): dit item openen
    @Published var pendingItemID: String?
    let playlists = PlaylistService()

    private let lastKey = "lastPlaylistID"

    var lastPlaylistID: UUID? {
        get { UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastKey) }
    }

    func splashFinished() {
        withAnimation(.easeInOut(duration: 0.5)) { stage = .picker }
    }

    func open(_ p: PlaylistSource, thenShow itemID: String? = nil) {
        lastPlaylistID = p.id
        pendingItemID = itemID
        withAnimation(.easeInOut(duration: 0.4)) { stage = .main }
        Task { await playlists.select(p) }
    }

    func switchPlaylist() {
        withAnimation(.easeInOut(duration: 0.35)) { stage = .picker }
    }

    func play(_ item: PlayableItem, zap: [Channel] = []) {
        liveZapList = zap
        playing = item
    }

    func openMultiview(start: [Channel], candidates: [Channel]) {
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
            PlayerScreen(item: item)
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
