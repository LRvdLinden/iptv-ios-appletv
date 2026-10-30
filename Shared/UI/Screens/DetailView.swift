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
    /// Geopende acteur/actrice uit de cast
    @State private var person: PersonRef?
    @State private var toast: String?
    /// Scrollpositie apart: alleen de kopafbeelding en de balk lezen hem (anders rekent de hele pagina per frame opnieuw)
    @State private var scroll = ScrollTracker()
    /// Aanbevelingen die in je lijst staan (één keer opgezocht, niet bij elke scrollframe)
    @State private var recMatches: [String: DetailTarget] = [:]
    @State private var ageGate = false
    @State private var afterPIN: (() -> Void)?
    @State private var pinOK = false
    @State private var collecting: CollectionTarget?
    /// Leeftijdsclassificatie uit TMDB (Kijkwijzer eerst), build 53
    @State private var ageInfo: AgeInfo?
    /// Trailer per seizoen (TMDB), seizoen → YouTube-ID; build 53
    @State private var seasonTrailers: [Int: String] = [:]
    /// De trailer die in het blad speelt
    @State private var trailerID: String?
    /// Build 59: dezelfde titel in andere talen in je bibliotheek
    @State private var languageVersions: [LanguageVersion] = []
    @State private var showLanguages = false
    #if !os(tvOS)
    /// Build 82: trailer automatisch (zonder geluid) in de kop
    @StateObject private var heroTrailer = HeroTrailerModel()
    @AppStorage(Trailer.autoplayKey) private var autoplayTrailers = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #endif
    #if os(tvOS)
    /// Build 85: de kop beweegt (Ken Burns) zolang de pagina echt in beeld is
    @Environment(\.scenePhase) private var scenePhase
    /// Apple TV: focus in de afleveringenrij begint bij de aflevering waar je bent
    @FocusState private var focusedEpisode: String?
    @Namespace private var episodeNS
    @State private var episodeFocusRedirected = false
    #endif

    /// Build 128: de server van deze titel (een andere server als hij daarvandaan komt), anders de open server
    private var pid: UUID? { target.sourceID ?? playlists.source?.id }
    /// Build 128: titel van een andere server die nog niet gevonden is: zoeken of de melding
    @State private var crossPrompt: CrossServer.Prompt?
    private var baseTitle: String { switch target { case .movie(let m): return m.title; case .series(let s): return s.title } }
    /// Titel zonder taallabel ("Animal (IT)" → "Animal"), build 59
    private var title: String { d?.title ?? ContentLanguage.displayTitle(baseTitle) }
    /// Taal van deze versie (label in de titel/categorie, anders de originele taal uit TMDB)
    private var language: ContentLanguage? {
        switch target {
        case .movie(let m): return ContentLanguage.of(m)
        case .series(let s): return ContentLanguage.of(s)
        }
    }
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
    #if os(tvOS)
    /// Build 85: de hoofdafbeelding plus maximaal twee andere achtergronden (TMDB/server) voor de bewegende kop
    private var heroBackdrops: [URL] {
        let extra = d?.backdrop == nil ? [] : (d?.backdrops ?? [])
        return Array(orderedUnique([heroImage].compactMap { $0 } + extra).prefix(3))
    }
    /// Niet wisselen als er iets speelt of een ander scherm erover ligt
    private var heroActive: Bool {
        app.playing == nil && scenePhase == .active && nested == nil && person == nil && !showSources
            && !showLanguages && collecting == nil && !ageGate
    }
    #endif
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
                        // build 111: titel uit TMDB (Binnenkort op Bingr / Nieuw op Bingr): niet in je afspeellijst en
                        // de datum (build 112: bronvermelding staat in Instellingen → Over)
                        if let note = DiscoverStore.detailNote(for: target.id) {
                            Text(note).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, Theme.edge)

                    if case .series(let s) = target { episodesSection(s) }
                    if let r = d?.ratings, !r.isEmpty { ratingsSection(r) }
                    if let c = d?.cast, !c.isEmpty { castSection(c) }
                    if let rec = visibleRecommendations, !rec.isEmpty { recommendationsSection(rec) }
                    Color.clear.frame(height: 40)
                }
                #if !os(tvOS)
                .background(GeometryReader { g in
                    Color.clear.preference(key: DetailOffsetKey.self, value: g.frame(in: .named("detail")).minY)
                })
                #endif
            }
            .coordinateSpace(name: "detail")
            #if !os(tvOS)
            .onPreferenceChange(DetailOffsetKey.self) { y in
                let v = max(-800, min(400, y))
                if abs(v - scroll.y) >= 2 { scroll.y = v }
            }
            #endif
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
        .task(id: target.id) { await resolveCrossServer() }
        .crossServerPrompt($crossPrompt)
        .task(id: "\(target.id)-\(playlists.libraryVersion)") { await loadLanguageVersions() }
        .task(id: d?.recommendations.map(\.id) ?? []) { await matchRecommendations() }
        #if !os(tvOS)
        .task(id: "\(target.id)-\(loading)-\(seasons.last ?? 0)") { await autoplayTrailer() }
        .onChange(of: trailerBlocked) { _, blocked in if blocked { heroTrailer.stop() } }
        .onChange(of: autoplayTrailers) { _, on in if !on { heroTrailer.stop() } }
        .onDisappear { heroTrailer.stop() }
        #endif
        .sheet(isPresented: $showSources) { sourcesSheet }
        .sheet(isPresented: $showLanguages) { languagesSheet }
        .sheet(item: $collecting) { AddToCollectionSheet(target: $0) }
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
            if let t = trailerID ?? currentTrailer { TrailerSheet(youtubeID: t, title: title) }
        }
        .sheet(item: $nested) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $nested) { DetailView(target: $0) }
        #endif
        #if os(iOS)
        .sheet(item: $person) { PersonView(person: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $person) { PersonView(person: $0) }
        #endif
    }

    // MARK: kop

    private var header: some View {
        ZStack(alignment: .bottom) {
            #if os(tvOS)
            KenBurnsBackdrop(urls: heroBackdrops, height: headerHeight, active: heroActive, maxPixel: 1600)
            #else
            ParallaxImage(url: heroImage, height: headerHeight, scroll: scroll)
            heroTrailerLayer
            #endif
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
            heroTrailerControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 58).padding(.leading, 16)
            #endif
        }
        .frame(height: headerHeight)
    }

    #if !os(tvOS)
    // MARK: trailer in de kop (build 82)

    /// De trailer over de kopafbeelding; komt pas in beeld (overvloeiend) als hij echt speelt.
    @ViewBuilder private var heroTrailerLayer: some View {
        if let id = heroTrailer.videoID {
            HeroTrailerView(id: id, model: heroTrailer)
                .id(heroTrailer.token)
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .allowsHitTesting(false)
                .opacity(heroTrailer.isVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.8), value: heroTrailer.isVisible)
                .accessibilityHidden(true)
                .transition(.opacity.animation(.easeInOut(duration: 0.6)))
        }
    }

    /// Geluid aan/uit tijdens de trailer, daarna "Opnieuw afspelen".
    @ViewBuilder private var heroTrailerControls: some View {
        if heroTrailer.isVisible {
            heroControlButton(heroTrailer.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { heroTrailer.toggleMute() }
                .accessibilityLabel(heroTrailer.muted ? L("Sound on") : L("Sound off"))
                .transition(.opacity)
        } else if heroTrailer.phase == .finished, autoplayTrailers {
            heroControlButton("arrow.counterclockwise") { heroTrailer.replay() }
                .accessibilityLabel(L("Play trailer again"))
                .transition(.opacity)
        }
    }

    private func heroControlButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Trailer die automatisch speelt: film → die van de film; serie → die van het nieuwste seizoen,
    /// anders die van de serie.
    private func autoplayTrailerID() async -> String? {
        guard let d else { return nil }
        if isMovie { return d.trailerYouTubeID }
        if let newest = seasons.last {
            if let t = seasonTrailers[newest] { return t }
            if let tv = d.tmdbID, let t = await TMDB.seasonTrailer(tvID: tv, season: newest) {
                seasonTrailers[newest] = t
                return t
            }
        }
        return d.trailerYouTubeID
    }

    /// Mag de trailer nu (automatisch) spelen? Niet bij de instelling uit, Bewegingen beperken,
    /// de modus voor weinig data, iets wat speelt, een blad erover of de app op de achtergrond.
    private var trailerAllowed: Bool {
        autoplayTrailers && !reduceMotion && !NetworkStatus.shared.isConstrained && !trailerBlocked
    }

    private var trailerBlocked: Bool {
        app.playing != nil || scenePhase != .active || showTrailer || showSources || showLanguages
            || nested != nil || person != nil || collecting != nil || ageGate
    }

    private func autoplayTrailer() async {
        _ = NetworkStatus.shared   // monitor alvast starten
        guard !loading, d != nil, heroTrailer.phase == .idle, trailerAllowed else { return }
        guard let id = await autoplayTrailerID() else { return }
        // even wachten zoals streamingdiensten; daarna opnieuw controleren
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, heroTrailer.phase == .idle, trailerAllowed else { return }
        heroTrailer.start(id)
    }
    #endif

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
            // screenshotmodus: geen leeg "★ –" (de demo heeft bewust geen scores)
            if main != nil || !Screenshots.isActive {
                Text("★ \(main?.value ?? "–")")
                    .font(.system(size: tvScaled(15), weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            if let y = d?.year { Text(String(y.prefix(4))) }
            if let c = certificationLabel { Text(c).font(.system(size: tvScaled(12), weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.secondary)) }
            if !isMovie, !seasons.isEmpty {
                Text(seasons.count == 1 ? L("1 season") : L("%d seasons", seasons.count))
            } else if let rt = d?.runtime { Text(rt) }
            if isWatchedTitle { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
            // build 59: taal van deze versie ("Taal: Italiaans")
            if let lt = language?.detailText {
                Text(L("Language: %@", lt)).lineLimit(1).minimumScaleFactor(0.7)
            }
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
                // build 141: alleen als de titel een bewaarbaar id heeft (aanbeveling: zodra het TMDB-id bekend is)
                if listID != nil { myListButton }
                if !DiscoverItem.isExternal(target.id) {   // build 111: TMDB-titels niet in collecties
                    circleButton(inAnyCollection ? "rectangle.stack.fill.badge.plus" : "rectangle.stack.badge.plus") {
                        collecting = .detail(target)
                    }
                    .accessibilityLabel(L("Add to collection…"))
                }
                if let t = currentTrailer {
                    circleButton("film") { openTrailer(t) }
                        .accessibilityLabel(hasSeasonTrailer ? L("Trailer season %d", season) : L("Trailer"))
                }
                if isMovie {
                    circleButton(isWatchedTitle ? "checkmark.circle.fill" : "checkmark.circle") { toggleWatchedMovie() }
                        .accessibilityLabel(isWatchedTitle ? L("Mark as unwatched") : L("Mark as watched"))   // build 97
                }
                #if os(iOS)
                // offline kijken (build 52)
                if case .movie(let m) = target, DownloadManager.canDownload(Playables.movie(m, imdb: imdb)) {
                    DownloadButton(item: Playables.movie(m, imdb: imdb), poster: m.poster)
                }
                #endif
                #if !os(tvOS)
                shareButton // geen deelknop (ook geen QR) op tv's, zie docs/ACCOUNT.md
                #endif
                Button { Task { await openSources() } } label: {
                    Label(L("Other sources"), systemImage: Theme.otherSourceIcon)
                        .font(.system(size: tvScaled(15), weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, tvScaled(10))
                        .frame(maxWidth: .infinity).frame(height: tvScaled(50))
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12)))
                }
                .plainTVButton()
            }
            // build 59: dezelfde titel in een andere taal
            if !languageVersions.isEmpty {
                Button { showLanguages = true } label: {
                    Label(L("Other language") + " · " + orderedUnique(languageVersions.map(\.label)).prefix(4).joined(separator: ", "),
                          systemImage: "globe")
                        .font(.system(size: tvScaled(15), weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, tvScaled(14))
                        .frame(maxWidth: .infinity).frame(height: tvScaled(46))
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
                .frame(maxWidth: .infinity).frame(height: tvScaled(52))
                .contentShape(Capsule())
                .overlay(alignment: .bottom) {
                    // voortgang: wit op de accentkleur (build 58; bij goud donker)
                    if let p = resumeFraction, p > 0.02 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.onAccent.opacity(0.3))
                                Capsule().fill(Theme.onAccent).frame(width: g.size.width * p)
                            }
                        }.frame(height: 3).padding(.horizontal, 24).padding(.bottom, 6)
                    }
                }
        }
        // afspeelknop in de accentkleur van het profiel, met eigen tvOS-focus (build 58)
        .buttonStyle(PlayButtonStyle())
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
    /// Build 132: de eigen Bingr-link (`https://bingr.online/titel/?type=&id=&q=&y=`, zie TitleLink): de pagina geeft een
    /// rijke preview (cover + meta) en opent de app op deze detailpagina. Zonder TMDB-id: type + titel + jaar (de app
    /// zoekt dan op titel). Een serie deelt altijd de serie (ook vanaf een aflevering).
    private var shareTMDBID: Int? {
        if let t = d?.tmdbID { return t }
        switch target {
        case .movie(let m): return m.tmdbID ?? ContentLanguage.Facts.shared.tmdbID(m.id)
        case .series(let s): return s.tmdbID ?? ContentLanguage.Facts.shared.tmdbID(s.id)
        }
    }
    private var shareURL: URL? {
        TitleLink.shareURL(kind: isMovie ? .movie : .tv, tmdbID: shareTMDBID, title: shareTitle,
                           year: shareYear.flatMap { Int($0.prefix(4)) })
    }
    private var shareText: String {
        let name = shareYear.map { "\(shareTitle) (\($0))" } ?? shareTitle
        return L(isMovie ? "Movie tip: %@" : "Series tip: %@", name)
    }
    /// Poster als preview-afbeelding, alleen als hij al geladen is (geheugencache); anders alleen de titel.
    private var sharePoster: Image? {
        for u in [d?.poster, basePoster].compactMap({ $0 }) {
            if let cg = ImagePipeline.shared.cachedAny(u) { return Image(decorative: cg, scale: 1) }
        }
        return nil
    }

    #if !os(tvOS)
    private var shareButton: some View {
        Group {
            if let url = shareURL {
                if let img = sharePoster {
                    ShareLink(item: url, subject: Text(shareTitle), message: Text(shareText),
                              preview: SharePreview(shareTitle, image: img)) { shareIcon }
                } else {
                    ShareLink(item: url, subject: Text(shareTitle), message: Text(shareText),
                              preview: SharePreview(shareTitle)) { shareIcon }
                }
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
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up").font(.system(size: tvScaled(19), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: tvScaled(50), height: tvScaled(50))
            .background(Color.white.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.12)))
    }
    #endif

    /// Mijn lijst: plus als de titel er niet in staat, vinkje (accentkleur) als hij er wel in staat, met een korte
    /// animatie van plus naar vinkje (en terug) en een lichte tik op iPhone/iPad. Was tot nu toe een hartje.
    private var myListButton: some View {
        Button { toggleMyList() } label: {
            PlusCheckGlyph(inList: inMyList, size: tvScaled(19))
                .foregroundStyle(inMyList ? Theme.red : .white)
                .frame(width: tvScaled(50), height: tvScaled(50))
                .background(Color.white.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .plainTVButton()
        .accessibilityLabel(inMyList ? L("In My List") : L("Add to My List"))
        .accessibilityAddTraits(inMyList ? .isSelected : [])
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: tvScaled(19), weight: .semibold))
                .foregroundStyle(.white)
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
            // hoeveel van de serie je al gezien hebt (build 53)
            if let f = watchedFraction(episodes), f > 0 {
                progressLine(L("%d%% of the series watched", percent(f)), f)
            }
            HStack(spacing: 12) {
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.self) { n in Button(seasonLabel(n)) { season = n } }
                    } label: { seasonPill(chevron: true) }
                } else if !seasons.isEmpty {
                    seasonPill(chevron: false)
                }
                if hasSeasonTrailer, let t = seasonTrailers[season] {
                    Button { openTrailer(t) } label: {
                        Label(L("Trailer season %d", season), systemImage: "play.rectangle")
                            .font(.system(size: tvScaled(14), weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .plainTVButton()
                }
                Spacer()
                let list = episodes.filter { $0.season == season }
                if !list.isEmpty {
                    let all = list.allSatisfy { Playables.isWatched($0, imdb: imdb, series: seriesTarget) }
                    Button {
                        // build 154: ook de inhoudssleutels (gezien op alle servers) en daarna "serie gezien"
                        for e in list { Watched154.setEpisode(e, series: seriesTarget, imdb: imdb, !all, updateSeries: false) }
                        if let s = seriesTarget {
                            Watched154.updateSeriesFlag(s, imdb: imdb, episodes: episodes)
                            if trakt.isLoggedIn, let first = list.first {
                                let show = Playables.episode(first, of: s, imdb: imdb)
                                Task { await trakt.setWatched(show: show, imdb: imdb, episodes: list, !all) }
                            }
                        }
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
            if seasons.count > 1, let f = watchedFraction(list), f > 0 {
                progressLine(L("Season %d · %d%% watched", season, percent(f)), f)
            }
            let current = currentEpisodeID(in: list)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: tvScaled(14)) {
                        ForEach(list) { e in
                            episodeCard(e, s).id(e.id)
                            #if os(tvOS)
                                .focused($focusedEpisode, equals: e.id)
                                .prefersDefaultFocus(e.id == current, in: episodeNS)
                            #endif
                        }
                    }
                    .padding(.horizontal, Theme.edge)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    .focusScope(episodeNS)
                    #endif
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
                // meteen naar de aflevering waar je bent (volgende onbekeken of half gekeken), ook als de lijst later binnenkomt
                .task(id: "\(season)-\(list.count)-\(current ?? "")") {
                    guard let current else { return }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    #if os(tvOS)
                    proxy.scrollTo(current, anchor: .leading)
                    #else
                    proxy.scrollTo(current, anchor: .center)
                    #endif
                }
            }
            #if os(tvOS)
            .onChange(of: focusedEpisode) { old, new in
                // eerste keer de rij in: naar de huidige aflevering, niet de dichtstbijzijnde kaart
                guard !episodeFocusRedirected, old == nil, let new else { return }
                episodeFocusRedirected = true
                if let current, current != new { focusedEpisode = current }
            }
            .onChange(of: season) { _, _ in episodeFocusRedirected = false }
            #endif
        }
        .task(id: "\(season)-\(d?.tmdbID ?? -1)-\(d != nil)") {
            guard let d else { return }
            let n = season
            // trailer van dit seizoen (TMDB), tegelijk met de afleveringsinfo; geen eigen trailer → die van de serie
            let tvID = seasonTrailers[n] == nil ? (d.tmdbID ?? -1) : -1
            async let trailer = TMDB.seasonTrailer(tvID: tvID, season: n)
            let info = await DetailsService.shared.seasonInfo(d, season: n)
            if !info.isEmpty { seasonInfo.merge(info) { _, new in new } }
            if let t = await trailer { seasonTrailers[n] = t }
        }
    }

    /// Dunne voortgangsbalk met tekst ("42% van de serie bekeken").
    private func progressLine(_ text: String, _ f: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.system(size: tvScaled(13), weight: .medium)).foregroundStyle(Theme.secondary)
            Capsule().fill(Color.white.opacity(0.18)).frame(height: tvScaled(3))
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(Theme.red).frame(width: g.size.width * min(max(f, 0), 1)) }
                }
                .frame(maxWidth: tvScaled(420))
        }
        .padding(.horizontal, Theme.edge)
        .accessibilityElement(children: .combine)
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

    // MARK: kijkvoortgang (build 53)

    /// Gezien = 1, half gekeken = de voortgang, anders 0.
    private func episodeFraction(_ e: Episode) -> Double {
        if Playables.isWatched(e, imdb: imdb, series: seriesTarget) { return 1 }
        return min(max(store.progress[e.id]?.fraction ?? 0, 0), 1)
    }

    /// Deel van deze afleveringen dat je gezien hebt (nil als er geen afleveringen bekend zijn).
    private func watchedFraction(_ list: [Episode]) -> Double? {
        guard !list.isEmpty else { return nil }
        return list.reduce(0) { $0 + episodeFraction($1) } / Double(list.count)
    }

    /// Percentage zonder "0%" bij een begin of "100%" als er nog iets open staat.
    private func percent(_ f: Double) -> Int {
        let p = Int((f * 100).rounded())
        if f > 0 && p == 0 { return 1 }
        if f < 1 && p == 100 { return 99 }
        return p
    }

    private func seasonLabel(_ n: Int) -> String {
        guard let f = watchedFraction(episodes.filter { $0.season == n }), f > 0 else { return L("Season %d", n) }
        return L("Season %d · %d%% watched", n, percent(f))
    }

    /// De aflevering waar je bent in deze lijst: de half gekeken of volgende onbekeken.
    private func currentEpisodeID(in list: [Episode]) -> String? {
        guard let n = nextEpisode, list.contains(where: { $0.id == n.id }) else { return nil }
        return n.id
    }

    // MARK: trailer per seizoen (build 53)

    /// Seizoen met een eigen trailer (bij meer dan één seizoen)?
    private var hasSeasonTrailer: Bool { !isMovie && seasons.count > 1 && seasonTrailers[season] != nil }

    /// Trailer van het gekozen seizoen, anders die van de serie/film.
    private var currentTrailer: String? {
        if !isMovie, let t = seasonTrailers[season] { return t }
        return d?.trailerYouTubeID
    }

    /// Kijkwijzer als die er is, anders de classificatie van IMDb/Trakt of TMDB.
    private var certificationLabel: String? {
        if let a = ageInfo, a.country == "NL", let l = a.label { return l }
        return d?.certification ?? ageInfo?.label
    }

    private func info(_ e: Episode) -> TitleDetails.EpisodeInfo? {
        seasonInfo["\(e.season)-\(e.number)"] ?? d?.episodeInfo["\(e.season)-\(e.number)"]
    }

    private func episodeCard(_ e: Episode, _ s: Series) -> some View {
        let i = info(e)
        let watched = Playables.isWatched(e, imdb: imdb, series: seriesTarget)
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
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            // offline kijken (build 52)
            let item = Playables.episode(e, of: s, imdb: imdb)
            if DownloadManager.canDownload(item) {
                DownloadButton(item: item, seriesTitle: s.title, poster: s.poster, compact: true).padding(8)
            }
        }
        #endif
        .contextMenu {
            Button {
                Watched154.setEpisode(e, series: s, imdb: imdb, !watched)   // build 154: ook de inhoudssleutels
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
            sectionTitle(L("Actors"))   // build 97: eigen sleutel ("Cast" is voor Chromecast)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(tvScaled(76)), spacing: tvScaled(14)),
                                 GridItem(.fixed(tvScaled(76)), spacing: tvScaled(14))], spacing: tvScaled(26)) {
                    ForEach(cast) { c in
                        // tik/klik (Apple TV: focus + select) → eigen pagina van de acteur/actrice
                        if PersonService.shared.available {
                            Button { person = PersonRef(tmdbID: c.personID, name: c.name, photo: c.photo) } label: { castCell(c) }
                                .plainTVButton()
                        } else {
                            castCell(c)
                        }
                    }
                }
                .padding(.horizontal, Theme.edge)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private func castCell(_ c: TitleDetails.CastMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.elevated)
                if let p = c.photo { RemoteImage(url: p).clipShape(Circle()) }
                else { Text(initials(c.name)).font(.system(size: tvScaled(18), weight: .bold)).foregroundStyle(Theme.secondary) }
            }
            .frame(width: tvScaled(70), height: tvScaled(70))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: tvScaled(16), weight: .medium)).foregroundStyle(.white).lineLimit(1)
                if let ch = c.character, !ch.isEmpty {
                    Text(ch).font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .frame(width: tvScaled(170), alignment: .leading)
        }
        .contentShape(Rectangle())
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
                                                .foregroundStyle(Theme.onAccent, Theme.red).padding(6)
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
        DetailStickyBar(title: title, threshold: -(headerHeight - 120), scroll: scroll) { dismiss() }
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
                        if h.playlist.id == playlists.source?.id { openLocal(h.itemID) } else { openOther(h) }
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

    /// Build 59: andere-taalversies; kiezen = die versie afspelen (film, met zijn eigen hervatpunt) of openen (serie).
    private var languagesSheet: some View {
        NavigationStack {
            List {
                if let l = language?.detailText {
                    Section(L("This version")) { Label(l, systemImage: "checkmark.circle.fill") }
                }
                Section(L("Other language")) {
                    ForEach(languageVersions) { v in
                        Button {
                            showLanguages = false
                            openVersion(v)
                        } label: {
                            HStack(spacing: 12) {
                                Text(v.label).font(.system(size: tvScaled(12), weight: .bold).smallCaps())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name)
                                    Text(v.group).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: isMovie ? "play.fill" : "chevron.right").foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Other language"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { showLanguages = false } } }
        }
    }

    private func openVersion(_ v: LanguageVersion) {
        switch v.target {
        case .movie(let m):
            let imdbID = imdb
            Task { @MainActor in
                // pas afspelen als het blad weg is (anders opent de speler niet, vooral op Apple TV)
                try? await Task.sleep(nanoseconds: 350_000_000)
                ageChecked { app.play(Playables.movie(m, imdb: imdbID)) }
            }
        case .series:
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                nested = v.target
            }
        }
    }

    private func loadLanguageVersions() async {
        let key = "\(playlists.source?.id.uuidString ?? "")-\(playlists.libraryVersion)"
        languageVersions = await LanguageVersions.shared.versions(of: target, in: playlists.library, key: key)
    }

    // MARK: acties

    private var isWatchedTitle: Bool {
        if case .movie(let m) = target { return Playables.isWatched(movie: m, imdb: imdb) }
        return false
    }

    /// Build 154: de serie van deze pagina (voor de inhoudssleutels van de afleveringen)
    private var seriesTarget: Series? {
        if case .series(let s) = target { return s }
        return nil
    }

    /// Mijn lijst van dít profiel (de Trakt-watchlist volgt mee, maar bepaalt niet wat er in je lijst staat).
    /// Build 128: geopend vanaf een plek zonder eigen afhandeling (bijv. "Alles bekijken") en nog niet gevonden op zijn
    /// server: nu zoeken; gevonden → die titel openen, anders de melding (en daarna deze pagina sluiten)
    private func resolveCrossServer() async {
        guard let sid = target.sourceID, CrossServer.shared.isMissing(target) else { return }
        switch await CrossServerOpen.open(key: sid.uuidString + "|" + target.id, list: .myList) {
        case .movie(let m): nested = .movie(m)
        case .series(let x): nested = .series(x)
        case .channel: break
        case .prompt(let p): crossPrompt = p
        }
    }

    private var inMyList: Bool {
        guard let pid, let id = listID else { return false }
        return store.inMyList(pid, id)
    }

    /// Build 141: het id waaronder deze titel in Mijn lijst staat. Een titel die niet uit een bibliotheek komt (een
    /// aanbeveling, "rec-…") krijgt zijn TMDB-id ("tmdb-movie-123", zoals Binnenkort op Bingr), zodat Mijn lijst hem op
    /// elk apparaat kan tonen; tot nu toe kwam "rec-…" in de lijst en verscheen hij nergens. nil = (nog) niet bekend.
    private var listID: String? { MyListID.forTitle(id: target.id, tmdb: shareTMDBID, isShow: !isMovie) }

    /// Staat deze titel in een eigen (handmatige) collectie?
    private var inAnyCollection: Bool {
        let item = CollectionTarget.detail(target).item
        return store.activeCollections.contains { $0.kind == .manual && $0.contains(item) }
    }

    private var nextEpisode: Episode? {
        // de laatst bekeken aflevering met voortgang (niet zomaar de eerste in de lijst)
        let started = episodes.compactMap { e in store.progress[e.id].flatMap { $0.fraction > 0.02 && $0.fraction < 0.95 ? (e, $0.updated) : nil } }
        if let resumed = started.max(by: { $0.1 < $1.1 })?.0 { return resumed }
        return episodes.first { !Playables.isWatched($0, imdb: imdb, series: seriesTarget) } ?? episodes.first
    }

    /// Leeftijdsfilter van dit profiel: boven de grens alleen met pincode.
    /// Classificatie: TMDB (Kijkwijzer eerst), anders IMDb/Trakt; onbekend bij een kinderprofiel = streng.
    private func ageChecked(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, let limit = profile.effectiveAgeLimit else { action(); return }
        PlaybackTiming.begin(title, step: "age check")
        Task { @MainActor in
            // build 59: eerst de classificatie die al bekend is (de detailpagina haalt hem bij het openen al op).
            // Onbekend: een kinderprofiel wacht op TMDB (streng), andere profielen hooguit 1,5 seconde.
            var info: AgeInfo? = ageInfo ?? cachedAgeInfo
            if info == nil || !(info?.isFresh ?? false) {
                let lookup = Task { @MainActor in await currentAgeInfo() }
                if profile.strictAgeFilter {
                    info = await lookup.value ?? info
                } else {
                    let quick: AgeInfo? = await withTaskGroup(of: AgeInfo?.self) { g in
                        g.addTask { await lookup.value }
                        g.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000); return nil }
                        let first = (await g.next()) ?? nil
                        g.cancelAll()
                        return first
                    }
                    info = quick ?? info
                }
            }
            if info != nil { ageInfo = info }
            PlaybackTiming.mark("age check done")
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
                                              strict: profile.strictAgeFilter, info: info) { action(); return }
            if ParentalControl.shared.hasPIN { afterPIN = action; ageGate = true }
            else { flash(L("Not available on this profile (age limit).")) }
        }
    }

    /// Classificatie uit de cache (zonder netwerk), ook als hij oud is.
    private var cachedAgeInfo: AgeInfo? {
        switch target {
        case .movie(let m): return AgeRatingService.shared.cached(m)
        case .series(let s): return AgeRatingService.shared.cached(s)
        }
    }

    /// TMDB-classificatie van deze titel (gecachet; voor series die van de serie, niet van een film).
    private func currentAgeInfo() async -> AgeInfo? {
        switch target {
        case .movie(let m): return await AgeRatingService.shared.info(title: m.title, year: m.year, isShow: false, imdb: imdb, tmdbID: d?.tmdbID)
        case .series(let s): return await AgeRatingService.shared.info(title: s.title, year: s.year, isShow: true, imdb: imdb, tmdbID: d?.tmdbID)
        }
    }

    private func play() {
        #if !os(tvOS)
        heroTrailer.stop()
        #endif
        if store.activeProfile?.effectiveAgeLimit == nil { PlaybackTiming.begin(title) }
        ageChecked(playNow)
    }

    private func playNow() {
        switch target {
        case .movie(let m):
            // build 111: TMDB-titel (niet in deze afspeellijst): in je andere bronnen zoeken
            if DiscoverItem.isExternal(m.id) || (m.streamURL == nil && m.stalkerCmd == nil && m.imdbID == nil && imdb == nil) {
                Task { await openSources() }; return
            }
            app.play(Playables.movie(m, imdb: imdb))
        case .series(let s):
            if let n = nextEpisode { app.play(Playables.episode(n, of: s, imdb: imdb)) }
            else { Task { await openSources() } }
        }
    }

    private func toggleMyList() {
        guard let pid, let id = listID else { return }
        let on = !inMyList
        if on {
            if DiscoverItem.isExternal(id), let p = DiscoverItem.parse(id) {
                // build 141: TMDB-titel: hier meteen bekend (Mijn lijst toont hem zonder eerst op te zoeken)
                DiscoverKnown.shared.remember([DiscoverItem(tmdbID: p.tmdbID, isShow: p.isShow, title: title, originalTitle: nil,
                                                            date: shareYear.map { String($0.prefix(4)) + "-01-01" },
                                                            posterPath: TMDB.path(of: target.posterURL), backdropPath: nil,
                                                            overview: nil, kind: .streaming)])
            } else {
                // build 141: ook van een andere server meteen in de lijst, met de meta voor andere apparaten
                CrossServer.shared.noteListed(target, server: pid)
            }
        }
        store.setMyList(pid, id, on)
        PlusCheckFeedback.toggled()
        if let imdb, store.isMainActive { Task { await trakt.setWatchlist(imdb: imdb, isShow: target.isSeries, on) } }
        flash(on ? L("Added to My List") : L("Removed from My List"))
    }

    private func toggleWatchedMovie() {
        guard case .movie(let m) = target else { return }
        let w = isWatchedTitle
        Watched154.setMovie(m, imdb: imdb, !w)   // build 154: ook de inhoudssleutels
        Task { await trakt.setWatched(Playables.movie(m, imdb: imdb), !w) }
    }

    private func openTrailer(_ t: String) {
        #if !os(tvOS)
        heroTrailer.stop()
        trailerID = t
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

    /// Build 129: dezelfde titel op een andere server openen via die server, zonder van server te wisselen. Alleen als
    /// hij daar niet meer in de catalogus staat: zoals voorheen naar die server.
    private func openOther(_ h: PlaylistService.OtherHit) {
        Task { @MainActor in
            guard let f = await playlists.foreignItem(h) else { dismiss(); app.open(h.playlist, thenShow: h.itemID); return }
            if let m = f.movie { nested = .movie(m) } else if let s = f.series { nested = .series(s) }
        }
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
        // build 59: bij een profiel met leeftijdsgrens de classificatie meteen (tegelijk met de details) ophalen,
        // zodat Afspelen er niet op hoeft te wachten
        if store.activeProfile?.effectiveAgeLimit != nil, ageInfo == nil {
            Task { @MainActor in if let info = await currentAgeInfo(), ageInfo == nil { ageInfo = info } }
        }
        var epsTask: Task<[Episode], Never>?
        if case .series(let s) = target {
            let pl = playlists
            epsTask = Task { await pl.episodes(for: s) }
        }
        d = await DetailsService.shared.details(for: target, playlists: playlists, knownIMDb: imdb)
        episodes = await epsTask?.value ?? []
        // al begonnen met kijken: het seizoen van de volgende aflevering; anders het nieuwste seizoen
        let started = episodes.contains { e in
            (store.progress[e.id]?.fraction ?? 0) > 0.02 || Playables.isWatched(e, imdb: imdb, series: seriesTarget)
        }
        if started, let n = nextEpisode { season = n.season } else if let newest = seasons.last { season = newest }
        loading = false
        // classificatie voor de detailregel (Kijkwijzer) en het leeftijdsfilter
        if let info = await currentAgeInfo() { ageInfo = info }
    }
}

private struct DetailOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Kopafbeelding met parallax: leest als enige de scrollpositie.
private struct ParallaxImage: View {
    let url: URL?
    let height: CGFloat
    let scroll: ScrollTracker
    var body: some View {
        let y = scroll.y
        RemoteImage(url: url, placeholder: "", maxPixel: 1600)
            .frame(height: height + max(y, 0))
            .frame(maxWidth: .infinity)
            .clipped()
            .offset(y: y > 0 ? -y / 2 : 0)
    }
}

#if !os(tvOS)
/// Balk met titel die verschijnt als je voorbij de kop scrolt.
private struct DetailStickyBar: View {
    let title: String
    let threshold: CGFloat
    let scroll: ScrollTracker
    let onClose: () -> Void
    var body: some View {
        let show = scroll.y < threshold
        HStack {
            Spacer()
            Text(title).font(.headline).lineLimit(1).opacity(show ? 1 : 0)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if show {
                Button(action: onClose) {
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
}
#endif
