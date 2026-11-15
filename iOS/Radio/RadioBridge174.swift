import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import WidgetKit
#if os(iOS)
import UIKit
import ActivityKit
#else
import AppKit
#endif

// Build 175: ook in de Mac-app (widget "Bingr Radio" op de Mac). De Live Activity en CarPlay blijven iPhone/iPad.

/// Build 174: voert de knoppen van de widget en de Live Activity uit (in de app).
@MainActor
enum RadioIntentHandler {
    static func play(_ id: String) async {
        let r = RadioPlayer.shared
        if r.channel?.id == id, !r.isPlaying { r.togglePlay(); return }
        if let c = await r.waitForStation(id: id) {
            r.play(c)
        } else {
            // bibliotheek nog niet klaar: starten zodra hij er is (RadioBridge174)
            UserDefaults.standard.set(id, forKey: Radio174.pendingKey)
        }
    }

    static func toggle() async {
        let r = RadioPlayer.shared
        if r.channel != nil { r.togglePlay(); return }
        // niets aan het spelen: de zender van de widget (laatst gespeeld of eerste favoriet)
        if let id = RadioBridge174.shared.lastSnapshot.flatMap(Radio174.featured)?.id { await play(id) }
    }

    static func step(_ d: Int) async { await RadioPlayer.shared.stepLoaded(d >= 0 ? 1 : -1) }
}

/// Build 174: houdt de widget "Bingr Radio" (zenderlijst en logo's in de App Group) en de Live Activity bij.
@MainActor
final class RadioBridge174 {
    static let shared = RadioBridge174()

    private var bag = Set<AnyCancellable>()
    private var started = false
    #if os(iOS)
    private var activity: Activity<RadioActivityAttributes>?
    private var lastState: RadioActivityAttributes.ContentState?
    #endif
    private(set) var lastSnapshot: Radio174.Snapshot?
    private var writeTask: Task<Void, Never>?
    private var logoTask: Task<Void, Never>?

