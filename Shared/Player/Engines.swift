import Foundation
import AVFoundation
import AVKit
#if os(tvOS)
import UIKit
import TVVLCKit
#elseif os(macOS)
import AppKit
import VLCKit
#else
import UIKit
import MobileVLCKit
#endif

/// Grootte van ondertitels (Mijn Bingr → Speler, en tijdens het afspelen bij Opties).
enum SubtitleSize: Int, CaseIterable {
    case small, medium, large
    static let key = "subtitle.size"
    static var current: SubtitleSize { SubtitleSize(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .small }
    var title: String { switch self { case .small: return L("Small"); case .medium: return L("Medium"); case .large: return L("Large") } }
    /// VLC: percentage van de standaardgrootte (die op een tv erg groot is)
    var vlcScale: Int { switch self { case .small: return 55; case .medium: return 75; case .large: return 100 } }
    /// Apple-speler: relatieve lettergrootte in procenten
    var applePercent: Int { switch self { case .small: return 65; case .medium: return 85; case .large: return 110 } }
    /// Eigen overlay (OpenSubtitles-bestanden bij de Apple-speler)
    var overlayFactor: Double { switch self { case .small: return 0.75; case .medium: return 0.95; case .large: return 1.2 } }
}

enum EngineState { case idle, opening, buffering, playing, paused, ended, error }

struct MediaTrack: Identifiable, Hashable { var id: String; var name: String; var lang: String? = nil }

/// Gekozen ondertitel (build 57), voor Chromecast: een bestand (OpenSubtitles) of een spoor uit de stream.
struct SubtitleChoice: Equatable {
    enum Kind: Equatable {
        case file(URL)
        /// Spoor in de stream; `index` = plaats in de lijst met ondertitelsporen van de speler
        case embedded(index: Int)
    }
    var kind: Kind
    var name: String
    var language: String?
}

/// Gemeenschappelijke interface voor de twee afspeel-engines:
/// - **Apple (AVPlayer)**: HDR/Dolby Vision, Atmos, AirPlay, beeld-in-beeld — voor HLS/MP4
/// - **VLC**: alles daarbuiten (.ts, .mkv, AC3/DTS, MAC-portals)
@MainActor
protocol PlaybackEngine: AnyObject {
    var view: PlatformView { get }
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
    /// Ondertitels verschuiven (seconden); AVPlayer-ondertitels uit de stream kunnen niet verschoven worden.
    func setSubtitleDelay(_ seconds: Double)
    /// Ondertitelgrootte toepassen (VLC laadt de stream op dezelfde plek opnieuw)
    func setSubtitleSize(_ size: SubtitleSize)
}

// MARK: - VLC -------------------------------------------------------------------

@MainActor
final class VLCEngine: PlaybackEngine {
    private let player = VLCMediaPlayer()
    let view: PlatformView = makeBlackView()
    private var pendingStart: Double?
    /// Zendervoorbeeld: zonder geluid
    private let silent: Bool

    /// Zendervoorbeeld: stoppen en een nieuwe stream openen gebeurt hier, niet op de hoofdthread. In VLCKit 3 wacht
    /// `stop` (ook het vervangen van de media) tot de netwerk- en decodeerthreads klaar zijn; dat liet het scrollen haperen.
    private static let previewQueue = DispatchQueue(label: "bingr.preview.vlc", qos: .userInitiated)

    init(silent: Bool = false) {
        self.silent = silent
        player.drawable = view
        #if !os(macOS)
        // na de intro-tune (ambient) weer echte afspeel-audio, ook met de stil-schakelaar aan
        // (niet voor het stille voorbeeld: dat heeft geen geluid, en dit kost tijd op de hoofdthread)
        if !silent {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
    }

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
    /// Het voorbeeld is altijd live (en de media wordt daar op een eigen thread gewisseld): niet uitlezen
    var duration: Double { silent ? 0 : Double(player.media?.length.intValue ?? 0) / 1000 }
    var time: Double { Double(player.time.intValue) / 1000 }
    var position: Double { duration > 0 ? Double(player.position) : 0 }
    var rate: Float { get { player.rate } set { player.rate = newValue } }
    var muted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }
    var supportsExternalSubtitles: Bool { true }

    private var lastURL: URL?
    private var lastLive = false
    /// Build 59: hervatten vanaf deze seconde via `:start-time` (VLC buffert dan niet eerst vanaf het begin)
    var startSeconds: Double?

    func setSubtitleSize(_ size: SubtitleSize) {
        guard let url = lastURL, state == .playing || state == .paused || state == .buffering else { return }
        load(url, live: lastLive, startFraction: lastLive ? nil : position)
    }

