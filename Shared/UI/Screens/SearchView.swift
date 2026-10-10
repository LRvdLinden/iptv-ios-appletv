import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @State private var query = ""
    @State private var results = PlaylistService.SearchResults()
    @State private var detail: DetailTarget?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 20), spacing: Theme.rowSpacing)] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(22)) {
                    if query.count < 2 {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: tvScaled(40)))
                            Text("Zoek in films, series en zenders").font(.system(size: tvScaled(15)))
                        }
                        .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if results.movies.isEmpty && results.series.isEmpty && results.channels.isEmpty {
                        Text("Niets gevonden voor “\(query)”.").foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if !results.channels.isEmpty {
                        MediaRow(title: "Zenders") {
                            ForEach(results.channels) { c in
                                Button { app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)), zap: results.channels) } label: {
                                    ChannelCard(channel: c, now: playlists.library.nowPlaying(c))
                                }.cardButton()
                            }
                        }
                    }
                    if !results.movies.isEmpty { grid("Films", results.movies.map { .movie($0) }) }
                    if !results.series.isEmpty { grid("Series", results.series.map { .series($0) }) }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle("Zoeken")
            .searchable(text: $query, prompt: "Titels, zenders…")
            .onChange(of: query) { _, q in
                Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if q == query { results = playlists.search(q) }
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
}
