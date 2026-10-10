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
    @AppStorage("category.sort") private var sortRaw = Sort.standard.rawValue
    @State private var detail: DetailTarget?

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
        #if os(iOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    private var header: some View {
        HStack(spacing: tvScaled(12)) {
            #if os(iOS)
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

    private var sorted: [DetailTarget] {
        let items = target.items
        switch sort {
        case .standard: return items
        case .az: return items.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        case .za: return items.sorted { title($0).localizedStandardCompare(title($1)) == .orderedDescending }
        case .newest: return items.sorted { (added($0) ?? .distantPast) > (added($1) ?? .distantPast) }
        case .rating: return items.sorted { (rating($0) ?? -1) > (rating($1) ?? -1) }
        }
    }

    private func title(_ t: DetailTarget) -> String {
        switch t { case .movie(let m): return m.title; case .series(let s): return s.title }
    }
    private func poster(_ t: DetailTarget) -> URL? {
        switch t {
        case .movie(let m): return m.poster ?? meta.cached(m)?.poster
        case .series(let s): return s.poster ?? meta.cached(s)?.poster
        }
    }
    private func added(_ t: DetailTarget) -> Date? {
        switch t {
        case .movie(let m): return m.addedAt
        case .series: return nil
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
