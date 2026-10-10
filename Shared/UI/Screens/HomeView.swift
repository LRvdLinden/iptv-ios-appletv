import SwiftUI

struct HomeView: View {
    enum Filter { case all, movies, series }
    let filter: Filter

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @EnvironmentObject var meta: MetadataService

    @State private var detail: DetailTarget?
    @State private var hero: DetailTarget?
    @State private var trendingMovies: [Movie] = []
    @State private var trendingSeries: [Series] = []
    @State private var scrollOffset: CGFloat = 0

    private var lib: Library { playlists.library }
    private var pid: UUID? { playlists.source?.id }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tvScaled(26)) {
                    if let hero {
                        HeroBanner(target: hero, onPlay: { play(hero) }, onInfo: { detail = hero })
                    } else {
                        Color.clear.frame(height: tvScaled(90))
                    }
                    rows
                }
                .padding(.bottom, 40)
                .background(GeometryReader { g in
                    Color.clear.preference(key: OffsetKey.self, value: g.frame(in: .named("scroll")).minY)
                })
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(OffsetKey.self) { scrollOffset = $0 }
            .ignoresSafeArea(edges: .top)

            #if os(iOS)
            topBar
            #endif
        }
        .background(Color.black)
        .task(id: "\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)") { await prepare() }
        #if os(iOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    // MARK: rijen

    @ViewBuilder private var rows: some View {
        let continueItems = continueWatching
        if !continueItems.isEmpty {
            MediaRow(title: L("Continue watching")) {
                ForEach(continueItems) { c in
                    let entry = c.entry
                    Button { resume(c.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            PosterCard(title: entry.title, poster: entry.artwork, progress: entry.fraction)
                            Text(PlayerController.format(entry.position)).font(.system(size: tvScaled(10)))
                                .foregroundStyle(Theme.secondary)
                        }
                    }.cardButton()
                }
            }
        }

        if filter != .series {
            let mine = lib.movies.filter { m in pid.map { store.inMyList($0, m.id) } ?? false }
            if !mine.isEmpty { movieRow(L("My List"), mine) }
            if !trendingMovies.isEmpty { top10Row(L("Top 10 movies today"), movies: Array(trendingMovies.prefix(10))) }
            let recent = lib.movies.filter { $0.addedAt != nil }.sorted { $0.addedAt! > $1.addedAt! }.prefix(30)
            if !recent.isEmpty { movieRow(L("Recently added"), Array(recent)) }
        }
        if filter != .movies {
            let mine = lib.series.filter { s in pid.map { store.inMyList($0, s.id) } ?? false }
            if !mine.isEmpty && filter == .series { seriesRow(L("My List"), mine) }
            if !trendingSeries.isEmpty { top10Row(L("Top 10 series today"), series: Array(trendingSeries.prefix(10))) }
        }

        if filter == .all {
            let favs = lib.channels.filter { c in pid.map { store.isFavorite($0, c.id) } ?? false }
            if !favs.isEmpty {
                MediaRow(title: L("Favorite channels")) {
                    ForEach(favs) { c in
                        Button { app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: favs) } label: {
                            ChannelCard(channel: c, now: lib.nowPlaying(c), favorite: true)
                        }.cardButton()
                    }
                }
            }
        }

        if filter != .series {
            ForEach(lib.movieGroups.prefix(filter == .all ? 8 : 40), id: \.self) { g in
                movieRow(g, Array(lib.movies.lazy.filter { $0.group == g }.prefix(40)))
            }
        }
        if filter != .movies {
            ForEach(lib.seriesGroups.prefix(filter == .all ? 8 : 40), id: \.self) { g in
                seriesRow(g, Array(lib.series.lazy.filter { $0.group == g }.prefix(40)))
            }
        }

        if lib.movies.isEmpty && lib.series.isEmpty && !playlists.isLoading {
            VStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: tvScaled(40))).foregroundStyle(Theme.secondary)
                Text(filter == .all ? L("This playlist only contains live TV.") : L("No titles found in this playlist."))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    private func movieRow(_ title: String, _ items: [Movie]) -> some View {
        MediaRow(title: title) {
            ForEach(items) { m in
                let imdb = trakt.imdb(for: m)
                Button { detail = .movie(m) } label: {
                    PosterCard(title: m.title, poster: m.poster, imdbID: imdb,
                               watched: Playables.isWatched(movie: m, imdb: imdb),
                               progress: store.progress[m.id]?.fraction)
                }
                .cardButton()
                .contextMenu { movieMenu(m, imdb: imdb) }
            }
        }
    }

    private func seriesRow(_ title: String, _ items: [Series]) -> some View {
        MediaRow(title: title) {
            ForEach(items) { s in
                let imdb = trakt.imdb(for: s)
                let count = trakt.watchedCount(show: imdb)
                Button { detail = .series(s) } label: {
                    PosterCard(title: s.title, poster: s.poster, imdbID: imdb,
                               badge: count > 0 ? L("%d WATCHED", count) : nil)
                }
                .cardButton()
            }
        }
    }

    private func top10Row(_ title: String, movies: [Movie] = [], series: [Series] = []) -> some View {
        MediaRow(title: title) {
            ForEach(Array(movies.enumerated()), id: \.element.id) { i, m in
                Button { detail = .movie(m) } label: {
                    Top10Card(rank: i + 1, title: m.title, poster: m.poster,
                              watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)))
                }.cardButton()
            }
            ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                Button { detail = .series(s) } label: { Top10Card(rank: i + 1, title: s.title, poster: s.poster) }.cardButton()
            }
        }
    }

    @ViewBuilder private func movieMenu(_ m: Movie, imdb: String?) -> some View {
        Button { app.play(Playables.movie(m, imdb: imdb)) } label: { Label(L("Play"), systemImage: "play.fill") }
        let watched = Playables.isWatched(movie: m, imdb: imdb)
        Button {
            store.setLocalWatched(m.id, !watched)
            Task { await trakt.setWatched(Playables.movie(m, imdb: imdb), !watched) }
        } label: { Label(watched ? L("Mark as unwatched") : L("Mark as watched"), systemImage: watched ? "eye.slash" : "checkmark.circle") }
        if let pid {
            Button { store.toggleMyList(pid, m.id) } label: {
                Label(store.inMyList(pid, m.id) ? L("Remove from My List") : L("Add to My List"), systemImage: "plus")
            }
        }
    }

    // MARK: data

    struct ContinueItem: Identifiable { let id: String; let entry: ProgressEntry }

    private var continueWatching: [ContinueItem] {
        guard filter != .series else { return [] }
        let ids = Set(lib.movies.map(\.id)).union(lib.series.flatMap { $0.episodes.map(\.id) })
        return store.progress
            .filter { ids.contains($0.key) || $0.key.hasPrefix("xe") }
            .sorted { $0.value.updated > $1.value.updated }
            .prefix(20).map { ContinueItem(id: $0.key, entry: $0.value) }
    }

    private func resume(_ key: String) {
        if let m = lib.movies.first(where: { $0.id == key }) { app.play(Playables.movie(m, imdb: trakt.imdb(for: m))); return }
        for s in lib.series {
            if let e = s.episodes.first(where: { $0.id == key }) { app.play(Playables.episode(e, of: s, imdb: trakt.imdb(for: s))); return }
        }
        // Xtream-aflevering: episodes worden lazy geladen → open de serie via de opgeslagen titel
        if let entry = store.progress[key], let s = lib.series.first(where: { $0.title == entry.title }) { detail = .series(s) }
    }

    private func play(_ t: DetailTarget) {
        switch t {
        case .movie(let m): app.play(Playables.movie(m, imdb: trakt.imdb(for: m)))
        case .series: detail = t
        }
    }

    private func prepare() async {
        guard !lib.movies.isEmpty || !lib.series.isEmpty else { hero = nil; return }
        // Trending op Trakt koppelen aan wat in jouw afspeellijst zit
        if filter != .series, trendingMovies.isEmpty {
            let t = await trakt.trending(shows: false)
            trendingMovies = match(t, in: lib.movies, title: \.title, year: \.year)
        }
        if filter != .movies, trendingSeries.isEmpty {
            let t = await trakt.trending(shows: true)
            trendingSeries = match(t, in: lib.series, title: \.title, year: \.year)
        }
        // hero: liefst iets trending, anders willekeurig met een poster
        let candidate: DetailTarget? = {
            switch filter {
            case .series: return (trendingSeries.first ?? lib.series.filter { $0.poster != nil }.randomElement()).map { .series($0) }
            case .movies: return (trendingMovies.first ?? lib.movies.filter { $0.poster != nil }.randomElement()).map { .movie($0) }
            case .all:
                if let m = trendingMovies.randomElement() { return .movie(m) }
                if let m = lib.movies.filter({ $0.poster != nil }).randomElement() { return .movie(m) }
                return lib.series.randomElement().map { .series($0) }
            }
        }()
        withAnimation(.easeInOut(duration: 0.5)) { hero = candidate }
    }

    private func match<T>(_ trending: [TraktSync.TraktMedia], in items: [T], title: KeyPath<T, String>, year: KeyPath<T, Int?>) -> [T] {
        var byKey: [String: T] = [:]
        for i in items {
            let n = TraktSync.TitleIndex.norm(i[keyPath: title])
            if byKey[n] == nil { byKey[n] = i }
            if let y = i[keyPath: year] { byKey["\(n)|\(y)"] = i }
        }
        return trending.compactMap { t in
            guard let title = t.title else { return nil }
            let n = TraktSync.TitleIndex.norm(title)
            return t.year.flatMap { byKey["\(n)|\($0)"] } ?? byKey[n]
        }
    }

    // MARK: iOS bovenbalk (wordt donker bij scrollen, zoals Netflix)

    #if os(iOS)
    private var topBar: some View {
        HStack(spacing: 14) {
            BingrLogo(size: 26)
            Spacer()
            if let s = playlists.source {
                Button { app.switchPlaylist() } label: {
                    MiniAvatar(playlist: s, size: 30)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(min(0.95, 0.55 + Double(-scrollOffset) / 300)), .black.opacity(min(0.9, Double(-scrollOffset) / 300))],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
    #endif
}

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
