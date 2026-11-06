import SwiftUI
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Speler-instellingen van build 51 (Mijn Bingr → Speler).
enum PlayerSettings {
    /// Zapvertraging in seconden (0 = uit): snel zappen toont alleen de zenderbalk, de stream start pas na de pauze.
    static let zapDelayKey = "player.zapDelay"
    static let zapDelays: [Double] = [0, 0.5, 1, 2]
    static var zapDelay: Double {
        let v = UserDefaults.standard.object(forKey: zapDelayKey) as? Double ?? 0
        return zapDelays.contains(v) ? v : 0
    }
    static func zapDelayTitle(_ v: Double) -> String {
        switch v {
        case 0: return L("Off")
        case 0.5: return L("0.5 seconds")
        case 1: return L("1 second")
        default: return L("%d seconds", Int(v))
        }
    }

    /// Zendervoorbeeld in Live TV en de tv-gids. Oude schakelaar (tot build 163); vanaf build 164 volgt hij de keuze
    /// "Live voorbeeld in de gids" (uit = Nooit), en hij gaat nog mee met de sync voor oudere apps.
    static let previewKey = "live.preview"
    static var previewEnabled: Bool { guidePreviewMode != .never }

    /// Build 164: "Live voorbeeld in de gids": Altijd, Alleen wifi (standaard) of Nooit.
    static var guidePreviewMode: GuidePreviewMode164 {
        GuidePreviewMode164.resolve(stored: UserDefaults.standard.string(forKey: GuidePreviewMode164.key),
                                    legacyPreview: UserDefaults.standard.object(forKey: previewKey) as? Bool)
    }
    static func setGuidePreviewMode(_ m: GuidePreviewMode164) {
        UserDefaults.standard.set(m.rawValue, forKey: GuidePreviewMode164.key)
        UserDefaults.standard.set(m != .never, forKey: previewKey)
    }
    static func guidePreviewTitle(_ m: GuidePreviewMode164) -> String {
        switch m {
        case .always: return L("Always")
        case .wifi: return L("Wi-Fi only")
        case .never: return L("Never")
        }
    }

    /// Apple TV: beeldfrequentie en dynamisch bereik van het scherm aanpassen aan de stream.
    static let matchKey = "player.matchFrameRate"
    static var matchFrameRate: Bool { UserDefaults.standard.object(forKey: matchKey) as? Bool ?? true }

    /// iPhone/iPad: met een extern scherm (HDMI of AirPlay-schermdeling) de video daar tonen (standaard aan).
    static let externalKey = "player.externalDisplay"
    static var externalDisplay: Bool { UserDefaults.standard.object(forKey: externalKey) as? Bool ?? true }

    @MainActor static var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
}

/// Netwerk: is de verbinding (alleen) mobiel? Voor het zendervoorbeeld op de iPhone.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = false
    private var constrained = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            self.constrained = path.isConstrained
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "bingr.network"))
    }

    var isCellular: Bool {
        lock.lock(); defer { lock.unlock() }
        return cellular
    }

    /// Modus voor weinig data (build 82: dan geen trailers automatisch)
    var isConstrained: Bool {
        lock.lock(); defer { lock.unlock() }
        return constrained
    }
}

/// Eén gedeelde, lichte speler voor het zendervoorbeeld (zonder geluid). Start pas als de selectie even blijft staan,
/// eerst met de Apple-engine; alleen als die de stream niet kan afspelen valt hij terug op VLC.
///
/// Scrollen (build 56): het voorbeeld start pas als de selectie 1,2 seconde blijft staan; elke nieuwe selectie zet
/// de wachttijd opnieuw in. Bij snel door de lijst gaan (focus/aanwijzer verspringt binnen `scrollGap`) wordt het
/// lopende beeld stilgezet, zodat er tijdens het scrollen niets gedecodeerd wordt. Er is één speler die steeds een
/// andere zender krijgt; hij wordt pas losgelaten als je Live TV verlaat of er echt iets gaat spelen.
@MainActor
final class ChannelPreview: ObservableObject {
    static let shared = ChannelPreview()

