import Foundation
import SwiftUI
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// VLC-engine: speelt ook .ts, .mkv, AC3/DTS en externe ondertitels af (net als UHF).
@MainActor
final class PlayerController: ObservableObject {
    let player = VLCMediaPlayer()

    @Published var item: PlayableItem
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0       // 0...1
    @Published private(set) var currentTime: Double = 0    // sec
    @Published private(set) var duration: Double = 0       // sec (0 = live)
    @Published private(set) var errorText: String?
    @Published var rate: Float = 1 { didSet { player.rate = rate } }
    @Published var sleepAt: Date?
    @Published var aspect: Aspect = .fit { didSet { applyAspect() } }

    enum Aspect: String, CaseIterable { case fit = "Passend", fill = "Vullen", r169 = "16:9", r43 = "4:3" }

    private var timer: Timer?
    private var lastSaved = Date.distantPast
    private var didResume = false
    private var didScrobbleStart = false
    var onFinished: (() -> Void)?

    init(item: PlayableItem) { self.item = item }

    var isLive: Bool { item.type == .live || duration <= 0 }

    // MARK: afspelen

    func start(url: URL) {
        errorText = nil; didResume = false; didScrobbleStart = false
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(item.type == .live ? 1500 : 3000)")
        media.addOption(":http-user-agent=\(Secrets.userAgent)")
        player.media = media
        player.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let state = player.state
        isPlaying = player.isPlaying
        isBuffering = state == .buffering || state == .opening
        if state == .error { errorText = "Deze stream kan niet worden afgespeeld." }
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        duration = len
        currentTime = Double(player.time.intValue) / 1000
        position = len > 0 ? Double(player.position) : 0

        if isPlaying && !didResume {
            didResume = true
            if item.resumeAt > 0.01 && item.resumeAt < 0.95 && len > 0 { player.position = Float(item.resumeAt) }
        }
        if isPlaying && !didScrobbleStart && len > 0 {
            didScrobbleStart = true
            Task { await TraktSync.shared.scrobble(.start, item: item, progress: position) }
        }
        if let s = sleepAt, Date() >= s { sleepAt = nil; pause() }
        if Date().timeIntervalSince(lastSaved) > 15 { saveProgress() }
        if state == .ended || (state == .stopped && position > 0.98) { finish() }
    }

    func togglePlay() { player.isPlaying ? pause() : resume() }

    func pause() {
        player.pause()
        saveProgress()
        Task { await TraktSync.shared.scrobble(.pause, item: item, progress: position) }
    }

    func resume() {
        player.play()
        Task { await TraktSync.shared.scrobble(.start, item: item, progress: position) }
    }

    func seek(by seconds: Int) {
        guard !isLive else { return }
        if seconds >= 0 { player.jumpForward(Int32(seconds)) } else { player.jumpBackward(Int32(-seconds)) }
    }

    func seek(to fraction: Double) {
        guard !isLive else { return }
        player.position = Float(min(max(fraction, 0), 1))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        saveProgress()
        let p = position, it = item
        Task { await TraktSync.shared.scrobble(.stop, item: it, progress: p) }
        player.stop()
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        position = 1
        saveProgress()
        let it = item
        Task { await TraktSync.shared.scrobble(.stop, item: it, progress: 1) }
        onFinished?()
    }

    private func saveProgress() {
        lastSaved = Date()
        guard item.type != .live, duration > 60 else { return }
        let store = CloudStore.shared
        if position >= 0.9 {
            store.clearProgress(item.id)
            store.setLocalWatched(item.id, true)
        } else if position > 0.02 {
            store.setProgress(item.id, ProgressEntry(fraction: position, position: currentTime, updated: Date(),
                                                     title: item.title, artwork: item.artwork,
                                                     playlistID: nil))
        }
    }

    // MARK: sporen

    struct Track: Identifiable, Hashable { var id: Int32; var name: String }

    var audioTracks: [Track] { tracks(player.audioTrackNames, player.audioTrackIndexes) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesNames, player.videoSubTitlesIndexes) }
    var currentAudio: Int32 { player.currentAudioTrackIndex }
    var currentSubtitle: Int32 { player.currentVideoSubTitleIndex }

    func selectAudio(_ t: Track) { player.currentAudioTrackIndex = t.id; objectWillChange.send() }
    func selectSubtitle(_ t: Track) { player.currentVideoSubTitleIndex = t.id; objectWillChange.send() }

    func addSubtitle(file: URL) {
        player.addPlaybackSlave(file, type: .subtitle, enforce: true)
        objectWillChange.send()
    }

    private func tracks(_ names: [Any]?, _ idx: [Any]?) -> [Track] {
        let n = names?.compactMap { $0 as? String } ?? []
        let i = idx?.compactMap { ($0 as? NSNumber)?.int32Value } ?? []
        return zip(i, n).map { Track(id: $0, name: $1) }
    }

    private func applyAspect() {
        switch aspect {
        case .fit: player.videoAspectRatio = nil; player.scaleFactor = 0
        case .fill:
            player.videoAspectRatio = nil
            #if os(tvOS)
            let b = UIScreen.main.bounds
            #else
            let b = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first ?? .zero
            #endif
            let ratio = "\(Int(b.width)):\(Int(b.height))"
            ratio.withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        case .r169: "16:9".withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        case .r43: "4:3".withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        }
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// UIView waarin VLC tekent.
struct VLCVideoView: UIViewRepresentable {
    let controller: PlayerController
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .black
        controller.player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
