import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tegelijk kijken (build 51, docs/ACCOUNT.md): de stream van dit apparaat bij de Bingr-account aanmelden
/// (`stream_start`), elke 30 s `stream_ping` (ook bij pauze) en afmelden (`stream_stop`) bij sluiten of als de app
/// naar de achtergrond gaat — behalve bij beeld-in-beeld, AirPlay of Chromecast.
///
/// Eén stream per apparaat: zappen, de volgende aflevering en Multiview roepen gewoon opnieuw `start` aan;
/// de server vervangt dan de lopende stream. Netwerkfouten blokkeren het afspelen nooit.
@MainActor
final class StreamSession {
    static let shared = StreamSession()

    struct Info: Equatable {
        let title: String
        let kind: String
        let contentID: String
    }

    enum Result { case ok, limit(AccountService.StreamLimit) }

    /// Wat er nu op dit apparaat speelt (nil = niets).
    private(set) var current: Info?
    /// Op de achtergrond afgemeld; bij terugkeer naar de voorgrond opnieuw aanmelden.
    private var suspended = false
    private var generation = 0
    /// Wie de stream heeft aangemeld (speler of Multiview): een late stop van een vorige speler telt niet.
    private var owner: ObjectIdentifier?
    private var pingTask: Task<Void, Never>?
    /// Aanvragen op volgorde (een stop mag een nieuwe start niet inhalen).
    private var queue: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Gezet door het spelerscherm: `true` = op de achtergrond doorlopen (beeld-in-beeld, AirPlay, Chromecast).
    var keepAliveInBackground: (@MainActor () -> Bool)?
    /// Actuele titel voor de ping (bij live verandert het programma).
    var titleProvider: (@MainActor () -> String?)?
    /// Limiet bereikt bij een herstart (na `stopped` of terug uit de achtergrond): de speler stopt en toont het scherm.
    var onLimit: (@MainActor (AccountService.StreamLimit) -> Void)?

    private init() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StreamSession.shared.enteredBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StreamSession.shared.enteredForeground() }
        })
        #endif
    }

    // MARK: titel en soort

    /// Titel zoals het contract hem wil: bij live "Zender · Programma", bij een aflevering "Serie · S1:E2 · Titel".
    static func info(for item: PlayableItem) -> Info {
        let kind: String
        var title = item.title
        switch item.type {
        case .live:
            kind = "live"
            if let s = item.subtitle, !s.isEmpty { title += " · " + s }
        case .movie:
            kind = "movie"
        case .episode, .series:
            kind = "episode"
            if let s = item.subtitle, !s.isEmpty { title += " · " + s }
        }
        return Info(title: String(title.prefix(200)), kind: kind, contentID: item.channelID ?? item.id)
    }

    // MARK: aanmelden en afmelden

    /// Aanmelden. Bij `.limit` is de stream niet aangemeld en moet de speler stoppen.
    func start(_ info: Info, owner: AnyObject) async -> Result {
        generation += 1
        let gen = generation
        self.owner = ObjectIdentifier(owner)
        current = info
        suspended = false
        startPinging()
        let r = await send { await AccountService.shared.streamStart(profileID: Self.profileID, profileName: Self.profileName,
                                                                      title: info.title, kind: info.kind,
                                                                      contentID: info.contentID) }
        // intussen gezapt of gesloten: dit antwoord telt niet meer
        guard gen == generation else { return .ok }
        if case .limit(let l) = r {
            current = nil
            pingTask?.cancel(); pingTask = nil
            return .limit(l)
        }
        return .ok
    }

    func start(item: PlayableItem, owner: AnyObject) async -> Result { await start(Self.info(for: item), owner: owner) }

    /// Is deze speler (of Multiview) degene die nu aangemeld is?
    func isOwner(_ o: AnyObject) -> Bool { owner == ObjectIdentifier(o) }

    /// Afmelden (sluiten, stoppen), alleen als `owner` de stream heeft aangemeld.
    func stop(owner o: AnyObject) {
        guard owner == ObjectIdentifier(o) else { return }
        owner = nil
        guard current != nil || suspended else { return }
        generation += 1
        current = nil
        let wasSuspended = suspended
        suspended = false
        pingTask?.cancel(); pingTask = nil
        keepAliveInBackground = nil
        titleProvider = nil
        onLimit = nil
        if !wasSuspended { Task { await send { await AccountService.shared.streamStop() } } }
    }

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.ping()
            }
        }
    }

    private func ping() async {
        guard let info = current, !suspended else { return }
        let gen = generation
        let title = titleProvider?() ?? info.title
        let alive = await send { await AccountService.shared.streamPing(title: title) }
        guard !alive, gen == generation, let cur = current else { return }
        // telt niet meer (bijv. te lange pauze of verwijderd op een ander apparaat): opnieuw aanmelden
        let r = await AccountService.shared.streamStart(profileID: Self.profileID, profileName: Self.profileName,
                                                        title: titleProvider?() ?? cur.title, kind: cur.kind,
                                                        contentID: cur.contentID)
        guard gen == generation, case .limit(let l) = r else { return }
        reportLimit(l)
    }

    private func reportLimit(_ l: AccountService.StreamLimit) {
        let handler = onLimit
        current = nil
        pingTask?.cancel(); pingTask = nil
        handler?(l)
    }

    // MARK: achtergrond

    private func enteredBackground() {
        guard current != nil, !suspended else { return }
        if keepAliveInBackground?() == true { return }
        suspended = true
        generation += 1
        pingTask?.cancel(); pingTask = nil
        Task { await send { await AccountService.shared.streamStop() } }
    }

    private func enteredForeground() {
        guard suspended, let info = current else { return }
        suspended = false
        generation += 1
        let gen = generation
        startPinging()
        Task { @MainActor in
            let r = await self.send { await AccountService.shared.streamStart(profileID: Self.profileID, profileName: Self.profileName,
                                                                               title: self.titleProvider?() ?? info.title,
                                                                               kind: info.kind, contentID: info.contentID) }
            guard gen == self.generation, case .limit(let l) = r else { return }
            self.reportLimit(l)
        }
    }

    // MARK: hulp

    private static var profileID: String? { CloudStore.shared.activeProfile?.id.uuidString }
    private static var profileName: String? { CloudStore.shared.activeProfile?.name }

    /// Voert aanvragen na elkaar uit, in de volgorde waarin ze gedaan zijn.
    private func send<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        queue = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