    /// Instelling (Instellingen → Speler): Live Activity bij radio, standaard aan
    static var liveActivityEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Radio174.liveActivityKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Radio174.liveActivityKey) }
    }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Radio174.appGroup)?
            .appendingPathComponent("radio", isDirectory: true)
    }

    func start() {
        guard !started else { return }
        started = true
        lastSnapshot = Self.readSnapshot()
        #if os(iOS)
        // oude Live Activities van een vorige keer (app gestopt tijdens radio) opruimen
        Task { for a in Activity<RadioActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) } }
        #endif
        let r = RadioPlayer.shared
        Publishers.Merge4(r.$channel.map { _ in () }.eraseToAnyPublisher(),
                          r.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                          r.$isBuffering.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                          r.$streamTitle.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.syncActivity()
                self?.scheduleWrite(stationsChanged: false)
            }
            .store(in: &bag)
        CloudStore.shared.$favorites.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWrite(stationsChanged: true) }
            .store(in: &bag)
        #if os(iOS)
        let becameActive = UIApplication.didBecomeActiveNotification
        #else
        let becameActive = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: becameActive)
            .sink { [weak self] _ in self?.syncActivity(); self?.scheduleWrite(stationsChanged: true) }
            .store(in: &bag)
        // de bibliotheek komt pas later (service wordt door AppState gezet)
        Task { @MainActor [weak self] in
            while RadioPlayer.shared.service == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard let self, let service = RadioPlayer.shared.service else { return }
            service.$libraryVersion.removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.scheduleWrite(stationsChanged: true)
                    self?.playPending()
                }
                .store(in: &self.bag)
        }
    }

    /// Instelling gewijzigd
    func settingChanged() { syncActivity() }

    // MARK: widget

    private func playPending() {
        guard let id = UserDefaults.standard.string(forKey: Radio174.pendingKey),
              let c = RadioPlayer.shared.station(id: id) else { return }
        UserDefaults.standard.removeObject(forKey: Radio174.pendingKey)
        RadioPlayer.shared.play(c)
    }

    private func scheduleWrite(stationsChanged: Bool) {
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.writeSnapshot(withLogos: stationsChanged)
        }
    }

    private func writeSnapshot(withLogos: Bool) {
        let r = RadioPlayer.shared
        guard let dir = Self.container else { return }
        let list = r.stations()
        let pid = r.service?.source?.id
        let store = CloudStore.shared
        // geen bibliotheek (nog niet geladen): de vorige lijst houden, alleen de stand bijwerken
        var stations = list.prefix(Radio174.maxStations).map { c in
            Radio174.Station(id: c.id, name: CategoryName.channel(c.name), logo: c.logo.map { Radio174.logoFileName($0.absoluteString) },
                             favorite: (c.sourceID ?? pid).map { store.isFavorite($0, c.id) } ?? false,
                             group: CategoryName.clean(c.group))
        }
        if stations.isEmpty, r.service?.library.isEmptyLibrary ?? true { stations = lastSnapshot?.stations ?? [] }
        let snap = Radio174.Snapshot(stations: Array(stations), currentID: r.channel?.id, isPlaying: r.isPlaying,
                                     nowPlaying: r.nowPlayingText, texts: Self.widgetTexts)
        guard snap.withoutDate != lastSnapshot?.withoutDate else { return }
        lastSnapshot = snap
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = snap.encoded() {
            try? data.write(to: dir.appendingPathComponent("stations.json"), options: .atomic)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Radio174.widgetKind)
        if withLogos { writeLogos(list, dir: dir) }
    }

    /// Logo's klein (max. 120 px) in de App Group voor de widget, de Live Activity en CarPlay; alleen nieuwe
    private func writeLogos(_ list: [Channel], dir: URL, single: Bool = false) {
        let wanted = Array(list.prefix(Radio174.maxStations)).compactMap(\.logo)
        if !single { logoTask?.cancel() }
        let task = Task.detached(priority: single ? .userInitiated : .utility) {
            var wrote = false
            for u in wanted {
                if Task.isCancelled { return }
                let file = dir.appendingPathComponent(Radio174.logoFileName(u.absoluteString))
                if FileManager.default.fileExists(atPath: file.path) { continue }
                guard let cg = await ImagePipeline.shared.load(u, maxPixel: 120),
                      let png = RadioBridge174.png(cg) else { continue }
                try? png.write(to: file, options: .atomic)
                wrote = true
            }
            if wrote { await MainActor.run { WidgetCenter.shared.reloadTimelines(ofKind: Radio174.widgetKind) } }
        }
        if !single { logoTask = task }
    }

    static func readSnapshot() -> Radio174.Snapshot? {
        guard let dir = container else { return nil }
        return Radio174.Snapshot.decode(try? Data(contentsOf: dir.appendingPathComponent("stations.json")))
    }

    /// Build 175: PNG zonder UIKit (ook op de Mac)
    nonisolated static func png(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    #if os(iOS)
    /// Logo uit de App Group (voor CarPlay als het nog niet in het geheugen staat)
    static func logo(for c: Channel) -> UIImage? {
        guard let u = c.logo, let dir = container else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(Radio174.logoFileName(u.absoluteString)).path)
    }
    #endif

    /// Teksten voor de widget (in de app-taal; de widget zelf heeft geen vertalingen)
    static var widgetTexts: [String: String] {
        ["title": "Bingr Radio", "empty": L("Open Bingr to choose your radio stations."), "radio": L("Radio"),
         "favorites": L("Favorites"), "play": L("Play"), "pause": L("Pause")]
    }

    // MARK: Live Activity

    #if os(macOS)
    /// Geen Live Activity op de Mac
    private func syncActivity() {}
    #else
    private func makeState() -> RadioActivityAttributes.ContentState? {
        let r = RadioPlayer.shared
        guard let c = r.channel else { return nil }
        return .init(stationID: c.id, station: CategoryName.channel(c.name), nowPlaying: r.nowPlayingText,
                     logo: c.logo.map { Radio174.logoFileName($0.absoluteString) }, isPlaying: r.isPlaying,
                     isBuffering: r.isBuffering)
    }

    private func syncActivity() {
        let state = makeState()
        let allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        let step = Radio174.activityStep(enabled: Self.liveActivityEnabled, allowed: allowed,
                                         playingStation: state?.stationID, running: activity != nil, changed: state != lastState)
        switch step {
        case .start:
            guard let state else { return }
            // logo van deze zender meteen klaarzetten (de Live Activity leest het bestand)
            if let c = RadioPlayer.shared.channel, let dir = Self.container { writeLogos([c], dir: dir, single: true) }
            let attrs = RadioActivityAttributes(heading: "Bingr Radio", playLabel: L("Play"), pauseLabel: L("Pause"),
                                                nextLabel: L("Next station"), previousLabel: L("Previous station"))
            activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: nil)
            lastState = activity == nil ? nil : state
        case .update:
            guard let state, let a = activity else { return }
            lastState = state
            Task { await a.update(.init(state: state, staleDate: nil)) }
        case .end:
            let a = activity
            activity = nil
            lastState = nil
            Task { await a?.end(nil, dismissalPolicy: .immediate) }
        case .none:
            break
        }
    }
    #endif
}
