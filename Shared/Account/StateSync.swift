import Foundation
import Combine
import CryptoKit

/// Alle overige gegevens per Bingr-account, zie docs/ACCOUNT.md → "Alle overige gegevens via het account
/// (build 44)". Opslag via device-auth `get_state`/`put_state`/`delete_state`; de server versleutelt alles.
///
/// Onderdelen (sections):
/// - `connections`: Trakt-tokens en de OpenSubtitles-sessie (geheel: nieuwste `updatedAt` wint).
/// - `settings`: `shared` (zelfde betekenis op iOS en Android), `apple` (de rest); `android` blijft onaangeroerd.
/// - `profile.<id>`: Mijn lijst, favorieten, voortgang, bekeken, geschiedenis, recente zenders, kijkvoorkeuren, pincode.
/// - `reminders`: herinneringen (van alle profielen; per herinnering `profileID`, zie docs/ACCOUNT.md).
/// - `collections`: eigen collecties (build 51), sinds build 54 per profiel (`profiles.<profielID>.items`); per item
///   wint de nieuwste `updatedAt`; in `profile.<id>` ook `homeLayout`.
/// - `account` (build 140): wat voor het hele account geldt: `hiddenCategories` (categorieën uit voor alle
///   niet-kinderprofielen, "<server-id kleine letters>|<categorienaam>") met `removed.hiddenCategories`.
///
/// Lijsten en sets worden per item samengevoegd (`{id, removed?, at}`, nieuwste `at` wint), zodat ook een
/// verwijdering doorkomt. Lokale wijzigingen worden herkend door de huidige stand te vergelijken met de laatst
/// bekende stand (de *meta*, alleen lokaal). Zelfde patroon als `ProfileSync`/`SourceSync`: fouten zijn stil.
@MainActor
final class StateSync {
    static let shared = StateSync()

    private var bag = Set<AnyCancellable>()
    /// `get_state` is (deze sessie) gelezen: pas daarna leiden eigen wijzigingen tot een upload.
    private var ready = false
    private var running: Task<Void, Never>?
    /// Onderdelen voor de volgende ronde (nil = alles)
    private var requested: Set<String>? = []
    private var again = false
    /// Vertraagd uploaden: onderdelen en het moment waarop
    private var scheduled = Set<String>()
    private var timer: Task<Void, Never>?
    private var fireAt: Date?
    private var lastProgressUpload: Date = .distantPast
    /// Ander account: eerst Trakt/OpenSubtitles van het vorige account loskoppelen
    private var switchTask: Task<Void, Never>?

    private let metaKey = "account.stateMeta.v1"
    private var meta: Meta

    private static let removedLifetime: TimeInterval = 90 * 24 * 3600
    private static let maxRemoved = 2000
    private static let maxHistory = 500
    private static let maxRecent = 20
    /// build 128: `hiddenCategories` (categorieën uit per profiel, "<server-id>|<categorienaam>") als set erbij
    private static let setLists = ["myList", "favorites", "watched", "hiddenCategories"]

    private init() {
        if let d = UserDefaults.standard.data(forKey: metaKey), let m = try? JSONDecoder().decode(Meta.self, from: d) {
            meta = m
        } else {
            meta = Meta()
        }
    }

    // MARK: - Lokale sync-stand (meta)

    private struct Stamp: Codable, Equatable {
        /// SHA-256 van de inhoud zoals laatst gezien (nooit de geheimen zelf)
        var fp: String?
        /// Wanneer de inhoud het laatst veranderd is (nil = onbekend, telt als heel oud)
        var at: Double?
    }

    private struct ListMeta: Codable {
        /// Per lijst: aanwezige items → `at`
        var present: [String: [String: Double]] = [:]
        /// Per lijst: verwijderde items → `at`
        var removed: [String: [String: Double]] = [:]
        var prefs = Stamp()
        var pin = Stamp()
        /// Dit onderdeel is al eens met de server afgestemd (daarvoor tellen lokale items als heel oud)
        var seeded = false
    }

    private struct Meta: Codable {
        var settings = Stamp()
        var settingsSeeded = false
        var connections = Stamp()
        var connectionsSeeded = false
        var reminders = ListMeta()
        /// Per lokaal profiel-ID
        var profiles: [String: ListMeta] = [:]
        /// Opbouw van de instellingen-vingerafdruk (build 54: zonder `accentColor`). Anders = na een update
        /// eenmalig opnieuw vastleggen, zonder dat het als eigen wijziging telt.
        /// (Een nieuwe meta begint met het huidige formaat; een opgeslagen meta van vóór build 54 heeft nil.)
        var settingsFormat: Int? = StateSync.settingsFormat
        /// Build 140: section `account` (optioneel, zodat een opgeslagen meta van vóór build 140 gewoon te lezen is)
        var account: ListMeta? = nil
    }

    /// 60: `subtitleLanguage: "off"` wordt `""` + `autoSubtitles: "off"`
    nonisolated static let settingsFormat = 145   // build 145: zonder refreshInterval

    /// Build 144: lokale sync-stand vergeten (de account is daarna de bron, zoals op een nieuw apparaat), zie
    /// `Keychain.settleBeforeSync`.
    func forgetLocalStamps() {
        meta = Meta()
        saveMeta()
    }

    private func saveMeta() {
        if let d = try? JSONEncoder().encode(meta) { UserDefaults.standard.set(d, forKey: metaKey) }
    }

    // MARK: - Starten en volgen

