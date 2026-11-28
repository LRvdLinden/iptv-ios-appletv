import Foundation
import SwiftUI
import AVKit
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Stuurt één afspeelsessie aan: kiest de engine (Apple of VLC), herverbindt
/// automatisch, doet timeshift bij live, bewaart voortgang en scrobblet naar Trakt.
@MainActor
final class PlayerController: ObservableObject {
    enum EngineChoice: String, CaseIterable { case auto, apple, vlc }
    enum Aspect: String, CaseIterable { case fit, fill, r169, r43 }

    @Published var item: PlayableItem {
        // build 154: ander item (zappen, volgende aflevering): de gezien-grens opnieuw
        didSet { if item.id != oldValue.id { reachedWatched = false } }
    }
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
    /// build 97: deze speler houdt nu het scherm wakker (geen slaapstand/schermbeveiliging tijdens het afspelen)
    private var holdsAwake = false
    /// build 97: het profiel dat keek toen het afspelen begon; voortgang en geschiedenis gaan daarheen, ook als er
    /// intussen (bijv. tijdens beeld-in-beeld) een ander profiel gekozen is
    private var playbackProfileID: UUID?

    /// Echte afspeel-URL (na Stalker/Stremio-resolutie)
    private(set) var url: URL?
    var catchupProvider: (@MainActor (Date, Date) -> URL?)?
    /// Build 194: terugkijken uit de gids: nieuwe URL vanaf een ander punt van het programma (spoelen)
    var replayProvider: (@MainActor (Date, Date) -> URL?)?
    /// Build 194: seconden vanaf het begin van het programma waar de huidige stream begint
    private var replayBase: Double = 0
    /// Build 194: gekozen doel tijdens het opnieuw laden (zodat de balk niet terugspringt) en wanneer dat begon
    private var replayPending: Double?
    private var replayPendingAt = Date.distantPast
    private var replaySeekTask: Task<Void, Never>?
    /// Build 194: speelt dit een terugkijkprogramma uit de gids (met bekende begin- en eindtijd)?
    var isReplay: Bool { item.replayStart != nil && item.replayEnd != nil && item.type != .live }
    private var replayLength: Double {
        guard let a = item.replayStart, let b = item.replayEnd else { return 0 }
        return Replay194.duration(start: a.timeIntervalSince1970, end: b.timeIntervalSince1970)
    }
    private var replayLimit: Double {
        guard let a = item.replayStart, let b = item.replayEnd else { return 0 }
        return Replay194.limit(start: a.timeIntervalSince1970, end: b.timeIntervalSince1970, now: Date().timeIntervalSince1970)
    }
    var onFinished: (@MainActor () -> Void)?
    /// Multiview-tegels: geen voortgang/scrobble
    var isPreview = false
    /// Zendervoorbeeld: zonder geluid, lage bitrate, geen beeld-in-beeld en geen schermaanpassing
    var silent = false

    private var timer: Timer?
    private var lastSaved = Date.distantPast
    /// Build 154: lokaal als gezien gemarkeerd (zelfde grens voor Trakt: de scrobble-stop gaat anders onder de 80%)
    private var reachedWatched = false
    private var backgroundObserver: NSObjectProtocol?
    private var didScrobbleStart = false
    private var stallSince: Date?
    private var attempts = 0
    private var pausedAt: Date?
    private var timeshiftStart: Date?        // begin van de catch-up-stream die nu speelt
    private var externalCues: [SubtitleCue] = []
    /// Ingeladen ondertitelbestand (OpenSubtitles), UTF-8; ook nodig voor Chromecast en AirPlay (build 57)
    private(set) var externalSubtitleFile: URL?
    /// Taalcode van dat bestand (bijv. "nl", "pt-BR"), als bekend
    private(set) var externalSubtitleLanguage: String?
    /// AirPlay met eigen ondertitels: de Apple-speler speelt een eigen HLS-afspeellijst met ondertitelspoor (build 57)
    private var airPlayWrapped = false
    private var airPlayWrapBusy = false
    private var airPlayWrapTries = 0
    private var airPlaySelectPending = 0
    private var wasExternalPlayback = false
    /// Ondertitelspoor van de vorige engine, opnieuw kiezen zodra de sporen bekend zijn (build 57)
    private var carrySubtitle: MediaTrack?
    /// Verschuiving veranderd terwijl de eigen afspeellijst speelt: ondertitels opnieuw maken
    private var airPlayNeedsRewrap = false
    /// Deze speler deelt bestanden op de lokale server (bij stoppen weer weghalen)
    private var airPlayServing = false
    /// Build 179: voor deze AirPlay-route al naar de Apple-speler gewisseld (niet heen en weer)
    private var airPlay179Done = false
    private var tracksApplied = false
    private var watchedSeconds: Double = 0
    /// Build 164: tellen voor het stilstaande beeld van de tv-gids
    private var stillTicks = 0
    private var playingTicks = 0
    /// Build 179: automatisch een andere speler proberen (docs/ACCOUNT.md → "Build 179", punt 3)
    private var sw179Start = Date()
    private var sw179FirstFrame = false
    private var sw179Played: Double = 0
    private var sw179StallSince: Date?
    private var sw179Switched = false
    /// engine waarmee deze stream begon ("apple"/"vlc") en of hij al onthouden is
    private var sw179Started = "apple"
    private var sw179Remembered: String?
    private var sw179Settled = false
    /// Foutherstel (build 52): de andere engine al geprobeerd, en of er een herlaadpoging loopt
    private var triedOtherEngine = false
    private var reloadPending = false
    private var stableTicks = 0
    /// Build 179 (X2): elke (her)start, halt en stop krijgt een nieuw nummer; een uitgestelde herlaadpoging van daarvoor
    /// vervalt dan (anders opende een stilgezet voorbeeld na `halt()` alsnog een verbinding die niemand meer sloot)
    private var loadEpoch = 0
    /// Build 179 (X2): moment van het laatste (her)laden, en of de speler sindsdien "afgelopen/fout" verlaten heeft
    private var loadedAt = Date.distantPast
    private var leftTerminal = false
    /// Build 179 (X2): seconden beeld sinds het laatste (her)laden, en of deze titel/zender ooit beeld had
    private var playedSinceLoad: Double = 0
    private var hadPicture = false
    /// Build 179 (X2): begin van de lopende storing (eerste herverbindpoging); nil = geen storing
    private var outageSince: Date?
    /// Build 179 (X2): een verse link ophalen vóór het herverbinden (MAC-portal: de link is maar één keer geldig)
    var refreshURL: (@MainActor () async -> URL?)?
    /// Laatst bekende afspeelpositie (0...1) — na een fout verder op dezelfde plek
    private(set) var lastGoodPosition: Double = 0
    /// Afspelen lukt niet (ook niet na één stille nieuwe poging). `true` = afgehandeld (bijv. overgeschakeld
    /// naar een andere bron); anders verschijnt de foutmelding met Opnieuw / Andere bron / Andere speler.
    var onGiveUp: (@MainActor () -> Bool)?
    /// Limiet van de IPTV-provider controleren als het afspelen mislukt: geeft een melding als alle verbindingen van
    /// de provider (Xtream) in gebruik zijn, anders nil. Staat los van de streamlimiet van Bingr.
    var providerLimitCheck: (@MainActor () async -> String?)?

    static var choice: EngineChoice {
        EngineChoice(rawValue: UserDefaults.standard.string(forKey: "player.engine") ?? "") ?? .auto
    }

    /// `silent`: zendervoorbeeld — meteen een stille engine (zonder het instellen van de audiosessie op de hoofdthread)
    init(item: PlayableItem, silent: Bool = false) {
        self.item = item
        self.silent = silent
        // build 59: meteen de engine die deze stream waarschijnlijk gebruikt; `start` hergebruikt hem dan in plaats
        // van eerst een VLC-speler te maken en die direct weer weg te gooien
        let apple = !silent && (item.url.map(Self.prefersApple) ?? false)
        engine = apple ? AVEngine(silent: silent) : VLCEngine(silent: silent)
        usingApple = apple
        freshEngine = true
        (engine as? AVEngine)?.onPiP = { [weak self] e in self?.handlePiP(e) }
    }

