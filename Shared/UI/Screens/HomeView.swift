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
    /// Rijen één keer per lijst opbouwen (op de achtergrond), niet bij elke schermverversing
    @State private var index = HomeIndex()
    /// Films die je in een andere app (via Trakt) half keek — één keer gekoppeld, niet per frame
    @State private var traktContinue: [ContinueItem] = []
    /// Scrollpositie apart bijhouden: alleen de bovenbalk leest hem, zodat Home niet bij elke scrollframe opnieuw rekent.
    @State private var scroll = ScrollTracker()
    /// Inhoud van de collecties (één keer per lijst of wijziging, op de achtergrond)
    @State private var collectionContent: [String: CollectionContent] = [:]
    @State private var collecting: CollectionTarget?
    /// Build 86: rij Categorieën op Home (tegels) en het overzicht via "Alle categorieën"
    @State private var showCategories = false
    @State private var browseOpen: BrowseCategory?
    @ObservedObject private var browse = BrowseIndexStore.shared

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
                ScrollActivity.shared.touch()   // zwaar achtergrondwerk wacht tot het scrollen stopt
                let v = max(-400, min(0, y))   // alleen het stuk waar de balk van kleur verandert
                if abs(v - scroll.y) >= 2 || (v == 0) != (scroll.y == 0) { scroll.y = v }
            }
            .ignoresSafeArea(edges: .top)

            #if !os(tvOS)
            HomeTopBar(scroll: scroll, filter: filter, onSearch: { showSearch = true },   // op Apple TV zit Zoeken al in de menubalk
                       onTab: { app.selectedTab = $0 })
            #endif
        }
        .fullScreenCover(isPresented: $showSearch) { SearchView(modal: true) }
        .fullScreenCover(isPresented: $showCategories) { BrowseCategoriesView(modal: true) }
        .fullScreenCover(item: $browseOpen) { BrowseCategoryView(category: $0) }
        .background(Color.black)
        .task(id: "\(store.activeProfileID?.uuidString ?? "")-\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)") { await prepare() }
        .task(id: playlists.libraryVersion) {
            let l = lib
            index = await Task.detached(priority: .userInitiated) { HomeIndex.build(l) }.value
            matchTraktPlayback()
        }
        .onChange(of: trakt.playback.count) { _, _ in matchTraktPlayback() }
        .task(id: playlists.libraryVersion) { if filter == .all { browse.refresh(playlists) } }
        .onAppear { if filter == .all { browse.refresh(playlists) } }
        .task(id: CollectionsKey(version: playlists.libraryVersion, source: pid, collections: store.activeCollections)) {
            // Build 56: wijzigingen (sync, nieuwe lijst) komen vaak vlak na elkaar; even wachten, en niet midden in
            // het scrollen herberekenen. De eerste keer meteen.
            if !collectionContent.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await ScrollActivity.shared.waitUntilIdle()
                if Task.isCancelled { return }
            }
            let l = lib, list = store.activeCollections, src = pid, version = playlists.libraryVersion
            // buiten de hoofdthread, en per (lijst, server, collectie) bewaard: alleen gewijzigde collecties rekenen opnieuw
            let out = await CollectionCache.shared.content(for: list, lib: l, version: version, source: src)
            guard !Task.isCancelled else { return }
            if out != collectionContent { collectionContent = out }   // gelijk = Home niet opnieuw tekenen
        }
        .sheet(item: $collecting) { AddToCollectionSheet(target: $0) }
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
        switch filter {
        case .all:
            // Home: de rijen zoals ingesteld bij Mijn Bingr → Startscherm (per profiel)
            ForEach(homeSlots) { slot in homeSlot(slot) }
        case .movies:
            continueRow
            myListRows
            recentRow
            forYouRow
            top10MoviesRow
            ForEach(store.activeCollections) { c in collectionRow(c) }
        case .series:
            continueRow
            myListRows
            forYouRow
            top10SeriesRow
            ForEach(store.activeCollections) { c in collectionRow(c) }
        }

        if filter == .movies {
            ForEach(index.movieGroups.prefix(40)) { g in
                movieRow(g.id, Array(g.items.prefix(40)), all: g.items)
            }
        }
        if filter == .series {
            ForEach(index.seriesGroups.prefix(40)) { g in
                seriesRow(g.id, Array(g.items.prefix(40)), all: g.items)
            }
        }

        if lib.movies.isEmpty && lib.series.isEmpty && !playlists.isLoading && !playlists.isFiltering {
            VStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: tvScaled(40))).foregroundStyle(Theme.secondary)
                Text(filter == .all ? L("This playlist only contains live TV.") : L("No titles found in this playlist."))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    /// Eén rij op Home. Build 86: de vaste rijen zijn opgesplitst tot op de rij (Top 10 = twee rijen, "Rijen per
    /// categorie" = één rij per categorie), zodat er precies 5 rijen tussen Nu live en de rij Categorieën kunnen staan.
    enum HomeSlot: Hashable, Identifiable {
        case key(String)
        case top10Series, top10Movies
        case movieGroup(String), seriesGroup(String)
        case browse
        var id: Self { self }
    }

    /// Rijen van het startscherm zoals ingesteld bij Mijn Bingr → Startscherm (per profiel), alleen die iets tonen.
    /// De rij Categorieën ("browse") staat standaard direct na "live" in de indeling; dan staan er precies 5 getoonde
    /// rijen tussen Nu live en Categorieën (hij is de 6e rij eronder; zijn er minder rijen, dan onderaan; staat Nu live uit of is hij leeg, dan telt de plek
    /// waar Nu live had gestaan). Heeft het profiel hem zelf ergens anders neergezet, dan staat hij daar.
    private var homeSlots: [HomeSlot] {
        let layout = store.homeLayout.effective(collections: store.activeCollections)
        let hasBrowse = !browse.index.isEmpty
        var slots: [(slot: HomeSlot, shown: Bool)] = []
        var liveAt: Int?
        var autoBrowse = false
        for (i, r) in layout.enumerated() {
            switch r.key {
            case "browse":
                if i > 0 && layout[i - 1].key == "live" { autoBrowse = r.visible }
                else if r.visible && hasBrowse { slots.append((.browse, true)) }
            case "live":
                liveAt = slots.count
                slots.append((.key("live"), r.visible && !liveChannels.list.isEmpty))
            case "top10":
                guard r.visible else { continue }
                // zoals Netflix: eerst de Top 10 series, daarna de films
                slots.append((.top10Series, !trendingSeries.isEmpty))
                slots.append((.top10Movies, !trendingMovies.isEmpty))
            case "categories":
                guard r.visible else { continue }
                for g in index.movieGroups.prefix(8) { slots.append((.movieGroup(g.id), true)) }
                for g in index.seriesGroups.prefix(8) { slots.append((.seriesGroup(g.id), true)) }
            default:
                guard r.visible else { continue }
                slots.append((.key(r.key), hasContent(r.key)))
            }
        }
        if autoBrowse && hasBrowse {
            var at = slots.count
            var seen = 0
            for j in ((liveAt ?? -1) + 1)..<max((liveAt ?? -1) + 1, slots.count) where slots[j].shown {
                seen += 1
                if seen == HomeLayout.browseOffset { at = j + 1; break }
            }
            slots.insert((.browse, true), at: min(at, slots.count))
        }
        return slots.filter { $0.shown }.map { $0.slot }
    }

    /// Toont deze vaste rij (of collectie) iets?
    private func hasContent(_ key: String) -> Bool {
        switch key {
        case "continue": return !continueWatching.isEmpty
        case "mylist": return !(myListMovies.isEmpty && myListSeries.isEmpty)
        case "recent": return !index.recent.isEmpty
        case "foryou": return !forYou.isEmpty
        case "movies": return !index.popularMovies.isEmpty
        case "series": return !index.popularSeries.isEmpty
        default:
            guard key.hasPrefix(HomeLayout.collectionPrefix),
                  let c = store.collection(String(key.dropFirst(HomeLayout.collectionPrefix.count))) else { return false }
            let content = collectionContent[c.id] ?? CollectionContent()
            return !(content.channels.isEmpty && content.movies.isEmpty && content.series.isEmpty)
        }
    }

    @ViewBuilder private func homeSlot(_ slot: HomeSlot) -> some View {
        switch slot {
        case .top10Series: top10SeriesRow
        case .top10Movies: top10MoviesRow
        case .movieGroup(let id):
            if let g = index.movieGroups.first(where: { $0.id == id }) { movieRow(g.id, Array(g.items.prefix(40)), all: g.items) }
        case .seriesGroup(let id):
            if let g = index.seriesGroups.first(where: { $0.id == id }) { seriesRow(g.id, Array(g.items.prefix(40)), all: g.items) }
        case .browse: browseRow
        case .key(let key): homeRow(key)
        }
    }

    @ViewBuilder private func homeRow(_ key: String) -> some View {
        switch key {
        case "continue": continueRow
        case "mylist": myListRows
        case "recent": recentRow
        case "foryou": forYouRow
        case "live": favoriteChannelsRow
        case "movies":
            let top = index.popularMovies
            if !top.isEmpty { movieRow(L("Movies"), Array(top.prefix(30)), all: top) }
        case "series":
            let top = index.popularSeries
            if !top.isEmpty { seriesRow(L("Series"), Array(top.prefix(30)), all: top) }
        default:
            if key.hasPrefix(HomeLayout.collectionPrefix),
               let c = store.collection(String(key.dropFirst(HomeLayout.collectionPrefix.count))) {
                collectionRow(c)
            }
        }
    }

    /// Build 86: rij Categorieën: de grootste genres (en categorieën van je server) als tegels, met als laatste
    /// "Alle categorieën".
    @ViewBuilder private var browseRow: some View {
        let tiles = browse.index.homeTiles()
        if !tiles.isEmpty {
            let w = Theme.landscapeWidth * 0.8
            MediaRow(title: L("Categories"), onSeeAll: { showCategories = true }) {
                ForEach(tiles) { c in
                    Button { browseOpen = c } label: {
                        BrowseCategoryTile(title: c.title, count: c.count(.all), covers: c.covers(.all), colors: c.colors)
                            .frame(width: w)
                    }
                    .cardButton()
                    .tileHover()
                    .accessibilityLabel("\(c.title), \(L("%d titles", c.count(.all)))")
                }
                Button { showCategories = true } label: { BrowseAllTile().frame(width: w) }
                    .cardButton()
                    .tileHover()
            }
        }
    }

    @ViewBuilder private var top10MoviesRow: some View {
        let kids = store.activeProfile?.kids ?? false
        if !trendingMovies.isEmpty {
            top10Row(kids ? L("Top 10 kids movies") : L("Top 10 movies today"), movies: Array(trendingMovies.prefix(10)))
        }
    }

    @ViewBuilder private var top10SeriesRow: some View {
        let kids = store.activeProfile?.kids ?? false
        if !trendingSeries.isEmpty {
            top10Row(kids ? L("Top 10 kids series") : L("Top 10 series today"), series: Array(trendingSeries.prefix(10)))
        }
    }

    /// Favoriete zenders; zonder favorieten de laatst bekeken zenders.
    private var liveChannels: (list: [Channel], favs: [Channel]) {
        let favs = pid.map { p in store.favorites.compactMap { k in index.channel(forKey: k, playlist: p) } } ?? []
        let recent = favs.isEmpty ? (pid.map { p in store.recentChannels.compactMap { k in index.channel(forKey: k, playlist: p) } } ?? []) : []
        return (favs.isEmpty ? recent : favs, favs)
    }

    @ViewBuilder private var favoriteChannelsRow: some View {
        let lc = liveChannels
        let list = lc.list, favs = lc.favs
        if !list.isEmpty {
            MediaRow(title: favs.isEmpty ? L("Recently watched channels") : L("Favorite channels")) {
                ForEach(list) { c in
                    Button { app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: list) } label: {
                        ChannelCard(channel: c, now: lib.nowPlaying(c), favorite: !favs.isEmpty)
                    }
                    .cardButton()
                    .contextMenu {
                        Button { collecting = .channel(c) } label: {
                            Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                }
            }
        }
    }

    /// Rij van een eigen collectie (op Films/Series alleen de films of series daaruit).
    @ViewBuilder private func collectionRow(_ c: BingrCollection) -> some View {
        let content = collectionContent[c.id] ?? CollectionContent()
        let channels = filter == .all ? content.channels : []
        let movies = filter == .series ? [] : content.movies
        let series = filter == .movies ? [] : content.series
        if !(channels.isEmpty && movies.isEmpty && series.isEmpty) {
            let titles: [DetailTarget] = movies.map { .movie($0) } + series.map { .series($0) }
            MediaRow(title: c.name, onSeeAll: seeAll(c.name, titles)) {
                ForEach(channels.prefix(40)) { ch in
                    Button { app.play(Playables.channel(ch, now: lib.nowPlaying(ch)), zap: channels) } label: {
                        ChannelCard(channel: ch, now: lib.nowPlaying(ch))
                    }
                    .cardButton()
                    .contextMenu { collectionItemMenu(c, .init(type: .channel, id: ch.id)) }
                }
                ForEach(titles.prefix(60)) { t in
                    Button { detail = t } label: {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster, imdbID: trakt.imdb(for: m),
                                       watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)),
                                       progress: store.progress[m.id]?.fraction, language: ContentLanguage.of(m))
                        case .series(let se):
                            let imdb = trakt.imdb(for: se)
                            PosterCard(title: se.title, poster: se.poster, imdbID: imdb,
                                       watchedEpisodes: Playables.watchedEpisodeCount(se, imdb: imdb), language: ContentLanguage.of(se))
                        }
                    }
                    .cardButton()
                    .contextMenu {
                        collectionItemMenu(c, t.isSeries ? .init(type: .series, id: t.id) : .init(type: .movie, id: t.id))
                    }
                }
            }
        }
    }

    private func seeAll(_ title: String, _ items: [DetailTarget]) -> (() -> Void)? {
        guard items.count > 6 else { return nil }
        return { category = CategoryTarget(title: title, items: items) }
    }

    @ViewBuilder private func collectionItemMenu(_ c: BingrCollection, _ item: CollectionItem) -> some View {
        if c.kind == .manual {
            Button(role: .destructive) { store.toggleInCollection(c.id, item) } label: {
                Label(L("Remove from collection"), systemImage: "minus.circle")
            }
        }
        Button { collecting = CollectionTarget(item: item, title: c.name) } label: {
            Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
        }
    }

    @ViewBuilder private var myListRows: some View {
        if filter == .all {
            // Home: films én series uit Mijn lijst in één rij
            let mine: [DetailTarget] = myListMovies.map { DetailTarget.movie($0) } + myListSeries.map { DetailTarget.series($0) }
            if !mine.isEmpty {
                MediaRow(title: L("My List"), onSeeAll: { category = CategoryTarget(title: L("My List"), items: mine) }) {
                    ForEach(mine) { t in
                        Button { detail = t } label: {
                            switch t {
                            case .movie(let m):
                                PosterCard(title: m.title, poster: m.poster, imdbID: trakt.imdb(for: m),
                                           watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)), progress: store.progress[m.id]?.fraction, language: ContentLanguage.of(m))
                            case .series(let se):
                                let imdb = trakt.imdb(for: se)
                                PosterCard(title: se.title, poster: se.poster, imdbID: imdb,
                                           watchedEpisodes: Playables.watchedEpisodeCount(se, imdb: imdb), language: ContentLanguage.of(se))
                            }
                        }
                        .cardButton()
                    }
                }
            }
        }
        if filter == .movies {
            let mine = myListMovies
            if !mine.isEmpty { movieRow(L("My List"), mine, all: mine) }
        }
        if filter == .series {
            let mine = myListSeries
            if !mine.isEmpty { seriesRow(L("My List"), mine, all: mine) }
        }
    }

    @ViewBuilder private var recentRow: some View {
        let all = index.recent
        if !all.isEmpty { movieRow(L("Recently added"), Array(all.prefix(30)), all: all) }
    }

    /// Mijn lijst via de opgeslagen sleutels (snel), niet door de hele bibliotheek te lopen
    private var myListMovies: [Movie] {
        guard let pid else { return [] }
        return store.myList.compactMap { index.movie(forKey: $0, playlist: pid) }.sorted { $0.title < $1.title }
    }
    private var myListSeries: [Series] {
        guard let pid else { return [] }
        return store.myList.compactMap { index.series(forKey: $0, playlist: pid) }.sorted { $0.title < $1.title }
    }

    private func matchTraktPlayback() {
        guard !trakt.playback.isEmpty else { traktContinue = []; return }
        var out: [ContinueItem] = []
        for p in trakt.playback where p.type == "movie" {
            guard let imdb = p.imdb, let m = index.movie(imdb: imdb) ?? lib.movies.first(where: { trakt.imdb(for: $0) == imdb }) else { continue }
            out.append(ContinueItem(id: m.id, title: m.title, subtitle: "Trakt · \(Int(p.progress))%", artwork: m.poster,
                                    fraction: p.progress / 100, updated: .distantPast, isMovie: true, traktPlaybackID: p.id))
        }
        traktContinue = out
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
        // altijd alfabetisch op titel, films en series door elkaar (zonder taallabel, hoofdletters en accenten)
        let items = forYou.filter { t in
            switch (filter, t) {
            case (.movies, .series), (.series, .movie): return false
            default: return true
            }
        }.sorted(by: Self.alphabetical)
        if !items.isEmpty {
            MediaRow(title: L("For you"), onSeeAll: { category = CategoryTarget(title: L("For you"), items: items) }) {
                ForEach(items) { t in
                    Button { detail = t } label: {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster,
                                       watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)),
                                       badge: L("MOVIE"), badgeAlignment: .topLeading, language: ContentLanguage.of(m))
                        case .series(let s):
                            // "N BEKEKEN" komt onder het label SERIE (zoals op bingr.online)
                            PosterCard(title: s.title, poster: s.poster,
                                       badge: L("SERIES"), watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: trakt.imdb(for: s)),
                                       badgeAlignment: .topLeading, language: ContentLanguage.of(s))
                        }
                    }
                    .cardButton()
                }
            }
        }
    }

    /// Alfabetisch op titel, zonder onderscheid in hoofdletters en accenten (bij gelijke titel op id)
    private static func alphabetical(_ a: DetailTarget, _ b: DetailTarget) -> Bool {
        let x = sortTitle(a), y = sortTitle(b)
        let r = x.compare(y, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                          range: nil, locale: .current)
        return r == .orderedSame ? a.id < b.id : r == .orderedAscending
    }

    /// Titel om op te sorteren: zoals op de poster (zonder taallabel)
    private static func sortTitle(_ t: DetailTarget) -> String {
        switch t {
        case .movie(let m): return ContentLanguage.displayTitle(m.title)
        case .series(let s): return ContentLanguage.displayTitle(s.title)
        }
    }

    private func movieRow(_ title: String, _ items: [Movie], all: [Movie]? = nil) -> some View {
        MediaRow(title: title, onSeeAll: all.map { list in { category = CategoryTarget(title: title, items: list.map { .movie($0) }) } }) {
            ForEach(items) { m in
                let imdb = trakt.imdb(for: m)
                Button { detail = .movie(m) } label: {
                    PosterCard(title: m.title, poster: m.poster, imdbID: imdb,
                               watched: Playables.isWatched(movie: m, imdb: imdb),
                               progress: store.progress[m.id]?.fraction, language: ContentLanguage.of(m))
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
                Button { detail = .series(s) } label: {
                    PosterCard(title: s.title, poster: s.poster, imdbID: imdb,
                               watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: imdb), language: ContentLanguage.of(s))
                }
                .cardButton()
                .contextMenu {
                    if let pid {
                        Button { store.toggleMyList(pid, s.id) } label: {
                            Label(store.inMyList(pid, s.id) ? L("Remove from My List") : L("Add to My List"), systemImage: "plus")
                        }
                    }
                    Button { collecting = .series(s) } label: {
                        Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
                    }
                }
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
                              badge: (m.addedAt ?? .distantPast) > Date().addingTimeInterval(-14 * 86400) ? L("Recently added") : nil, language: ContentLanguage.of(m))
                }.cardButton()
            }
            ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                Button { detail = .series(s) } label: {
                    Top10Card(rank: i + 1, title: s.title, poster: s.poster, language: ContentLanguage.of(s),
                              watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: trakt.imdb(for: s)))
                }.cardButton()
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
        Button { collecting = .movie(m) } label: {
            Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
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
        let movieIDs = index.movieByID
        let seriesTitles = index.seriesTitles
        var out: [ContinueItem] = store.progress.compactMap { key, e in
            guard store.belongsToActive(e.profileID) else { return nil }   // alleen van dit profiel
            guard e.playlistID == nil || e.playlistID == pid else { return nil }   // alleen van deze server
            let isMovie = movieIDs[key] != nil
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
        if filter != .series && !traktContinue.isEmpty {
            let known = Set(out.map(\.id))
            out += traktContinue.filter { !known.contains($0.id) }
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

/// Opnieuw uitrekenen als de lijst of de collecties veranderen.
private struct CollectionsKey: Equatable {
    let version: Int
    let source: UUID?
    let collections: [BingrCollection]
}

#if !os(tvOS)
/// iOS bovenbalk (wordt donker bij scrollen, zoals Netflix).
private struct HomeTopBar: View {
    let scroll: ScrollTracker
    let filter: HomeView.Filter
    let onSearch: () -> Void
    let onTab: (Int) -> Void

    var body: some View {
        let off = Double(-scroll.y)
        VStack(alignment: .leading, spacing: 8) {
            bar
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(min(0.95, 0.55 + off / 300)), .black.opacity(min(0.9, off / 300))],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // Build 87: de chips Series / Films onder het logo zijn weg (Films en Series staan in de tabbalk,
    // Categorieën in Mijn Bingr en als rij op Home).

    private var bar: some View {
        HStack(spacing: 14) {
            BingrLogo(size: 26)
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(L("Search"))
            // build 72: profielmenu zoals op bingr.online (andere profielen, Mijn Bingr, Instellingen, Uitloggen…)
            ProfileMenuButton {
                HStack(spacing: 5) {
                    ProfileAvatar(size: 30)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
                .frame(height: 34)
                .contentShape(Rectangle())
            }
        }
    }
}
#endif

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Vooraf berekende rijen voor Home/Films/Series: één keer per lijst, op de achtergrond.
struct HomeIndex {
    struct Group<T>: Identifiable { let id: String; let items: [T] }
    var movieGroups: [Group<Movie>] = []
    var seriesGroups: [Group<Series>] = []
    var recent: [Movie] = []
    var movieByID: [String: Movie] = [:]
    var seriesByID: [String: Series] = [:]
    var channelByID: [String: Channel] = [:]
    var movieByIMDb: [String: Movie] = [:]
    var seriesTitles: Set<String> = []
    /// Rij "Films"/"Series" op het startscherm: best beoordeeld, anders nieuwst
    var popularMovies: [Movie] = []
    var popularSeries: [Series] = []

    static func build(_ lib: Library) -> HomeIndex {
        var x = HomeIndex()
        var mOrder: [String] = [], mGroups: [String: [Movie]] = [:]
        for m in lib.movies {
            if mGroups[m.group] == nil { mOrder.append(m.group) }
            mGroups[m.group, default: []].append(m)
            x.movieByID[m.id] = m
            if let i = m.imdbID, !i.isEmpty { x.movieByIMDb[i] = m }
        }
        x.movieGroups = mOrder.map { Group(id: $0, items: mGroups[$0] ?? []) }
        var sOrder: [String] = [], sGroups: [String: [Series]] = [:]
        for s in lib.series {
            if sGroups[s.group] == nil { sOrder.append(s.group) }
            sGroups[s.group, default: []].append(s)
            x.seriesByID[s.id] = s
            x.seriesTitles.insert(s.title)
        }
        x.seriesGroups = sOrder.map { Group(id: $0, items: sGroups[$0] ?? []) }
        for c in lib.channels { x.channelByID[c.id] = c }
        x.recent = lib.movies.filter { $0.addedAt != nil }.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        x.popularMovies = Array(lib.movies.filter { $0.poster != nil }
            .sorted { ($0.rating ?? 0, $0.addedAt ?? .distantPast) > ($1.rating ?? 0, $1.addedAt ?? .distantPast) }.prefix(60))
        x.popularSeries = Array(lib.series.filter { $0.poster != nil }.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(60))
        return x
    }

    private func itemID(_ key: String, _ playlist: UUID) -> Substring? {
        let p = playlist.uuidString
        guard key.count > p.count, key.hasPrefix(p) else { return nil }
        return key.dropFirst(p.count + 1)
    }
    func movie(forKey k: String, playlist: UUID) -> Movie? { itemID(k, playlist).flatMap { movieByID[String($0)] } }
    func series(forKey k: String, playlist: UUID) -> Series? { itemID(k, playlist).flatMap { seriesByID[String($0)] } }
    func channel(forKey k: String, playlist: UUID) -> Channel? { itemID(k, playlist).flatMap { channelByID[String($0)] } }
    func movie(imdb: String) -> Movie? { movieByIMDb[imdb] }
}
