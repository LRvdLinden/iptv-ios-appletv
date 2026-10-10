import Foundation
import AVFoundation
import AVKit
import UIKit
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

enum EngineState { case idle, opening, buffering, playing, paused, ended, error }

struct MediaTrack: Identifiable, Hashable { var id: String; var name: String }

/// Gemeenschappelijke interface voor de twee afspeel-engines:
/// - **Apple (AVPlayer)**: HDR/Dolby Vision, Atmos, AirPlay, beeld-in-beeld — voor HLS/MP4
/// - **VLC**: alles daarbuiten (.ts, .mkv, AC3/DTS, MAC-portals)
@MainActor
protocol PlaybackEngine: AnyObject {
    var view: UIView { get }
    var state: EngineState { get }
    var isPlaying: Bool { get }
    var position: Double { get }      // 0...1 (0 bij live)
    var time: Double { get }          // seconden
    var duration: Double { get }      // seconden (0 = live)
    var rate: Float { get set }
    var muted: Bool { get set }
    var supportsExternalSubtitles: Bool { get }

    func load(_ url: URL, live: Bool, startFraction: Double?)
    func play()
    func pause()
    func stop()
    func seek(toFraction f: Double)
    func jump(_ seconds: Double)

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var currentAudio: String? { get }
    var currentSubtitle: String? { get }
    func selectAudio(_ t: MediaTrack)
    func selectSubtitle(_ t: MediaTrack?)
    func addSubtitle(_ file: URL)
    func setAspect(_ a: PlayerController.Aspect)
}

// MARK: - VLC -------------------------------------------------------------------

@MainActor
final class VLCEngine: PlaybackEngine {
    private let player = VLCMediaPlayer()
    let view: UIView = { let v = UIView(); v.backgroundColor = .black; return v }()
    private var pendingStart: Double?

    init() { player.drawable = view }

    var state: EngineState {
        switch player.state {
        case .opening: return .opening
        case .buffering: return player.isPlaying ? .playing : .buffering
        case .playing, .esAdded: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .error: return .error
        case .stopped: return .idle
        @unknown default: return .idle
        }
    }
    var isPlaying: Bool { player.isPlaying }
    var duration: Double { Double(player.media?.length.intValue ?? 0) / 1000 }
    var time: Double { Double(player.time.intValue) / 1000 }
    var position: Double { duration > 0 ? Double(player.position) : 0 }
    var rate: Float { get { player.rate } set { player.rate = newValue } }
    var muted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }
    var supportsExternalSubtitles: Bool { true }

    func load(_ url: URL, live: Bool, startFraction: Double?) {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(live ? 1500 : 3000)")
        media.addOption(":http-user-agent=\(Secrets.userAgent)")
        media.addOption(":http-reconnect")
        player.media = media
        pendingStart = startFraction
        player.play()
        if let s = startFraction, s > 0.01 {
            Task { @MainActor in
                for _ in 0..<40 {   // wachten tot de lengte bekend is
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if self.duration > 0 && self.player.isPlaying { self.player.position = Float(s); break }
                }
            }
        }
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    func seek(toFraction f: Double) { player.position = Float(min(max(f, 0), 1)) }
    func jump(_ seconds: Double) {
        if seconds >= 0 { player.jumpForward(Int32(seconds)) } else { player.jumpBackward(Int32(-seconds)) }
    }

    private func tracks(_ names: [Any]?, _ idx: [Any]?) -> [MediaTrack] {
        let n = names?.compactMap { $0 as? String } ?? []
        let i = idx?.compactMap { ($0 as? NSNumber)?.int32Value } ?? []
        return zip(i, n).map { MediaTrack(id: String($0), name: $1) }
    }
    var audioTracks: [MediaTrack] { tracks(player.audioTrackNames, player.audioTrackIndexes) }
    var subtitleTracks: [MediaTrack] { tracks(player.videoSubTitlesNames, player.videoSubTitlesIndexes).filter { $0.id != "-1" } }
    var currentAudio: String? { String(player.currentAudioTrackIndex) }
    var currentSubtitle: String? { player.currentVideoSubTitleIndex == -1 ? nil : String(player.currentVideoSubTitleIndex) }
    func selectAudio(_ t: MediaTrack) { if let i = Int32(t.id) { player.currentAudioTrackIndex = i } }
    func selectSubtitle(_ t: MediaTrack?) { player.currentVideoSubTitleIndex = t.flatMap { Int32($0.id) } ?? -1 }
    func addSubtitle(_ file: URL) { _ = player.addPlaybackSlave(file, type: .subtitle, enforce: true) }

    func setAspect(_ a: PlayerController.Aspect) {
        switch a {
        case .fit: player.videoAspectRatio = nil
        case .fill:
            let b = view.bounds.size == .zero ? CGSize(width: 16, height: 9) : view.bounds.size
            "\(Int(b.width)):\(Int(b.height))".withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        case .r169: "16:9".withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        case .r43: "4:3".withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        }
    }
}