    /// De engine uit `init` is nog niet gebruikt
    private var freshEngine = false
    /// Build 148: haperingen na het eerste beeld (diagnose, `playback_stall`)
    private var stallTracker = StallTracker()
    /// Build 59: wacht na de start op het eerste beeld (spinner meteen weg, tijdmeting)
    private var startWatch: Task<Void, Never>?
    /// Build 59: OpenSubtitles nodig in deze taal (het spelerscherm haalt ze op de achtergrond op)
    var onNeedSubtitles: (@MainActor (String) -> Void)?
    private var subtitleCheck: Task<Void, Never>?
    /// Voor welke titel de automatische ondertitels al bekeken zijn (één keer per titel, niet na elke herverbinding)
    private var autoSubtitlesFor: String?
    /// build 91: zelf een ondertitel gekozen (of uitgezet) voor deze titel: de automatische ondertitels niet meer aanzetten
    private(set) var userPickedSubtitle = false

    var isLive: Bool { item.type == .live }
    /// Build 179: live, maar achter het live-punt (terugkijken/timeshift of gepauzeerd)
    var isTimeshifting179: Bool { isLive && (timeshiftStart != nil || pausedAt != nil) }
    var canTimeshift: Bool { isLive && (catchupProvider != nil || ((engine as? AVEngine)?.liveWindow ?? 0) > 30) }

    // MARK: engine kiezen

    private static func prefersApple(_ url: URL) -> Bool {
        // smb://, ftp://, nfs:// enz. kan alleen VLC openen
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        // gedownloade HLS-pakketten (build 52) kan alleen de Apple-speler afspelen
        if url.pathExtension.lowercased() == "movpkg" { return true }
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
        hadPicture = false; outageSince = nil   // build 179
        dismissed = false
        backgroundResume = nil; pauseWhenReady = false
        triedOtherEngine = false; reloadPending = false; lastGoodPosition = 0
        sw179Switched = false; sw179Remembered = nil   // build 179: nieuwe stream
        // ondertitels van de vorige titel niet meenemen
        externalCues = []; subtitleText = nil; externalSubtitleName = nil
        externalSubtitleFile = nil; externalSubtitleLanguage = nil
        airPlayWrapTries = 0
        // build 59: niets van de vorige titel gebruiken om te hervatten (duur) of voor ondertitels
        duration = 0; position = 0; currentTime = 0
        replayBase = 0; replayPending = nil; replaySeekTask?.cancel(); replaySeekTask = nil   // build 194
        subtitleCheck?.cancel(); subtitleCheck = nil
        // build 60: ook geen ondertitelspoor van de vorige titel, en opnieuw beginnen ("Opnieuw" na een fout) haalt
        // de automatische ondertitels opnieuw op (de ingeladen ondertitels zijn hierboven gewist)
        carrySubtitle = nil
        autoSubtitlesFor = nil
        userPickedSubtitle = false
    }

    /// Opnieuw beginnen met foutherstel (andere bron of andere speler gekozen).
    func resetRecovery() {
        attempts = 0; reconnecting = false; errorText = nil; isBuffering = true
        triedOtherEngine = false; reloadPending = false; stallSince = nil
        outageSince = nil   // build 179
    }

    /// Andere speler (VLC ↔ Apple) op dezelfde positie.
    func switchEngine() {
        guard let url else { return }
        sw179Switched = true   // build 179: handmatig gewisseld: niet nog eens automatisch
        if !isLive { item.resumeAt = lastGoodPosition > 0.01 ? lastGoodPosition : item.resumeAt }
        resetRecovery()
        triedOtherEngine = true
        start(url: url, forceApple: !usingApple)
    }

    /// Spoelen naar een tijdstip in seconden (intro overslaan).
    func seek(toSeconds t: Double) {
        if isReplay { replaySeek(to: t); return }   // build 194
        guard !isLive, duration > 0 else { return }
        engine.seek(toFraction: min(max(t / duration, 0), 1))
    }

    /// Kan niet afspelen (geen stream gevonden): foutmelding met "Opnieuw" in plaats van een eindeloze spinner.
    func fail(_ message: String) {
        errorText = message; isBuffering = false; reconnecting = false
    }

