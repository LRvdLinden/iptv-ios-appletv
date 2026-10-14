import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @State private var pendingDetail: DetailTarget?
    @AppStorage("ui.startTab") private var startTab = 0
    @AppStorage("ui.showLive") private var showLive = true
    @AppStorage("ui.showMovies") private var showMovies = true
    @AppStorage("ui.showSeries") private var showSeries = true

    @ViewBuilder private var myBingrTab: some View {
        #if os(iOS)
        if let img = ProfileTabIcon.image(CloudStore.shared) {
            Label { Text(L("My Bingr")) } icon: { Image(uiImage: img) }
        } else {
            Label(L("My Bingr"), systemImage: "person.crop.circle")
        }
        #elseif os(tvOS)
        // build 72: de ronde avatar van het actieve profiel aan het eind van de menubalk (als tvOS hem toont)
        if let img = ProfileTabIcon.image(CloudStore.shared, size: 40) {
            Label { Text(CloudStore.shared.activeProfile?.name ?? L("My Bingr")) } icon: { Image(uiImage: img) }
        } else {
            Label(CloudStore.shared.activeProfile?.name ?? L("My Bingr"), systemImage: "person.crop.circle")
        }
        #else
        Label(CloudStore.shared.activeProfile?.name ?? L("My Bingr"), systemImage: "person.crop.circle")
        #endif
    }

    private static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var hasLive: Bool { !playlists.library.channels.isEmpty || !(playlists.source?.kind.isMediaServer ?? false) }

    var body: some View {
        ZStack {
            TabView(selection: Binding(get: { app.selectedTab ?? 0 }, set: { app.selectedTab = $0 })) {
                HomeView(filter: .all).tag(0)
                    .tabItem { Label(L("Home"), systemImage: "house.fill") }
                if hasLive && showLive {
                    LiveTVView().tag(1)
                        .tabItem { Label(L("Live TV"), systemImage: "dot.radiowaves.left.and.right") }
                }
                if showMovies {
                    HomeView(filter: .movies).tag(2)
                        .tabItem { Label(L("Movies"), systemImage: "film.stack") }
                }
                if showSeries {
                    HomeView(filter: .series).tag(3)
                        .tabItem { Label(L("Series"), systemImage: "rectangle.stack.fill") }
                }
                // Build 85: Categorieën als eigen tabblad op iPad, Mac en Apple TV (iPhone: chip bovenaan Home/Films/Series)
                if !Self.isPhone && (showMovies || showSeries) {
                    BrowseCategoriesView().tag(7)
                        .tabItem { Label(L("Categories"), systemImage: "square.grid.2x2") }
                }
                // iPhone toont max. 5 tabbladen (anders "Meer"); zoeken zit daar al als vergrootglas op Home/Films/Series
                if !Self.isPhone {
                    SearchView().tag(4)
                        .tabItem { Label(L("Search"), systemImage: "magnifyingglass") }
                }
                #if os(iOS)
                // iPad: Downloads als eigen tabblad (iPhone: in Mijn Bingr, want daar passen maar 5 tabbladen)
                if !Self.isPhone {
                    NavigationStack { DownloadsView() }.tag(6)
                        .tabItem { Label(L("Downloads"), systemImage: "arrow.down.circle") }
                }
                #endif
                MyBingrView().tag(5)
                    .tabItem { myBingrTab }
            }
            #if os(iOS)
            .toolbarBackground(.black.opacity(0.92), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            #endif

            if playlists.isLoading {
                LoadingOverlay(text: playlists.loadingText, source: playlists.source)
                    .transition(.opacity)
            } else if playlists.isRefreshing {
                // de bewaarde lijst staat al in beeld; verversen gebeurt op de achtergrond
                UpdatingPill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, tvScaled(70))
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: playlists.isLoading)
        .animation(.easeInOut, value: playlists.isRefreshing)
        .alert(L("Couldn't load playlist"), isPresented: Binding(get: { playlists.error != nil },
                                                                 set: { if !$0 { playlists.error = nil } })) {
            Button(L("Try again")) { if let s = playlists.source { Task { await playlists.select(s, forceRefresh: true) } } }
            Button("OK", role: .cancel) {}
        } message: { Text(playlists.error ?? "") }
        .onChange(of: playlists.library.channels.count + playlists.library.movies.count + playlists.library.series.count) { _, _ in
            openPending()
        }
        .onAppear {
            openPending()
            if app.selectedTab == nil {
                let allowed = [0, hasLive && showLive ? 1 : -1, showMovies ? 2 : -1, showSeries ? 3 : -1]
                app.selectedTab = allowed.contains(startTab) ? startTab : 0
            }
        }
        #if !os(tvOS)
        .sheet(item: $pendingDetail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $pendingDetail) { DetailView(target: $0) }
        #endif
    }

    /// Item uit een andere afspeellijst (globaal zoeken / herinnering) openen zodra de lijst geladen is.
    private func openPending() {
        resumeLastChannel()
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

extension MainTabView {
    /// "Start bij laatste zender" (build 52): de laatst bekeken zender van dit profiel op deze server openen.
    fileprivate func resumeLastChannel() {
        guard app.resumeLastChannelPending, app.playing == nil, let pid = playlists.source?.id else { return }
        let lib = playlists.library
        guard !lib.channels.isEmpty else { return }
        app.resumeLastChannelPending = false
        let prefix = pid.uuidString + "|"
        guard let k = CloudStore.shared.recentChannels.first(where: { $0.hasPrefix(prefix) }),
              let c = lib.channels.first(where: { $0.id == String(k.dropFirst(prefix.count)) }) else { return }
        // zappen binnen dezelfde groep, zoals vanuit Live TV
        app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: lib.channels.filter { $0.group == c.group })
    }
}

/// Klein "Bijwerken…"-label tijdens het verversen op de achtergrond.
private struct UpdatingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white).scaleEffect(0.7)
            Text(L("Updating…")).font(.system(size: tvScaled(12), weight: .semibold))
        }
        .padding(.horizontal, tvScaled(14)).padding(.vertical, tvScaled(6))
        .background(.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
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
                    AvatarTile(name: CloudStore.shared.activeProfile?.name ?? source.name,
                               avatar: CloudStore.shared.activeProfile?.avatar ?? source.avatar,
                               photo: CloudStore.shared.photos[CloudStore.shared.activeProfile?.id ?? source.id])
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
