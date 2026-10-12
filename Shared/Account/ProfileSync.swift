import Foundation
import Combine
import CryptoKit

/// Profielen per Bingr-account (tabel `account_data`), zie docs/ACCOUNT.md → "Profielen migreren en delen".
///
/// Na inloggen en bij het starten met een geldige sessie: lezen, dan migreren (server leeg),
/// importeren (lokaal alleen het automatische hoofdprofiel of niets) of samenvoegen op `id`.
/// Daarna gaat elke wijziging (met ~2 s vertraging) als hele lijst naar de server.
/// Pincodes en eigen foto's gaan nooit mee. Fouten zijn stil en blokkeren de app nooit.
@MainActor
final class ProfileSync {
    static let shared = ProfileSync()

    private var bag = Set<AnyCancellable>()
    /// `account_data` is gelezen: pas daarna mag er geüpload worden (anders zou een lege/automatische
    /// lokale lijst de profielen op de server overschrijven).
    private var ready = false
    private var running: Task<Void, Never>?
    private var lastUploaded: Data?
    /// Onbekende velden van de server per profiel (bewaren en weer meesturen)
    private let extrasKey = "account.profileExtras.v1"
    /// Velden die nooit naar de server gaan
    private static let privateKeys = ["pin", "pinCode", "pin_code", "photo", "photoData", "customPhoto"]

    private init() {}

