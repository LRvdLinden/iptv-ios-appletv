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
    /// Build 140: vaste, roulerende selectie voor het billboard (Voor jou + Nieuw op Bingr), wisselt om de 8 seconden;
    /// de start schuift elke dag één plek op (HeroRotation)
    @State private var heroItems: [DetailTarget] = []
    @State private var heroIndex = 0
    @State private var trendingMovies: [Movie] = []
    @State private var trendingSeries: [Series] = []
    @State private var forYou: [DetailTarget] = []
    /// Build 140: zonder kijkgeschiedenis van dit profiel: populaire titels onder de kop "Populair"
    @State private var forYouPopular = false
    /// Build 140: Nieuw op Bingr: laatst toegevoegd aan de bibliotheek (alle servers), nieuwste eerst
    @State private var newOnBingr: [DetailTarget] = []
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
    /// Build 128: items van andere servers (Mijn lijst, Verder kijken, favoriete zenders, collecties)
    @ObservedObject private var cross = CrossServer.shared
    @State private var prompt: CrossServer.Prompt?
    /// P0-fix: `.task` start bij elke terugkeer naar het tabblad opnieuw. Onthouden wat al klaar is, zodat Home,
    /// Films en Series dan niet opnieuw door de hele bibliotheek lopen (dat bevroor de app).
    @State private var indexVersion = -1
    @State private var preparedKey: String?
    @State private var preparedAt = Date.distantPast
    @State private var traktMatchedKey: TraktMatchKey?
    @State private var collectionsDone: CollectionsKey?
    /// Build 111: rijen Binnenkort op Bingr / Nieuw op Bingr (TMDB, gekoppeld aan je bibliotheek op de achtergrond)
    @State private var discover: [DiscoverKind: [DiscoverEntry]] = [:]
    /// Build 111: telt op als TMDB-titels uit Mijn lijst (van een ander apparaat) opgezocht zijn
    @State private var discoverKnownTick = 0

    private var lib: Library { playlists.library }
    private var pid: UUID? { playlists.source?.id }
    private var prepareKey: String {
        "\(store.activeProfileID?.uuidString ?? "")-\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)"
    }
    /// Zelfde sleutel als de gedeelde titel-index (MatcherCache)
    private var matcherKey: String { "\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)" }
    private var collectionsKey: CollectionsKey {
        CollectionsKey(version: playlists.libraryVersion, source: pid, collections: store.activeCollections)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tvScaled(26)) {
                    // App Store-screenshots: scherm "top10" begint direct met de Top 10
                    if let hero, !(Screenshots.isActive && Screenshots.screen == "top10") {
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
        .task(id: prepareKey) { await prepare() }
        .task(id: heroItems.map(\.id)) { await rotateHero() }
        .task(id: playlists.libraryVersion) {
            let v = playlists.libraryVersion
            guard indexVersion != v else { return }   // al gebouwd: niet bij elke terugkeer naar het tabblad
            // één keer per lijstversie gebouwd en gedeeld door Home, Films en Series
            let built = await HomeIndexCache.shared.index(for: lib, version: v)
            guard !Task.isCancelled else { return }
            index = built
            indexVersion = v
        }
        // Trakt-voortgang koppelen zodra de index er is of Trakt iets nieuws heeft (ook bij gewijzigd percentage)
        .task(id: TraktMatchKey(version: indexVersion, playback: trakt.playback)) { await matchTraktPlayback() }
        .task(id: playlists.libraryVersion) { if filter == .all { browse.refresh(playlists) } }
        .onAppear { if filter == .all { browse.refresh(playlists) } }
        // build 111: TMDB-rijen (12 uur bewaard) zodra de index er is; opnieuw bij ander profiel, taal of indeling
        .task(id: DiscoverKey(version: indexVersion, profile: store.activeProfileID, kinds: discoverKinds,
                              language: Localizer.shared.language)) { await loadDiscover() }
        // build 111: TMDB-titels in Mijn lijst die dit apparaat nog niet kent (op een ander apparaat toegevoegd)
        .task(id: store.myList) { await resolveExternalMyList() }
        .task(id: collectionsKey) {
            let key = collectionsKey
            guard key != collectionsDone else { return }   // al bijgewerkt: niet bij elke terugkeer opnieuw
            // Build 56: wijzigingen (sync, nieuwe lijst) komen vaak vlak na elkaar; even wachten, en niet midden in
            // het scrollen herberekenen. De eerste keer meteen.
            if !collectionContent.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await ScrollActivity.shared.waitUntilIdle()
                if Task.isCancelled { return }
            }
            let l = lib, list = store.activeCollections, src = pid, version = playlists.libraryVersion
            // buiten de hoofdthread, en per (lijst, server, collectie) bewaard: alleen gewijzigde collecties rekenen opnieuw
            let raw = await CollectionCache.shared.content(for: list, lib: l, version: version, source: src)
            // geen dubbele id's in de rijen (op de achtergrond)
            let out = await Task.detached(priority: .userInitiated) {
                raw.mapValues { c in
                    CollectionContent(channels: uniqueByID(c.channels), movies: uniqueByID(c.movies), series: uniqueByID(c.series))
                }
            }.value
            guard !Task.isCancelled else { return }
            if out != collectionContent { collectionContent = out }   // gelijk = Home niet opnieuw tekenen
            collectionsDone = key
        }
        .sheet(item: $collecting) { AddToCollectionSheet(target: $0) }
        .fullScreenCover(item: $category) { CategoryView(target: $0) }
        .resumeDialog($resumeChoice) { detail = $0 }
        .crossServerPrompt($prompt)
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
        case "recent": return !index.recentTitles.isEmpty   // build 111: Home = films én series, laatste 30 dagen
        case "upcoming": return !(discover[.upcoming] ?? []).isEmpty
        case "streaming": return !newOnBingrItems.isEmpty   // build 140: Nieuw op Bingr uit je bibliotheek
        case "foryou": return !forYou.isEmpty
        case "movies": return !index.popularMovies.isEmpty
        case "series": return !index.popularSeries.isEmpty
        default:
            guard key.hasPrefix(HomeLayout.collectionPrefix),
                  let c = store.collection(String(key.dropFirst(HomeLayout.collectionPrefix.count))) else { return false }
            let content = collectionContent[c.id] ?? CollectionContent()
            return !(content.channels.isEmpty && content.movies.isEmpty && content.series.isEmpty)
                || !cross.collectionContent(c, active: pid).isEmpty
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
        case "upcoming": discoverRow(.upcoming)
        case "streaming": newOnBingrRow
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
    /// Build 128: van alle servers (andere servers via CrossServer); dezelfde zender op twee servers één keer.
    private var liveChannels: (list: [Channel], favs: [Channel]) {
        _ = cross.version
        func channel(_ k: String) -> Channel? {
            if let p = pid, isActive(k) { return index.channel(forKey: k, playlist: p) }
            return cross.channel(forKey: k)
        }
        let favKeys = store.favorites.sorted { cross.addedAt($0, field: "favorites") > cross.addedAt($1, field: "favorites") }
        let favs = CrossServer.dedupe(uniqueByID(favKeys.compactMap(channel)), identity: CrossServer.identity)
        let recent = favs.isEmpty ? CrossServer.dedupe(store.recentChannels.compactMap(channel), identity: CrossServer.identity) : []
        return (favs.isEmpty ? recent : favs, favs)
    }

    /// Hoort deze sleutel bij de open server? (server-id hoofdletterongevoelig)
    private func isActive(_ key: String) -> Bool {
        guard let pid, let bar = key.firstIndex(of: "|") else { return false }
        return key[..<bar].caseInsensitiveCompare(pid.uuidString) == .orderedSame
    }

    @ViewBuilder private var favoriteChannelsRow: some View {
        let lc = liveChannels
        let list = lc.list, favs = lc.favs
        if !list.isEmpty {
            MediaRow(title: favs.isEmpty ? L("Recently watched channels") : L("Favorite channels")) {
                ForEach(list) { c in
                    Button {
                        CrossServerOpen.channel(c, list: favs.isEmpty ? .recentChannels : .favorites,
                                                onChannel: { app.play(Playables.channel($0, now: lib.nowPlaying($0)), zap: list) },
                                                onPrompt: { prompt = $0 })
                    } label: {
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
        let content = mergedCollection(c)
        let channels = filter == .all ? content.channels : []
        let movies = filter == .series ? [] : content.movies
        let series = filter == .movies ? [] : content.series
        if !(channels.isEmpty && movies.isEmpty && series.isEmpty) {
            let titles: [DetailTarget] = movies.map { .movie($0) } + series.map { .series($0) }
            MediaRow(title: c.name, onSeeAll: seeAll(c.name, titles)) {
                ForEach(channels.prefix(40)) { ch in
                    Button {
                        CrossServerOpen.channel(ch, list: .collection(c.id),
                                                onChannel: { app.play(Playables.channel($0, now: lib.nowPlaying($0)), zap: channels) },
                                                onPrompt: { prompt = $0 })
                    } label: {
                        ChannelCard(channel: ch, now: lib.nowPlaying(ch))
                    }
                    .cardButton()
                    .contextMenu { collectionItemMenu(c, .init(type: .channel, id: ch.id, sid: ch.sourceID?.uuidString)) }
                }
                ForEach(titles.prefix(60)) { t in
                    Button { open(t, .collection(c.id)) } label: {
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
                        collectionItemMenu(c, t.isSeries ? .init(type: .series, id: t.id, sid: t.sourceID?.uuidString)
                                                         : .init(type: .movie, id: t.id, sid: t.sourceID?.uuidString))
                    }
                }
            }
        }
    }

    /// Build 128: collectie met de items van andere servers erbij (dezelfde titel op twee servers één keer)
    private func mergedCollection(_ c: BingrCollection) -> CollectionContent {
        var content = collectionContent[c.id] ?? CollectionContent()
        let other = cross.collectionContent(c, active: pid)
        guard !other.isEmpty else { return content }
        content.channels = CrossServer.dedupe(uniqueByID(content.channels + other.channels), identity: CrossServer.identity)
        content.movies = CrossServer.dedupe(uniqueByID(content.movies + other.movies), identity: CrossServer.identity)
        content.series = CrossServer.dedupe(uniqueByID(content.series + other.series), identity: CrossServer.identity)
        return content
    }

    /// Titel openen; van een andere server en nog niet gevonden → eerst zoeken, anders de melding (build 128)
    private func open(_ t: DetailTarget, _ list: CrossServer.ListKind) {
        CrossServerOpen.title(t, list: list, onTarget: { detail = $0 }, onPrompt: { prompt = $0 })
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
                        Button { open(t, .myList) } label: {
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
        if filter == .all {
            // build 111: "Nieuw toegevoegd": films én series van de laatste 30 dagen, nieuwste eerst (max. 30)
            let items = index.recentTitles
            if !items.isEmpty {
                MediaRow(title: L("Recently added"), onSeeAll: seeAll(L("Recently added"), items)) {
                    ForEach(items) { t in titleButton(t) }
                }
            }
        } else {
            let all = index.recent
            if !all.isEmpty { movieRow(L("Recently added"), Array(all.prefix(30)), all: all) }
        }
    }

    /// Mijn lijst via de opgeslagen sleutels (snel), niet door de hele bibliotheek te lopen.
    /// Build 111: plus TMDB-titels (Binnenkort / Nieuw op streamingdiensten) die niet in je bibliotheek staan.
    /// Build 128: Mijn lijst over alle servers, laatst toegevoegd eerst; dezelfde titel op twee servers één tegel
    /// (die van de open server gaat voor).
    private var myListMovies: [Movie] {
        guard let pid else { return [] }
        _ = cross.version
        let ext = showExternalInMyList
        var mine: [(Movie, Double)] = [], other: [(Movie, Double)] = []
        // build 141: herkomst per sleutel zoals in de zelftest (MyListID): open server, TMDB-titel of andere server
        for k in store.myList {
            switch MyListID.origin(of: k, activeSID: pid.uuidString) {
            case .active?:
                if let m = index.movie(forKey: k, playlist: pid) { mine.append((m, cross.addedAt(k, field: "myList"))) }
            case .external?:
                if ext, let m = DiscoverKnown.shared.movie(forKey: k, playlist: pid) { mine.append((m, cross.addedAt(k, field: "myList"))) }
            case .otherServer?:
                if let m = cross.movie(forKey: k) { other.append((m, cross.addedAt(k, field: "myList"))) }
            case nil: break
            }
        }
        return Self.ordered(mine + other, identity: CrossServer.identity)
    }
    private var myListSeries: [Series] {
        guard let pid else { return [] }
        _ = cross.version
        let ext = showExternalInMyList
        var mine: [(Series, Double)] = [], other: [(Series, Double)] = []
        for k in store.myList {
            switch MyListID.origin(of: k, activeSID: pid.uuidString) {
            case .active?:
                if let s = index.series(forKey: k, playlist: pid) { mine.append((s, cross.addedAt(k, field: "myList"))) }
            case .external?:
                if ext, let s = DiscoverKnown.shared.series(forKey: k, playlist: pid) { mine.append((s, cross.addedAt(k, field: "myList"))) }
            case .otherServer?:
                if let s = cross.series(forKey: k) { other.append((s, cross.addedAt(k, field: "myList"))) }
            case nil: break
            }
        }
        return Self.ordered(mine + other, identity: CrossServer.identity)
    }

    /// Eén tegel per titel (de eerste, dus de open server), daarna laatst toegevoegd eerst (bij gelijke tijd op titel)
    private static func ordered<T: Identifiable>(_ items: [(T, Double)], identity: (T) -> String) -> [T] where T.ID == String {
        var seenID = Set<String>(), seenWork = Set<String>()
        let kept = items.filter { seenID.insert($0.0.id).inserted && seenWork.insert(identity($0.0)).inserted }
        return kept.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : identity(a.0) < identity(b.0) }.map { $0.0 }
    }
    /// TMDB-titels alleen zonder leeftijdsgrens (die profielen zien alleen hun eigen, gefilterde bibliotheek)
    private var showExternalInMyList: Bool {
        _ = discoverKnownTick   // opnieuw tekenen zodra titels van een ander apparaat opgezocht zijn
        return store.activeProfile?.effectiveAgeLimit == nil
    }

    // MARK: build 111: Binnenkort op Bingr / Nieuw op Bingr (TMDB; namen sinds build 112)

    /// Rijen die in de Home-indeling aan staan (alleen die worden opgehaald)
    private var discoverKinds: [DiscoverKind] {
        guard filter == .all else { return [] }
        let rows = store.homeLayout.effective(collections: store.activeCollections)
        // build 140: Nieuw op Bingr komt uit je eigen bibliotheek (NewOnBingr), niet meer van TMDB
        return DiscoverKind.allCases.filter { k in k != .streaming && rows.contains { $0.key == k.homeKey && $0.visible } }
    }

    @ViewBuilder private func discoverRow(_ kind: DiscoverKind) -> some View {
        let list = discover[kind] ?? []
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: tvScaled(4)) {
                MediaRow(title: kind.title) {
                    ForEach(list) { e in
                        if let m = e.match {
                            titleButton(m)
                        } else {
                            Button { detail = e.item.target } label: {
                                // build 112: datum als rood label linksboven (zoals SERIE/FILM)
                                PosterCard(title: e.item.title, poster: e.item.poster, badge: e.item.dateLabel,
                                           badgeAlignment: .topLeading)
                            }
                            .cardButton()
                            .contextMenu {
                                if let pid {
                                    Button { store.toggleMyList(pid, e.item.id); PlusCheckFeedback.toggled() } label: {
                                        Label(store.inMyList(pid, e.item.id) ? L("Remove from My List") : L("Add to My List"),
                                              systemImage: PlusCheckGlyph.symbol(store.inMyList(pid, e.item.id)))
                                    }
                                }
                            }
                        }
                    }
                }
                // build 112: geen bronvermelding meer onder de rij (staat in Instellingen → Over)
            }
        }
    }

    /// Build 140: Nieuw op Bingr (op Films/Series alleen dat soort)
    private var newOnBingrItems: [DetailTarget] {
        newOnBingr.filter { t in
            switch (filter, t) {
            case (.movies, .series), (.series, .movie): return false
            default: return true
            }
        }
    }

    @ViewBuilder private var newOnBingrRow: some View {
        let items = newOnBingrItems
        if !items.isEmpty {
            MediaRow(title: L("New on Bingr"), onSeeAll: seeAll(L("New on Bingr"), items)) {
                // build 141: met het label Film/Serie, zoals bij Voor jou
                ForEach(items) { t in titleButton(t, kindBadge: true) }
            }
        }
    }

    /// Build 140: het billboard wisselt vanzelf (om de 8 seconden), niet tijdens het afspelen.
    private func rotateHero() async {
        guard heroItems.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(HeroRotation.interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if app.playing != nil || Screenshots.isActive { continue }
            // build 141: de selectie kan intussen leeg of korter zijn (bijv. ander profiel of bibliotheek ververst,
            // terwijl deze taak nog niet geannuleerd is, zoals op een tabblad dat niet in beeld is): nooit delen door
            // nul of buiten de lijst lezen
            let items = heroItems
            guard items.count > 1 else { return }
            heroIndex = (min(max(heroIndex, 0), items.count - 1) + 1) % items.count
            withAnimation(.easeInOut(duration: 0.6)) { hero = items[heroIndex] }
        }
    }

    /// Build 140: de vaste selectie voor het billboard: om en om uit Voor jou (op volgorde van relevantie) en Nieuw op
    /// Bingr, maximaal 8, met poster en van het soort van dit tabblad. Geen willekeur per opening.
    private func updateHeroItems(forYouRanked: [DetailTarget]) {
        guard !Screenshots.isActive else { return }
        func ok(_ t: DetailTarget) -> Bool {
            switch (filter, t) {
            case (.movies, .series), (.series, .movie): return false
            default: return t.posterURL != nil
            }
        }
        let fy = forYouRanked.filter(ok), nw = newOnBingr.filter(ok)
        let ids = HeroRotation.pick(forYou: fy.map(\.id), new: nw.map(\.id))
        let byID = Dictionary((fy + nw).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items = HeroRotation.rotated(ids.compactMap { byID[$0] }, day: HeroRotation.day(Date()))
        if items.isEmpty {
            // nog niets: de Top 10 van vandaag (vaste volgorde)
            var t: [DetailTarget] = []
            if filter != .series { t += trendingMovies.prefix(4).map { .movie($0) } }
            if filter != .movies { t += trendingSeries.prefix(4).map { .series($0) } }
            items = HeroRotation.rotated(t.filter(ok), day: HeroRotation.day(Date()))
        }
        guard !items.isEmpty, items.map(\.id) != heroItems.map(\.id) else { return }
        heroItems = items
        heroIndex = 0
        if hero?.id != items[0].id { withAnimation(.easeInOut(duration: 0.4)) { hero = items[0] } }
    }

    /// Poster van een titel uit je bibliotheek (film of serie), met het gewone menu.
    /// `kindBadge` (build 141): label FILM/SERIE linksboven, zoals bij Voor jou (rij Nieuw op Bingr)
    @ViewBuilder private func titleButton(_ t: DetailTarget, kindBadge: Bool = false) -> some View {
        switch t {
        case .movie(let m):
            let imdb = trakt.imdb(for: m)
            Button { detail = t } label: {
                PosterCard(title: m.title, poster: m.poster, imdbID: imdb,
                           watched: Playables.isWatched(movie: m, imdb: imdb),
                           progress: store.progress[m.id]?.fraction,
                           badge: kindBadge ? L("MOVIE") : nil, badgeAlignment: .topLeading, language: ContentLanguage.of(m))
            }
            .cardButton()
            .contextMenu { movieMenu(m, imdb: imdb) }
        case .series(let s):
            let imdb = trakt.imdb(for: s)
            Button { detail = t } label: {
                PosterCard(title: s.title, poster: s.poster, imdbID: imdb,
                           badge: kindBadge ? L("SERIES") : nil,
                           watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: imdb),
                           badgeAlignment: .topLeading, language: ContentLanguage.of(s))
            }
            .cardButton()
            .contextMenu {
                // build 140: de eigen server van de serie (een serie van een andere server kwam anders met de sleutel
                // van de open server in Mijn lijst en verscheen daar niet)
                if let pid = s.sourceID ?? pid {
                    Button { store.toggleMyList(pid, s.id); PlusCheckFeedback.toggled() } label: {
                        Label(store.inMyList(pid, s.id) ? L("Remove from My List") : L("Add to My List"),
                              systemImage: PlusCheckGlyph.symbol(store.inMyList(pid, s.id)))
                    }
                }
                Button { collecting = .series(s) } label: {
                    Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
                }
            }
        }
    }

    /// Eerst wat al bewaard is (meteen), daarna het netwerk (12 uur bewaard); koppelen aan je bibliotheek op de
    /// achtergrond. Kinderprofiel: animatie/familie; profiel met leeftijdsgrens: alleen titels uit de eigen bibliotheek.
    private func loadDiscover() async {
        let kinds = discoverKinds
        guard !kinds.isEmpty else { if !discover.isEmpty { discover = [:] }; return }
        guard indexVersion >= 0, !lib.movies.isEmpty || !lib.series.isEmpty else { return }
        let profile = store.activeProfile
        let kids = profile?.kids ?? false
        let onlyLibrary = profile?.effectiveAgeLimit != nil
        let idx = index
        let matcher = await MatcherCache.shared.matcher(for: lib, key: matcherKey)
        guard !Task.isCancelled else { return }
        var out: [DiscoverKind: [DiscoverEntry]] = [:]
        for k in kinds {
            let cached = await Task.detached(priority: .utility) { DiscoverStore.cached(k, kids: kids) }.value
            // build 112: Nieuw op Bingr alleen met titels uit je bibliotheek (k.onlyLibrary)
            if !cached.isEmpty { out[k] = await DiscoverStore.match(cached, matcher: matcher, index: idx, onlyLibrary: onlyLibrary || k.onlyLibrary) }
        }
        guard !Task.isCancelled else { return }
        if out != discover { discover = out }
        for k in kinds {
            let items = await DiscoverStore.shared.get(k, kids: kids)
            guard !Task.isCancelled else { return }
            out[k] = await DiscoverStore.match(items, matcher: matcher, index: idx, onlyLibrary: onlyLibrary || k.onlyLibrary)
        }
        guard !Task.isCancelled else { return }
        if out != discover { discover = out }
    }

    private func resolveExternalMyList() async {
        guard let pid else { return }
        // server-id hoofdletterongevoelig (web/Android/Samsung TV schrijven hem soms met kleine letters)
        // build 141: TMDB-titels onder elke server-id (zie MyListID.origin)
        _ = pid
        let ids = store.myList.compactMap { k -> String? in
            guard let bar = k.firstIndex(of: "|") else { return nil }
            let id = String(k[k.index(after: bar)...])
            return DiscoverItem.isExternal(id) ? id : nil
        }
        guard !ids.isEmpty else { return }
        let missing = await Task.detached(priority: .utility) { ids.filter { !DiscoverKnown.shared.contains($0) } }.value
        guard !missing.isEmpty else { return }
        if await DiscoverStore.shared.resolve(missing), !Task.isCancelled { discoverKnownTick += 1 }
    }

    /// P0-fix: voorheen `lib.movies.first(where: { trakt.imdb(for: $0) == imdb })` op de hoofdthread: per Trakt-item
    /// de hele bibliotheek door, met titel-opschoning (regex) per film. Bij tienduizenden films seconden vast, en dat
    /// in alle drie de tabbladen bij elke terugkeer en na elke Trakt-sync (bijv. na het kijken). Nu: IMDb-index, dan
    /// de gedeelde titel-index (op de achtergrond gebouwd) en alleen die ene kandidaat controleren.
    private func matchTraktPlayback() async {
        let key = TraktMatchKey(version: indexVersion, playback: trakt.playback)
        guard key != traktMatchedKey else { return }
        let items = trakt.playback.filter { $0.type == "movie" }
        guard !items.isEmpty else {
            if !traktContinue.isEmpty { traktContinue = [] }
            traktMatchedKey = key
            return
        }
        guard indexVersion >= 0 else { return }   // eerst de index
        let idx = index, l = lib, mk = matcherKey
        var matcher: TitleMatcher?
        var out: [ContinueItem] = []
        var seen = Set<String>()
        for p in items {
            guard let imdb = p.imdb else { continue }
            var found = idx.movie(imdb: imdb)
            if found == nil, !p.title.isEmpty {
                if matcher == nil { matcher = await MatcherCache.shared.matcher(for: l, key: mk) }
                if Task.isCancelled { return }
                if let c = matcher?.movie(ExternalTitle(titles: [p.title], year: nil)), trakt.imdb(for: c) == imdb { found = c }
            }
            guard let m = found, seen.insert(m.id).inserted else { continue }   // geen dubbele id's in de rij
            out.append(ContinueItem(id: m.id, title: m.title, subtitle: "Trakt · \(Int(p.progress))%", artwork: m.poster,
                                    fraction: p.progress / 100, updated: .distantPast, isMovie: true, traktPlaybackID: p.id))
        }
        guard !Task.isCancelled else { return }
        traktContinue = out
        traktMatchedKey = key
    }

    @ViewBuilder private var continueRow: some View {
        let items = continueWatching
        if !items.isEmpty {
            MediaRow(title: L("Continue watching")) {
                ForEach(items) { c in
                    Button { tapContinue(c) } label: {
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
            let title = forYouPopular ? L("Popular") : L("For you")
            MediaRow(title: title, onSeeAll: { category = CategoryTarget(title: title, items: items) }) {
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
                Button { open(.movie(m), .myList) } label: {
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
                Button { open(.series(s), .myList) } label: {
                    PosterCard(title: s.title, poster: s.poster, imdbID: imdb,
                               watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: imdb), language: ContentLanguage.of(s))
                }
                .cardButton()
                .contextMenu {
                    if let pid = s.sourceID ?? pid {
                        Button { store.toggleMyList(pid, s.id); PlusCheckFeedback.toggled() } label: {
                            Label(store.inMyList(pid, s.id) ? L("Remove from My List") : L("Add to My List"),
                                  systemImage: PlusCheckGlyph.symbol(store.inMyList(pid, s.id)))
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
        if let pid = m.sourceID ?? pid {
            Button { store.toggleMyList(pid, m.id); PlusCheckFeedback.toggled() } label: {
                Label(store.inMyList(pid, m.id) ? L("Remove from My List") : L("Add to My List"),
                      systemImage: PlusCheckGlyph.symbol(store.inMyList(pid, m.id)))
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
        /// Build 128: van een andere server (nil = de open server)
        var source: UUID? = nil
    }

    private var continueWatching: [ContinueItem] {
        let movieIDs = index.movieByID
        let seriesTitles = index.seriesTitles
        _ = cross.version
        var out: [ContinueItem] = store.progress.compactMap { key, e in
            guard store.belongsToActive(e.profileID) else { return nil }   // alleen van dit profiel
            // build 128: ook van andere servers (opgezocht in de catalogus van die server, zie CrossServer)
            if let other = e.playlistID, other != pid { return foreignContinue(key, e, server: other) }
            let isMovie = movieIDs[key] != nil
            // afleveringen alleen als de serie (nog) zichtbaar is voor dit profiel (niet verborgen/op slot/te oud)
            if !isMovie && !seriesTitles.contains(e.title) { return nil }
            if filter == .movies && !isMovie { return nil }
            if filter == .series && isMovie { return nil }
            let left = max(0, e.position / max(e.fraction, 0.01) - e.position)
            // build 141: de cover van de film of serie, niet het beeld van de scène (dat staat in de voortgang)
            let cover = isMovie ? movieIDs[key]?.poster : index.seriesByTitle[e.title]?.poster
            return ContinueItem(id: key, title: e.title, subtitle: L("%d min left", Int(left / 60)),
                                artwork: cover ?? e.artwork, fraction: e.fraction, updated: e.updated, isMovie: isMovie,
                                position: e.position > 0 ? e.position : nil)
        }
        // films die je in een andere app (via Trakt) half hebt gekeken
        if filter != .series && !traktContinue.isEmpty {
            let known = Set(out.map(\.id))
            out += traktContinue.filter { !known.contains($0.id) }
        }
        return Array(out.sorted { $0.updated > $1.updated }.prefix(20))
    }

    /// Verder kijken van een andere server: film of aflevering (de serie moet daar zichtbaar zijn voor dit profiel);
    /// nog niet gevonden → de tegel met de bewaarde titel, bij aantikken zoeken of de melding.
    private func foreignContinue(_ key: String, _ e: ProgressEntry, server: UUID) -> ContinueItem? {
        let full = server.uuidString + "|" + key
        let left = max(0, e.position / max(e.fraction, 0.01) - e.position)
        let isMovie: Bool
        var cover: URL?
        if let m = cross.movie(forKey: full), !cross.isMissing(full) { isMovie = true; cover = m.poster }
        else if let x = cross.episodeSeries(playlist: server, key: key) { isMovie = false; cover = x.poster }
        else if cross.isMissing(full), store.activeProfile?.effectiveAgeLimit == nil { isMovie = true }
        else { return nil }
        if filter == .movies && !isMovie { return nil }
        if filter == .series && isMovie && !cross.isMissing(full) { return nil }
        // build 141: cover van de film/serie (niet het beeld van de scène)
        return ContinueItem(id: key, title: e.title, subtitle: L("%d min left", Int(left / 60)), artwork: cover ?? e.artwork,
                            fraction: e.fraction, updated: e.updated, isMovie: isMovie,
                            position: e.position > 0 ? e.position : nil, source: server)
    }

    private func tapContinue(_ c: ContinueItem) {
        guard let s = c.source, cross.isMissing(s.uuidString + "|" + c.id) else { resumeChoice = choice(for: c); return }
        Task { @MainActor in
            switch await CrossServerOpen.open(key: s.uuidString + "|" + c.id, list: .continueWatching) {
            case .movie(let m):
                resumeChoice = ResumeChoice(id: m.id, title: c.title, fraction: c.fraction, position: c.position,
                                            detail: .movie(m), source: m.sourceID)
            case .series(let x):
                detail = .series(x)
            case .channel: break
            case .prompt(let p): prompt = p
            }
        }
    }

    private func removeFromContinue(_ c: ContinueItem) {
        withAnimation {
            store.clearProgress(c.id)
            if let id = c.traktPlaybackID { Task { await trakt.removePlayback(id) } }
        }
    }

    /// Tik op Verder kijken: kiezen tussen hervatten en opnieuw kijken.
    private func choice(for c: ContinueItem) -> ResumeChoice {
        if let s = c.source {
            let full = s.uuidString + "|" + c.id
            let d: DetailTarget? = c.isMovie ? cross.movie(forKey: full).map { .movie($0) }
                                             : cross.episodeSeries(playlist: s, key: c.id).map { .series($0) }
            return ResumeChoice(id: c.id, title: c.title, fraction: c.fraction, position: c.position, detail: d, source: s)
        }
        let d: DetailTarget? = c.isMovie ? lib.movies.first { $0.id == c.id }.map { .movie($0) }
                                         : lib.series.first { $0.title == c.title }.map { .series($0) }
        return ResumeChoice(id: c.id, title: c.title, fraction: c.fraction, position: c.position, detail: d)
    }

    /// Profielen met een leeftijdsgrens gaan via de detailpagina (die controleert de classificatie).
    private var ageLimited: Bool { store.activeProfile?.effectiveAgeLimit != nil }

    private func play(_ t: DetailTarget) {
        switch t {
        // build 111: TMDB-titel (niet in je bibliotheek, bijv. uit Mijn lijst) → detailpagina
        case .movie(let m) where !ageLimited && !DiscoverItem.isExternal(m.id): app.play(Playables.movie(m, imdb: trakt.imdb(for: m)))
        default: detail = t
        }
    }

    /// P0-fix: liep bij elke terugkeer naar het tabblad opnieuw, met meerdere lussen door de hele bibliotheek op de
    /// hoofdthread (Sets van alle id's, Top 10-aanvulling sorteren, groepen filteren). Nu: niet opnieuw voor dezelfde
    /// lijst/profiel binnen 15 minuten, en de opzoekingen via de (op de achtergrond gebouwde) HomeIndex.
    private func prepare() async {
        let pkey = prepareKey
        if preparedKey == pkey && Date().timeIntervalSince(preparedAt) < 15 * 60 { return }
        guard !lib.movies.isEmpty || !lib.series.isEmpty else { hero = nil; return }
        let l = lib, key = matcherKey
        let idx = await HomeIndexCache.shared.index(for: l, version: playlists.libraryVersion)
        guard !Task.isCancelled else { return }
        // 0. wat niet (meer) in de gefilterde lijst staat weghalen (ander profiel, leeftijdsgrens, verborgen groep)
        // build 140: titels van een andere server (Voor jou, Nieuw op Bingr) worden hieronder opnieuw bepaald
        if preparedKey != pkey { heroItems = []; newOnBingr = []; if !forYou.isEmpty { forYou = [] } }
        func known(_ t: DetailTarget) -> Bool {
            if let sid = t.sourceID, sid != pid { return true }
            return t.isSeries ? idx.seriesByID[t.id] != nil : idx.movieByID[t.id] != nil
        }
        if let h = hero, !known(h) { hero = nil }
        trendingMovies.removeAll { idx.movieByID[$0.id] == nil }
        trendingSeries.removeAll { idx.seriesByID[$0.id] == nil }
        forYou.removeAll { !known($0) }
        // 1. meteen iets laten zien: billboard en Top 10 uit de cache van vandaag (of je eigen lijst)
        if hero == nil { withAnimation(.easeInOut(duration: 0.4)) { hero = quickHero(l) } }
        let matcher = await MatcherCache.shared.matcher(for: l, key: key)   // op de achtergrond gebouwd
        guard !Task.isCancelled else { return }
        let kids = store.activeProfile?.kids ?? false
        applyTrending(matcher, idx, movies: TrendingStore.cached(shows: false, kids: kids), series: TrendingStore.cached(shows: true, kids: kids))
        // build 140: de andere servers (gefilterd voor dit profiel) voor Nieuw op Bingr en Voor jou
        let others = await AccountLibrary.shared.others(playlists)
        guard !Task.isCancelled else { return }
        let fresh = await NewOnBingr.shared.titles(active: l, activeID: pid, others: others)
        guard !Task.isCancelled else { return }
        if fresh != newOnBingr { newOnBingr = fresh }
        if forYou.isEmpty {
            let r = await buildForYou(useNetwork: false, matcher: matcher, idx: idx, lib: l, others: others)
            forYou = r.items
            forYouPopular = r.popular
        }
        guard !Task.isCancelled else { return }
        updateHeroItems(forYouRanked: forYou)

        // 2. daarna pas het netwerk (gedeeld door alle tabbladen, 6 uur bewaard)
        async let mv = TrendingStore.shared.get(shows: false, kids: kids)
        async let sv = TrendingStore.shared.get(shows: true, kids: kids)
        let (m, s) = await (mv, sv)
        guard !Task.isCancelled else { return }
        applyTrending(matcher, idx, movies: m, series: s)
        let fy = await buildForYou(useNetwork: true, matcher: matcher, idx: idx, lib: l, others: others)
        guard !Task.isCancelled else { return }
        forYou = fy.items
        forYouPopular = fy.popular
        updateHeroItems(forYouRanked: fy.items)
        preparedKey = pkey
        preparedAt = Date()
    }

    /// Billboard zonder te wachten: iets uit de Top 10-cache, anders de eerste titel met poster.
    /// Build 140: niet meer willekeurig; daarna neemt de vaste selectie (`updateHeroItems`) het over.
    private func quickHero(_ l: Library) -> DetailTarget? {
        if Screenshots.isActive, let t = ScreenshotDemo.hero(l, filter: filter) { return t }
        switch filter {
        case .series: return (trendingSeries.first ?? l.series.first { $0.poster != nil }).map { .series($0) }
        case .movies: return (trendingMovies.first ?? l.movies.first { $0.poster != nil }).map { .movie($0) }
        case .all:
            if let m = trendingMovies.first ?? l.movies.first(where: { $0.poster != nil }) { return .movie(m) }
            return l.series.first { $0.poster != nil }.map { .series($0) }
        }
    }

    /// Top 10: trending gekoppeld aan je lijst; te weinig treffers → aanvullen met je best beoordeelde/nieuwste titels
    /// (vooraf berekend in de HomeIndex; geen dubbele id's in de rij).
    private func applyTrending(_ matcher: TitleMatcher, _ idx: HomeIndex, movies: [ExternalTitle], series: [ExternalTitle]) {
        if filter != .series {
            let found = uniqueByID(matcher.movies(movies))
            if found.count >= 5 || trendingMovies.isEmpty {
                trendingMovies = found.count >= 5 ? found : found + idx.localTopMovies
                    .filter { m in !found.contains { $0.id == m.id } }
            }
        }
        if filter != .movies {
            let found = uniqueByID(matcher.series(series))
            if found.count >= 5 || trendingSeries.isEmpty {
                trendingSeries = found.count >= 5 ? found : found + idx.localTopSeries
                    .filter { s in !found.contains { $0.id == s.id } }
            }
        }
    }

    /// Build 140: "Voor jou" van HET actieve profiel: de titels die dit profiel het meest/laatst keek (Verder kijken,
    /// geschiedenis, bekeken), daarbij TMDB "recommendations" en "similar" (gekoppeld aan de bibliotheek van alle
    /// servers), en titels uit dezelfde categorieën met de meeste genre-overlap. Nooit al bekeken of begonnen titels;
    /// alleen wat in de (voor dit profiel gefilterde) bibliotheek staat. Het hoofdprofiel met Trakt krijgt ook zijn
    /// Trakt-aanbevelingen. Zonder kijkgeschiedenis: populaire titels onder de kop "Populair" (`popular`).
    private func buildForYou(useNetwork: Bool = true, matcher: TitleMatcher, idx: HomeIndex, lib: Library,
                             others: [(UUID, Library)] = []) async -> (items: [DetailTarget], popular: Bool) {
        // 1. wat dit profiel keek
        var watches: [ForYouSeeds.Watch] = []
        var seedTargets: [String: DetailTarget] = [:]
        func note(_ t: DetailTarget?, _ at: Date) {
            guard let t else { return }
            let k = (t.isSeries ? "s|" : "m|") + t.id
            seedTargets[k] = t
            watches.append(.init(key: k, at: at.timeIntervalSince1970))
        }
        for (k, e) in store.progress where e.playlistID == nil || e.playlistID == pid {
            if let m = idx.movieByID[k] { note(.movie(m), e.updated) }
            else if let se = idx.seriesByTitle[e.title] { note(.series(se), e.updated) }
        }
        for h in store.history where store.belongsToActive(h.profileID) && (h.playlistID == nil || h.playlistID == pid) {
            switch h.type {
            case .movie: note(idx.movieByID[h.itemID].map { .movie($0) }, h.date)
            case .series, .episode: note((idx.seriesByID[h.itemID] ?? idx.seriesByTitle[h.title]).map { .series($0) }, h.date)
            case .live: break
            }
        }
        for id in store.localWatched { if let m = idx.movieByID[id] { note(.movie(m), .distantPast) } }
        let seeds = ForYouSeeds.rank(watches, limit: 6).compactMap { seedTargets[$0] }
        guard !seeds.isEmpty else { return (popularTitles(idx), true) }

        var out: [DetailTarget] = []
        var seen = Set<String>()
        let seedIDs = Set(seeds.map(\.id))
        func add(_ t: DetailTarget) {
            guard !seen.contains(t.id), !seedIDs.contains(t.id), store.progress[t.id] == nil else { return }
            if filter == .movies, t.isSeries { return }
            if filter == .series, !t.isSeries { return }
            if case .movie(let m) = t, Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)) { return }
            if case .series(let x) = t, Playables.watchedEpisodeCount(x, imdb: trakt.imdb(for: x)) > 0 { return }
            seen.insert(t.id); out.append(t)
        }

        // 2. TMDB: aanbevelingen en vergelijkbare titels van wat dit profiel keek (eerst de open server, dan de andere)
        if useNetwork {
            let otherMatcher = await AccountLibrary.shared.othersMatcher(others)
            for seed in seeds.prefix(4) {
                let related = await relatedTitles(seed)
                if Task.isCancelled { return (out, false) }
                if seed.isSeries {
                    matcher.series(related, limit: 8).forEach { add(.series($0)) }
                    otherMatcher?.series(related, limit: 4).forEach { add(.series($0)) }
                } else {
                    matcher.movies(related, limit: 8).forEach { add(.movie($0)) }
                    otherMatcher?.movies(related, limit: 4).forEach { add(.movie($0)) }
                }
            }
        }

        // 3. dezelfde categorieën, op genre-overlap (TMDB-genres uit de cache) en daarna score (op de achtergrond)
        var seedGenres: [Int: Int] = [:], seedGroups: [String: Int] = [:]
        let ratings = AgeRatingService.shared.cache
        for t in seeds {
            switch t {
            case .movie(let m):
                seedGroups[m.group, default: 0] += 1
                for g in ratings[AgeRatingService.key(title: m.title, year: m.year, isShow: false)]?.genres ?? [] { seedGenres[g, default: 0] += 1 }
            case .series(let x):
                seedGroups[x.group, default: 0] += 1
                for g in ratings[AgeRatingService.key(title: x.title, year: x.year, isShow: true)]?.genres ?? [] { seedGenres[g, default: 0] += 1 }
            }
        }
        let groupMovies = filter == .series ? [] : seedGroups.keys.map { Array((idx.movieGroupItems[$0] ?? []).prefix(400)) }
        let groupSeries = filter == .movies ? [] : seedGroups.keys.map { Array((idx.seriesGroupItems[$0] ?? []).prefix(400)) }
        let sg = seedGenres, sgr = seedGroups
        let ranked = await Task.detached(priority: .utility) { () -> [DetailTarget] in
            var c: [(DetailTarget, Int, Double)] = []
            for list in groupMovies {
                for m in list {
                    let g = Set(ratings[AgeRatingService.key(title: m.title, year: m.year, isShow: false)]?.genres ?? [])
                    c.append((.movie(m), ForYouSeeds.score(genres: g, group: m.group, seedGenres: sg, seedGroups: sgr), m.rating ?? 0))
                }
            }
            for list in groupSeries {
                for x in list {
                    let g = Set(ratings[AgeRatingService.key(title: x.title, year: x.year, isShow: true)]?.genres ?? [])
                    c.append((.series(x), ForYouSeeds.score(genres: g, group: x.group, seedGenres: sg, seedGroups: sgr), x.rating ?? 0))
                }
            }
            c.sort { a, b in a.1 != b.1 ? a.1 > b.1 : (a.2 != b.2 ? a.2 > b.2 : a.0.id < b.0.id) }
            return c.prefix(120).map { $0.0 }
        }.value
        for t in ranked where out.count < 30 { add(t) }

        // 4. hoofdprofiel met Trakt: zijn persoonlijke Trakt-aanbevelingen
        if useNetwork && store.isMainActive && trakt.isLoggedIn && out.count < 30 {
            func ext(_ l: [TraktSync.TraktMedia]) -> [ExternalTitle] { l.compactMap { t in t.title.map { ExternalTitle(titles: [$0], year: t.year) } } }
            var rm: [TraktSync.TraktMedia] = [], rs: [TraktSync.TraktMedia] = []
            if filter != .series { rm = await trakt.recommendations(shows: false) }
            if filter != .movies { rs = await trakt.recommendations(shows: true) }
            matcher.movies(ext(rm), limit: 10).forEach { add(.movie($0)) }
            matcher.series(ext(rs), limit: 10).forEach { add(.series($0)) }
        }
        if out.isEmpty { return (popularTitles(idx), true) }
        return (Array(out.prefix(30)), false)
    }

    /// Build 140: zonder kijkgeschiedenis: best beoordeelde/nieuwste titels met poster (rij "Populair")
    private func popularTitles(_ idx: HomeIndex) -> [DetailTarget] {
        var out: [DetailTarget] = []
        let m = filter == .series ? [] : Array(idx.popularMovies.prefix(15))
        let x = filter == .movies ? [] : Array(idx.popularSeries.prefix(15))
        for i in 0..<max(m.count, x.count) {
            if i < m.count { out.append(.movie(m[i])) }
            if i < x.count { out.append(.series(x[i])) }
        }
        return out
    }

    /// Build 140: TMDB "recommendations" en "similar" van een titel, als titels om aan de bibliotheek te koppelen.
    private func relatedTitles(_ t: DetailTarget) async -> [ExternalTitle] {
        let raw: String, year: Int?, tmdb: Int?, imdb: String?
        switch t {
        case .movie(let m): raw = m.title; year = m.year; tmdb = m.tmdbID; imdb = trakt.imdb(for: m)
        case .series(let x): raw = x.title; year = x.year; tmdb = x.tmdbID; imdb = trakt.imdb(for: x)
        }
        let parsed = TitleCleaner.parse(raw)
        let show = t.isSeries
        guard let r = await TMDB.details(imdb: imdb, tmdbID: tmdb, title: parsed.title, year: year ?? parsed.year, isShow: show) else {
            return []
        }
        var out = r.recommendations.map { ExternalTitle(titles: [$0.title], year: $0.year) }
        struct Similar: Decodable {
            struct R: Decodable {
                let title: String?, name: String?, original_title: String?, original_name: String?
                let release_date: String?, first_air_date: String?
            }
            let results: [R]?
        }
        let sim: Similar? = await TMDB.get(show ? "/tv/\(r.id)/similar" : "/movie/\(r.id)/similar", ["language": TMDB.language])
        for x in (sim?.results ?? []).prefix(15) {
            let titles = [show ? x.name : x.title, show ? x.original_name : x.original_title].compactMap { $0 }
            guard !titles.isEmpty else { continue }
            out.append(ExternalTitle(titles: titles, year: (show ? x.first_air_date : x.release_date).flatMap { Int($0.prefix(4)) }))
        }
        return out
    }

}

@Observable final class ScrollTracker { var y: CGFloat = 0 }

/// Opnieuw uitrekenen als de lijst of de collecties veranderen.
private struct CollectionsKey: Equatable {
    let version: Int
    let source: UUID?
    let collections: [BingrCollection]
}

/// Trakt-voortgang opnieuw koppelen als de index of de Trakt-lijst verandert.
private struct TraktMatchKey: Equatable {
    let version: Int
    let playback: [TraktSync.PlaybackItem]
}

/// Build 111: TMDB-rijen opnieuw ophalen/koppelen bij een andere index, profiel, indeling of taal.
private struct DiscoverKey: Equatable {
    let version: Int
    let profile: UUID?
    let kinds: [DiscoverKind]
    let language: String
}

/// Elke id één keer (de eerste blijft). Dubbele id's (bijv. dezelfde stream twee keer in een M3U-lijst) in een
/// ForEach in een Lazy-stack geven in SwiftUI ongedefinieerd gedrag: haperen of vastlopen, vooral met de focus op Apple TV.
func uniqueByID<T: Identifiable>(_ xs: [T]) -> [T] {
    var seen = Set<T.ID>()
    seen.reserveCapacity(xs.count)
    return xs.filter { seen.insert($0.id).inserted }
}

/// Eén HomeIndex per lijstversie, op de achtergrond gebouwd en gedeeld door Home, Films en Series
/// (voorheen bouwde elk tabblad hem bij elke terugkeer opnieuw).
@MainActor
final class HomeIndexCache {
    static let shared = HomeIndexCache()
    private var version = -1
    private var current: HomeIndex?
    private var building: Task<HomeIndex, Never>?

    func index(for lib: Library, version v: Int) async -> HomeIndex {
        if v == version, let current { return current }
        if v == version, let building { return await building.value }
        version = v
        current = nil
        let t = Task.detached(priority: .userInitiated) { HomeIndex.build(lib) }
        building = t
        let x = await t.value
        if version == v { current = x; building = nil }
        return x
    }
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
    /// Voor "Voor jou" en de Top 10-aanvulling (voorheen per keer op de hoofdthread door de hele lijst)
    var seriesByTitle: [String: Series] = [:]
    var movieGroupItems: [String: [Movie]] = [:]
    var seriesGroupItems: [String: [Series]] = [:]
    var localTopMovies: [Movie] = []
    var localTopSeries: [Series] = []
    /// Build 111: rij "Nieuw toegevoegd" op Home: films én series van de laatste 30 dagen (Xtream `added` /
    /// `last_modified`), nieuwste eerst, max. 30; zonder datum (M3U) blijft hij leeg
    var recentTitles: [DetailTarget] = []
    /// Build 111: TMDB-id van de bron → titel (rijen Binnenkort / Nieuw op streamingdiensten)
    var movieByTMDB: [Int: Movie] = [:]
    var seriesByTMDB: [Int: Series] = [:]

    static func build(_ lib: Library) -> HomeIndex {
        var x = HomeIndex()
        // zelfde id meer dan eens (dezelfde stream twee keer in de lijst): één keer per rij, anders loopt SwiftUI vast
        let movies = uniqueByID(lib.movies), series = uniqueByID(lib.series)
        var mOrder: [String] = [], mGroups: [String: [Movie]] = [:]
        for m in lib.movies {
            if mGroups[m.group] == nil { mOrder.append(m.group) }
            mGroups[m.group, default: []].append(m)
            x.movieByID[m.id] = m
            if let i = m.imdbID, !i.isEmpty { x.movieByIMDb[i] = m }
        }
        for g in mOrder { mGroups[g] = uniqueByID(mGroups[g] ?? []) }
        x.movieGroups = mOrder.map { Group(id: $0, items: mGroups[$0] ?? []) }
        x.movieGroupItems = mGroups
        var sOrder: [String] = [], sGroups: [String: [Series]] = [:]
        for s in lib.series {
            if sGroups[s.group] == nil { sOrder.append(s.group) }
            sGroups[s.group, default: []].append(s)
            x.seriesByID[s.id] = s
            x.seriesTitles.insert(s.title)
            if x.seriesByTitle[s.title] == nil { x.seriesByTitle[s.title] = s }
        }
        for g in sOrder { sGroups[g] = uniqueByID(sGroups[g] ?? []) }
        x.seriesGroups = sOrder.map { Group(id: $0, items: sGroups[$0] ?? []) }
        x.seriesGroupItems = sGroups
        for c in lib.channels { x.channelByID[c.id] = c }
        x.recent = movies.filter { $0.addedAt != nil }.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        x.popularMovies = Array(movies.filter { $0.poster != nil }
            .sorted { ($0.rating ?? 0, $0.addedAt ?? .distantPast) > ($1.rating ?? 0, $1.addedAt ?? .distantPast) }.prefix(60))
        x.popularSeries = Array(series.filter { $0.poster != nil }.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(60))
        x.localTopMovies = localTop(movies, rating: \.rating, added: \.addedAt, poster: \.poster)
        x.localTopSeries = localTop(series, rating: \.rating, added: nil, poster: \.poster)
        // build 111
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var fresh: [(t: DetailTarget, at: Date)] = []
        for m in movies { if let a = m.addedAt, a >= cutoff { fresh.append((.movie(m), a)) } }
        for s in series { if let a = s.addedAt, a >= cutoff { fresh.append((.series(s), a)) } }
        x.recentTitles = Array(fresh.sorted { $0.at > $1.at }.prefix(30).map(\.t))
        for m in movies { if let t = m.tmdbID, x.movieByTMDB[t] == nil { x.movieByTMDB[t] = m } }
        for s in series { if let t = s.tmdbID, x.seriesByTMDB[t] == nil { x.seriesByTMDB[t] = s } }
        return x
    }

    /// Eigen Top 10 als er (nog) geen trending-gegevens zijn: hoogste score, dan nieuwste, met poster.
    static func localTop<T>(_ items: [T], rating: KeyPath<T, Double?>, added: KeyPath<T, Date?>?, poster: KeyPath<T, URL?>) -> [T] {
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

    /// `n` willekeurige elementen (zonder herhaling) die aan `ok` voldoen, zonder de hele lijst te filteren en te
    /// schudden; alleen als de steekproef te weinig oplevert, de hele lijst.
    static func sample<T>(_ xs: [T], _ n: Int, where ok: (T) -> Bool = { _ in true }) -> [T] {
        guard n > 0, !xs.isEmpty else { return [] }
        if xs.count > n * 4 {
            var out: [T] = [], picked = Set<Int>()
            var tries = 0
            while out.count < n && tries < n * 20 {
                tries += 1
                let i = Int.random(in: 0..<xs.count)
                if picked.insert(i).inserted && ok(xs[i]) { out.append(xs[i]) }
            }
            if out.count == n { return out }
        }
        return Array(xs.filter(ok).shuffled().prefix(n))
    }

    /// Willekeurig item met poster (steekproef; alleen bij weinig posters de hele lijst).
    static func randomWithPoster(_ xs: [Movie]) -> Movie? { sample(xs, 1, where: { $0.poster != nil }).first }
    static func randomWithPoster(_ xs: [Series]) -> Series? { sample(xs, 1, where: { $0.poster != nil }).first }

    private func itemID(_ key: String, _ playlist: UUID) -> Substring? {
        // server-id hoofdletterongevoelig: web/Android/Samsung TV schrijven hem soms met kleine letters
        let p = playlist.uuidString
        guard key.count > p.count + 1, key.prefix(p.count).caseInsensitiveCompare(p) == .orderedSame,
              key[key.index(key.startIndex, offsetBy: p.count)] == "|" else { return nil }
        return key.dropFirst(p.count + 1)
    }
    func movie(forKey k: String, playlist: UUID) -> Movie? { itemID(k, playlist).flatMap { movieByID[String($0)] } }
    func series(forKey k: String, playlist: UUID) -> Series? { itemID(k, playlist).flatMap { seriesByID[String($0)] } }
    func channel(forKey k: String, playlist: UUID) -> Channel? { itemID(k, playlist).flatMap { channelByID[String($0)] } }
    func movie(imdb: String) -> Movie? { movieByIMDb[imdb] }
}
