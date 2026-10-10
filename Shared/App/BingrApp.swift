import SwiftUI

@main
struct BingrApp: App {
    @StateObject private var app = AppState()
    @StateObject private var store = CloudStore.shared
    @StateObject private var trakt = TraktSync.shared
    @StateObject private var meta = MetadataService.shared
    @StateObject private var subs = OpenSubtitles.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.playlists)
                .environmentObject(store)
                .environmentObject(trakt)
                .environmentObject(meta)
                .environmentObject(subs)
                .preferredColorScheme(.dark)
                .tint(Theme.red)
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                store.load(mergeProgress: true)
                Task { await trakt.refresh() }
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
    let playlists = PlaylistService()

    private let lastKey = "lastPlaylistID"

    var lastPlaylistID: UUID? {
        get { UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastKey) }
    }

    func splashFinished() {
        withAnimation(.easeInOut(duration: 0.5)) { stage = .picker }
    }

    func open(_ p: PlaylistSource) {
        lastPlaylistID = p.id
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
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
        .fullScreenCover(item: $app.playing) { item in
            PlayerScreen(item: item)
        }
    }
}