    /// Wijzigingen in profielen volgen (eenmalig).
    func start() {
        guard bag.isEmpty else { return }
        let store = CloudStore.shared
        store.$profiles.combineLatest(store.$mainProfileIDStored)
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.uploadIfChanged() }
            .store(in: &bag)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.reset() }
            }
            .store(in: &bag)
    }

    /// Lezen + migreren/importeren/samenvoegen + uploaden. Stil bij fouten.
    func syncNow() async {
        start()
        if let running {
            await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
            return
        }
        let t = Task { await self.performSync() }
        running = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        running = nil
    }

    private func reset() {
        running?.cancel()
        ready = false
        lastUploaded = nil
        UserDefaults.standard.removeObject(forKey: extrasKey)
    }

    // MARK: - Synchroniseren

    private struct Remote {
        let profile: ViewerProfile
        let isMain: Bool
        let order: Int
        let raw: [String: Any]
    }

    private func performSync() async {
        let account = AccountService.shared
        guard Secrets.accountsConfigured, account.isSignedIn else { return }
        let rows: [[String: Any]]
        do { rows = try await account.fetchAccountProfiles() ?? [] } catch { return }
        guard !Task.isCancelled, account.isSignedIn else { return }

        let store = CloudStore.shared
        var seen = Set<UUID>()
        let remote = rows.enumerated().compactMap { Self.decode($0.element, index: $0.offset) }
            .filter { seen.insert($0.profile.id).inserted }
            .sorted { $0.order < $1.order }
        // onbekende velden bewaren
        var extras = loadExtras()
        for r in remote { extras[r.profile.id.uuidString] = r.raw }
        saveExtras(extras)

        let local = store.profiles
        let remoteIDs = Set(remote.map(\.profile.id))
        // "lokaal geen profielen": niets, of alleen het automatische hoofdprofiel (dat niet op de server staat)
        let localEmpty = local.isEmpty || (local.count == 1 && !remoteIDs.contains(local[0].id))

        if remote.isEmpty {
            // migreren: lokale profielen uploaden (of niets te doen)
            ready = true
            if !local.isEmpty { await upload(force: true) }
            return
        }
        if localEmpty {
            // importeren: dezelfde id's, zonder pincode
            let main = remote.first(where: \.isMain)?.profile.id ?? remote.first?.profile.id
            store.replaceProfiles(remote.map(\.profile), mainID: main)
            ready = true
            lastUploaded = encoded(payload())
            return
        }
        // samenvoegen op id: lokale profielen blijven, alleen-op-de-server erbij, daarna uploaden
        let localIDs = Set(local.map(\.id))
        let added = remote.filter { !localIDs.contains($0.profile.id) }.map(\.profile)
        if !added.isEmpty { store.replaceProfiles(local + added, mainID: nil) }
        ready = true
        await upload(force: true)
    }

    // MARK: - Uploaden

    private func uploadIfChanged() {
        guard ready, AccountService.shared.isSignedIn else { return }
        Task { await self.upload(force: false) }
    }

    private func upload(force: Bool) async {
        guard ready, AccountService.shared.isSignedIn else { return }
        let list = payload()
        let data = encoded(list)
        if !force, data != nil, data == lastUploaded { return }
        do {
            try await AccountService.shared.saveAccountProfiles(list)
            lastUploaded = data
        } catch {
            // stil: de volgende wijziging of start probeert het opnieuw
        }
    }

    private func encoded(_ list: [[String: Any]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
    }

    /// De hele profielenlijst in het contractformaat (zonder pincodes en eigen foto's;
    /// een profiel met een eigen foto stuurt zijn gewone avatar mee).
    private func payload() -> [[String: Any]] {
        let store = CloudStore.shared
        let extras = loadExtras()
        var out: [[String: Any]] = []
        for (i, p) in store.profiles.enumerated() {
            var d = extras[p.id.uuidString] ?? [:]
            for k in Self.privateKeys { d[k] = nil }
            if (d["id"] as? String).map({ Self.uuid(for: $0) }) != p.id { d["id"] = p.id.uuidString }
            d["name"] = p.name
            var av = d["avatar"] as? [String: Any] ?? [:]
            for k in Self.privateKeys { av[k] = nil }
            av["symbol"] = p.avatar.symbol
            av["colorIndex"] = p.avatar.colorIndex
            d["avatar"] = av
            d["kids"] = p.kids
            if let a = p.ageLimit { d["ageLimit"] = a } else { d["ageLimit"] = NSNull() }
            d["isMain"] = store.isMain(p)
            d["order"] = i
            out.append(d)
        }
        return out
    }

    // MARK: - Decoderen

    private static func decode(_ d: [String: Any], index: Int) -> Remote? {
        let rawID = (d["id"] as? String) ?? (d["id"] as? NSNumber)?.stringValue ?? ""
        guard !rawID.isEmpty else { return nil }
        let name = ((d["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var p = ViewerProfile(name: name.isEmpty ? "Bingr" : name, avatar: avatar(d["avatar"], seed: rawID))
        p.id = uuid(for: rawID)
        if let n = d["ageLimit"] as? NSNumber, n.intValue > 0 { p.ageLimit = n.intValue }
        if (d["kids"] as? Bool) == true { p.isKids = true }
        let isMain = (d["isMain"] as? Bool) ?? false
        let order = (d["order"] as? NSNumber)?.intValue ?? index
        var raw = d
        for k in privateKeys { raw[k] = nil }
        return Remote(profile: p, isMain: isMain, order: order, raw: raw)
    }

    /// Profiel-ID van de server → UUID (een ander formaat krijgt een vaste, afgeleide UUID).
    private static func uuid(for raw: String) -> UUID {
        if let u = UUID(uuidString: raw) { return u }
        let h = Array(SHA256.hash(data: Data(raw.utf8)))
        var b = Array(h.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func avatar(_ v: Any?, seed: String) -> PlaylistAvatar {
        let count = PlaylistAvatar.palettes.count
        let fallbackColor = seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFFFF } % count
        func symbol(_ s: String?) -> String {
            guard let s, !s.isEmpty,
                  s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") })
            else { return "person" }
            return s
        }
        if let d = v as? [String: Any] {
            let c = (d["colorIndex"] as? NSNumber)?.intValue ?? (d["color"] as? NSNumber)?.intValue ?? fallbackColor
            let s = (d["symbol"] as? String) ?? (d["figure"] as? String) ?? (d["illustration"] as? String)
            return PlaylistAvatar(symbol: symbol(s), colorIndex: ((c % count) + count) % count)
        }
        return PlaylistAvatar(symbol: symbol(v as? String), colorIndex: fallbackColor)
    }

    // MARK: - Opslag van extra velden

    private func loadExtras() -> [String: [String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: extrasKey),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { return [:] }
        return j
    }

    private func saveExtras(_ e: [String: [String: Any]]) {
        guard let d = try? JSONSerialization.data(withJSONObject: e) else { return }
        UserDefaults.standard.set(d, forKey: extrasKey)
    }
}
