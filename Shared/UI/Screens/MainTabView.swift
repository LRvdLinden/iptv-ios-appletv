import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @State private var tab = 0
    @State private var pendingDetail: DetailTarget?

    private var hasLive: Bool { !playlists.library.channels.isEmpty || !(playlists.source?.kind.isMediaServer ?? false) }

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(filter: .all).tag(0)
                    .tabItem { Label(L("Home"), systemImage: "house.fill") }
                if hasLive {
                    LiveTVView().tag(1)
                        .tabItem { Label(L("Live TV"), systemImage: "dot.radiowaves.left.and.right") }
                }
                HomeView(filter: .movies).tag(2)
                    .tabItem { Label(L("Movies"), systemImage: "film.stack") }
                HomeView(filter: .series).tag(3)
                    .tabItem { Label(L("Series"), systemImage: "rectangle.stack.fill") }
                SearchView().tag(4)
                    .tabItem { Label(L("Search"), systemImage: "magnifyingglass") }
                SettingsView().tag(5)
                    .tabItem { Label(L("My Bingr"), systemImage: "person.crop.circle") }
            }
            #if os(iOS)
            .toolbarBackground(.black.opacity(0.92), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            #endif

            if playlists.isLoading {
                LoadingOverlay(text: playlists.loadingText, source: playlists.source)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: playlists.isLoading)
        .alert(L("Couldn't load playlist"), isPresented: Binding(get: { playlists.error != nil },
                                                                 set: { if !$0 { playlists.error = nil } })) {
            Button(L("Try again")) { if let s = playlists.source { Task { await playlists.select(s, forceRefresh: true) } } }
            Button("OK", role: .cancel) {}
        } message: { Text(playlists.error ?? "") }
        .onChange(of: playlists.library.channels.count + playlists.library.movies.count + playlists.library.series.count) { _, _ in
            openPending()
        }
        .onAppear { openPending() }
        #if os(iOS)
        .sheet(item: $pendingDetail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $pendingDetail) { DetailView(target: $0) }
        #endif
    }

    /// Item uit een andere afspeellijst (globaal zoeken / herinnering) openen zodra de lijst geladen is.
    private func openPending() {
        guard let id = app.pendingItemID else { return }
        let lib = playlists.library
        if let c = lib.channels.first(where: { $0.id == id }) {
            app.pendingItemID = nil
            app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: lib.channels)
        } else if let m = lib.movies.first(where: { $0.id == id }) {
            app.pendingItemID = nil; pendingDetail = .movie(m)
        } else if let s = lib.series.first(where: { $0.id == id }) {
            app.pendingItemID = nil; pendingDetail = .series(s)
        }
    }
}

private struct LoadingOverlay: View {
    let text: String
    let source: PlaylistSource?
    @State private var pulse = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: tvScaled(22)) {
                if let source {
                    AvatarTile(name: source.name, avatar: source.avatar)
                        .frame(width: tvScaled(110))
                        .scaleEffect(pulse ? 1.05 : 0.97)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                }
                ProgressView().tint(Theme.red).scaleEffect(tvScaled(1.3))
                Text(text).font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
            }
        }
        .onAppear { pulse = true }
    }
}
