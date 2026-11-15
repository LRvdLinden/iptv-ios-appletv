import SwiftUI
import AVFoundation
import MediaPlayer

/// Build 171: radio. Radiozenders herkennen (`Radio171`: Xtream `radio_streams`, M3U `radio="true"`, een categorie met
/// "radio"), alleen geluid met een kleine speler onderaan die blijft spelen terwijl je verder bladert, de bediening op het
/// vergrendelscherm en in het meldingencentrum (Now Playing), en het telt als stream (`stream_start`, kind "radio").
/// CarPlay: zie iOS/CarPlay.swift en docs/CARPLAY.md.
extension Library {
    /// Radiozenders van deze (al gefilterde) bibliotheek: in een kinderprofiel dus alleen toegestane zenders
    var radioChannels: [Channel] { uniqueByID(channels.filter { Radio171.isRadio(flag: $0.radio, group: $0.group) }) }
}

@MainActor
final class RadioPlayer: ObservableObject {
    static let shared = RadioPlayer()

    @Published private(set) var channel: Channel?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var failed = false
    /// De bibliotheek en het opzoeken van stream-adressen (gezet door AppState)
    weak var service: PlaylistService?

    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var commandsReady = false
    private final class Owner {}
    private let owner = Owner()

    /// Zenders in de volgorde voor CarPlay en het scherm: favorieten bovenaan
    func stations() -> [Channel] {
        guard let s = service else { return [] }
        let pid = s.source?.id
        let store = CloudStore.shared
        return Radio171.ordered(s.library.radioChannels) { c in
            guard let p = c.sourceID ?? pid else { return false }
            return store.isFavorite(p, c.id)
        }
    }

    func play(_ c: Channel) {
        guard let service else { return }
        stopPlayer()
        channel = c
        failed = false
        isBuffering = true
        Task { @MainActor in
            let item = Playables.channel(c, now: service.library.nowPlaying(c))
            guard var url = await service.resolve(item), self.channel?.id == c.id else {
                if self.channel?.id == c.id { self.failed = true; self.isBuffering = false }
                return
            }
            url = Self.playableURL(url)
            self.start(url, channel: c)
            // telt als stream (de aanbieder telt hem ook mee)
            let session = StreamSession.shared
            let r = await session.start(StreamSession.Info(title: String(c.name.prefix(200)), kind: "radio", contentID: c.id), owner: self.owner)
            guard self.channel?.id == c.id else { return }
            switch r {
            case .ok:
                session.keepAliveInBackground = { true }   // radio speelt op de achtergrond door
                session.titleProvider = nil
                session.onBackground = nil
                session.onForeground = nil
                session.onLimit = { [weak self] _ in self?.stop() }
                session.onReplaced = { [weak self] in self?.stop(release: false) }
            case .limit, .activation:
                self.stop()
                self.failed = true
            }
        }
    }

    /// Xtream-zenders als .ts: AVPlayer speelt geen losse MPEG-TS, wel HLS → hetzelfde adres als .m3u8
    static func playableURL(_ u: URL) -> URL {
        guard u.pathExtension.lowercased() == "ts", u.path.contains("/live/") else { return u }
        return u.deletingPathExtension().appendingPathExtension("m3u8")
    }

    private func start(_ url: URL, channel c: Channel) {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let p = AVPlayer(url: url)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        timeControlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            let status = pl.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.updateNowPlaying()
            }
        }
        statusObservation = p.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            let bad = item.status == .failed
            Task { @MainActor in
                guard let self, bad else { return }
                self.failed = true
                self.isBuffering = false
            }
        }
        p.play()
        setupCommands()
        updateNowPlaying()
    }

    func togglePlay() {
        guard let player else { if let c = channel { play(c) }; return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// Stoppen. `release`: ook `stream_stop` (niet als een andere speler de stream net heeft overgenomen).
    func stop(release: Bool = true) {
        stopPlayer()
        channel = nil
        isPlaying = false
        isBuffering = false
        if release { StreamSession.shared.stop(owner: owner) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func stopPlayer() {
        statusObservation = nil
        timeControlObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// Volgende/vorige zender in de radiolijst
    func step(_ d: Int) {
        let list = stations()
        guard !list.isEmpty else { return }
        let i = channel.flatMap { c in list.firstIndex { $0.id == c.id } } ?? -1
        play(list[(i + d + list.count) % list.count])
    }

    // MARK: Now Playing

    private func updateNowPlaying() {
        guard let c = channel else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: CategoryName.channel(c.name),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let now = service?.library.nowPlaying(c) { info[MPMediaItemPropertyArtist] = now.title }
        else { info[MPMediaItemPropertyArtist] = L("Radio") }
        if let logo = c.logo, let cg = ImagePipeline.shared.cachedAny(logo) {
            #if os(macOS)
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            #else
            let img = UIImage(cgImage: cg)
            #endif
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func setupCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in
            Task { @MainActor in RadioPlayer.shared.player?.play() }
            return .success
        }
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in RadioPlayer.shared.player?.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in RadioPlayer.shared.togglePlay() }
            return .success
        }
        cc.nextTrackCommand.addTarget { _ in
            Task { @MainActor in RadioPlayer.shared.step(1) }
            return .success
        }
        cc.previousTrackCommand.addTarget { _ in
            Task { @MainActor in RadioPlayer.shared.step(-1) }
            return .success
        }
    }
}

// MARK: - Kleine speler onderaan

/// Speelt er radio, dan een balk met logo, naam, afspelen/pauze en stoppen; blijft staan terwijl je bladert.
struct RadioMiniPlayer: View {
    @ObservedObject private var radio = RadioPlayer.shared

    var body: some View {
        if let c = radio.channel {
            HStack(spacing: tvScaled(12)) {
                RemoteImage(url: c.logo, contentMode: .fit, placeholder: "radio", maxPixel: 160)
                    .frame(width: tvScaled(40), height: tvScaled(40))
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(CategoryName.channel(c.name)).font(.system(size: tvScaled(15), weight: .semibold)).lineLimit(1)
                    Text(radio.failed ? L("This station cannot be played.") : (radio.isBuffering ? L("Loading…") : L("Radio")))
                        .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { radio.togglePlay() } label: {
                    Image(systemName: radio.isPlaying ? "pause.fill" : "play.fill").font(.system(size: tvScaled(20)))
                        .frame(width: tvScaled(40), height: tvScaled(40))
                }
                .plainTVButton()
                .accessibilityLabel(radio.isPlaying ? L("Pause") : L("Play"))
                Button { radio.stop() } label: {
                    Image(systemName: "xmark").font(.system(size: tvScaled(16), weight: .semibold))
                        .frame(width: tvScaled(40), height: tvScaled(40))
                }
                .plainTVButton()
                .accessibilityLabel(L("Stop"))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(8))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: tvScaled(12)))
            .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.1)))
            .padding(.horizontal, tvScaled(12))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Scherm Radio

/// Alle radiozenders met logo's (favorieten bovenaan); kiezen = alleen geluid afspelen.
struct RadioView: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var radio = RadioPlayer.shared
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 5)
        #else
        [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12, alignment: .top)]
        #endif
    }

    var body: some View {
        let list = radio.stations()
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(16)) {
                    HStack {
                        Text(L("Radio")).font(.system(size: tvScaled(28), weight: .heavy)).foregroundStyle(.white)
                        Spacer()
                        #if !os(tvOS)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Close"))
                        #endif
                    }
                    .padding(.horizontal, Theme.edge).padding(.top, tvScaled(16))
                    if list.isEmpty {
                        Text(L("No radio stations found.")).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.edge)
                    }
                    LazyVGrid(columns: columns, spacing: tvScaled(14)) {
                        ForEach(list) { c in
                            Button { radio.play(c) } label: { RadioTile(channel: c, playing: radio.channel?.id == c.id) }
                                .cardButton()
                                .accessibilityLabel(CategoryName.channel(c.name))
                        }
                    }
                    .padding(.horizontal, Theme.edge)
                    #if os(tvOS)
                    .padding(.vertical, 20)
                    #endif
                    Color.clear.frame(height: tvScaled(90))
                }
            }
            RadioMiniPlayer().padding(.bottom, tvScaled(16))
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: radio.channel?.id)
    }
}

private struct RadioTile: View {
    let channel: Channel
    let playing: Bool
    @Environment(\.tvFocused) private var focused

    var body: some View {
        VStack(spacing: tvScaled(8)) {
            RemoteImage(url: channel.logo, contentMode: .fit, placeholder: "radio", maxPixel: 300)
                .padding(tvScaled(14))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: tvScaled(10)))
                .overlay(RoundedRectangle(cornerRadius: tvScaled(10))
                    .stroke(playing ? Theme.red : .white.opacity(focused ? 0.9 : 0.08), lineWidth: playing || focused ? 3 : 1))
            Text(CategoryName.channel(channel.name))
                .font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.center)
        }
    }
}
