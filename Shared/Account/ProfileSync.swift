import Foundation
import Combine
import CryptoKit

/// Profielen per Bingr-account (tabel `account_data`), zie docs/ACCOUNT.md → "Profielen migreren en delen".
///
/// Na inloggen en bij het starten met een geldige sessie: lezen, dan migreren (server leeg),
/// importeren (lokaal alleen het automatische hoofdprofiel of niets) of samenvoegen op `id`.
/// Daarna gaat elke wijziging (met ~2 s vertraging) als hele lijst naar de server.
/// Pincodes gaan nooit mee. Eigen foto's staan in de Storage-bucket `avatars`; in de lijst staat per
/// profiel alleen `photo` (`{path, updated}` of null), zie "Profielfoto's delen (build 40)".
/// Fouten zijn stil en blokkeren de app nooit.
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
    /// Per profiel de `updated` van de foto die dit apparaat heeft (*photoVersion*), alleen lokaal
    private let versionsKey = "account.photoVersions.v1"
    /// Profielen met een eigen foto-wijziging die nog geüpload of verwijderd moet worden
    private let pendingKey = "account.photoPending.v1"
    /// `photo` per profiel zoals laatst van de server gelezen
    private var remotePhotos: [UUID: [String: Any]] = [:]
    private var photoBusy = false
    private var photoAgain = false
    private var photoChanged = false
    /// Velden die nooit (zo) naar de server gaan; `photo` zet `payload()` zelf
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
        // eigen foto gekozen, gewijzigd of verwijderd op dit apparaat → uploaden of verwijderen
        store.photoEdited
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.photoEdited(id) }
            .store(in: &bag)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.reset() }
            }
            .store(in: &bag)
    }

    /// Lezen + migreren/importeren/samenvoegen + foto's + uploaden. Stil bij fouten.
    /// `periodic`: bij elke heartbeat opnieuw lezen; de lijst gaat dan alleen mee als hij veranderd is.
    func syncNow(periodic: Bool = false) async {
        start()
        if let running {
            await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
            return
        }
        let t = Task { await self.performSync(periodic: periodic) }
        running = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        running = nil
    }

    private func reset() {
        running?.cancel()
        ready = false
        lastUploaded = nil
        remotePhotos = [:]
        for k in [extrasKey, versionsKey, pendingKey] { UserDefaults.standard.removeObject(forKey: k) }
    }

    // MARK: - Synchroniseren

    private struct Remote {
        let profile: ViewerProfile
        let isMain: Bool
        let order: Int
        let raw: [String: Any]
        /// `photo` van de server: ontbreekt/null, een foto, of onleesbaar (dan niets mee doen)
        let photo: PhotoField
    }

    private enum PhotoField {
        case none
        case photo(path: String, updated: String, raw: [String: Any])
        case invalid
    }

    private func performSync(periodic: Bool) async {
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
            // migreren: lokale profielen (en hun foto's) uploaden, of niets te doen
            ready = true
            _ = await applyRemotePhotos(remote)
            if !store.profiles.isEmpty { await upload(force: true) }
            return
        }
        if localEmpty {
            // importeren: dezelfde id's, zonder pincode; foto's downloaden
            let main = remote.first(where: \.isMain)?.profile.id ?? remote.first?.profile.id
            store.replaceProfiles(remote.map(\.profile), mainID: main)
            ready = true
            if await applyRemotePhotos(remote) {
                await upload(force: true)
            } else {
                lastUploaded = encoded(payload())
            }
            return
        }
        // samenvoegen op id: lokale profielen blijven, alleen-op-de-server erbij, foto's, daarna uploaden
        let localIDs = Set(local.map(\.id))
        let added = remote.filter { !localIDs.contains($0.profile.id) }.map(\.profile)
        if !added.isEmpty { store.replaceProfiles(local + added, mainID: nil) }
        ready = true
        let photosChanged = await applyRemotePhotos(remote)
        await upload(force: !periodic || photosChanged)
    }

    // MARK: - Profielfoto's

    /// Regels uit het contract toepassen op wat de server zegt. `true` = er is een foto
    /// geüpload of verwijderd (de lijst moet dan mee).
    private func applyRemotePhotos(_ remote: [Remote]) async -> Bool {
        let store = CloudStore.shared
        let account = AccountService.shared
        var fresh: [UUID: [String: Any]] = [:]
        for r in remote { if case .photo(_, _, let raw) = r.photo { fresh[r.profile.id] = raw } }
        remotePhotos = fresh

        let localIDs = Set(store.profiles.map(\.id))
        var onServer = Set<UUID>()
        for r in remote where localIDs.contains(r.profile.id) {
            let id = r.profile.id
            onServer.insert(id)
            if loadPending().contains(id) { continue }   // eigen wijziging gaat voor
            let local = store.photos[id]
            let mine = loadVersions()[id.uuidString]
            switch r.photo {
            case .invalid:
                continue
            case .photo(let path, let updated, _):
                guard local == nil || mine == nil || Self.isNewer(updated, than: mine!) else { continue }
                guard let data = await account.downloadPhoto(path: path),
                      let small = AccountService.squareJPEG(data, maxSide: 320, quality: 0.72) else { continue }
                // intussen uitgelogd of zelf een foto gekozen? dan niet overschrijven
                guard account.isSignedIn, !loadPending().contains(id),
                      store.profiles.contains(where: { $0.id == id }) else { continue }
                store.setSyncedPhoto(small, for: id)
                setVersion(updated, for: id)
            case .none:
                if mine != nil {
                    // foto elders verwijderd: de lokale (uit de sync) ook weg
                    if local != nil { store.setSyncedPhoto(nil, for: id) }
                    setVersion(nil, for: id)
                } else if local != nil {
                    markPending(id)   // migratie: lokale foto, server heeft er geen
                }
            }
        }
        // profielen die (nog) niet op de server staan: lokale foto zonder photoVersion → migreren
        for p in store.profiles where !onServer.contains(p.id) && store.photos[p.id] != nil
            && loadVersions()[p.id.uuidString] == nil {
            markPending(p.id)
        }
        return await processPending(uploadList: false)
    }

    /// Foto op dit apparaat gekozen, gewijzigd of verwijderd.
    private func photoEdited(_ id: UUID) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        markPending(id)
        Task { await self.processPending(uploadList: true) }
    }

    /// Openstaande foto-wijzigingen uploaden of verwijderen. Eén tegelijk; komt er intussen
    /// een wijziging bij, dan gaat de lopende ronde nog een keer.
    @discardableResult
    private func processPending(uploadList: Bool) async -> Bool {
        if photoBusy {
            photoAgain = true
            return false
        }
        photoBusy = true
        photoChanged = false
        repeat {
            photoAgain = false
            for id in loadPending() {
                guard AccountService.shared.isSignedIn else { break }
                await processPhoto(id)
            }
        } while photoAgain && AccountService.shared.isSignedIn
        photoBusy = false
        let changed = photoChanged
        if changed && uploadList { await upload(force: false) }
        return changed
    }

    private func processPhoto(_ id: UUID) async {
        let store = CloudStore.shared
        let account = AccountService.shared
        let key = rawID(for: id)
        if store.profiles.contains(where: { $0.id == id }), let data = store.photos[id] {
            guard let jpeg = AccountService.squareJPEG(data, maxSide: 512, quality: 0.8) else {
                removePending(id)
                return
            }
            do {
                try await account.uploadPhoto(profileID: key, jpegData: jpeg)
            } catch {
                return   // blijft openstaan: de volgende sync of heartbeat probeert het opnieuw
            }
            setVersion(Self.now(), for: id)
            remotePhotos[id] = nil
            photoChanged = true
            // intussen alweer gewijzigd? dan blijft hij openstaan voor de volgende ronde
            if store.photos[id] == data { removePending(id) } else { photoAgain = true }
        } else {
            // foto (of het hele profiel) verwijderd
            let known = loadVersions()[id.uuidString] != nil || remotePhotos[id] != nil
            if known, let path = (remotePhotos[id]?["path"] as? String) ?? account.photoPath(profileID: key) {
                await account.deletePhoto(path: path)
                photoChanged = true
            }
            setVersion(nil, for: id)
            remotePhotos[id] = nil
            removePending(id)
        }
    }

    /// `photo` voor de lijst: `{path, updated}` of null.
    private func photoField(for id: UUID) -> Any {
        let store = CloudStore.shared
        let pending = loadPending().contains(id)
        let local = store.photos[id]
        if !pending, local != nil, let v = loadVersions()[id.uuidString],
           let path = (remotePhotos[id]?["path"] as? String) ?? AccountService.shared.photoPath(profileID: rawID(for: id)) {
            return ["path": path, "updated": v]
        }
        if pending && local == nil { return NSNull() }
        // nog niet geüpload (of download mislukt): de waarde van de server laten staan
        if let r = remotePhotos[id] { return r }
        return NSNull()
    }

    /// Profiel-ID zoals de server het kent (voor het pad in de bucket).
    private func rawID(for id: UUID) -> String {
        if let s = loadExtras()[id.uuidString]?["id"] as? String, Self.uuid(for: s) == id { return s }
        return id.uuidString
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Is de `updated` van de server nieuwer dan de lokale photoVersion?
    private static func isNewer(_ server: String, than local: String) -> Bool {
        if server == local { return false }
        if let s = AccountService.parseDate(server), let l = AccountService.parseDate(local) { return s > l }
        return true
    }

    private func loadVersions() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: versionsKey) as? [String: String] ?? [:]
    }

    private func setVersion(_ v: String?, for id: UUID) {
        var all = loadVersions()
        all[id.uuidString] = v
        UserDefaults.standard.set(all, forKey: versionsKey)
    }

    private func loadPending() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: pendingKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func markPending(_ id: UUID) {
        var all = loadPending()
        guard !all.contains(id) else { return }
        all.append(id)
        UserDefaults.standard.set(all.map(\.uuidString), forKey: pendingKey)
    }

    private func removePending(_ id: UUID) {
        let all = loadPending().filter { $0 != id }
        UserDefaults.standard.set(all.map(\.uuidString), forKey: pendingKey)
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

    /// De hele profielenlijst in het contractformaat (zonder pincodes; een eigen foto alleen als
    /// verwijzing `photo`, en het gewone avatar-icoon gaat altijd mee).
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
            d["photo"] = photoField(for: p.id)
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
        let photo: PhotoField
        let pv = d["photo"]
        if pv == nil || pv is NSNull {
            photo = .none
        } else if let j = pv as? [String: Any], let path = j["path"] as? String, !path.isEmpty,
                  let updated = j["updated"] as? String, !updated.isEmpty {
            photo = .photo(path: path, updated: updated, raw: j)
        } else {
            photo = .invalid
        }
        return Remote(profile: p, isMain: isMain, order: order, raw: raw, photo: photo)
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