// MARK: - AVPlayer ----------------------------------------------------------------

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor
final class AVEngine: PlaybackEngine {
    let player = AVPlayer()
    private let layerView = PlayerLayerView()
    var view: UIView { layerView }
    private var failed = false
    private var ended = false
    private var observers: [NSObjectProtocol] = []
    private var live = false

    init() {
        layerView.backgroundColor = .black
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #else
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    var state: EngineState {
        if failed || player.currentItem?.status == .failed { return .error }
        if ended { return .ended }
        switch player.timeControlStatus {
        case .playing: return .playing
        case .waitingToPlayAtSpecifiedRate: return .buffering
        case .paused: return player.currentItem?.status == .readyToPlay ? .paused : .opening
        @unknown default: return .idle
        }
    }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var duration: Double {
        guard let d = player.currentItem?.duration, d.isNumeric, !live else { return 0 }
        return d.seconds
    }
    var time: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var position: Double { duration > 0 ? time / duration : 0 }
    var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    var muted: Bool { get { player.isMuted } set { player.isMuted = newValue } }
    var supportsExternalSubtitles: Bool { false }    // via eigen overlay

    /// Hoeveel seconden er bij live terug gespoeld kan worden (HLS-DVR-venster).
    var liveWindow: Double {
        guard let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return 0 }
        return r.duration.seconds.isFinite ? r.duration.seconds : 0
    }
    var behindLive: Double {
        guard let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return 0 }
        return max(0, r.end.seconds - time)
    }

    func load(_ url: URL, live: Bool, startFraction: Double?) {
        failed = false; ended = false; self.live = live
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Secrets.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = live ? 4 : 0
        observers = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.failed = true }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.ended = true }
            }
        ]
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: rate)
        if let s = startFraction, s > 0.01 {
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if self.duration > 0 { self.seek(toFraction: s); break }
                }
            }
        }
    }
    func play() { player.playImmediately(atRate: rate) }
    func pause() { player.pause() }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
    func seek(toFraction f: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * min(max(f, 0), 1), preferredTimescale: 600))
    }
    func jump(_ seconds: Double) {
        let t = CMTime(seconds: max(0, time + seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func goLive() {
        if let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue { player.seek(to: r.end) }
        play()
    }

    private func group(_ c: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: c)
    }
    private func options(_ c: AVMediaCharacteristic) -> [MediaTrack] {
        group(c)?.options.enumerated().map { i, o in MediaTrack(id: "\(i)", name: o.displayName) } ?? []
    }
    var audioTracks: [MediaTrack] { options(.audible) }
    var subtitleTracks: [MediaTrack] { options(.legible) }
    private func current(_ c: AVMediaCharacteristic) -> String? {
        guard let g = group(c), let o = player.currentItem?.currentMediaSelection.selectedMediaOption(in: g),
              let i = g.options.firstIndex(of: o) else { return nil }
        return "\(i)"
    }
    var currentAudio: String? { current(.audible) }
    var currentSubtitle: String? { current(.legible) }
    func selectAudio(_ t: MediaTrack) {
        guard let g = group(.audible), let i = Int(t.id), i < g.options.count else { return }
        player.currentItem?.select(g.options[i], in: g)
    }
    func selectSubtitle(_ t: MediaTrack?) {
        guard let g = group(.legible) else { return }
        if let t, let i = Int(t.id), i < g.options.count { player.currentItem?.select(g.options[i], in: g) }
        else { player.currentItem?.select(nil, in: g) }
    }
    func addSubtitle(_ file: URL) {}

    func setAspect(_ a: PlayerController.Aspect) {
        layerView.playerLayer.videoGravity = a == .fill ? .resizeAspectFill : (a == .fit ? .resizeAspect : .resize)
    }
}

// MARK: - Externe ondertitels (SRT) voor AVPlayer ---------------------------------

struct SubtitleCue: Hashable { var start: Double; var end: Double; var text: String }

enum SRT {
    static func parse(_ data: Data) -> [SubtitleCue] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeLine = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLine].components(separatedBy: "-->")
            guard parts.count == 2, let s = time(parts[0]), let e = time(parts[1]) else { continue }
            let body = lines[(timeLine + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func time(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let p = t.split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2].prefix(6)) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
