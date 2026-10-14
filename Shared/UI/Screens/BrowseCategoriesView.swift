import SwiftUI

/// "Categorieën" (build 85), in Netflix-stijl: tegels per genre (TMDB/IMDb-genres en de naam van de categorie op je
/// server) en de categorieën van je server zelf ("Van je server"). Volgt verborgen categorieën, het kinderslot en
/// de leeftijdsgrens van het profiel, want alles komt uit de al gefilterde bibliotheek.
struct BrowseCategoriesView: View {
    var initialScope: BrowseScope = .all
    /// Als blad geopend (tegel "Alle categorieën" op Home): met sluitknop
    var modal = false
    /// Build 86: geopend vanuit Mijn Bingr (in de navigatie): titel in de navigatiebalk
    var pushed = false

    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var meta: MetadataService
    @ObservedObject private var ages = AgeRatingService.shared
    @ObservedObject private var store = BrowseIndexStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope: BrowseScope?
    @State private var open: BrowseCategory?

    private var current: BrowseScope { scope ?? initialScope }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tvScaled(22)) {
                header
                let idx = store.index
                let genres = idx.genres.filter { $0.count(current) > 0 }
                let server = idx.server.filter { $0.count(current) > 0 }
                if genres.isEmpty && server.isEmpty {
                    emptyState
                } else {
                    if !genres.isEmpty { section(L("Genres"), genres) }
                    if !server.isEmpty { section(L("From your server"), server) }
                }
            }
            .padding(.bottom, 40)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: store.key(playlists) + "\(meta.cache.count / 50)-\(ages.cache.count / 50)") {
            store.refresh(playlists)
        }
        .fullScreenCover(item: $open) { BrowseCategoryView(category: $0, initialScope: current) }
        .navigationTitle(pushed ? L("Categories") : "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            if !pushed {
                HStack(spacing: 12) {
                    Text(L("Categories")).font(.system(size: tvScaled(28), weight: .heavy)).foregroundStyle(.white)
                    Spacer()
                    #if !os(tvOS)
                    if modal {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Close"))
                    }
                    #endif
                }
            }
            Picker("", selection: Binding(get: { current }, set: { scope = $0 })) {
                ForEach(BrowseScope.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: tvScaled(420))
        }
        .padding(.horizontal, Theme.edge)
        .padding(.top, tvScaled(modal ? 16 : 8))
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isBuilding || playlists.isLoading || playlists.isFiltering {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "square.grid.2x2").font(.system(size: tvScaled(40))).foregroundStyle(Theme.secondary)
                Text(L("No titles found in this playlist.")).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 4)
        #else
        [GridItem(.adaptive(minimum: 160, maximum: 300), spacing: 12, alignment: .top)]
        #endif
    }

    private func section(_ title: String, _ list: [BrowseCategory]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            Text(title).font(Theme.titleFont).foregroundStyle(.white).padding(.horizontal, Theme.edge)
            LazyVGrid(columns: columns, spacing: tvScaled(12)) {
                ForEach(list) { c in
                    Button { open = c } label: {
                        BrowseCategoryTile(title: c.title, count: c.count(current), covers: c.covers(current), colors: c.colors)
                    }
                    .cardButton()
                    .tileHover()
                    .accessibilityLabel("\(c.title), \(L("%d titles", c.count(current)))")
                }
            }
            .padding(.horizontal, Theme.edge)
            #if os(tvOS)
            .padding(.vertical, 20)
            #endif
        }
    }
}

/// Tegel: naam en aantal op een kleurverloop, met een waaier van 3–4 posters rechts.
struct BrowseCategoryTile: View {
    let title: String
    let count: Int
    let covers: [URL]
    let colors: (UInt32, UInt32)
    @Environment(\.tvFocused) private var focused

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let pw = h * 0.78 / 1.5
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // waaier van posters, de populairste vooraan
                ZStack {
                    ForEach(Array(covers.prefix(4).enumerated().reversed()), id: \.offset) { i, u in
                        RemoteImage(url: u, placeholder: "", maxPixel: 360)
                            .frame(width: pw, height: pw * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: tvScaled(4)))
                            .shadow(color: .black.opacity(0.5), radius: 6, x: -2, y: 3)
                            .rotationEffect(.degrees(Double(i) * 7 - 4), anchor: .bottom)
                            .offset(x: -CGFloat(i) * pw * 0.42, y: CGFloat(i) * h * 0.03)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: pw * 0.18, y: h * 0.12)
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: tvScaled(16), weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    Text(L("%d titles", count))
                        .font(.system(size: tvScaled(11), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: g.size.width * 0.6, alignment: .leading)
                .padding(tvScaled(10))
            }
            .frame(width: g.size.width, height: h)
        }
        .aspectRatio(16.0 / 9.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(8)).stroke(.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: tvScaled(8)))
    }
}

