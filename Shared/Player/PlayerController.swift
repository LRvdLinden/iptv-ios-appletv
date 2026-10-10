import Foundation
import SwiftUI

/// Stuurt één afspeelsessie aan: kiest de engine (Apple of VLC), herverbindt
/// automatisch, doet timeshift bij live, bewaart voortgang en scrobblet naar Trakt.
@MainActor
final class PlayerController: ObservableObject {
    enum EngineChoice: String, CaseIterable { case auto, apple, vlc }
    enum Aspect: String, CaseIterable { case fit, fill, r169, r43 }

    @Published var item: PlayableItem
    @Published private(set) var engine: PlaybackEngine
    @Published private(set) var usingApple = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorText: String?
    @Published private(set) var reconnecting = false
    /// Hoeveel seconden achter live (timeshift)
    @Published private(set) var behindLive: Double = 0
    @Published private(set) var subtitleText: String?
    @Published var rate: Float = 1 { didSet { engine.rate = rate } }
    @Published var sleepAt: Date?
    @Published var aspect: Aspect = .fit { didSet { engine.setAspect(aspect) } }
    @Published var muted = false { didSet { engine.muted = muted } }

    /// Echte afspeel-URL (na Stalker/Stremio-resolutie)
    private(set) var url: URL?
    var catchupProvider: (@MainActor (Date, Date) -> URL?)?
    var onFinished: (() -> Void)?
    /// Multiview-tegels: geen voortgang/scrobble
    var isPreview = false

    private var timer: Timer?
    private var lastSaved = Date.distantPast
    private var didScrobbleStart = false
    private var stallSince: Date?
    private var attempts = 0
    private var pausedAt: Date?
    private var timeshiftStart: Date?        // begin van de catch-up-stream die nu speelt
    private var externalCues: [SubtitleCue] = []

    static var choice: EngineChoice {
        EngineChoice(rawValue: UserDefaults.standard.string(forKey: "player.engine") ?? "") ?? .auto
    }

    init(item: PlayableItem) {
        self.item = item
        engine = VLCEngine()
    }

    var isLive: Bool { item.type == .live }
    var canTimeshift: Bool { isLive && (catchupProvider != nil || ((engine as? AVEngine)?.liveWindow ?? 0) > 30) }

    // MARK: engine kiezen

    private static func prefersApple(_ url: URL) -> Bool {
        switch choice {
        case .apple: return true
        case .vlc: return false
        case .auto:
            let ext = url.pathExtension.lowercased()
            let s = url.absoluteString.lowercased()
            return ["m3u8", "mp4", "m4v", "mov"].contains(ext) || s.contains(".m3u8") || s.contains("/master.m3u8")
        }
    }

    private func makeEngine(apple: Bool) {
        engine.stop()
        engine = apple ? AVEngine() : VLCEngine()
        usingApple = apple
        engine.rate = rate
        engine.muted = muted
        engine.setAspect(aspect)
    }

    // MARK: afspelen