    /// Lokale wijzigingen volgen (eenmalig).
    func start() {
        guard bag.isEmpty else { return }
        let store = CloudStore.shared
        store.stateEdited
            .receive(on: DispatchQueue.main)
            .sink { [weak self] e in self?.edited(profile: e.0, e.1) }
            .store(in: &bag)
        // bewust uit Verder kijken gehaald: meteen (synchroon) als verwijdering vastleggen, vóór een volgende sync-ronde
        store.progressCleared
            .sink { [weak self] e in self?.recordRemoved("progress", profile: e.0, keys: [e.1], at: e.2) }
            .store(in: &bag)
        store.historyRemoved
            .sink { [weak self] e in self?.recordRemoved("history", profile: e.0, keys: Self.historyVariants(e.1), at: e.2) }
            .store(in: &bag)
        store.profileDeleted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.profileDeleted(id) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: Keychain.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.keychainChanged(n.userInfo?["key"] as? String ?? "") }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsMaybeChanged() }
            .store(in: &bag)
        store.$profiles
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsMaybeChanged() }
            .store(in: &bag)
        AccountService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.reset() }
            }
            .store(in: &bag)
    }

    /// Alles lezen, samenvoegen, lokaal toepassen en zo nodig uploaden. Stil bij fouten.
    func syncNow() async { await run(nil) }

    private func run(_ sections: Set<String>?) async {
        start()
        if let sections, var r = requested { r.formUnion(sections); requested = r } else { requested = nil }
        if let running {
            again = true
            // build 97: een wachter die stopt (bijv. de time-out vóór het verversen van Trakt) annuleert de gedeelde
            // ronde niet meer; hij stopt alleen met wachten
            await SharedRound.wait(running)
            // de lopende ronde was net klaar: wat er nog gevraagd is alsnog doen
            if self.running == nil, requested?.isEmpty != true, !Task.isCancelled { await run([]) }
            return
        }
        let t = Task { @MainActor in
            repeat {
                self.again = false
                let want = self.requested
                self.requested = []
                if want?.isEmpty == true { break }
                await self.performSync(want)
            } while self.again && !Task.isCancelled
            self.running = nil
        }
        running = t
        // build 97: annuleren van deze aanroep stopt alleen het wachten, niet de ronde (anderen wachten er ook op)
        await SharedRound.wait(t)
    }

    private func reset() {
        running?.cancel()
        timer?.cancel()
        timer = nil
        fireAt = nil
        scheduled = []
        requested = []
        ready = false
        meta = Meta()
        UserDefaults.standard.removeObject(forKey: metaKey)
    }

    /// Een **ander** account op dit apparaat (na `CloudStore.wipeAccountData`): Trakt en OpenSubtitles van het
    /// vorige account loskoppelen en de sync-stand wissen. De eerstvolgende sync importeert alles van dit account.
    func accountSwitched() {
        start()
        running?.cancel()
        meta = Meta()
        saveMeta()
        ready = false
        scheduled = []
        OpenSubtitles.shared.forgetSession()
        switchTask = Task { @MainActor in
            await TraktSync.shared.logout()
            self.switchTask = nil
        }
    }

    // MARK: - Eigen wijzigingen → vertraagd uploaden

    private func edited(profile id: UUID?, _ kind: CloudStore.StateEdit) {
        switch kind {
        case .reminders: schedule(["reminders"], delay: 3)
        case .collections: schedule(["collections"], delay: 3)
        case .account: schedule(["account"], delay: 3)
        case .settings: settingsMaybeChanged()
        case .prefs:
            settingsMaybeChanged()
            if let id { schedule([profileSection(id)], delay: 3) }
        case .profile:
            if let id { schedule([profileSection(id)], delay: 3) }
        case .progress:
            // voortgang tijdens het afspelen: maximaal eens per 30 seconden
            let wait = max(3, 30 - Date().timeIntervalSince(lastProgressUpload))
            if let id { schedule([profileSection(id)], delay: wait) }
        }
    }

    // MARK: - Klok (build 97)

    /// build 97: lokaal tijdstip dat meer dan 60 s voor de serverklok ligt (apparaatklok loopt voor) → de servertijd.
    /// Zonder bekende servertijd ongewijzigd.
    private func trusted(_ t: Double) -> Double {
        guard let offset = AccountService.shared.serverClockOffset else { return t }
        let serverNow = Date().timeIntervalSince1970 + offset
        return t > serverNow + 60 ? serverNow : t
    }

    private func trustedNow() -> Double { trusted(Date().timeIntervalSince1970) }

    /// Afspelen gestopt: de voortgang meteen uploaden. build 97: `profile` = het profiel dat keek (anders het actieve).
    func playbackStopped(profile: UUID? = nil) {
        let store = CloudStore.shared
        guard let id = profile ?? store.activeProfileID ?? store.mainProfileID else { return }
        schedule([profileSection(id)], delay: 0.5)
    }

    private func keychainChanged(_ key: String) {
        let store = CloudStore.shared
        if key == "trakt.tokens" || key == "opensubtitles.session" {
            schedule(["connections"], delay: 3)
        } else if key == "parental.pin", let main = store.mainProfileID {
            schedule([profileSection(main)], delay: 3)
        } else if key.hasPrefix("profile."), key.hasSuffix(".pin") {
            let raw = String(key.dropFirst("profile.".count).dropLast(".pin".count))
            if let id = UUID(uuidString: raw), store.profiles.contains(where: { $0.id == id }) {
                schedule([profileSection(id)], delay: 3)
            }
        } else if key.hasPrefix("nas.") {
            settingsMaybeChanged()
        }
    }

    /// Instellingen mogelijk veranderd: alleen bij een echte wijziging uploaden.
    private func settingsMaybeChanged() {
        guard ready, Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        if noteSettings() { schedule(["settings"], delay: 3) }
    }

    private func schedule(_ sections: Set<String>, delay: TimeInterval) {
        guard ready, Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        scheduled.formUnion(sections)
        let at = Date().addingTimeInterval(delay)
        if let f = fireAt, f <= at, timer != nil { return }
        fireAt = at
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let s = self.scheduled
            self.scheduled = []
            self.fireAt = nil
            self.timer = nil
            if s.contains(where: { $0.hasPrefix("profile.") }) { self.lastProgressUpload = Date() }
            await self.run(s)
        }
    }

    /// Bewust uit Verder kijken gehaald (zie `CloudStore.progressCleared`): de verwijdering met haar tijd in de meta
    /// zetten. Alleen zo ontstaat een verwijdering van voortgang; `noteProfile` leidt ze niet meer af uit een sleutel die
    /// lokaal ontbreekt (een onvolledige lokale kopie wiste anders bij de eerstvolgende ronde, bijv. na "Mijn lijst",
    /// Verder kijken op alle apparaten).
    /// Geldt ook voor de kijkgeschiedenis (`CloudStore.historyRemoved`).
    private func recordRemoved(_ field: String, profile id: UUID, keys: [String], at: Date) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn, !keys.isEmpty else { return }
        var m = meta.profiles[id.uuidString] ?? ListMeta()
        var removed = m.removed[field] ?? [:]
        let t = trusted(at.timeIntervalSince1970)
        for key in keys {
            removed[key] = max(removed[key] ?? 0, t)
            m.present[field]?[key] = nil
        }
        m.removed[field] = removed
        meta.profiles[id.uuidString] = m
        saveMeta()
    }

    // MARK: - Build 128: remap, oude categoriekeuzes en volgorde

    /// Remap van één item in een lijst van een profiel: de nieuwe sleutel krijgt de `at` van de oude (de volgorde
    /// blijft), de oude wordt een verwijdering met de remap-tijd. `field`: myList, favorites, watched, recentChannels,
    /// hiddenCategories, progress of history. Werkt alleen met een account (zonder is er geen sync-stand).
    func noteRemap(profile id: UUID, field: String, old: String, new: String, at: Date) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn, old != new else { return }
        var m = meta.profiles[id.uuidString] ?? ListMeta()
        let t = trusted(at.timeIntervalSince1970)
        var present = m.present[field] ?? [:]
        var removed = m.removed[field] ?? [:]
        if let oldAt = present[old] { present[new] = max(present[new] ?? 0, oldAt) }
        present[old] = nil
        removed[old] = max(removed[old] ?? 0, t)
        removed[new] = nil
        m.present[field] = present
        m.removed[field] = removed
        meta.profiles[id.uuidString] = m
        saveMeta()
    }

    /// Items die als heel oud moeten tellen (migratie van oude keuzes): een keuze die een ander apparaat al maakte
    /// (ook een verwijdering) gaat dan voor.
    func presetOld(profile id: UUID, field: String, keys: [String]) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn, !keys.isEmpty else { return }
        var m = meta.profiles[id.uuidString] ?? ListMeta()
        var present = m.present[field] ?? [:]
        for k in keys where present[k] == nil { present[k] = 1 }
        m.present[field] = present
        meta.profiles[id.uuidString] = m
        saveMeta()
    }

    /// Wanneer dit item aan de lijst is toegevoegd (volgorde van Mijn lijst en favorieten), nil = onbekend.
    func addedAt(profile id: UUID, field: String, key: String) -> Double? {
        guard let p = meta.profiles[id.uuidString]?.present[field] else { return nil }
        if let t = p[key] { return t }
        let n = CatalogKey.normalize(key)
        return p.first { CatalogKey.normalize($0.key) == n }?.value
    }

    /// catalogmeta gewijzigd: vertraagd uploaden (zoals andere onderdelen)
    func catalogMetaChanged(delay: TimeInterval = 3) {
        schedule(["catalogmeta"], delay: delay)
    }

    /// Id van een geschiedenis-vermelding ("<server-id>|<item>") ook met de server-id in kleine letters: web en Samsung
    /// TV gebruiken de id zoals de server hem kreeg (soms kleine letters), deze app hoofdletters. Zo raakt een
    /// verwijdering hier ook hun vermelding.
    private static func historyVariants(_ ids: [String]) -> [String] {
        var out: [String] = []
        for k in ids {
            out.append(k)
            if let bar = k.firstIndex(of: "|") {
                let lower = k[..<bar].lowercased() + k[bar...]
                if lower != k { out.append(lower) }
            }
        }
        return out
    }

    /// Geschiedenis-id van de server naar de vorm van deze app: een server-id die een UUID is, met hoofdletters
    /// (`HistoryEntry.id`). Zo raakt een verwijdering van web/Samsung TV ("<kleine letters>|<item>") de vermelding hier.
    private static func historyKey(_ k: String) -> String {
        guard let bar = k.firstIndex(of: "|"), let u = UUID(uuidString: String(k[..<bar])) else { return k }
        return u.uuidString + String(k[bar...])
    }

    private func profileDeleted(_ id: UUID) {
        let section = profileSection(id)
        meta.profiles[id.uuidString] = nil
        saveMeta()
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        Task { try? await AccountService.shared.deleteState(section: section) }
    }

    private func profileSection(_ id: UUID) -> String {
        "profile." + ProfileSync.shared.serverID(for: id)
    }

    // MARK: - Trakt: tokens zijn eenmalig bij verversen

    /// Vóór het verversen van Trakt-tokens: `connections` lezen; nieuwere tokens van de server worden dan gebruikt.
    /// Maximaal 6 seconden; stil bij fouten.
    static func beforeTraktRefresh() async {
        let me = shared
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        let t = Task { @MainActor in await me.run(["connections"]) }
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            // build 97: stopt alleen het wachten van `t`; de sync-ronde zelf loopt door
            t.cancel()
        }
        await t.value
        timeout.cancel()
    }

    /// Trakt-tokens zijn ververst: meteen `put_state` voor `connections`.
    static func traktTokensRefreshed() async {
        let me = shared
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn else { return }
        _ = me.noteConnections(force: true)
        me.saveMeta()
        Task { @MainActor in await me.run(["connections"]) }
    }

    // MARK: - Synchroniseren

    private func performSync(_ sections: Set<String>?) async {
        let account = AccountService.shared
        guard Secrets.accountsConfigured, account.isSignedIn else { return }
        // build 144: eerst de overzetting uit de sleutelhanger (pincodes, Trakt, OpenSubtitles) afwachten
        await Keychain.settleBeforeSync()
        if let s = switchTask { await s.value }
        let store = CloudStore.shared

        // eigen wijzigingen sinds de vorige keer vastleggen
        _ = noteSettings()
        _ = noteConnections()
        noteReminders()
        noteAccount()
        for p in store.profiles { noteProfile(p.id) }
        saveMeta()

        let server: [String: (data: Any, updatedAt: String?)]
        do { server = try await account.getState(sections: sections.map { Array($0).sorted() }) } catch { return }
        guard !Task.isCancelled, account.isSignedIn else { return }
        func wants(_ s: String) -> Bool { sections?.contains(s) ?? true }
        // build 147: pincode-hashes (PBKDF2, 100.000 iteraties) vooraf buiten de hoofdthread uitrekenen
        await preparePins(server)
        defer { pinMade = [:]; pinMatch = [:] }
        let taskID = MainTasks.shared.begin("sync_apply")
        defer { MainTasks.shared.end(taskID) }

        var uploads: [(String, [String: Any])] = []
        if wants("connections"), let u = await mergeConnections(server["connections"]) { uploads.append(("connections", u)) }
        if wants("settings"), let u = mergeSettings(server["settings"]) { uploads.append(("settings", u)) }
        if wants("reminders"), let u = mergeReminders(server["reminders"]) { uploads.append(("reminders", u)) }
        // build 128: eerst catalogmeta (remap-regels van andere apparaten), dan de regels toepassen op alle profielen en
        // collecties; de samenvoeging hieronder neemt de herschreven lijsten (met behoud van `at`) mee
        if wants("catalogmeta"), let u = CrossServer.shared.mergeRemote(server["catalogmeta"]?.data, hadRemote: server["catalogmeta"] != nil) {
            uploads.append(("catalogmeta", u))
        }
        CrossServer.shared.applyRemapEverywhere()
        if wants("collections"), let u = mergeCollections(server["collections"]) { uploads.append(("collections", u)) }
        let tombs = ProfileSync.shared.tombstonedIDs
        for p in store.profiles where !tombs.contains(p.id) {
            let name = profileSection(p.id)
            guard wants(name) else { continue }
            if let u = mergeProfile(p.id, server[name]) { uploads.append((name, u)) }
        }
        // build 140: categorieën per account; eerst (eenmalig, na een volledige ronde zodat de per-profiel-sets van de
        // server er zijn) de oude per-profiel-keuzes overnemen met een oude tijd
        if sections == nil {
            let added = store.migrateAccountCategories()
            if !added.isEmpty { presetOldAccount(added) }
        }
        if wants("account"), let u = mergeAccount(server["account"]) { uploads.append(("account", u)) }
        // verwijderde profielen (tombstone): hun onderdeel op de server weg
        var deletes: [String] = []
        let localIDs = Set(store.profiles.map(\.id))
        for name in server.keys where name.hasPrefix("profile.") {
            let id = ProfileSync.uuid(for: String(name.dropFirst("profile.".count)))
            if tombs.contains(id) && !localIDs.contains(id) { deletes.append(name) }
        }
        for id in meta.profiles.keys.compactMap(UUID.init(uuidString:)) where !localIDs.contains(id) {
            meta.profiles[id.uuidString] = nil
        }
        if sections == nil || sections?.contains("settings") == true { meta.settingsSeeded = true }
        if sections == nil || sections?.contains("connections") == true { meta.connectionsSeeded = true }
        ready = true
        saveMeta()
        MainTasks.shared.end(taskID)

        for (name, data) in uploads {
            guard account.isSignedIn, !Task.isCancelled else { return }
            _ = try? await account.putState(section: name, data: data)
        }
        for name in deletes {
            guard account.isSignedIn, !Task.isCancelled else { return }
            try? await account.deleteState(section: name)
        }
    }

    // MARK: - pincodes vooraf hashen (build 147)

    /// Uitkomsten van PBKDF2 die vóór het samenvoegen buiten de hoofdthread berekend zijn: pincode → hash, en
    /// "bewaarde hash + pincode" → klopt. Voorheen liep dit tijdens het toepassen van de sync op de hoofdthread.
    private var pinMade: [String: String] = [:]
    private var pinMatch: [String: Bool] = [:]

    private func makePin(_ plain: String) -> String? { pinMade[plain] ?? PinHash.make(pin: plain)?.string }
    private func pinMatches(_ stored: String, _ plain: String) -> Bool {
        pinMatch[stored + "\u{1}" + plain] ?? PinHash.matches(stored: stored, pin: plain)
    }

    private func preparePins(_ server: [String: (data: Any, updatedAt: String?)]) async {
        var plains = Set<String>()
        var pairs = Set<String>()
        for p in CloudStore.shared.profiles {
            let local = Keychain.get(ParentalControl.pinKey(for: p.id))
            if let l = local, PinHash.isLegacyPlain(l) { plains.insert(l) }
            guard let data = server[profileSection(p.id)]?.data as? [String: Any],
                  case .legacy(let plain, _) = PinState.read(data, sectionAt: 0, time: { Self.time($0) }) else { continue }
            plains.insert(plain)
            if let l = local { pairs.insert(l + "\u{1}" + plain) }
        }
        guard !plains.isEmpty || !pairs.isEmpty else { return }
        let ps = plains, pr = pairs
        let (made, match) = await Task.detached(priority: .userInitiated) { () -> ([String: String], [String: Bool]) in
            var made: [String: String] = [:], match: [String: Bool] = [:]
            for p in ps { if let h = PinHash.make(pin: p)?.string { made[p] = h } }
            for k in pr {
                let parts = k.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { continue }
                match[k] = PinHash.matches(stored: parts[0], pin: parts[1])
            }
            return (made, match)
        }.value
        pinMade = made
        pinMatch = match
    }

    // MARK: - connections

    private func localConnections() -> [String: Any] {
        var out: [String: Any] = [:]
        if let t = Keychain.getCodable(TraktTokens.self, "trakt.tokens") {
            var d: [String: Any] = ["accessToken": t.accessToken, "refreshToken": t.refreshToken,
                                    "expiresAt": Self.iso(t.expiresAt.timeIntervalSince1970)]
            d["username"] = Self.orNull(t.username)
            out["trakt"] = d
        } else {
            out["trakt"] = NSNull()
        }
        if let s = OpenSubtitles.shared.syncedSession {
            out["opensubtitles"] = ["token": s.token, "username": s.username, "baseURL": s.baseURL]
        } else {
            out["opensubtitles"] = NSNull()
        }
        return out
    }

    /// Lokale wijziging aan de koppelingen herkennen. `true` = veranderd.
    @discardableResult
    private func noteConnections(force: Bool = false) -> Bool {
        let fp = Self.fingerprint(localConnections())
        guard force || fp != meta.connections.fp else { return false }
        let at: Double? = (meta.connectionsSeeded || force) ? trustedNow() : meta.connections.at
        meta.connections = Stamp(fp: fp, at: at)
        return true
    }

    private func mergeConnections(_ remote: (data: Any, updatedAt: String?)?) async -> [String: Any]? {
        let local = localConnections()
        let hasLocal = !(local["trakt"] is NSNull) || !(local["opensubtitles"] is NSNull)
        guard let remote, let data = remote.data as? [String: Any] else {
            // migratie: server leeg en lokaal een koppeling → uploaden
            guard hasLocal else { return nil }
            let at = meta.connections.at ?? trustedNow()
            meta.connections.at = at
            return connectionsPayload(local, extras: [:], at: at)
        }
        let serverAt = Self.time(data["updatedAt"]) ?? Self.time(remote.updatedAt) ?? 0
        let localAt = meta.connections.at
        var result = local
        var resultAt: Double
        if localAt == nil {
            // eerste keer (herinstallatie, nieuw apparaat of update): van de server overnemen wat er is,
            // en een lokale koppeling die de server niet heeft houden (migratie)
            var keptLocal = false
            for k in ["trakt", "opensubtitles"] {
                if let v = data[k], !(v is NSNull), Self.validConnection(k, v) { result[k] = v }
                else if !(local[k] is NSNull) { keptLocal = true }
            }
            resultAt = keptLocal ? trustedNow() : serverAt
        } else if serverAt > localAt! {
            for k in ["trakt", "opensubtitles"] {
                let v = data[k] ?? NSNull()
                result[k] = (v is NSNull || Self.validConnection(k, v)) ? v : local[k]
            }
            resultAt = serverAt
        } else {
            resultAt = localAt!
        }
        await applyConnections(result, current: local)
        meta.connections = Stamp(fp: Self.fingerprint(localConnections()), at: resultAt)
        let payload = connectionsPayload(result, extras: data, at: resultAt)
        return Self.same(Self.withoutUpdatedAt(payload), Self.withoutUpdatedAt(data)) ? nil : payload
    }

    private static func validConnection(_ kind: String, _ v: Any) -> Bool {
        guard let d = v as? [String: Any] else { return false }
        if kind == "trakt" {
            return !((d["accessToken"] as? String) ?? "").isEmpty && !((d["refreshToken"] as? String) ?? "").isEmpty
        }
        return !((d["token"] as? String) ?? "").isEmpty
    }

    private func connectionsPayload(_ c: [String: Any], extras: [String: Any], at: Double) -> [String: Any] {
        var out = extras
        out["trakt"] = c["trakt"] ?? NSNull()
        out["opensubtitles"] = c["opensubtitles"] ?? NSNull()
        out["updatedAt"] = Self.iso(at)
        return out
    }

    /// Koppelingen lokaal zetten en de Trakt- en OpenSubtitles-schermen bijwerken.
    private func applyConnections(_ c: [String: Any], current: [String: Any]) async {
        if !Self.same(c["trakt"] ?? NSNull(), current["trakt"] ?? NSNull()) {
            if let d = c["trakt"] as? [String: Any], let a = d["accessToken"] as? String, let r = d["refreshToken"] as? String {
                let exp = Self.time(d["expiresAt"]).map { Date(timeIntervalSince1970: $0) } ?? Date()
                let old = Keychain.getCodable(TraktTokens.self, "trakt.tokens")
                let t = TraktTokens(accessToken: a, refreshToken: r, expiresAt: exp,
                                    username: (d["username"] as? String) ?? old?.username)
                await TraktSync.shared.applySyncedConnection(t)
            } else if c["trakt"] is NSNull {
                await TraktSync.shared.applySyncedConnection(nil)
            }
        }
        if !Self.same(c["opensubtitles"] ?? NSNull(), current["opensubtitles"] ?? NSNull()) {
            if let d = c["opensubtitles"] as? [String: Any], let token = d["token"] as? String {
                OpenSubtitles.shared.applySyncedSession(token: token, baseURL: d["baseURL"] as? String,
                                                        username: (d["username"] as? String) ?? "")
            } else if c["opensubtitles"] is NSNull {
                OpenSubtitles.shared.forgetSession()
            }
        }
    }

    // MARK: - settings

    private static let tabNames = ["home", "live", "movies", "series"]
    private static let sizeNames = ["small", "medium", "large"]

    /// De instellingen zoals ze naar de account gaan: `shared` (zelfde betekenis op beide platforms) en `apple`.
    private func localSettings() -> (shared: [String: Any], apple: [String: Any]) {
        let d = UserDefaults.standard
        let store = CloudStore.shared
        var shared: [String: Any] = [:]
        shared["appLanguage"] = Localizer.shared.override
        shared["playerEngine"] = d.string(forKey: "player.engine") ?? "auto"
        shared["subtitleSize"] = Self.sizeNames[min(max(SubtitleSize.current.rawValue, 0), 2)]
        // kijkvoorkeuren: die van het hoofdaccount (andere profielen hebben hun eigen in profile.<id>)
        let main = store.profiles.first { $0.id == store.mainProfileID }
        let useGlobals = store.activeProfileID == nil || store.isMainActive
        func pref<T>(_ v: T?, _ global: @autoclosure () -> T) -> Any? {
            if let v { return v }
            return useGlobals ? global() : nil
        }
        shared["audioLanguage"] = pref(main?.audioLanguage, TrackPreferences.audio)
        var subtitleLanguage = pref(main?.streamSubtitleLanguage, TrackPreferences.subtitle)
        // build 59: "off" | "whenNeeded" | "always" (was true/false)
        var autoSubtitles = pref(main?.effectiveSubtitleMode, TrackPreferences.subtitleMode.rawValue)
        // build 60: het oude "off" als ondertiteltaal betekent "automatisch uit" (docs/ACCOUNT.md → Build 59);
        // zo opslaan, dan lezen alle platforms hetzelfde
        // (alleen als er geen modus gekozen is; `TrackPreferences.subtitleMode` geeft dan al "off")
        if (subtitleLanguage as? String) == "off" {
            subtitleLanguage = ""
            if main?.effectiveSubtitleMode == nil && !useGlobals { autoSubtitles = TrackPreferences.SubtitleMode.off.rawValue }
        }
        shared["subtitleLanguage"] = subtitleLanguage
        shared["autoSubtitles"] = autoSubtitles
        shared["openSubtitlesLanguage"] = pref(main?.subtitleLanguage, OpenSubtitles.shared.defaultLanguage)
        shared["openSubtitlesLanguages"] = OpenSubtitles.shared.preferredLanguages
        let tab = d.integer(forKey: "ui.startTab")
        shared["startScreen"] = Self.tabNames.indices.contains(tab) ? Self.tabNames[tab] : "home"
        var hidden: [String] = []
        if !(d.object(forKey: "ui.showLive") as? Bool ?? true) { hidden.append("live") }
        if !(d.object(forKey: "ui.showMovies") as? Bool ?? true) { hidden.append("movies") }
        if !(d.object(forKey: "ui.showSeries") as? Bool ?? true) { hidden.append("series") }
        shared["hiddenTabs"] = hidden
        shared["introMusic"] = true   // instelling vervallen: altijd aan (oudere apps lezen dit veld nog)
        // build 145: `refreshInterval` niet meer schrijven: "Servers laden bij openen" is per apparaat (niet gesynct);
        // bij het samenvoegen blijft de waarde van de server staan voor oudere apps en Android
        shared["parentalControl"] = store.parental.enabled
        shared["parentalAutoLockAdult"] = store.parental.autoLockAdult
        shared["traktScrobble"] = TraktSync.scrobbleEnabled
        shared["traktAskRating"] = TraktSync.askRating
        // build 52: deinterlacing, laatste zender en intro-markeringen (zelfde sleutels als Android).
        // `accentColor` staat sinds build 54 per profiel in account_data.profiles; de oude sleutel hier wordt niet
        // meer geschreven (bij het samenvoegen blijft de waarde van de server gewoon staan).
        shared["deinterlace"] = DeinterlaceMode.current.rawValue
        shared["resumeLastChannel"] = PlayerSettings.resumeLastChannel
        shared["introMarkers"] = IntroMarkers.syncJSON()

        var apple: [String: Any] = [:]
        shared["categorySort"] = d.string(forKey: "category.sort") ?? "standard"
        if let h = d.string(forKey: "trakt.oauthHost") { apple["traktOAuthHost"] = h }
        apple["zapDelay"] = PlayerSettings.zapDelay
        apple["channelPreview"] = PlayerSettings.previewEnabled
        apple["matchFrameRate"] = PlayerSettings.matchFrameRate
        apple["nasServers"] = NASServer.load().map { s -> [String: Any] in
            ["id": s.id.uuidString, "name": s.name, "host": s.host, "share": s.share, "username": s.username,
             "password": Keychain.get(s.passwordKey) ?? ""]
        }
        return (shared, apple)
    }

    /// Lokale wijziging aan de instellingen herkennen. `true` = veranderd.
    @discardableResult
    private func noteSettings() -> Bool {
        let s = localSettings()
        let fp = Self.fingerprint(["shared": s.shared, "apple": s.apple])
        if meta.settingsFormat != Self.settingsFormat {
            // andere opbouw na een update: alleen de vingerafdruk bijwerken
            if meta.settings.fp != nil { meta.settings.fp = fp }
            meta.settingsFormat = Self.settingsFormat
            saveMeta()
            return false
        }
        guard fp != meta.settings.fp else { return false }
        meta.settings = Stamp(fp: fp, at: meta.settingsSeeded ? trustedNow() : meta.settings.at)
        saveMeta()
        return true
    }

    private func mergeSettings(_ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let data = remote?.data as? [String: Any]
        let serverAt = Self.time(data?["updatedAt"]) ?? Self.time(remote?.updatedAt) ?? 0
        let localAt = meta.settings.at
        if let data, localAt == nil || serverAt > localAt! {
            // de server wint (geheel): toepassen, en alleen het eigen `apple`-blok aanvullen als het ontbreekt
            applySettings(shared: data["shared"] as? [String: Any] ?? [:], apple: data["apple"] as? [String: Any] ?? [:],
                          serverAt: serverAt)
            let s = localSettings()
            meta.settings = Stamp(fp: Self.fingerprint(["shared": s.shared, "apple": s.apple]), at: serverAt)
            guard data["apple"] == nil else { return nil }
            var out = data
            out["apple"] = s.apple
            return out
        }
        // lokaal wint (of de server is leeg: migratie)
        let at = localAt ?? trustedNow()
        let s = localSettings()
        meta.settings = Stamp(fp: Self.fingerprint(["shared": s.shared, "apple": s.apple]), at: at)
        var out = data ?? [:]
        var shared = data?["shared"] as? [String: Any] ?? [:]
        let serverEngine = shared["playerEngine"] as? String
        for (k, v) in s.shared { shared[k] = v }
        // "auto" hier en een speler die Apple niet heeft (bijv. "exo" van Android): die van de server laten staan
        if let e = serverEngine, PlayerController.EngineChoice(rawValue: e) == nil, (s.shared["playerEngine"] as? String) == "auto" {
            shared["playerEngine"] = e
        }
        var apple = data?["apple"] as? [String: Any] ?? [:]
        for (k, v) in s.apple { apple[k] = v }
        out["shared"] = shared
        out["apple"] = apple
        out["updatedAt"] = Self.iso(at)
        if let data, Self.same(Self.withoutUpdatedAt(out), Self.withoutUpdatedAt(data)) { return nil }
        return out
    }

    private func applySettings(shared: [String: Any], apple: [String: Any], serverAt: Double) {
        let d = UserDefaults.standard
        let store = CloudStore.shared
        func setIfChanged(_ v: Any, _ key: String) {
            if let s = v as? String, d.string(forKey: key) == s { return }
            if let b = v as? Bool, d.object(forKey: key) as? Bool == b { return }
            if let i = v as? Int, d.object(forKey: key) as? Int == i { return }
            d.set(v, forKey: key)
        }
        if let v = shared["playerEngine"] as? String {
            let e = PlayerController.EngineChoice(rawValue: v) ?? .auto   // "exo" (Android) → automatisch
            setIfChanged(e.rawValue, "player.engine")
        }
        if let v = shared["subtitleSize"] as? String, let i = Self.sizeNames.firstIndex(of: v) { setIfChanged(i, SubtitleSize.key) }
        if let v = shared["openSubtitlesLanguages"] as? [String], !v.isEmpty, v != OpenSubtitles.shared.preferredLanguages {
            OpenSubtitles.shared.preferredLanguages = v
        }
        if let v = shared["startScreen"] as? String, let i = Self.tabNames.firstIndex(of: v) { setIfChanged(i, "ui.startTab") }
        if let v = shared["hiddenTabs"] as? [String] {
            setIfChanged(!v.contains("live"), "ui.showLive")
            setIfChanged(!v.contains("movies"), "ui.showMovies")
            setIfChanged(!v.contains("series"), "ui.showSeries")
        }
        // introMusic: niet meer lezen (intromuziek staat altijd aan)
        // build 145: `refreshInterval` niet meer lezen (de vernieuwtermijn is vervallen; "Servers laden bij openen" is per apparaat)
        if let p = shared["parentalControl"] as? [String: Any] {
            store.setSyncedParental(enabled: p["enabled"] as? Bool ?? store.parental.enabled,
                                    autoLockAdult: p["autoLockAdult"] as? Bool ?? store.parental.autoLockAdult)
        } else if shared["parentalControl"] is Bool || shared["parentalAutoLockAdult"] is Bool {
            store.setSyncedParental(enabled: shared["parentalControl"] as? Bool ?? store.parental.enabled,
                                    autoLockAdult: shared["parentalAutoLockAdult"] as? Bool ?? store.parental.autoLockAdult)
        }
        if let v = shared["traktScrobble"] as? Bool { setIfChanged(v, "trakt.scrobble") }
        if let v = shared["traktAskRating"] as? Bool { setIfChanged(v, "trakt.askRating") }
        // oude accentkleur van het account (build 52/53): alleen nog bewaren voor de eenmalige migratie naar de profielen
        if !d.bool(forKey: AccentChoice.migratedKey), let v = shared["accentColor"] as? String, AccentChoice(rawValue: v) != nil {
            setIfChanged(v, AccentChoice.legacyKey)
            ProfileSync.shared.legacyAccentArrived()
        }
        if let v = shared["deinterlace"] as? String, DeinterlaceMode(rawValue: v) != nil { setIfChanged(v, DeinterlaceMode.key) }
        if let v = shared["resumeLastChannel"] as? Bool { setIfChanged(v, PlayerSettings.resumeLastChannelKey) }
        if let v = shared["introMarkers"] as? [String: Any] { IntroMarkers.apply(syncJSON: v) }

        // kijkvoorkeuren van het hoofdaccount
        let audio = shared["audioLanguage"] as? String
        var sub = shared["subtitleLanguage"] as? String
        var auto = TrackPreferences.mode(fromSynced: shared["autoSubtitles"])?.rawValue
        // build 60: oud "off" als taal (oudere app) = automatisch uit, in de app-taal
        // alleen als `autoSubtitles` ontbreekt: een gesynchroniseerde modus wint
        if sub == "off" { sub = ""; if auto == nil { auto = TrackPreferences.SubtitleMode.off.rawValue } }
        let os = shared["openSubtitlesLanguage"] as? String
        if let main = store.mainProfileID, audio != nil || sub != nil || auto != nil || os != nil {
            store.setSyncedPreferences(main) { p in
                if let audio { p.audioLanguage = audio }
                if let sub { p.streamSubtitleLanguage = sub }
                if let auto { p.subtitleMode = auto }
                if let os { p.subtitleLanguage = os }
            }
            // dezelfde voorkeuren zijn nu ook de bekende stand van profile.<hoofdprofiel>
            if var m = meta.profiles[main.uuidString], let p = store.profiles.first(where: { $0.id == main }) {
                let fp = Self.fingerprint(Self.prefs(of: p))
                if fp != m.prefs.fp { m.prefs = Stamp(fp: fp, at: max(serverAt, m.prefs.at ?? 0)) }
                meta.profiles[main.uuidString] = m
            }
        }
        if store.activeProfileID == nil || store.isMainActive {
            if let audio { setIfChanged(audio, TrackPreferences.audioKey) }
            if let sub { setIfChanged(sub, TrackPreferences.subtitleKey) }
            if let auto { setIfChanged(auto, TrackPreferences.subtitleModeKey) }
            if let os, os != OpenSubtitles.shared.defaultLanguage { OpenSubtitles.shared.defaultLanguage = os }
        }

        // apple
        if let v = (shared["categorySort"] as? String) ?? (apple["categorySort"] as? String) { setIfChanged(v, "category.sort") }
        if let raw = apple["traktOAuthHost"] as? String, let v = TraktClient.allowedOAuthHost(raw) { setIfChanged(v, "trakt.oauthHost") }   // build 141: vaste lijst
        if let v = (apple["zapDelay"] as? NSNumber)?.doubleValue, PlayerSettings.zapDelays.contains(v),
           v != PlayerSettings.zapDelay { d.set(v, forKey: PlayerSettings.zapDelayKey) }
        if let v = apple["channelPreview"] as? Bool { setIfChanged(v, PlayerSettings.previewKey) }
        if let v = apple["matchFrameRate"] as? Bool { setIfChanged(v, PlayerSettings.matchKey) }
        if let list = apple["nasServers"] as? [[String: Any]] {
            var servers: [NASServer] = []
            for j in list {
                guard let host = j["host"] as? String, !host.isEmpty else { continue }
                var s = NASServer(name: j["name"] as? String ?? host, host: host, share: j["share"] as? String ?? "",
                                  username: j["username"] as? String ?? "")
                if let id = (j["id"] as? String).flatMap(UUID.init(uuidString:)) { s.id = id }
                servers.append(s)
                let pw = j["password"] as? String ?? ""
                if (Keychain.get(s.passwordKey) ?? "") != pw { Keychain.set(pw.isEmpty ? nil : pw, for: s.passwordKey) }
            }
            if servers != NASServer.load() { NASServer.save(servers) }
        }

        // taal als laatste: dit bouwt de hele interface opnieuw op
        if let v = (shared["appLanguage"] as? String) ?? (shared["language"] as? String), v != Localizer.shared.override,
           v.isEmpty || Localizer.supported.contains(where: { $0.code == v }) {
            Localizer.shared.override = v
        }
    }

    // MARK: - reminders

    private func noteReminders() {
        var m = meta.reminders
        let now = m.seeded ? trustedNow() : 0
        let current = Dictionary(CloudStore.shared.reminders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Self.diff(&m, "reminders", Set(current.keys), now: now)
        meta.reminders = m
    }

    private func mergeReminders(_ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let store = CloudStore.shared
        let data: [String: Any]
        if let d = remote?.data as? [String: Any] { data = d }
        else if let a = remote?.data as? [Any] { data = ["reminders": a] }
        else { data = [:] }
        let sectionAt = Self.time(data["updatedAt"]) ?? Self.time(remote?.updatedAt) ?? 0
        // `items` eerst: Android en Tizen schrijven `items`; Android-apps tot nu toe laten daarbij een oudere `reminders`
        // (van iOS) staan. iOS schrijft `reminders` en haalt `items` weg, dus staan ze er allebei, dan is `items` het nieuwst.
        let raw = (data["items"] ?? data["reminders"] ?? data["list"]) as? [Any] ?? []
        var serverItems: [String: ProgramReminder] = [:]
        var serverPresent: [String: Double] = [:]
        var serverRemoved: [String: Double] = Self.timeMap(data["removed"])
        for e in raw {
            guard let j = e as? [String: Any], let id = Self.string(j["id"]) else { continue }
            let at = Self.time(j["at"]) ?? Self.time(j["updatedAt"]) ?? sectionAt
            if (j["removed"] as? Bool) == true { serverRemoved[id] = max(serverRemoved[id] ?? 0, at); continue }
            guard let r = Self.reminder(j, id: id) else { continue }
            serverItems[id] = r
            serverPresent[id] = max(serverPresent[id] ?? 0, at)
        }
        let local = Dictionary(store.reminders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var m = meta.reminders
        let merged = Self.mergeSet(local: (m.present["reminders"] ?? [:], m.removed["reminders"] ?? [:]),
                                   server: (serverPresent, serverRemoved))
        let cutoff = Date().addingTimeInterval(-3600)
        var list: [ProgramReminder] = []
        var present: [String: Double] = [:]
        for (id, at) in merged.present {
            guard let r = local[id] ?? serverItems[id], r.start > cutoff else { continue }
            list.append(r)
            present[id] = at
        }
        list.sort { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        // meldingen: nieuw van de server → inplannen; elders verwijderd → intrekken
        for r in list where local[r.id] == nil {
            Task { await ReminderCenter.shared.scheduleNotification(r, ask: false) }
        }
        for id in local.keys where present[id] == nil { ReminderCenter.shared.cancelNotification(id) }
        store.replaceReminders(list)
        m.present["reminders"] = present
        m.removed["reminders"] = Self.pruned(merged.removed)
        m.seeded = true
        meta.reminders = m

        let items: [[String: Any]] = list.map { r in
            var j = Self.reminderJSON(r, id: r.id)
            j["at"] = Self.iso(present[r.id] ?? 0)
            return j
        }
        let normalizedServer = remindersPayload(
            serverItems.filter { serverPresent[$0.key] != nil && $0.value.start > cutoff }
                .sorted { $0.value.start != $1.value.start ? $0.value.start < $1.value.start : $0.key < $1.key }
                .map { id, r -> [String: Any] in
                    var j = Self.reminderJSON(r, id: id)
                    j["at"] = Self.iso(serverPresent[id] ?? 0)
                    return j
                },
            removed: Self.pruned(serverRemoved), extras: data, at: sectionAt)
        let payload = remindersPayload(items, removed: m.removed["reminders"] ?? [:], extras: data,
                                       at: trustedNow())
        if remote != nil, Self.same(Self.withoutUpdatedAt(payload), Self.withoutUpdatedAt(normalizedServer)) { return nil }
        if remote == nil && items.isEmpty && (m.removed["reminders"] ?? [:]).isEmpty { return nil }
        return payload
    }

    private func remindersPayload(_ items: [[String: Any]], removed: [String: Double], extras: [String: Any],
                                  at: Double) -> [String: Any] {
        var out = extras
        for k in ["items", "list"] { out[k] = nil }
        out["reminders"] = items
        out["removed"] = removed.mapValues { Self.iso($0) }
        out["updatedAt"] = Self.iso(at)
        return out
    }

    private static func reminder(_ j: [String: Any], id: String) -> ProgramReminder? {
        guard let pl = string(j["playlistID"]).flatMap(UUID.init(uuidString:)),
              let channel = string(j["channelID"]),
              let start = time(j["start"]) else { return nil }
        // profiel: het veld `profileID`, anders uit de ID ("p:<profiel>:…"), anders het hoofdprofiel (nil)
        let profile = string(j["profileID"]).flatMap(UUID.init(uuidString:)) ?? ProgramReminder.profile(fromID: id)
        return ProgramReminder(id: id, playlistID: pl, channelID: channel,
                               channelName: j["channelName"] as? String ?? "", title: j["title"] as? String ?? "",
                               start: Date(timeIntervalSince1970: start), profileID: profile)
    }

    /// Eén herinnering voor de server (zonder `at`). `profileID` in kleine letters, alleen bij een ander profiel dan het
    /// hoofdprofiel (zie docs/ACCOUNT.md → "Herinneringen per profiel").
    private static func reminderJSON(_ r: ProgramReminder, id: String) -> [String: Any] {
        var j: [String: Any] = ["id": id, "playlistID": r.playlistID.uuidString, "channelID": r.channelID,
                                "channelName": r.channelName, "title": r.title,
                                "start": iso(r.start.timeIntervalSince1970)]
        if let p = r.profileID { j["profileID"] = p.uuidString.lowercased() }
        return j
    }

    // MARK: - account (build 140): categorieën voor het hele account

    private static let accountField = "hiddenCategories"

    private func noteAccount() {
        var m = meta.account ?? ListMeta()
        let now = m.seeded ? trustedNow() : 0
        Self.diff(&m, Self.accountField, CloudStore.shared.hiddenCategories, now: now)
        meta.account = m
    }

    /// Migratie (build 140): deze sleutels tellen als heel oud, zodat een keuze van een ander apparaat voorgaat.
    private func presetOldAccount(_ keys: [String]) {
        var m = meta.account ?? ListMeta()
        var present = m.present[Self.accountField] ?? [:]
        for k in keys where present[k] == nil { present[k] = 1 }
        m.present[Self.accountField] = present
        meta.account = m
        saveMeta()
    }

    /// Server-id in kleine letters (build 140); bij twee schrijfwijzen telt de nieuwste tijd.
    private static func normalizedKeys(_ d: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in d {
            let n = AccountCategories.normalize(k)
            out[n] = max(out[n] ?? -1, v)
        }
        return out
    }

    private func mergeAccount(_ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let store = CloudStore.shared
        noteAccount()
        var m = meta.account ?? ListMeta()
        let data = remote?.data as? [String: Any] ?? [:]
        let sectionAt = Self.time(data["updatedAt"]) ?? Self.time(remote?.updatedAt) ?? 0
        var s = Self.decodeSet(data[Self.accountField], fallbackAt: sectionAt)
        let removedAll = data["removed"] as? [String: Any] ?? [:]
        for (k, v) in Self.timeMap(removedAll[Self.accountField]) { s.removed[k] = max(s.removed[k] ?? 0, v) }
        let server = (present: Self.normalizedKeys(s.present), removed: Self.normalizedKeys(s.removed))
        let merged = Self.mergeSet(local: (Self.normalizedKeys(m.present[Self.accountField] ?? [:]),
                                           Self.normalizedKeys(m.removed[Self.accountField] ?? [:])),
                                   server: server)
        let removed = Self.pruned(merged.removed)
        store.setSyncedAccountCategories(Set(merged.present.keys))
        m.present[Self.accountField] = merged.present
        m.removed[Self.accountField] = removed
        m.seeded = true
        meta.account = m

        let mine = accountPayload(present: merged.present, removed: removed, extras: data)
        guard remote != nil else {
            return merged.present.isEmpty && removed.isEmpty ? nil : mine
        }
        let theirsMerged = Self.mergeSet(local: ([:], [:]), server: server)
        let theirs = accountPayload(present: theirsMerged.present, removed: Self.pruned(theirsMerged.removed), extras: data)
        return Self.same(Self.withoutUpdatedAt(mine), Self.withoutUpdatedAt(theirs)) ? nil : mine
    }

    private func accountPayload(present: [String: Double], removed: [String: Double], extras: [String: Any]) -> [String: Any] {
        var out = extras
        var items: [[String: Any]] = present.sorted { $0.key < $1.key }.map { ["id": $0.key, "at": Self.iso($0.value)] }
        items += removed.sorted { $0.key < $1.key }.map { ["id": $0.key, "removed": true, "at": Self.iso($0.value)] }
        out[Self.accountField] = items
        var removedOut = extras["removed"] as? [String: Any] ?? [:]
        removedOut[Self.accountField] = removed.mapValues { Self.iso($0) }
        out["removed"] = removedOut
        out["updatedAt"] = Self.iso(trustedNow())
        return out
    }

    // MARK: - collections (build 51, per profiel sinds build 54)
    //
    // Section `collections` (zie docs/ACCOUNT.md → "Build 54"):
    // `{version: 2, profiles: {"<profielID>": {items:[…], updatedAt}}, items:[…oud…], migratedAt, updatedAt}`.
    // Elk profiel heeft zijn eigen collecties. `items` op het hoogste niveau is het formaat van build 51–53: dat
    // blijft onaangeroerd staan en wordt alleen gelezen zolang `version` < 2 (de migratie).

    /// Onbekende velden per collectie van de server (die gaan onaangeroerd terug), per "<profielID>|<collectieID>"
    private let collectionExtrasKey = "account.collectionExtras.v2"
    /// Build 51–53: per collectie-ID (alleen nog voor de migratie)
    private let legacyCollectionExtrasKey = "account.collectionExtras.v1"

    private func loadCollectionExtras(_ key: String? = nil) -> [String: [String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: key ?? collectionExtrasKey),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { return [:] }
        return j
    }

    private func saveCollectionExtras(_ e: [String: [String: Any]]) {
        guard JSONSerialization.isValidJSONObject(e), let d = try? JSONSerialization.data(withJSONObject: e) else { return }
        UserDefaults.standard.set(d, forKey: collectionExtrasKey)
    }

    private static func extrasKey(_ owner: UUID, _ id: String) -> String { owner.uuidString + "|" + id }

    /// Per profiel en per item wint de nieuwste `updatedAt` (ook een tombstone). Oude collecties (build 51–53,
    /// zonder profiel) gaan eenmalig naar het hoofdprofiel (build 74; daarvoor naar elk profiel), met dezelfde `id`
    /// en `updatedAt`, zodat niets verdwijnt en de rijen op het startscherm (`collection:<id>`) blijven werken. Geeft de data terug als er
    /// geüpload moet worden.
    private func mergeCollections(_ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let store = CloudStore.shared
        let data: [String: Any]
        if let d = remote?.data as? [String: Any] { data = d }
        else if let a = remote?.data as? [Any] { data = ["items": a] }
        else { data = [:] }
        let tombs = ProfileSync.shared.tombstonedIDs
        let profileIDs = store.profiles.map(\.id).filter { !tombs.contains($0) }
        guard !profileIDs.isEmpty else { return nil }
        let known = Set(profileIDs)
        let serverBuckets = data["profiles"] as? [String: Any] ?? [:]
        let migrated = ((data["version"] as? NSNumber)?.intValue ?? 1) >= 2 || data["profiles"] is [String: Any]

        // server: per profiel; emmers van profielen die dit apparaat (nog) niet kent blijven onaangeroerd
        var server: [UUID: [String: (c: BingrCollection, raw: [String: Any])]] = [:]
        var serverKey: [UUID: String] = [:]
        var foreign: [String: Any] = [:]
        for (key, v) in serverBuckets {
            let owner = ProfileSync.uuid(for: key)
            guard known.contains(owner) else {
                if !tombs.contains(owner) { foreign[key] = v }   // verwijderd profiel: emmer weg
                continue
            }
            serverKey[owner] = key
            let items = ((v as? [String: Any])?["items"] as? [Any]) ?? (v as? [Any]) ?? []
            var bucket = server[owner] ?? [:]
            for e in items {
                guard let j = e as? [String: Any], var c = Self.collection(j) else { continue }
                c.owner = owner
                if let old = bucket[c.id], old.c.updatedAt >= c.updatedAt { continue }
                bucket[c.id] = (c, j)
            }
            server[owner] = bucket
        }

        // oude collecties (zonder profiel): van de server zolang die nog niet gemigreerd is, en lokaal
        var legacy: [String: (c: BingrCollection, raw: [String: Any]?)] = [:]
        // alle oude collecties van de server (ook na de migratie), om de kopieën van build 54–73 te herkennen
        var legacyStamps: [String: Set<Date>] = [:]
        for e in data["items"] as? [Any] ?? [] {
            guard let j = e as? [String: Any], let c = Self.collection(j) else { continue }
            legacyStamps[c.id, default: []].insert(c.updatedAt)
            if migrated { continue }
            if let old = legacy[c.id], old.c.updatedAt >= c.updatedAt { continue }
            legacy[c.id] = (c: c, raw: Optional(j))
        }
        let legacyExtras = loadCollectionExtras(legacyCollectionExtrasKey)
        for c in store.collections where c.owner == nil {
            if let old = legacy[c.id], old.c.updatedAt >= c.updatedAt { continue }
            let raw: [String: Any]? = legacy[c.id]?.raw ?? legacyExtras[c.id]
            legacy[c.id] = (c: c, raw: raw)
        }

        // het hoofdprofiel is nodig voor de migratie; nog onbekend: wachten (niets weggooien)
        let main = store.mainProfileID.flatMap { known.contains($0) ? $0 : nil }
        if main == nil && !legacy.isEmpty { return nil }

        // samenvoegen: lokaal (per profiel) + server, nieuwste `updatedAt` wint
        var extras = loadCollectionExtras()
        var merged: [UUID: [String: BingrCollection]] = [:]
        for c in store.collections {
            guard let o = c.owner, known.contains(o) else { continue }
            if let old = merged[o]?[c.id], old.updatedAt >= c.updatedAt { continue }
            merged[o, default: [:]][c.id] = c
        }
        for (owner, bucket) in server {
            for (id, s) in bucket {
                extras[Self.extrasKey(owner, id)] = s.raw
                if let l = merged[owner]?[id], l.updatedAt >= s.c.updatedAt { continue }
                merged[owner, default: [:]][id] = s.c
            }
        }
        // migratie (build 74): oude collecties gaan alleen naar het hoofdprofiel; een profiel ziet nooit de
        // collecties van een ander profiel
        if let owner = main {
            for (id, l) in legacy where merged[owner]?[id] == nil {
                var c = l.c
                c.owner = owner
                c.id = id
                merged[owner, default: [:]][id] = c
                if let r = l.raw { extras[Self.extrasKey(owner, id)] = r }
            }
        }
        // build 54–73 kopieerde oude collecties naar élk profiel: ongewijzigde kopieën bij een ander profiel dan het
        // hoofdprofiel (zelfde `id` en `updatedAt` als de oude collectie of als die van het hoofdprofiel) worden
        // tombstones, zodat ze ook op andere apparaten verdwijnen
        if let main {
            for c in legacy.values.map(\.c) { legacyStamps[c.id, default: []].insert(c.updatedAt) }
            for c in (merged[main] ?? [:]).values { legacyStamps[c.id, default: []].insert(c.updatedAt) }
            let now = Date()
            for owner in profileIDs where owner != main {
                for (id, c) in merged[owner] ?? [:] where !c.deleted {
                    guard let stamps = legacyStamps[id],
                          stamps.contains(where: { abs($0.timeIntervalSince(c.updatedAt)) < 1 }) else { continue }
                    var t = c
                    t.deleted = true
                    t.deletedAt = now
                    t.updatedAt = now
                    t.items = []
                    merged[owner]?[id] = t
                }
            }
        }
        // tombstones ouder dan 90 dagen weg
        let cutoff = Date().addingTimeInterval(-Self.removedLifetime)
        for (owner, bucket) in merged {
            merged[owner] = bucket.filter { !$0.value.deleted || ($0.value.deletedAt ?? $0.value.updatedAt) >= cutoff }
        }
        let list = profileIDs.flatMap { Self.sortedCollections(Array((merged[$0] ?? [:]).values)) }
        store.replaceCollections(list)
        extras = extras.filter { k, _ in list.contains { Self.extrasKey($0.owner!, $0.id) == k } }
        saveCollectionExtras(extras)
        UserDefaults.standard.removeObject(forKey: legacyCollectionExtrasKey)

        if remote == nil && list.isEmpty { return nil }
        // uploaden als er gemigreerd is, of als een profiel lokaal iets anders heeft dan de server
        var buckets = foreign
        var differs = !migrated
        for owner in profileIDs {
            let key = serverKey[owner] ?? ProfileSync.shared.serverID(for: owner)
            let mine = Self.sortedCollections(Array((merged[owner] ?? [:]).values))
            let theirs = Self.sortedCollections((server[owner] ?? [:]).values.map(\.c))
            let mineJSON = mine.map { Self.collectionJSON($0, extras: extras[Self.extrasKey(owner, $0.id)] ?? [:]) }
            let theirsJSON = theirs.map { Self.collectionJSON($0, extras: extras[Self.extrasKey(owner, $0.id)] ?? [:]) }
            if !Self.same(mineJSON, theirsJSON) { differs = true }
            if mine.isEmpty && serverBuckets[key] == nil { continue }
            var b = serverBuckets[key] as? [String: Any] ?? [:]
            b["items"] = mineJSON
            let last = mine.map(\.updatedAt).max() ?? Date(timeIntervalSince1970: 0)
            b["updatedAt"] = Self.iso(last.timeIntervalSince1970)
            buckets[key] = b
        }
        // emmers van verwijderde profielen die de server nog had: weg
        if serverBuckets.keys.contains(where: { tombs.contains(ProfileSync.uuid(for: $0)) }) { differs = true }
        guard differs else { return nil }
        var out = data
        out["version"] = 2
        out["profiles"] = buckets
        if out["migratedAt"] == nil { out["migratedAt"] = Self.iso(trustedNow()) }
        out["updatedAt"] = Self.iso(trustedNow())
        return out
    }

    private static func sortedCollections(_ l: [BingrCollection]) -> [BingrCollection] {
        l.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    private static func collectionJSON(_ c: BingrCollection, extras: [String: Any]) -> [String: Any] {
        var d = extras
        d["id"] = c.id
        d["name"] = c.name
        if let u = c.image.url, !u.isEmpty {
            d["image"] = ["url": u]
        } else {
            d["image"] = ["symbol": c.image.avatar.symbol, "colorIndex": c.image.avatar.colorIndex]
        }
        d["kind"] = c.kind.rawValue
        // build 128: `sid` (server van het item) als hij bekend is
        d["items"] = c.items.map { i -> [String: Any] in
            var x: [String: Any] = ["type": i.type.rawValue, "id": i.id]
            if let sid = i.sid, !sid.isEmpty { x["sid"] = sid }
            return x
        }
        d["query"] = c.query
        d["types"] = c.types
        if let g = c.group, !g.isEmpty { d["group"] = g } else { d.removeValue(forKey: "group") }
        if let s = c.sourceID, !s.isEmpty { d["sourceID"] = s } else { d.removeValue(forKey: "sourceID") }
        d["order"] = c.order
        d["updatedAt"] = iso(c.updatedAt.timeIntervalSince1970)
        if c.deleted {
            d["deleted"] = true
            d["deletedAt"] = iso((c.deletedAt ?? c.updatedAt).timeIntervalSince1970)
        } else {
            d.removeValue(forKey: "deleted")
            d.removeValue(forKey: "deletedAt")
        }
        return d
    }

    private static func collection(_ j: [String: Any]) -> BingrCollection? {
        guard let id = string(j["id"]) else { return nil }
        var c = BingrCollection(name: j["name"] as? String ?? "")
        c.id = id
        if let img = j["image"] as? [String: Any] {
            var ci = CollectionImage()
            ci.url = (img["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ci.symbol = img["symbol"] as? String
            ci.colorIndex = (img["colorIndex"] as? NSNumber).map { (($0.intValue % PlaylistAvatar.palettes.count)
                + PlaylistAvatar.palettes.count) % PlaylistAvatar.palettes.count }
            if ci.url == nil && ci.symbol == nil { ci.symbol = "star" }
            c.image = ci
        }
        c.kind = (j["kind"] as? String).flatMap(BingrCollection.Kind.init(rawValue:)) ?? .manual
        c.items = (j["items"] as? [Any] ?? []).compactMap { e in
            guard let d = e as? [String: Any], let t = (d["type"] as? String).flatMap(CollectionItem.Kind.init(rawValue:)),
                  let iid = string(d["id"]) else { return nil }
            return CollectionItem(type: t, id: iid, sid: string(d["sid"]))
        }
        c.query = j["query"] as? String ?? ""
        if let t = j["types"] as? [String] { c.types = t }
        c.group = (j["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        c.sourceID = string(j["sourceID"])
        c.order = (j["order"] as? NSNumber)?.intValue ?? 0
        c.updatedAt = Date(timeIntervalSince1970: time(j["updatedAt"]) ?? 0)
        c.deleted = (j["deleted"] as? Bool) ?? false
        c.deletedAt = time(j["deletedAt"]).map { Date(timeIntervalSince1970: $0) }
        return c
    }

    // MARK: - startscherm (homeLayout in profile.<id>)

    private static func homeLayout(_ j: [String: Any]) -> HomeLayout? {
        guard let rows = j["rows"] as? [Any] else { return nil }
        var l = HomeLayout()
        l.rows = rows.compactMap { e in
            guard let d = e as? [String: Any], let k = string(d["key"]) else { return nil }
            return HomeLayout.Row(key: k, visible: (d["visible"] as? Bool) ?? true)
        }
        l.updatedAt = Date(timeIntervalSince1970: time(j["updatedAt"]) ?? 0)
        return l
    }

    private static func homeLayoutJSON(_ l: HomeLayout, extras: [String: Any]) -> [String: Any] {
        var d = extras
        d["rows"] = l.rows.map { ["key": $0.key, "visible": $0.visible] as [String: Any] }
        d["updatedAt"] = iso(l.updatedAt.timeIntervalSince1970)
        return d
    }

    // MARK: - profile.<id>

    private static func prefs(of p: ViewerProfile) -> [String: Any] {
        ["autoSubtitles": p.effectiveSubtitleMode.map { $0 as Any } ?? NSNull(),
         "subtitleLanguage": p.subtitleLanguage.map { $0 as Any } ?? NSNull(),
         "audioLanguage": p.audioLanguage.map { $0 as Any } ?? NSNull(),
         "streamSubtitleLanguage": p.streamSubtitleLanguage.map { $0 as Any } ?? NSNull()]
    }

    /// Lokale wijzigingen van een profiel herkennen (toegevoegd/verwijderd per item, voorkeuren, pincode).
    private func noteProfile(_ id: UUID) {
        let store = CloudStore.shared
        guard let profile = store.profiles.first(where: { $0.id == id }) else { return }
        var m = meta.profiles[id.uuidString] ?? ListMeta()
        let first = !m.seeded
        let now = first ? 0 : trustedNow()
        let d = store.profileData(id)
        Self.diff(&m, "myList", d.myList, now: now)
        Self.diff(&m, "favorites", d.favorites, now: now)
        Self.diff(&m, "watched", d.watched, now: now)
        Self.diff(&m, "hiddenCategories", d.hiddenCategories, now: now)
        Self.diffOrdered(&m, "recentChannels", d.recentChannels, now: now)
        // voortgang: alleen bewuste verwijderingen tellen (`progressCleared`), niet een sleutel die hier ontbreekt
        Self.diffTimed(&m, "progress", d.progress.mapValues { $0.updated.timeIntervalSince1970 }, now: now, inferRemovals: false)
        var hist: [String: Double] = [:]
        for e in d.history { hist[e.id] = max(hist[e.id] ?? 0, e.date.timeIntervalSince1970) }
        // geschiedenis: idem, alleen bewuste verwijderingen (`CloudStore.historyRemoved`)
        Self.diffTimed(&m, "history", hist, now: now, inferRemovals: false)
        let pfp = Self.fingerprint(Self.prefs(of: profile))
        if pfp != m.prefs.fp { m.prefs = Stamp(fp: pfp, at: first || m.prefs.fp == nil ? m.prefs.at : now) }
        let pinKeyName = ParentalControl.pinKey(for: id)
        let pin = Keychain.get(pinKeyName)
        let pinFP = Self.hash(pin ?? "")
        if pinFP != m.pin.fp {
            // build 146: de oude lokale pincode alleen omgezet naar een hash = geen nieuwe pincode (tijd blijft)
            let migrated = ParentalControl.consumeMigration(key: pinKeyName, value: pin)
            m.pin = Stamp(fp: pinFP, at: first || m.pin.fp == nil || migrated ? m.pin.at : now)
        }
        meta.profiles[id.uuidString] = m
    }

    private struct ProgressItem { var at: Double; var entry: ProgressEntry; var raw: [String: Any] }
    private struct HistoryItem { var at: Double; var entry: HistoryEntry; var raw: [String: Any] }

    /// Samenvoegen per contract en lokaal toepassen. Geeft de data terug als er geüpload moet worden.
    private func mergeProfile(_ id: UUID, _ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let store = CloudStore.shared
        guard let profile = store.profiles.first(where: { $0.id == id }) else { return nil }
        noteProfile(id)
        var m = meta.profiles[id.uuidString] ?? ListMeta()
        let data = remote?.data as? [String: Any] ?? [:]
        let sectionAt = Self.time(data["updatedAt"]) ?? Self.time(remote?.updatedAt) ?? 0
        let local = store.profileData(id)
        let removedAll = data["removed"] as? [String: Any] ?? [:]
        func serverRemoved(_ name: String) -> [String: Double] {
            var r = Self.timeMap(data[name + "Removed"])
            for (k, v) in Self.timeMap(removedAll[name]) { r[k] = max(r[k] ?? 0, v) }
            return r
        }

        // sets (Mijn lijst, favorieten, bekeken, recente zenders)
        var sets: [String: [String: Double]] = [:]
        var removed: [String: [String: Double]] = [:]
        var serverSets: [String: (present: [String: Double], removed: [String: Double])] = [:]
        for name in Self.setLists + ["recentChannels"] {
            var s = Self.decodeSet(data[name], fallbackAt: sectionAt)
            for (k, v) in serverRemoved(name) { s.removed[k] = max(s.removed[k] ?? 0, v) }
            serverSets[name] = s
            let merged = Self.mergeSet(local: (m.present[name] ?? [:], m.removed[name] ?? [:]), server: s)
            sets[name] = merged.present
            removed[name] = Self.pruned(merged.removed)
        }
        let recentOrdered = (sets["recentChannels"] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maxRecent)
        sets["recentChannels"] = Dictionary(uniqueKeysWithValues: recentOrdered.map { ($0.key, $0.value) })

        // voortgang: per sleutel de nieuwste updatedAt (een verwijdering telt mee)
        var serverProgress: [String: ProgressItem] = [:]
        for (k, v) in data["progress"] as? [String: Any] ?? [:] {
            guard let j = v as? [String: Any], let item = Self.progressItem(j, profile: id) else { continue }
            serverProgress[k] = item
        }
        let serverProgressRemoved = serverRemoved("progress")
        var progress: [String: ProgressItem] = [:]
        var progressRemoved = m.removed["progress"] ?? [:]
        for (k, v) in serverProgressRemoved { progressRemoved[k] = max(progressRemoved[k] ?? 0, v) }
        for (k, e) in local.progress {
            // build 97: een apparaatklok die voorloopt mag niet altijd winnen
            progress[k] = ProgressItem(at: trusted(e.updated.timeIntervalSince1970), entry: e, raw: Self.progressRaw(e))
        }
        for (k, s) in serverProgress where s.at > (progress[k]?.at ?? -1) {
            var s = s
            if let l = progress[k] { for (rk, rv) in l.raw where s.raw[rk] == nil { s.raw[rk] = rv } }
            progress[k] = s
        }
        for (k, at) in progressRemoved {
            if let p = progress[k], p.at >= at { progressRemoved[k] = nil } else { progress[k] = nil }
        }
        if progress.count > 300 {
            let keep = progress.sorted { $0.value.at > $1.value.at }.prefix(250)
            progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        removed["progress"] = Self.pruned(progressRemoved)

        // geschiedenis: samenvoegen op id, nieuwste eerst, max. 500
        var serverHistory: [String: HistoryItem] = [:]
        for e in data["history"] as? [Any] ?? [] {
            guard let j = e as? [String: Any], let h = Self.historyItem(j, profile: id, fallbackAt: sectionAt) else { continue }
            if let old = serverHistory[h.entry.id], old.at >= h.at { continue }
            serverHistory[h.entry.id] = h
        }
        var history: [String: HistoryItem] = [:]
        for e in local.history where (history[e.id]?.at ?? -1) < trusted(e.date.timeIntervalSince1970) {
            history[e.id] = HistoryItem(at: trusted(e.date.timeIntervalSince1970), entry: e, raw: Self.historyRaw(e))
        }
        for (k, h) in serverHistory where h.at > (history[k]?.at ?? -1) { history[k] = h }
        var historyRemoved = m.removed["history"] ?? [:]
        // ook in de vorm van deze app (server-id met hoofdletters), zodat een verwijdering van web/Samsung TV hier telt
        for (k, v) in serverRemoved("history") {
            for kk in Set([k, Self.historyKey(k)]) { historyRemoved[kk] = max(historyRemoved[kk] ?? 0, v) }
        }
        for (k, at) in historyRemoved {
            if let h = history[k], h.at > at { historyRemoved[k] = nil } else { history[k] = nil }
        }
        let historySorted = history.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.entry.id < $1.entry.id }
            .prefix(Self.maxHistory)
        removed["history"] = Self.pruned(historyRemoved)

        // kijkvoorkeuren en pincode: het geheel met de nieuwste updatedAt wint
        var prefsOut = Self.prefs(of: profile)
        var prefsAt = m.prefs.at
        if let sp = data["prefs"] as? [String: Any] {
            let spAt = Self.time(sp["updatedAt"]) ?? sectionAt
            if prefsAt == nil || spAt > prefsAt! {
                store.setSyncedPreferences(id) { p in
                    if sp.keys.contains("autoSubtitles") {
                        if (sp["autoSubtitles"] as? Bool) == false {
                            // build 91: oud `false` in `prefs` = niet ingesteld (docs/ACCOUNT.md), niet "wanneer nodig"
                            p.subtitleMode = nil; p.autoSubtitles = nil
                        } else {
                            p.subtitleMode = TrackPreferences.mode(fromSynced: sp["autoSubtitles"])?.rawValue
                            if p.subtitleMode == nil { p.autoSubtitles = nil }
                        }
                    }
                    if sp.keys.contains("subtitleLanguage") { p.subtitleLanguage = sp["subtitleLanguage"] as? String }
                    if sp.keys.contains("audioLanguage") { p.audioLanguage = sp["audioLanguage"] as? String }
                    if sp.keys.contains("streamSubtitleLanguage") { p.streamSubtitleLanguage = sp["streamSubtitleLanguage"] as? String }
                }
                if let p = store.profiles.first(where: { $0.id == id }) { prefsOut = Self.prefs(of: p) }
                prefsAt = spAt
            }
            for (k, v) in sp where prefsOut[k] == nil && k != "updatedAt" { prefsOut[k] = v }
        }
        m.prefs = Stamp(fp: Self.fingerprint(Self.prefs(of: store.profiles.first { $0.id == id } ?? profile)), at: prefsAt)

        let pinKey = ParentalControl.pinKey(for: id)
        var pin = Keychain.get(pinKey)
        var pinAt = m.pin.at
        // build 146: `pin`, `pinHash` en `pinUpdatedAt` zijn één geheel; een geldige hash gaat voor, een `pin` als tekst
        // (oude app) wordt meteen gehasht met dezelfde `pinUpdatedAt` (docs/ACCOUNT.md "Pincode als hash")
        let serverPin = PinState.read(data, sectionAt: sectionAt, time: { Self.time($0) })
        do {
            let hasPin = serverPin != .absent
            // `pin: null` zonder eigen tijd telt als heel oud (anders verdwijnt een lokale pincode bij de eerste sync)
            let spAt = serverPin.at ?? 0
            let spPresent: Bool
            switch serverPin {
            case .hash, .legacy: spPresent = true
            case .removed, .absent: spPresent = false
            }
            let take: Bool
            if let mine = pinAt {
                take = hasPin && spAt > mine
            } else if hasPin && (spPresent || spAt > 0) {
                take = true   // eerste keer: de server weet het (of de pincode is elders bewust verwijderd)
            } else {
                take = false
                if pin != nil { pinAt = trustedNow() }   // migratie: lokale pincode naar de server
            }
            if take {
                // pas hier afleiden (PBKDF2), alleen als de pincode van de server overgenomen wordt
                let sp: String?
                switch serverPin {
                case .hash(let h, _): sp = h.string
                case .legacy(let plain, _):
                    // dezelfde pincode die hier al als hash staat: die hash houden (geen nieuwe salt bij elke ronde)
                    if let mine = pin, pinMatches(mine, plain) { sp = PinHash.isLegacyPlain(mine) ? makePin(plain) : mine }
                    else { sp = makePin(plain) }
                case .removed, .absent: sp = nil
                }
                if sp != pin {
                    Keychain.set(sp, for: pinKey)
                    ParentalControl.shared.objectWillChange.send()
                }
                pin = sp
                pinAt = spAt
            }
        }
        m.pin = Stamp(fp: Self.hash(pin ?? ""), at: pinAt)

        // startscherm: het geheel met de nieuwste updatedAt wint
        var layoutOut: [String: Any]?
        let localLayout = store.homeLayout(for: id)
        if let sj = data["homeLayout"] as? [String: Any], let sl = Self.homeLayout(sj) {
            if let l = localLayout, l.updatedAt > sl.updatedAt {
                layoutOut = Self.homeLayoutJSON(l, extras: sj)
            } else if localLayout != sl {
                store.setSyncedHomeLayout(id, sl)
            }
        } else if let l = localLayout, !l.rows.isEmpty {
            layoutOut = Self.homeLayoutJSON(l, extras: [:])
        }

        // lokaal toepassen
        var newData = CloudStore.ProfileData()
        newData.myList = Set((sets["myList"] ?? [:]).keys)
        newData.favorites = Set((sets["favorites"] ?? [:]).keys)
        newData.watched = Set((sets["watched"] ?? [:]).keys)
        newData.hiddenCategories = Set((sets["hiddenCategories"] ?? [:]).keys)
        newData.recentChannels = recentOrdered.map(\.key)
        newData.history = historySorted.map(\.entry)
        newData.progress = progress.mapValues(\.entry)
        store.setProfileData(id, newData)

        for name in Self.setLists + ["recentChannels"] { m.present[name] = sets[name] }
        m.present["progress"] = progress.mapValues(\.at)
        m.present["history"] = Dictionary(historySorted.map { ($0.entry.id, $0.at) }, uniquingKeysWith: { a, b in max(a, b) })
        for (k, v) in removed { m.removed[k] = v }
        m.seeded = true
        meta.profiles[id.uuidString] = m

        // payload, en dezelfde vorm voor wat de server had: alleen uploaden als het verschilt
        let mine: [String: Any] = profilePayload(
            sets: sets, removed: removed,
            progress: progress.mapValues { $0.raw.merging(["updatedAt": Self.iso($0.at)]) { _, b in b } },
            history: historySorted.map { $0.raw.merging(["at": Self.iso($0.at), "date": Self.iso($0.at)]) { _, b in b } },
            prefs: prefsOut, prefsAt: prefsAt, pin: pin, pinAt: pinAt, homeLayout: layoutOut, extras: data)
        guard remote != nil else {
            let empty = sets.values.allSatisfy(\.isEmpty) && progress.isEmpty && history.isEmpty && pin == nil
                && removed.values.allSatisfy(\.isEmpty) && prefsAt == nil && layoutOut == nil
            return empty ? nil : mine
        }
        var theirSets: [String: [String: Double]] = [:]
        var theirRemoved: [String: [String: Double]] = [:]
        for (name, s) in serverSets {
            let merged = Self.mergeSet(local: ([:], [:]), server: s)
            theirSets[name] = merged.present
            theirRemoved[name] = Self.pruned(merged.removed)
        }
        if let r = theirSets["recentChannels"] {
            let top = r.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(Self.maxRecent)
            theirSets["recentChannels"] = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
        }
        theirRemoved["progress"] = Self.pruned(serverProgressRemoved)
        theirRemoved["history"] = Self.pruned(serverRemoved("history"))
        let sp = data["prefs"] as? [String: Any]
        let theirs: [String: Any] = profilePayload(
            sets: theirSets, removed: theirRemoved,
            progress: serverProgress.mapValues { $0.raw.merging(["updatedAt": Self.iso($0.at)]) { _, b in b } },
            history: serverHistory.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.entry.id < $1.entry.id }
                .prefix(Self.maxHistory).map { $0.raw.merging(["at": Self.iso($0.at), "date": Self.iso($0.at)]) { _, b in b } },
            prefs: sp.map { $0.filter { $0.key != "updatedAt" } } ?? [:],
            prefsAt: sp.map { Self.time($0["updatedAt"]) ?? sectionAt },
            pin: Self.theirPin(serverPin), pinAt: serverPin.at, serverLegacyPin: Self.legacyPin(serverPin),
            extras: data)
        // staan er verwijderingen alleen in de oude velden (iOS vóór build 60), upload dan ook zonder
        // verdere wijziging, zodat Android en Tizen ze in `removed` zien
        let legacyOnly = ["progress", "history"].contains { name in
            !(removed[name] ?? [:]).isEmpty && removedAll[name] == nil
        }
        if !legacyOnly && Self.same(Self.withoutUpdatedAt(mine), Self.withoutUpdatedAt(theirs)) { return nil }
        return mine
    }

    private func profilePayload(sets: [String: [String: Double]], removed: [String: [String: Double]],
                                progress: [String: [String: Any]], history: [[String: Any]],
                                prefs: [String: Any], prefsAt: Double?, pin: String?, pinAt: Double?,
                                serverLegacyPin: String? = nil,
                                homeLayout: [String: Any]? = nil, extras: [String: Any]) -> [String: Any] {
        var out = extras
        if let homeLayout { out["homeLayout"] = homeLayout }
        // verwijderingen per contract (build 60) in `removed.<veld>`; onbekende sleutels blijven staan en
        // `removed` wordt nooit weggehaald (Android en Tizen lezen voor progress en history alleen deze vorm)
        var removedOut = extras["removed"] as? [String: Any] ?? [:]
        for name in Self.setLists + ["recentChannels", "progress", "history"] {
            removedOut[name] = (removed[name] ?? [:]).mapValues { Self.iso($0) }
        }
        out["removed"] = removedOut
        for name in Self.setLists + ["recentChannels"] {
            let present = sets[name] ?? [:]
            let gone = removed[name] ?? [:]
            let presentSorted = name == "recentChannels"
                ? present.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                : present.sorted { $0.key < $1.key }
            var items: [[String: Any]] = presentSorted.map { e -> [String: Any] in ["id": e.key, "at": Self.iso(e.value)] }
            items += gone.sorted { $0.key < $1.key }.map { e -> [String: Any] in
                ["id": e.key, "removed": true, "at": Self.iso(e.value)]
            }
            out[name] = items
            out[name + "Removed"] = nil
        }
        out["progress"] = progress
        out["history"] = history
        // de oudere velden blijven ook gevuld, voor iOS-apps van vóór build 60
        out["progressRemoved"] = (removed["progress"] ?? [:]).mapValues { Self.iso($0) }
        out["historyRemoved"] = (removed["history"] ?? [:]).mapValues { Self.iso($0) }
        var p = prefs
        p["updatedAt"] = Self.iso(prefsAt ?? 0)
        out["prefs"] = p
        // build 146: alleen de hash (`pinHash`), `pin` altijd null; een oude lokale pincode wordt hier alsnog gehasht
        let hashed: PinHash? = pin.flatMap { p in
            PinHash(string: p) ?? (PinHash.isLegacyPlain(p) ? (pinMade[p].flatMap(PinHash.init(string:)) ?? PinHash.make(pin: p)) : nil)
        }
        out["pinHash"] = hashed.map { $0.json as Any } ?? NSNull()
        // (alleen bij de vergelijkingsvorm van de server: een oude leesbare pincode, zodat er altijd geüpload wordt)
        out["pin"] = serverLegacyPin.map { $0 as Any } ?? NSNull()
        out["pinUpdatedAt"] = Self.iso(pinAt ?? 0)
        out["updatedAt"] = Self.iso(trustedNow())
        return out
    }

    private static func progressRaw(_ e: ProgressEntry) -> [String: Any] {
        var j: [String: Any] = ["position": e.position, "fraction": e.fraction, "title": e.title,
                                "updatedAt": iso(e.updated.timeIntervalSince1970)]
        j["duration"] = e.fraction > 0 ? (e.position / e.fraction).rounded() : 0
        j["artwork"] = Self.orNull(e.artwork?.absoluteString)
        j["playlistID"] = Self.orNull(e.playlistID?.uuidString)
        return j
    }

    private static func progressItem(_ j: [String: Any], profile: UUID) -> ProgressItem? {
        guard let position = (j["position"] as? NSNumber)?.doubleValue,
              let at = time(j["updatedAt"]) ?? time(j["at"]) else { return nil }
        let duration = (j["duration"] as? NSNumber)?.doubleValue ?? 0
        var fraction = (j["fraction"] as? NSNumber)?.doubleValue ?? 0
        if duration > 0 { fraction = min(max(position / duration, 0), 1) }
        let e = ProgressEntry(fraction: fraction, position: position, updated: Date(timeIntervalSince1970: at),
                              title: j["title"] as? String ?? "",
                              artwork: (j["artwork"] as? String).flatMap(URL.init(string:)),
                              playlistID: string(j["playlistID"]).flatMap(UUID.init(uuidString:)),
                              profileID: profile)
        return ProgressItem(at: at, entry: e, raw: j)
    }

    private static func historyRaw(_ e: HistoryEntry) -> [String: Any] {
        var j: [String: Any] = ["id": e.id, "itemID": e.itemID, "title": e.title, "type": e.type.rawValue,
                                "at": iso(e.date.timeIntervalSince1970), "date": iso(e.date.timeIntervalSince1970)]
        j["playlistID"] = Self.orNull(e.playlistID?.uuidString)
        j["subtitle"] = Self.orNull(e.subtitle)
        j["artwork"] = Self.orNull(e.artwork?.absoluteString)
        j["channelID"] = Self.orNull(e.channelID)
        return j
    }

    private static func historyItem(_ j: [String: Any], profile: UUID, fallbackAt: Double) -> HistoryItem? {
        let rawID = string(j["id"])
        var itemID = string(j["itemID"])
        var playlist = string(j["playlistID"]).flatMap(UUID.init(uuidString:))
        if itemID == nil, let rawID, let bar = rawID.firstIndex(of: "|") {
            itemID = String(rawID[rawID.index(after: bar)...])
            playlist = playlist ?? UUID(uuidString: String(rawID[..<bar]))
        }
        guard let itemID, !itemID.isEmpty else { return nil }
        let at = time(j["at"]) ?? time(j["date"]) ?? time(j["time"]) ?? time(j["watchedAt"]) ?? fallbackAt
        let e = HistoryEntry(itemID: itemID, playlistID: playlist, title: j["title"] as? String ?? "",
                             subtitle: j["subtitle"] as? String,
                             artwork: (j["artwork"] as? String).flatMap(URL.init(string:)),
                             type: (j["type"] as? String).flatMap(MediaType.init(rawValue:)) ?? .movie,
                             channelID: j["channelID"] as? String,
                             date: Date(timeIntervalSince1970: at), profileID: profile)
        return HistoryItem(at: at, entry: e, raw: j)
    }

    // MARK: - Lijsten: verschil en samenvoegen

    /// Aanwezig nu tegenover laatst bekend: nieuw → `at` = nu, verdwenen → verwijderd met `at` = nu.
    /// Build 140: een bekende verwijdering met een even late of latere tijd (klok van een ander apparaat loopt voor)
    /// overstemt een toevoeging hier niet meer (`ListStamp`, logica in Build140.swift → `ListMerge`).
    private static func diff(_ m: inout ListMeta, _ name: String, _ current: Set<String>, now: Double) {
        let r = ListMerge.diff((m.present[name] ?? [:], m.removed[name] ?? [:]), current: current, now: now)
        m.present[name] = r.present
        m.removed[name] = r.removed
    }

    /// Geordende lijst (nieuwste eerst, bijv. recente zenders): naar voren gehaald telt als nieuw.
    private static func diffOrdered(_ m: inout ListMeta, _ name: String, _ current: [String], now: Double) {
        var present = m.present[name] ?? [:]
        var removed = m.removed[name] ?? [:]
        var next: Double?
        for (i, id) in current.enumerated().reversed() {
            var at = present[id] ?? (now > 0 ? now : Double(current.count - i) / 1000)
            if let n = next, at <= n { at = max(now, n + 0.001) }
            if present[id] == nil, now > 0 { removed[id] = nil }
            present[id] = at
            next = at
        }
        let set = Set(current)
        for id in present.keys where !set.contains(id) {
            present[id] = nil
            removed[id] = now
        }
        m.present[name] = present
        m.removed[name] = removed
    }

    /// Items met een eigen tijd (voortgang, geschiedenis): verdwenen → verwijderd met `at` = nu.
    /// `inferRemovals: false` (voortgang): verdwenen → alleen uit de bekende stand; de verwijdering zelf komt dan van
    /// `progressCleared`, en wat de server nog heeft komt bij het samenvoegen gewoon terug.
    private static func diffTimed(_ m: inout ListMeta, _ name: String, _ current: [String: Double], now: Double,
                                  inferRemovals: Bool = true) {
        var present = m.present[name] ?? [:]
        var removed = m.removed[name] ?? [:]
        for (k, at) in current {
            present[k] = at
            if let r = removed[k], at > r { removed[k] = nil }
        }
        for k in present.keys where current[k] == nil {
            present[k] = nil
            if now > 0 && inferRemovals { removed[k] = now }
        }
        m.present[name] = present
        m.removed[name] = removed
    }

    /// Per item wint de nieuwste `at`; bij gelijke tijd blijft het item staan (`ListMerge`, Build140.swift).
    private static func mergeSet(local: (present: [String: Double], removed: [String: Double]),
                                 server: (present: [String: Double], removed: [String: Double]))
        -> (present: [String: Double], removed: [String: Double]) {
        ListMerge.merge(local: local, server: server)
    }

    /// Lijst van de server: tekst (`"id"`), of objecten `{id, removed?, at}`; ook `{id: at}`.
    private static func decodeSet(_ v: Any?, fallbackAt: Double) -> (present: [String: Double], removed: [String: Double]) {
        var present: [String: Double] = [:]
        var removed: [String: Double] = [:]
        if let arr = v as? [Any] {
            for e in arr {
                if let s = e as? String {
                    present[s] = max(present[s] ?? -1, fallbackAt)
                } else if let j = e as? [String: Any], let id = string(j["id"] ?? j["key"]) {
                    let at = time(j["at"]) ?? time(j["updatedAt"]) ?? fallbackAt
                    if (j["removed"] as? Bool) == true { removed[id] = max(removed[id] ?? -1, at) }
                    else { present[id] = max(present[id] ?? -1, at) }
                }
            }
        } else if let map = v as? [String: Any] {
            for (k, x) in map { present[k] = time(x) ?? fallbackAt }
        }
        return (present, removed)
    }

    /// Verwijderingen ouder dan 90 dagen weg, en hooguit 2000 per lijst.
    private static func pruned(_ r: [String: Double]) -> [String: Double] {
        let cutoff = Date().addingTimeInterval(-removedLifetime).timeIntervalSince1970
        var out = r.filter { $0.value >= cutoff }
        if out.count > maxRemoved {
            out = Dictionary(uniqueKeysWithValues: out.sorted { $0.value > $1.value }.prefix(maxRemoved).map { ($0.key, $0.value) })
        }
        return out
    }

    // MARK: - Hulpjes

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// ISO-8601 of een getal (seconden of milliseconden sinds 1970) → seconden sinds 1970.
    private static func time(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d > 100_000_000_000 ? d / 1000 : d
        }
        if let s = v as? String, !s.isEmpty {
            if let d = ProfileSync.date(s) { return d.timeIntervalSince1970 }
            if let d = Double(s) { return d > 100_000_000_000 ? d / 1000 : d }
        }
        return nil
    }

    private static func timeMap(_ v: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, x) in v as? [String: Any] ?? [:] { if let t = time(x) { out[k] = t } }
        return out
    }

    private static func iso(_ t: Double) -> String { FastISO.string(t) }   // build 149

    private static func canonical(_ v: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([v]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys])
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(_ v: Any) -> String {
        guard let d = canonical(v) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        guard let x = canonical(a), let y = canonical(b) else { return false }
        return x == y
    }

    /// Optionele waarde → de waarde of JSON-null.
    private static func orNull(_ v: Any?) -> Any { v ?? NSNull() }

    /// Build 146: de pincode van de server in dezelfde vorm als de lokale (hash als tekst) om te vergelijken; een oude
    /// `pin` als tekst blijft tekst, zodat de app na het hashen altijd uploadt.
    private static func theirPin(_ s: PinState) -> String? {
        if case .hash(let h, _) = s { return h.string }
        return nil
    }

    private static func legacyPin(_ s: PinState) -> String? {
        if case .legacy(let plain, _) = s { return plain }
        return nil
    }

    private static func withoutUpdatedAt(_ d: [String: Any]) -> [String: Any] {
        var d = d
        d["updatedAt"] = nil
        return d
    }
}

/// build 97: wachten op een gedeelde sync-ronde (`Task`) die meerdere aanroepers delen. Wordt de wachter
/// geannuleerd, dan stopt alleen het wachten; de ronde zelf loopt door (die wordt alleen bij uitloggen of een
/// accountwissel bewust geannuleerd).
enum SharedRound {
    /// Eén keer hervatten, wat er ook eerst gebeurt: de ronde is klaar of de wachter is geannuleerd.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var continuation: CheckedContinuation<Void, Never>?

        func set(_ c: CheckedContinuation<Void, Never>) {
            lock.lock()
            if done { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }

        func resume() {
            lock.lock()
            done = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    static func wait(_ round: Task<Void, Never>) async {
        let once = Once()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                once.set(c)
                Task.detached {
                    await round.value
                    once.resume()
                }
            }
        } onCancel: {
            once.resume()
        }
    }
}