    func load(_ url: URL, live: Bool, startFraction: Double?) {
        lastURL = url; lastLive = live
        let media = VLCMedia(url: url)
        // ondertitels: VLC tekent ze standaard erg groot (zeker op een tv)
        media.addOption(":sub-text-scale=\(SubtitleSize.current.vlcScale)")
        media.addOption(":freetype-rel-fontsize=\(SubtitleSize.current == .large ? 16 : SubtitleSize.current == .medium ? 18 : 20)")
        // build 59: kleinere buffer = sneller beeld (was 1500 ms live / 3000 ms films); VLC herverbindt zelf bij haperen.
        // Build 148: live had met 1000 ms te weinig buffer: IPTV-providers leveren een live-TS-stream precies op
        // afspeelsnelheid, dus de buffer groeit na het starten niet meer bij. Na een paar seconden was hij leeg bij het
        // eerste beetje netwerkschommeling (wifi, de provider) en haperde het beeld kort. Apple TV (vast aan de tv,
        // zappen mag iets langer duren) 3000 ms, de rest 2000 ms (zoals vóór build 59 iets ruimer).
        #if os(tvOS)
        let liveCaching = 3000
        #else
        let liveCaching = 2000
        #endif
        media.addOption(":network-caching=\(live ? liveCaching : 1200)")
        media.addOption(":http-user-agent=\(Secrets.userAgent)")
        media.addOption(":http-reconnect")
        if !silent, let audio = TrackPreferences.autoAudio {
            // build 59: meteen het audiospoor in de voorkeurstaal kiezen (instelling, anders de app-taal);
            // build 60: niet bij "zoals in de stream"
            media.addOption(":audio-language=\(TrackPreferences.vlcCodes(audio))")
        }
        let resumeAt = live ? nil : startSeconds.flatMap { $0 > 1 ? $0 : nil }
        startSeconds = nil
        if let r = resumeAt { media.addOption(":start-time=\(Int(r))") }
        if silent {
            media.addOption(":no-audio")
            // voorbeeld in een klein venster: lagere resolutie kiezen (HLS/DASH) en lichter decoderen
            media.addOption(":adaptive-maxheight=576")
            media.addOption(":avcodec-skiploopfilter=4")
        }
        // deinterlacing (build 52): Mijn Bingr → Speler; standaard automatisch
        let deint = DeinterlaceMode.current
        for o in deint.vlcOptions { media.addOption(o) }
        let deintSel = NSSelectorFromString("setDeinterlaceFilter:")
        // aan/uit ook rechtstreeks op de speler; "automatisch" alleen via de media-optie (nil zou het uitzetten)
        if deint != .auto, player.responds(to: deintSel) {
            player.perform(deintSel, with: deint == .on ? "yadif2x" as NSString : nil)
        }
        // ook de tekstweergave van VLC zelf (iOS/tvOS); hoger getal = kleiner
        let sel = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: sel) {
            player.perform(sel, with: NSNumber(value: SubtitleSize.current == .large ? 16 : SubtitleSize.current == .medium ? 18 : 20))
        }
        if silent {
            let p = player
            Self.previewQueue.async {
                p.media = media
                p.play()
            }
            return
        }
        player.media = media
        pendingStart = startFraction
        player.play()
        if resumeAt == nil, let s = startFraction, s > 0.01 {
            Task { @MainActor [weak self] in
                for _ in 0..<40 {   // wachten tot de lengte bekend is
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    // build 60: intussen een andere stream geladen (zappen, volgende aflevering): niet op die spoelen
                    guard let self, self.player.media === media else { return }
                    if self.duration > 0 && self.player.isPlaying { self.player.position = Float(s); break }
                }
            }
        }
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() {
        if silent {
            let p = player
            Self.previewQueue.async { p.stop() }
        } else {
            player.stop()
        }
    }
    func seek(toFraction f: Double) { player.position = Float(min(max(f, 0), 1)) }
    func jump(_ seconds: Double) {
        if seconds >= 0 { player.jumpForward(Int32(seconds)) } else { player.jumpBackward(Int32(-seconds)) }
    }

