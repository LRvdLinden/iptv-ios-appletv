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

    /// Zendervoorbeeld in Live TV en de tv-gids (standaard aan; op een iPhone niet via mobiel internet).
    static let previewKey = "live.preview"
    static var previewEnabled: Bool { UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true }

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
    }

    /// Mag er nu een voorbeeld spelen?
    var allowed: Bool {
        PlayerSettings.previewEnabled && !(PlayerSettings.isPhone && NetworkStatus.shared.isCellular)
    }

    /// Een zender is geselecteerd (focus op Apple TV, aanwijzer op iPad/Mac): als de selectie blijft staan het
    /// voorbeeld starten. `nil` = selectie weg; het lopende voorbeeld blijft dan staan.
    func select(_ c: Channel?, playlists: PlaylistService, delay: Double = 1.2, floating: Bool = true) {
        pending?.cancel()
        pending = nil
        ScrollActivity.shared.touch()   // focus gaat door de lijst: ander zwaar werk even laten wachten
        guard let c, allowed else { return }
        let now = Date()
        let scrolling = now.timeIntervalSince(lastSelect) < Self.scrollGap
        lastSelect = now
        if channel?.id == c.id && !suspended { return }   // speelt al
        if self.floating != floating { self.floating = floating }
        let wait = delay
        if scrolling && delay > 0 {
            // snel scrollen: niet decoderen terwijl de lijst beweegt; starten zodra de focus even rust
            suspend(showing: c)
        }
        pending = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            await self.start(c, playlists: playlists)
        }
    }

    /// Beeld stilzetten (speler blijft bewaard); een al zichtbaar voorbeeld volgt de selectie met het logo.
    private func suspend(showing c: Channel) {
        generation += 1   // een lopende start (stream opzoeken) is niet meer nodig
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
        generation += 1
        let gen = generation
        let item = Playables.channel(c, now: playlists.library.nowPlaying(c))
        let ctrl = controller ?? spare ?? {
            let p = PlayerController(item: item, silent: true)
            p.isPreview = true
            p.muted = true
            return p
        }()
        spare = nil
        suspended = false
        if controller !== ctrl { controller = ctrl }
        if channel?.id != c.id { channel = c }
        ctrl.prepareNew()
        ctrl.item = item
        guard let url = await playlists.resolve(item), gen == generation, channel?.id == c.id else {
            if gen == generation { ctrl.fail(L("No stream address available.")) }
            return
        }
        ctrl.start(url: url, forceApple: url.scheme.map { ["http", "https"].contains($0.lowercased()) } ?? false)
    }

    /// Weg uit Live TV of de gids, of er gaat echt iets spelen: stoppen. `release`: ook de bewaarde speler loslaten
    /// (scherm verlaten); anders blijft hij klaarstaan voor het volgende voorbeeld.
    func stop(release: Bool = false) {
        pending?.cancel()
        pending = nil
        generation += 1
        suspended = false
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
            if let ctrl = preview.controller, preview.channel != nil {
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

private struct PreviewStatus: View {
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
