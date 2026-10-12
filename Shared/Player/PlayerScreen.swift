import SwiftUI

struct PlayerScreen: View {
    let item: PlayableItem

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoSubtitles") private var autoSubtitles = false

    @StateObject private var player: PlayerController
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: Panel?
    @State private var scrubbing: Double?
    @State private var toast: String?
    @State private var stremioChoices: [StremioClient.Stream] = []
    /// Volgende aflevering (series): knop aan het eind en automatisch verder kijken
    @State private var nextUp: PlayableItem?
    #if os(tvOS)
    /// Apple TV: wat de focus heeft — de onzichtbare "vanger" (bediening verborgen) of een knop in de balk
    enum TVField: Hashable { case catcher, bar(String) }
    @FocusState private var tvFocus: TVField?
    #endif
    #if !os(tvOS)
    @StateObject private var cast = CastManager.shared
    #endif
    #if os(iOS)
    @ObservedObject private var external = ExternalDisplay.shared
    #endif
    /// Zappen: de zender waar de balk nu naar wijst (met zapvertraging start de stream pas later)
    @State private var zapTarget: Channel?
    @State private var zapTask: Task<Void, Never>?
    /// Zenderbalk in beeld (zappen)
    @State private var banner: Channel?
    @State private var bannerPending = false
    @State private var bannerHide: Task<Void, Never>?
    /// Tegelijk kijken: limiet bereikt (403 `stream_limit`) → "Too many people are watching"
    @State private var streamLimit: AccountService.StreamLimit?
    /// Build 52: andere bronnen voor deze zender/titel, en welke al geprobeerd zijn (automatisch overschakelen)
    @State private var alternatives: [AlternativeSource] = []
    @State private var triedAlternatives: Set<String> = []
    @State private var loadingAlternatives = false
    /// Build 52: kaart "Volgende aflevering" weggeklikt (aftiteling verder kijken)
    @State private var creditsDismissed = false
    /// Voor welke zender/titel `alternatives` gezocht zijn
    @State private var altFor: String?
    @ObservedObject private var markers = IntroMarkers.shared

    enum Panel: String, Identifiable { case audioSubs, opensubs, options, cast, sources, rate, intro, alternatives; var id: String { rawValue } }

    /// Teruggekomen uit beeld-in-beeld: de bestaande speler overnemen.
    private let reused: Bool

    init(item: PlayableItem, existing: PlayerController? = nil) {
        self.item = item
        reused = existing != nil
        _player = StateObject(wrappedValue: existing ?? PlayerController(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EngineView(controller: player, external: true).ignoresSafeArea().allowsHitTesting(false)
            #if os(iOS)
            if external.isConnected && PlayerSettings.externalDisplay {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 44))
                    Text(L("Playing on the external display")).font(.headline)
                }
                .foregroundStyle(Theme.secondary)
                .allowsHitTesting(false)
            }
            #endif
            #if !os(tvOS)
            tapLayer
            #endif

            if let s = player.subtitleText {
                Text(s)
                    .font(.system(size: tvScaled(20) * SubtitleSize.current.overlayFactor, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, showControls ? tvScaled(120) : tvScaled(40))
                    .allowsHitTesting(false)
            }

            if (player.isBuffering || player.reconnecting) && player.errorText == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(tvScaled(1.6))
                    if player.reconnecting { Text(L("Reconnecting…")).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                }
            }
            if let e = player.errorText {
                errorOverlay(e)
            }
            #if !os(tvOS)
            if cast.connected != nil {
                VStack(spacing: 12) {
                    Image(systemName: "tv.and.mediabox").font(.system(size: 48))
                    Text(cast.status).font(.headline)
                    if let note = cast.subtitleNote {
                        Text(note).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 20) {
                        NetflixButton(title: cast.isPlaying ? L("Pause") : L("Play"), icon: cast.isPlaying ? "pause.fill" : "play.fill") { cast.togglePause() }
                        NetflixButton(title: L("Stop casting"), icon: "xmark", kind: .secondary) { cast.disconnect(); player.resume() }
                    }
                }
                .padding(30).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }
            #endif

