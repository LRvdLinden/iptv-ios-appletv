import SwiftUI

/// Een categorie die volledig getoond wordt ("Bekijk allemaal").
struct CategoryTarget: Identifiable {
    let id = UUID()
    let title: String
    let items: [DetailTarget]
    /// Build 179: sleutel in `profile.<id>.categorySort` (`Build179.sortKey`) voor een categorie van de server;
    /// nil = een eigen lijst (Mijn lijst, Recent toegevoegd …): dan de sortering van dit apparaat (`category.sort`)
    var sortKey: String? = nil

    init(title: String, items: [DetailTarget], sortKey: String? = nil) {
        self.title = title; self.items = items; self.sortKey = sortKey
    }

    /// Build 179: sleutel voor een categorie van films of series (server-id van de titels, of "*" bij meerdere servers)
    @MainActor static func key(_ category: String, kind: String, items: [DetailTarget]) -> String {
        let ids = Set(items.prefix(200).map { $0.sourceID ?? CloudStore.shared.activePlaylistID })
        let only: UUID? = ids.count == 1 ? ids.first.flatMap { $0 } : nil
        let server = only?.uuidString ?? "*"
        return Build179.sortKey(server: server, kind: kind, category: category)
    }
}

/// Categoriepagina zoals in UHF: terugknop, titel in hoofdletters, sorteerknop
/// en een raster van posters met score en titel eronder.
struct CategoryView: View {
    let target: CategoryTarget

    /// Build 179: de vijf sorteringen van het contract (`Build179.SortMode`)
    typealias Sort = Build179.SortMode

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var meta: MetadataService
    @EnvironmentObject var trakt: TraktSync
    /// vinkjes en "N BEKEKEN" ook bijwerken na afvinken in Bingr (build 75)
    @EnvironmentObject var store: CloudStore
    @AppStorage("category.sort") private var localSortRaw = Sort.server.rawValue
    /// Build 179: sortering per categorie per profiel (gesynct)
    @ObservedObject private var sorts = CategorySort179.shared
    @State private var detail: DetailTarget?
    /// P0-fix: gesorteerde titels één keer per sortering, op de achtergrond. Voorheen sorteerde `body` bij elke
    /// verversing (bijv. elke binnenkomende IMDb-score) duizenden titels op de hoofdthread.
    @State private var sorted: [DetailTarget] = []
    @State private var sortedFor: Sort?

    private var sortRaw: String {
        if let k = target.sortKey { return sorts.mode(k).rawValue }
        // oude waarden (t/m build 178) omzetten
        switch localSortRaw {
        case "standard", "za": return Sort.server.rawValue
        case "az": return Sort.name.rawValue
        case "newest": return Sort.added.rawValue
        default: return Sort.from(localSortRaw).rawValue
        }
    }
    private var sortBinding: Binding<String> {
        Binding(get: { sortRaw }, set: { v in
            if let k = target.sortKey { sorts.set(k, Sort.from(v)) } else { localSortRaw = v }
        })
    }
    private var sort: Sort { Sort.from(sortRaw) }

    #if os(tvOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 6)
    #elseif os(iOS)
    /// Build 179 (iPhone Duo): op reguliere breedte (binnenscherm, iPad) een even aantal kolommen, zodat de vouw
    /// tussen twee kolommen valt; compact zoveel als past (zoals voorheen met `.adaptive(minimum: 150)`)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var gridWidth: CGFloat = 0
    private var columns: [GridItem] {
        guard gridWidth > 0 else { return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14, alignment: .top)] }
        let n = Duo179.columns(width: Double(gridWidth - 2 * Theme.edge), minItem: 150, spacing: 14,
                               regular: hSize == .regular)
        return Array(repeating: GridItem(.flexible(maximum: 240), spacing: 14, alignment: .top), count: n)
    }
    #else
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14, alignment: .top)]
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: tvScaled(18)) {
                    ForEach(sorted) { t in
                        Button { detail = t } label: { cell(t) }
                            .cardButton()
                    }
                }
                .padding(.horizontal, Theme.edge)
                #if os(iOS)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                #endif
                .padding(.vertical, tvScaled(12))
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: sortRaw) { await resort() }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    private var header: some View {
        HStack(spacing: tvScaled(12)) {
            #if !os(tvOS)
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(L("Back"))
            #endif
            Text(target.title.uppercased())
                .font(Theme.titleFont)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Picker(L("Sort"), selection: sortBinding) {
                    ForEach(Sort.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: tvScaled(18), weight: .semibold))
                    .frame(width: tvScaled(40), height: tvScaled(40))
            }
            .accessibilityLabel(L("Sort"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.edge - tvScaled(6))
        .padding(.top, tvScaled(6))
    }

    @ViewBuilder private func cell(_ t: DetailTarget) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(6)) {
            GeometryReader { g in
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: poster(t), placeholder: title(t))
                        .frame(width: g.size.width, height: g.size.width * 1.5)
                        .clipped()
                    if watched(t) { WatchedBadge().padding(6).frame(maxWidth: .infinity, alignment: .topLeading) }
                    // serie: "N BEKEKEN" linksboven (build 75); de score staat rechtsboven
                    if case .series(let s) = t {
                        let n = Playables.watchedEpisodeCount(s, imdb: trakt.imdb(for: s))
                        if n > 0 && !watched(t) {
                            WatchedEpisodesLabel(count: n).padding(tvScaled(6))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    // taal onderaan de poster (build 59)
                    if let l = language(t) {
                        LanguageStrip(language: l).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    if let r = rating(t) {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: tvScaled(9)))
                            Text(String(format: "%.1f", r)).font(.system(size: tvScaled(11), weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.imdb, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: tvScaled(6)))
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            Text(title(t))
                .font(.system(size: tvScaled(13), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: gegevens

    private func resort() async {
        let s = sort
        guard s != sortedFor else { return }
        let items = target.items
        // scores komen uit de metadata (hoofdthread); alleen opzoeken, het sorteren gebeurt op de achtergrond
        var ratings: [String: Double] = [:]
        if s == .rating { for t in items where ratings[t.id] == nil { ratings[t.id] = rating(t) ?? 0 } }
        let out = await Task.detached(priority: .userInitiated) { CategorySorter.sort(items, s, ratings: ratings) }.value
        guard !Task.isCancelled else { return }
        sorted = out
        sortedFor = s
    }

    /// Titel zonder taallabel ("Animal (IT)" → "Animal"); de taal staat op de poster (build 59)
    private func title(_ t: DetailTarget) -> String {
        switch t {
        case .movie(let m): return ContentLanguage.displayTitle(m.title)
        case .series(let s): return ContentLanguage.displayTitle(s.title)
        }
    }
    private func language(_ t: DetailTarget) -> ContentLanguage? {
        switch t { case .movie(let m): return ContentLanguage.of(m); case .series(let s): return ContentLanguage.of(s) }
    }
    private func poster(_ t: DetailTarget) -> URL? {
        switch t {
        case .movie(let m): return m.poster ?? meta.cached(m)?.poster
        case .series(let s): return s.poster ?? meta.cached(s)?.poster
        }
    }
    private func rating(_ t: DetailTarget) -> Double? {
        let imdb: String?
        switch t {
        case .movie(let m): imdb = meta.cached(m)?.imdbRating; if imdb == nil, let r = m.rating, r > 0 { return r }
        case .series(let s): imdb = meta.cached(s)?.imdbRating; if imdb == nil, let r = s.rating, r > 0 { return r }
        }
        return imdb.flatMap(Double.init)
    }
    private func watched(_ t: DetailTarget) -> Bool {
        if case .movie(let m) = t { return Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)) }
        // build 154: een serie is gezien als alle uitgezonden afleveringen gezien zijn (`w:s:`)
        if case .series(let s) = t { return Playables.isSeriesWatched(s, imdb: trakt.imdb(for: s)) }
        return false
    }
}

/// Sorteren van een categorie buiten de hoofdthread; elke titel één keer (dubbele id's laten het raster vastlopen).
/// Build 179: volgens `Build179.sortOrder` (zelfde regels als Android en web).
private enum CategorySorter {
    static func sort(_ items: [DetailTarget], _ s: CategoryView.Sort, ratings: [String: Double]) -> [DetailTarget] {
        let unique = uniqueByID(items)
        guard s != .server else { return unique }
        let keys = unique.map { t -> Build179.SortItem in
            switch t {
            case .movie(let m):
                return .init(name: ContentLanguage.displayTitle(m.title), year: m.year,
                             added: m.addedAt?.timeIntervalSince1970, rating: ratings[t.id])
            case .series(let x):
                return .init(name: ContentLanguage.displayTitle(x.title), year: x.year,
                             added: x.addedAt?.timeIntervalSince1970, rating: ratings[t.id])
            }
        }
        return Build179.sortOrder(keys, mode: s).map { unique[$0] }
    }
}
