import Foundation
import Combine
import CryptoKit

/// Servers en afspeellijsten per Bingr-account, zie docs/ACCOUNT.md → "Servers en afspeellijsten via het
/// account (build 43)". Opslag via device-auth `get_sources`/`put_sources`; de server versleutelt alles.
///
/// Zelfde patroon als `ProfileSync`: elke bron heeft een `updatedAt`, een verwijderde bron blijft als tombstone
/// (`deleted`, `deletedAt`) in de lijst. Per bron gaan ook alle geheime velden mee (`secrets`: elke sleutel
/// `playlist.<id>.<naam>` uit de sleutelhanger) en een eigen blok `apple` met de instellingen van deze bron
/// (aanpassingen en kinderslot-groepen). Het blok `android` en onbekende velden blijven onaangeroerd.
/// Fouten zijn stil en blokkeren de app nooit.
@MainActor
final class SourceSync {
    static let shared = SourceSync()

    /// Wat een sync lokaal veranderd heeft (zodat de app de bibliotheek kan laden of verversen).
    struct Change {
        /// Alles is van de server gekomen (herinstallatie, nieuw apparaat of ander account)
        let imported: Bool
        /// Bronnen die opnieuw geladen moeten worden: nieuw, of adres/inloggegevens van de server overgenomen
        let updated: Set<UUID>
        /// Bronnen die door een tombstone (of een ander account) lokaal verwijderd zijn
        let removed: Set<UUID>
        /// De hoofdserver is door de server veranderd
        let mainChanged: Bool
    }

    let changes = PassthroughSubject<Change, Never>()

    private var bag = Set<AnyCancellable>()
    /// `get_sources` is (deze sessie) gelezen: pas daarna leiden eigen wijzigingen tot een sync.
    private var ready = false
    private var running: Task<Void, Never>?
    private var again = false
    /// Er is lokaal iets dat zeker naar de server moet (bijv. een tombstone).
    private var dirty = false
    /// Bronnen met een `kind` die deze versie niet kent: onaangeroerd terugsturen (alleen in het geheugen,
    /// want ze kunnen geheimen bevatten).
    private var unsupported: [[String: Any]] = []

    /// Onbekende velden van de server per bron (zonder `secrets`)
    private let extrasKey = "account.sourceExtras.v1"
    /// Per bron de `updatedAt` van de versie die dit apparaat heeft (*localUpdatedAt*)
    private let updatedKey = "account.sourceUpdatedAt.v1"
    /// Per bron een hash van de gesynchroniseerde velden zoals laatst gezien (om eigen wijzigingen te herkennen)
    private let fingerprintKey = "account.sourceFingerprints.v1"
    /// Tombstones (eigen en van de server), per bron-ID
    private let tombstonesKey = "account.sourceTombstones.v1"
    /// `mainSourceID` zoals laatst met de server afgestemd
    private let lastMainKey = "account.sourceMain.v1"

    private static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600
    /// device-auth bewaart maximaal 50 bronnen (inclusief tombstones)
    private static let maxEntries = 50

    private init() {}

