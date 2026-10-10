import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var playlists: PlaylistService
    @State private var tab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(filter: .all).tag(0)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                LiveTVView().tag(1)
                    .tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }
                HomeView(filter: .movies).tag(2)
                    .tabItem { Label("Films", systemImage: "film.stack") }
                HomeView(filter: .series).tag(3)
                    .tabItem { Label("Series", systemImage: "rectangle.stack.fill") }
                SearchView().tag(4)
                    .tabItem { Label("Zoeken", systemImage: "magnifyingglass") }
                SettingsView().tag(5)
                    .tabItem { Label("Mijn Bingr", systemImage: "person.crop.circle") }
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
        .alert("Afspeellijst laden mislukt", isPresented: Binding(get: { playlists.error != nil },
                                                                  set: { if !$0 { playlists.error = nil } })) {
            Button("Opnieuw") { if let s = playlists.source { Task { await playlists.select(s, forceRefresh: true) } } }
            Button("OK", role: .cancel) {}
        } message: { Text(playlists.error ?? "") }
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
