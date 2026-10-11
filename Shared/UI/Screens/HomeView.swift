import SwiftUI

struct HomeView: View {
    enum Filter { case all, movies, series }
    let filter: Filter

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync

    @State private var detail: DetailTarget?
    @State private var hero: DetailTarget?
    @State private var trendingMovies: [Movie] = []
    @State private var trendingSeries: [Series] = []
    @State private var forYou: [DetailTarget] = []
    @State private var category: CategoryTarget?
    @State private var showSearch = false
    @State private var resumeChoice: ResumeChoice?
    /// Scrollpositie apart bijhouden: alleen de bovenbalk leest hem, zodat Home niet bij elke scrollframe opnieuw rekent.
    @State private var scroll = ScrollTracker()

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
            .onPreferenceChange(OffsetKey.self) { y in
                let v = max(-400, min(0, y))   // alleen het stuk waar de balk van kleur verandert
                if abs(v - scroll.y) >= 2 || (v == 0) != (scroll.y == 0) { scroll.y = v }
            }
            .ignoresSafeArea(edges: .top)

            #if !os(tvOS)
            HomeTopBar(scroll: scroll, onSearch: { showSearch = true }, onProfile: { app.switchPlaylist() })   // op Apple TV zit Zoeken al in de menubalk
            #endif
        }
        .fullScreenCover(isPresented: $showSearch) { SearchView(modal: true) }
        .background(Color.black)
        .task(id: "\(store.activeProfileID?.uuidString ?? "")-\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)") { await prepare() }
        .fullScreenCover(item: $category) { CategoryView(target: $0) }
        .resumeDialog($resumeChoice) { detail = $0 }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    // MARK: rijen

    @ViewBuilder private var rows: some View {
        let kids = store.activeProfile?.kids ?? false
        let top10Movies = trendingMovies.isEmpty ? nil : top10Row(kids ? L("Top 10 kids movies") : L("Top 10 movies today"), movies: Array(trendingMovies.prefix(10)))
        let top10Series = trendingSeries.isEmpty ? nil : top10Row(kids ? L("Top 10 kids series") : L("Top 10 series today"), series: Array(trendingSeries.prefix(10)))
        switch filter {
        case .all:
            myListRows
            recentRow
            continueRow
            forYouRow
            // zoals Netflix: onder Voor jou de Top 10 series, daarna de films
            if let top10Series { top10Series }
            if let top10Movies { top10Movies }
        case .movies:
            myListRows
            recentRow
            continueRow
            forYouRow
            if let top10Movies { top10Movies }
        case .series:
            myListRows
            continueRow
            forYouRow
            if let top10Series { top10Series }
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
                let all = lib.movies.filter { $0.group == g }
                movieRow(g, Array(all.prefix(40)), all: all)
            }
        }
        if filter != .movies {
            ForEach(lib.seriesGroups.prefix(filter == .all ? 8 : 40), id: \.self) { g in
                let all = lib.series.filter { $0.group == g }
                seriesRow(g, Array(all.prefix(40)), all: all)
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

    @ViewBuilder private var myListRows: some View {
        if filter == .all {
            // Home: films én series uit Mijn lijst in één rij
            let mine: [DetailTarget] = pid.map { p in
                lib.movies.filter { store.inMyList(p, $0.id) }.map { DetailTarget.movie($0) }
                    + lib.series.filter { store.inMyList(p, $0.id) }.map { DetailTarget.series($0) }
            } ?? []
            if !mine.isEmpty {
                MediaRow(title: L("My List"), onSeeAll: { category = CategoryTarget(title: L("My List"), items: mine) }) {
                    ForEach(mine) { t in
                        Button { detail = t } label: {
                            switch t {
                            case .movie(let m):
                                PosterCard(title: m.title, poster: m.poster, imdbID: trakt.imdb(for: m),
                                           watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)), progress: store.progress[m.id]?.fraction)
                            case .series(let se):
                                PosterCard(title: se.title, poster: se.poster, imdbID: trakt.imdb(for: se))
                            }
                        }
                        .cardButton()
                    }
                }
            }
        }
        if filter == .movies {
            let mine = lib.movies.filter { m in pid.map { store.inMyList($0, m.id) } ?? false }
            if !mine.isEmpty { movieRow(L("My List"), mine, all: mine) }
        }
        if filter == .series {
            let mine = lib.series.filter { s in pid.map { store.inMyList($0, s.id) } ?? false }
            if !mine.isEmpty { seriesRow(L("My List"), mine, all: mine) }
        }
    }

    @ViewBuilder private var recentRow: some View {
        let all = lib.movies.filter { $0.addedAt != nil }.sorted { $0.addedAt! > $1.addedAt! }
        if !all.isEmpty { movieRow(L("Recently added"), Array(all.prefix(30)), all: all) }
    }

    @ViewBuilder private var continueRow: some View {
        let items = continueWatching
        if !items.isEmpty {
            MediaRow(title: L("Continue watching")) {
                ForEach(items) { c in
                    Button { resumeChoice = choice(for: c) } label: {
                        ContinueCard(title: c.title, poster: c.artwork, fraction: c.fraction, caption: c.subtitle)
                    }
                    .cardButton()
                    .contextMenu {
                        Button(role: .destructive) { removeFromContinue(c) } label: {
                            Label(L("Remove from Continue watching"), systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var forYouRow: some View {
        let items = forYou.filter { t in
            switch (filter, t) {
            case (.movies, .series), (.series, .movie): return false
            default: return true
            }
        }
        if !items.isEmpty {
            MediaRow(title: L("For you"), onSeeAll: { category = CategoryTarget(title: L("For you"), items: items) }) {
                ForEach(items) { t in
                    Button { detail = t } label: {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster, badge: L("MOVIE"))
                        case .series(let s):
                            PosterCard(title: s.title, poster: s.poster, badge: L("SERIES"))
                        }
                    }
                    .cardButton()
                }
            }
        }
    }

    private func movieRow(_ title: String, _ items: [Movie], all: [Movie]? = nil) -> some View {
        MediaRow(title: title, onSeeAll: all.map { list in { category = CategoryTarget(title: title, items: list.map { .movie($0) }) } }) {
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

    private func seriesRow(_ title: String, _ items: [Series], all: [Series]? = nil) -> some View {
        MediaRow(title: title, onSeeAll: all.map { list in { category = CategoryTarget(title: title, items: list.map { .series($0) }) } }) {
            ForEach(items) { s in
                let imdb = trakt.imdb(for: s)
                let count = max(trakt.watchedCount(show: imdb), store.localWatchedCount(series: s.id),
                                s.episodes.filter { store.localWatched.contains($0.id) }.count)
                Button { detail = .series(s) } label: {
                    PosterCard(title: s.title, poster: s.poster, imdbID: imdb,
                               badge: count > 0 ? L("%d WATCHED", count) : nil)
                }
                .cardButton()
            }
        }
    }

    private func top10Row(_ title: String, movies: [Movie] = [], series: [Series] = []) -> some View {
        MediaRow(title: title, onSeeAll: {
            category = CategoryTarget(title: title, items: series.isEmpty ? trendingMovies.map { .movie($0) } : trendingSeries.map { .series($0) })
        }) {
            ForEach(Array(movies.enumerated()), id: \.element.id) { i, m in
                Button { detail = .movie(m) } label: {
                    Top10Card(rank: i + 1, title: m.title, poster: m.poster,
                              watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)),
                              badge: (m.addedAt ?? .distantPast) > Date().addingTimeInterval(-14 * 86400) ? L("Recently added") : nil)
                }.cardButton()
            }
            ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                Button { detail = .series(s) } label: { Top10Card(rank: i + 1, title: s.title, poster: s.poster) }.cardButton()
            }
        }
    }

    @ViewBuilder private func movieMenu(_ m: Movie, imdb: String?) -> some View {
        Button { play(.movie(m)) } label: { Label(L("Play"), systemImage: "play.fill") }
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

    struct ContinueItem: Identifiable {
        let id: String; let title: String; let subtitle: String; let artwork: URL?; let fraction: Double
        let updated: Date; let isMovie: Bool
        var position: Double? = nil
        var traktPlaybackID: Int? = nil
    }

    private var continueWatching: [ContinueItem] {
        let movieIDs = Set(lib.movies.map(\.id))
        let seriesTitles = Set(lib.series.map(\.title))
        var out: [ContinueItem] = store.progress.compactMap { key, e in
            guard store.belongsToActive(e.profileID) else { return nil }   // alleen van dit profiel
            guard e.playlistID == nil || e.playlistID == pid else { return nil }   // alleen van deze server
            let isMovie = movieIDs.contains(key)
            // afleveringen alleen als de serie (nog) zichtbaar is voor dit profiel (niet verborgen/op slot/te oud)
            if !isMovie && !seriesTitles.contains(e.title) { return nil }
            if filter == .movies && !isMovie { return nil }
            if filter == .series && isMovie { return nil }
            let left = max(0, e.position / max(e.fraction, 0.01) - e.position)
            return ContinueItem(id: key, title: e.title, subtitle: L("%d min left", Int(left / 60)),
                                artwork: e.artwork, fraction: e.fraction, updated: e.updated, isMovie: isMovie,
                                position: e.position > 0 ? e.position : nil)
        }
        // films die je in een andere app (via Trakt) half hebt gekeken
        if filter != .series && !trakt.playback.isEmpty {
            let known = Set(out.map(\.id))
            for p in trakt.playback where p.type == "movie" {
                guard let imdb = p.imdb, let m = lib.movies.first(where: { trakt.imdb(for: $0) == imdb }), !known.contains(m.id) else { continue }
                out.append(ContinueItem(id: m.id, title: m.title, subtitle: "Trakt · \(Int(p.progress))%", artwork: m.poster,
                                        fraction: p.progress / 100, updated: .distantPast, isMovie: true, traktPlaybackID: p.id))
            }
        }
        return Array(out.sorted { $0.updated > $1.updated }.prefix(20))
    }

    private func removeFromContinue(_ c: ContinueItem) {
        withAnimation {
            store.clearProgress(c.id)
            if let id = c.traktPlaybackID { Task { await trakt.removePlayback(id) } }
        }
    }

    /// Tik op Verder kijken: kiezen tussen hervatten en opnieuw kijken.
    private func choice(for c: ContinueItem) -> ResumeChoice {
        let d: DetailTarget? = c.isMovie ? lib.movies.first { $0.id == c.id }.map { .movie($0) }
                                         : lib.series.first { $0.title == c.title }.map { .series($0) }
        return ResumeChoice(id: c.id, title: c.title, fraction: c.fraction, position: c.position, detail: d)
    }

    /// Profielen met een leeftijdsgrens gaan via de detailpagina (die controleert de classificatie).
    private var ageLimited: Bool { store.activeProfile?.effectiveAgeLimit != nil }

    private func play(_ t: DetailTarget) {
        switch t {
        case .movie(let m) where !ageLimited: app.play(Playables.movie(m, imdb: trakt.imdb(for: m)))
        default: detail = t
        }
    }

    private func prepare() async {
        guard !lib.movies.isEmpty || !lib.series.isEmpty else { hero = nil; return }
        let key = "\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)"
        // 0. wat niet (meer) in de gefilterde lijst staat weghalen (ander profiel, leeftijdsgrens, verborgen groep)
        let movieIDs = Set(lib.movies.map(\.id)), seriesIDs = Set(lib.series.map(\.id))
        if let h = hero, !(h.isSeries ? seriesIDs : movieIDs).contains(h.id) { hero = nil }
        trendingMovies.removeAll { !movieIDs.contains($0.id) }
        trendingSeries.removeAll { !seriesIDs.contains($0.id) }
        forYou.removeAll { !($0.isSeries ? seriesIDs : movieIDs).contains($0.id) }
        // 1. meteen iets laten zien: billboard en Top 10 uit de cache van vandaag (of je eigen lijst)
        if hero == nil { withAnimation(.easeInOut(duration: 0.4)) { hero = quickHero() } }
        let matcher = await MatcherCache.shared.matcher(for: lib, key: key)   // op de achtergrond gebouwd
        let kids = store.activeProfile?.kids ?? false
        applyTrending(matcher, movies: TrendingStore.cached(shows: false, kids: kids), series: TrendingStore.cached(shows: true, kids: kids))
        if forYou.isEmpty { forYou = await buildForYou(useNetwork: false, matcher: matcher) }

        // 2. daarna pas het netwerk (gedeeld door alle tabbladen, 6 uur bewaard)
        async let mv = TrendingStore.shared.get(shows: false, kids: kids)
        async let sv = TrendingStore.shared.get(shows: true, kids: kids)
        let (m, s) = await (mv, sv)
        applyTrending(matcher, movies: m, series: s)
        forYou = await buildForYou(useNetwork: true, matcher: matcher)
    }

    /// Billboard zonder te wachten: iets uit de Top 10-cache, anders willekeurig met poster.
    private func quickHero() -> DetailTarget? {
        switch filter {
        case .series: return (trendingSeries.first ?? lib.series.filter { $0.poster != nil }.randomElement()).map { .series($0) }
        case .movies: return (trendingMovies.first ?? lib.movies.filter { $0.poster != nil }.randomElement()).map { .movie($0) }
        case .all:
            if let m = trendingMovies.randomElement() ?? lib.movies.filter({ $0.poster != nil }).randomElement() { return .movie(m) }
            return lib.series.randomElement().map { .series($0) }
        }
    }

    /// Top 10: trending gekoppeld aan je lijst; te weinig treffers → aanvullen met je best beoordeelde/nieuwste titels.
    private func applyTrending(_ matcher: TitleMatcher, movies: [ExternalTitle], series: [ExternalTitle]) {
        if filter != .series {
            let found = matcher.movies(movies)
            if found.count >= 5 || trendingMovies.isEmpty {
                trendingMovies = found.count >= 5 ? found : found + localTop(lib.movies, rating: \.rating, added: \.addedAt, poster: \.poster)
                    .filter { m in !found.contains { $0.id == m.id } }
            }
        }
        if filter != .movies {
            let found = matcher.series(series)
            if found.count >= 5 || trendingSeries.isEmpty {
                trendingSeries = found.count >= 5 ? found : found + localTop(lib.series, rating: \.rating, added: nil, poster: \.poster)
                    .filter { s in !found.contains { $0.id == s.id } }
            }
        }
    }

    /// "Voor jou": Trakt-aanbevelingen die in je lijst staan, aangevuld met
    /// onbekeken titels uit de groepen waar je het meest kijkt, en trending.
    private func buildForYou(useNetwork: Bool = true, matcher: TitleMatcher) async -> [DetailTarget] {
        func ext(_ l: [TraktSync.TraktMedia]) -> [ExternalTitle] { l.compactMap { t in t.title.map { ExternalTitle(titles: [$0], year: t.year) } } }
        var out: [DetailTarget] = []
        var seen = Set<String>()
        func add(_ t: DetailTarget) {
            guard !seen.contains(t.id), store.progress[t.id] == nil else { return }
            if filter == .movies, t.isSeries { return }
            if filter == .series, !t.isSeries { return }
            if case .movie(let m) = t, Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)) { return }
            if case .series(let s) = t, trakt.watchedCount(show: trakt.imdb(for: s)) > 0 { return }
            seen.insert(t.id); out.append(t)
        }
        // 1. vergelijkbaar met wat je (half) gekeken hebt
        var seeds: [(imdb: String, show: Bool)] = []
        let recentKeys = store.progress.sorted { $0.value.updated > $1.value.updated }.map(\.key)
        let movieByID = Dictionary(lib.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for k in recentKeys {
            if let m = movieByID[k], let i = trakt.imdb(for: m) { seeds.append((i, false)) }
            else if let se = lib.series.first(where: { $0.title == store.progress[k]?.title }), let i = trakt.imdb(for: se) { seeds.append((i, true)) }
            if seeds.count >= 4 { break }
        }
        for i in trakt.watchedEpisodes.keys.shuffled().prefix(2) { seeds.append((i, true)) }
        for i in trakt.watchedMovies.shuffled().prefix(2) { seeds.append((i, false)) }
        if filter == .movies { seeds.removeAll { $0.show } }
        if filter == .series { seeds.removeAll { !$0.show } }
        var seenSeeds = Set<String>()
        for seed in seeds where useNetwork && seenSeeds.insert(seed.imdb).inserted {
            let rel = await trakt.related(imdb: seed.imdb, shows: seed.show)
            if seed.show { matcher.series(ext(rel), limit: 6).forEach { add(.series($0)) } }
            else { matcher.movies(ext(rel), limit: 6).forEach { add(.movie($0)) } }
        }

        // 2. persoonlijke Trakt-aanbevelingen
        let rmList = useNetwork ? await trakt.recommendations(shows: false) : []
        let rsList = useNetwork ? await trakt.recommendations(shows: true) : []
        let recMovies = matcher.movies(ext(rmList), limit: 40)
        let recSeries = matcher.series(ext(rsList), limit: 40)
        for (a, b) in zip(recMovies.prefix(15), recSeries.prefix(15)) { add(.movie(a)); add(.series(b)) }
        recMovies.dropFirst(15).prefix(5).forEach { add(.movie($0)) }
        recSeries.dropFirst(15).prefix(5).forEach { add(.series($0)) }

        // groepen waar je in kijkt (voortgang, Mijn lijst, bekeken)
        var groupScore: [String: Int] = [:]
        // alleen titels met voortgang, in Mijn lijst of lokaal bekeken (snel, zonder de hele lijst door te lopen)
        let keys = Set(store.progress.keys).union(store.localWatched)
        for k in keys { if let m = movieByID[k] { groupScore[m.group, default: 0] += 1 } }
        if let pid {
            for m in lib.movies where store.inMyList(pid, m.id) { groupScore[m.group, default: 0] += 1 }
            for s in lib.series where store.inMyList(pid, s.id) { groupScore[s.group, default: 0] += 2 }
        }
        let topGroups = groupScore.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        for g in topGroups {
            lib.movies.filter { $0.group == g }.shuffled().prefix(5).forEach { add(.movie($0)) }
            lib.series.filter { $0.group == g }.shuffled().prefix(5).forEach { add(.series($0)) }
        }
        // aanvullen met trending
        for (a, b) in zip(trendingMovies.prefix(8), trendingSeries.prefix(8)) { add(.movie(a)); add(.series(b)) }
        if out.count < 8 {
            lib.movies.filter { $0.poster != nil }.shuffled().prefix(6).forEach { add(.movie($0)) }
            lib.series.filter { $0.poster != nil }.shuffled().prefix(6).forEach { add(.series($0)) }
        }
        return Array(out.prefix(30))
    }

    /// Eigen Top 10 als er (nog) geen trending-gegevens zijn: hoogste score, dan nieuwste, met poster.
    private func localTop<T>(_ items: [T], rating: KeyPath<T, Double?>, added: KeyPath<T, Date?>?, poster: KeyPath<T, URL?>) -> [T] {
        let withPoster = items.filter { $0[keyPath: poster] != nil }
        let pool = withPoster.isEmpty ? items : withPoster
        let rated = pool.filter { ($0[keyPath: rating] ?? 0) > 0 }
        if rated.count >= 10 {
            return Array(rated.sorted { ($0[keyPath: rating] ?? 0) > ($1[keyPath: rating] ?? 0) }.prefix(10))
        }
        if let added {
            let recent = pool.filter { $0[keyPath: added] != nil }.sorted { $0[keyPath: added]! > $1[keyPath: added]! }
            if recent.count >= 10 { return Array(recent.prefix(10)) }
        }
        return Array(pool.prefix(10))
    }

}

@Observable final class ScrollTracker { var y: CGFloat = 0 }

#if !os(tvOS)
/// iOS bovenbalk (wordt donker bij scrollen, zoals Netflix).
private struct HomeTopBar: View {
    let scroll: ScrollTracker
    let onSearch: () -> Void
    let onProfile: () -> Void

    var body: some View {
        let off = Double(-scroll.y)
        HStack(spacing: 14) {
            BingrLogo(size: 26)
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(L("Search"))
            Button(action: onProfile) { ProfileAvatar(size: 30) }
                .accessibilityLabel(L("Switch profile"))
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(min(0.95, 0.55 + off / 300)), .black.opacity(min(0.9, off / 300))],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
}
#endif

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