    func start(url: URL, forceApple: Bool? = nil) {
        self.url = url
        errorText = nil; didScrobbleStart = false; stallSince = nil; reloadPending = false; stableTicks = 0
        tracksApplied = false; playingTicks = 0
        markLoaded()   // build 179
        stallTracker = StallTracker()
        #if os(tvOS)
        displayTicks = 0; displayMatched = false
        #endif
        if stopped || timer == nil {
            watchedSeconds = 0; recordedHistory = false
            // build 97: nieuwe afspeelsessie: het profiel van nu vastleggen
            playbackProfileID = CloudStore.shared.activeProfileID
            // build 128: meta van wat er speelt (titel, aflevering, zender) meeschrijven voor "één lijst over alle servers"
            if !isPreview { CrossServer.shared.notePlayed(item) }
        }
        stopped = false
        var apple = forceApple ?? Self.prefersApple(url)
        // build 179: per stream onthouden speler eerst (als beide engines dit adres kunnen openen)
        if forceApple == nil, sw179Eligible(url) {
            let order = apple ? ["apple", "vlc"] : ["vlc", "apple"]
            let remembered = EngineMemo179.get(sw179Key)
            sw179Remembered = remembered
            apple = Build179.firstEngine(order: order, remembered: remembered) == "apple"
        }
        // gedwongen engine (automatisch of handmatig gewisseld, AirPlay): niet nog eens automatisch wisselen
        if forceApple != nil { sw179Switched = true }
        sw179Start = Date(); sw179FirstFrame = false; sw179Played = 0; sw179StallSince = nil; sw179Settled = false
        if !sw179Switched { sw179Started = apple ? "apple" : "vlc" }
        let switching = apple != usingApple
        // zendervoorbeeld na `halt()`: dezelfde engine (en weergave) hergebruiken in plaats van een nieuwe te maken;
        // de nog ongebruikte engine uit `init` ook (build 59)
        let reuseFresh = freshEngine && !switching
        if !reuseFresh && (switching || (timer == nil && !keepEngine)) { makeEngine(apple: apple) }
        freshEngine = false
        keepEngine = false
        airPlayWrapped = false; airPlaySelectPending = 0
        // build 59: VLC hervat meteen op de juiste seconde (`:start-time`) in plaats van eerst vanaf het begin te bufferen
        if let v = engine as? VLCEngine {
            // build 177: voorbeeld (ook in de tv-gids): VLC stopt en opent streams buiten de hoofdthread
            if isPreview { v.offMain = true }
            var secs: Double?
            if !isLive, !isReplay, item.resumeAt > 0.01 { secs = duration > 0 ? item.resumeAt * duration : item.resumeSeconds }
            v.startSeconds = secs
        }
        if !isPreview && !silent { PlaybackTiming.mark("engine.load (\(apple ? "Apple" : "VLC"))") }
        engine.load(url, live: isLive && timeshiftStart == nil, startFraction: (isLive || isReplay) ? nil : item.resumeAt)
        watchFirstFrame()
        // andere engine (bijv. VLC → Apple voor AirPlay): ingeladen ondertitels meenemen (build 57)
        if switching, let f = externalSubtitleFile { applyExternalSubtitle(f) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            // build 60: speler opgeruimd zonder `stop()` (bijv. een tegel of voorbeeld): de timer niet eeuwig laten lopen
            guard self != nil else { t.invalidate(); return }
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Build 179 (X2): er wordt (opnieuw) geladen: eerdere uitgestelde pogingen vervallen, het respijt begint opnieuw.
    private func markLoaded() {
        loadEpoch += 1
        loadedAt = Date(); leftTerminal = false; playedSinceLoad = 0
    }

    /// Build 179 (X2): reden van een stop of onderbreking bewaren voor Diagnose (niet voor voorbeelden).
    func noteStop(_ reason: Stream179.Reason) {
        guard !isPreview, !silent else { return }
        StopLog179.shared.note(reason, after: playedSinceLoad, engine: usingApple ? "apple" : "vlc",
                               format: PlaybackLog.format(url), live: isLive)
    }

    /// Build 59: zo snel mogelijk merken dat het beeld er is (de gewone tick is maar elke halve seconde):
    /// spinner weg en de starttijd loggen.
    private func watchFirstFrame() {
        startWatch?.cancel()
        let log = !isPreview && !silent
        startWatch = Task { @MainActor [weak self] in
            for _ in 0..<300 {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                if self.engine.state == .playing && self.engine.isPlaying {
                    if self.isBuffering { self.isBuffering = false }
                    if !self.isPlaying { self.isPlaying = true }
                    self.updateAwake()
                    if log { PlaybackTiming.end("first frame (\(self.usingApple ? "Apple" : "VLC"))") }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    #if os(iOS)
    /// Build 179: AirPlay-video, ook naar CarPlay als de auto stilstaat (iOS 26). Wordt er een AirPlay-route actief
    /// (Bedieningspaneel, de auto of de AirPlay-knop) terwijl VLC speelt, dan naar de Apple-speler op dezelfde positie:
    /// alleen die stuurt video via AirPlay (`allowsExternalPlayback`). `start` sluit VLC eerst (geen tweede verbinding).
    /// CarPlay-audio tijdens het rijden is geen AirPlay en wisselt niet. true = er is gewisseld.
    private func checkAirPlayVideo179() -> Bool {
        guard !isPreview, !silent, !stopped else { return false }
        // met de Apple-speler alleen bijhouden of de route weer weg is (dan mag een volgende AirPlay-route weer wisselen)
        if usingApple && !airPlay179Done { return false }
        let air = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        if !air { airPlay179Done = false; return false }
        guard let url, errorText == nil,
              Duo179.switchForAirPlay(usingApple: usingApple, airPlay: air, alreadyForThisRoute: airPlay179Done,
                                      preview: isPreview || silent,
                                      appleCanOpen: Duo179.appleCanOpen(scheme: url.scheme, isFile: url.isFileURL))
        else { return false }
        airPlay179Done = true
        if !isPreview && !silent { PlaybackTiming.mark("AirPlay: VLC → Apple") }
        switchToApple()
        return true
    }
    #endif

    /// Wisselt naar de Apple-engine (voor AirPlay) op dezelfde positie.
    func switchToApple() {
        guard !usingApple, let url else { return }
        // gekozen ondertitelspoor uit de stream meenemen naar de Apple-speler (die geeft het door via AirPlay)
        if externalSubtitleFile == nil, let id = engine.currentSubtitle {
            carrySubtitle = engine.subtitleTracks.first { $0.id == id }
        }
        item.resumeAt = position
        start(url: url, forceApple: true)
    }

    private func tick() {
        #if os(iOS)
        if checkAirPlayVideo179() { return }
        #endif
        let st = engine.state
        // build 148: haperingen (bufferen of opnieuw openen na het eerste beeld) vastleggen voor de diagnose
        if !isPreview && !silent {
            let s: StallTracker.State = st == .playing ? .playing : (st == .buffering || st == .opening) ? .buffering : .other
            if let stall = stallTracker.tick(s, now: Date().timeIntervalSince1970) {
                PlaybackLog.shared.note(stall, engine: usingApple ? "apple" : "vlc", format: PlaybackLog.format(url), live: isLive)
            }
        }
        if pauseWhenReady && st == .playing { pauseWhenReady = false; pause() }
        // alleen publiceren wat veranderd is (elke toewijzing laat de schermen die deze speler volgen opnieuw tekenen)
        let playingNow = engine.isPlaying
        if isPlaying != playingNow { isPlaying = playingNow }
        let buffering = st == .buffering || st == .opening
        if isBuffering != buffering { isBuffering = buffering }
        if isReplay {
            // build 194: duur en positie van het programma, niet van de (duurloze) stream
            let len = replayLength
            if duration != len { duration = len }
            var shown = Replay194.display(base: replayBase, engineTime: engine.time, duration: len)
            if let p = replayPending {
                if st == .playing && Date().timeIntervalSince(replayPendingAt) > 1.5 { replayPending = nil }
                else { shown = Replay194.display(base: p, engineTime: 0, duration: len) }
            }
            if currentTime != shown.time { currentTime = shown.time }
            if position != shown.fraction { position = shown.fraction }
        } else {
        let d = engine.duration
        if duration != d { duration = d }
        let t0 = engine.time
        if currentTime != t0 { currentTime = t0 }
        let pos = engine.position
        if position != pos { position = pos }
        if st == .playing && position > 0.005 && !isLive { lastGoodPosition = position }
        }
        if let av = engine as? AVEngine, isLive, timeshiftStart == nil {
            let b = av.behindLive > 8 ? av.behindLive : 0
            if behindLive != b { behindLive = b }
        }

        #if !os(tvOS)
        if !isPreview && !silent { checkAirPlaySubtitles() }
        #endif
        if !externalCues.isEmpty && !airPlayWrapped {
            let t = currentTime - subtitleDelay
            let text = externalCues.last(where: { $0.start <= t })
                .flatMap { $0.end >= t ? $0.text : nil }
            if subtitleText != text { subtitleText = text }
        }

        // build 179: niet gestart of meteen vastgelopen → één keer de andere speler (Apple ↔ VLC)
        if sw179Check(st) { return }

        // automatisch herverbinden: eerst de andere engine (Apple → VLC), dan één stille nieuwe poging,
        // daarna een back-upbron (live) of de foutmelding met keuzes (build 52)
        // build 179 (X2): vlak na het (her)laden meldt de speler soms nog "afgelopen" of "fout" van de vorige stream
        // (VLC, zeker als het laden buiten de hoofdthread gebeurt): dat is geen nieuwe storing
        let terminal = st == .error || st == .ended
        if !terminal && st != .idle { leftTerminal = true }
        let stale = terminal && !usingApple && Stream179.terminalIsStale(sinceLoad: Date().timeIntervalSince(loadedAt), leftTerminal: leftTerminal)
        if st == .playing { playedSinceLoad += 0.5; if !hadPicture && engine.isPlaying { hadPicture = true } }
        if errorText == nil && !reloadPending && !stale {
            if st == .error || (isLive && st == .ended) {
                if let r = Stream179.reason(error: st == .error, ended: st == .ended, live: isLive, stalledFor: 0) { noteStop(r) }
                reconnect(reason: st == .error ? L("Stream lost") : nil)
            } else if isBuffering && isLive {
                stableTicks = 0
                if stallSince == nil { stallSince = Date() }
                if let s = stallSince, Date().timeIntervalSince(s) > 15 { noteStop(.timeout); reconnect(reason: nil) }
            } else if st == .playing {
                stableTicks += 1
                if Double(stableTicks) * 0.5 > Stream179.stableSeconds { attempts = 0; outageSince = nil }   // 10 seconden stabiel aan het spelen
                stallSince = nil; reconnecting = false
            }
        }

        if isPlaying && !didScrobbleStart && duration > 0 && !isPreview {
            didScrobbleStart = true
            observeBackgroundForTrakt()
            let it = item, p = position
            Task { @MainActor [weak self] in
                // kort laten zien dat Trakt meekijkt (of waarom niet)
                switch await TraktSync.shared.scrobble(.start, item: it, progress: p) {
                case .ok: self?.notice = L("Trakt: watching %@", it.subtitle.map { "\(ContentLanguage.shown(it.title)) · \($0)" } ?? ContentLanguage.shown(it.title))
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
        updateAwake()
        #if os(tvOS)
        // na een seconde echt afspelen: het scherm aanpassen aan framerate en dynamisch bereik van de stream
        if st == .playing && !isPreview && !silent && !displayMatched {
            displayTicks += 1
            if displayTicks >= 2 { matchDisplay() }
        }
        #endif
        if !tracksApplied && st == .playing && isPreview {
            // voorbeeld/Multiview: geen voorkeurssporen, en de sporenlijst (bij Apple synchroon uit de stream gelezen)
            // dus ook niet elke halve seconde op de hoofdthread opvragen
            tracksApplied = true
        }
        if !tracksApplied && st == .playing {
            playingTicks += 1
            // sporen zijn er meestal na een paar tellen; daarna niet meer ingrijpen (jouw eigen keuze blijft staan)
            if !engine.audioTracks.isEmpty || playingTicks > 12 { applyTrackPreferences() }
        }
        // build 173: slaaptimer (minuten, of na het programma bij live) en ondertitels even aan na terugspoelen
        if sleep != .off, Player173.sleepDue(sleep, deadline: sleepAt, now: Date(),
                                              titleEnded: isLive && (sleepProgramEnd.map { Date() >= $0 } ?? false)) {
            fireSleep()
        }
        if tempSubtitles, Player173.rewindSubtitlesDone(position: currentTime, until: tempSubUntil, startedAt: tempSubFrom) {
            tempSubtitles = false
            engine.selectSubtitle(nil)
            objectWillChange.send()
        }
        // build 164: live: af en toe een stilstaand beeld voor de tv-gids (na ±4 s, daarna elke 5 minuten)
        if isLive && !isPreview && st == .playing, let cid = item.channelID {
            stillTicks += 1
            if stillTicks == 8 || stillTicks % 600 == 0 {
                GuideStills.shared.capture(self, key: GuideStills.key(channelID: cid, sourceID: item.sourceID))
            }
        }
        if Date().timeIntervalSince(lastSaved) > 15 { saveProgress() }
        if !isLive && st == .ended { finish() }
    }

    // MARK: build 179: andere speler proberen en onthouden

    /// Sleutel van deze stream in `player.engineMemo`
    private var sw179Key: String? {
        guard let server = (item.sourceID ?? CloudStore.shared.activePlaylistID)?.uuidString else { return nil }
        switch item.type {
        case .live:
            guard let cid = item.channelID else { return nil }
            return Build179.memoKey(server: server, live: true, kind: "live", id: cid)
        case .movie: return Build179.memoKey(server: server, live: false, kind: "movie", id: item.id)
        case .episode: return Build179.memoKey(server: server, live: false, kind: "episode", id: item.id)
        case .series: return nil
        }
    }

    /// Kunnen beide engines dit adres openen, en is dit een gewone stream (geen voorbeeld, download of AirPlay)?
    private func sw179Eligible(_ url: URL) -> Bool {
        guard !isPreview, !silent, !url.isFileURL, timeshiftStart == nil else { return false }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if url.pathExtension.lowercased() == "movpkg" { return false }
        return !isExternalPlayback && !airPlayWrapped
    }

    /// Elke tick: tellen en zo nodig wisselen. true = er is gewisseld (rest van de tick overslaan).
    private func sw179Check(_ st: EngineState) -> Bool {
        guard let url, sw179Eligible(url), errorText == nil, !reloadPending else { return false }
        let now = Date()
        if st == .playing && engine.isPlaying {
            if !sw179FirstFrame { sw179FirstFrame = true }
            sw179Played += 0.5
            sw179StallSince = nil
            // speelt: onthouden (alleen schrijven als het anders is dan wat er stond)
            if !sw179Settled && sw179Played >= 2 {
                sw179Settled = true
                let cur = usingApple ? "apple" : "vlc"
                let memo = Build179.memoAfter(remembered: sw179Remembered, started: sw179Started,
                                              switchedTo: sw179Switched ? cur : nil, ok: true)
                if memo != sw179Remembered { EngineMemo179.set(sw179Key, memo); sw179Remembered = memo }
            }
        } else if sw179FirstFrame && (st == .buffering || st == .opening) {
            if sw179StallSince == nil { sw179StallSince = now }
        }
        let stalled = sw179StallSince.map { now.timeIntervalSince($0) } ?? 0
        // gepauzeerd of op de achtergrond gezet vóór het eerste beeld telt niet als "start niet"
        let waiting = st == .opening || st == .buffering || st == .error
        let go = Build179.shouldSwitch(error: st == .error, firstFrame: sw179FirstFrame,
                                       sinceStart: waiting && backgroundResume == nil ? now.timeIntervalSince(sw179Start) : 0,
                                       stalled: stalled,
                                       played: sw179Played, switched: sw179Switched)
        guard go else { return false }
        let cur = usingApple ? "apple" : "vlc"
        let order = sw179Started == "apple" ? ["apple", "vlc"] : ["vlc", "apple"]
        guard let next = Build179.nextEngine(order: order, current: cur, switched: sw179Switched) else { return false }
        sw179Switched = true
        // Apple → VLC telt als de bestaande "andere engine" (build 52); VLC → Apple niet, zodat een fout van de
        // Apple-speler daarna nog één keer naar VLC teruggaat (zoals altijd)
        if next == "vlc" { triedOtherEngine = true }
        if !isLive { item.resumeAt = lastGoodPosition > 0.01 ? lastGoodPosition : item.resumeAt }
        notice = L("Tried another player")
        // Eerst de huidige speler volledig sluiten en even wachten: er mogen nooit twee verbindingen naar de server
        // tegelijk open staan (aanbieders met één verbinding verbreken dan de stream). Daarna pas de andere speler.
        engine.stop()
        reloadPending = true; reconnecting = true; isBuffering = true
        stallSince = nil
        let toApple = next == "apple"
        // X2: intussen stilgezet (`halt`, bijv. naar de achtergrond), gestopt of iets anders gestart: niet meer wisselen
        loadEpoch += 1
        let epoch = loadEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, epoch == self.loadEpoch else { return }
            self.reloadPending = false
            guard !self.stopped, self.url == url, self.errorText == nil else { return }
            self.start(url: url, forceApple: toApple)
        }
        return true
    }

    /// Lukt ook de andere speler niet: het onthouden voor deze stream wissen
    private func sw179GaveUp() {
        guard sw179Switched || sw179Remembered != nil else { return }
        if Build179.memoAfter(remembered: sw179Remembered, started: sw179Started, switchedTo: nil, ok: false) == nil {
            EngineMemo179.set(sw179Key, nil)
            sw179Remembered = nil
        }
    }

    private func reconnect(reason: String?) {
        guard let url else { return }
        #if !os(tvOS)
        // eigen AirPlay-afspeellijst werkt niet: terug naar de gewone stream (met de melding) (build 57)
        if airPlayWrapped, engine.state == .error {
            airPlayWrapped = false; airPlaySelectPending = 0; airPlayWrapTries = 2
            notice = L("Subtitles from OpenSubtitles aren't shown via AirPlay.")
            if let f = externalSubtitleFile { applyExternalSubtitle(f) }
            engine.load(url, live: isLive && timeshiftStart == nil, startFraction: (isLive || isReplay) ? nil : lastGoodPosition)
            return
        }
        #endif
        // Apple-engine faalt → eerst VLC proberen (kan meer formaten aan)
        if usingApple && !triedOtherEngine && engine.state == .error && !url.isFileURL {
            triedOtherEngine = true
            if !isLive && !isReplay { item.resumeAt = lastGoodPosition > 0.01 ? lastGoodPosition : item.resumeAt }
            start(url: url, forceApple: false)
            return
        }
        // stil opnieuw verbinden. Build 179 (X2): bij live meerdere pogingen met oplopende wachttijd (was één poging na
        // 1,5 s): een stream die de server zelf sluit (bij sommige aanbieders steeds na een halve tot hele minuut) gaat
        // zo vanzelf verder in plaats van te stoppen. Films en series: één poging, zoals het was.
        let outage = outageSince.map { Date().timeIntervalSince($0) } ?? 0
        if let delay = Stream179.retryDelay(attempt: attempts, live: isLive, hadPicture: hadPicture, outage: outage) {
            if outageSince == nil { outageSince = Date() }
            attempts += 1
            reconnecting = true
            reloadPending = true
            stallSince = nil
            let resume = lastGoodPosition > 0.01 ? lastGoodPosition : item.resumeAt
            // VLC: de oude verbinding eerst echt sluiten; VLC probeert anders zelf nog te herverbinden terwijl wij wachten,
            // en dan staan er even twee verbindingen naar de aanbieder open. (De Apple-speler laat de oude stream los bij
            // het laden van de nieuwe; hem hier stoppen zou beeld-in-beeld beëindigen.)
            if isLive, engine is VLCEngine { engine.stop() }
            loadEpoch += 1
            let epoch = loadEpoch
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // intussen gestopt, stilgezet (`halt`) of iets anders gestart: deze poging vervalt
                guard let self, epoch == self.loadEpoch else { return }
                var target = url
                // MAC-portal: de link is maar één keer geldig → een verse ophalen (niet tijdens terugkijken)
                if self.isLive, self.timeshiftStart == nil, let refresh = self.refreshURL, let fresh = await refresh() {
                    guard epoch == self.loadEpoch else { return }
                    target = fresh
                }
                self.reloadPending = false
                guard !self.stopped, self.url == url else { return }
                if target != url {
                    if self.liveURL == url { self.liveURL = target }
                    self.url = target
                }
                if !self.isLive && !self.isReplay { self.item.resumeAt = resume }
                self.airPlayWrapped = false
                self.markLoaded()
                self.engine.load(target, live: self.isLive && self.timeshiftStart == nil, startFraction: (self.isLive || self.isReplay) ? nil : resume)
            }
            return
        }
        noteStop(.gaveUp)   // build 179
        reconnecting = false
        stallSince = nil
        sw179GaveUp()   // build 179
        if onGiveUp?() == true {
            // het spelerscherm schakelt over (start() zet dit terug); intussen niet opnieuw ingrijpen
            reloadPending = true; reconnecting = true
            return
        }
        let generic = L("This stream can't be played right now.")
        errorText = generic
        isBuffering = false
        // de stream echt stoppen (niet pauzeren): anders blijft de verbinding met de provider open (VLC probeert
        // zelfs opnieuw te verbinden) en telt hij daar mee terwijl je de foutmelding ziet. "Opnieuw" laadt hem opnieuw.
        engine.stop()
        // provider vol (alle verbindingen in gebruik)? Dan die melding in plaats van de algemene fout
        if !url.isFileURL, let check = providerLimitCheck {
            Task { @MainActor [weak self] in
                guard let m = await check(), let self, !self.stopped, self.url == url, self.errorText == generic else { return }
                self.errorText = m
            }
        }
    }

    func togglePlay() { engine.isPlaying ? pause() : resume() }

    func pause() {
        engine.pause()
        releaseAwake()
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
        if isReplay { replaySeek(to: (replayPending ?? currentTime) + seconds); return }   // build 194
        if !isLive {
            let before = currentTime
            engine.jump(seconds)
            if seconds < 0 { rewindSubtitles(jump: seconds, from: before) }   // build 173
            return
        }
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

    func seek(to fraction: Double) {
        if isReplay { replaySeek(to: Replay194.target(fraction: fraction, duration: replayLength, limit: replayLimit)); return }   // build 194
        guard !isLive else { return }; engine.seek(toFraction: fraction)
    }

    /// Build 194: spoelen in een terugkijkprogramma. De stream heeft geen bruikbare duur: de lengte komt uit het
    /// programma en de URL wordt opnieuw opgebouwd vanaf het gekozen punt. Achter elkaar drukken telt op (kort wachten).
    private func replaySeek(to raw: Double) {
        guard let a = item.replayStart, let b = item.replayEnd else { return }
        let now = Date().timeIntervalSince1970
        if Replay194.finishes(raw: raw, start: a.timeIntervalSince1970, end: b.timeIntervalSince1970, now: now) {
            replaySeekTask?.cancel(); finish(); return
        }
        let t = Replay194.target(current: raw, delta: 0, limit: replayLimit)
        replayPending = t; replayPendingAt = Date()
        isBuffering = true
        let len = replayLength
        if len > 0 { currentTime = t; position = min(max(t / len, 0), 1) }
        replaySeekTask?.cancel()
        replaySeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, !self.stopped, let provider = self.replayProvider else { return }
            let from = Date(timeIntervalSince1970: Replay194.streamStart(programStart: a.timeIntervalSince1970, offset: t))
            guard let u = provider(from, b) else { self.replayPending = nil; return }
            self.replayBase = t
            self.pausedAt = nil
            self.start(url: u)
        }
    }

    /// Zendervoorbeeld: alleen het beeld stoppen (snel scrollen, andere groep). De engine blijft bestaan voor de
    /// volgende zender, zodat er niet steeds een nieuwe speler opgebouwd en afgebroken wordt.
    private var keepEngine = false
    func halt() {
        timer?.invalidate(); timer = nil
        // build 179 (X2): een herlaadpoging die nog gepland stond mag de stilgezette speler niet opnieuw openen
        loadEpoch += 1; reloadPending = false; reconnecting = false
        keepEngine = true
        engine.stop()
        releaseAwake()
        if isPlaying { isPlaying = false }
        if !isBuffering { isBuffering = true }
    }

    /// Positie om na de achtergrond te hervatten (nil = niet op de achtergrond gestopt)
    private var backgroundResume: Double?
    /// Film/aflevering stond op pauze toen de app naar de achtergrond ging: na het opnieuw laden weer pauzeren
    private var pauseWhenReady = false

    /// Naar de achtergrond zonder beeld-in-beeld/AirPlay/Chromecast: de stream echt stoppen, zodat de verbinding met
    /// de IPTV-provider meteen vrijkomt (VLC speelde anders het geluid door en de provider telde hem nog mee).
    func suspendForBackground() {
        guard !stopped, url != nil, !inPiP, backgroundResume == nil else { return }
        backgroundResume = isLive ? 0 : (position > 0.005 ? position : item.resumeAt)
        pauseWhenReady = !isLive && engine.state == .paused
        startWatch?.cancel()
        saveProgress()
        halt()
    }

    /// Terug op de voorgrond: op dezelfde plek verder (live: weer live).
    func resumeFromBackground() {
        guard let p = backgroundResume else { return }
        backgroundResume = nil
        guard !stopped, errorText == nil, let url else { return }
        if !isLive { item.resumeAt = p }
        // geen nieuwe kijksessie: kijktijd en geschiedenis lopen gewoon door
        let w = watchedSeconds, recorded = recordedHistory, profile = playbackProfileID
        start(url: url)
        watchedSeconds = w; recordedHistory = recorded; playbackProfileID = profile
    }

    /// `keepDisplay`: zappen of volgende aflevering — de schermstand niet eerst terugzetten (geen extra knipper).
    func stop(keepDisplay: Bool = false) {
        guard !stopped else { return }
        stopped = true
        loadEpoch += 1   // build 179
        startWatch?.cancel(); subtitleCheck?.cancel()
        backgroundResume = nil
        #if os(tvOS)
        if !keepDisplay { resetDisplay() }
        #endif
        pendingPiP = 0
        recordHistory()
        timer?.invalidate(); timer = nil
        saveProgress()
        if !isPreview {
            let p = position, it = item, w = reachedWatched
            Task { await TraktSync.shared.scrobble(.stop, item: it, progress: p, watched: w) }
        }
        if let o = backgroundObserver { NotificationCenter.default.removeObserver(o); backgroundObserver = nil }
        // voortgang bij stoppen meteen naar de Bingr-account
        if !isPreview { StateSync.shared.playbackStopped(profile: playbackProfileID) }
        engine.stop()
        releaseAwake()
        #if !os(tvOS)
        if airPlayServing { AirPlaySubtitles.stop(); airPlayServing = false }
        airPlayWrapped = false
        #endif
    }

    /// Build 154: naar de achtergrond → scrobble-stop met de huidige positie (Trakt ziet anders nooit een stop);
    /// weer actief en nog aan het spelen → opnieuw een start.
    private func observeBackgroundForTrakt() {
        #if os(iOS) || os(tvOS)
        guard backgroundObserver == nil else { return }
        let nc = NotificationCenter.default
        backgroundObserver = nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPreview, !self.stopped else { return }
                let it = self.item, p = self.position, w = self.reachedWatched
                Task { await TraktSync.shared.scrobble(.stop, item: it, progress: p, watched: w) }
                self.didScrobbleStart = false   // bij terugkeer en verder spelen: opnieuw een start
            }
        }
        #endif
    }

    // MARK: scherm wakker houden (build 97)

    /// build 97: zolang er echt beeld speelt (ook VLC, Multiview-tegels en beeld-in-beeld) het scherm wakker houden;
    /// een stil zendervoorbeeld telt niet mee. Alleen bij een verandering naar `DisplayAwake`.
    private func updateAwake() {
        let want = isPlaying && !silent && !stopped && errorText == nil
        guard want != holdsAwake else { return }
        holdsAwake = want
        DisplayAwake.shared.set(self, awake: want)
    }

    /// build 97: pauze, stoppen, einde of halt: het scherm mag weer slapen (als geen andere speler nog speelt)
    private func releaseAwake() {
        guard holdsAwake else { return }
        holdsAwake = false
        DisplayAwake.shared.set(self, awake: false)
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

    /// AirPlay (Apple-engine speelt op een ander scherm): op de achtergrond blijft de stream dan aangemeld.
    var isExternalPlayback: Bool { (engine as? AVEngine)?.player.isExternalPlaybackActive ?? false }

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
            if restoringFromPiP { restoringFromPiP = false } else {   // venster gesloten = stoppen
                stop()
                StreamSession.shared.stop(owner: self)
            }
        case .failed:
            notice = L("Picture in Picture isn't available for this stream.")
        }
    }

    private func finish() {
        recordHistory()
        timer?.invalidate(); timer = nil
        releaseAwake()
        position = 1
        saveProgress()
        if !isPreview { let it = item; Task { await TraktSync.shared.scrobble(.stop, item: it, progress: 1, watched: true) } }
        if !isPreview { StateSync.shared.playbackStopped(profile: playbackProfileID) }
        // build 173: slaaptimer "Na deze aflevering": stoppen in plaats van door naar de volgende
        if sleep == .endOfEpisode { fireSleep(); return }
        onFinished?()
    }

    // MARK: build 173: slaaptimer, vanaf het begin, ondertitels na terugspoelen

    /// Slaaptimer: na deze aflevering / 30 / 60 / 90 minuten / uit (`sleepAt` = moment bij minuten)
    @Published private(set) var sleep: Player173.Sleep = .off
    /// Live met "na dit programma": einde van het programma volgens de gids
    var sleepProgramEnd: Date?
    /// Gezet door het spelerscherm: einde van het lopende programma (live, volgens de gids)
    var sleepProgramEndProvider: (@MainActor () -> Date?)?
    /// Slaaptimer afgegaan: het spelerscherm pauzeert, meldt de stream af en toont "Slaaptimer: gestopt"
    var onSleep: (@MainActor () -> Void)?

    func setSleep(_ s: Player173.Sleep, programEnd: Date? = nil) {
        sleep = s
        sleepAt = Player173.sleepDeadline(s, now: Date())
        sleepProgramEnd = s == .endOfEpisode ? programEnd : nil
    }

    private func fireSleep() {
        sleep = .off; sleepAt = nil; sleepProgramEnd = nil
        if let f = onSleep { f() } else { pause() }
    }

    /// Kan deze zender terugkijken (catch-up van de server)?
    var hasCatchup: Bool {
        guard isLive, let p = catchupProvider else { return false }
        return p(Date().addingTimeInterval(-600), Date()) != nil
    }

    /// Vanaf het begin van het lopende programma (terugkijken van de server), daarna Terug naar live met `goLive`.
    @discardableResult
    func startOver(from begin: Date) -> Bool {
        guard isLive, let provider = catchupProvider, begin < Date(),
              let u = provider(begin, Date().addingTimeInterval(3 * 3600)) else { return false }
        timeshiftStart = begin
        behindLive = Date().timeIntervalSince(begin)
        pausedAt = nil
        start(url: u)
        return true
    }

    /// Ondertitels tijdelijk aan na kort terugspoelen (instelling Afspelen, standaard aan)
    static let rewindSubtitlesKey = "player.rewindSubtitles"
    static var rewindSubtitlesEnabled: Bool { UserDefaults.standard.object(forKey: rewindSubtitlesKey) as? Bool ?? true }
    @Published private(set) var tempSubtitles = false
    private var tempSubUntil: Double = 0
    private var tempSubFrom: Double = 0

    private func rewindSubtitles(jump: Double, from before: Double) {
        guard !isLive, duration > 0 else { return }
        if tempSubtitles { tempSubFrom = max(0, before + jump); return }   // al aan: tot hetzelfde punt
        let on = engine.currentSubtitle != nil || hasExternalSubtitle
        let tracks = engine.subtitleTracks
        let wanted = [TrackPreferences.subtitle, Localizer.shared.language].filter { !$0.isEmpty && $0 != "off" }
        let idx = Player173.subtitleTrack(tracks.map { ($0.lang?.isEmpty == false ? $0.lang! : $0.name) }, wanted: wanted)
        guard Player173.rewindSubtitles(jump: jump, subtitlesOn: on, hasTrack: idx != nil, enabled: Self.rewindSubtitlesEnabled),
              let i = idx else { return }
        tempSubtitles = true
        tempSubUntil = before
        tempSubFrom = max(0, before + jump)
        engine.selectSubtitle(tracks[i])
        objectWillChange.send()
    }

    /// Na minstens een minuut kijken komt het in de kijkgeschiedenis van dit profiel.
    private var recordedHistory = false
    private func recordHistory() {
        guard !isPreview, !recordedHistory, watchedSeconds >= 60 else { return }
        recordedHistory = true
        let it = item
        // build 128: de eigen server van het item (ook als dat niet de open bron is)
        CloudStore.shared.addHistory(HistoryEntry(itemID: it.channelID ?? it.id, playlistID: it.sourceID ?? CloudStore.shared.activePlaylistID,
                                                  title: it.title, subtitle: it.subtitle, artwork: it.artwork,
                                                  type: it.type, channelID: it.channelID, date: Date(),
                                                  profileID: playbackProfileID ?? CloudStore.shared.activeProfileID))
    }

    private func saveProgress() {
        lastSaved = Date()
        guard !isPreview, item.type != .live, item.channelID == nil, !item.id.contains("-cu-"), duration > 60 else { return }
        let store = CloudStore.shared
        // build 97: voor het profiel dat keek toen het afspelen begon (niet het profiel dat nu toevallig actief is)
        let prof = playbackProfileID ?? store.activeProfileID
        // gezien: bijna uitgekeken, of alleen de aftiteling nog over — per profiel, ook zonder Trakt
        // build 154: `WatchedThreshold` (Build154.swift), dezelfde grens als op Android en web
        if WatchedThreshold.reached(position: position, duration: duration, currentTime: currentTime) {
            store.clearProgress(item.id, profile: prof)
            // build 154: id-sleutel én inhoudssleutels (gezien op alle servers), en via de wachtrij naar Trakt
            Watched154.setItem(item, true, profile: prof)
            reachedWatched = true
            if prof == nil || prof == store.activeProfileID { TraktSync.shared.markWatchedFromPlayer(item) }
        } else if position > 0.02 {
            store.setProgress(item.id, ProgressEntry(fraction: position, position: currentTime, updated: Date(),
                                                     title: item.title, artwork: item.artwork, playlistID: item.sourceID ?? store.activePlaylistID,
                                                     profileID: prof), profile: prof)
        }
    }

    // MARK: sporen & ondertitels

    /// Voorkeurstaal voor audio en automatische ondertitels toepassen (build 59).
    private func applyTrackPreferences() {
        tracksApplied = true
        guard !isPreview else { return }
        // audio: de voorkeurstaal (instelling, anders de app-taal) als de stream meer dan één audiotaal heeft
        // bij "zoals in de stream" niets kiezen
        let tracks = engine.audioTracks
        // build 148: bij live niet meer wisselen na de start: de voorkeurstaal is al vóór het afspelen gekozen (VLC
        // `:audio-language`, AVPlayer `setMediaSelectionCriteria`); een wissel tijdens live leegde de buffer (hapering ±5 s)
        if !isLive, let prefAudio = TrackPreferences.autoAudio, tracks.count > 1, let t = tracks.first(where: { TrackPreferences.matches($0, code: prefAudio) }), t.id != engine.currentAudio {
            engine.selectAudio(t)
        }
        // na het wisselen van engine: hetzelfde spoor als daarvoor (op taal, anders op naam)
        if let want = carrySubtitle, externalCues.isEmpty, externalSubtitleFile == nil {
            carrySubtitle = nil
            let code = want.lang.map(TrackPreferences.baseCode)
                ?? TrackPreferences.languages.map(\.code).first { TrackPreferences.matches(want, code: $0) }
            let subs = engine.subtitleTracks
            if let t = subs.first(where: { code != nil && TrackPreferences.matches($0, code: code!) })
                ?? subs.first(where: { $0.name.caseInsensitiveCompare(want.name) == .orderedSame }) {
                engine.selectSubtitle(t)
            }
        } else {
            applyAutoSubtitles()
        }
        objectWillChange.send()
    }

    /// Gesproken taal: het gekozen audiospoor, anders het label van de titel ("Animal (IT)") of de originele taal (TMDB).
    var spokenLanguage: String? {
        let tracks = engine.audioTracks
        if let id = engine.currentAudio, let t = tracks.first(where: { $0.id == id }), let l = TrackPreferences.language(of: t) { return l }
        if tracks.count == 1, let l = TrackPreferences.language(of: tracks[0]) { return l }
        return item.audioLanguage
    }

    /// Ondertitels automatisch (build 59). "Wanneer nodig": alleen als de audio een andere taal is dan je voorkeur en
    /// er nog geen ondertitels in die taal in beeld zijn. "Altijd": altijd in je voorkeurstaal. Eerst een spoor in de
    /// stream, anders OpenSubtitles op de achtergrond — het afspelen wacht hier nooit op.
    private func applyAutoSubtitles() {
        guard autoSubtitlesFor != item.id, externalSubtitleFile == nil, externalCues.isEmpty else { return }
        autoSubtitlesFor = item.id
        let mode = TrackPreferences.subtitleMode
        if mode == .off {
            // oude instelling "ondertitels uit": ook een standaardspoor van de stream uitzetten
            if TrackPreferences.subtitle == "off", engine.currentSubtitle != nil { engine.selectSubtitle(nil) }
            return
        }
        let want = TrackPreferences.preferredSubtitle
        if item.burnedSubtitles == want { return }          // zitten al in beeld ("NL SUBS")
        if mode == .whenNeeded {
            guard let spoken = spokenLanguage, spoken != want else { return }   // zelfde taal of onbekend: niet nodig
        }
        if let t = engine.subtitleTracks.first(where: { TrackPreferences.matches($0, code: want) }) {
            if t.id != engine.currentSubtitle {
                engine.selectSubtitle(t)
                notice = L("Subtitles: %@", TrackPreferences.name(want))
            }
            return
        }
        guard !isLive else { return }
        // ondertitelsporen komen soms later binnen: even wachten, dan pas OpenSubtitles
        let id = item.id
        subtitleCheck?.cancel()
        subtitleCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, !self.stopped, self.item.id == id, !self.userPickedSubtitle,
                  self.externalSubtitleFile == nil, self.externalCues.isEmpty else { return }
            if let t = self.engine.subtitleTracks.first(where: { TrackPreferences.matches($0, code: want) }) {
                self.engine.selectSubtitle(t)
                self.objectWillChange.send()
                self.notice = L("Subtitles: %@", TrackPreferences.name(want))
                return
            }
            self.onNeedSubtitles?(want)
        }
    }

    var audioTracks: [MediaTrack] { engine.audioTracks }
    var subtitleTracks: [MediaTrack] { engine.subtitleTracks }
    var currentAudio: String? { engine.currentAudio }
    var currentSubtitle: String? { externalCues.isEmpty ? engine.currentSubtitle : "ext" }
    var hasExternalSubtitle: Bool { !externalCues.isEmpty || externalSubtitleName != nil }

    /// Wat er nu als ondertitel gekozen is (voor Chromecast).
    var selectedSubtitle: SubtitleChoice? {
        if let f = externalSubtitleFile {
            return SubtitleChoice(kind: .file(f), name: externalSubtitleName ?? "OpenSubtitles", language: externalSubtitleLanguage)
        }
        guard let id = engine.currentSubtitle, let t = engine.subtitleTracks.first(where: { $0.id == id }) else { return nil }
        let index = engine.subtitleTracks.firstIndex(where: { $0.id == id }) ?? 0
        let lang = t.lang ?? TrackPreferences.languages.map(\.code).first { TrackPreferences.matches(t, code: $0) }
        return SubtitleChoice(kind: .embedded(index: index), name: t.name, language: lang)
    }
    /// Naam van de laatst ingeladen OpenSubtitles-ondertitel (met vlag)
    @Published private(set) var externalSubtitleName: String?
    /// Verschuiving van de ondertitels in seconden (+ = later tonen)
    @Published var subtitleDelay: Double = 0 {
        didSet {
            engine.setSubtitleDelay(subtitleDelay)
            if oldValue != subtitleDelay {
                if airPlayWrapped { airPlayNeedsRewrap = true; airPlayWrapTries = 0 }
                subtitlesChanged()
            }
        }
    }

    func selectAudio(_ t: MediaTrack) {
        engine.selectAudio(t); objectWillChange.send()
        // build 59: sommige streams nemen de wissel niet meteen over → na even nog eens, bij VLC met een korte herstart
        // van de decoder op dezelfde plek
        let id = t.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !self.stopped, self.engine.currentAudio != id,
                  self.engine.audioTracks.contains(where: { $0.id == id }) else { return }
            self.engine.selectAudio(t)
            if !self.usingApple, !self.isLive, self.duration > 0 { self.engine.seek(toFraction: self.engine.position) }
            self.objectWillChange.send()
        }
    }
    func selectSubtitle(_ t: MediaTrack?) {
        tempSubtitles = false   // build 173: eigen keuze gaat voor
        // build 91: eigen keuze gaat voor: geen automatische ondertitels meer (ook niet als die nog onderweg zijn)
        subtitleCheck?.cancel(); subtitleCheck = nil
        autoSubtitlesFor = item.id
        userPickedSubtitle = true
        externalCues = []; subtitleText = nil; externalSubtitleName = nil
        externalSubtitleFile = nil; externalSubtitleLanguage = nil
        engine.selectSubtitle(t); objectWillChange.send()
        subtitlesChanged()
    }

    /// `language`: taalcode van de ondertitel (OpenSubtitles), voor Chromecast en AirPlay.
    func addSubtitle(file: URL, name: String? = nil, language: String? = nil) {
        // altijd als UTF-8 aanbieden (OpenSubtitles levert soms Windows-1252/Latin-1 → rare tekens)
        let utf8 = SRT.normalizedFile(file) ?? file
        externalSubtitleFile = utf8
        externalSubtitleLanguage = language
        applyExternalSubtitle(utf8)
        externalSubtitleName = name ?? file.deletingPathExtension().lastPathComponent
        objectWillChange.send()
        // nieuwe ondertitel tijdens AirPlay: opnieuw proberen met het nieuwe bestand
        airPlayWrapTries = 0
        if airPlayWrapped { airPlayWrapped = false; airPlaySelectPending = 0 }
        subtitlesChanged()
    }

    /// Bestand aan de huidige engine geven: VLC tekent het zelf, bij de Apple-speler de eigen overlay.
    private func applyExternalSubtitle(_ utf8: URL) {
        if engine.supportsExternalSubtitles {
            externalCues = []
            engine.addSubtitle(utf8)
        } else if let d = try? Data(contentsOf: utf8) {
            engine.selectSubtitle(nil)
            externalCues = SRT.parse(d)
            subtitleText = nil
        }
        engine.setSubtitleDelay(subtitleDelay)
    }

    /// Ondertitelkeuze veranderd: Chromecast bijwerken (tijdens het casten).
    private func subtitlesChanged() {
        #if !os(tvOS)
        guard !isPreview, !silent, CastManager.shared.connected != nil else { return }
        CastManager.shared.updateSubtitle(selectedSubtitle, delay: subtitleDelay)
        #endif
    }

    // MARK: AirPlay met eigen ondertitels (build 57)

    #if !os(tvOS)
    /// Elke tick: AirPlay aan of uit? Met een eigen ondertitel tijdens AirPlay → eigen HLS-afspeellijst met
    /// ondertitelspoor; lukt dat niet (geen HLS), dan een melding.
    private func checkAirPlaySubtitles() {
        let external = isExternalPlayback
        defer { wasExternalPlayback = external }
        guard let av = engine as? AVEngine else { return }

        // ons spoor kiezen zodra de nieuwe afspeellijst geladen is
        if airPlaySelectPending > 0 {
            airPlaySelectPending += 1
            if let t = av.subtitleTracks.first(where: { $0.name == AirPlaySubtitles.trackName }) {
                av.selectSubtitle(t)
                airPlaySelectPending = 0
                subtitleText = nil
                objectWillChange.send()
            } else if airPlaySelectPending > 40 {
                airPlaySelectPending = 0
            }
        }

        // AirPlay net aangezet: opnieuw proberen (en zo nodig opnieuw melden)
        if external && !wasExternalPlayback && !airPlayWrapped { airPlayWrapTries = 0 }
        // opnieuw maken (andere verschuiving) mag ook zonder AirPlay: dan speelt de eigen afspeellijst al
        let wanted = airPlayWrapped ? airPlayNeedsRewrap : external
        guard wanted, externalSubtitleFile != nil, !airPlayWrapBusy,
              engine.state == .playing || engine.state == .paused,
              !isLive, airPlayWrapTries < 2, let url, let file = externalSubtitleFile else { return }
        airPlayNeedsRewrap = false
        airPlayWrapTries += 1
        airPlayWrapBusy = true
        let lang = externalSubtitleLanguage, dur = duration, delay = subtitleDelay, pos = position
        Task { @MainActor in
            let wrapped = await AirPlaySubtitles.wrap(source: url, subtitle: file, language: lang, duration: dur, delay: delay)
            self.airPlayWrapBusy = false
            // intussen iets anders gaan spelen of AirPlay al weer uit
            guard !self.stopped, self.url == url, self.externalSubtitleFile == file,
                  self.isExternalPlayback || self.airPlayWrapped, let av = self.engine as? AVEngine else { return }
            guard let wrapped else {
                self.airPlayWrapTries = 2
                self.notice = L("Subtitles from OpenSubtitles aren't shown via AirPlay.")
                return
            }
            let at = av.duration > 0 ? av.position : pos
            let wasPlaying = av.isPlaying
            self.airPlayWrapped = true
            self.airPlayServing = true
            self.airPlaySelectPending = 1
            self.subtitleText = nil
            av.load(wrapped, live: false, startFraction: at)
            if !wasPlaying { av.pause() }
        }
    }
    #endif


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
    /// Build 164: de speler komt uit het live voorbeeld van de tv-gids (nog niet aangemeld als gewone stream)
    private var handedOff: ObjectIdentifier?
    func handOff(_ c: PlayerController) {
        reuse = c
        handedOff = ObjectIdentifier(c)
    }
    func takeHandoff(_ c: PlayerController) -> Bool {
        defer { handedOff = nil }
        return handedOff == ObjectIdentifier(c)
    }
    /// Iets anders gaat spelen: beeld-in-beeld stoppen.
    func stopActive() {
        guard let a = active else { return }
        active = nil
        (a.engine as? AVEngine)?.stopPiP()
        a.stop()
        StreamSession.shared.stop(owner: a)
    }
}

/// build 97: houdt het scherm wakker zolang minstens één speler afspeelt. iPhone, iPad en Apple TV via
/// `isIdleTimerDisabled` (terug bij pauze/stop en naar de achtergrond), de Mac via een activiteit die de
/// slaapstand van het scherm (en de schermbeveiliging) tegenhoudt. De Apple-speler doet dit zelf al, VLC niet.
@MainActor
final class DisplayAwake {
    static let shared = DisplayAwake()

    private final class Weak { weak var ref: PlayerController?; init(_ r: PlayerController) { ref = r } }
    /// build 97: spelers die nu wakker houden (zwak vast: een opgeruimde speler telt vanzelf niet meer mee)
    private var holders: [ObjectIdentifier: Weak] = [:]
    private var applied = false
    private var prune: Timer?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #else
    private var observers: [NSObjectProtocol] = []
    #endif

    private init() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default
        // build 97: op de achtergrond (ook beeld-in-beeld) de gewone instelling terug; weer actief → opnieuw toepassen
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled = false }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayAwake.shared.reapply() }
        })
        #endif
    }

    func set(_ player: PlayerController, awake: Bool) {
        let key = ObjectIdentifier(player)
        if awake { holders[key] = Weak(player) } else { holders[key] = nil }
        refresh()
    }

    private func refresh() {
        holders = holders.filter { $0.value.ref != nil }
        apply(!holders.isEmpty)
        // build 97: een speler die zonder stop() opgeruimd is, mag het scherm niet eeuwig wakker houden
        if holders.isEmpty {
            prune?.invalidate(); prune = nil
        } else if prune == nil {
            prune = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in DisplayAwake.shared.refresh() }
            }
        }
    }

    private func reapply() {
        applied = false
        refresh()
    }

    private func apply(_ on: Bool) {
        #if os(iOS) || os(tvOS)
        // build 97: alleen als de app voorop staat; op de achtergrond doet de instelling niets
        let foreground = UIApplication.shared.applicationState != .background
        let target = on && foreground
        if UIApplication.shared.isIdleTimerDisabled != target { UIApplication.shared.isIdleTimerDisabled = target }
        applied = on
        #else
        guard on != applied else { return }
        applied = on
        if on {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                                 reason: "Bingr speelt video af")
            }
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #endif
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
        if external && display.isConnected && PlayerSettings.externalDisplay {
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