            #if os(tvOS)
            if !showControls && streamLimit == nil && player.errorText == nil { tvCatcher }
            #endif
            if showControls && streamLimit == nil { controls.transition(.opacity) }

            if showSkipIntro, let end = marker?.introEnd {
                skipIntroButton(end)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, tvScaled(40))
                    .padding(.bottom, showControls ? tvScaled(130) : tvScaled(50))
                    .transition(.opacity)
            }

            if let n = nextUp, let left = nextCountdown {
                NextEpisodeCard(next: n, secondsLeft: left, autoplay: marker?.creditsStart != nil,
                                onPlay: { playNext(n) }, onDismiss: { creditsDismissed = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, tvScaled(40))
                    .padding(.bottom, showControls ? tvScaled(130) : tvScaled(50))
                    .transition(.opacity)
            }

            if let banner {
                ZapBanner(channel: banner, now: playlists.library.nowPlaying(banner), pending: bannerPending)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, Theme.edge)
                    .padding(.bottom, showControls ? tvScaled(110) : tvScaled(30))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if let toast {
                Text(toast).font(.system(size: tvScaled(14), weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, tvScaled(40))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let l = streamLimit {
                StreamLimitView(limit: l, onRetry: {
                    streamLimit = nil
                    Task { await start(player.item) }
                }, onClose: { close() })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.2), value: banner?.id)
        #if !os(tvOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #if os(macOS)
        // Mac-toetsenbord: spatie = pauze, ←/→ = 10 s, ↑/↓ = zappen, Esc = sluiten
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { player.togglePlay(); poke(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(by: -10); flash("−10 s"); return .handled }
        .onKeyPress(.rightArrow) { player.seek(by: 10); flash("+10 s"); return .handled }
        .onKeyPress(.upArrow) { zap(-1); return .handled }
        .onKeyPress(.downArrow) { zap(1); return .handled }
        .onExitCommand { if panel != nil { panel = nil } else { close() } }
        #endif
        #else
        .onPlayPauseCommand { player.togglePlay(); poke() }
        .onChange(of: showControls) { _, shown in
            // bediening tevoorschijn → focus op afspelen/pauze; weg → focus terug naar de vanger
            tvFocus = shown ? .bar("play") : .catcher
        }
        .onChange(of: tvFocus) { _, f in if case .some(.bar(_)) = f { poke() } }   // rondkijken in de balk houdt hem zichtbaar
        .onAppear { tvFocus = showControls ? .bar("play") : .catcher }
        // intro overslaan: de knop krijgt de focus zolang de bediening verborgen is (zoals Netflix)
        .onChange(of: showSkipIntro) { _, v in
            if v && !showControls { tvFocus = .bar("skipintro") }
            else if !v && tvFocus == .bar("skipintro") { tvFocus = showControls ? .bar("play") : .catcher }
        }
        .onExitCommand {
            if streamLimit != nil { close() }
            else if panel != nil { panel = nil } else if showControls { showControls = false } else { close() }
        }
        #endif
        .sheet(item: $panel) { p in
            switch p {
            case .audioSubs: TracksPanel(player: player)
            case .opensubs: OpenSubtitlesPanel(player: player)
            case .options: OptionsPanel(player: player)
            case .rate:
                RatingPanel(item: player.item) { close() }
            case .sources: StremioSourcesPanel(streams: stremioChoices) { s in
                    panel = nil
                    player.start(url: s.url)
                }
            case .intro:
                if let key = markerKey {
                    IntroMarkerPanel(player: player, key: key)
                }
            case .alternatives:
                AlternativesPanel(items: alternatives, loading: loadingAlternatives,
                                  currentURL: player.url) { alt in
                    panel = nil
                    Task { await switchTo(alt, automatic: false) }
                }
            case .cast:
                #if !os(tvOS)
                if let u = player.url {
                    CastPicker(item: player.item, url: u, position: player.currentTime,
                               subtitles: player.selectedSubtitle, subtitleDelay: player.subtitleDelay) { player.pause() }
                }
                #else
                EmptyView()
                #endif
            }
        }
        .task {
            if reused { bind(player.item); attachStream(); poke() } else { await start(item) }
        }
        // aftiteling gemarkeerd: na het aftellen automatisch de volgende aflevering
        .onChange(of: nextCountdown) { _, v in
            if v == 0, marker?.creditsStart != nil, let n = nextUp { playNext(n) }
        }
        .onChange(of: player.notice) { _, n in
            if let n { flash(n); player.notice = nil }
        }
        .onDisappear {
            zapTask?.cancel()
            if !player.inPiP {
                player.dismissed = true; player.stop()
                StreamSession.shared.stop(owner: player)
            }
        }
    }

    // MARK: bediening

    #if !os(tvOS)
    /// Tik = bediening tonen/verbergen; dubbeltik links/rechts = 10 s terug/vooruit.
    private var tapLayer: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !player.isLive || player.canTimeshift { player.seek(by: -10); flash("−10 s"); poke() } }
                    .onTapGesture { toggleControls() }
                    .frame(width: geo.size.width * 0.35)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !player.isLive || player.canTimeshift { player.seek(by: 10); flash("+10 s"); poke() } }
                    .onTapGesture { toggleControls() }
                    .frame(width: geo.size.width * 0.35)
            }
        }
        .ignoresSafeArea()
        // live: omhoog/omlaag vegen = volgende/vorige zender in de groep
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                let dy = v.translation.height, dx = v.translation.width
                guard player.isLive, abs(dy) > 60, abs(dy) > abs(dx) * 1.5 else { return }
                zap(dy < 0 ? 1 : -1)
            }
        )
    }
    #endif

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(alignment: .top, spacing: 14) {
                    #if !os(tvOS)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).padding(10) }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.item.title).font(.system(size: tvScaled(17), weight: .bold))
                        if let s = player.item.subtitle { Text(s).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                    }
                    Spacer()
                    #if !os(tvOS)
                    if PlayerController.pipSupported {
                        Button { player.startPiP() } label: { Image(systemName: "pip.enter").font(.system(size: 20)) }
                            .accessibilityLabel(L("Picture in Picture"))
                    }
                    AirPlayButton { player.switchToApple() }.frame(width: 34, height: 34)
                    Button { panel = .cast } label: { Image(systemName: "tv.and.mediabox").font(.system(size: 20)) }
                    #endif
                    if player.isLive {
                        Button { player.goLive(); poke() } label: {
                            Label(player.behindLive > 5 ? "−\(PlayerController.format(player.behindLive))" : L("LIVE"),
                                  systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: tvScaled(12), weight: .heavy))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(player.behindLive > 5 ? Theme.elevated : Theme.red, in: Capsule())
                        }
                        .plainTVButton()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.edge).padding(.top, tvScaled(12))

                Spacer()

                #if !os(tvOS)
                HStack(spacing: 56) {
                    if player.isLive && !player.canTimeshift { roundButton("chevron.up", size: 24) { zap(-1) } }
                    else { roundButton("gobackward.10", size: 30) { player.seek(by: -10); poke() } }
                    roundButton(player.isPlaying ? "pause.fill" : "play.fill", size: 44) { player.togglePlay(); poke() }
                    if player.isLive && !player.canTimeshift { roundButton("chevron.down", size: 24) { zap(1) } }
                    else { roundButton("goforward.10", size: 30) { player.seek(by: 10); poke() } }
                }
                Spacer()
                #endif

                VStack(spacing: tvScaled(10)) {
                    if !player.isLive { timeline }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tvScaled(26)) {
                            #if os(tvOS)
                            barButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? L("Pause") : L("Play"), id: "play") { player.togglePlay() }
                            if !player.isLive || player.canTimeshift {
                                barButton("gobackward.10", "−10") { player.seek(by: -10) }
                                barButton("goforward.30", "+30") { player.seek(by: 30) }
                            }
                            if player.isLive {
                                barButton("chevron.up", L("Previous channel")) { zap(-1) }
                                barButton("chevron.down", L("Next channel")) { zap(1) }
                            }
                            #endif
                            barButton("speaker.wave.2.bubble", L("Audio & subtitles")) { panel = .audioSubs }
                            if !player.isLive { barButton("captions.bubble", "OpenSubtitles") { panel = .opensubs } }
                            if !stremioChoices.isEmpty { barButton("list.bullet", L("Sources")) { panel = .sources } }
                            if player.item.type == .episode && markerKey != nil {
                                barButton("forward.frame", L("Mark intro here")) { panel = .intro }
                            }
                            if player.isLive {
                                barButton("arrow.triangle.branch", L("Other source")) { openAlternatives() }
                            }
                            if player.isLive && !playlists.library.channels.isEmpty {
                                barButton("square.grid.2x2", "Multiview") { openMultiview() }
                            }
                            #if os(tvOS)
                            if PlayerController.pipSupported {
                                barButton("pip.enter", L("Picture in Picture")) { player.startPiP() }
                            }
                            #endif
                            barButton("slider.horizontal.3", L("Options")) { panel = .options }
                            if let s = player.sleepAt {
                                Label(s.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                            }
                        }
                        #if os(tvOS)
                        .padding(.vertical, 20)
                        #endif
                    }
                }
                .padding(.horizontal, Theme.edge).padding(.bottom, tvScaled(18))
            }
        }
    }

    private var timeline: some View {
        HStack(spacing: tvScaled(12)) {
            Text(PlayerController.format(player.duration * (scrubbing ?? player.position)))
                .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary)
            #if !os(tvOS)
            Slider(value: Binding(get: { scrubbing ?? player.position },
                                  set: { scrubbing = $0; poke() }),
                   in: 0...1, onEditingChanged: { editing in
                if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
            })
            .tint(Theme.red)
            #else
            ProgressBar(value: player.position).frame(height: 8).clipShape(Capsule())
            #endif
            Text("-" + PlayerController.format(player.duration * (1 - (scrubbing ?? player.position))))
                .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary)
        }
    }

    private func roundButton(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(.white).frame(width: 64, height: 64) }
    }

    @ViewBuilder
    private func barButton(_ icon: String, _ label: String, id: String? = nil, _ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button { action(); poke() } label: {
            Label(label, systemImage: icon).font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(.white)
        .focused($tvFocus, equals: .bar(id ?? label))
        #else
        Button { action(); poke() } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 20)).padding(6)
        }
        .foregroundStyle(.white)
        #endif
    }

    #if os(tvOS)
    /// Bediening verborgen: een onzichtbare knop over het hele beeld.
    /// Klik = bediening tonen · ←/→ = 10 s spoelen · ↑/↓ = zappen (live) of bediening tonen.
    private var tvCatcher: some View {
        Button { poke() } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(InvisibleTVButtonStyle())
            .focused($tvFocus, equals: .catcher)
            .onMoveCommand { dir in
                let canSeek = !player.isLive || player.canTimeshift
                switch dir {
                case .left: if canSeek { player.seek(by: -10); flash("−10 s") } else { poke() }
                case .right: if canSeek { player.seek(by: 10); flash("+10 s") } else { poke() }
                case .up: if player.isLive { zap(-1) } else { poke() }
                case .down: if player.isLive { zap(1) } else { poke() }
                default: break
                }
            }
            .ignoresSafeArea()
    }
    #endif

    // MARK: logica

    /// Callbacks die naar dit scherm verwijzen (ook na terugkeer uit beeld-in-beeld opnieuw zetten).
    private func bind(_ it: PlayableItem) {
        player.onEnterPiP = { dismiss() }
        // build 52: live → automatisch naar een back-upbron; anders de foutmelding met keuzes
        player.onGiveUp = { autoFailover() }
        player.onFinished = {
            if let n = nextUp { playNext(n); return }   // zoals Netflix: gewoon door naar de volgende aflevering
            if TraktSync.askRating, TraktSync.shared.isLoggedIn, it.imdbID != nil, it.type != .live {
                panel = .rate
            } else {
                close()
            }
        }
    }

    private func start(_ it: PlayableItem) async {
        player.prepareNew()
        player.item = it
        streamLimit = nil
        creditsDismissed = false
        // andere bronnen: bij live alvast zoeken (voor automatisch overschakelen), bij films pas na een fout
        let altKey = it.channelID ?? it.id
        if altFor != altKey {
            altFor = altKey
            alternatives = []; triedAlternatives = []
            if it.type == .live { Task { await loadAlternatives(for: it) } }
        }
        bind(it)
        registerStream(it)
        if it.type == .live, let cid = it.channelID {
            let pl = playlists
            player.catchupProvider = { from, to in pl.catchupURL(channelID: cid, start: from, end: to) }
        } else {
            player.catchupProvider = nil
        }
        if it.stremio != nil {
            let found = await playlists.stremioStreams(it)
            // intussen gesloten of al naar een andere zender gezapt → niet meer starten
            guard !player.dismissed, player.item.id == it.id, streamLimit == nil else { return }
            stremioChoices = found
            guard let first = stremioChoices.first else {
                player.fail(L("No playable streams found for this title.")); return
            }
            player.start(url: first.url)
        } else {
            let resolved = await playlists.resolve(it)
            guard !player.dismissed, player.item.id == it.id, streamLimit == nil else { return }
            guard let url = resolved else { player.fail(L("No stream address available.")); return }
            player.liveURL = url
            player.start(url: url)
        }
        poke()
        if autoSubtitles, it.type != .live { Task { await autoLoadSubtitles(it) } }
        await findNext(it)
    }

    /// Zoekt de aflevering na deze (ook over seizoenen heen).
    private func findNext(_ it: PlayableItem) async {
        nextUp = nil
        guard it.type == .episode else { return }
        #if os(iOS)
        // gedownloade aflevering (offline): de volgende gedownloade aflevering van dezelfde serie
        if it.url?.isFileURL == true {
            nextUp = DownloadManager.shared.nextEpisode(after: it)
            return
        }
        #endif
        let lib = playlists.library
        guard let s = lib.series.first(where: { $0.episodes.contains { $0.id == it.id } })
                ?? lib.series.first(where: { $0.title == it.title }) else { return }
        let eps = await playlists.episodes(for: s).sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard player.item.id == it.id, let i = eps.firstIndex(where: { $0.id == it.id }), i + 1 < eps.count else { return }
        nextUp = Playables.episode(eps[i + 1], of: s, imdb: it.imdbID)
    }

    private func playNext(_ n: PlayableItem) {
        nextUp = nil
        flash(n.subtitle ?? n.title)
        Task { player.stop(keepDisplay: true); await start(n) }
    }

    /// Standaard ondertitels: eerst een spoor in de stream in je standaardtaal, anders de beste van OpenSubtitles.
    private func autoLoadSubtitles(_ it: PlayableItem) async {
        let lang = subs.defaultLanguage
        guard !lang.isEmpty else { return }
        for _ in 0..<40 where !player.isPlaying { try? await Task.sleep(nanoseconds: 500_000_000) }
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // sporen laten binnenkomen
        guard player.item.id == it.id, !player.hasExternalSubtitle else { return }
        if let t = player.subtitleTracks.first(where: { TrackPreferences.matches($0, code: lang) }) {
            player.selectSubtitle(t)
            flash(L("Subtitles: %@", TrackPreferences.label(lang)))
            return
        }
        guard subs.isLoggedIn else { return }
        do {
            let found = try await subs.search(imdbID: it.imdbID, title: it.title, year: it.subtitle.flatMap { Int($0) },
                                              season: it.season, episode: it.episode, languages: [lang])
            guard let best = found.first, player.item.id == it.id else { return }
            let file = try await subs.download(best)
            player.addSubtitle(file: file, name: "\(TrackPreferences.flag(best.language)) \(best.release)", language: best.language)
            flash(L("Subtitles: %@", "\(TrackPreferences.label(lang)) · OpenSubtitles"))
        } catch {}
    }

    /// Volgende/vorige zender in de huidige groep. Met een zapvertraging toont snel zappen alleen de zenderbalk;
    /// de stream start pas als je even stopt.
    private func zap(_ step: Int) {
        let list = app.liveZapList
        let current = zapTarget?.id ?? player.item.channelID ?? player.item.id
        guard player.isLive, !list.isEmpty, let i = list.firstIndex(where: { $0.id == current }) else { return }
        let next = list[(i + step + list.count) % list.count]
        zapTarget = next
        let delay = PlayerSettings.zapDelay
        showBanner(next, pending: delay > 0)
        zapTask?.cancel()
        zapTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await tune(next)
        }
    }

    private func tune(_ next: Channel) async {
        if let pid = playlists.source?.id { CloudStore.shared.pushRecentChannel(pid, next.id) }
        let it = Playables.channel(next, now: playlists.library.nowPlaying(next))
        player.stop(keepDisplay: true)
        zapTarget = nil
        showBanner(next, pending: false)
        await start(it)
    }

    private func showBanner(_ c: Channel, pending: Bool) {
        banner = c
        bannerPending = pending
        bannerHide?.cancel()
        bannerHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, zapTarget == nil else { return }
            banner = nil
        }
    }

    private func openMultiview() {
        let current = playlists.library.channels.first { $0.id == player.item.channelID }
        let zap = app.liveZapList
        close()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            app.openMultiview(start: current.map { [$0] } ?? [], candidates: zap)
        }
    }

    private func close() { player.stop(); StreamSession.shared.stop(owner: player); dismiss() }

    // MARK: tegelijk kijken (build 51)

    /// Elke nieuwe stream (ook zappen en de volgende aflevering) aanmelden bij de Bingr-account.
    /// Afspelen wacht daar niet op; bij 403 `stream_limit` stopt de speler alsnog.
    private func registerStream(_ it: PlayableItem) {
        attachStream()
        let p = player
        Task { @MainActor in
            let r = await StreamSession.shared.start(item: it, owner: p)
            guard case .limit(let l) = r, !p.dismissed, p.item.id == it.id else { return }
            hitLimit(l)
        }
    }

    /// Callbacks van de stream-sessie naar deze speler (ook na terugkeer uit beeld-in-beeld).
    private func attachStream() {
        let p = player, pl = playlists
        let session = StreamSession.shared
        session.keepAliveInBackground = {
            #if os(tvOS)
            return p.inPiP || p.isExternalPlayback
            #else
            return p.inPiP || p.isExternalPlayback || CastManager.shared.connected != nil
            #endif
        }
        session.titleProvider = {
            var it = p.item
            if it.type == .live, let cid = it.channelID, let c = pl.library.channels.first(where: { $0.id == cid }),
               let now = pl.library.nowPlaying(c) {
                it.subtitle = now.title
            }
            return StreamSession.info(for: it).title
        }
        session.onLimit = { l in hitLimit(l) }
    }

    private func hitLimit(_ l: AccountService.StreamLimit) {
        zapTask?.cancel()
        zapTarget = nil
        nextUp = nil
        player.stop()
        panel = nil
        showControls = false
        streamLimit = l
    }


    // MARK: intro en aftiteling (build 52)

    /// Sleutel van de serie (server + serie) voor de intro-markeringen
    private var markerKey: String? {
        guard player.item.type == .episode else { return nil }
        return IntroMarkers.key(source: player.item.sourceID ?? playlists.source?.id, series: player.item.seriesID)
    }
    private var marker: IntroMarker? { markers.marker(markerKey) }

    private var showSkipIntro: Bool {
        guard let m = marker, player.errorText == nil, !player.isLive, player.duration > 0 else { return false }
        return m.inIntro(player.currentTime)
    }

    /// Seconden tot de volgende aflevering start (nil = kaart niet tonen). Met een gemarkeerde aftiteling
    /// 10 seconden aftellen vanaf het begin ervan; anders (zoals eerder) de laatste 45 seconden tot het einde.
    private var nextCountdown: Int? {
        guard nextUp != nil, player.errorText == nil, !creditsDismissed, player.duration > 120 else { return nil }
        if let c = marker?.creditsStart, c > 0, c < player.duration {
            guard player.currentTime >= c else { return nil }
            return max(0, Int((10 - (player.currentTime - c)).rounded(.up)))
        }
        let left = player.duration - player.currentTime
        guard left < 45 else { return nil }
        return max(0, Int(left.rounded(.up)))
    }

    private func skipIntroButton(_ end: Double) -> some View {
        Button {
            player.seek(toSeconds: end)
            flash(L("Intro skipped"))
        } label: {
            Label(L("Skip intro"), systemImage: "forward.fill")
                .font(.system(size: tvScaled(16), weight: .bold))
                .padding(.horizontal, tvScaled(20)).padding(.vertical, tvScaled(12))
                .foregroundStyle(.black)
                .background(.white, in: RoundedRectangle(cornerRadius: tvScaled(8)))
        }
        #if os(tvOS)
        .buttonStyle(TVLiftStyle(scale: 1.08))
        .focused($tvFocus, equals: .bar("skipintro"))
        #else
        .plainTVButton()
        #endif
    }

    // MARK: foutherstel en andere bronnen (build 52)

    private func errorOverlay(_ e: String) -> some View {
        VStack(spacing: tvScaled(14)) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: tvScaled(36))).foregroundStyle(Theme.alert)
            Text(e).font(.system(size: tvScaled(16))).multilineTextAlignment(.center)
            HStack(spacing: tvScaled(12)) {
                NetflixButton(title: L("Try again"), icon: "arrow.clockwise") { retry() }
                if player.item.type != .live || player.item.channelID != nil {
                    NetflixButton(title: L("Other source"), icon: "arrow.triangle.branch", kind: .secondary) { openAlternatives() }
                }
                if canSwitchEngine {
                    NetflixButton(title: L("Other player"), icon: "arrow.left.arrow.right", kind: .secondary) {
                        player.switchEngine()
                        flash(player.usingApple ? L("Now playing with: Apple") : L("Now playing with: VLC"))
                    }
                }
            }
            #if !os(tvOS)
            Button(L("Close")) { close() }.foregroundStyle(Theme.secondary).padding(.top, 4)
            #endif
        }
        .padding(tvScaled(24))
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: tvScaled(16)))
        .padding(Theme.edge)
    }

    /// Andere speler kan alleen bij http(s) en lokale bestanden (geen HLS-pakket, geen smb://)
    private var canSwitchEngine: Bool {
        guard let u = player.url, ["http", "https", "file"].contains(u.scheme?.lowercased() ?? "") else { return false }
        return u.pathExtension.lowercased() != "movpkg"
    }

    /// Opnieuw, bij films en series op dezelfde positie.
    private func retry() {
        var it = player.item
        if it.type != .live, player.lastGoodPosition > 0.01 { it.resumeAt = player.lastGoodPosition }
        Task { await start(it) }
    }

    /// Live: de zender is weggevallen (ook na een nieuwe poging) → zelf naar de volgende back-upbron.
    private func autoFailover() -> Bool {
        guard player.isLive, let alt = alternatives.first(where: { !triedAlternatives.contains($0.id) && $0.url != player.url }) else {
            return false
        }
        Task { await switchTo(alt, automatic: true) }
        return true
    }

    private func loadAlternatives(for it: PlayableItem) async {
        let key = it.channelID ?? it.id
        loadingAlternatives = true
        defer { if altFor == key { loadingAlternatives = false } }
        let found: [AlternativeSource]
        if it.type == .live, let cid = it.channelID {
            found = await AlternativeSources.liveMatches(for: cid, playlists: playlists)
        } else {
            found = await AlternativeSources.vodMatches(for: it, playlists: playlists)
        }
        guard altFor == key else { return }
        alternatives = found
    }

    /// "Andere bron": de lijst met treffers (bij films en series eerst zoeken).
    private func openAlternatives() {
        panel = .alternatives
        if alternatives.isEmpty && !loadingAlternatives {
            let it = player.item
            Task { await loadAlternatives(for: it) }
        }
    }

    private func switchTo(_ alt: AlternativeSource, automatic: Bool) async {
        triedAlternatives.insert(alt.id)
        var url = alt.url
        if alt.isCurrentSource, let cmd = alt.stalkerCmd {
            var tmp = player.item
            tmp.url = alt.url; tmp.stalkerCmd = cmd
            url = await playlists.resolve(tmp)
        }
        guard !player.dismissed else { return }
        guard let url else {
            if automatic, autoFailover() { return }
            player.fail(L("This stream can't be played right now."))
            return
        }
        var it = player.item
        if it.type == .live {
            // zappen blijft werken vanaf de zender in de eigen lijst
            if alt.isCurrentSource { it.channelID = alt.itemID }
        } else if player.lastGoodPosition > 0.01 {
            it.resumeAt = player.lastGoodPosition
        }
        it.url = url
        it.stalkerCmd = nil
        player.item = it
        player.liveURL = url
        player.resetRecovery()
        player.start(url: url)
        let label = alt.isCurrentSource ? alt.name : alt.source.name
        flash(automatic ? L("Switched to %@", label) : label)
    }

    private func toggleControls() { showControls.toggle(); if showControls { poke() } }

    private func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled && panel == nil && player.isPlaying { showControls = false }
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { if toast == text { toast = nil } } }
    }
}