    func start(url: URL, forceApple: Bool? = nil) {
        self.url = url
        errorText = nil; didScrobbleStart = false; stallSince = nil
        let apple = forceApple ?? Self.prefersApple(url)
        if apple != usingApple || timer == nil { makeEngine(apple: apple) }
        engine.load(url, live: isLive && timeshiftStart == nil, startFraction: isLive ? nil : item.resumeAt)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Wisselt naar de Apple-engine (voor AirPlay) op dezelfde positie.
    func switchToApple() {
        guard !usingApple, let url else { return }
        item.resumeAt = position
        start(url: url, forceApple: true)
    }

    private func tick() {
        let st = engine.state
        isPlaying = engine.isPlaying
        isBuffering = st == .buffering || st == .opening
        duration = engine.duration
        currentTime = engine.time
        position = engine.position
        if let av = engine as? AVEngine, isLive, timeshiftStart == nil { behindLive = av.behindLive > 8 ? av.behindLive : 0 }

        if !externalCues.isEmpty {
            let t = currentTime
            subtitleText = externalCues.last(where: { $0.start <= t })
                .flatMap { $0.end >= t ? $0.text : nil }
        }

        // automatisch herverbinden
        if st == .error || (isLive && st == .ended) {
            reconnect(reason: st == .error ? L("Stream lost") : nil)
        } else if isBuffering && isLive {
            if stallSince == nil { stallSince = Date() }
            if let s = stallSince, Date().timeIntervalSince(s) > 15 { reconnect(reason: nil) }
        } else if st == .playing {
            stallSince = nil; attempts = 0; reconnecting = false
        }

        if isPlaying && !didScrobbleStart && duration > 0 && !isPreview {
            didScrobbleStart = true
            let it = item, p = position
            Task { await TraktSync.shared.scrobble(.start, item: it, progress: p) }
        }
        if let s = sleepAt, Date() >= s { sleepAt = nil; pause() }
        if Date().timeIntervalSince(lastSaved) > 15 { saveProgress() }
        if !isLive && st == .ended { finish() }
    }

    private func reconnect(reason: String?) {
        guard let url, attempts < 6 else {
            if attempts >= 6 { errorText = L("This stream can't be played right now."); reconnecting = false }
            return
        }
        // Apple-engine faalt → eerst VLC proberen (kan meer formaten aan)
        if usingApple && attempts == 0 && engine.state == .error {
            attempts += 1
            start(url: url, forceApple: false)
            return
        }
        attempts += 1
        reconnecting = true
        stallSince = Date().addingTimeInterval(Double(attempts) * 2)  // backoff
        let resume = position
        let delay = UInt64(min(pow(2.0, Double(attempts - 1)), 8) * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if !self.isLive { self.item.resumeAt = resume }
            self.engine.load(url, live: self.isLive && self.timeshiftStart == nil, startFraction: self.isLive ? nil : resume)
        }
    }

    func togglePlay() { engine.isPlaying ? pause() : resume() }

    func pause() {
        engine.pause()
        if isLive { pausedAt = Date() }
        saveProgress()
        if !isPreview { let it = item, p = position; Task { await TraktSync.shared.scrobble(.pause, item: it, progress: p) } }
    }

    func resume() {
        // Live gepauzeerd met catch-up: verder kijken waar je was (timeshift)
        if isLive, let p = pausedAt, Date().timeIntervalSince(p) > 10, !usingApple, let provider = catchupProvider {
            let from = timeshiftStart.map { $0.addingTimeInterval(currentTime) } ?? p
            if let u = provider(from, Date().addingTimeInterval(3 * 3600)) {
                timeshiftStart = from
                behindLive = Date().timeIntervalSince(from)
                pausedAt = nil
                start(url: u)
                return
            }
        }
        pausedAt = nil
        engine.play()
        if !isPreview { let it = item, p = position; Task { await TraktSync.shared.scrobble(.start, item: it, progress: p) } }
    }

    /// Spoelen. Bij live: binnen het HLS-venster, of via catch-up (timeshift).
    func seek(by seconds: Double) {
        if !isLive { engine.jump(seconds); return }
        if let av = engine as? AVEngine, av.liveWindow > 30 { av.jump(seconds); return }
        guard let provider = catchupProvider else { return }
        let currentWall = timeshiftStart.map { $0.addingTimeInterval(currentTime) } ?? Date()
        let target = min(currentWall.addingTimeInterval(seconds), Date())
        if Date().timeIntervalSince(target) < 10 { goLive(); return }
        if let u = provider(target, Date().addingTimeInterval(3 * 3600)) {
            timeshiftStart = target
            behindLive = Date().timeIntervalSince(target)
            start(url: u)
        }
    }

    func goLive() {
        if let av = engine as? AVEngine, timeshiftStart == nil { av.goLive(); behindLive = 0; return }
        guard timeshiftStart != nil, let u = liveURL ?? item.url else { return }
        timeshiftStart = nil; behindLive = 0
        start(url: u)
    }
    /// De gewone live-URL (om na timeshift terug te keren)
    var liveURL: URL?

    func seek(to fraction: Double) { guard !isLive else { return }; engine.seek(toFraction: fraction) }

    func stop() {
        timer?.invalidate(); timer = nil
        saveProgress()
        if !isPreview { let p = position, it = item; Task { await TraktSync.shared.scrobble(.stop, item: it, progress: p) } }
        engine.stop()
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        position = 1
        saveProgress()
        if !isPreview { let it = item; Task { await TraktSync.shared.scrobble(.stop, item: it, progress: 1) } }
        onFinished?()
    }

    private func saveProgress() {
        lastSaved = Date()
        guard !isPreview, item.type != .live, duration > 60 else { return }
        let store = CloudStore.shared
        if position >= 0.9 {
            store.clearProgress(item.id)
            store.setLocalWatched(item.id, true)
        } else if position > 0.02 {
            store.setProgress(item.id, ProgressEntry(fraction: position, position: currentTime, updated: Date(),
                                                     title: item.title, artwork: item.artwork, playlistID: nil))
        }
    }

    // MARK: sporen & ondertitels

    var audioTracks: [MediaTrack] { engine.audioTracks }
    var subtitleTracks: [MediaTrack] { engine.subtitleTracks }
    var currentAudio: String? { engine.currentAudio }
    var currentSubtitle: String? { externalCues.isEmpty ? engine.currentSubtitle : "ext" }
    var hasExternalSubtitle: Bool { !externalCues.isEmpty }

    func selectAudio(_ t: MediaTrack) { engine.selectAudio(t); objectWillChange.send() }
    func selectSubtitle(_ t: MediaTrack?) {
        externalCues = []; subtitleText = nil
        engine.selectSubtitle(t); objectWillChange.send()
    }

    func addSubtitle(file: URL) {
        if engine.supportsExternalSubtitles {
            engine.addSubtitle(file)
        } else if let d = try? Data(contentsOf: file) {
            engine.selectSubtitle(nil)
            externalCues = SRT.parse(d)
        }
        objectWillChange.send()
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

extension PlayerController.Aspect {
    var title: String {
        switch self { case .fit: return L("Fit"); case .fill: return L("Fill"); case .r169: return "16:9"; case .r43: return "4:3" }
    }
}

extension PlayerController.EngineChoice {
    var title: String {
        switch self {
        case .auto: return L("Automatic")
        case .apple: return L("Apple (HDR, AirPlay)")
        case .vlc: return L("VLC (all formats)")
        }
    }
}

/// Toont de video van de actieve engine.
struct EngineView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    func makeUIView(context: Context) -> UIView {
        let host = UIView(); host.backgroundColor = .black
        attach(controller.engine.view, to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        if controller.engine.view.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            attach(controller.engine.view, to: host)
        }
    }
    private func attach(_ v: UIView, to host: UIView) {
        v.frame = host.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(v)
    }
}