    /// Wijzigingen in servers en hun instellingen volgen (eenmalig).
    func start() {
        guard bag.isEmpty else { return }
        let store = CloudStore.shared
        store.$playlists.map { _ in () }
            .merge(with: store.$customizations.map { _ in () },
                   store.$parental.map { _ in () },
                   store.$mainSourceID.map { _ in () })
            .dropFirst(4)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.localChanged() }
            .store(in: &bag)
        store.sourceDeleted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.sourceDeleted(id) }
            .store(in: &bag)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.reset() }
            }
            .store(in: &bag)
    }

    /// Lezen + serverstand toepassen (tombstones, importeren, samenvoegen) + zo nodig uploaden. Stil bij fouten.
    func syncNow() async {
        start()
        if let running {
            again = true
            // build 97: een wachter die stopt annuleert de gedeelde ronde niet meer (zie `SharedRound`)
            await SharedRound.wait(running)
            return
        }
        let t = Task { @MainActor in
            repeat {
                self.again = false
                await self.performSync()
            } while self.again && !Task.isCancelled
            // build 97: pas vrijgeven als de ronde echt klaar is (de aanroeper kan eerder stoppen met wachten)
            self.running = nil
        }
        running = t
        await SharedRound.wait(t)
    }

    private func reset() {
        running?.cancel()
        ready = false
        dirty = false
        unsupported = []
        for k in [extrasKey, updatedKey, fingerprintKey, tombstonesKey, lastMainKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    // MARK: - Eigen wijzigingen

    /// Servers, aanpassingen, kinderslot of hoofdserver veranderd (debounced): alleen bij een echte wijziging syncen.
    private func localChanged() {
        guard ready, Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        let store = CloudStore.shared
        let prints = loadFingerprints()
        let changed = store.playlists.contains { prints[$0.id.uuidString] != fingerprint($0) }
            || store.mainSourceID?.uuidString != UserDefaults.standard.string(forKey: lastMainKey)
        guard changed else { return }
        Task { await self.syncNow() }
    }

    /// Server op dit apparaat verwijderd: tombstone en de lijst uploaden.
    private func sourceDeleted(_ id: UUID) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        addTombstone(id)
        forget(id)
        dirty = true
        Task { await self.syncNow() }
    }

    private func addTombstone(_ id: UUID) {
        let now = Self.now()
        var tombs = loadTombstones()
        tombs[id.uuidString] = ["id": rawID(for: id), "deleted": true, "deletedAt": now, "updatedAt": now]
        saveTombstones(tombs)
    }

    /// Eigen wijzigingen herkennen: gesynchroniseerde velden anders dan laatst gezien → `updatedAt` = nu.
    /// Een bron zonder vingerafdruk die de server al kent, krijgt geen nieuwe `updatedAt` (eerste keer na een
    /// update of op een nieuw apparaat); een nieuwe lokale bron krijgt het moment van zijn laatste wijziging.
    private func noteLocalChanges(knownOnServer: Set<UUID>) {
        let store = CloudStore.shared
        var prints = loadFingerprints()
        var updated = loadUpdated()
        let now = Self.now()
        for p in store.playlists {
            let key = p.id.uuidString
            let fp = fingerprint(p)
            if let old = prints[key] {
                if old != fp { updated[key] = now }
            } else if !knownOnServer.contains(p.id) && updated[key] == nil {
                updated[key] = Self.iso(p.updatedAt)
            }
            prints[key] = fp
        }
        saveFingerprints(prints)
        saveUpdated(updated)
    }

    /// Hash (SHA-256) van alle gesynchroniseerde velden, geheimen en het `apple`-blok; de geheimen zelf
    /// worden zo nooit leesbaar in de instellingen bewaard.
    private func fingerprint(_ p: PlaylistSource) -> String {
        var d = Self.fields(p)
        d["secrets"] = secrets(of: p.id)
        d["apple"] = appleBlock(for: p.id)
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func forget(_ id: UUID) {
        var updated = loadUpdated(); updated[id.uuidString] = nil; saveUpdated(updated)
        var prints = loadFingerprints(); prints[id.uuidString] = nil; saveFingerprints(prints)
        var extras = loadExtras(); extras[id.uuidString] = nil; saveExtras(extras)
    }

    // MARK: - Synchroniseren

    private struct Remote {
        var source: PlaylistSource
        let updatedAt: String?
        /// Zonder `secrets`
        let raw: [String: Any]
        /// nil = het veld ontbrak (lokale geheimen dan laten staan)
        let secrets: [String: String]?
        let apple: [String: Any]?
        let order: Int
    }

    private struct Tombstone {
        let id: UUID
        let raw: [String: Any]
        var deletedAt: Date { ProfileSync.date(raw["deletedAt"]) ?? ProfileSync.date(raw["updatedAt"]) ?? .distantPast }
    }

    private func performSync() async {
        let account = AccountService.shared
        guard Secrets.accountsConfigured, account.isSignedIn else { return }
        // build 144: eerst de overzetting uit de sleutelhanger (wachtwoorden van servers) afwachten
        await Keychain.settleBeforeSync()
        let server: (sources: [[String: Any]], mainSourceID: String?, updatedAt: String?)
        do { server = try await account.getSources() } catch { return }
        guard !Task.isCancelled, account.isSignedIn else { return }

        let store = CloudStore.shared
        let defaults = UserDefaults.standard

        // decoderen: actieve bronnen en tombstones; dubbele id's → de nieuwste telt
        var serverActive: [UUID: Remote] = [:]
        var serverTombs: [UUID: Tombstone] = [:]
        var unknown: [[String: Any]] = []
        for (i, row) in server.sources.enumerated() {
            if (row["deleted"] as? Bool) == true {
                guard let t = Self.decodeTombstone(row) else { continue }
                if let old = serverTombs[t.id], old.deletedAt >= t.deletedAt { continue }
                serverTombs[t.id] = t
            } else if let r = Self.decode(row, index: i) {
                if let old = serverActive[r.source.id],
                   (ProfileSync.date(old.updatedAt) ?? .distantPast) >= (ProfileSync.date(r.updatedAt) ?? .distantPast) { continue }
                serverActive[r.source.id] = r
            } else if row["id"] != nil {
                unknown.append(row)   // bijv. een soort bron die deze versie nog niet kent
            }
        }
        for (id, t) in serverTombs {
            guard let r = serverActive[id] else { continue }
            if (ProfileSync.date(r.updatedAt) ?? .distantPast) > t.deletedAt { serverTombs[id] = nil } else { serverActive[id] = nil }
        }
        unsupported = unknown
        var extras = loadExtras()
        for r in serverActive.values { extras[r.source.id.uuidString] = r.raw }
        for id in serverTombs.keys { extras[id.uuidString] = nil }
        saveExtras(extras)

        // servers van een vorig account op dit apparaat (via iCloud teruggekomen): lokaal wissen, niet uploaden
        let foreign = Set((defaults.stringArray(forKey: CloudStore.foreignSourcesKey) ?? []).compactMap(UUID.init(uuidString:)))
        let foreignLocal = Set(store.playlists.filter { foreign.contains($0.id) && serverActive[$0.id] == nil }.map(\.id))
        for id in foreignLocal { store.removeSource(id); forget(id) }

        // eigen wijzigingen sinds de vorige keer → updatedAt = nu
        noteLocalChanges(knownOnServer: Set(serverActive.keys).union(serverTombs.keys))
        var updated = loadUpdated()
        let prints = loadFingerprints()

        // tombstones samenvoegen (eigen + server)
        var tombs = loadTombstones()
        for (id, t) in serverTombs {
            if let mine = tombs[id.uuidString].flatMap({ Self.decodeTombstone($0) }), mine.deletedAt >= t.deletedAt { continue }
            tombs[id.uuidString] = t.raw
        }
        let localIDs = Set(store.playlists.map(\.id))
        var active = serverActive
        for (id, r) in serverActive {
            if let t = tombs[id.uuidString].flatMap({ Self.decodeTombstone($0) }) {
                // eigen tombstone tegenover een actieve bron: verwijderd blijft verwijderd,
                // tenzij de bron op de server ná het verwijderen nog gewijzigd is
                if (ProfileSync.date(r.updatedAt) ?? .distantPast) > t.deletedAt {
                    tombs[id.uuidString] = nil
                } else {
                    active[id] = nil
                    dirty = true
                }
            } else if !localIDs.contains(id), prints[id.uuidString] != nil,
                      (ProfileSync.date(r.updatedAt) ?? .distantPast) <= (ProfileSync.date(updated[id.uuidString]) ?? .distantPast) {
                // dit apparaat had de bron en hij is lokaal verdwenen (bijv. via iCloud verwijderd) zonder dat
                // de server hem sindsdien gewijzigd heeft: dat is een verwijdering → tombstone
                active[id] = nil
                tombs[id.uuidString] = ["id": r.raw["id"] as? String ?? id.uuidString, "deleted": true,
                                        "deletedAt": Self.now(), "updatedAt": Self.now()]
                dirty = true
            }
        }
        // een tombstone tegenover een lokaal nieuwere bron: de bron blijft (en gaat weer naar de server)
        for p in store.playlists {
            guard let raw = tombs[p.id.uuidString], let t = Self.decodeTombstone(raw), active[p.id] == nil else { continue }
            if let mine = ProfileSync.date(updated[p.id.uuidString]), mine > t.deletedAt {
                tombs[p.id.uuidString] = nil
                dirty = true
            }
        }
        saveTombstones(tombs)

        let local = store.playlists
        let tombIDs = Set(tombs.keys.compactMap(UUID.init(uuidString:)))
        let removed = local.filter { tombIDs.contains($0.id) }.map(\.id)
        let remaining = local.filter { !removed.contains($0.id) }
        let activeSorted = active.values.sorted { $0.order < $1.order }
        var list = remaining
        var applied: [Remote] = []
        /// nieuw of met ander adres/andere inloggegevens: bibliotheek opnieuw laden
        var reload = Set<UUID>()
        let imported: Bool
        let serverMain = server.mainSourceID.flatMap { Self.uuid(for: $0) }
        let localMain = store.mainSourceID
        var mainID: UUID?

        if activeSorted.isEmpty {
            // migreren (of alleen tombstones): lokale bronnen houden en uploaden
            imported = false
            dirty = dirty || !remaining.isEmpty
        } else if remaining.isEmpty {
            // importeren: herinstallatie, nieuw apparaat of ander account
            imported = true
            list = activeSorted.map(\.source)
            applied = activeSorted
            reload = Set(list.map(\.id))
            for r in activeSorted { updated[r.source.id.uuidString] = r.updatedAt ?? Self.iso(r.source.updatedAt) }
            mainID = serverMain.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list.first?.id
        } else {
            // samenvoegen op id: de nieuwste updatedAt telt
            imported = false
            list = remaining.map { p in
                guard let r = active[p.id] else { return p }
                let mine = ProfileSync.date(updated[p.id.uuidString]) ?? .distantPast
                guard let theirs = ProfileSync.date(r.updatedAt), theirs > mine else {
                    // terugkijk-correcties die een andere app (of de website) al bewaarde: overnemen
                    var keep = p
                    if keep.catchupOffsets == nil, let o = r.source.catchupOffsets { keep.catchupOffsets = o }
                    return keep
                }
                var s = r.source
                s.createdAt = p.createdAt
                s.ageLimit = p.ageLimit
                if s.catchupOffsets == nil { s.catchupOffsets = p.catchupOffsets }
                let connection: (PlaylistSource) -> [String] = {
                    [$0.kind.rawValue, $0.m3uURL, $0.epgURL, $0.serverURL, $0.username, $0.macAddress, $0.preferHLS ? "1" : "0"]
                }
                if connection(s) != connection(p) || (r.secrets != nil && r.secrets != secrets(of: p.id)) {
                    reload.insert(p.id)
                }
                applied.append(r)
                updated[p.id.uuidString] = r.updatedAt
                return s
            }
            let ids = Set(remaining.map(\.id))
            for r in activeSorted where !ids.contains(r.source.id) {
                list.append(r.source)
                applied.append(r)
                reload.insert(r.source.id)
                updated[r.source.id.uuidString] = r.updatedAt ?? Self.iso(r.source.updatedAt)
            }
            // hoofdserver: die van de server overnemen als hij hier sinds de vorige afstemming niet veranderd is
            if let serverMain, serverMain != localMain, list.contains(where: { $0.id == serverMain }),
               localMain == nil || localMain?.uuidString == defaults.string(forKey: lastMainKey)
                || !list.contains(where: { $0.id == localMain }) {
                mainID = serverMain
            }
        }
        saveUpdated(updated)

        // eerst de geheimen terugzetten, zodat het laden van de bibliotheek ze meteen vindt
        for r in applied { applySecrets(r.secrets, to: r.source.id) }
        for id in removed {
            store.removeSource(id)
            forget(id)
        }
        let current = store.playlists
        if list != current || (mainID != nil && mainID != store.mainSourceID) {
            store.replaceSources(list, mainID: mainID)
        }
        for r in applied { applyApple(r.apple, to: r.source.id) }

        // de nieuwe stand is de bekende stand: geen "eigen wijziging"
        var newPrints = loadFingerprints()
        for p in store.playlists { newPrints[p.id.uuidString] = fingerprint(p) }
        saveFingerprints(newPrints)
        ready = true

        let mainChanged = store.mainSourceID != localMain
        if imported || !applied.isEmpty || !removed.isEmpty || !foreignLocal.isEmpty || mainChanged {
            changes.send(Change(imported: imported, updated: reload,
                                removed: Set(removed).union(foreignLocal), mainChanged: mainChanged))
        }
        guard account.isSignedIn, !Task.isCancelled else { return }

        // uploaden als lokaal iets nieuwer is of op de server ontbreekt
        let now = loadUpdated()
        let pruned = prunedTombstones()
        let needs = dirty
            || store.playlists.contains { p in
                guard let r = active[p.id] else { return true }
                let mine = ProfileSync.date(now[p.id.uuidString]) ?? .distantPast
                return mine > (ProfileSync.date(r.updatedAt) ?? .distantPast)
            }
            || pruned.keys.contains { k in UUID(uuidString: k).map { serverTombs[$0] == nil } ?? false }
            || (store.mainSourceID != serverMain
                && (serverMain == nil || store.mainSourceID?.uuidString != defaults.string(forKey: lastMainKey)))
        if needs {
            await upload()
        } else {
            defaults.set(store.mainSourceID?.uuidString, forKey: lastMainKey)
        }
    }

    // MARK: - Geheimen en het `apple`-blok

    /// Alle geheime velden van een bron: elke sleutel `playlist.<id>.<naam>` → `{naam: waarde}`.
    private func secrets(of id: UUID) -> [String: String] {
        let prefix = CloudStore.secretPrefix(id)
        var out: [String: String] = [:]
        for k in Keychain.keys(withPrefix: prefix) {
            let name = String(k.dropFirst(prefix.count))
            guard Self.validSecretName(name), let v = Keychain.get(k), !v.isEmpty else { continue }
            out[name] = v
        }
        return out
    }

    /// Geheimen van de server terugzetten; lokale geheimen die de server niet (meer) heeft, gaan weg.
    private func applySecrets(_ secrets: [String: String]?, to id: UUID) {
        guard let secrets else { return }
        let prefix = CloudStore.secretPrefix(id)
        for (name, value) in secrets where Self.validSecretName(name) {
            if Keychain.get(prefix + name) != value { Keychain.set(value.isEmpty ? nil : value, for: prefix + name) }
        }
        for k in Keychain.keys(withPrefix: prefix) where secrets[String(k.dropFirst(prefix.count))] == nil {
            Keychain.set(nil, for: k)
        }
    }

    private static func validSecretName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0))
        }
    }

    /// Instellingen van deze bron op Apple: aanpassingen (hernoemd, verborgen = categorieën uit, volgorde,
    /// samengevoegd) en de groepen op kinderslot. Lijsten gesorteerd, zodat de vingerafdruk stabiel is.
    private func appleBlock(for id: UUID) -> [String: Any] {
        let store = CloudStore.shared
        let c = store.customizations[id] ?? Customization()
        let custom: [String: Any] = [
            "renamed": c.renamed,
            "hidden": c.hidden.sorted(),
            "groupOrder": c.groupOrder,
            "channelOrder": c.channelOrder,
            "merged": c.merged
        ]
        let prefix = id.uuidString + "|"
        let locked = store.parental.lockedGroups.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
        return ["customization": custom, "lockedGroups": locked]
    }

    private func applyApple(_ apple: [String: Any]?, to id: UUID) {
        guard let apple else { return }
        let store = CloudStore.shared
        if let c = apple["customization"] as? [String: Any] {
            var cu = Customization()
            cu.renamed = c["renamed"] as? [String: String] ?? [:]
            cu.hidden = Set(c["hidden"] as? [String] ?? [])
            cu.groupOrder = c["groupOrder"] as? [String] ?? []
            cu.channelOrder = c["channelOrder"] as? [String: [String]] ?? [:]
            cu.merged = c["merged"] as? [String: String] ?? [:]
            store.setCustomization(id, cu == Customization() ? nil : cu)
        }
        if let locked = apple["lockedGroups"] as? [String] {
            store.setLockedGroups(id, locked)
        }
    }

    // MARK: - Uploaden

    private func upload() async {
        guard ready, AccountService.shared.isSignedIn else { return }
        let main = CloudStore.shared.mainSourceID
        do {
            try await AccountService.shared.putSources(payload(), mainSourceID: main.map { rawID(for: $0) })
            dirty = false
            UserDefaults.standard.set(main?.uuidString, forKey: lastMainKey)
        } catch {
            // stil: de volgende wijziging, start of heartbeat probeert het opnieuw
        }
    }

    private func prunedTombstones() -> [String: [String: Any]] {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        let localIDs = Set(CloudStore.shared.playlists.map(\.id.uuidString))
        return loadTombstones().filter { k, raw in
            guard !localIDs.contains(k), let t = Self.decodeTombstone(raw) else { return false }
            return t.deletedAt >= cutoff
        }
    }

    /// De hele lijst in het gedeelde formaat: alle bronnen (met geheimen en het `apple`-blok, `android` en
    /// onbekende velden onaangeroerd), onbekende soorten van de server, en de tombstones (nieuwste eerst).
    private func payload() -> [[String: Any]] {
        let store = CloudStore.shared
        let extras = loadExtras()
        let updated = loadUpdated()
        var out: [[String: Any]] = []
        var ids = Set<String>()
        for p in store.playlists {
            var d = extras[p.id.uuidString] ?? [:]
            d["deleted"] = nil
            d["deletedAt"] = nil
            let raw = rawID(for: p.id)
            for (k, v) in Self.fields(p) where k != "avatar" { d[k] = v }
            d["id"] = raw
            var av = d["avatar"] as? [String: Any] ?? [:]
            av["symbol"] = p.avatar.symbol
            av["colorIndex"] = p.avatar.colorIndex
            d["avatar"] = av
            d["secrets"] = secrets(of: p.id)
            var apple = d["apple"] as? [String: Any] ?? [:]
            for (k, v) in appleBlock(for: p.id) { apple[k] = v }
            d["apple"] = apple
            d["updatedAt"] = updated[p.id.uuidString] ?? Self.iso(p.updatedAt)
            out.append(d)
            ids.insert(p.id.uuidString)
        }
        for u in unsupported {
            guard let raw = u["id"] as? String, !ids.contains(Self.uuid(for: raw).uuidString) else { continue }
            out.append(u)
            ids.insert(Self.uuid(for: raw).uuidString)
        }
        let tombs = prunedTombstones()
            .compactMap { _, raw in Self.decodeTombstone(raw) }
            .filter { !ids.contains($0.id.uuidString) }
            .sorted { $0.deletedAt > $1.deletedAt }
        for t in tombs.prefix(max(0, Self.maxEntries - out.count)) {
            let deletedAt = (t.raw["deletedAt"] as? String) ?? Self.now()
            out.append(["id": t.raw["id"] as? String ?? t.id.uuidString, "deleted": true,
                        "deletedAt": deletedAt, "updatedAt": (t.raw["updatedAt"] as? String) ?? deletedAt])
        }
        return out
    }

    /// De gedeelde velden van een bron (zonder geheimen, `apple` en `updatedAt`).
    private static func fields(_ p: PlaylistSource) -> [String: Any] {
        var d: [String: Any] = ["id": p.id.uuidString, "name": p.name, "kind": p.kind.rawValue,
                                "avatar": ["symbol": p.avatar.symbol, "colorIndex": p.avatar.colorIndex],
                                "m3uURL": p.m3uURL, "epgURL": p.epgURL, "serverURL": p.serverURL,
                                "username": p.username, "macAddress": p.macAddress, "preferHLS": p.preferHLS]
        // terugkijk-correctie per zender (build 51); zonder eigen waarde blijft die van de server onaangeroerd
        if let o = p.catchupOffsets { d["catchupOffsets"] = o }
        return d
    }

    /// Bron-ID zoals de server het kent (exact bewaren).
    /// Server-ID zoals in de Bingr-account (voor gedeelde sleutels, bijv. intro-markeringen in build 52).
    func serverID(for id: UUID) -> String { rawID(for: id) }

    private func rawID(for id: UUID) -> String {
        if let s = loadExtras()[id.uuidString]?["id"] as? String, Self.uuid(for: s) == id { return s }
        return id.uuidString
    }

    // MARK: - Decoderen

    private static func decode(_ d: [String: Any], index: Int) -> Remote? {
        let rawID = (d["id"] as? String) ?? ""
        guard !rawID.isEmpty, let kind = (d["kind"] as? String).flatMap(PlaylistKind.init(rawValue:)) else { return nil }
        func str(_ k: String) -> String { (d[k] as? String) ?? "" }
        let name = str("name").trimmingCharacters(in: .whitespacesAndNewlines)
        var s = PlaylistSource(name: name.isEmpty ? kind.title : name, kind: kind, avatar: avatar(d["avatar"], seed: rawID, kind: kind))
        s.id = uuid(for: rawID)
        s.m3uURL = str("m3uURL"); s.epgURL = str("epgURL"); s.serverURL = str("serverURL")
        s.username = str("username"); s.macAddress = str("macAddress")
        s.preferHLS = (d["preferHLS"] as? Bool) ?? false
        if let o = d["catchupOffsets"] as? [String: Any] {
            var m: [String: Int] = [:]
            for (k, v) in o {
                guard let n = (v as? NSNumber)?.intValue ?? (v as? String).flatMap({ Int($0) }) else { continue }
                m[k] = min(max(n, -120), 120)
            }
            s.catchupOffsets = m
        }
        let updatedAt = (d["updatedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let u = ProfileSync.date(updatedAt) { s.updatedAt = u }
        var secrets: [String: String]?
        if let sec = d["secrets"] as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in sec { if let v = v as? String { out[k] = v } }
            secrets = out
        }
        var raw = d
        raw["secrets"] = nil
        raw["deleted"] = nil
        raw["deletedAt"] = nil
        return Remote(source: s, updatedAt: updatedAt, raw: raw, secrets: secrets,
                      apple: d["apple"] as? [String: Any], order: index)
    }

    private static func decodeTombstone(_ d: [String: Any]) -> Tombstone? {
        let rawID = (d["id"] as? String) ?? ""
        guard !rawID.isEmpty else { return nil }
        var raw: [String: Any] = ["id": rawID, "deleted": true]
        let deletedAt = (d["deletedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updatedAt = (d["updatedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let deleted: String = deletedAt ?? updatedAt ?? now()
        raw["deletedAt"] = deleted
        raw["updatedAt"] = updatedAt ?? deleted
        return Tombstone(id: uuid(for: rawID), raw: raw)
    }

    /// Bron-ID van de server → UUID (een ander formaat krijgt een vaste, afgeleide UUID).
    nonisolated static func uuid(for raw: String) -> UUID {
        if let u = UUID(uuidString: raw) { return u }
        let h = Array(SHA256.hash(data: Data(raw.utf8)))
        var b = Array(h.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func avatar(_ v: Any?, seed: String, kind: PlaylistKind) -> PlaylistAvatar {
        let count = PlaylistAvatar.palettes.count
        let fallbackColor = seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFFFF } % count
        func symbol(_ s: String?) -> String {
            guard let s, !s.isEmpty,
                  s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") })
            else { return "tv" }
            return s
        }
        if let d = v as? [String: Any] {
            let c = (d["colorIndex"] as? NSNumber)?.intValue ?? fallbackColor
            return PlaylistAvatar(symbol: symbol(d["symbol"] as? String), colorIndex: ((c % count) + count) % count)
        }
        return PlaylistAvatar(symbol: symbol(v as? String), colorIndex: fallbackColor)
    }

    private static func now() -> String { iso(Date()) }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: - Opslag van sync-gegevens

    private func loadUpdated() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: updatedKey) as? [String: String] ?? [:]
    }

    /// Build 144: lokale vingerafdrukken en tijden vergeten (de account is daarna de bron), zie
    /// `Keychain.settleBeforeSync`.
    func forgetLocalStamps() {
        saveFingerprints([:])
        saveUpdated([:])
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
