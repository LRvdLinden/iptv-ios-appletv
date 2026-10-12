import Foundation
import SwiftUI
import AVKit
#if os(tvOS)
import UIKit
#endif

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
    /// Korte melding voor in beeld (bijv. "beeld-in-beeld niet beschikbaar")
    @Published var notice: String?
    @Published private(set) var inPiP = false
    /// Het spelerscherm sluit zich als beeld-in-beeld start; de speler blijft doorlopen.
    var onEnterPiP: (@MainActor () -> Void)?
    private var pendingPiP = 0
    private var restoringFromPiP = false
    private var stopped = false

    /// Echte afspeel-URL (na Stalker/Stremio-resolutie)
    private(set) var url: URL?
    var catchupProvider: (@MainActor (Date, Date) -> URL?)?
    var onFinished: (@MainActor () -> Void)?
    /// Multiview-tegels: geen voortgang/scrobble
    var isPreview = false
    /// Zendervoorbeeld: zonder geluid, lage bitrate, geen beeld-in-beeld en geen schermaanpassing
    var silent = false

    private var timer: Timer?
    private var lastSaved = Date.distantPast
    private var didScrobbleStart = false
    private var stallSince: Date?
    private var attempts = 0
    private var pausedAt: Date?
    private var timeshiftStart: Date?        // begin van de catch-up-stream die nu speelt
    private var externalCues: [SubtitleCue] = []
    private var tracksApplied = false
    private var watchedSeconds: Double = 0
    private var playingTicks = 0

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
        // smb://, ftp://, nfs:// enz. kan alleen VLC openen
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
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
        engine = apple ? AVEngine(silent: silent) : VLCEngine(silent: silent)
        usingApple = apple
        (engine as? AVEngine)?.onPiP = { [weak self] e in self?.handlePiP(e) }
        engine.rate = rate
        engine.muted = muted
        engine.setAspect(aspect)
    }

    // MARK: afspelen

    /// Nieuwe ondertitelgrootte meteen toepassen (Opties tijdens het afspelen).
    func applySubtitleSize() {
        engine.setSubtitleSize(SubtitleSize.current)
        objectWillChange.send()
    }

    /// Spelerscherm is gesloten: een stream die daarna pas klaar is met laden niet meer starten.
    var dismissed = false

    /// Nieuwe titel/zender: niets meenemen van de vorige (timeshift, pauze, herverbind-pogingen, fout).
    func prepareNew() {
        timeshiftStart = nil; behindLive = 0; pausedAt = nil
        attempts = 0; reconnecting = false; errorText = nil; isBuffering = true
        dismissed = false
    }

    /// Kan niet afspelen (geen stream gevonden): foutmelding met "Opnieuw" in plaats van een eindeloze spinner.
    func fail(_ message: String) {
        errorText = message; isBuffering = false; reconnecting = false
    }

    func start(url: URL, forceApple: Bool? = nil) {
        self.url = url
        errorText = nil; didScrobbleStart = false; stallSince = nil
        tracksApplied = false; playingTicks = 0
        #if os(tvOS)
        displayTicks = 0; displayMatched = false
        #endif
        if stopped || timer == nil { watchedSeconds = 0; recordedHistory = false }
        stopped = false
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
            let t = currentTime - subtitleDelay
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
            Task { @MainActor [weak self] in
                // kort laten zien dat Trakt meekijkt (of waarom niet)
                switch await TraktSync.shared.scrobble(.start, item: it, progress: p) {
                case .ok: self?.notice = L("Trakt: watching %@", it.subtitle.map { "\(it.title) · \($0)" } ?? it.title)
                case .notFound: self?.notice = L("Trakt: title not found, not synced")
                case .failed: self?.notice = L("Trakt: could not connect")
                case .skipped: break
                }
            }
        }
        if pendingPiP > 0 {
            pendingPiP += 1
            if let av = engine as? AVEngine, av.pipPossible { pendingPiP = 0; av.startPiP() }
            else if pendingPiP > 30 { pendingPiP = 0; notice = L("Picture in Picture isn't available for this stream.") }
        }
        if st == .playing { watchedSeconds += 0.5 }
        #if os(tvOS)
        // na een seconde echt afspelen: het scherm aanpassen aan framerate en dynamisch bereik van de stream
        if st == .playing && !isPreview && !silent && !displayMatched {
            displayTicks += 1
            if displayTicks >= 2 { matchDisplay() }
        }
        #endif
        if !tracksApplied && st == .playing {
            playingTicks += 1
            // sporen zijn er meestal na een paar tellen; daarna niet meer ingrijpen (jouw eigen keuze blijft staan)
            if !engine.audioTracks.isEmpty || playingTicks > 12 { applyTrackPreferences() }
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

    /// `keepDisplay`: zappen of volgende aflevering — de schermstand niet eerst terugzetten (geen extra knipper).
    func stop(keepDisplay: Bool = false) {
        guard !stopped else { return }
        stopped = true
        #if os(tvOS)
        if !keepDisplay { resetDisplay() }
        #endif
        pendingPiP = 0
        recordHistory()
        timer?.invalidate(); timer = nil
        saveProgress()
        if !isPreview { let p = position, it = item; Task { await TraktSync.shared.scrobble(.stop, item: it, progress: p) } }
        // voortgang bij stoppen meteen naar de Bingr-account
        if !isPreview { StateSync.shared.playbackStopped() }
        engine.stop()
    }

    // MARK: Apple TV: framerate en dynamisch bereik (Match Content)

    #if os(tvOS)
    private var displayTicks = 0
    private var displayMatched = false
    /// Deze sessie heeft de schermstand veranderd (en zet hem bij het stoppen terug)
    private var displayChanged = false

    private static var displayManager: AVDisplayManager? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.avDisplayManager
    }

    /// Werkt alleen als "Pas inhoud aan" (Match Content) in de instellingen van de Apple TV aan staat.
    private func matchDisplay() {
        displayMatched = true
        guard PlayerSettings.matchFrameRate, let dm = Self.displayManager, dm.isDisplayCriteriaMatchingEnabled else { return }
        if let av = engine as? AVEngine {
            if let c = av.displayCriteria() { dm.preferredDisplayCriteria = c; displayChanged = true }
        } else if let vlc = engine as? VLCEngine {
            if let c = vlc.displayCriteria() { dm.preferredDisplayCriteria = c; displayChanged = true }
        }
    }

    private func resetDisplay() {
        guard displayChanged else { return }
        displayChanged = false
        Self.displayManager?.preferredDisplayCriteria = nil
    }
    #endif

    // MARK: beeld-in-beeld

    static var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Start beeld-in-beeld. Bij VLC wordt eerst naar de Apple-speler gewisseld (alleen die kan PiP).
    func startPiP() {
        if let av = engine as? AVEngine {
            if av.pipPossible { av.startPiP() } else { pendingPiP = 1 }
        } else {
            switchToApple()
            pendingPiP = 1
        }
    }

    private func handlePiP(_ e: PiPDelegate.Event) {
        switch e {
        case .willStart:
            inPiP = true
            PiPCenter.shared.active = self
            onEnterPiP?()
        case .restore(let done):
            restoringFromPiP = true
            PiPCenter.shared.restore(self)
            Task { @MainActor in try? await Task.sleep(nanoseconds: 400_000_000); done() }
        case .didStop:
            inPiP = false
            if PiPCenter.shared.active === self { PiPCenter.shared.active = nil }
            if restoringFromPiP { restoringFromPiP = false } else { stop() }   // venster gesloten = stoppen
        case .failed:
            notice = L("Picture in Picture isn't available for this stream.")
        }
    }

    private func finish() {
        recordHistory()
        timer?.invalidate(); timer = nil
        position = 1
        saveProgress()
        if !isPreview { let it = item; Task { await TraktSync.shared.scrobble(.stop, item: it, progress: 1) } }
        if !isPreview { StateSync.shared.playbackStopped() }
        onFinished?()
    }

    /// Na minstens een minuut kijken komt het in de kijkgeschiedenis van dit profiel.
    private var recordedHistory = false
    private func recordHistory() {
        guard !isPreview, !recordedHistory, watchedSeconds >= 60 else { return }
        recordedHistory = true
        let it = item
        CloudStore.shared.addHistory(HistoryEntry(itemID: it.channelID ?? it.id, playlistID: CloudStore.shared.activePlaylistID,
                                                  title: it.title, subtitle: it.subtitle, artwork: it.artwork,
                                                  type: it.type, channelID: it.channelID, date: Date(),
                                                  profileID: CloudStore.shared.activeProfileID))
    }

    private func saveProgress() {
        lastSaved = Date()
        guard !isPreview, item.type != .live, item.channelID == nil, !item.id.contains("-cu-"), duration > 60 else { return }
        let store = CloudStore.shared
        // gezien: bijna uitgekeken, of alleen de aftiteling nog over — per profiel, ook zonder Trakt
        let left = duration - currentTime
        if position >= 0.85 || (duration > 600 && left < 180 && position > 0.7) {
            store.clearProgress(item.id)
            store.setLocalWatched(item.id, true)
            if item.type == .episode, let sid = item.seriesID, let s = item.season, let e = item.episode {
                store.setLocalWatched(CloudStore.episodeKey(series: sid, season: s, episode: e), true)
            }
        } else if position > 0.02 {
            store.setProgress(item.id, ProgressEntry(fraction: position, position: currentTime, updated: Date(),
                                                     title: item.title, artwork: item.artwork, playlistID: store.activePlaylistID,
                                                     profileID: store.activeProfileID))
        }
    }

    // MARK: sporen & ondertitels

    /// Standaard audio-/ondertiteltaal uit de instellingen toepassen.
    private func applyTrackPreferences() {
        tracksApplied = true
        guard !isPreview else { return }
        let audio = TrackPreferences.audio, sub = TrackPreferences.subtitle
        if !audio.isEmpty {
            let tracks = engine.audioTracks.filter { $0.id != "-1" }
            if let t = tracks.first(where: { TrackPreferences.matches($0, code: audio) }), t.id != engine.currentAudio {
                engine.selectAudio(t)
            }
        }
        if sub == "off" {
            if externalCues.isEmpty { engine.selectSubtitle(nil) }
        } else if !sub.isEmpty, externalCues.isEmpty {
            if let t = engine.subtitleTracks.first(where: { TrackPreferences.matches($0, code: sub) }) {
                engine.selectSubtitle(t)
            }
        }
        objectWillChange.send()
    }

    var audioTracks: [MediaTrack] { engine.audioTracks }
    var subtitleTracks: [MediaTrack] { engine.subtitleTracks }
    var currentAudio: String? { engine.currentAudio }
    var currentSubtitle: String? { externalCues.isEmpty ? engine.currentSubtitle : "ext" }
    var hasExternalSubtitle: Bool { !externalCues.isEmpty || externalSubtitleName != nil }
    /// Naam van de laatst ingeladen OpenSubtitles-ondertitel (met vlag)
    @Published private(set) var externalSubtitleName: String?
    /// Verschuiving van de ondertitels in seconden (+ = later tonen)
    @Published var subtitleDelay: Double = 0 { didSet { engine.setSubtitleDelay(subtitleDelay) } }

    func selectAudio(_ t: MediaTrack) { engine.selectAudio(t); objectWillChange.send() }
    func selectSubtitle(_ t: MediaTrack?) {
        externalCues = []; subtitleText = nil; externalSubtitleName = nil
        engine.selectSubtitle(t); objectWillChange.send()
    }

    func addSubtitle(file: URL, name: String? = nil) {
        // altijd als UTF-8 aanbieden (OpenSubtitles levert soms Windows-1252/Latin-1 → rare tekens)
        let utf8 = SRT.normalizedFile(file) ?? file
        if engine.supportsExternalSubtitles {
            engine.addSubtitle(utf8)
        } else if let d = try? Data(contentsOf: utf8) {
            engine.selectSubtitle(nil)
            externalCues = SRT.parse(d)
            subtitleText = nil
        }
        externalSubtitleName = name ?? file.deletingPathExtension().lastPathComponent
        engine.setSubtitleDelay(subtitleDelay)
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

/// Houdt de speler vast zolang die in beeld-in-beeld speelt en zet hem terug in beeld.
@MainActor
final class PiPCenter {
    static let shared = PiPCenter()
    var active: PlayerController?
    /// Speler die het volgende spelerscherm moet overnemen (terug uit beeld-in-beeld)
    private var reuse: PlayerController?
    /// Opent het spelerscherm (ingesteld door AppState)
    var present: ((PlayableItem) -> Void)?

    func restore(_ c: PlayerController) {
        reuse = c
        present?(c.item)
    }
    func takeReuse(for item: PlayableItem) -> PlayerController? {
        defer { reuse = nil }
        return reuse?.item.id == item.id ? reuse : nil
    }
    /// Iets anders gaat spelen: beeld-in-beeld stoppen.
    func stopActive() {
        guard let a = active else { return }
        active = nil
        (a.engine as? AVEngine)?.stopPiP()
        a.stop()
    }
}

/// Toont de video van de actieve engine.
#if os(macOS)
struct EngineView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    var external = false
    /// Klikken gaan naar de SwiftUI-bediening, niet naar VLC/AVPlayer.
    final class Host: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> NSView {
        let host = Host(); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.black.cgColor
        attach(controller.engine.view, to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if controller.engine.view.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            attach(controller.engine.view, to: host)
        }
    }
    private func attach(_ v: NSView, to host: NSView) {
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
    }
}
#else
struct EngineView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    /// iPhone/iPad: met een extern scherm komt het beeld daar (alleen het spelerscherm, niet Multiview of voorbeelden)
    var external = false
    #if os(iOS)
    @ObservedObject private var display = ExternalDisplay.shared
    #endif

    final class Coordinator { weak var engineView: UIView? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(); host.backgroundColor = .black
        host.isUserInteractionEnabled = false   // tikken gaan naar de SwiftUI-bediening, niet naar VLC/AVPlayer
        place(host, context)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        place(host, context)
    }
    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        #if os(iOS)
        if let v = coordinator.engineView { ExternalDisplay.shared.detach(v) }
        #endif
    }
    private func place(_ host: UIView, _ context: Context) {
        let v = controller.engine.view
        context.coordinator.engineView = v
        #if os(iOS)
        if external && display.isConnected {
            display.attach(v)
            return
        }
        #endif
        if v.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            attach(v, to: host)
        }
    }
    private func attach(_ v: UIView, to host: UIView) {
        v.isUserInteractionEnabled = false
        v.frame = host.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(v)
    }
}
#endif
