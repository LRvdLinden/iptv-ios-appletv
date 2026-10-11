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
    #if os(iOS)
    @StateObject private var cast = CastManager.shared
    #endif

    enum Panel: String, Identifiable { case audioSubs, opensubs, options, cast, sources, rate; var id: String { rawValue } }

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
            EngineView(controller: player).ignoresSafeArea().allowsHitTesting(false)
            #if os(iOS)
            tapLayer
            #endif

            if let s = player.subtitleText {
                Text(s)
                    .font(.system(size: tvScaled(20), weight: .semibold))
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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: tvScaled(36))).foregroundStyle(Theme.red)
                    Text(e).font(.system(size: tvScaled(16)))
                    NetflixButton(title: L("Try again"), icon: "arrow.clockwise") { Task { await start(player.item) } }
                }
            }
            #if os(iOS)
            if cast.connected != nil {
                VStack(spacing: 12) {
                    Image(systemName: "tv.and.mediabox").font(.system(size: 48))
                    Text(cast.status).font(.headline)
                    HStack(spacing: 20) {
                        NetflixButton(title: cast.isPlaying ? L("Pause") : L("Play"), icon: cast.isPlaying ? "pause.fill" : "play.fill") { cast.togglePause() }
                        NetflixButton(title: L("Stop casting"), icon: "xmark", kind: .secondary) { cast.disconnect(); player.resume() }
                    }
                }
                .padding(30).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }
            #endif

            if showControls { controls.transition(.opacity) }

            if let toast {
                Text(toast).font(.system(size: tvScaled(14), weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, tvScaled(40))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #else
        .onPlayPauseCommand { player.togglePlay(); poke() }
        .onMoveCommand { dir in
            if showControls { poke(); return }
            switch dir {
            case .left: player.seek(by: -10); flash("−10 s")
            case .right: player.seek(by: 10); flash("+10 s")
            case .up: zap(-1)
            case .down: zap(1)
            default: break
            }
        }
        .onExitCommand {
            if panel != nil { panel = nil } else if showControls { showControls = false } else { close() }
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
            case .cast:
                #if os(iOS)
                if let u = player.url {
                    CastPicker(item: player.item, url: u, position: player.currentTime) { player.pause() }
                }
                #else
                EmptyView()
                #endif
            }
        }
        .task {
            if reused { bind(player.item); poke() } else { await start(item) }
        }
        .onChange(of: player.notice) { _, n in
            if let n { flash(n); player.notice = nil }
        }
        .onDisappear { if !player.inPiP { player.stop() } }
    }

    // MARK: bediening

    #if os(iOS)
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
    }
    #endif

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(alignment: .top, spacing: 14) {
                    #if os(iOS)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).padding(10) }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.item.title).font(.system(size: tvScaled(17), weight: .bold))
                        if let s = player.item.subtitle { Text(s).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                    }
                    Spacer()
                    #if os(iOS)
                    if PlayerController.pipSupported {
                        Button { player.startPiP() } label: { Image(systemName: "pip.enter").font(.system(size: 20)) }
                            .accessibilityLabel(L("Picture in Picture"))
                    }
                    AirPlayButton { player.switchToApple() }.frame(width: 34, height: 34)
                    Button { panel = .cast } label: { Image(systemName: "tv.and.mediabox").font(.system(size: 20)) }
                    #endif
                    if player.isLive {
                        Button { player.goLive(); poke() } label: {
                            Label(player.behindLive > 5 ? "−\(PlayerController.format(player.behindLive))" : "LIVE",
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

                #if os(iOS)
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
                            barButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? L("Pause") : L("Play")) { player.togglePlay() }
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
                            if player.item.imdbID != nil { barButton("captions.bubble", "OpenSubtitles") { panel = .opensubs } }
                            if !stremioChoices.isEmpty { barButton("list.bullet", L("Sources")) { panel = .sources } }
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
            #if os(iOS)
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

    private func barButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            #if os(tvOS)
            Label(label, systemImage: icon).font(.system(size: 24, weight: .semibold))
            #else
            Label(label, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 20)).padding(6)
            #endif
        }
        .foregroundStyle(.white)
    }

    // MARK: logica

    /// Callbacks die naar dit scherm verwijzen (ook na terugkeer uit beeld-in-beeld opnieuw zetten).
    private func bind(_ it: PlayableItem) {
        player.onEnterPiP = { dismiss() }
        player.onFinished = {
            if TraktSync.askRating, TraktSync.shared.isLoggedIn, it.imdbID != nil, it.type != .live {
                panel = .rate
            } else {
                close()
            }
        }
    }

    private func start(_ it: PlayableItem) async {
        player.item = it
        bind(it)
        if it.type == .live, let cid = it.channelID {
            let pl = playlists
            player.catchupProvider = { from, to in pl.catchupURL(channelID: cid, start: from, end: to) }
        } else {
            player.catchupProvider = nil
        }
        if it.stremio != nil {
            stremioChoices = await playlists.stremioStreams(it)
            guard let first = stremioChoices.first else {
                flash(L("No playable streams found for this title.")); return
            }
            player.start(url: first.url)
        } else {
            guard let url = await playlists.resolve(it) else { flash(L("No stream address available.")); return }
            player.liveURL = url
            player.start(url: url)
        }
        poke()
        if autoSubtitles, subs.isLoggedIn, let imdb = it.imdbID, it.type != .live {
            if let first = try? await subs.search(imdbID: imdb, season: it.season, episode: it.episode).first,
               let file = try? await subs.download(first) {
                player.addSubtitle(file: file); flash(L("Subtitles: %@", first.language.uppercased()))
            }
        }
    }

    private func zap(_ step: Int) {
        let list = app.liveZapList
        guard player.isLive, !list.isEmpty, let i = list.firstIndex(where: { $0.id == player.item.channelID ?? player.item.id }) else { return }
        let next = list[(i + step + list.count) % list.count]
        if let pid = playlists.source?.id { CloudStore.shared.pushRecentChannel(pid, next.id) }
        let it = Playables.channel(next, now: playlists.library.nowPlaying(next))
        flash("\(next.number.map { "\($0)  " } ?? "")\(next.name)")
        Task { player.stop(); await start(it) }
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

    private func close() { player.stop(); dismiss() }

    private func toggleControls() { showControls.toggle(); if showControls { poke() } }

    private func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && panel == nil && player.isPlaying { showControls = false }
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { if toast == text { toast = nil } } }
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
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
