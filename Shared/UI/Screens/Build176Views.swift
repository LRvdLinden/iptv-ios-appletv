import SwiftUI

// Build 176 (versie 1.0.8): automatisch volgende aflevering per profiel (2) en vergrendelen met pincode (5)
// (momenten bewaren is sinds build 178 vervallen). Contract: docs/ACCOUNT.md → "Build 176"; pure logica in `Build176` (Shared/Account/Build176.swift).

// MARK: - Opslag per profiel (gesynct via `profile.<id>`, zie StateSync.merge176)

@MainActor
final class Profile176: ObservableObject {
    static let shared = Profile176()

    struct Autoplay: Codable, Equatable { var value: Bool; var at: Double }

    /// Verandert bij elke wijziging (schermen tekenen opnieuw)
    @Published private(set) var revision = 0

    private let defaults = UserDefaults.standard
    private func apKey(_ id: UUID) -> String { "autoplayNext.v176.\(id.uuidString)" }
    private static let unlockedKey = "locks.unlocked.v176"

    private var store: CloudStore { CloudStore.shared }
    /// Nu, afgerond op milliseconden (zoals in ISO-8601 bewaard)
    private static var nowMS: Double { (Date().timeIntervalSince1970 * 1000).rounded() / 1000 }
    private var current: UUID? { store.activeProfileID ?? store.mainProfileID }

    // MARK: automatisch volgende aflevering

    func autoplay(_ id: UUID) -> Autoplay? {
        defaults.data(forKey: apKey(id)).flatMap { try? JSONDecoder().decode(Autoplay.self, from: $0) }
    }

    /// Effectieve keuze van het actieve profiel (niet ingesteld = aan, kinderprofiel uit)
    var autoplayNext: Bool {
        _ = revision
        guard let id = current else { return true }
        return autoplay(id)?.value ?? !(store.activeProfile?.kids ?? false)
    }

    func setAutoplayNext(_ on: Bool) {
        guard let id = current else { return }
        setSyncedAutoplay(id, Autoplay(value: on, at: Self.nowMS))
        store.stateEdited.send((id, .profile))
    }

    func setSyncedAutoplay(_ id: UUID, _ a: Autoplay) {
        guard a != autoplay(id) else { return }
        if let d = try? JSONEncoder().encode(a) { defaults.set(d, forKey: apKey(id)) }
        revision += 1
    }

    // MARK: vergrendeld: 4 uur open na de pincode (alleen dit apparaat)

    private var unlocked: [String: Double] {
        get { defaults.dictionary(forKey: Self.unlockedKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.unlockedKey) }
    }

    var mainHasPIN: Bool {
        guard let main = store.mainProfileID else { return false }
        return ParentalControl.shared.hasPIN(profile: main)
    }

    /// Moet het openen van dit item (sleutel) eerst de pincode van het hoofdprofiel vragen?
    func asks(_ key: String?) -> Bool {
        guard let key else { return false }
        return Build176.lockAsks(locked: true, hasMainPin: mainHasPIN, unlockedAt: unlocked[key.lowercased()],
                                 now: Date().timeIntervalSince1970)
    }

    func markUnlocked(_ key: String) {
        let now = Date().timeIntervalSince1970
        var u = unlocked.filter { now - $0.value < Build176.unlockSeconds }
        u[key.lowercased()] = now
        unlocked = u
        revision += 1
    }
}

// MARK: - Vergrendelde zenders en titels

extension CloudStore {
    /// Sleutel van een vergrendelde zender (nil = niet vergrendeld)
    func lockedChannelKey(_ server: UUID?, _ item: String) -> String? {
        guard let server = server ?? activePlaylistID,
              ProfileHide171.contains(lockedChannels, server: server.uuidString, kind: nil, item: item) else { return nil }
        return ProfileHide171.channelKey(server: server.uuidString, item: item)
    }

    func lockedTitleKey(_ server: UUID?, _ kind: ProfileHide171.Kind, _ item: String) -> String? {
        guard let server = server ?? activePlaylistID,
              ProfileHide171.contains(lockedTitles, server: server.uuidString, kind: kind, item: item) else { return nil }
        return ProfileHide171.titleKey(server: server.uuidString, kind: kind, item: item)
    }