    private func tracks(_ names: [Any]?, _ idx: [Any]?) -> [MediaTrack] {
        let n = names?.compactMap { $0 as? String } ?? []
        let i = idx?.compactMap { ($0 as? NSNumber)?.int32Value } ?? []
        return zip(i, n).map { MediaTrack(id: String($0), name: $1) }
    }
    /// Zonder "Uitschakelen" (-1): die keuze zette het geluid uit in plaats van een andere taal te kiezen
    var audioTracks: [MediaTrack] { tracks(player.audioTrackNames, player.audioTrackIndexes).filter { $0.id != "-1" } }
    var subtitleTracks: [MediaTrack] { tracks(player.videoSubTitlesNames, player.videoSubTitlesIndexes).filter { $0.id != "-1" } }
    var currentAudio: String? { String(player.currentAudioTrackIndex) }
    var currentSubtitle: String? { player.currentVideoSubTitleIndex == -1 ? nil : String(player.currentVideoSubTitleIndex) }
    // build 148: alleen wisselen als het spoor echt anders is: een spoorwissel (ook naar hetzelfde spoor) laat VLC de
    // stroom opnieuw kiezen, en dat gaf bij live een korte hapering een paar seconden na de start
    func selectAudio(_ t: MediaTrack) {
        if let i = Int32(t.id), player.currentAudioTrackIndex != i { player.currentAudioTrackIndex = i }
    }
    func selectSubtitle(_ t: MediaTrack?) {
        let i = t.flatMap { Int32($0.id) } ?? -1
        if player.currentVideoSubTitleIndex != i { player.currentVideoSubTitleIndex = i }
    }
    func addSubtitle(_ file: URL) { _ = player.addPlaybackSlave(file, type: .subtitle, enforce: true) }
    func setSubtitleDelay(_ seconds: Double) { player.currentVideoSubTitleDelay = Int(seconds * 1_000_000) }

    #if os(tvOS)
    /// Schermstand voor de stream (framerate uit de VLC-sporen; VLC speelt altijd SDR af).
    func displayCriteria() -> AVDisplayCriteria? {
        guard let info = player.media?.tracksInformation as? [[String: Any]] else { return nil }
        for t in info where (t["type"] as? String) == "video" {
            let num = (t["frame_rate_num"] as? NSNumber)?.doubleValue ?? 0
            let den = (t["frame_rate_den"] as? NSNumber)?.doubleValue ?? 0
            guard num > 0, den > 0 else { continue }
            let fps = Float(num / den)
            guard fps > 10, fps < 130 else { continue }
            let w = Int32((t["width"] as? NSNumber)?.intValue ?? 1920)
            let h = Int32((t["height"] as? NSNumber)?.intValue ?? 1080)
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                                           width: max(w, 16), height: max(h, 16), extensions: nil, formatDescriptionOut: &fd)
            guard let fd else { return nil }
            return AVDisplayCriteria(refreshRate: fps, formatDescription: fd)
        }
        return nil
    }
    #endif

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

#if os(macOS)
/// Mac: view met een AVPlayerLayer als eigen laag.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var backgroundColor: NSColor? { didSet { playerLayer.backgroundColor = backgroundColor?.cgColor } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = playerLayer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}
#else
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif

@MainActor
final class AVEngine: PlaybackEngine {
    let player = AVPlayer()
    private let layerView = PlayerLayerView()
    var view: PlatformView { layerView }
    private var failed = false
    private var ended = false
    private var observers: [NSObjectProtocol] = []
    private var live = false
    /// Beeld-in-beeld (iPhone, iPad en Apple TV)
    private(set) var pip: AVPictureInPictureController?
    private let pipDelegate = PiPDelegate()
    /// Zendervoorbeeld: zonder geluid, lage bitrate, geen AirPlay en geen beeld-in-beeld
    private let silent: Bool
    /// Build 60: audio- en ondertitelgroepen, asynchroon geladen per stream. De oude synchrone API
    /// (`mediaSelectionGroup(forMediaCharacteristic:)`) is verouderd en kon de hoofdthread laten wachten.
    private var groups: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
    private var groupsTask: Task<Void, Never>?
    /// De geladen stream: bij stoppen of een nieuwe stream het laden afbreken (open HTTP-verzoeken naar de provider dicht)
    private var asset: AVURLAsset?