/// Build 86: laatste tegel van de rij Categorieën op Home, opent het overzicht.
struct BrowseAllTile: View {
    @Environment(\.tvFocused) private var focused

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3F3F46), Color(hex: 0x111114)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: tvScaled(6)) {
                Image(systemName: "square.grid.2x2").font(.system(size: tvScaled(24), weight: .semibold))
                Text(L("All categories"))
                    .font(.system(size: tvScaled(15), weight: .heavy))
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(tvScaled(10))
        }
        .aspectRatio(16.0 / 9.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(8)).stroke(.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: tvScaled(8)))
    }
}

extension BrowseIndex {
    /// Build 86: tegels voor de rij op Home: de genres met de meeste titels, aangevuld met de grootste categorieën
    /// van je server.
    func homeTiles(_ n: Int = 10) -> [BrowseCategory] {
        var out = Array(genres.prefix(n))
        if out.count < n {
            out += server.sorted { $0.entries.count > $1.entries.count }.prefix(n - out.count)
        }
        return out
    }
}

// MARK: - Categoriepagina

/// Eén categorie: naam en aantal, Alles/Films/Series, sorteren (Populair, Nieuwste, A–Z, Beoordeling) en een raster
/// van posters dat in porties bijlaadt.
struct BrowseCategoryView: View {
    let category: BrowseCategory
    var initialScope: BrowseScope = .all

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @EnvironmentObject var meta: MetadataService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("browse.sort") private var sortRaw = BrowseSort.popular.rawValue
    @State private var scope: BrowseScope?
    @State private var list: [BrowseEntry] = []
    @State private var sorting = true
    @State private var limit = BrowseCategoryView.page
    @State private var detail: DetailTarget?
    @State private var collecting: CollectionTarget?

    private static let page = 60
    private var sort: BrowseSort { BrowseSort(rawValue: sortRaw) ?? .popular }
    /// Gekozen soort; zonder films of zonder series altijd Alles
    private var current: BrowseScope {
        let s = scope ?? initialScope
        return category.count(s) > 0 ? s : .all
    }
    private var pid: UUID? { playlists.source?.id }
    private var bothKinds: Bool { category.movieCount > 0 && category.seriesCount > 0 }

    #if os(tvOS)
    private let gap: CGFloat = 40
    private let minWidth: CGFloat = 230
    #else
    private let gap: CGFloat = 10
    private let minWidth: CGFloat = 105
    #endif