    @Published private(set) var channel: Channel?
    @Published private(set) var controller: PlayerController?
    /// Als zwevend venster tonen (aanwijzer/gids); niet bij het voorbeeld in een contextmenu
    @Published private(set) var floating = true
    private var pending: Task<Void, Never>?
    private var generation = 0
    /// De speler die stilstaat (na scrollen of een andere groep), klaar om opnieuw te gebruiken
    private var spare: PlayerController?
    /// Beeld stilgezet tijdens het scrollen; `channel` toont dan alleen het logo
    private var suspended = false
    private var lastSelect = Date.distantPast

    /// Twee selecties binnen deze tijd = scrollen
    static let scrollGap: TimeInterval = 0.6

    private init() {
        _ = NetworkStatus.shared   // vast beginnen met meten
        #if canImport(UIKit)
        // naar de achtergrond: het voorbeeld stoppen, anders bleef de verbinding met de provider open (bevroren app)
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChannelPreview.shared.stop() }
        }
        #endif
    }
    private var background: NSObjectProtocol?

    /// Mag er nu een voorbeeld spelen? Build 164: volgens "Live voorbeeld in de gids"; op mobiel netwerk bij
    /// "Alleen wifi" pas na een tik (`userInitiated`). Tv's zijn altijd wifi of kabel.
    var allowed: Bool { allowed(userInitiated: false) }
    func allowed(userInitiated: Bool) -> Bool {
        let mode = PlayerSettings.guidePreviewMode
        if userInitiated { return mode.allowsTap }
        #if os(tvOS)
        return mode.autoStart(isTV: true, cellular: false)
        #else
        return mode.autoStart(isTV: false, cellular: NetworkStatus.shared.isCellular)
        #endif
    }

    /// Build 164: de tv-gids wil een voorbeeld dat naar volledig scherm kan zonder opnieuw te laden (en waarvan het
    /// geluid aan kan): dan een gewone (niet-stille) speler, gedempt. Live TV houdt het lichte stille voorbeeld.
    @Published private(set) var handoffCapable = false
    /// Build 164: geen live beeld (streamlimiet, er speelt al iets, fout): de gids toont het stilstaande beeld
    @Published private(set) var blocked = false
    /// Build 164: geluid van het voorbeeld aan (alleen bij `handoffCapable`)
    @Published private(set) var soundOn = false

    /// Een zender is geselecteerd (focus op Apple TV, aanwijzer op iPad/Mac): als de selectie blijft staan het
    /// voorbeeld starten. `nil` = selectie weg; het lopende voorbeeld blijft dan staan.
    func select(_ c: Channel?, playlists: PlaylistService, delay: Double = 1.2, floating: Bool = true,
                handoff: Bool = false, userInitiated: Bool = false) {
        pending?.cancel()
        pending = nil
        ScrollActivity.shared.touch()   // focus gaat door de lijst: ander zwaar werk even laten wachten
        guard let c, allowed(userInitiated: userInitiated) else { return }
        let now = Date()
        let scrolling = now.timeIntervalSince(lastSelect) < Self.scrollGap
        lastSelect = now
        if handoffCapable != handoff {
            handoffCapable = handoff
            if !handoff { soundOn = false }
        }
        if channel?.id == c.id && !suspended && !blocked { return }   // speelt al
        if self.floating != floating { self.floating = floating }
        let wait = delay
        if scrolling && delay > 0 {
            // snel scrollen: niet decoderen terwijl de lijst beweegt; starten zodra de focus even rust
            suspend(showing: c)
        }
        pendingID = c.id
        pending = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.pendingID = nil
            await self.start(c, playlists: playlists)
        }
    }

    /// Build 164 (Apple TV): de focus gaat weg van de NU-kaart van deze zender: dat beeld stoppen, behalve als de
    /// focus intussen al op een andere kaart staat (die heeft het voorbeeld dan overgenomen).
    private var pendingID: String?
    func release(_ c: Channel) {
        if let p = pendingID, p != c.id { return }
        if pendingID == c.id || channel?.id == c.id { stop() }
    }

    /// Beeld stilzetten (speler blijft bewaard); een al zichtbaar voorbeeld volgt de selectie met het logo.
    private func suspend(showing c: Channel) {
        generation += 1   // een lopende start (stream opzoeken) is niet meer nodig
        StreamSession.shared.stop(owner: self)
        if let ctrl = controller {
            ctrl.halt()
            spare = ctrl
            controller = nil
        }
        if channel != nil {
            suspended = true
            if channel?.id != c.id { channel = c }
        }
    }

    private func start(_ c: Channel, playlists: PlaylistService) async {
        // App Store-screenshots: geen stream, alleen het (getekende) beeld van de zender
        if Screenshots.isActive {
            suspended = false
            if channel?.id != c.id { channel = c }
            return
        }
        // build 164: hooguit één live voorbeeld, en niet als er al iets speelt (beeld-in-beeld, speler, Multiview):
        // dan het stilstaande beeld, zonder melding
        if PiPCenter.shared.active != nil
            || (StreamSession.shared.current != nil && !StreamSession.shared.isOwner(self)) {
            showBlocked(c)
            return
        }
        generation += 1
        let gen = generation
        let item = Playables.channel(c, now: playlists.library.nowPlaying(c))
        let silent = !handoffCapable
        var reuse = controller ?? spare
        if let r = reuse, r.silent != silent {
            // stil ↔ met geluid wisselen kan niet met dezelfde engine
            r.stop()
            if controller === r { controller = nil }
            reuse = nil
        }
        let ctrl = reuse ?? {
            let p = PlayerController(item: item, silent: silent)
            p.isPreview = true
            p.muted = true
            return p
        }()
        ctrl.muted = !(handoffCapable && soundOn)
        spare = nil
        suspended = false
        blocked = false
        if controller !== ctrl { controller = ctrl }
        if channel?.id != c.id { channel = c }
        ctrl.prepareNew()
        ctrl.item = item
        // build 164: het voorbeeld telt mee voor de streamlimiet van het account (zoals gewoon afspelen, met ping);
        // soort "preview": telt niet voor de statistieken. Limiet bereikt: stilstaand beeld.
        let session = StreamSession.shared
        let r = await session.start(StreamSession.Info(title: c.name, kind: "preview", contentID: c.id), owner: self)
        guard gen == generation, channel?.id == c.id else { return }
        if case .limit = r {
            showBlocked(c)
            return
        }
        session.keepAliveInBackground = nil
        session.titleProvider = nil
        session.onLimit = { [weak self] _ in
            guard let self, let ch = self.channel else { return }
            self.showBlocked(ch)
        }
        session.onBackground = { [weak self] in self?.stop() }
        session.onForeground = nil
        guard let url = await playlists.resolve(item), gen == generation, channel?.id == c.id else {
            if gen == generation { ctrl.fail(L("No stream address available.")); showBlocked(c) }
            return
        }
        ctrl.start(url: url, forceApple: url.scheme.map { ["http", "https"].contains($0.lowercased()) } ?? false)
        watchForStill(ctrl, channel: c, gen: gen)
    }

    /// Geen live beeld: speler stil (bewaard), afmelden, de gids toont het stilstaande beeld of het logo.
    private func showBlocked(_ c: Channel) {
        generation += 1
        StreamSession.shared.stop(owner: self)
        if let ctrl = controller {
            ctrl.halt()
            spare = ctrl
            controller = nil
        }
        suspended = false
        if channel?.id != c.id { channel = c }
        if !blocked { blocked = true }
    }

    /// Build 164: zodra het voorbeeld een paar tellen echt speelt een stilstaand beeld voor de gids bewaren; bij een
    /// fout geen live beeld meer (stilstaand beeld, zonder melding).
    private func watchForStill(_ ctrl: PlayerController, channel c: Channel, gen: Int) {
        let key = GuideStills.key(c)
        Task { @MainActor [weak self] in
            var playing = 0
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, gen == self.generation, self.controller === ctrl else { return }
                if ctrl.errorText != nil { self.showBlocked(c); return }
                playing = ctrl.isPlaying && !ctrl.isBuffering ? playing + 1 : 0
                if playing >= 4 { GuideStills.shared.capture(ctrl, key: key); return }
            }
        }
    }

    /// Build 164: geluid van het voorbeeld aan of uit (telefoon: het luidsprekertje). Een stil voorbeeld kan geen
    /// geluid: dan opnieuw starten met een gewone speler.
    func setSound(_ on: Bool, playlists: PlaylistService) {
        soundOn = on
        guard let c = channel else { return }
        if let ctrl = controller, !ctrl.silent {
            ctrl.muted = !on
            return
        }
        if on {
            handoffCapable = true
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = nil
                await self.start(c, playlists: playlists)
            }
        }
    }

    /// Build 164: volledig scherm met DEZELFDE stream (zonder opnieuw te laden): de speler van het voorbeeld gaat naar
    /// het spelerscherm. Kan alleen als het voorbeeld een gewone speler is die nu deze zender speelt; anders nil.
    func takeForFullscreen(_ c: Channel) -> PlayerController? {
        guard let ctrl = controller, channel?.id == c.id, !ctrl.silent, !suspended, !blocked,
              ctrl.errorText == nil, ctrl.url != nil else { return nil }
        pending?.cancel()
        pending = nil
        generation += 1
        controller = nil
        channel = nil
        soundOn = false
        ctrl.isPreview = false
        ctrl.muted = false
        return ctrl
    }

    /// Weg uit Live TV of de gids, of er gaat echt iets spelen: stoppen. `release`: ook de bewaarde speler loslaten
    /// (scherm verlaten); anders blijft hij klaarstaan voor het volgende voorbeeld.
    func stop(release: Bool = false) {
        pending?.cancel()
        pending = nil
        pendingID = nil
        generation += 1
        suspended = false
        if blocked { blocked = false }
        StreamSession.shared.stop(owner: self)
        if let ctrl = controller {
            if release { ctrl.stop() } else { ctrl.halt(); spare = ctrl }
            controller = nil
        }
        if release, let s = spare {
            s.stop()
            spare = nil
        }
        if channel != nil { channel = nil }
    }
}

