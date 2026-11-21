import SwiftUI

struct PlayerScreen: View {
    let item: PlayableItem

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss

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
    /// Build 169: voorbeeldpositie op de tijdbalk. Bevestigen met Select of Play/Pauze, annuleren met Terug.
    /// Build 170: de scrub-status (voorbeeldpositie, uitrollen, klikstappen, meelopende seeks) in een eigen object.
    /// Bewust `@State` en niet `@StateObject`: dit scherm volgt hem niet, alleen de tijdbalk (`TVTimelineBarContent`),
    /// zodat een swipe niet elke frame het hele spelerscherm opnieuw tekent.
    @State private var scrub = TVScrubModel()
    /// Zonder bevestigen vervalt de voorbeeldpositie 5 s nadat de focus van de balk is (build 169).
    @State private var tvPreviewExpire: Task<Void, Never>?
    /// Swipen met verborgen bediening: de bediening komt met de focus op de tijdbalk
    @State private var tvFocusTimelineOnShow = false
    /// Build 176: ±10 en ←/→ spoelen direct (snel achter elkaar telt op); ±10-knoppen van de Remote-app via de systeemopdrachten
    @State private var skipChain = Skip176.Chain()
    @State private var remoteSkip = RemoteSkip176()
    /// Build 178: laatste afspeel/pauze-druk (systeemopdracht en `.onPlayPauseCommand` samen tellen één keer)
    @State private var tvLastPlayPause = Date.distantPast
    #endif
    #if !os(tvOS)
    @StateObject private var cast = CastManager.shared
    #endif
    #if os(macOS)
    /// Mac: toetsenbordfocus voor de sneltoetsen van de speler (build 60)
    @FocusState private var macKeys: Bool
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
    /// Build 179: tijden uit IntroDB voor de aflevering die speelt
    @State private var introSegs: Build179.Segments?
    /// Build 59: dezelfde film/serie in andere talen (om naar te wisselen vanuit Audio & ondertitels)
    @State private var languageVersions: [LanguageVersion] = []
    @State private var versionsFor: String?
    /// build 91: de melding "log in bij OpenSubtitles" is in deze spelersessie al getoond (niet bij elke titel opnieuw)
    @State private var osSignInHinted = false
    /// Build 171: "Kijk je nog?"
    @StateObject private var still = StillWatchingModel()
    #if os(iOS)
    /// Build 171: bediening vergrendeld (alle tikken en vegen genegeerd)
    @State private var locked = false
    /// Build 176: helderheid met verticaal vegen links (terug bij sluiten)
    @State private var brightness = Brightness176.Session()
    @State private var brightnessStart: Double?
    @State private var swipeKind: Brightness176.Kind?
    @State private var brightnessHUD: Double?
    @State private var brightnessHUDHide: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase176
    #endif