    var body: some View {
        GeometryReader { g in
            let avail = max(200, g.size.width - Theme.edge * 2)
            let cols = max(3, Int((avail + gap) / (minWidth + gap)))
            let w = floor((avail - gap * CGFloat(cols - 1)) / CGFloat(cols))
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(16)) {
                    header
                    if sorting && list.isEmpty {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: gap, alignment: .top), count: cols),
                                  alignment: .leading, spacing: tvScaled(12)) {
                            ForEach(list.prefix(limit)) { e in
                                cell(e, width: w)
                                    .onAppear { if e.id == list.prefix(limit).last?.id { loadMore() } }
                            }
                        }
                        .padding(.horizontal, Theme.edge)
                        #if os(tvOS)
                        .padding(.vertical, 30)
                        #endif
                        if limit < list.count {
                            ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
                                .onAppear { loadMore() }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: "\(category.id)-\(category.entries.count)-\(current.rawValue)-\(sort.rawValue)") { await resort() }
        .sheet(item: $collecting) { AddToCollectionSheet(target: $0) }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            HStack(alignment: .center, spacing: tvScaled(10)) {
                #if !os(tvOS)
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Back"))
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: tvScaled(26), weight: .heavy)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(L("%d titles", category.count(current)))
                        .font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: tvScaled(12)) {
                if bothKinds {
                    Picker("", selection: Binding(get: { current }, set: { scope = $0 })) {
                        ForEach(BrowseScope.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: tvScaled(360))
                }
                Spacer(minLength: 0)
                Menu {
                    Picker(L("Sort"), selection: $sortRaw) {
                        ForEach(BrowseSort.allCases) { s in Text(s.title).tag(s.rawValue) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sort.title)
                    }
                    .font(.system(size: tvScaled(14), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(7))
                    .background(Theme.elevated, in: Capsule())
                }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                #endif
                .accessibilityLabel(L("Sort"))
            }
        }
        .padding(.horizontal, Theme.edge - tvScaled(4))
        .padding(.top, tvScaled(10))
    }

    @ViewBuilder private func cell(_ e: BrowseEntry, width: CGFloat) -> some View {
        Button { detail = e.target } label: {
            switch e.target {
            case .movie(let m):
                let imdb = trakt.imdb(for: m)
                let recent = (m.addedAt ?? .distantPast) > Date().addingTimeInterval(-14 * 86400)
                PosterCard(title: m.title, poster: m.poster ?? meta.cached(m)?.poster, imdbID: imdb,
                           watched: Playables.isWatched(movie: m, imdb: imdb),
                           progress: store.progress[m.id]?.fraction,
                           badge: recent ? L("Recently added") : nil,
                           width: width, language: ContentLanguage.of(m))
            case .series(let s):
                let imdb = trakt.imdb(for: s)
                PosterCard(title: s.title, poster: s.poster ?? meta.cached(s)?.poster, imdbID: imdb,
                           watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: imdb),
                           width: width, language: ContentLanguage.of(s))
            }
        }
        .cardButton()
        .contextMenu { menu(e.target) }
    }

    @ViewBuilder private func menu(_ t: DetailTarget) -> some View {
        switch t {
        case .movie(let m):
            let imdb = trakt.imdb(for: m)
            Button { play(m) } label: { Label(L("Play"), systemImage: "play.fill") }
            let watched = Playables.isWatched(movie: m, imdb: imdb)
            Button {
                store.setLocalWatched(m.id, !watched)
                Task { await trakt.setWatched(Playables.movie(m, imdb: imdb), !watched) }
            } label: { Label(watched ? L("Mark as unwatched") : L("Mark as watched"), systemImage: watched ? "eye.slash" : "checkmark.circle") }
        case .series:
            Button { detail = t } label: { Label(L("More info"), systemImage: "info.circle") }
        }
        if let pid {
            Button { store.toggleMyList(pid, t.id) } label: {
                Label(store.inMyList(pid, t.id) ? L("Remove from My List") : L("Add to My List"), systemImage: "plus")
            }
        }
        Button { collecting = .detail(t) } label: {
            Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
        }
    }

    /// Profielen met een leeftijdsgrens gaan via de detailpagina (die controleert de classificatie), zoals op Home.
    private func play(_ m: Movie) {
        if store.activeProfile?.effectiveAgeLimit != nil { detail = .movie(m); return }
        app.play(Playables.movie(m, imdb: trakt.imdb(for: m)))
    }

    private func loadMore() {
        guard limit < list.count else { return }
        limit = min(list.count, limit + Self.page)
    }

    /// Sorteren buiten de hoofdthread (categorieën kunnen duizenden titels hebben).
    private func resort() async {
        sorting = true
        let entries = category.entries, s = sort, sc = current
        let out = await Task.detached(priority: .userInitiated) { s.sorted(entries.filter { sc.includes($0) }) }.value
        guard !Task.isCancelled else { return }
        list = out
        limit = Self.page
        sorting = false
    }
}

extension View {
    /// Muis/trackpad (iPad en Mac): tegel licht op en komt iets naar voren.
    @ViewBuilder func tileHover() -> some View {
        #if os(iOS)
        self.hoverEffect(.lift)
        #elseif os(macOS)
        self.modifier(MacHoverLift())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacHoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.03 : 1)
            .brightness(hover ? 0.06 : 0)
            .shadow(color: .black.opacity(hover ? 0.5 : 0), radius: 10, y: 6)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 }
    }
}
#endif