    /// Sleutel van wat hier gaat spelen, als dat vergrendeld is (zender, film of de serie van een aflevering)
    func lockedKey(_ it: PlayableItem) -> String? {
        let server = it.sourceID ?? activePlaylistID
        switch it.type {
        case .live: return lockedChannelKey(server, it.channelID ?? it.id)
        case .movie: return lockedTitleKey(server, .movie, it.id)
        default:
            if let s = it.seriesID { return lockedTitleKey(server, .series, s) }
            return nil
        }
    }

    func setChannelLocked(_ server: UUID, _ item: String, _ on: Bool) {
        if on {
            updateProfileSet(.lockedChannels, insert: [ProfileHide171.channelKey(server: server.uuidString, item: item)])
        } else {
            updateProfileSet(.lockedChannels, remove: ProfileHide171.variants(lockedChannels, server: server.uuidString, kind: nil, item: item))
        }
    }

    func setTitleLocked(_ server: UUID, _ kind: ProfileHide171.Kind, _ item: String, _ on: Bool) {
        if on {
            updateProfileSet(.lockedTitles, insert: [ProfileHide171.titleKey(server: server.uuidString, kind: kind, item: item)])
        } else {
            updateProfileSet(.lockedTitles, remove: ProfileHide171.variants(lockedTitles, server: server.uuidString, kind: kind, item: item))
        }
    }
}

/// Vraagt de pincode van het hoofdprofiel vóór het openen van iets vergrendelds. Het bovenste scherm met
/// `.lockGate176()` toont het pincodeblad (de app zelf, een detailpagina in een blad, de speler).
@MainActor
final class LockGate176: ObservableObject {
    static let shared = LockGate176()

    struct Request: Identifiable {
        let id = UUID()
        let key: String
        let run: () -> Void
        let cancel: (() -> Void)?
    }

    @Published var request: Request?
    @Published private(set) var top: UUID?
    private var hosts: [UUID] = []

    func push(_ id: UUID) { hosts.removeAll { $0 == id }; hosts.append(id); top = hosts.last }
    func pop(_ id: UUID) { hosts.removeAll { $0 == id }; top = hosts.last }

    /// `run` meteen, of pas na de juiste pincode (dan is het item 4 uur open op dit apparaat)
    func open(_ key: String?, cancel: (() -> Void)? = nil, run: @escaping () -> Void) {
        guard let key, Profile176.shared.asks(key) else { run(); return }
        request = Request(key: key, run: run, cancel: cancel)
    }

    /// Alleen de pincode (bijv. ontgrendelen in het overzicht)
    func confirm(_ run: @escaping () -> Void) {
        guard Profile176.shared.mainHasPIN else { run(); return }
        request = Request(key: "", run: run, cancel: nil)
    }

    func answered(_ r: Request, ok: Bool) {
        guard request?.id == r.id else { return }
        request = nil
        if ok {
            if !r.key.isEmpty { Profile176.shared.markUnlocked(r.key) }
            // na het sluiten van het blad (anders kan bijv. de speler niet verschijnen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { r.run() }
        } else {
            r.cancel?()
        }
    }
}

private struct LockGate176Host: ViewModifier {
    @ObservedObject private var gate = LockGate176.shared
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { gate.push(id) }
            .onDisappear { gate.pop(id) }
            .sheet(item: Binding(get: { gate.top == id ? gate.request : nil },
                                 set: { v in if v == nil, let r = gate.request, gate.top == id { gate.answered(r, ok: false) } })) { r in
                PINPad(title: L("Enter the PIN of the main profile")) { pin in
                    guard let main = CloudStore.shared.mainProfileID, ParentalControl.shared.verify(pin, profile: main) else { return false }
                    gate.answered(r, ok: true)
                    return true
                }
            }
    }
}

extension View {
    /// Build 176: hier mag het pincodeblad voor vergrendelde zenders en titels verschijnen
    func lockGate176() -> some View { modifier(LockGate176Host()) }
}