    init(silent: Bool = false) {
        self.silent = silent
        layerView.backgroundColor = .black
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
        player.allowsExternalPlayback = !silent
        player.isMuted = silent
        if silent { return }
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: layerView.playerLayer)
            pip?.delegate = pipDelegate
            #if os(iOS)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true   // naar het beginscherm = beeld-in-beeld
            #endif
        }
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #elseif os(tvOS)
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
        // vorige stream (zappen, nieuwe poging) eerst echt loslaten
        self.asset?.cancelLoading()
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        // build 148: live automatisch (0): met maar 4 s vooruit kon AVPlayer bij HLS met segmenten van 6–10 s het
        // volgende segment pas laden als de buffer bijna leeg was, en haperde het na ±5 s. Het live-venster van de
        // afspeellijst begrenst de buffer zelf al.
        #if os(tvOS)
        // build 143: Apple TV (weinig geheugen): films/series niet onbeperkt vooruit bufferen (0 = automatisch, kan groot worden)
        item.preferredForwardBufferDuration = live ? 0 : 30
        #else
        item.preferredForwardBufferDuration = 0
        #endif
        player.automaticallyWaitsToMinimizeStalling = true
        if silent {
            item.preferredPeakBitRate = 2_500_000
            item.preferredMaximumResolution = CGSize(width: 960, height: 540)
            player.isMuted = true
        }
        item.textStyleRules = Self.textRules(SubtitleSize.current)
        if !silent, let audio = TrackPreferences.autoAudio {
            // build 59: audio in de voorkeurstaal (instelling, anders de app-taal) als de stream die heeft;
            // build 60: niet bij "zoals in de stream"
            let criteria = AVPlayerMediaSelectionCriteria(preferredLanguages: [audio],
                                                          preferredMediaCharacteristics: nil)
            player.setMediaSelectionCriteria(criteria, forMediaCharacteristic: .audible)
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.failed = true }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.ended = true }
            }
        ]
        player.replaceCurrentItem(with: item)
        loadGroups(asset, for: item)
        // build 148: live met `play` (wacht tot er genoeg gebufferd is), niet `playImmediately`: dat start ook met een
        // bijna lege buffer en gaf bij live na een paar seconden een hapering
        if live { player.rate = rate; return }
        guard let s = startFraction, s > 0.01 else { player.playImmediately(atRate: rate); return }
        // build 59: hervatten — eerst naar de positie, dan pas afspelen (niet eerst het begin laden en tonen)
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard let self, self.player.currentItem === item else { return }
                if self.duration > 0 {
                    let tol = CMTime(seconds: 2, preferredTimescale: 600)
                    self.player.seek(to: CMTime(seconds: self.duration * s, preferredTimescale: 600),
                                     toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.player.currentItem === item else { return }
                            self.player.playImmediately(atRate: self.rate)
                        }
                    }
                    return
                }
                if item.status == .failed { self.player.playImmediately(atRate: self.rate); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, self.player.currentItem === item else { return }
            self.player.playImmediately(atRate: self.rate)
        }
    }
    func play() { if live { player.rate = rate } else { player.playImmediately(atRate: rate) } }
    func pause() { player.pause() }
    func stop() {
        player.pause(); player.replaceCurrentItem(with: nil)
        asset?.cancelLoading(); asset = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        groupsTask?.cancel(); groupsTask = nil
        groups = [:]
    }

    /// Audio- en ondertitelgroepen van deze stream op de achtergrond laden (build 60).
    private func loadGroups(_ asset: AVURLAsset, for item: AVPlayerItem) {
        groupsTask?.cancel()
        groups = [:]
        // zendervoorbeeld: geen sporen nodig
        guard !silent else { return }
        groupsTask = Task { @MainActor [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, !Task.isCancelled, self.player.currentItem === item else { return }
            var g: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
            if let audible { g[.audible] = audible }
            if let legible { g[.legible] = legible }
            self.groups = g
        }
    }

    #if os(tvOS)
    /// Schermstand voor de stream: framerate en formaat (incl. HDR/Dolby Vision) van het videospoor; anders
    /// wat het bestand zelf aangeeft.
    func displayCriteria() -> AVDisplayCriteria? {
        guard let item = player.currentItem else { return nil }
        for t in item.tracks {
            guard let a = t.assetTrack, a.mediaType == .video else { continue }
            let fps = t.currentVideoFrameRate > 0 ? t.currentVideoFrameRate : a.nominalFrameRate
            guard fps > 10, let raw = a.formatDescriptions.first else { continue }
            let fd = raw as! CMFormatDescription
            return AVDisplayCriteria(refreshRate: fps, formatDescription: fd)
        }
        return item.asset.preferredDisplayCriteria
    }
    #endif
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

    var pipPossible: Bool { pip?.isPictureInPicturePossible ?? false }
    var pipActive: Bool { pip?.isPictureInPictureActive ?? false }
    func startPiP() { pip?.startPictureInPicture() }
    func stopPiP() { pip?.stopPictureInPicture() }
    /// Wordt aangeroepen bij start/stop en bij "terug naar de app" vanuit het beeld-in-beeldvenster.
    var onPiP: ((PiPDelegate.Event) -> Void)? {
        get { pipDelegate.handler }
        set { pipDelegate.handler = newValue }
    }

    private func group(_ c: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        player.currentItem == nil ? nil : groups[c]
    }
    private func options(_ c: AVMediaCharacteristic) -> [MediaTrack] {
        group(c)?.options.enumerated().map { i, o in
            MediaTrack(id: "\(i)", name: o.displayName, lang: o.extendedLanguageTag ?? o.locale?.language.languageCode?.identifier)
        } ?? []
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
    // build 148: alleen wisselen als het spoor echt anders is (een mediaselectie leegt bij HLS de buffer; bij live gaf
    // dat een hapering een paar seconden na de start, als de voorkeurssporen werden toegepast)
    func selectAudio(_ t: MediaTrack) {
        guard let g = group(.audible), let i = Int(t.id), i < g.options.count, let item = player.currentItem else { return }
        if item.currentMediaSelection.selectedMediaOption(in: g) == g.options[i] { return }
        item.select(g.options[i], in: g)
    }
    func selectSubtitle(_ t: MediaTrack?) {
        guard let g = group(.legible), let item = player.currentItem else { return }
        let current = item.currentMediaSelection.selectedMediaOption(in: g)
        if let t, let i = Int(t.id), i < g.options.count {
            if current != g.options[i] { item.select(g.options[i], in: g) }
        } else if current != nil {
            item.select(nil, in: g)
        }
    }
    func addSubtitle(_ file: URL) {}
    func setSubtitleDelay(_ seconds: Double) {}   // externe ondertitels: via de eigen overlay
    func setSubtitleSize(_ size: SubtitleSize) { player.currentItem?.textStyleRules = Self.textRules(size) }
    static func textRules(_ size: SubtitleSize) -> [AVTextStyleRule] {
        AVTextStyleRule(textMarkupAttributes: [kCMTextMarkupAttribute_RelativeFontSize as String: size.applePercent]).map { [$0] } ?? []
    }

    func setAspect(_ a: PlayerController.Aspect) {
        layerView.playerLayer.videoGravity = a == .fill ? .resizeAspectFill : (a == .fit ? .resizeAspect : .resize)
    }
}

final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    enum Event { case willStart, didStop, restore(() -> Void), failed }
    var handler: ((Event) -> Void)?

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        let h = handler; DispatchQueue.main.async { h?(.willStart) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        let h = handler; DispatchQueue.main.async { h?(.didStop) }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let h = handler; DispatchQueue.main.async { h?(.failed) }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        let h = handler
        DispatchQueue.main.async {
            if let h { h(.restore { completion(true) }) } else { completion(true) }
        }
    }
}

