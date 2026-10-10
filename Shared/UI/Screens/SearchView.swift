import SwiftUI

/// Zoeken in de huidige afspeellijst én in alle andere afspeellijsten.
struct SearchView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @State private var query = ""
    @State private var results = PlaylistService.SearchResults()
    @State private var detail: DetailTarget?
    @State private var searching = false

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 20), spacing: Theme.rowSpacing)] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(22)) {
                    if query.count < 2 {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: tvScaled(40)))
                            Text(L("Search movies, series and channels in all your playlists")).font(.system(size: tvScaled(15)))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if results.isEmpty && !searching {
                        Text(L("Nothing found for “%@”.", query)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if !results.channels.isEmpty {
                        MediaRow(title: L("Channels")) {
                            ForEach(results.channels) { c in
                                Button { app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)), zap: results.channels) } label: {
                                    ChannelCard(channel: c, now: playlists.library.nowPlaying(c))
                                }.cardButton()
                            }
                        }
                    }
                    if !results.movies.isEmpty { grid(L("Movies"), results.movies.map { .movie($0) }) }
                    if !results.series.isEmpty { grid(L("Series"), results.series.map { .series($0) }) }
                    if !results.other.isEmpty { otherPlaylists }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle(L("Search"))
            .searchable(text: $query, prompt: L("Titles, channels…"))
            .onChange(of: query) { _, q in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard q == query else { return }
                    searching = true
                    results = await playlists.search(q)
                    searching = false
                }
            }
        }
        #if os(iOS)
        .sheet(item: $detail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    private func grid(_ title: String, _ items: [DetailTarget]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVGrid(columns: columns, spacing: Theme.rowSpacing * 2) {
                ForEach(items) { t in
                    Button { detail = t } label: {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster,
                                       watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)))
                        case .series(let s):
                            PosterCard(title: s.title, poster: s.poster)
                        }
                    }
                    .cardButton()
                }
            }
            .padding(.horizontal, Theme.edge)
        }
    }

    /// Treffers in andere afspeellijsten: tik → wissel van afspeellijst en open het item.
    private var otherPlaylists: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("In your other playlists")).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVStack(spacing: 4) {
                ForEach(results.other) { h in
                    Button { app.open(h.playlist, thenShow: h.itemID) } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: h.artwork, contentMode: .fill, placeholder: String(h.title.prefix(2)))
                                .frame(width: tvScaled(44), height: tvScaled(62)).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.title).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                Text(h.subtitle).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4).fill(h.playlist.avatar.gradient)
                                    Image(systemName: h.playlist.avatar.symbol).font(.system(size: tvScaled(11), weight: .bold))
                                }.frame(width: tvScaled(22), height: tvScaled(22))
                                Text(h.playlist.name).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.horizontal, Theme.edge).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .plainTVButton()
                }
            }
        }
    }
}
