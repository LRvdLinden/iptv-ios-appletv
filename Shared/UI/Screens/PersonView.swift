import SwiftUI

/// Eigen pagina voor een acteur of actrice (zoals Netflix): grote ronde foto, naam, bekend van,
/// geboortedatum/-plaats en biografie, daarna wat er van hem/haar in je afspeellijst staat
/// (direct te kijken) en de rest van het werk (alleen info).
struct PersonView: View {
    let person: PersonRef

    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @Environment(\.dismiss) private var dismiss

    @State private var info: PersonInfo?
    @State private var available: [DetailTarget] = []
    @State private var more: [PersonCredit] = []
    @State private var loading = true
    @State private var bioExpanded = false
    @State private var detail: DetailTarget?
    @State private var credit: PersonCredit?

    private var name: String { info?.name.isEmpty == false ? info!.name : person.name }
    private var photo: URL? { info?.photo ?? person.photo }
    private var kids: Bool { store.activeProfile?.kids ?? false }
    private var ageLimited: Bool { store.activeProfile?.effectiveAgeLimit != nil }
    private var photoSize: CGFloat {
        #if os(tvOS)
        return 360
        #else
        return 168
        #endif
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(26)) {
                    header.padding(.horizontal, Theme.edge)
                    if loading {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 20)
                    } else if info == nil && available.isEmpty && more.isEmpty {
                        Text(L("No information found for this person."))
                            .font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    if !available.isEmpty { availableRow }
                    // titels buiten je lijst (zonder leeftijdscontrole) niet tonen bij een leeftijdsgrens
                    if !ageLimited, !more.isEmpty { moreRow }
                    Color.clear.frame(height: 40)
                }
                .padding(.top, tvScaled(40))
            }
            #if !os(tvOS)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel(L("Close"))
            #endif
        }
        .task(id: "\(person.id)-\(Localizer.shared.language)-\(playlists.libraryVersion)") { await load() }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
        .sheet(item: $credit) { CreditInfoSheet(credit: $0) }
    }

    // MARK: kop

    @ViewBuilder private var header: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 60) {
            portrait
            VStack(alignment: .leading, spacing: 18) { nameAndFacts; biography }
        }
        #else
        VStack(alignment: .center, spacing: 18) {
            portrait
            VStack(alignment: .center, spacing: 14) { nameAndFacts }
            VStack(alignment: .leading, spacing: 14) { biography }.frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    private var portrait: some View {
        ZStack {
            Circle().fill(Theme.elevated)
            if let p = photo { RemoteImage(url: p, maxPixel: 900).clipShape(Circle()) }
            else {
                Text(initials(name)).font(.system(size: photoSize / 3, weight: .bold)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: photoSize, height: photoSize)
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    @ViewBuilder private var nameAndFacts: some View {
        Text(name).font(.system(size: tvScaled(30), weight: .heavy)).foregroundStyle(.white)
            #if !os(tvOS)
            .multilineTextAlignment(.center)
            #endif
        let facts = factLines
        if !facts.isEmpty {
            VStack(alignment: alignment, spacing: 4) {
                ForEach(facts, id: \.self) { Text($0) }
            }
            .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
            #if !os(tvOS)
            .multilineTextAlignment(.center)
            #endif
        }
    }

    private var alignment: HorizontalAlignment {
        #if os(tvOS)
        return .leading
        #else
        return .center
        #endif
    }

    private var factLines: [String] {
        var out: [String] = []
        if let d = info?.department ?? person.department, !d.isEmpty { out.append("\(L("Known for")): \(Self.department(d))") }
        if let b = info?.birthday {
            var line = L("Born %@", format(b))
            if let p = info?.birthPlace { line += " · \(p)" }
            out.append(line)
        } else if let p = info?.birthPlace { out.append(p) }
        if let d = info?.deathday { out.append(L("Died %@", format(d))) }
        return out
    }

    private func format(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).year().locale(Localizer.shared.locale))
    }

    static func department(_ d: String) -> String {
        switch d {
        case "Acting": return L("Acting")
        case "Directing": return L("Directing")
        case "Writing": return L("Writing")
        case "Production": return L("Production")
        default: return d
        }
    }

    @ViewBuilder private var biography: some View {
        if let bio = info?.biography {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Biography")).font(.system(size: tvScaled(17), weight: .bold)).foregroundStyle(.white)
                // knop: op Apple TV focusbaar (en uitklapbaar), op iPhone/Mac tikken om alles te lezen
                Button { withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio).font(.system(size: tvScaled(15))).foregroundStyle(.white.opacity(0.88))
                            .lineLimit(bioExpanded ? nil : 5)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if bio.count > 280 {
                            Text(bioExpanded ? L("Show less") : L("Show more"))
                                .font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    #if os(tvOS)
                    .padding(16)
                    #endif
                }
                .plainTVButton()
            }
        }
    }

    // MARK: rijen

    private var availableRow: some View {
        MediaRow(title: L("Available in Bingr")) {
            ForEach(available) { t in
                Button { detail = t } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster, watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)))
                        case .series(let s):
                            PosterCard(title: s.title, poster: s.poster)
                        }
                    }
                }
                .cardButton()
            }
        }
    }

    private var moreRow: some View {
        MediaRow(title: L("More with %@", name)) {
            ForEach(more) { c in
                Button { credit = c } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        PosterCard(title: c.title, poster: c.poster)
                        Text(c.year.map { "\(c.title) (\($0))" } ?? c.title)
                            .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(1)
                            .frame(width: Theme.posterWidth, alignment: .leading)
                    }
                }
                .cardButton()
            }
        }
    }

    private func initials(_ n: String) -> String {
        n.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    // MARK: laden

    private func load() async {
        let svc = PersonService.shared
        var id = person.tmdbID
        if id == nil { id = await svc.resolve(name: person.name) }
        guard let id else { loading = false; return }
        async let i = svc.info(id: id)
        async let c = svc.credits(id: id)
        let (pi, credits) = await (i, c)
        if Task.isCancelled { return }
        info = pi

        // koppelen aan de (al per profiel gefilterde) afspeellijst, met dezelfde index als de Top 10
        let lib = playlists.library
        let key = "\(playlists.source?.id.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)"
        var found: [DetailTarget] = [], seen = Set<String>(), rest: [PersonCredit] = []
        if !lib.movies.isEmpty || !lib.series.isEmpty {
            let matcher = await MatcherCache.shared.matcher(for: lib, key: key)
            if Task.isCancelled { return }
            for c in credits {
                let ext = ExternalTitle(titles: c.titles, year: c.year)
                var t: DetailTarget?
                if c.isShow { if let x = matcher.series(ext) { t = .series(x) } }
                else if let m = matcher.movie(ext) { t = .movie(m) }
                if let t {
                    if allowed(t), seen.insert(t.id).inserted { found.append(t) }
                } else {
                    rest.append(c)
                }
            }
        } else {
            rest = credits
        }
        available = found
        more = Array(rest.filter { $0.poster != nil }.prefix(40))
        loading = false
    }

    /// Leeftijdsfilter van dit profiel (zelfde regel als de afspeellijst en de detailpagina).
    private func allowed(_ t: DetailTarget) -> Bool {
        switch t {
        case .movie(let m): return ParentalControl.shared.allowed(movie: m)
        case .series(let s): return ParentalControl.shared.allowed(series: s)
        }
    }
}