// MARK: - Externe ondertitels (SRT) voor AVPlayer ---------------------------------

struct SubtitleCue: Hashable { var start: Double; var end: Double; var text: String }

enum SRT {
    /// Tekst uit een ondertitelbestand: UTF-8 (met/zonder BOM), UTF-16, anders Windows-1252/Latin-1.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s.replacingOccurrences(of: "\u{FEFF}", with: "") }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Schrijft een UTF-8-kopie naast het origineel (VLC en de eigen overlay lezen dan altijd goed).
    static func normalizedFile(_ file: URL) -> URL? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        if String(data: d, encoding: .utf8) != nil, !d.starts(with: [0xEF, 0xBB, 0xBF]) { return file }
        let out = file.deletingPathExtension().appendingPathExtension("utf8.srt")
        guard (try? Data(decode(d).utf8).write(to: out)) != nil else { return nil }
        return out
    }

    static func parse(_ data: Data) -> [SubtitleCue] {
        let text = decode(data).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // blokken scheiden op lege regels (ook regels met alleen spaties)
        var blocks: [[String]] = [], cur: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if !cur.isEmpty { blocks.append(cur); cur = [] } }
            else { cur.append(line) }
        }
        if !cur.isEmpty { blocks.append(cur) }
        var cues: [SubtitleCue] = []
        for lines in blocks {
            guard let timeLine = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLine].components(separatedBy: "-->")
            guard parts.count == 2, let s = time(parts[0]), let e = time(parts[1]) else { continue }
            let body = lines[(timeLine + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func time(_ s: String) -> Double? {
        // "00:00:05,000 X1:100 …" → alleen de tijd
        let first = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let t = first.replacingOccurrences(of: ",", with: ".")
        let p = t.split(separator: ":")
        // WebVTT mag de uren weglaten ("01:02.500")
        if p.count == 2, let m = Double(p[0]), let sec = Double(p[1].prefix(6)) { return m * 60 + sec }
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2].prefix(6)) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
