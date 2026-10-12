import Foundation
import Combine
import CryptoKit

/// Profielen per Bingr-account (tabel `account_data`), zie docs/ACCOUNT.md → "Profielen migreren en delen"
/// en "Profielen volledig synchroniseren (build 41)".
///
/// `account_data.profiles` is de bron van waarheid: toevoegen, wijzigen en verwijderen gaan via de server.
/// Elk profiel heeft een `updatedAt`; een verwijderd profiel blijft als tombstone (`deleted`, `deletedAt`)
/// in de lijst staan, zodat andere apparaten het ook verwijderen. Bij elke lezing (login, starten, voorgrond,
/// heartbeat en na een eigen wijziging) wordt de serverstand toegepast en zo nodig de samengevoegde lijst
/// geüpload. Pincodes gaan nooit mee. Eigen foto's staan in de Storage-bucket `avatars`; in de lijst staat per
/// profiel alleen `photo` (`{path, updated}` of null), zie "Profielfoto's delen (build 40)".
/// Fouten zijn stil en blokkeren de app nooit.
@MainActor
final class ProfileSync {
    static let shared = ProfileSync()

    /// Het actieve profiel is op een ander apparaat verwijderd: terug naar "Wie kijkt er?".
    let activeProfileRemoved = PassthroughSubject<Void, Never>()

    private var bag = Set<AnyCancellable>()
    /// `account_data` is (deze sessie) gelezen: pas daarna leiden eigen wijzigingen tot een sync.
    private var ready = false
    private var running: Task<Void, Never>?
    /// Tijdens een lopende sync kwam er nog een verzoek: daarna nog een ronde.
    private var again = false
    /// Er is lokaal iets dat zeker naar de server moet (bijv. een foto of een tombstone).
    private var dirty = false
    /// Onbekende velden van de server per profiel (bewaren en weer meesturen)
    private let extrasKey = "account.profileExtras.v1"
    /// Per profiel de `updated` van de foto die dit apparaat heeft (*photoVersion*), alleen lokaal
    private let versionsKey = "account.photoVersions.v1"
    /// Profielen met een eigen foto-wijziging die nog geüpload of verwijderd moet worden
    private let pendingKey = "account.photoPending.v1"
    /// Per profiel de `updatedAt` van de versie die dit apparaat heeft (*localUpdatedAt*)
    private let updatedKey = "account.profileUpdatedAt.v1"
    /// Per profiel de gesynchroniseerde velden zoals laatst gezien (om eigen wijzigingen te herkennen)
    private let fingerprintKey = "account.profileFingerprints.v1"
    /// Tombstones (eigen en van de server), per profiel-ID
    private let tombstonesKey = "account.profileTombstones.v1"
    /// `photo` per profiel zoals laatst van de server gelezen
    private var remotePhotos: [UUID: [String: Any]] = [:]
    private var photoBusy = false
    private var photoAgain = false
    private var photoChanged = false
    /// Velden die nooit (zo) naar de server gaan; `photo` zet `payload()` zelf
    private static let privateKeys = ["pin", "pinCode", "pin_code", "photo", "photoData", "customPhoto"]
    /// Tombstones ouder dan dit mogen bij het uploaden weg
    private static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    private init() {}

