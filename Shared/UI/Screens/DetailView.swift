import SwiftUI

/// Detailpagina in UHF/Netflix-stijl: grote afbeelding met logo, score, afspeelknop,
/// Mijn lijst + Andere bronnen, beschrijving, afleveringen, beoordelingen, cast en aanbevelingen.
struct DetailView: View {
    let target: DetailTarget

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var d: TitleDetails?
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var seasonInfo: [String: TitleDetails.EpisodeInfo] = [:]
    @State private var loading = true
    @State private var showTrailer = false
    @State private var showSources = false
    @State private var sources: [PlaylistService.OtherHit] = []
    @State private var nested: DetailTarget?
    @State private var toast: String?
    @State private var scrollY: CGFloat = 0
    /// Aanbevelingen die in je lijst staan (één keer opgezocht, niet bij elke scrollframe)
    @State private var recMatches: [String: DetailTarget] = [:]
    @State private var ageGate = false
    @State private var afterPIN: (() -> Void)?
    @State private var pinOK = false
    @State private var showShareQR = false

    private var pid: UUID? { playlists.source?.id }
    private var baseTitle: String { switch target { case .movie(let m): return m.title; case .series(let s): return s.title } }
    private var title: String { d?.title ?? baseTitle }
    private var imdb: String? {
        switch target {
        case .movie(let m): return trakt.imdb(for: m) ?? d?.imdbID
        case .series(let s): return trakt.imdb(for: s) ?? d?.imdbID
        }
    }
    private var heroImage: URL? {
        #if os(tvOS)
        return d?.backdrop ?? d?.poster ?? basePoster
        #else
        return d?.poster ?? basePoster ?? d?.backdrop
        #endif
    }
    private var basePoster: URL? { switch target { case .movie(let m): return m.poster; case .series(let s): return s.poster } }
    private var seasons: [Int] { orderedUnique(episodes.map(\.season)).sorted() }
    private var isMovie: Bool { if case .movie = target { return true }; return false }
    private var headerHeight: CGFloat {
        #if os(tvOS)
        return 760
        #else
        return 560
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(22)) {
                    header
                    VStack(alignment: .leading, spacing: tvScaled(22)) {
                        metaRow
                        actions
                        if let o = d?.overview, !o.isEmpty {
                            Text(o).font(.system(size: tvScaled(16))).foregroundStyle(.white.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: tvScaled(700), alignment: .leading)
                        } else if loading {
                            ProgressView().tint(.white).frame(maxWidth: .infinity)
                        }
                        if !(d?.genres.isEmpty ?? true) || d?.director != nil { creditsBlock }
                    }
                    .padding(.horizontal, Theme.edge)

                    if case .series(let s) = target { episodesSection(s) }
                    if let r = d?.ratings, !r.isEmpty { ratingsSection(r) }
                    if let c = d?.cast, !c.isEmpty { castSection(c) }
                    if let rec = visibleRecommendations, !rec.isEmpty { recommendationsSection(rec) }
                    Color.clear.frame(height: 40)
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: DetailOffsetKey.self, value: g.frame(in: .named("detail")).minY)
                })
            }
            .coordinateSpace(name: "detail")
            .onPreferenceChange(DetailOffsetKey.self) { scrollY = $0 }
            .ignoresSafeArea(edges: .top)

            #if !os(tvOS)
            stickyBar
            #endif

            if let toast {
                Text(toast).font(.system(size: tvScaled(13), weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .task(id: target.id) { await load() }
        .task(id: d?.recommendations.map(\.id) ?? []) { await matchRecommendations() }
        .sheet(isPresented: $showSources) { sourcesSheet }
        #if os(tvOS)
        .sheet(isPresented: $showShareQR) { shareQRSheet }
        #endif
        .sheet(isPresented: $ageGate, onDismiss: {
            // pas afspelen als het pincodescherm helemaal weg is (anders opent de speler niet, vooral op Apple TV)
            let run = pinOK ? afterPIN : nil
            afterPIN = nil; pinOK = false
            if let run { Task { @MainActor in try? await Task.sleep(nanoseconds: 150_000_000); run() } }
        }) {
            PINPad(title: L("This title is above the age limit of this profile. Enter PIN")) { pin in
                guard ParentalControl.shared.check(pin) else { return false }   // alleen deze titel, niet alles ontgrendelen
                pinOK = true
                return true
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: $showTrailer) {
            if let t = d?.trailerYouTubeID { TrailerSheet(youtubeID: t, title: title) }
        }
        .sheet(item: $nested) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $nested) { DetailView(target: $0) }
        #endif
    }

    // MARK: kop

    private var header: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: heroImage, placeholder: "")
                .frame(height: headerHeight + max(scrollY, 0))
                .frame(maxWidth: .infinity)
                .clipped()
                .offset(y: scrollY > 0 ? -scrollY / 2 : 0)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.65), location: 0.75),
                                   .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
            #if os(tvOS)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
            #endif
            titleArt
                .padding(.horizontal, Theme.edge).padding(.bottom, tvScaled(8))
            #if !os(tvOS)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 58).padding(.trailing, 16)
            #endif
        }
        .frame(height: headerHeight)
    }

    @ViewBuilder private var titleArt: some View {
        let align = alignLeadingOnTV
        if let logo = d?.logo {
            AsyncImage(url: logo) { img in img.resizable().scaledToFit() } placeholder: { titleText }
                .frame(maxWidth: tvScaled(300), maxHeight: tvScaled(110))
                .frame(maxWidth: .infinity, alignment: align)
                .shadow(color: .black.opacity(0.6), radius: 10)
        } else {
            titleText.frame(maxWidth: .infinity, alignment: align)
        }
    }

    private var titleText: some View {
        Text(title.uppercased())
            .font(.system(size: tvScaled(38), weight: .black)).kerning(1)
            .lineLimit(2).minimumScaleFactor(0.5)
            #if !os(tvOS)
            .multilineTextAlignment(.center)
            #endif
            .shadow(color: .black.opacity(0.7), radius: 10)
    }

    private var metaRow: some View {
        HStack(spacing: tvScaled(14)) {
            let main = d?.ratings.first { $0.source == "IMDb" } ?? d?.ratings.first
            Text("★ \(main?.value ?? "–")")
                .font(.system(size: tvScaled(15), weight: .bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            if let y = d?.year { Text(String(y.prefix(4))) }
            if let c = d?.certification { Text(c).font(.system(size: tvScaled(12), weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.secondary)) }
            if !isMovie, !seasons.isEmpty {
                Text(seasons.count == 1 ? L("1 season") : L("%d seasons", seasons.count))
            } else if let rt = d?.runtime { Text(rt) }
            if isWatchedTitle { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
        }
        .font(.system(size: tvScaled(16)))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: alignLeadingOnTV)
    }

    private var alignLeadingOnTV: Alignment {
        #if os(tvOS)
        return .leading
        #else
        return .center
        #endif
    }

    // MARK: knoppen

    @ViewBuilder private var actions: some View {
        VStack(spacing: tvScaled(12)) {
            playButton
            HStack(spacing: tvScaled(12)) {
                circleButton(inMyList ? "heart.fill" : "heart") { toggleMyList() }
                if let _ = d?.trailerYouTubeID { circleButton("film") { openTrailer() } }
                if isMovie { circleButton(isWatchedTitle ? "checkmark.circle.fill" : "checkmark.circle") { toggleWatchedMovie() } }
                shareButton
                Button { Task { await openSources() } } label: {
                    Text(L("Other sources")).font(.system(size: tvScaled(15), weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: tvScaled(50))
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12)))
                }
                .plainTVButton()
            }
        }
        .frame(maxWidth: tvScaled(700))
        .frame(maxWidth: .infinity, alignment: alignLeadingOnTV)
    }

    private var playButton: some View {
        Button { play() } label: {
            Label(playTitle, systemImage: "play.fill")
                .font(.system(size: tvScaled(16), weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).frame(height: tvScaled(52))
                .background(.white, in: Capsule())
                .overlay(alignment: .bottom) {
                    if let p = resumeFraction, p > 0.02 {
                        GeometryReader { g in
                            Capsule().fill(Theme.red).frame(width: g.size.width * p, height: 3)
                        }.frame(height: 3).padding(.horizontal, 24).padding(.bottom, 6)
                    }
                }
        }
        .plainTVButton()
        .disabled(isMovie ? false : episodes.isEmpty && !loading)
    }

    // MARK: delen

    /// Titel zonder IPTV-rommel ("NL | Reacher (2022) 4K" → "Reacher").
    private var shareTitle: String {
        if let t = d?.title { return t }
        return TitleCleaner.parse(baseTitle).title
    }
    private var shareYear: String? {
        if let y = d?.year { return y }
        switch target { case .movie(let m): return m.year.map(String.init); case .series(let s): return s.year.map(String.init) }
    }
    /// Openbare link: IMDb (mooie preview in WhatsApp/iMessage), anders Trakt of TMDB.
    private var shareURL: URL? {
        if let i = imdb { return URL(string: "https://www.imdb.com/title/\(i)/") }
        if let slug = d?.traktSlug { return URL(string: "https://trakt.tv/\(isMovie ? "movies" : "shows")/\(slug)") }
        if let t = d?.tmdbID { return URL(string: "https://www.themoviedb.org/\(isMovie ? "movie" : "tv")/\(t)") }
        return nil
    }
    private var shareText: String {
        let name = shareYear.map { "\(shareTitle) (\($0))" } ?? shareTitle
        return L(isMovie ? "Movie tip: %@" : "Series tip: %@", name)
    }

    @ViewBuilder private var shareButton: some View {
        #if !os(tvOS)
        Group {
            if let url = shareURL {
                ShareLink(item: url, subject: Text(shareTitle), message: Text(shareText),
                          preview: SharePreview(shareTitle)) { shareIcon }
            } else {
                ShareLink(item: shareText, subject: Text(shareTitle), preview: SharePreview(shareTitle)) { shareIcon }
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = shareURL?.absoluteString ?? shareText
                flash(L("Link copied"))
            } label: { Label(L("Copy link"), systemImage: "doc.on.doc") }
        }
        .accessibilityLabel(L("Share"))
        #else
        // Apple TV kan niet delen: QR-code om met je telefoon te scannen
        if shareURL != nil { circleButton("square.and.arrow.up") { showShareQR = true } }
        #endif
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up").font(.system(size: tvScaled(19), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: tvScaled(50), height: tvScaled(50))
            .background(Color.white.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.12)))
    }

    #if os(tvOS)
    private var shareQRSheet: some View {
        VStack(spacing: 30) {
            Text(L("Share")).font(.system(size: 46, weight: .bold))
            Text(shareText).font(.system(size: 28)).foregroundStyle(Theme.secondary)
            if let u = shareURL, let img = QRCode.image(u.absoluteString) {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 360, height: 360)
                    .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))
                Text(L("Scan with your phone to share via WhatsApp, iMessage and more."))
                    .font(.system(size: 26)).foregroundStyle(Theme.secondary)
                Text(u.absoluteString).font(.system(size: 24, design: .monospaced))
            }
        }
        .padding(60)
    }
    #endif

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: tvScaled(19), weight: .semibold))
                .foregroundStyle(icon.hasPrefix("heart.fill") ? Theme.red : .white)
                .frame(width: tvScaled(50), height: tvScaled(50))
                .background(Color.white.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12)))
        }
        .plainTVButton()
    }

    private var playTitle: String {
        switch target {
        case .movie: return (resumeFraction ?? 0) > 0.02 ? L("Resume") : L("Play")
        case .series:
            guard let n = nextEpisode else { return L("Play") }
            return L("Play Season %d: Episode %d", n.season, n.number)
        }
    }

    private var resumeFraction: Double? {
        switch target {
        case .movie(let m): return Playables.resume(m.id, imdb: imdb)
        case .series: return nextEpisode.flatMap { store.progress[$0.id]?.fraction }
        }
    }

    // MARK: blokken

    private var creditsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let g = d?.genres, !g.isEmpty { creditLine(L("Genres"), g.joined(separator: ", ")) }
            if let dir = d?.director { creditLine(L("Director"), dir) }
        }
    }

    private func creditLine(_ k: String, _ v: String) -> some View {
        (Text("\(k): ").foregroundStyle(Theme.secondary) + Text(v).foregroundStyle(.white.opacity(0.85)))
            .font(.system(size: tvScaled(13))).lineLimit(2)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: tvScaled(14), weight: .semibold)).kerning(0.5)
            .foregroundStyle(Theme.secondary).padding(.horizontal, Theme.edge)
    }

    @ViewBuilder private func episodesSection(_ s: Series) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(14)) {
            sectionTitle(L("Episodes"))
            HStack(spacing: 12) {
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.self) { n in Button(L("Season %d", n)) { season = n } }
                    } label: { seasonPill(chevron: true) }
                } else if !seasons.isEmpty {
                    seasonPill(chevron: false)
                }
                Spacer()
                let list = episodes.filter { $0.season == season }
                if !list.isEmpty {
                    let all = list.allSatisfy { Playables.isWatched($0, imdb: imdb) }
                    Button {
                        for e in list { store.setLocalWatched(e.id, !all) }
                        if let imdb { Task { await trakt.setWatched(show: imdb, episodes: list, !all) } }
                    } label: {
                        Image(systemName: all ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: tvScaled(22))).foregroundStyle(all ? Theme.red : Theme.secondary)
                    }
                    .plainTVButton()
                }
            }
            .padding(.horizontal, Theme.edge)

            if loading && episodes.isEmpty { ProgressView().tint(.white).frame(maxWidth: .infinity) }
            let list = episodes.filter { $0.season == season }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: tvScaled(14)) {
                        ForEach(list) { e in episodeCard(e, s).id(e.id) }
                    }
                    .padding(.horizontal, Theme.edge)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    #endif
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
                .onAppear { if let n = nextEpisode, n.season == season { proxy.scrollTo(n.id, anchor: .leading) } }
            }
        }
        .task(id: season) {
            guard let d else { return }
            let info = await DetailsService.shared.seasonInfo(d, season: season)
            if !info.isEmpty { seasonInfo.merge(info) { _, new in new } }
        }
    }

    private func seasonPill(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(L("Season %d", season)).font(.system(size: tvScaled(16), weight: .semibold))
            if chevron { Image(systemName: "chevron.down").font(.system(size: tvScaled(11), weight: .bold)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.12), in: Capsule())
        .foregroundStyle(.white)
    }

    private func info(_ e: Episode) -> TitleDetails.EpisodeInfo? {
        seasonInfo["\(e.season)-\(e.number)"] ?? d?.episodeInfo["\(e.season)-\(e.number)"]
    }

    private func episodeCard(_ e: Episode, _ s: Series) -> some View {
        let i = info(e)
        let watched = Playables.isWatched(e, imdb: imdb)
        let progress = store.progress[e.id]?.fraction
        let w = tvScaled(290)
        return Button { ageChecked { app.play(Playables.episode(e, of: s, imdb: imdb)) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: i?.still ?? e.still ?? d?.backdrop ?? s.poster, placeholder: "")
                        .frame(width: w, height: w * 9 / 16).clipped()
                    if let progress, progress > 0 {
                        Capsule().fill(Color.white.opacity(0.3)).frame(height: 5)
                            .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: (w - 32) * progress, height: 5) }
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                    if watched {
                        WatchedBadge().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
                    }
                }
                .frame(width: w, height: w * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: tvScaled(12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "S%02dE%02d", e.season, e.number)).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                    Text(i?.title.flatMap { $0.isEmpty ? nil : $0 } ?? Playables.cleanEpisodeTitle(e))
                        .font(.system(size: tvScaled(16), weight: .semibold)).lineLimit(1)
                    if let o = i?.overview ?? e.plot, !o.isEmpty {
                        Text(o).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary).lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 8) {
                        if let a = i?.airDate { Text(a.formatted(date: .long, time: .omitted)) }
                        if let rt = i?.runtime ?? e.durationSeconds.map({ $0 / 60 }), rt > 0 { Text(L("%d min", rt)) }
                    }
                    .font(.system(size: tvScaled(12))).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 4)
            }
            .frame(width: w, alignment: .leading)
            .padding(.bottom, 8)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: tvScaled(14)))
        }
        .plainTVButton()
        .contextMenu {
            Button {
                store.setLocalWatched(e.id, !watched)
                Task { await trakt.setWatched(Playables.episode(e, of: s, imdb: imdb), !watched) }
            } label: { Label(watched ? L("Mark as unwatched") : L("Mark as watched"), systemImage: watched ? "eye.slash" : "checkmark.circle") }
        }
    }

    private func ratingsSection(_ r: [TitleDetails.Rating]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            sectionTitle(L("Ratings"))
            HStack(alignment: .top, spacing: tvScaled(40)) {
                ForEach(r) { x in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            ratingLogo(x.source)
                            Text(x.source).font(.system(size: tvScaled(16))).foregroundStyle(Theme.secondary)
                        }
                        Text(x.value).font(.system(size: tvScaled(22), weight: .bold))
                    }
                }
            }
            .padding(.horizontal, Theme.edge)
        }
    }

    @ViewBuilder private func ratingLogo(_ source: String) -> some View {
        switch source {
        case "IMDb":
            Text("IMDb").font(.system(size: tvScaled(9), weight: .black)).foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 2).background(Theme.imdb, in: RoundedRectangle(cornerRadius: 3))
        case "Trakt":
            Image(systemName: "checkmark.square.fill").foregroundStyle(Color(hex: 0xED1C24)).font(.system(size: tvScaled(16)))
        default:
            Image(systemName: "star.fill").foregroundStyle(Theme.secondary).font(.system(size: tvScaled(13)))
        }
    }

    private func castSection(_ cast: [TitleDetails.CastMember]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            sectionTitle(L("Cast"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(tvScaled(76)), spacing: tvScaled(14)),
                                 GridItem(.fixed(tvScaled(76)), spacing: tvScaled(14))], spacing: tvScaled(26)) {
                    ForEach(cast) { c in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Theme.elevated)
                                if let p = c.photo { RemoteImage(url: p).clipShape(Circle()) }
                                else { Text(initials(c.name)).font(.system(size: tvScaled(18), weight: .bold)).foregroundStyle(Theme.secondary) }
                            }
                            .frame(width: tvScaled(70), height: tvScaled(70))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: tvScaled(16), weight: .medium)).lineLimit(1)
                                if let ch = c.character, !ch.isEmpty {
                                    Text(ch).font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: tvScaled(170), alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, Theme.edge)
            }
        }
    }

    private func initials(_ n: String) -> String {
        n.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private func recommendationsSection(_ rec: [TitleDetails.Recommendation]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            sectionTitle(L("Recommendations"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: tvScaled(14)) {
                    ForEach(rec) { r in
                        Button { openRecommendation(r) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteImage(url: r.poster, placeholder: r.title)
                                    .frame(width: tvScaled(160), height: tvScaled(240)).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: tvScaled(12)))
                                    .overlay(alignment: .topTrailing) {
                                        if findInLibrary(r) != nil {
                                            Image(systemName: "play.circle.fill").font(.system(size: tvScaled(20)))
                                                .foregroundStyle(.white, Theme.red).padding(6)
                                        }
                                    }
                                Text(r.title).font(.system(size: tvScaled(14))).lineLimit(1)
                                    .frame(width: tvScaled(160), alignment: .leading)
                            }
                        }
                        .cardButton()
                    }
                }
                .padding(.horizontal, Theme.edge)
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    #if !os(tvOS)
    private var stickyBar: some View {
        let show = scrollY < -(headerHeight - 120)
        return HStack {
            Spacer()
            Text(title).font(.headline).lineLimit(1).opacity(show ? 1 : 0)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if show {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                }.padding(.trailing, 16)
            }
        }
        .frame(height: 56)
        .padding(.top, 50)
        .background(.ultraThinMaterial.opacity(show ? 1 : 0))
        .animation(.easeInOut(duration: 0.2), value: show)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(show)
    }
    #endif

    private var sourcesSheet: some View {
        NavigationStack {
            List {
                if sources.isEmpty {
                    Text(L("This title isn't available in your other groups or playlists.")).foregroundStyle(Theme.secondary)
                }
                ForEach(sources) { h in
                    Button {
                        showSources = false
                        if h.playlist.id == pid { openLocal(h.itemID) } else { dismiss(); app.open(h.playlist, thenShow: h.itemID) }
                    } label: {
                        HStack(spacing: 12) {
                            MiniAvatar(playlist: h.playlist, size: 34)
                            VStack(alignment: .leading) {
                                Text(h.playlist.name)
                                Text(h.subtitle).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Other sources"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { showSources = false } } }
        }
    }

    // MARK: acties

    private var isWatchedTitle: Bool {
        if case .movie(let m) = target { return Playables.isWatched(movie: m, imdb: imdb) }
        return false
    }

    /// Mijn lijst van dít profiel (de Trakt-watchlist volgt mee, maar bepaalt niet wat er in je lijst staat).
    private var inMyList: Bool { pid.map { store.inMyList($0, target.id) } ?? false }

    private var nextEpisode: Episode? {
        // de laatst bekeken aflevering met voortgang (niet zomaar de eerste in de lijst)
        let started = episodes.compactMap { e in store.progress[e.id].flatMap { $0.fraction > 0.02 && $0.fraction < 0.95 ? (e, $0.updated) : nil } }
        if let resumed = started.max(by: { $0.1 < $1.1 })?.0 { return resumed }
        return episodes.first { !Playables.isWatched($0, imdb: imdb) } ?? episodes.first
    }

    /// Leeftijdsfilter van dit profiel: boven de grens alleen met pincode.
    private func ageChecked(_ action: @escaping () -> Void) {
        let limit = store.activeProfile?.effectiveAgeLimit
        let group: String = { switch target { case .movie(let m): return m.group; case .series(let s): return s.group } }()
        let cached: TitleMetadata? = {
            switch target {
            case .movie(let m): return MetadataService.shared.cached(m)
            case .series(let s): return MetadataService.shared.cached(s)
            }
        }()
        let rated = d?.certification ?? cached?.rated
        let genre = cached?.genre ?? d.map { $0.genres.joined(separator: ",") }
        if ParentalControl.shared.allowed(rated: rated, group: group, limit: limit, genre: genre,
                                          strict: store.activeProfile?.strictAgeFilter ?? false) { action(); return }
        if ParentalControl.shared.hasPIN { afterPIN = action; ageGate = true }
        else { flash(L("Not available on this profile (age limit).")) }
    }

    private func play() { ageChecked(playNow) }

    private func playNow() {
        switch target {
        case .movie(let m):
            if m.streamURL == nil && m.stalkerCmd == nil && m.imdbID == nil && imdb == nil {
                Task { await openSources() }; return
            }
            app.play(Playables.movie(m, imdb: imdb))
        case .series(let s):
            if let n = nextEpisode { app.play(Playables.episode(n, of: s, imdb: imdb)) }
            else { Task { await openSources() } }
        }
    }

    private func toggleMyList() {
        guard let pid else { return }
        let on = !inMyList
        store.setMyList(pid, target.id, on)
        if let imdb, store.isMainActive { Task { await trakt.setWatchlist(imdb: imdb, isShow: target.isSeries, on) } }
        flash(on ? L("Added to My List") : L("Removed from My List"))
    }

    private func toggleWatchedMovie() {
        guard case .movie(let m) = target else { return }
        let w = isWatchedTitle
        store.setLocalWatched(m.id, !w)
        Task { await trakt.setWatched(Playables.movie(m, imdb: imdb), !w) }
    }

    private func openTrailer() {
        guard let t = d?.trailerYouTubeID else { return }
        #if !os(tvOS)
        showTrailer = true
        #else
        if let u = Trailer.appURL(t) { openURL(u) { ok in if !ok, let w = Trailer.webURL(t) { openURL(w) } } }
        #endif
    }

    private func openSources() async {
        let year = d?.year.flatMap { Int($0.prefix(4)) }
        sources = await playlists.otherSources(title: title, year: year, isShow: target.isSeries, excluding: target.id)
        showSources = true
    }

    private func openLocal(_ id: String) {
        if let m = playlists.library.movies.first(where: { $0.id == id }) { nested = .movie(m) }
        else if let s = playlists.library.series.first(where: { $0.id == id }) { nested = .series(s) }
    }

    private func findInLibrary(_ r: TitleDetails.Recommendation) -> DetailTarget? { recMatches[r.id] }

    /// Profielen met een leeftijdsgrens zien alleen aanbevelingen die (gefilterd) in hun lijst staan.
    private var visibleRecommendations: [TitleDetails.Recommendation]? {
        guard let rec = d?.recommendations else { return nil }
        guard store.activeProfile?.effectiveAgeLimit != nil else { return rec }
        return rec.filter { recMatches[$0.id] != nil }
    }

    private func matchRecommendations() async {
        guard let rec = d?.recommendations, !rec.isEmpty else { recMatches = [:]; return }
        let movies = playlists.library.movies, series = playlists.library.series
        recMatches = await Task.detached(priority: .userInitiated) {
            let wanted = Set(rec.map { PlaylistService.normTitle($0.title) })
            var mv: [String: [Movie]] = [:], sv: [String: Series] = [:]
            for m in movies { let n = PlaylistService.normTitle(m.title); if wanted.contains(n) { mv[n, default: []].append(m) } }
            for x in series { let n = PlaylistService.normTitle(x.title); if wanted.contains(n), sv[n] == nil { sv[n] = x } }
            var out: [String: DetailTarget] = [:]
            for r in rec {
                let n = PlaylistService.normTitle(r.title)
                if r.isShow { if let x = sv[n] { out[r.id] = .series(x) } }
                else if let m = mv[n]?.first(where: { r.year == nil || $0.year == nil || $0.year == r.year }) { out[r.id] = .movie(m) }
            }
            return out
        }.value
    }

    private func openRecommendation(_ r: TitleDetails.Recommendation) {
        if let t = findInLibrary(r) { nested = t; return }
        // niet in deze afspeellijst: toon de details (afspelen zoekt in andere bronnen / Stremio)
        if r.isShow {
            nested = .series(Series(id: "rec-\(r.id)", title: r.title, year: r.year, poster: r.poster, group: "", imdbID: r.imdbID))
        } else {
            nested = .movie(Movie(id: "rec-\(r.id)", title: r.title, year: r.year, poster: r.poster, group: "", imdbID: r.imdbID))
        }
    }

    private func flash(_ t: String) {
        withAnimation { toast = t }
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { if toast == t { toast = nil } } }
    }

    private func load() async {
        loading = true
        var epsTask: Task<[Episode], Never>?
        if case .series(let s) = target {
            let pl = playlists
            epsTask = Task { await pl.episodes(for: s) }
        }
        d = await DetailsService.shared.details(for: target, playlists: playlists, knownIMDb: imdb)
        episodes = await epsTask?.value ?? []
        if let n = nextEpisode { season = n.season } else if let f = seasons.first { season = f }
        loading = false
    }
}

private struct DetailOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