/// Het voorbeeldbeeld: de gedeelde speler, of een plaatsaanduiding met het zenderlogo.
struct ChannelPreviewView: View {
    @ObservedObject var preview = ChannelPreview.shared
    var placeholder: Channel?
    var cornerRadius: CGFloat = tvScaled(8)

    var body: some View {
        ZStack {
            Color.black
            if Screenshots.isActive, let c = placeholder ?? preview.channel {
                ScreenshotStill(channel: c)
            } else if let ctrl = preview.controller, preview.channel != nil {
                EngineView(controller: ctrl)
                PreviewStatus(controller: ctrl)
            } else if let c = placeholder ?? preview.channel {
                RemoteImage(url: c.logo, contentMode: .fit, placeholder: c.name).padding(tvScaled(24))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
    }
}

struct PreviewStatus: View {
    @ObservedObject var controller: PlayerController
    var body: some View {
        if controller.errorText != nil {
            Image(systemName: "video.slash").font(.system(size: tvScaled(22))).foregroundStyle(Theme.secondary)
        } else if controller.isBuffering {
            ProgressView().tint(.white)
        }
    }
}

/// Meldt of de knop waar dit in staat de focus heeft (Apple TV) — voor het zendervoorbeeld.
struct FocusProbe: View {
    let onChange: (Bool) -> Void
    @Environment(\.isFocused) private var focused
    var body: some View {
        Color.clear
            .onChange(of: focused) { _, f in onChange(f) }
            .onAppear { if focused { onChange(true) } }
    }
}
