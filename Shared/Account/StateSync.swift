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
/// - `reminders`: herinneringen.
/// - `collections`: eigen collecties (build 51), per item wint de nieuwste `updatedAt`; in `profile.<id>` ook `homeLayout`.
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
    private static let setLists = ["myList", "favorites", "watched"]

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
            await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
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
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
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

    /// Afspelen gestopt: de voortgang meteen uploaden.
    func playbackStopped() {
        let store = CloudStore.shared
        guard let id = store.activeProfileID ?? store.mainProfileID else { return }
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
        if let s = switchTask { await s.value }
        let store = CloudStore.shared

        // eigen wijzigingen sinds de vorige keer vastleggen
        _ = noteSettings()
        _ = noteConnections()
        noteReminders()
        for p in store.profiles { noteProfile(p.id) }
        saveMeta()

        let server: [String: (data: Any, updatedAt: String?)]
        do { server = try await account.getState(sections: sections.map { Array($0).sorted() }) } catch { return }
        guard !Task.isCancelled, account.isSignedIn else { return }
        func wants(_ s: String) -> Bool { sections?.contains(s) ?? true }

        var uploads: [(String, [String: Any])] = []
        if wants("connections"), let u = await mergeConnections(server["connections"]) { uploads.append(("connections", u)) }
        if wants("settings"), let u = mergeSettings(server["settings"]) { uploads.append(("settings", u)) }
        if wants("reminders"), let u = mergeReminders(server["reminders"]) { uploads.append(("reminders", u)) }
        if wants("collections"), let u = mergeCollections(server["collections"]) { uploads.append(("collections", u)) }
        let tombs = ProfileSync.shared.tombstonedIDs
        for p in store.profiles where !tombs.contains(p.id) {
            let name = profileSection(p.id)
            guard wants(name) else { continue }
            if let u = mergeProfile(p.id, server[name]) { uploads.append((name, u)) }
        }
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

        for (name, data) in uploads {
            guard account.isSignedIn, !Task.isCancelled else { return }
            _ = try? await account.putState(section: name, data: data)
        }
        for name in deletes {
            guard account.isSignedIn, !Task.isCancelled else { return }
            try? await account.deleteState(section: name)
        }
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
        let at: Double? = (meta.connectionsSeeded || force) ? Date().timeIntervalSince1970 : meta.connections.at
        meta.connections = Stamp(fp: fp, at: at)
        return true
    }

    private func mergeConnections(_ remote: (data: Any, updatedAt: String?)?) async -> [String: Any]? {
        let local = localConnections()
        let hasLocal = !(local["trakt"] is NSNull) || !(local["opensubtitles"] is NSNull)
        guard let remote, let data = remote.data as? [String: Any] else {
            // migratie: server leeg en lokaal een koppeling → uploaden
            guard hasLocal else { return nil }
            let at = meta.connections.at ?? Date().timeIntervalSince1970
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
            resultAt = keptLocal ? Date().timeIntervalSince1970 : serverAt
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
        shared["subtitleLanguage"] = pref(main?.streamSubtitleLanguage, TrackPreferences.subtitle)
        shared["autoSubtitles"] = pref(main?.autoSubtitles, d.bool(forKey: "autoSubtitles"))
        shared["openSubtitlesLanguage"] = pref(main?.subtitleLanguage, OpenSubtitles.shared.defaultLanguage)
        shared["openSubtitlesLanguages"] = OpenSubtitles.shared.preferredLanguages
        let tab = d.integer(forKey: "ui.startTab")
        shared["startScreen"] = Self.tabNames.indices.contains(tab) ? Self.tabNames[tab] : "home"
        var hidden: [String] = []
        if !(d.object(forKey: "ui.showLive") as? Bool ?? true) { hidden.append("live") }
        if !(d.object(forKey: "ui.showMovies") as? Bool ?? true) { hidden.append("movies") }
        if !(d.object(forKey: "ui.showSeries") as? Bool ?? true) { hidden.append("series") }
        shared["hiddenTabs"] = hidden
        shared["introMusic"] = d.object(forKey: "splash.sound") as? Bool ?? true
        shared["refreshInterval"] = RefreshPolicy.current.rawValue
        shared["parentalControl"] = store.parental.enabled
        shared["parentalAutoLockAdult"] = store.parental.autoLockAdult
        shared["traktScrobble"] = TraktSync.scrobbleEnabled
        shared["traktAskRating"] = TraktSync.askRating
        // build 52: uiterlijk, deinterlacing, laatste zender en intro-markeringen (zelfde sleutels als Android)
        shared["accentColor"] = AccentChoice.current.rawValue
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
        guard fp != meta.settings.fp else { return false }
        meta.settings = Stamp(fp: fp, at: meta.settingsSeeded ? Date().timeIntervalSince1970 : meta.settings.at)
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
        let at = localAt ?? Date().timeIntervalSince1970
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
        if let v = shared["introMusic"] as? Bool { setIfChanged(v, "splash.sound") }
        if let v = shared["refreshInterval"] as? String, RefreshPolicy(rawValue: v) != nil { setIfChanged(v, "playlist.refresh") }
        if let p = shared["parentalControl"] as? [String: Any] {
            store.setSyncedParental(enabled: p["enabled"] as? Bool ?? store.parental.enabled,
                                    autoLockAdult: p["autoLockAdult"] as? Bool ?? store.parental.autoLockAdult)
        } else if shared["parentalControl"] is Bool || shared["parentalAutoLockAdult"] is Bool {
            store.setSyncedParental(enabled: shared["parentalControl"] as? Bool ?? store.parental.enabled,
                                    autoLockAdult: shared["parentalAutoLockAdult"] as? Bool ?? store.parental.autoLockAdult)
        }
        if let v = shared["traktScrobble"] as? Bool { setIfChanged(v, "trakt.scrobble") }
        if let v = shared["traktAskRating"] as? Bool { setIfChanged(v, "trakt.askRating") }
        if let v = shared["accentColor"] as? String, AccentChoice(rawValue: v) != nil { setIfChanged(v, AccentChoice.key) }
        if let v = shared["deinterlace"] as? String, DeinterlaceMode(rawValue: v) != nil { setIfChanged(v, DeinterlaceMode.key) }
        if let v = shared["resumeLastChannel"] as? Bool { setIfChanged(v, PlayerSettings.resumeLastChannelKey) }
        if let v = shared["introMarkers"] as? [String: Any] { IntroMarkers.apply(syncJSON: v) }

        // kijkvoorkeuren van het hoofdaccount
        let audio = shared["audioLanguage"] as? String
        let sub = shared["subtitleLanguage"] as? String
        let auto = shared["autoSubtitles"] as? Bool
        let os = shared["openSubtitlesLanguage"] as? String
        if let main = store.mainProfileID, audio != nil || sub != nil || auto != nil || os != nil {
            store.setSyncedPreferences(main) { p in
                if let audio { p.audioLanguage = audio }
                if let sub { p.streamSubtitleLanguage = sub }
                if let auto { p.autoSubtitles = auto }
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
            if let auto { setIfChanged(auto, "autoSubtitles") }
            if let os, os != OpenSubtitles.shared.defaultLanguage { OpenSubtitles.shared.defaultLanguage = os }
        }

        // apple
        if let v = (shared["categorySort"] as? String) ?? (apple["categorySort"] as? String) { setIfChanged(v, "category.sort") }
        if let v = apple["traktOAuthHost"] as? String, v.hasPrefix("https://") { setIfChanged(v, "trakt.oauthHost") }
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
        let now = m.seeded ? Date().timeIntervalSince1970 : 0
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
        let raw = (data["reminders"] ?? data["items"] ?? data["list"]) as? [Any] ?? []
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
            var j = ["id": r.id, "playlistID": r.playlistID.uuidString, "channelID": r.channelID,
                     "channelName": r.channelName, "title": r.title,
                     "start": Self.iso(r.start.timeIntervalSince1970)] as [String: Any]
            j["at"] = Self.iso(present[r.id] ?? 0)
            return j
        }
        let normalizedServer = remindersPayload(
            serverItems.filter { serverPresent[$0.key] != nil && $0.value.start > cutoff }
                .sorted { $0.value.start != $1.value.start ? $0.value.start < $1.value.start : $0.key < $1.key }
                .map { id, r -> [String: Any] in
                    ["id": id, "playlistID": r.playlistID.uuidString, "channelID": r.channelID, "channelName": r.channelName,
                     "title": r.title, "start": Self.iso(r.start.timeIntervalSince1970), "at": Self.iso(serverPresent[id] ?? 0)]
                },
            removed: Self.pruned(serverRemoved), extras: data, at: sectionAt)
        let payload = remindersPayload(items, removed: m.removed["reminders"] ?? [:], extras: data,
                                       at: Date().timeIntervalSince1970)
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
        return ProgramReminder(id: id, playlistID: pl, channelID: channel,
                               channelName: j["channelName"] as? String ?? "", title: j["title"] as? String ?? "",
                               start: Date(timeIntervalSince1970: start))
    }

    // MARK: - collections (build 51)

    /// Onbekende velden per collectie van de server (die gaan onaangeroerd terug)
    private let collectionExtrasKey = "account.collectionExtras.v1"

    private func loadCollectionExtras() -> [String: [String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: collectionExtrasKey),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { return [:] }
        return j
    }

    private func saveCollectionExtras(_ e: [String: [String: Any]]) {
        guard JSONSerialization.isValidJSONObject(e), let d = try? JSONSerialization.data(withJSONObject: e) else { return }
        UserDefaults.standard.set(d, forKey: collectionExtrasKey)
    }

    /// Per item wint de nieuwste `updatedAt` (ook een tombstone). Geeft de data terug als er geüpload moet worden.
    private func mergeCollections(_ remote: (data: Any, updatedAt: String?)?) -> [String: Any]? {
        let store = CloudStore.shared
        let data: [String: Any]
        if let d = remote?.data as? [String: Any] { data = d }
        else if let a = remote?.data as? [Any] { data = ["items": a] }
        else { data = [:] }
        var server: [String: (c: BingrCollection, raw: [String: Any])] = [:]
        for e in data["items"] as? [Any] ?? [] {
            guard let j = e as? [String: Any], let c = Self.collection(j) else { continue }
            if let old = server[c.id], old.c.updatedAt >= c.updatedAt { continue }
            server[c.id] = (c, j)
        }
        var merged: [String: BingrCollection] = [:]
        for c in store.collections { merged[c.id] = c }
        var extras = loadCollectionExtras()
        for (id, s) in server {
            extras[id] = s.raw
            if let l = merged[id], l.updatedAt >= s.c.updatedAt { continue }
            merged[id] = s.c
        }
        // tombstones ouder dan 90 dagen weg
        let cutoff = Date().addingTimeInterval(-Self.removedLifetime)
        merged = merged.filter { !$0.value.deleted || ($0.value.deletedAt ?? $0.value.updatedAt) >= cutoff }
        let list = Self.sortedCollections(Array(merged.values))
        store.replaceCollections(list)
        extras = extras.filter { merged[$0.key] != nil }
        saveCollectionExtras(extras)

        if remote == nil && list.isEmpty { return nil }
        let mine = collectionsPayload(list, extras: extras, section: data)
        if remote != nil {
            let theirs = collectionsPayload(Self.sortedCollections(server.values.map { $0.c }), extras: extras, section: data)
            if Self.same(Self.withoutUpdatedAt(mine), Self.withoutUpdatedAt(theirs)) { return nil }
        }
        return mine
    }

    private static func sortedCollections(_ l: [BingrCollection]) -> [BingrCollection] {
        l.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    private func collectionsPayload(_ list: [BingrCollection], extras: [String: [String: Any]],
                                    section: [String: Any]) -> [String: Any] {
        var out = section
        out["items"] = list.map { Self.collectionJSON($0, extras: extras[$0.id] ?? [:]) }
        out["updatedAt"] = Self.iso(Date().timeIntervalSince1970)
        return out
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
        d["items"] = c.items.map { ["type": $0.type.rawValue, "id": $0.id] }
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
            return CollectionItem(type: t, id: iid)
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
        ["autoSubtitles": p.autoSubtitles.map { $0 as Any } ?? NSNull(),
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
        let now = first ? 0 : Date().timeIntervalSince1970
        let d = store.profileData(id)
        Self.diff(&m, "myList", d.myList, now: now)
        Self.diff(&m, "favorites", d.favorites, now: now)
        Self.diff(&m, "watched", d.watched, now: now)
        Self.diffOrdered(&m, "recentChannels", d.recentChannels, now: now)
        Self.diffTimed(&m, "progress", d.progress.mapValues { $0.updated.timeIntervalSince1970 }, now: now)
        var hist: [String: Double] = [:]
        for e in d.history { hist[e.id] = max(hist[e.id] ?? 0, e.date.timeIntervalSince1970) }
        Self.diffTimed(&m, "history", hist, now: now)
        let pfp = Self.fingerprint(Self.prefs(of: profile))
        if pfp != m.prefs.fp { m.prefs = Stamp(fp: pfp, at: first || m.prefs.fp == nil ? m.prefs.at : now) }
        let pin = Keychain.get(ParentalControl.pinKey(for: id))
        let pinFP = Self.hash(pin ?? "")
        if pinFP != m.pin.fp { m.pin = Stamp(fp: pinFP, at: first || m.pin.fp == nil ? m.pin.at : now) }
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
            progress[k] = ProgressItem(at: e.updated.timeIntervalSince1970, entry: e, raw: Self.progressRaw(e))
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
        for e in local.history where (history[e.id]?.at ?? -1) < e.date.timeIntervalSince1970 {
            history[e.id] = HistoryItem(at: e.date.timeIntervalSince1970, entry: e, raw: Self.historyRaw(e))
        }
        for (k, h) in serverHistory where h.at > (history[k]?.at ?? -1) { history[k] = h }
        var historyRemoved = m.removed["history"] ?? [:]
        for (k, v) in serverRemoved("history") { historyRemoved[k] = max(historyRemoved[k] ?? 0, v) }
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
                    if sp.keys.contains("autoSubtitles") { p.autoSubtitles = sp["autoSubtitles"] as? Bool }
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
        do {
            let hasPin = data.keys.contains("pin")
            let sp = (data["pin"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // `pin: null` zonder eigen tijd telt als heel oud (anders verdwijnt een lokale pincode bij de eerste sync)
            let spAt = hasPin ? (Self.time(data["pinUpdatedAt"]) ?? (sp != nil ? sectionAt : 0)) : 0
            let take: Bool
            if let mine = pinAt {
                take = hasPin && spAt > mine
            } else if hasPin && (sp != nil || spAt > 0) {
                take = true   // eerste keer: de server weet het (of de pincode is elders bewust verwijderd)
            } else {
                take = false
                if pin != nil { pinAt = Date().timeIntervalSince1970 }   // migratie: lokale pincode naar de server
            }
            if take {
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
            history: historySorted.map { $0.raw.merging(["at": Self.iso($0.at)]) { _, b in b } },
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
                .prefix(Self.maxHistory).map { $0.raw.merging(["at": Self.iso($0.at)]) { _, b in b } },
            prefs: sp.map { $0.filter { $0.key != "updatedAt" } } ?? [:],
            prefsAt: sp.map { Self.time($0["updatedAt"]) ?? sectionAt },
            pin: (data["pin"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            pinAt: data.keys.contains("pin")
                ? (Self.time(data["pinUpdatedAt"]) ?? ((data["pin"] as? String).map { $0.isEmpty ? 0 : sectionAt } ?? 0)) : nil,
            extras: data)
        if Self.same(Self.withoutUpdatedAt(mine), Self.withoutUpdatedAt(theirs)) { return nil }
        return mine
    }

    private func profilePayload(sets: [String: [String: Double]], removed: [String: [String: Double]],
                                progress: [String: [String: Any]], history: [[String: Any]],
                                prefs: [String: Any], prefsAt: Double?, pin: String?, pinAt: Double?,
                                homeLayout: [String: Any]? = nil, extras: [String: Any]) -> [String: Any] {
        var out = extras
        if let homeLayout { out["homeLayout"] = homeLayout }
        out["removed"] = nil
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
        out["progressRemoved"] = (removed["progress"] ?? [:]).mapValues { Self.iso($0) }
        out["history"] = history
        out["historyRemoved"] = (removed["history"] ?? [:]).mapValues { Self.iso($0) }
        var p = prefs
        p["updatedAt"] = Self.iso(prefsAt ?? 0)
        out["prefs"] = p
        out["pin"] = Self.orNull(pin)
        out["pinUpdatedAt"] = Self.iso(pinAt ?? 0)
        out["updatedAt"] = Self.iso(Date().timeIntervalSince1970)
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
                                "at": iso(e.date.timeIntervalSince1970)]
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
    private static func diff(_ m: inout ListMeta, _ name: String, _ current: Set<String>, now: Double) {
        var present = m.present[name] ?? [:]
        var removed = m.removed[name] ?? [:]
        for id in current where present[id] == nil {
            present[id] = now
            if now > 0 { removed[id] = nil }
        }
        for id in present.keys where !current.contains(id) {
            present[id] = nil
            removed[id] = now
        }
        m.present[name] = present
        m.removed[name] = removed
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
    private static func diffTimed(_ m: inout ListMeta, _ name: String, _ current: [String: Double], now: Double) {
        var present = m.present[name] ?? [:]
        var removed = m.removed[name] ?? [:]
        for (k, at) in current {
            present[k] = at
            if let r = removed[k], at > r { removed[k] = nil }
        }
        for k in present.keys where current[k] == nil {
            present[k] = nil
            if now > 0 { removed[k] = now }
        }
        m.present[name] = present
        m.removed[name] = removed
    }

    /// Per item wint de nieuwste `at`; bij gelijke tijd blijft het item staan.
    private static func mergeSet(local: (present: [String: Double], removed: [String: Double]),
                                 server: (present: [String: Double], removed: [String: Double]))
        -> (present: [String: Double], removed: [String: Double]) {
        var present: [String: Double] = [:]
        var removed: [String: Double] = [:]
        let ids = Set(local.present.keys).union(local.removed.keys).union(server.present.keys).union(server.removed.keys)
        for id in ids {
            let p = max(local.present[id] ?? -1, server.present[id] ?? -1)
            let r = max(local.removed[id] ?? -1, server.removed[id] ?? -1)
            if p >= 0 && p >= r { present[id] = p } else if r >= 0 { removed[id] = r }
        }
        return (present, removed)
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

    private static func iso(_ t: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

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

    private static func withoutUpdatedAt(_ d: [String: Any]) -> [String: Any] {
        var d = d
        d["updatedAt"] = nil
        return d
    }
}