/// Zenderbalk bij het zappen: logo, nummer, naam en wat er nu op is.
private struct ZapBanner: View {
    let channel: Channel
    let now: EPGProgram?
    let pending: Bool

    var body: some View {
        HStack(spacing: tvScaled(14)) {
            RemoteImage(url: channel.logo, contentMode: .fit, placeholder: String(channel.name.prefix(3)))
                .frame(width: tvScaled(72), height: tvScaled(44))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let n = channel.number {
                        Text("\(n)").font(.system(size: tvScaled(15), weight: .heavy).monospacedDigit()).foregroundStyle(Theme.red)
                    }
                    Text(channel.name).font(.system(size: tvScaled(16), weight: .bold)).lineLimit(1)
                    if pending { ProgressView().tint(.white).scaleEffect(0.7) }
                }
                if let now {
                    Text("\(now.start.formatted(date: .omitted, time: .shortened))–\(now.end.formatted(date: .omitted, time: .shortened))  \(now.title)")
                        .font(.system(size: tvScaled(12))).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    ProgressBar(value: now.progress).frame(width: tvScaled(220), height: 3).clipShape(Capsule())
                } else {
                    Text(channel.group).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, tvScaled(16)).padding(.vertical, tvScaled(10))
        .frame(maxWidth: tvScaled(560), alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(.white.opacity(0.12)))
    }
}

