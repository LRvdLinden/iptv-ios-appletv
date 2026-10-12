import Foundation
import Combine

/// Deinterlacing voor VLC (build 52). Gedeeld met Android via `settings.shared.deinterlace` ("off", "auto", "on").
enum DeinterlaceMode: String, CaseIterable, Identifiable {
    case off, auto, on
    var id: String { rawValue }
    static let key = "player.deinterlace"

    static var current: DeinterlaceMode {
        DeinterlaceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    var title: String {
        switch self {
        case .off: return L("Off")
        case .auto: return L("Automatic")
        case .on: return L("On")
        }
    }

    /// VLC-opties voor de media (`--deinterlace`: 0 = uit, -1 = automatisch, 1 = aan; yadif2x behoudt 50/60 beelden per seconde)
    var vlcOptions: [String] {
        switch self {
        case .off: return [":deinterlace=0"]
        case .auto: return [":deinterlace=-1", ":deinterlace-mode=yadif2x"]
        case .on: return [":deinterlace=1", ":deinterlace-mode=yadif2x"]
        }
    }
}

extension PlayerSettings {
    /// Na het kiezen van een profiel meteen de laatst bekeken zender van dat profiel openen (build 52, standaard uit).
    /// Gedeeld met Android via `settings.shared.resumeLastChannel`.
    static let resumeLastChannelKey = "player.resumeLastChannel"
    static var resumeLastChannel: Bool { UserDefaults.standard.bool(forKey: resumeLastChannelKey) }
}

/// Intro en aftiteling van een serie (seconden). Eén keer instellen, geldt voor elke aflevering.
struct IntroMarker: Codable, Equatable {
    var introStart: Double?
    var introEnd: Double?
    var creditsStart: Double?

    var isEmpty: Bool { introStart == nil && introEnd == nil && creditsStart == nil }

    /// Ligt `t` in de intro? (zonder begin: vanaf het begin van de aflevering)
    func inIntro(_ t: Double) -> Bool {
        guard let end = introEnd, end > 0 else { return false }
        let start = max(0, introStart ?? 0)
        return t >= start && t < end - 1
    }
}

/// Intro-markeringen per serie (build 52). Sleutel `"<serverID>:<serieID>"`; gesynchroniseerd via
/// `settings.shared.introMarkers` (zie docs/ACCOUNT.md → Build 52). Sleutels worden zonder hoofdletters vergeleken.
@MainActor
final class IntroMarkers: ObservableObject {
    static let shared = IntroMarkers()
    static let defaultsKey = "player.introMarkers"

    @Published private(set) var all: [String: IntroMarker] = [:]

    private init() {
        all = Self.load()
        // gewijzigd door de account-sync (of een ander scherm) → opnieuw lezen
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let fresh = Self.load()
                if fresh != self.all { self.all = fresh }
            }
            .store(in: &bag)
    }
    private var bag = Set<AnyCancellable>()

    /// Sleutel voor een serie op een server (server-ID zoals in de Bingr-account).
    static func key(source: UUID?, series: String?) -> String? {
        guard let series, !series.isEmpty else { return nil }
        let server = source.map { SourceSync.shared.serverID(for: $0) } ?? ""
        return "\(server):\(series)"
    }

    func marker(_ key: String?) -> IntroMarker? {
        guard let key else { return nil }
        if let m = all[key] { return m }
        let low = key.lowercased()
        return all.first { $0.key.lowercased() == low }?.value
    }

    func update(_ key: String, _ change: (inout IntroMarker) -> Void) {
        let existing = all.first { $0.key.lowercased() == key.lowercased() }?.key ?? key
        var m = all[existing] ?? IntroMarker()
        change(&m)
        var next = all
        if m.isEmpty { next[existing] = nil } else { next[existing] = m }
        all = next
        Self.save(next)
    }

    // MARK: opslag (UserDefaults, zodat de instellingen-sync wijzigingen ziet)

    static func load() -> [String: IntroMarker] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let m = try? JSONDecoder().decode([String: IntroMarker].self, from: d) else { return [:] }
        return m
    }

    static func save(_ m: [String: IntroMarker]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }

    /// Voor `settings.shared.introMarkers`
    static func syncJSON() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, m) in load() where !m.isEmpty {
            out[k] = ["introStart": m.introStart.map { $0 as Any } ?? NSNull(),
                      "introEnd": m.introEnd.map { $0 as Any } ?? NSNull(),
                      "creditsStart": m.creditsStart.map { $0 as Any } ?? NSNull()] as [String: Any]
        }
        return out
    }

    /// Van de account: het geheel vervangt de lokale markeringen (instellingen: nieuwste `updatedAt` wint).
    static func apply(syncJSON j: [String: Any]) {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        var out: [String: IntroMarker] = [:]
        for (k, v) in j {
            guard let d = v as? [String: Any] else { continue }
            let m = IntroMarker(introStart: num(d["introStart"]), introEnd: num(d["introEnd"]), creditsStart: num(d["creditsStart"]))
            if !m.isEmpty { out[k] = m }
        }
        if out != load() { save(out) }
    }
}