    enum Panel: String, Identifiable {
        case audioSubs, opensubs, options, cast, sources, rate, intro, alternatives
        /// Build 173: zaplijst en afleveringen (net als Audio en ondertitels onderin over het beeld)
        case zap, episodes
        var id: String { rawValue }
        /// Build 173: deze panelen openen onderin over het beeld (geen blad) en pauzeren niet
        var isOverlay: Bool { self == .audioSubs || self == .zap || self == .episodes }
    }
    /// Build 173: vorige zender, dubbeltikken, vraag vanaf het begin, slaaptimer, afleveringen
    @State private var prevChannel = Player173.PreviousChannel()
    @State private var doubleTap = Player173.DoubleTap()
    @State private var tapBadge: Double?
    @State private var tapBadgeHide: Task<Void, Never>?
    @State private var startOverPrompt: EPGProgram?
    @State private var sleepStopped = false
    @State private var catchupOK = false
    @State private var episodeSeries: Series?
    #if os(iOS)
    /// Build 179 (iPhone Duo): half open met de vouw horizontaal (tafelstand): beeld boven de vouw, bediening eronder
    @State private var tabletop179: Duo179.Tabletop?
    #endif
    @State private var episodeList: [Episode] = []

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
            #if os(iOS)
            FoldReader179(tabletop: $tabletop179)
            #endif
            EngineView(controller: player, external: true)
                .padding(.bottom, videoBottom179)
                .ignoresSafeArea().allowsHitTesting(false)
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
                    .padding(.bottom, videoBottom179 > 0 ? videoBottom179 + 12 : (showControls ? tvScaled(120) : tvScaled(40)))
                    .allowsHitTesting(false)
            }

            if (player.isBuffering || player.reconnecting) && player.errorText == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(tvScaled(1.6))
                    if player.reconnecting { Text(L("Reconnecting…")).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                }
                .padding(.bottom, videoBottom179)
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
                        NetflixButton(title: cast.isPlaying ? L("Pause") : L("Play"), icon: cast.isPlaying ? "pause.fill" : "play.fill", kind: .play) { cast.togglePause() }
                        NetflixButton(title: L("Stop casting"), icon: "xmark", kind: .secondary) { cast.disconnect(); player.resume() }
                    }
                }
                .padding(30).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }
            #endif

            #if os(tvOS)
            if !showControls && streamLimit == nil && player.errorText == nil && !still.isActive && !sleepStopped
                && startOverPrompt == nil && !(panel?.isOverlay ?? false) { tvCatcher }
            // build 169: swipen over het touchoppervlak = voorbeeldpositie op de tijdbalk
            // build 170: aanraking stopt het uitrollen; ←/→ ingedrukt houden op de balk herhaalt met een vast ritme
            TVScrubPanListener(enabled: tvPanEnabled,
                               holdEnabled: tvHoldEnabled,
                               onTouchDown: { scrub.touchDown() },
                               onBegan: { tvPanBegan() },
                               onChanged: { dx, v in scrub.panChanged(dx, velocity: v) },
                               onEnded: { v in scrub.panEnded(velocity: v); userPoke() },
                               onHoldBegan: { forward in if canScrub { scrub.holdBegan(forward: forward); userPoke() } },
                               onHoldEnded: { scrub.holdEnded(); userPoke() })
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            #endif
            if showControls && streamLimit == nil && !still.isActive && !isLocked && !sleepStopped && !(panel?.isOverlay ?? false) {
                controls.padding(.top, controlsTop179).transition(.opacity)
            }

            // build 173: panelen onderin over het beeld (pauzeren niet)
            if let p = panel, p.isOverlay, !isLocked { overlayPanel(p).zIndex(3) }
            if let prog = startOverPrompt, panel == nil {
                StartOverPrompt173(program: prog, onStartOver: { startOverPrompt = nil; startOver173() },
                                   onLive: { startOverPrompt = nil; userPoke() })
                    .transition(.opacity).zIndex(4)
            }
            if let b = tapBadge { doubleTapBadge(b).allowsHitTesting(false) }
            #if os(iOS)
            if let b = brightnessHUD { BrightnessHUD176(value: b).transition(.opacity) }
            #endif

            if showSkipIntro, !tvBarHasPrimary, let skip = skipTarget {
                skipIntroButton(skip.end, recap: skip.recap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, tvScaled(40))
                    .padding(.bottom, showControls ? tvScaled(130) : tvScaled(50))
                    .transition(.opacity)
            }

            if let n = nextUp, let left = nextCountdown {
                nextEpisodeCard(n, left)
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

            #if os(iOS)
            // build 171: bediening vergrendeld: één laag over alles die alle tikken en vegen opvangt
            if locked { ControlLockOverlay { locked = false; userPoke() } }
            #endif

            // build 171: "Kijk je nog?" / "Gepauzeerd"
            StillWatchingOverlay(model: still, onStop: { close() })
            // build 173: slaaptimer afgegaan
            if sleepStopped { SleepStopped173(onContinue: { continueAfterSleep() }, onClose: { close() }).zIndex(5) }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: still.phase)
        .animation(.easeInOut(duration: 0.2), value: banner?.id)
        #if !os(tvOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #if os(macOS)
        // Mac-toetsenbord: spatie = pauze, ←/→ = 10 s, ↑/↓ = zappen, Esc = sluiten
        .focusable()
        // build 60: meteen (en na een paneel weer) de toetsenbordfocus, anders werkten de toetsen pas na een klik
        .focused($macKeys)
        .onAppear { macKeys = true }
        .onChange(of: panel) { _, p in if p == nil { macKeys = true } }
        .focusEffectDisabled()
        .onKeyPress(.space) { player.togglePlay(); userPoke(); return .handled }
        .onKeyPress(.leftArrow) { still.interaction(); player.seek(by: -10); flash("−10 s"); return .handled }
        .onKeyPress(.rightArrow) { still.interaction(); player.seek(by: 10); flash("+10 s"); return .handled }
        .onKeyPress(.upArrow) { zap(-1); return .handled }
        .onKeyPress(.downArrow) { zap(1); return .handled }
        .onExitCommand { if panel != nil { panel = nil } else { close() } }
        #endif
        #else
        .onPlayPauseCommand { tvPlayPause(.toggle) }
        .onChange(of: showControls) { _, shown in
            // bediening tevoorschijn → focus op afspelen/pauze; weg → focus terug naar de vanger, of naar
            // "Intro overslaan" / "Volgende aflevering" als die in beeld staan (build 60)
            if shown && tvFocusTimelineOnShow {
                // build 169: geswiped met verborgen bediening → focus op de tijdbalk (die staat er pas net)
                tvFocusTimelineOnShow = false
                tvFocus = .bar("timeline")
                DispatchQueue.main.async { if canScrub { tvFocus = .bar("timeline") } }
            }
            else if shown { tvFocus = tvDefaultFocus }
            else if showSkipIntro { tvFocus = .bar("skipintro") }
            else if nextCountdown != nil { tvFocus = .bar("nextplay") }
            else { tvFocus = .catcher }
        }
        // rondkijken in de balk houdt hem zichtbaar; de knoppen boven het beeld (intro overslaan, volgende aflevering)
        // niet, anders haalt het tonen van de balk de focus er meteen weer af (build 60)
        .onChange(of: tvFocus) { old, f in
            // build 171: focuswissel binnen de bediening = bediening ("Kijk je nog?")
            if case .some(.bar) = old, case .some(.bar) = f { still.interaction() }
            // build 170: tijdens swipen/uitrollen/ingedrukt houden blijft de focus op de tijdbalk (geen per ongeluk ↑/↓)
            if old == .bar("timeline"), f != .bar("timeline"), scrub.guardsFocus, canScrub {
                tvFocus = .bar("timeline")
                return
            }
            if case .some(.bar(let id)) = f, !Self.overlayFocusIDs.contains(id) { poke() }
            // build 169: focus van de balk af → de voorbeeldpositie vervalt na 5 s (terug op de balk = blijft)
            if f == .bar("timeline") { tvPreviewExpire?.cancel(); tvPreviewExpire = nil }
            else if scrub.isScrubbing { tvSchedulePreviewExpiry() }
        }
        .onAppear {
            scrub.player = player; tvFocus = showControls ? tvDefaultFocus : .catcher
            // build 176: ±10-knoppen van de Remote-app (iPhone/iPad) en andere afstandsbedieningen
            // build 178: ook afspelen/pauze (anders bereikt de knop van de Siri Remote `.onPlayPauseCommand` niet meer)
            remoteSkip.attach({ forward in tvSkip(forward: forward) }, playPause: { kind in tvPlayPause(kind) })
        }
        // intro overslaan: de knop krijgt de focus zolang de bediening verborgen is (zoals Netflix)
        .onChange(of: showSkipIntro) { _, v in
            if v && !showControls { tvFocus = .bar("skipintro") }
            else if !v && tvFocus == .bar("skipintro") { tvFocus = showControls ? tvDefaultFocus : .catcher }
        }
        // build 60: kaart "Volgende aflevering" ook bereikbaar met verborgen bediening (de vanger vangt alle pijltjes)
        .onChange(of: nextCountdown != nil) { _, v in
            if v && !showControls && !showSkipIntro { tvFocus = .bar("nextplay") }
            else if !v, case .bar(let id)? = tvFocus, id == "nextplay" || id == "nexthide" {
                tvFocus = showControls ? tvDefaultFocus : .catcher
            }
        }
        .onExitCommand {
            if sleepStopped { close() }
            else if startOverPrompt != nil { startOverPrompt = nil }
            else if streamLimit != nil || still.isActive { close() }
            else if panel != nil { panel = nil }
            // build 169: Terug annuleert eerst de voorbeeldpositie (zonder spoelen); een tweede keer werkt zoals altijd
            else if scrub.isScrubbing { tvCancelPreview() }
            else if showControls { showControls = false } else { close() }
        }
        #endif
        .sheet(item: Binding(get: { panel.flatMap { $0.isOverlay ? nil : $0 } }, set: { panel = $0 })) { p in
            switch p {
            case .audioSubs, .zap, .episodes:
                EmptyView()   // build 173: onderin over het beeld, zie overlayPanel
            case .opensubs:
                // build 157: OpenSubtitles is Lifetime (ondertitels uit de stream blijven gratis)
                if EntitlementsService.shared.allows(.opensubtitles) { OpenSubtitlesPanel(player: player) }
                else { LifetimeInfoView(topic: .feature(.opensubtitles)) }
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
            if reused {
                bind(player.item)
                // build 164: uit het live voorbeeld van de gids: nu pas als gewone stream aanmelden
                if PiPCenter.shared.takeHandoff(player) { adoptPreview() } else { attachStream() }
                poke()
            } else { await start(item, askStartOver: true) }
        }
        .task { setupStillWatching() }
        // build 179: tijden van intro, samenvatting en aftiteling uit IntroDB (per aflevering)
        .task(id: player.item.id) { await loadIntroDB() }
        .lockGate176()
        // aftiteling gemarkeerd: na het aftellen automatisch de volgende aflevering
        .onChange(of: nextCountdown) { _, v in
            // build 176: automatisch volgende aflevering kan per profiel uit (de knop blijft)
            if v == 0, creditsStart != nil, let n = nextUp, autoNext176 {
                // build 173: slaaptimer "na deze aflevering": niet door naar de volgende
                if player.sleep == .endOfEpisode { player.setSleep(.off); sleepNow() } else { playNext(n) }
            }
        }
        .onChange(of: player.notice) { _, n in
            if let n { flash(n); player.notice = nil }
        }
        #if os(iOS)
        // build 179: Live Activity bij live tv (zappen, pauze/afspelen)
        .onChange(of: player.item.id) { _, _ in liveActivity179() }
        .onChange(of: player.isPlaying) { _, _ in liveActivity179() }
        .onAppear { liveActivity179() }
        #endif
        .onDisappear {
            #if os(iOS)
            if !player.inPiP { LiveTVActivity179.shared.stop() }
            #endif
            still.stop()
            zapTask?.cancel()
            #if os(tvOS)
            scrub.reset()
            remoteSkip.detach()
            #endif
            #if os(iOS)
            restoreBrightness()
            #endif
            if !player.inPiP {
                player.dismissed = true; player.stop()
                StreamSession.shared.stop(owner: player)
            }
        }
        #if os(iOS)
        // build 176: naar de achtergrond = de eigen helderheid terug (iOS houdt hem anders vast)
        .onChange(of: scenePhase176) { _, p in if p == .background { restoreBrightness() } }
        #endif
    }

    // MARK: bediening

    #if !os(tvOS)
    /// Tik = bediening tonen/verbergen; dubbeltik links/rechts = 10 s terug/vooruit.
    private var tapLayer: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // build 173: dubbeltik = 10 s; vaker tikken telt op (20, 30 s) met een kleine animatie
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { doubleTapSeek(forward: false, taps: 2) }
                    .onTapGesture { if doubleTapActive { doubleTapSeek(forward: false, taps: 1) } else { toggleControls() } }
                    .frame(width: geo.size.width * 0.35)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { doubleTapSeek(forward: true, taps: 2) }
                    .onTapGesture { if doubleTapActive { doubleTapSeek(forward: true, taps: 1) } else { toggleControls() } }
                    .frame(width: geo.size.width * 0.35)
            }
            // live: omhoog/omlaag vegen = volgende/vorige zender in de groep (build 176: niet in de linkerhelft op
            // iPhone/iPad, daar regelt verticaal vegen de helderheid)
            .simultaneousGesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    let dy = v.translation.height, dx = v.translation.width
                    guard player.isLive, abs(dy) > 60, abs(dy) > abs(dx) * 1.5 else { return }
                    #if os(iOS)
                    if brightnessSwipeEnabled, Brightness176.inZone(x: v.startLocation.x, width: geo.size.width) { return }
                    #endif
                    zap(dy < 0 ? 1 : -1)
                }
            )
            #if os(iOS)
            .simultaneousGesture(brightnessGesture(geo.size))
            #endif
        }
        .ignoresSafeArea()
    }
    #endif

    #if os(iOS)
    // MARK: build 176: helderheid met vegen

    private var brightnessSwipeEnabled: Bool {
        Brightness176.enabled(locked: locked, casting: cast.connected != nil,
                              external: external.isConnected && PlayerSettings.externalDisplay)
    }

    private func brightnessGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: Brightness176.decideDistance)
            .onChanged { v in
                guard brightnessSwipeEnabled else { return }
                if swipeKind == nil {
                    swipeKind = Brightness176.classify(startX: v.startLocation.x, width: size.width,
                                                       dx: v.translation.width, dy: v.translation.height)
                    if swipeKind == .brightness { brightnessStart = brightness.begin(current: ScreenBrightness176.current) }
                }
                guard swipeKind == .brightness, let start = brightnessStart else { return }
                let b = Brightness176.value(start: start, dy: v.translation.height, height: size.height)
                ScreenBrightness176.set(b)
                brightnessHUDHide?.cancel()
                if brightnessHUD == nil { withAnimation(.easeOut(duration: 0.15)) { brightnessHUD = b } } else { brightnessHUD = b }
                still.interaction()
            }
            .onEnded { _ in
                let was = swipeKind
                swipeKind = nil; brightnessStart = nil
                guard was == .brightness else { return }
                brightnessHUDHide?.cancel()
                brightnessHUDHide = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { brightnessHUD = nil }
                }
            }
    }

    /// Sluiten van de speler of naar de achtergrond: de helderheid van vóór het vegen terug.
    private func restoreBrightness() {
        if let v = brightness.end() { ScreenBrightness176.set(v) }
        brightnessHUD = nil
    }
    #endif

    /// Build 179 (iPhone Duo): ruimte onder het beeld en begin van de bediening in tafelstand (anders 0)
    private var videoBottom179: CGFloat {
        #if os(iOS)
        return CGFloat(tabletop179?.videoBottom ?? 0)
        #else
        return 0
        #endif
    }

    private var controlsTop179: CGFloat {
        #if os(iOS)
        return CGFloat(tabletop179?.controlsTop ?? 0)
        #else
        return 0
        #endif
    }

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
                        Text(ContentLanguage.shown(player.item.title)).font(.system(size: tvScaled(17), weight: .bold))
                        if let s = player.item.subtitle { Text(s).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                    }
                    Spacer()
                    #if !os(tvOS)
                    if PlayerController.pipSupported {
                        Button { player.startPiP() } label: { Image(systemName: "pip.enter").font(.system(size: 20)) }
                            .accessibilityLabel(L("Picture in Picture"))
                    }
                    AirPlayButton { player.switchToApple() }.frame(width: 34, height: 34)
                    #if os(iOS)
                    // build 171: bediening vergrendelen (alle tikken en vegen genegeerd tot je het slot vasthoudt)
                    Button { locked = true; showControls = false; panel = nil } label: {
                        Image(systemName: "lock.open").font(.system(size: 20))
                    }
                    .accessibilityLabel(L("Lock controls"))
                    #endif
                    Button { panel = .cast } label: { Image(systemName: "tv.and.mediabox").font(.system(size: 20)) }
                    #endif
                    if player.isLive {
                        Button { player.goLive(); userPoke() } label: {
                            Label(player.behindLive > 5 ? "−\(PlayerController.format(player.behindLive))" : L("LIVE"),
                                  systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: tvScaled(12), weight: .heavy))
                                .foregroundStyle(player.behindLive > 5 ? Color.white : Theme.onAccent)
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
                // build 97: knoppen met alleen een icoon krijgen een VoiceOver-label
                HStack(spacing: 56) {
                    if player.isLive && !player.canTimeshift {
                        roundButton("chevron.up", size: 24) { zap(-1) }.accessibilityLabel(L("Previous channel"))
                    } else {
                        roundButton("gobackward.10", size: 30) { player.seek(by: -10); userPoke() }.accessibilityLabel(L("Back 10 seconds"))
                    }
                    roundButton(player.isPlaying ? "pause.fill" : "play.fill", size: 44) { player.togglePlay(); userPoke() }
                        .accessibilityLabel(player.isPlaying ? L("Pause") : L("Play"))
                    if player.isLive && !player.canTimeshift {
                        roundButton("chevron.down", size: 24) { zap(1) }.accessibilityLabel(L("Next channel"))
                    } else {
                        roundButton("goforward.10", size: 30) { player.seek(by: 10); userPoke() }.accessibilityLabel(L("Forward 10 seconds"))
                    }
                }
                Spacer()
                #endif

                // build 173: tv zonder knoppen voor afspelen/pauze en terug (die zitten op de afstandsbediening); de
                // knoppen bij elkaar linksonder boven een iets grotere tijdbalk, de belangrijkste knop het grootst
                VStack(alignment: .leading, spacing: tvScaled(10)) {
                    #if !os(tvOS)
                    if player.isLive { liveInfo } else { timeline }
                    #endif
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tvScaled(26)) {
                            if let p = primary173, Self.showsPrimaryInBar(p) { primaryButton(p) }
                            if player.isLive {
                                barButton("list.bullet.rectangle", L("Zap"), id: "zap") { panel = .zap }
                                if prevChannel.previous != nil {
                                    barButton("arrow.uturn.backward", L("Previous channel"), id: "prevch") { previousChannel() }
                                }
                                if canStartOver173 && primary173 != .startOver {
                                    barButton("backward.end.fill", L("From the start"), id: "startover") { startOver173() }
                                }
                            }
                            barButton("speaker.wave.2.bubble", L("Audio & subtitles"), id: "audiosubs") { panel = .audioSubs }
                            if player.item.type == .episode {
                                barButton("rectangle.stack", L("Episodes"), id: "episodes") { openEpisodes() }
                            }
                            if !stremioChoices.isEmpty { barButton("list.bullet", L("Sources")) { panel = .sources } }
                            // build 186: met tijden uit IntroDB is markeren niet nodig; dan alleen "Intro overslaan"
                            if player.item.type == .episode && markerKey != nil && !introDBKnown {
                                barButton("forward.frame", L("Mark intro here")) { panel = .intro }
                            }
                            if player.isLive {
                                barButton(Theme.otherSourceIcon, L("Other source")) { openAlternatives() }
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
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Label(Player173.countdown(s.timeIntervalSince(ctx.date)), systemImage: "moon.zzz.fill")
                                        .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary)
                                }
                            } else if player.sleep == .endOfEpisode {
                                Image(systemName: "moon.zzz.fill").font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                            }
                        }
                        #if os(tvOS)
                        .padding(.vertical, 20)
                        #endif
                    }
                    #if os(tvOS)
                    .focusSection()
                    #endif
                    #if os(tvOS)
                    if player.isLive { liveInfo } else { timeline }
                    #endif
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
                                  set: { scrubbing = $0; userPoke() }),
                   in: 0...1, onEditingChanged: { editing in
                if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil; userPoke() }
            })
            .tint(Theme.red)
            // build 169: tijd van de voorbeeldpositie en het verschil met nu boven de knop, zolang je sleept
            .overlay(alignment: .topLeading) {
                if let s = scrubbing, player.duration > 0 {
                    GeometryReader { g in
                        Text(Scrub169.label(preview: s * player.duration, current: player.position * player.duration))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.75), in: Capsule())
                            .fixedSize()
                            .position(x: min(max(g.size.width * s, 64), max(g.size.width - 64, 64)), y: -16)
                    }
                    .allowsHitTesting(false)
                }
            }
            #else
            tvTimelineBar
            #endif
            Text("-" + PlayerController.format(player.duration * (1 - (scrubbing ?? player.position))))
                .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary)
            // build 173: eindtijd (rekening houdend met de afspeelsnelheid)
            if let end = Player173.endsAt(now: Date(), remaining: player.duration * (1 - player.position), rate: Double(player.rate)) {
                Text(L("Ends at %@", end.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    /// Build 173: live: wat er nu op is, met voortgang en de eindtijd volgens de gids
    @ViewBuilder private var liveInfo: some View {
        if let p = currentProgram {
            HStack(spacing: tvScaled(12)) {
                Text(CategoryName.display(p.title)).font(.system(size: tvScaled(13), weight: .semibold)).lineLimit(1)
                ProgressBar(value: p.progress).frame(height: tvScaled(4)).clipShape(Capsule())
                Text(L("Ends at %@", p.end.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: tvScaled(12)).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private func roundButton(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(.white).frame(width: 64, height: 64) }
    }

    @ViewBuilder
    private func barButton(_ icon: String, _ label: String, id: String? = nil, _ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button { action(); userPoke() } label: {
            Label(label, systemImage: icon).font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(.white)
        .focused($tvFocus, equals: .bar(id ?? label))
        #else
        Button { action(); userPoke() } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 20)).padding(6)
        }
        .foregroundStyle(.white)
        #endif
    }

    /// Kaart "Volgende aflevering"; op Apple TV met de focus van het spelerscherm (build 60).
    @ViewBuilder
    private func nextEpisodeCard(_ n: PlayableItem, _ left: Int) -> some View {
        #if os(tvOS)
        NextEpisodeCard(next: n, secondsLeft: left, autoplay: creditsStart != nil, counting: autoNext176,
                        onPlay: { playNext(n) }, onDismiss: { creditsDismissed = true }, focus: $tvFocus)
        #else
        NextEpisodeCard(next: n, secondsLeft: left, autoplay: creditsStart != nil, counting: autoNext176,
                        onPlay: { playNext(n) }, onDismiss: { creditsDismissed = true })
        #endif
    }

    #if os(tvOS)
    /// Knoppen boven het beeld die de focus mogen houden zonder dat de balk tevoorschijn komt (build 60)
    private static let overlayFocusIDs: Set<String> = ["skipintro", "nextplay", "nexthide"]

    /// Bediening verborgen: een onzichtbare knop over het hele beeld.
    /// Klik = bediening tonen · ←/→ = 10 s spoelen · ↑/↓ = zappen (live) of bediening tonen.
    private var tvCatcher: some View {
        Button { userPoke() } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(InvisibleTVButtonStyle())
            .focused($tvFocus, equals: .catcher)
            .onMoveCommand { dir in
                still.interaction()   // build 171
                let canSeek = !player.isLive || player.canTimeshift
                // build 169: vlak na een swipe geen losse sprong van 10 s (de swipe opent de tijdbalk)
                if (dir == .left || dir == .right) && (scrub.recentlyPanned || scrub.isScrubbing) { return }
                switch dir {
                // build 179: live op het live-punt (niet achter live): links opent de zaplijst; achter live −10 s (176)
                case .left:
                    if player.isLive && player.behindLive == 0 && !player.isTimeshifting179 && panel == nil { panel = .zap }
                    else if canSeek { tvSkip(forward: false) } else { userPoke() }
                case .right: if canSeek { tvSkip(forward: true) } else { userPoke() }
                case .up: if player.isLive { zap(-1) } else { userPoke() }
                case .down: if player.isLive { zap(1) } else { userPoke() }
                default: break
                }
            }
            .ignoresSafeArea()
    }

    /// Build 169: kan er gespoeld worden via de tijdbalk (films, afleveringen, opnames, terugkijken)
    private var canScrub: Bool { !player.isLive && player.duration > 0 }
    private var currentSeconds: Double { player.duration * player.position }

    private var tvPanEnabled: Bool {
        canScrub && streamLimit == nil && panel == nil && player.errorText == nil
            && (tvFocus == .catcher || tvFocus == .bar("timeline"))
    }

    /// Build 170: ←/→ ingedrukt houden herhaalt alleen op de tijdbalk.
    private var tvHoldEnabled: Bool {
        canScrub && streamLimit == nil && panel == nil && player.errorText == nil && tvFocus == .bar("timeline")
    }

    /// Focusbare tijdbalk (zoals de standaardspeler van Apple TV): op focus dikker met een kop op de positie;
    /// boven de kop de tijd van de voorbeeldpositie en het verschil met het begin. Build 170: het getekende deel
    /// (`TVTimelineBarContent`) volgt het scrub-object zelf, zodat alleen de balk opnieuw tekent.
    private var tvTimelineBar: some View {
        let focused = tvFocus == .bar("timeline")
        return Button { tvTimelineSelect() } label: {
            TVTimelineBarContent(scrub: scrub, position: player.position, duration: player.duration, focused: focused)
                .frame(height: 46)   // build 173: iets groter
                .contentShape(Rectangle())
        }
        .buttonStyle(InvisibleTVButtonStyle())
        .focused($tvFocus, equals: .bar("timeline"))
        .onMoveCommand { dir in
            switch dir {
            // build 176: zonder voorbeeldpositie direct spoelen (niet pauzeren); met voorbeeldpositie die verschuiven
            case .left, .right:
                guard canScrub else { break }
                let forward = dir == .right
                if Skip176.click(scrubbing: scrub.isScrubbing || scrub.committing) == .scrubStep { scrub.click(forward: forward) }
                else if !scrub.recentlyPanned { tvSkip(forward: forward) }
                userPoke()
            default: break
            }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    /// Build 178: de afspeel/pauzeknop van de Siri Remote, als `.onPlayPauseCommand` of als systeemopdracht
    /// (togglePlayPause/play/pause via `RemoteSkip176`). Zelfde regels als in 175.
    private func tvPlayPause(_ kind: RemoteSkip176.PlayPause) {
        let now = Date()
        guard now.timeIntervalSince(tvLastPlayPause) > 0.35 else { return }
        tvLastPlayPause = now
        // build 171: "Gepauzeerd" → verder; "Kijk je nog?" → verder kijken
        if still.phase == .paused { still.resume(); return }
        if still.isActive { still.keepWatching(); return }
        // build 169: met een voorbeeldpositie op de tijdbalk springt Play/Pauze daarheen
        if scrub.isScrubbing { tvCommitPreview(); return }
        guard !scrub.committing else { return }
        switch kind {
        case .toggle: player.togglePlay()
        case .play: if !player.isPlaying { player.togglePlay() }
        // build 179 (X2): een pauze-opdracht die niet van de afspeel/pauzeknop komt (Remote-app, tv via HDMI-CEC,
        // systeem) vastleggen voor Diagnose
        case .pause: if player.isPlaying { player.noteStop(.remotePause); player.togglePlay() }
        }
        userPoke()
    }

    /// Build 176: direct 10 s spoelen zonder pauzeren (←/→, ±10 van de Remote-app); snel achter elkaar telt op.
    private func tvSkip(forward: Bool) {
        still.interaction()
        guard Skip176.canSkip(isLive: player.isLive, canTimeshift: player.canTimeshift, duration: player.duration),
              !scrub.isScrubbing else { return }
        if player.isLive {
            player.seek(by: forward ? Skip176.step : -Skip176.step)
            flash(Skip176.label(forward ? Skip176.step : -Skip176.step))
            return
        }
        let t = player.engine.time
        let current = t.isFinite && t > 0 ? t : player.duration * player.position
        let r = skipChain.jump(forward: forward, now: Date().timeIntervalSinceReferenceDate, current: current,
                               duration: player.duration)
        let delta = r.target - current
        if abs(delta) >= 0.5 { player.seek(by: delta) }
        flash(Skip176.label(r.total))
    }

    /// Select op de tijdbalk: naar de voorbeeldpositie springen, of zonder voorbeeldpositie afspelen/pauzeren.
    private func tvTimelineSelect() {
        if scrub.isScrubbing { tvCommitPreview() }
        else if !scrub.committing { player.togglePlay(); userPoke() }
    }

    private func tvPanBegan() {
        guard canScrub else { return }
        scrub.panBegan()
        if !showControls { tvFocusTimelineOnShow = true }
        else if tvFocus != .bar("timeline") { tvFocus = .bar("timeline") }
        userPoke()
    }

    private func tvCommitPreview() {
        tvPreviewExpire?.cancel(); tvPreviewExpire = nil
        scrub.commit()
        userPoke()
    }

    private func tvCancelPreview() {
        tvPreviewExpire?.cancel(); tvPreviewExpire = nil
        scrub.cancel()
        userPoke()
    }

    private func tvSchedulePreviewExpiry() {
        tvPreviewExpire?.cancel()
        tvPreviewExpire = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Scrub169.previewTimeout * 1_000_000_000))
            // build 170: vervallen = annuleren (terug naar het begin en verder spelen als het speelde)
            if !Task.isCancelled && tvFocus != .bar("timeline") { scrub.cancel() }
        }
    }
    #endif

    // MARK: build 173: bediening in de speler

    /// De belangrijkste knop van dit moment (Intro overslaan, Volgende aflevering, Terug naar live, Vanaf het begin)
    private var primary173: Player173.Primary? {
        Player173.primary(inIntro: showSkipIntro, nextEpisode: nextCountdown != nil, isLive: player.isLive,
                          canStartOver: canStartOver173, behindLive: player.behindLive)
    }

    /// Op de tv staat de belangrijkste knop altijd vooraan in de balk; elders alleen Vanaf het begin (Intro overslaan en
    /// Volgende aflevering hebben daar hun eigen knop boven het beeld, Terug naar live het LIVE-label)
    private static func showsPrimaryInBar(_ p: Player173.Primary) -> Bool {
        #if os(tvOS)
        return true
        #else
        return p == .startOver
        #endif
    }

    /// Tv: met de bediening in beeld staat Intro overslaan in de balk (niet ook nog los boven het beeld)
    private var tvBarHasPrimary: Bool {
        #if os(tvOS)
        return showControls && primary173 == .skipIntro
        #else
        return false
        #endif
    }

    private func primaryTitle(_ p: Player173.Primary) -> (String, String) {
        switch p {
        case .skipIntro: return (skipTarget?.recap == true ? L("Skip recap") : L("Skip intro"), "forward.fill")
        case .nextEpisode: return (L("Next episode"), "forward.end.fill")
        case .startOver: return (L("From the start"), "backward.end.fill")
        case .goLive: return (L("Back to live"), "dot.radiowaves.left.and.right")
        }
    }

    private func runPrimary(_ p: Player173.Primary) {
        switch p {
        case .skipIntro:
            if let skip = skipTarget { player.seek(toSeconds: skip.end); flash(skip.recap ? L("Recap skipped") : L("Intro skipped")) }
        case .nextEpisode: if let n = nextUp { playNext(n) }
        case .startOver: startOver173()
        case .goLive: player.goLive(); flash(L("LIVE"))
        }
        userPoke()
    }

    /// Grote knop vooraan (tv: wit, eerste focus)
    @ViewBuilder
    private func primaryButton(_ p: Player173.Primary) -> some View {
        let (title, icon) = primaryTitle(p)
        #if os(tvOS)
        Button { runPrimary(p) } label: {
            Label(title, systemImage: icon).font(.system(size: 28, weight: .bold))
                .padding(.horizontal, 28).padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(TVLiftStyle(scale: 1.08))
        .focused($tvFocus, equals: .bar("primary"))
        #else
        Button { runPrimary(p) } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
        #endif
    }

    #if os(tvOS)
    /// Eerste focus als de bediening verschijnt: de belangrijkste knop, anders de tijdbalk, anders Zappen
    private var tvDefaultFocus: TVField {
        if primary173 != nil { return .bar("primary") }
        if canScrub { return .bar("timeline") }
        if player.isLive { return .bar("zap") }
        return .bar("audiosubs")
    }
    #endif

    /// Wat er nu op de zender is (volgens de gids)
    private var currentProgram: EPGProgram? {
        guard player.isLive, let cid = player.item.channelID,
              let c = playlists.library.channels.first(where: { $0.id == cid }) else { return nil }
        return playlists.library.nowPlaying(c)
    }

    private var canStartOver173: Bool {
        Player173.canStartOver(hasCatchup: catchupOK, programStart: currentProgram?.start, now: Date(), behindLive: player.behindLive)
    }

    /// Vanaf het begin van het lopende programma (terugkijken van de server; daarna Terug naar live)
    private func startOver173() {
        guard let p = currentProgram else { return }
        if player.startOver(from: p.start) { flash(L("From the start")) }
        userPoke()
    }

    /// Eén tik terug naar de vorige zender (en weer terug)
    private func previousChannel() {
        guard let id = prevChannel.previous, let c = playlists.library.channels.first(where: { $0.id == id }) else { return }
        still.interaction()
        zapTask?.cancel()
        zapTarget = nil
        showBanner(c, pending: false)
        Task { await tune(c) }
    }

    /// Zaplijst: favorieten, dan de huidige categorie, dan de rest (verborgen zenders en kinderprofiel: al gefilterd)
    private var zapChannels: [Channel] {
        let all = uniqueByID(playlists.library.channels.filter { !Radio171.isRadio(flag: $0.radio, group: $0.group) })
        let pid = playlists.source?.id
        let store = CloudStore.shared
        let group = all.first { $0.id == player.item.channelID }?.group
        let fav = all.map { c in (c.sourceID ?? pid).map { store.isFavorite($0, c.id) } ?? false }
        return Player173.zapOrder(groups: all.map(\.group), favorite: fav, currentGroup: group).map { all[$0] }
    }

    @ViewBuilder
    private func overlayPanel(_ p: Panel) -> some View {
        switch p {
        case .audioSubs:
            AudioSubsPanel173(player: player, versions: languageVersions,
                              onSwitch: { v in panel = nil; Task { await switchLanguage(to: v) } },
                              onOpenSubtitles: { panel = .opensubs },
                              onClose: { panel = nil })
        case .zap:
            // build 179: tabs (Alle, Favorieten, categorieën) en zoeken
            ZapPanel179(channels: zapChannels, currentID: player.item.channelID,
                        isFavorite: { c in (c.sourceID ?? playlists.source?.id).map { CloudStore.shared.isFavorite($0, c.id) } ?? false },
                        isLocked: { c in CloudStore.shared.lockedChannelKey(c.sourceID ?? playlists.source?.id, c.id) != nil },
                        nowPlaying: { playlists.library.nowPlaying($0) },
                        onPick: { c in
                            panel = nil
                            guard c.id != player.item.channelID else { return }
                            zapTask?.cancel(); zapTarget = nil
                            // build 176/179: vergrendelde zender → eerst de pincode
                            let key = CloudStore.shared.lockedChannelKey(c.sourceID ?? playlists.source?.id, c.id)
                            if Profile176.shared.asks(key) {
                                LockGate176.shared.open(key, cancel: {}) { Task { @MainActor in showBanner(c, pending: false); await tune(c) } }
                                return
                            }
                            showBanner(c, pending: false)
                            Task { await tune(c) }
                        },
                        onClose: { panel = nil })
        case .episodes:
            if let s = episodeSeries {
                EpisodesPanel173(series: s, episodes: episodeList, currentID: player.item.id,
                                 onPick: { e in
                                     panel = nil
                                     guard e.id != player.item.id else { return }
                                     playNext(Playables.episode(e, of: s, imdb: player.item.imdbID))
                                 },
                                 onClose: { panel = nil })
            } else {
                BottomPanel173(title: L("Episodes"), onClose: { panel = nil }) { ProgressView().tint(.white) }
            }
        default:
            EmptyView()
        }
    }

    /// Afleveringen van deze serie ophalen en het paneel openen (de speler blijft open)
    private func openEpisodes() {
        panel = .episodes
        let it = player.item
        guard episodeSeries?.id != it.seriesID || episodeList.isEmpty else { return }
        let lib = playlists.library
        guard let s = lib.series.first(where: { $0.id == it.seriesID })
                ?? lib.series.first(where: { $0.episodes.contains { $0.id == it.id } }) else { return }
        Task {
            let eps = await playlists.episodes(for: s).sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            episodeSeries = s
            episodeList = eps
        }
    }

    // MARK: build 173: dubbeltikken

    private var doubleTapActive: Bool { doubleTap.active(at: Date().timeIntervalSinceReferenceDate) }

    private func doubleTapSeek(forward: Bool, taps: Int) {
        guard !player.isLive || player.canTimeshift else { toggleControls(); return }
        still.interaction()
        var step = 0.0
        for _ in 0..<(taps == 2 && doubleTapActive ? 2 : 1) {
            step += doubleTap.tap(forward: forward, at: Date().timeIntervalSinceReferenceDate).delta
        }
        player.seek(by: step)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { tapBadge = doubleTap.total }
        tapBadgeHide?.cancel()
        tapBadgeHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { tapBadge = nil }
        }
    }

    private func doubleTapBadge(_ total: Double) -> some View {
        let forward = total > 0
        return HStack(spacing: 6) {
            if !forward { Image(systemName: "backward.fill") }
            Text("\(Int(abs(total))) s").monospacedDigit()
            if forward { Image(systemName: "forward.fill") }
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .scaleEffect(1.0 + min(abs(total) / 10 - 1, 3) * 0.06)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: forward ? .trailing : .leading)
        .padding(.horizontal, 48)
        .transition(.scale.combined(with: .opacity))
        .id(forward)
    }

    // MARK: build 173: slaaptimer

    /// Slaaptimer afgegaan: pauzeren, de stream afmelden (`stream_stop`, zoals bij "Kijk je nog?") en het scherm
    /// "Slaaptimer: gestopt" met Verder kijken.
    private func sleepNow() {
        panel = nil
        showControls = false
        player.pause()
        StreamSession.shared.idleSuspend(owner: player)
        sleepStopped = true
    }

    private func continueAfterSleep() {
        sleepStopped = false
        if player.position >= 0.999, let n = nextUp { playNext(n); return }
        if StreamSession.shared.isOwner(player) && StreamSession.shared.idlePaused {
            StreamSession.shared.idleResume(owner: player)
        } else {
            player.resume()
        }
        userPoke()
    }

    // MARK: logica

    /// Callbacks die naar dit scherm verwijzen (ook na terugkeer uit beeld-in-beeld opnieuw zetten).
    private func bind(_ it: PlayableItem) {
        player.onEnterPiP = { dismiss() }
        // build 173: slaaptimer
        player.onSleep = { sleepNow() }
        player.sleepProgramEndProvider = { currentProgram?.end }
        // build 59: ondertitels van OpenSubtitles op de achtergrond (het afspelen wacht hier niet op)
        player.onNeedSubtitles = { lang in
            let current = player.item
            Task { await fetchSubtitles(current, language: lang) }
        }
        // build 52: live → automatisch naar een back-upbron; anders de foutmelding met keuzes
        player.onGiveUp = { autoFailover() }
        // build 179 (X2): MAC-portal: vóór het herverbinden een verse link (de oude is maar één keer geldig)
        player.refreshURL = {
            let cur = player.item
            guard cur.stalkerCmd != nil, cur.type == .live else { return nil }
            return await playlists.resolve(cur)
        }
        // limiet van de IPTV-provider (alleen Xtream; bij M3U e.d. geeft dit nil)
        let src = providerSource(it)
        player.providerLimitCheck = { await ProviderLimit.failureMessage(src) }
        player.onFinished = {
            // zoals Netflix: gewoon door naar de volgende aflevering (build 176: tenzij uit voor dit profiel; dan blijft de kaart)
            if let n = nextUp {
                if autoNext176 { playNext(n) } else { creditsDismissed = false }
                return
            }
            if TraktSync.askRating, TraktSync.shared.isLoggedIn, it.imdbID != nil, it.type != .live {
                panel = .rate
            } else {
                close()
            }
        }
    }

    private func start(_ it: PlayableItem, askStartOver: Bool = false) async {
        still.programmatic()   // build 171: geen bediening
        startOverPrompt = nil
        PlaybackTiming.mark("player screen")
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
        // vóór het afspelen: de verbindingslimiet van de provider alvast ophalen (blokkeert niets)
        ProviderLimit.prime(providerSource(it))
        if it.type == .live, let cid = it.channelID {
            let pl = playlists
            let sid = it.sourceID   // build 128: terugkijken via de eigen server van de zender
            player.catchupProvider = { from, to in pl.catchupURL(channelID: cid, start: from, end: to, sourceID: sid) }
        } else {
            player.catchupProvider = nil
        }
        // build 173: terugkijken mogelijk (knop Vanaf het begin), vorige zender bijhouden
        catchupOK = player.hasCatchup
        if it.type == .live, let cid = it.channelID { prevChannel.tuned(cid) }
        if askStartOver { askStartOverIfRunning() }
        if it.type != .live, versionsFor != it.id {
            versionsFor = it.id
            languageVersions = []
            Task { await loadLanguageVersions(for: it) }
        }
        // build 179 (X2): eerst het voorbeeld echt dicht (nooit twee verbindingen naar de aanbieder tegelijk)
        await PreviewTeardown179.shared.settle()
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
            PlaybackTiming.mark("stream url")
            player.liveURL = url
            player.start(url: url)
        }
        poke()
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
        guard let s = lib.series.first(where: { $0.id == it.seriesID })
                ?? lib.series.first(where: { $0.episodes.contains { $0.id == it.id } })
                ?? lib.series.first(where: { $0.title == it.title }) else { return }
        let eps = await playlists.episodes(for: s).sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard player.item.id == it.id, let i = eps.firstIndex(where: { $0.id == it.id }), i + 1 < eps.count else { return }
        nextUp = Playables.episode(eps[i + 1], of: s, imdb: it.imdbID)
    }

    /// Build 173: programma al bezig en terugkijken kan: vragen "Vanaf het begin" of "Live kijken" (live speelt alvast;
    /// zonder antwoord na 12 s blijft het live). Zonder terugkijken geen vraag.
    private func askStartOverIfRunning() {
        guard player.isLive, catchupOK, let p = currentProgram,
              Player173.askStartOver(hasCatchup: true, programStart: p.start, programEnd: p.end, now: Date()) else { return }
        startOverPrompt = p
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if startOverPrompt?.id == p.id { withAnimation { startOverPrompt = nil } }
        }
    }

    /// Build 176: volgende aflevering vanzelf starten (instelling van het profiel; "Kijk je nog?" gaat voor)
    private var autoNext176: Bool {
        Build176.autoplay(value: Profile176.shared.autoplayNext, kids: false, stillWatchingDue: still.isActive)
    }

    private func playNext(_ n: PlayableItem) {
        still.autoEpisodeStarted()   // build 171: automatisch of met Volgende aflevering
        nextUp = nil
        flash(n.subtitle ?? n.title)
        Task { player.stop(keepDisplay: true); await start(n) }
    }

    /// Build 59: beste ondertitel van OpenSubtitles in deze taal, op de achtergrond (IMDb- of TMDB-id, seizoen/aflevering
    /// en de hash van het bestand als dat kan), en meteen aanzetten met een korte melding.
    private func fetchSubtitles(_ it: PlayableItem, language lang: String) async {
        guard player.item.id == it.id, !player.hasExternalSubtitle, !player.userPickedSubtitle else { return }
        // build 157: OpenSubtitles is Lifetime: bij Gratis stil overslaan (de koppeling blijft bewaard)
        guard EntitlementsService.shared.allows(.opensubtitles) else { return }
        // build 91: niet meer stil overslaan: zonder inlog één keer per spelersessie een melding
        guard subs.isLoggedIn else {
            if !osSignInHinted {
                osSignInHinted = true
                flash(L("Sign in to OpenSubtitles under My Bingr → OpenSubtitles to download subtitles."))
            }
            return
        }
        // build 91: app-sleutel van de server nog niet binnen → eerst ophalen, anders stil overslaan (de gebruiker kan er niets aan doen)
        if !Secrets.openSubtitlesReady { await AccountService.shared.fetchConfig(force: false) }
        guard Secrets.openSubtitlesReady else { return }
        let tmdb = ContentLanguage.Facts.shared.tmdbID(it.seriesID ?? it.id)
        let hash = await OpenSubtitles.movieHash(player.url)
        do {
            let found = try await subs.search(imdbID: it.imdbID, tmdbID: tmdb, title: ContentLanguage.searchTitle(it.title),
                                              year: it.subtitle.flatMap { Int($0) }, season: it.season, episode: it.episode,
                                              languages: [lang], movieHash: hash)
            guard let best = found.first, player.item.id == it.id, !player.hasExternalSubtitle,
                  !player.userPickedSubtitle else { return }
            let file = try await subs.download(best)
            guard player.item.id == it.id, !player.hasExternalSubtitle, !player.userPickedSubtitle else { return }
            player.addSubtitle(file: file, name: "\(TrackPreferences.flag(best.language)) \(best.release)", language: best.language)
            flash(L("Subtitles: %@ (OpenSubtitles)", TrackPreferences.name(lang)))
        } catch {
            // build 91: fouten tonen (één keer per titel: de automatische ondertitels lopen maar één keer per titel)
            guard player.item.id == it.id, !player.userPickedSubtitle else { return }
            flash(Self.openSubtitlesMessage(error))
        }
    }

    /// build 91: foutmelding van OpenSubtitles voor de speler (downloadlimiet apart, anders de melding van de server)
    private static func openSubtitlesMessage(_ error: Error) -> String {
        if let h = error as? HTTPError, case .status(let code, let msg) = h {
            let m = msg.lowercased()
            if code == 406 || m.contains("quota") || (m.contains("allowed") && m.contains("download")) {
                return L("OpenSubtitles: no downloads left today.")
            }
            let text = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            return L("OpenSubtitles: %@", text.isEmpty ? "HTTP \(code)" : String(text.prefix(160)))
        }
        return L("OpenSubtitles: %@", error.localizedDescription)
    }

    // MARK: andere taal (build 59)

    private func loadLanguageVersions(for it: PlayableItem) async {
        let lib = playlists.library
        let target: DetailTarget
        if it.type == .episode, let s = lib.series.first(where: { $0.id == it.seriesID }) { target = .series(s) }
        else if let m = lib.movies.first(where: { $0.id == it.id }) { target = .movie(m) }
        else { return }
        let key = "\(playlists.source?.id.uuidString ?? "")-\(playlists.libraryVersion)"
        let found = await LanguageVersions.shared.versions(of: target, in: lib, key: key)
        guard versionsFor == it.id else { return }
        languageVersions = found
    }

    /// Naar dezelfde film/aflevering in een andere taal, op dezelfde plek.
    private func switchLanguage(to v: LanguageVersion) async {
        let old = player.item
        let at = player.currentTime, fraction = player.position
        var next: PlayableItem?
        switch v.target {
        case .movie(let m):
            next = Playables.movie(m, imdb: old.imdbID)
        case .series(let s):
            guard let season = old.season, let number = old.episode else { break }
            let eps = await playlists.episodes(for: s)
            if let e = eps.first(where: { $0.season == season && $0.number == number }) {
                next = Playables.episode(e, of: s, imdb: old.imdbID)
            }
        }
        guard var it = next else {
            flash(L("This episode isn't available in %@.", v.label))
            return
        }
        if fraction > 0.01 { it.resumeAt = fraction; it.resumeSeconds = at }
        flash(v.name)
        PlaybackTiming.begin(it.title, step: "language switch")
        player.stop(keepDisplay: true)
        await start(it)
    }

    /// Volgende/vorige zender in de huidige groep. Met een zapvertraging toont snel zappen alleen de zenderbalk;
    /// de stream start pas als je even stopt.
    private func zap(_ step: Int) {
        still.interaction()   // build 171: zenderwissel
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
            // build 176: vergrendelde zender → eerst de pincode; Annuleren = op de huidige zender blijven
            let key = CloudStore.shared.lockedChannelKey(next.sourceID ?? playlists.source?.id, next.id)
            if Profile176.shared.asks(key) {
                LockGate176.shared.open(key, cancel: { zapTarget = nil; banner = nil }) { Task { @MainActor in await tune(next) } }
                return
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

    private func close() {
        #if os(iOS)
        LiveTVActivity179.shared.stop()   // build 179
        #endif
        player.stop(); StreamSession.shared.stop(owner: player); dismiss()
    }

    #if os(iOS)
    /// Build 179: de Live Activity van live tv starten of bijwerken (zender, nu en straks)
    private func liveActivity179() {
        guard player.isLive, !player.isPreview else { LiveTVActivity179.shared.stop(); return }
        let pl = playlists
        let p = player
        LiveTVActivity179.shared.sync(player: player) {
            guard let cid = p.item.channelID, let c = pl.library.channels.first(where: { $0.id == cid }) else { return nil }
            let list = pl.library.upcoming(c, count: 2)
            let now = pl.library.nowPlaying(c)
            let next = list.first { $0.start >= (now?.end ?? Date()) }
            return (c, now, next)
        }
    }
    #endif

    // MARK: tegelijk kijken (build 51)

    /// Elke nieuwe stream (ook zappen en de volgende aflevering) aanmelden bij de Bingr-account.
    /// Afspelen wacht daar niet op; bij 403 `stream_limit` stopt de speler alsnog.
    private func registerStream(_ it: PlayableItem) {
        attachStream()
        let p = player
        Task { @MainActor in
            let r = await StreamSession.shared.start(item: it, owner: p)
            // build 167: 403 `activation_required`: stoppen; de app toont Activeer Lifetime
            if case .activation = r, !p.dismissed { close(); return }
            guard case .limit(let l) = r, !p.dismissed, p.item.id == it.id else { return }
            hitLimit(l)
        }
    }

    /// Build 164: de speler van het live voorbeeld overnemen (dezelfde stream, niet opnieuw laden): aanmelden als
    /// gewone stream, terugkijken en andere bronnen zoals bij een gewone start.
    private func adoptPreview() {
        let it = player.item
        registerStream(it)
        defer {
            // build 173: zoals bij een gewone start (uit de gids volledig scherm)
            catchupOK = player.hasCatchup
            if let cid = it.channelID { prevChannel.tuned(cid) }
            askStartOverIfRunning()
        }
        if let u = player.url { player.liveURL = u }
        CrossServer.shared.notePlayed(it)
        if it.type == .live, let cid = it.channelID {
            let pl = playlists
            let sid = it.sourceID
            player.catchupProvider = { from, to in pl.catchupURL(channelID: cid, start: from, end: to, sourceID: sid) }
            altFor = cid
            alternatives = []; triedAlternatives = []
            Task { await loadAlternatives(for: it) }
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
        // naar de achtergrond (zonder beeld-in-beeld/AirPlay/Chromecast): de stream echt stoppen, terug = verder
        session.onBackground = { p.suspendForBackground() }
        session.onForeground = { p.resumeFromBackground() }
    }

    private func hitLimit(_ l: AccountService.StreamLimit) {
        zapTask?.cancel()
        zapTarget = nil
        nextUp = nil
        player.noteStop(.limit)   // build 179
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

    private var showSkipIntro: Bool { skipTarget != nil }

    /// Build 186: IntroDB heeft tijden voor de intro of samenvatting van deze aflevering
    private var introDBKnown: Bool { introSegs?.introEnd != nil || introSegs?.recapEnd != nil }

    /// Build 179: wat de knop nu overslaat: de samenvatting of de intro (IntroDB eerst, anders de eigen markering)
    private var skipTarget: (end: Double, recap: Bool)? {
        guard player.item.type == .episode, player.errorText == nil, !player.isLive, player.duration > 0 else { return nil }
        let m = marker
        return Build179.skip(at: player.currentTime, introSegs, userIntroStart: m?.introStart, userIntroEnd: m?.introEnd)
    }

    /// Begin van de aftiteling: IntroDB, anders de eigen markering
    private var creditsStart: Double? {
        if let c = introSegs?.creditsStart, c > 0 { return c }
        return marker?.creditsStart
    }

    /// Build 179: IntroDB voor deze aflevering (via de server-functie `introdb`, 30 dagen bewaard)
    private func loadIntroDB() async {
        introSegs = nil
        let it = player.item
        guard it.type == .episode, let season = it.season, let episode = it.episode else { return }
        let series: Series? = playlists.library.series.first(where: { $0.id == it.seriesID })
        var tmdb: Int? = it.tmdbID ?? ContentLanguage.Facts.shared.tmdbID(it.seriesID ?? it.id) ?? series?.tmdbID
        if tmdb == nil || tmdb == 0, let s = series {
            // build 186: zonder TMDB-id van de server zelf opzoeken
            tmdb = await IntroDB179.shared.showTMDB(title: s.title, year: s.year, imdb: s.imdbID ?? it.imdbID)
        }
        guard let tmdb, tmdb > 0, !Task.isCancelled else { return }
        let seg = await IntroDB179.shared.segments(tmdb: tmdb, imdb: series?.imdbID ?? it.imdbID, season: season, episode: episode)
        guard !Task.isCancelled, player.item.id == it.id else { return }
        introSegs = seg
    }

    /// Seconden tot de volgende aflevering start (nil = kaart niet tonen). Met een gemarkeerde aftiteling
    /// 10 seconden aftellen vanaf het begin ervan; anders (zoals eerder) de laatste 45 seconden tot het einde.
    private var nextCountdown: Int? {
        guard nextUp != nil, player.errorText == nil, !creditsDismissed, player.duration > 120 else { return nil }
        if let c = creditsStart, c > 0, c < player.duration {
            guard player.currentTime >= c else { return nil }
            return max(0, Int((10 - (player.currentTime - c)).rounded(.up)))
        }
        let left = player.duration - player.currentTime
        guard left < 45 else { return nil }
        return max(0, Int(left.rounded(.up)))
    }

    private func skipIntroButton(_ end: Double, recap: Bool = false) -> some View {
        Button {
            player.seek(toSeconds: end)
            flash(recap ? L("Recap skipped") : L("Intro skipped"))
        } label: {
            Label(recap ? L("Skip recap") : L("Skip intro"), systemImage: "forward.fill")
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
                    NetflixButton(title: L("Other source"), icon: Theme.otherSourceIcon, kind: .secondary) { openAlternatives() }
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
        if it.type != .live, player.lastGoodPosition > 0.01 {
            it.resumeAt = player.lastGoodPosition
            // build 60: VLC hervat op seconden (`:start-time`); niet de oude startpositie van de titel gebruiken
            it.resumeSeconds = player.duration > 0 ? player.lastGoodPosition * player.duration : nil
        }
        Task { await start(it) }
    }

    /// De bron van deze titel als dat de open bron is (anders onbekend: geen providercontrole).
    private func providerSource(_ it: PlayableItem) -> PlaylistSource? {
        guard let s = playlists.source, it.sourceID == nil || it.sourceID == s.id else { return nil }
        return s
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

    private func toggleControls() { still.interaction(); showControls.toggle(); if showControls { poke() } }

    /// Build 171: bediening door de kijker (telt voor "Kijk je nog?"), dan de bediening tonen
    private func userPoke() { still.interaction(); poke() }

    /// Build 171: is de bediening vergrendeld (alleen iPhone en iPad)
    private var isLocked: Bool {
        #if os(iOS)
        return locked
        #else
        return false
        #endif
    }

    /// Build 171: "Kijk je nog?" voor deze speler
    private func setupStillWatching() {
        let p = player
        still.canAsk = { [weak p] in
            guard let p else { return false }
            return p.errorText == nil && !p.inPiP && !p.dismissed && streamLimit == nil && !sleepStopped
        }
        still.onTimeout = {
            // beeld echt stoppen en `stream_stop` (zoals naar de achtergrond); zonder aangemelde stream alleen pauzeren
            StreamSession.shared.idleSuspend(owner: p)
            if !StreamSession.shared.idlePaused { p.pause() }
        }
        still.onResume = {
            if StreamSession.shared.isOwner(p) && StreamSession.shared.idlePaused {
                StreamSession.shared.idleResume(owner: p)
            } else {
                p.resume()
            }
            poke()
        }
        still.start()
    }

    private func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled && panel == nil && player.isPlaying && !holdControls { showControls = false }
        }
    }

    /// Build 169: de bediening blijft staan zolang je op de tijdbalk spoelt (slepen, of een voorbeeldpositie op tvOS).
    private var holdControls: Bool {
        #if os(tvOS)
        return scrub.preview != nil && tvFocus == .bar("timeline")
        #else
        return scrubbing != nil
        #endif
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
                    Text("\(now.start.formatted(date: .omitted, time: .shortened))–\(now.end.formatted(date: .omitted, time: .shortened))  \(CategoryName.display(now.title))")
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
            Text(ContentLanguage.shown(item.title) + (item.subtitle.map { " · \(ContentLanguage.shown($0))" } ?? "")).foregroundStyle(Theme.secondary).lineLimit(2)
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


#if os(iOS)
/// Build 179 (iPhone Duo): leest de vouw (gereserveerd gebied `.division`, iOS 27.1) en geeft de tafelstand door.
/// Met een oudere SDK of iOS: niets (schermvullend, zoals altijd).
private struct FoldReader179: View {
    @Binding var tabletop: Duo179.Tabletop?

    var body: some View {
        #if compiler(>=6.4) && canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .onGeometryChange(for: Duo179.Tabletop?.self) { proxy in
                    let fold = proxy.reservedRegions(kind: .division).first { $0.isActive }.map {
                        Duo179.Rect(x: Double($0.frame.minX), y: Double($0.frame.minY),
                                    w: Double($0.frame.width), h: Double($0.frame.height))
                    }
                    return Duo179.tabletop(container: Double(proxy.size.width), Double(proxy.size.height), fold: fold)
                } action: { t in
                    withAnimation(.easeInOut(duration: 0.25)) { tabletop = t }
                }
        } else {
            Color.clear.allowsHitTesting(false)
        }
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}
#endif