/// Stremio: kies een andere bron als de eerste niet werkt.
struct StremioSourcesPanel: View {
    let streams: [StremioClient.Stream]
    let onPick: (StremioClient.Stream) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(streams) { s in
                Button { onPick(s) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).lineLimit(3)
                        Text(s.addon).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .navigationTitle(L("Sources"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { dismiss() } } }
        }
    }
}

/// Na afloop: waardering (1–10) naar Trakt.
struct RatingPanel: View {
    let item: PlayableItem
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rating = 0

    var body: some View {
        VStack(spacing: tvScaled(18)) {
            Text(L("What did you think?")).font(.system(size: tvScaled(22), weight: .bold))
            Text(item.title + (item.subtitle.map { " · \($0)" } ?? "")).foregroundStyle(Theme.secondary).lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: tvScaled(6)) {
                ForEach(1...10, id: \.self) { n in
                    Button { rating = n } label: {
                        Image(systemName: n <= rating ? "heart.fill" : "heart")
                            .font(.system(size: tvScaled(24)))
                            .foregroundStyle(n <= rating ? Theme.red : Theme.secondary)
                    }
                    .plainTVButton()
                }
            }
            if rating > 0 { Text("\(rating)/10").font(.headline) }
            HStack(spacing: tvScaled(14)) {
                NetflixButton(title: L("Skip"), icon: "xmark", kind: .secondary) { dismiss(); onDone() }
                NetflixButton(title: L("Rate on Trakt"), icon: "checkmark", kind: .accent) {
                    let r = rating, it = item
                    Task { await TraktSync.shared.rate(it, r) }
                    dismiss(); onDone()
                }
                .disabled(rating == 0)
            }
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #if !os(tvOS)
        .presentationDetents([.medium])
        #endif
    }
}

#if os(tvOS)
/// Knop zonder zichtbaar focus-effect (voor de onzichtbare vanger in de speler).
struct InvisibleTVButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif
