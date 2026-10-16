import SwiftUI

/// Een categorie die volledig getoond wordt ("Bekijk allemaal").
struct CategoryTarget: Identifiable {
    let id = UUID()
    let title: String
    let items: [DetailTarget]
}

/// Categoriepagina zoals in UHF: terugknop, titel in hoofdletters, sorteerknop
/// en een raster van posters met score en titel eronder.
struct CategoryView: View {
    let target: CategoryTarget

    enum Sort: String, CaseIterable, Identifiable {
        case standard, az, za, newest, rating
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: return L("Default")
            case .az: return L("Title (A–Z)")
            case .za: return L("Title (Z–A)")
            case .newest: return L("Recently added")
            case .rating: return L("Highest rated")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var meta: MetadataService
    @EnvironmentObject var trakt: TraktSync
    /// vinkjes en "N BEKEKEN" ook bijwerken na afvinken in Bingr (build 75)
    @EnvironmentObject var store: CloudStore
    @AppStorage("category.sort") private var sortRaw = Sort.standard.rawValue
    @State private var detail: DetailTarget?
    /// P0-fix: gesorteerde titels één keer per sortering, op de achtergrond. Voorheen sorteerde `body` bij elke
    /// verversing (bijv. elke binnenkomende IMDb-score) duizenden titels op de hoofdthread.
    @State private var sorted: [DetailTarget] = []
    @State private var sortedFor: Sort?

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .standard }

    #if os(tvOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 6)
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
                Picker(L("Sort"), selection: $sortRaw) {
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
                        if n > 0 {
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
        if s == .rating { for t in items where ratings[t.id] == nil { ratings[t.id] = rating(t) ?? -1 } }
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
        return false
    }
}

/// Sorteren van een categorie buiten de hoofdthread; elke titel één keer (dubbele id's laten het raster vastlopen).
private enum CategorySorter {
    static func sort(_ items: [DetailTarget], _ s: CategoryView.Sort, ratings: [String: Double]) -> [DetailTarget] {
        let unique = uniqueByID(items)
        switch s {
        case .standard: return unique
        case .az, .za:
            // titel zonder taallabel één keer per titel, niet per vergelijking
            let keyed = unique.map { (t: $0, title: title($0)) }
            let asc = s == .az
            return keyed.sorted {
                let r = $0.title.localizedStandardCompare($1.title)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }.map { $0.t }
        case .newest: return unique.sorted { (added($0) ?? .distantPast) > (added($1) ?? .distantPast) }
        case .rating: return unique.sorted { (ratings[$0.id] ?? -1) > (ratings[$1.id] ?? -1) }
        }
    }

    private static func title(_ t: DetailTarget) -> String {
        switch t {
        case .movie(let m): return ContentLanguage.displayTitle(m.title)
        case .series(let s): return ContentLanguage.displayTitle(s.title)
        }
    }

    private static func added(_ t: DetailTarget) -> Date? {
        if case .movie(let m) = t { return m.addedAt }
        return nil
    }
}