/// "Vergrendelen met pincode" / "Ontgrendelen" in het menu van een zender
struct LockChannelMenuItem: View {
    let channel: Channel
    let server: UUID?
    @ObservedObject private var store = CloudStore.shared
    @State private var noPIN = false

    var body: some View {
        if let server = channel.sourceID ?? server {
            let locked = store.lockedChannelKey(server, channel.id) != nil
            Button {
                toggle(locked: locked, server: server)
            } label: {
                Label(locked ? L("Unlock") : L("Lock with PIN"), systemImage: locked ? "lock.open" : "lock")
            }
        }
    }

    private func toggle(locked: Bool, server: UUID) {
        let id = channel.id
        if locked {
            LockGate176.shared.confirm { CloudStore.shared.setChannelLocked(server, id, false) }
        } else if Profile176.shared.mainHasPIN {
            CloudStore.shared.setChannelLocked(server, id, true)
        } else {
            LockNotice176.shared.show()
        }
    }
}

/// "Vergrendelen met pincode" / "Ontgrendelen" in het menu of op de detailpagina van een film of serie
struct LockTitleMenuItem: View {
    let target: DetailTarget
    let server: UUID?
    @ObservedObject private var store = CloudStore.shared

    var body: some View {
        if let server = target.sourceID ?? server, !DiscoverItem.isExternal(target.id) {
            let kind = target.hideKind171
            let id = target.id
            let locked = store.lockedTitleKey(server, kind, id) != nil
            Button {
                if locked {
                    LockGate176.shared.confirm { CloudStore.shared.setTitleLocked(server, kind, id, false) }
                } else if Profile176.shared.mainHasPIN {
                    CloudStore.shared.setTitleLocked(server, kind, id, true)
                } else {
                    LockNotice176.shared.show()
                }
            } label: {
                Label(locked ? L("Unlock") : L("Lock with PIN"), systemImage: locked ? "lock.open" : "lock")
            }
        }
    }
}

/// Melding "Stel eerst een pincode in voor het hoofdprofiel" (vanuit een menu, waar geen eigen melding kan)
@MainActor
final class LockNotice176: ObservableObject {
    static let shared = LockNotice176()
    @Published var visible = false
    func show() { visible = true }
}

private struct LockNoticeHost: ViewModifier {
    @ObservedObject private var notice = LockNotice176.shared
    func body(content: Content) -> some View {
        content.alert(L("Set a PIN for the main profile first"), isPresented: $notice.visible) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(L("You can set the PIN in Settings under Profiles."))
        }
    }
}

extension View {
    func lockNotice176() -> some View { modifier(LockNoticeHost()) }
}

/// Instellingen → Profielen: "Vergrendeld"
struct LockedItemsSection: View {
    @ObservedObject private var store = CloudStore.shared

    var body: some View {
        Section {
            NavigationLink { LockedItemsView() } label: {
                HStack {
                    Label(L("Locked"), systemImage: "lock")
                    Spacer()
                    let n = store.lockedChannels.count + store.lockedTitles.count
                    if n > 0 { Text(verbatim: "\(n)").foregroundStyle(Theme.secondary) }
                }
            }
        } footer: {
            Text(L("Lock a channel, movie or series with a long press. Opening it asks for the PIN of the main profile; after that it stays open for 4 hours on this device."))
        }
    }
}

struct LockedItemsView: View {
    @ObservedObject private var store = CloudStore.shared
    @EnvironmentObject var playlists: PlaylistService

    private struct Row: Identifiable {
        let id: String
        let field: CloudStore.ProfileSet171
        let title: String
        let detail: String?
        let image: URL?
    }