    /// Wijzigingen in profielen volgen (eenmalig).
    func start() {
        guard bag.isEmpty else { return }
        let store = CloudStore.shared
        store.$profiles.combineLatest(store.$mainProfileIDStored)
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.profilesChanged() }
            .store(in: &bag)
        // eigen foto gekozen, gewijzigd of verwijderd op dit apparaat → uploaden of verwijderen
        store.photoEdited
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.photoEdited(id) }
            .store(in: &bag)
        // profiel op dit apparaat verwijderd → tombstone
        store.profileDeleted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.profileDeleted(id) }
            .store(in: &bag)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.reset() }
            }
            .store(in: &bag)
    }

    /// Lezen + serverstand toepassen (tombstones, toevoegen, wijzigen, volgorde) + foto's + zo nodig uploaden.
    /// Stil bij fouten. `periodic` wordt niet meer anders behandeld: er gaat alleen iets naar de server als
    /// lokaal iets nieuwer is of op de server ontbreekt.
    func syncNow(periodic: Bool = false) async {
        start()
        if let running {
            again = true
            await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
            return
        }
        let t = Task { @MainActor in
            repeat {
                self.again = false
                await self.performSync()
            } while self.again && !Task.isCancelled
        }
        running = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        running = nil
    }

    private func reset() {
        running?.cancel()
        ready = false
        dirty = false
        remotePhotos = [:]
        for k in [extrasKey, versionsKey, pendingKey, updatedKey, fingerprintKey, tombstonesKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    // MARK: - Eigen wijzigingen

    /// Profielenlijst veranderd (debounced). Alleen als gesynchroniseerde velden anders zijn: synchroniseren.
    private func profilesChanged() {
        guard ready, Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        let store = CloudStore.shared
        let prints = loadFingerprints()
        let changed = store.profiles.enumerated().contains { i, p in prints[p.id.uuidString] != fingerprint(p, index: i) }
        guard changed else { return }
        Task { await self.syncNow() }
    }

    /// Profiel op dit apparaat verwijderd: tombstone, foto verwijderen (DELETE) en de lijst uploaden.
    private func profileDeleted(_ id: UUID) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        let now = Self.now()
        var tombs = loadTombstones()
        tombs[id.uuidString] = ["id": rawID(for: id), "deleted": true, "deletedAt": now, "updatedAt": now]
        let path = (remotePhotos[id]?["path"] as? String) ?? AccountService.shared.photoPath(profileID: rawID(for: id))
        saveTombstones(tombs)
        forget(id)
        dirty = true
        remotePhotos[id] = nil
        Task {
            if let path { await AccountService.shared.deletePhoto(path: path) }
            await self.syncNow()
        }
    }

    /// Eigen wijzigingen herkennen: gesynchroniseerde velden anders dan laatst gezien → `updatedAt` = nu.
    /// Een profiel zonder vingerafdruk dat de server al kent, krijgt geen nieuwe `updatedAt` (eerste keer na
    /// een update of op een nieuw apparaat); een nieuw lokaal profiel wel.
    private func noteLocalChanges(knownOnServer: Set<UUID>) {
        let store = CloudStore.shared
        var prints = loadFingerprints()
        var updated = loadUpdated()
        let now = Self.now()
        for (i, p) in store.profiles.enumerated() {
            let key = p.id.uuidString
            let fp = fingerprint(p, index: i)
            if let old = prints[key] {
                if old != fp { updated[key] = now }
            } else if !knownOnServer.contains(p.id) && updated[key] == nil {
                updated[key] = now
            }
            prints[key] = fp
        }
        saveFingerprints(prints)
        saveUpdated(updated)
    }

    /// Naam, avatar, kinderprofiel, leeftijdsgrens, volgorde en hoofdprofiel.
    private func fingerprint(_ p: ViewerProfile, index: Int) -> String {
        let store = CloudStore.shared
        return [p.name, p.avatar.symbol, String(p.avatar.colorIndex), p.kids ? "1" : "0",
                p.ageLimit.map(String.init) ?? "-", String(index), store.isMain(p) ? "m" : ""].joined(separator: "\u{1F}")
    }

    /// Lokale sync-gegevens van een profiel vergeten.
    private func forget(_ id: UUID) {
        var updated = loadUpdated(); updated[id.uuidString] = nil; saveUpdated(updated)
        var prints = loadFingerprints(); prints[id.uuidString] = nil; saveFingerprints(prints)
        var extras = loadExtras(); extras[id.uuidString] = nil; saveExtras(extras)
        setVersion(nil, for: id)
        removePending(id)
    }

    // MARK: - Synchroniseren

    private struct Remote {
        let profile: ViewerProfile
        let isMain: Bool
        let order: Int
        let updatedAt: String?
        let raw: [String: Any]
        /// `photo` van de server: ontbreekt/null, een foto, of onleesbaar (dan niets mee doen)
        let photo: PhotoField
    }

    private struct Tombstone {
        let id: UUID
        let raw: [String: Any]
        var deletedAt: Date { ProfileSync.date(raw["deletedAt"]) ?? ProfileSync.date(raw["updatedAt"]) ?? .distantPast }
    }

    private enum PhotoField {
        case none
        case photo(path: String, updated: String, raw: [String: Any])
        case invalid
    }

    private func performSync() async {
        let account = AccountService.shared
        guard Secrets.accountsConfigured, account.isSignedIn else { return }
        let rows: [[String: Any]]
        do { rows = try await account.fetchAccountProfiles() ?? [] } catch { return }
        guard !Task.isCancelled, account.isSignedIn else { return }

        let store = CloudStore.shared
        // decoderen: actieve profielen en tombstones; dubbele id's → de nieuwste telt
        var serverActive: [UUID: Remote] = [:]
        var serverTombs: [UUID: Tombstone] = [:]
        for (i, row) in rows.enumerated() {
            if (row["deleted"] as? Bool) == true {
                guard let t = Self.decodeTombstone(row) else { continue }
                if let old = serverTombs[t.id], old.deletedAt >= t.deletedAt { continue }
                serverTombs[t.id] = t
            } else if let r = Self.decode(row, index: i) {
                if let old = serverActive[r.profile.id],
                   (Self.date(old.updatedAt) ?? .distantPast) >= (Self.date(r.updatedAt) ?? .distantPast) { continue }
                serverActive[r.profile.id] = r
            }
        }
        for (id, t) in serverTombs {
            guard let r = serverActive[id] else { continue }
            if (Self.date(r.updatedAt) ?? .distantPast) > t.deletedAt { serverTombs[id] = nil } else { serverActive[id] = nil }
        }
        // onbekende velden bewaren
        var extras = loadExtras()
        for r in serverActive.values { extras[r.profile.id.uuidString] = r.raw }
        for id in serverTombs.keys { extras[id.uuidString] = nil }
        saveExtras(extras)

        // eigen wijzigingen sinds de vorige keer → updatedAt = nu
        noteLocalChanges(knownOnServer: Set(serverActive.keys).union(serverTombs.keys))

        // tombstones samenvoegen (eigen + server)
        var tombs = loadTombstones()
        for (id, t) in serverTombs {
            if let mine = tombs[id.uuidString].flatMap({ Self.decodeTombstone($0) }), mine.deletedAt >= t.deletedAt { continue }
            tombs[id.uuidString] = t.raw
        }
        // eigen tombstone tegenover een actief profiel op de server: verwijderd blijft verwijderd,
        // tenzij het profiel op de server ná het verwijderen nog gewijzigd is
        var active = serverActive
        for (id, r) in serverActive {
            guard let t = tombs[id.uuidString].flatMap({ Self.decodeTombstone($0) }) else { continue }
            if (Self.date(r.updatedAt) ?? .distantPast) > t.deletedAt {
                tombs[id.uuidString] = nil
            } else {
                active[id] = nil
                dirty = true   // de server moet de tombstone nog krijgen
            }
        }
        // het hoofdprofiel wordt nooit door een tombstone verwijderd
        if let main = store.mainProfileID, tombs[main.uuidString] != nil {
            tombs[main.uuidString] = nil
            dirty = true
        }
        saveTombstones(tombs)

        let local = store.profiles
        let activeID = store.activeProfileID
        let tombIDs = Set(tombs.keys.compactMap(UUID.init(uuidString:)))
        let removed = local.filter { tombIDs.contains($0.id) && !store.isMain($0) }.map(\.id)
        let remaining = local.filter { !removed.contains($0.id) }
        let activeSorted = active.values.sorted { $0.order < $1.order }
        var updated = loadUpdated()
        var list = remaining
        var mainID: UUID?

        if activeSorted.isEmpty {
            // migreren (of alleen tombstones): lokale profielen houden en uploaden
            dirty = dirty || !remaining.isEmpty
        } else if remaining.isEmpty || (remaining.count == 1 && active[remaining[0].id] == nil && removed.isEmpty) {
            // importeren: lokaal alleen het automatische hoofdprofiel of niets → de profielen van de server,
            // met dezelfde id's en zonder pincode
            list = activeSorted.map(\.profile)
            mainID = activeSorted.first(where: \.isMain)?.profile.id ?? activeSorted.first?.profile.id
            for r in activeSorted { updated[r.profile.id.uuidString] = r.updatedAt }
        } else {
            // samenvoegen op id
            var keyed: [(p: ViewerProfile, key: Double, tie: Int)] = []
            for (i, p) in remaining.enumerated() {
                var p = p
                var key = Double(i)
                if let r = active[p.id] {
                    let mine = Self.date(updated[p.id.uuidString]) ?? .distantPast
                    if let theirs = Self.date(r.updatedAt), theirs > mine {
                        // server nieuwer: naam, avatar, kinderprofiel, leeftijdsgrens en volgorde overnemen
                        p.name = r.profile.name
                        p.avatar = r.profile.avatar
                        p.isKids = r.profile.kids ? true : (p.isKids == nil ? nil : false)
                        p.ageLimit = r.profile.ageLimit
                        key = Double(r.order)
                        updated[p.id.uuidString] = r.updatedAt
                    }
                }
                keyed.append((p, key, i))
            }
            // alleen op de server (en niet verwijderd): toevoegen, zonder pincode
            let localIDs = Set(remaining.map(\.id))
            for r in activeSorted where !localIDs.contains(r.profile.id) {
                keyed.append((r.profile, Double(r.order), keyed.count))
                updated[r.profile.id.uuidString] = r.updatedAt
            }
            list = keyed.sorted { $0.key != $1.key ? $0.key < $1.key : $0.tie < $1.tie }.map(\.p)
        }
        saveUpdated(updated)

        if list != local || mainID != nil {
            store.replaceProfiles(list, mainID: mainID)
        }
        for id in removed {
            store.purgeProfileData(id)
            forget(id)
        }
        // bij importeren vervangen (automatisch hoofdprofiel): alleen de lokale sync-gegevens vergeten
        if mainID != nil {
            for p in remaining where !list.contains(where: { $0.id == p.id }) { forget(p.id) }
        }
        if let a = activeID, removed.contains(a) { activeProfileRemoved.send() }
        // de nieuwe stand is de bekende stand: geen "eigen wijziging"
        var prints = loadFingerprints()
        for (i, p) in store.profiles.enumerated() { prints[p.id.uuidString] = fingerprint(p, index: i) }
        saveFingerprints(prints)
        ready = true

        let photosChanged = await applyRemotePhotos(activeSorted)
        guard account.isSignedIn, !Task.isCancelled else { return }

        // uploaden als lokaal iets nieuwer is of op de server ontbreekt
        let now = loadUpdated()
        let pruned = prunedTombstones()
        let needs = dirty || photosChanged
            || store.profiles.contains { p in
                guard let r = active[p.id] else { return true }   // ontbreekt op de server
                let mine = Self.date(now[p.id.uuidString]) ?? .distantPast
                return mine > (Self.date(r.updatedAt) ?? .distantPast)
            }
            || pruned.keys.contains { k in UUID(uuidString: k).map { serverTombs[$0] == nil } ?? false }
        if needs { await upload() }
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
        if changed && uploadList {
            // de lijst (met `photo`) gaat mee via een gewone sync: eerst lezen, dan samengevoegd uploaden
            dirty = true
            Task { await self.syncNow() }
        }
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
        if let s = date(server), let l = date(local) { return s > l }
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

    private func upload() async {
        guard ready, AccountService.shared.isSignedIn else { return }
        do {
            try await AccountService.shared.saveAccountProfiles(payload())
            dirty = false
        } catch {
            // stil: de volgende wijziging, start of heartbeat probeert het opnieuw
        }
    }

    /// Tombstones zonder die van langer dan 90 dagen geleden (en nooit voor een lokaal profiel).
    private func prunedTombstones() -> [String: [String: Any]] {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        let localIDs = Set(CloudStore.shared.profiles.map(\.id.uuidString))
        return loadTombstones().filter { k, raw in
            guard !localIDs.contains(k), let t = Self.decodeTombstone(raw) else { return false }
            return t.deletedAt >= cutoff
        }
    }

    /// De hele profielenlijst in het contractformaat (zonder pincodes; een eigen foto alleen als
    /// verwijzing `photo`, en het gewone avatar-icoon gaat altijd mee), plus de tombstones.
    private func payload() -> [[String: Any]] {
        let store = CloudStore.shared
        let extras = loadExtras()
        let updated = loadUpdated()
        var out: [[String: Any]] = []
        for (i, p) in store.profiles.enumerated() {
            var d = extras[p.id.uuidString] ?? [:]
            for k in Self.privateKeys { d[k] = nil }
            d["deleted"] = nil
            d["deletedAt"] = nil
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
            if let u = updated[p.id.uuidString] { d["updatedAt"] = u }
            d["photo"] = photoField(for: p.id)
            out.append(d)
        }
        let tombs = prunedTombstones()
        for k in tombs.keys.sorted() {
            guard let raw = tombs[k], let t = Self.decodeTombstone(raw) else { continue }
            var d: [String: Any] = ["id": raw["id"] as? String ?? t.id.uuidString, "deleted": true]
            let deletedAt = (raw["deletedAt"] as? String) ?? (raw["updatedAt"] as? String) ?? Self.now()
            d["deletedAt"] = deletedAt
            d["updatedAt"] = (raw["updatedAt"] as? String) ?? deletedAt
            out.append(d)
        }
        return out
    }

    // MARK: - Opslag van sync-gegevens

    private func loadUpdated() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: updatedKey) as? [String: String] ?? [:]
    }

    private func saveUpdated(_ v: [String: String]) { UserDefaults.standard.set(v, forKey: updatedKey) }

    private func loadFingerprints() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: fingerprintKey) as? [String: String] ?? [:]
    }

    private func saveFingerprints(_ v: [String: String]) { UserDefaults.standard.set(v, forKey: fingerprintKey) }

    private func loadTombstones() -> [String: [String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: tombstonesKey),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { return [:] }
        return j
    }

    private func saveTombstones(_ t: [String: [String: Any]]) {
        guard let d = try? JSONSerialization.data(withJSONObject: t) else { return }
        UserDefaults.standard.set(d, forKey: tombstonesKey)
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
        let updatedAt = (d["updatedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        raw["deleted"] = nil
        raw["deletedAt"] = nil
        return Remote(profile: p, isMain: isMain, order: order, updatedAt: updatedAt, raw: raw, photo: photo)
    }

    /// Tombstone: alleen `id`, `deleted`, `deletedAt` en `updatedAt`. Zonder datum telt hij vanaf nu.
    private static func decodeTombstone(_ d: [String: Any]) -> Tombstone? {
        let rawID = (d["id"] as? String) ?? (d["id"] as? NSNumber)?.stringValue ?? ""
        guard !rawID.isEmpty else { return nil }
        var raw: [String: Any] = ["id": rawID, "deleted": true]
        let deletedAt = (d["deletedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updatedAt = (d["updatedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let deleted: String = deletedAt ?? updatedAt ?? now()
        raw["deletedAt"] = deleted
        raw["updatedAt"] = updatedAt ?? deleted
        return Tombstone(id: uuid(for: rawID), raw: raw)
    }

    /// ISO-8601 (met of zonder fracties) of Postgres-tijdstempel → Date. Ontbreekt = nil (telt als heel oud).
    nonisolated static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        return AccountService.parseDate(s)
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
