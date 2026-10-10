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

    enum Panel: String, Identifiable { case audioSubs, opensubs, options; var id: String { rawValue } }

    init(item: PlayableItem) {
        self.item = item
        _player = StateObject(wrappedValue: PlayerController(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(controller: player).ignoresSafeArea()

            if player.isBuffering && player.errorText == nil {
                ProgressView().tint(.white).scaleEffect(tvScaled(1.6))
            }
            if let e = player.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: tvScaled(36))).foregroundStyle(Theme.red)
                    Text(e).font(.system(size: tvScaled(16)))
                    NetflixButton(title: "Opnieuw", icon: "arrow.clockwise") { Task { await start(player.item) } }
                }
            }

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
        .onTapGesture { toggleControls() }
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
            if panel != nil { panel = nil } else if showControls && !player.isLive { showControls = false } else { close() }
        }
        #endif
        .sheet(item: $panel) { p in
            switch p {
            case .audioSubs: TracksPanel(player: player)
            case .opensubs: OpenSubtitlesPanel(player: player)
            case .options: OptionsPanel(player: player)
            }
        }
        .task { await start(item) }
        .onDisappear { player.stop() }
    }

    // MARK: bediening

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    #if os(iOS)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).padding(10) }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.item.title).font(.system(size: tvScaled(17), weight: .bold))
                        if let s = player.item.subtitle { Text(s).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary) }
                    }
                    Spacer()
                    if player.isLive {
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(.system(size: tvScaled(12), weight: .heavy))
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Theme.red, in: Capsule())
                    }
                }
                .padding(.horizontal, Theme.edge).padding(.top, tvScaled(12))

                Spacer()

                #if os(iOS)
                HStack(spacing: 56) {
                    if player.isLive { roundButton("chevron.up", size: 24) { zap(-1) } }
                    else { roundButton("gobackward.10", size: 30) { player.seek(by: -10); poke() } }
                    roundButton(player.isPlaying ? "pause.fill" : "play.fill", size: 44) { player.togglePlay(); poke() }
                    if player.isLive { roundButton("chevron.down", size: 24) { zap(1) } }
                    else { roundButton("goforward.10", size: 30) { player.seek(by: 10); poke() } }
                }
                Spacer()
                #endif

                VStack(spacing: tvScaled(10)) {
                    if !player.isLive { timeline }
                    HStack(spacing: tvScaled(26)) {
                        #if os(tvOS)
                        barButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pauze" : "Afspelen") { player.togglePlay() }
                        if !player.isLive {
                            barButton("gobackward.10", "−10") { player.seek(by: -10) }
                            barButton("goforward.30", "+30") { player.seek(by: 30) }
                        } else {
                            barButton("chevron.up", "Vorige zender") { zap(-1) }
                            barButton("chevron.down", "Volgende zender") { zap(1) }
                        }
                        #endif
                        barButton("speaker.wave.2.bubble", "Audio & ondertitels") { panel = .audioSubs }
                        if player.item.imdbID != nil { barButton("captions.bubble", "OpenSubtitles") { panel = .opensubs } }
                        barButton("slider.horizontal.3", "Opties") { panel = .options }
                        Spacer()
                        if let s = player.sleepAt {
                            Label(s.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                                .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                .padding(.horizontal, Theme.edge).padding(.bottom, tvScaled(18))
            }
        }
    }

    private var timeline: some View {
        HStack(spacing: tvScaled(12)) {
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

    private func start(_ it: PlayableItem) async {
        player.item = it
        guard let url = await playlists.resolve(it) else { player.objectWillChange.send(); return }
        player.start(url: url)
        poke()
        if autoSubtitles, subs.isLoggedIn, let imdb = it.imdbID, it.type != .live {
            if let first = try? await subs.search(imdbID: imdb, season: it.season, episode: it.episode).first,
               let file = try? await subs.download(first) {
                player.addSubtitle(file: file); flash("Ondertitel: \(first.language.uppercased())")
            }
        }
    }

    private func zap(_ step: Int) {
        let list = app.liveZapList
        guard player.isLive, !list.isEmpty, let i = list.firstIndex(where: { $0.id == player.item.id }) else { return }
        let next = list[(i + step + list.count) % list.count]
        if let pid = playlists.source?.id { CloudStore.shared.pushRecentChannel(pid, next.id) }
        let it = Playables.channel(next, now: playlists.library.nowPlaying(next))
        flash("\(next.number.map { "\($0)  " } ?? "")\(next.name)")
        Task { player.stop(); await start(it) }
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
