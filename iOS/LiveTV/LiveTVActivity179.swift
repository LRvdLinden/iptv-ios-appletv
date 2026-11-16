import Foundation
import ActivityKit
import UIKit

/// Build 179: houdt de Live Activity van live tv bij (docs/ACCOUNT.md → "Build 179", punt 2). Start bij live kijken
/// (instelling `liveActivity.tv`, standaard aan), bijwerken bij zappen, pauze/afspelen en op de programmawissel
/// (timer, zonder push), stoppen bij het sluiten van de speler. Niet bij voorbeelden, Multiview of radio.
@MainActor
final class LiveTVActivity179 {
    static let shared = LiveTVActivity179()

    private var activity: Activity<LiveTVActivityAttributes>?
    private var lastState: LiveTVActivityAttributes.ContentState?
    private weak var player: PlayerController?
    /// Programma's opnieuw opzoeken (bij de programmawissel)
    private var provider: (() -> (Channel, EPGProgram?, EPGProgram?)?)?
    private var programTimer: Task<Void, Never>?

    /// Live tv speelt (of zapt): starten of bijwerken
    func sync(player: PlayerController, provider: @escaping () -> (Channel, EPGProgram?, EPGProgram?)?) {
        self.player = player
        self.provider = provider
        refresh()
    }

    func toggle() {
        guard let p = player else { return }
        p.togglePlay()
        refresh()
    }

    func refresh() {
        guard LiveTVSettings179.liveActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              let p = player, p.isLive, !p.isPreview, !p.silent, let (c, now, next) = provider?() else { stop(); return }
        let state = LiveTVActivityAttributes.ContentState(
            channelID: c.id, channel: CategoryName.channel(c.name),
            logo: c.logo.map { Radio174.logoFileName($0.absoluteString) },
            now: now.map { CategoryName.display($0.title) }, nowStart: now?.start, nowEnd: now?.end,
            next: next.map { CategoryName.display($0.title) }, nextStart: next?.start,
            isPlaying: p.isPlaying || p.isBuffering)
        scheduleProgramChange(now?.end)
        guard state != lastState else { return }
        if lastState?.logo != state.logo || activity == nil { writeLogo(c) }
        lastState = state
        if let a = activity {
            Task { await a.update(.init(state: state, staleDate: nil)) }
        } else {
            let attrs = LiveTVActivityAttributes(heading: "Bingr · " + L("Live TV"), nextLabel: L("Next"),
                                                 playLabel: L("Play"), pauseLabel: L("Pause"))
            activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: nil)
            if activity == nil { lastState = nil }
        }
    }

    func stop() {
        programTimer?.cancel(); programTimer = nil
        let a = activity
        activity = nil
        lastState = nil
        if let a { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        // ook achtergebleven activiteiten (bijv. na een crash)
        Task { for x in Activity<LiveTVActivityAttributes>.activities where x.id != a?.id { await x.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Op het einde van het programma opnieuw kijken (nu/straks schuiven door)
    private func scheduleProgramChange(_ end: Date?) {
        programTimer?.cancel()
        guard let end else { return }
        let wait = max(end.timeIntervalSinceNow + 2, 5)
        programTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func writeLogo(_ c: Channel) {
        guard let u = c.logo, let dir = RadioBridge174.container else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(Radio174.logoFileName(u.absoluteString))
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        Task.detached(priority: .userInitiated) {
            guard let cg = await ImagePipeline.shared.load(u, maxPixel: 120), let png = RadioBridge174.png(cg) else { return }
            try? png.write(to: file, options: .atomic)
            await MainActor.run {
                // het logo staat er nu: de activiteit opnieuw tekenen
                guard let a = LiveTVActivity179.shared.activity, let s = LiveTVActivity179.shared.lastState else { return }
                Task { await a.update(.init(state: s, staleDate: nil)) }
            }
        }
    }
}