/// Korte info over een titel die niet in je afspeellijsten staat (geen afspelen).
private struct CreditInfoSheet: View {
    let credit: PersonCredit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: tvScaled(18)) {
                RemoteImage(url: credit.poster, placeholder: credit.title)
                    .frame(width: tvScaled(120), height: tvScaled(180)).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
                VStack(alignment: .leading, spacing: tvScaled(10)) {
                    Text(credit.title).font(.system(size: tvScaled(22), weight: .bold)).foregroundStyle(.white)
                    Text([credit.year.map(String.init), credit.isShow ? L("Series") : L("Movie")].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
                    if let ch = credit.character, !ch.isEmpty {
                        Text(ch).font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    if let o = credit.overview, !o.isEmpty {
                        Text(o).font(.system(size: tvScaled(15))).foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label(L("Not in your playlists"), systemImage: "info.circle")
                        .font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(Theme.secondary)
                    NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary) { dismiss() }
                        .padding(.top, tvScaled(6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.edge)
        }
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #elseif os(macOS)
        .frame(minWidth: 520, minHeight: 320)
        #endif
    }
}

/// Ronde foto + naam (cast op de detailpagina, Personen bij Zoeken).
struct PersonBubble: View {
    let name: String
    let photo: URL?
    var subtitle: String?
    var size: CGFloat = tvScaled(84)

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Theme.elevated)
                if let photo { RemoteImage(url: photo).clipShape(Circle()) }
                else {
                    Text(name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
                        .font(.system(size: size / 3.5, weight: .bold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: size, height: size)
            Text(name).font(.system(size: tvScaled(13), weight: .medium)).foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .frame(width: size + tvScaled(24))
    }
}