    private var rows: [Row] {
        let raw = playlists.rawLibrary
        var channels: [String: Channel] = [:], movies: [String: Movie] = [:], series: [String: Series] = [:]
        for c in raw.channels where channels[c.id] == nil { channels[c.id] = c }
        for m in raw.movies where movies[m.id] == nil { movies[m.id] = m }
        for s in raw.series where series[s.id] == nil { series[s.id] = s }
        let keys = store.lockedChannels.sorted().map { ($0, CloudStore.ProfileSet171.lockedChannels) }
            + store.lockedTitles.sorted().map { ($0, CloudStore.ProfileSet171.lockedTitles) }
        return keys.compactMap { k, field in
            guard let p = ProfileHide171.parse(k) else { return nil }
            switch p.kind {
            case nil:
                let c = channels[p.item]
                return Row(id: k, field: field, title: c.map { CategoryName.channel($0.name) } ?? p.item, detail: L("Channel"), image: c?.logo)
            case .movie?:
                let m = movies[p.item]
                return Row(id: k, field: field, title: m?.title ?? p.item, detail: L("Movie"), image: m?.poster)
            case .series?:
                let s = series[p.item]
                return Row(id: k, field: field, title: s?.title ?? p.item, detail: L("Series"), image: s?.poster)
            }
        }
    }

    var body: some View {
        List {
            Section {
                let list = rows
                if list.isEmpty { Text(L("Nothing locked.")).foregroundStyle(Theme.secondary) }
                ForEach(list) { r in
                    HStack(spacing: tvScaled(12)) {
                        RemoteImage(url: r.image, contentMode: .fit, placeholder: r.field == .lockedChannels ? "tv" : "film", maxPixel: 160)
                            .frame(width: tvScaled(44), height: tvScaled(44))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).lineLimit(2)
                            if let d = r.detail { Text(d).font(.caption).foregroundStyle(Theme.secondary) }
                        }
                        Spacer()
                        Button(L("Unlock")) {
                            let field = r.field, key = r.id
                            LockGate176.shared.confirm { CloudStore.shared.updateProfileSet(field, remove: [key]) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } footer: {
                if !Profile176.shared.mainHasPIN {
                    Text(L("The main profile has no PIN: locked items open without a PIN."))
                }
            }
        }
        .navigationTitle(L("Locked"))
        .lockGate176()
    }
}

/// Melding op de detailpagina van een vergrendelde titel, met "Ontgrendelen"
struct LockedTitleNotice: View {
    let key: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: tvScaled(16)) {
                Image(systemName: "lock.fill").font(.system(size: tvScaled(40))).foregroundStyle(.white)
                Text(L("This title is locked"))
                    .font(.system(size: tvScaled(22), weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(L("Enter the PIN of the main profile to open it."))
                    .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                NetflixButton(title: L("Unlock"), icon: "lock.open", kind: .primary) {
                    LockGate176.shared.open(key) {}
                }
                NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary) { onClose() }
            }
            .padding(Theme.edge)
            .frame(maxWidth: tvScaled(560))
        }
    }
}

// MARK: - Automatisch volgende aflevering (Instellingen → Afspelen)

struct AutoplayNextSettingsSection: View {
    @ObservedObject private var p176 = Profile176.shared
    @ObservedObject private var store = CloudStore.shared

    var body: some View {
        if store.activeProfileID != nil {
            Section {
                Toggle(isOn: Binding(get: { p176.autoplayNext }, set: { p176.setAutoplayNext($0) })) {
                    Label(L("Play next episode automatically"), systemImage: "forward.end.alt")
                }
            } footer: {
                Text(L("For this profile. When off, the Next episode button stays, but doesn't start by itself."))
            }
        }
    }
}

// MARK: - Data besparen op mobiel netwerk (Instellingen → Afspelen, alleen iPhone en iPad)

struct DataSaverSettingsSection: View {
    @AppStorage(DataSaver176.key) private var mode = Build176.DataMode.auto.rawValue

    var body: some View {
        #if os(iOS)
        Section {
            Picker(L("On cellular"), selection: $mode) {
                ForEach(Build176.DataMode.allCases, id: \.rawValue) { Text(DataSaver176.title($0)).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
        } footer: {
            Text(L("Save data plays at most about 1.5 Mbit/s in SD, without live previews or trailers. Automatic saves data when Low Data Mode is on. Wi-Fi is never limited."))
        }
        #else
        EmptyView()
        #endif
    }
}
