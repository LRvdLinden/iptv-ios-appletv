import Foundation
import Security

/// Wachtwoorden, tokens, pincodes en app-sleutels: **lokale opslag in de sandbox van de app** (build 144).
///
/// Build 144 (besluit: alles synchroniseren via het Bingr-account): de naam `Keychain` is gebleven zodat de rest van de
/// app niet verandert, maar er wordt **niets meer in de sleutelhanger of iCloud** gezet of bij het starten gelezen. Alles
/// staat in één bestand in Application Support (op Apple TV Caches als Application Support niet bruikbaar is), versleuteld
/// door het systeem (bestandsbescherming tot de eerste ontgrendeling, zodat ook achtergrondtaken, zoals het vernieuwen
/// van de sessie, kunnen schrijven). Synchroniseren tussen apparaten gaat via de Bingr-account (servers, pincodes,
/// Trakt, OpenSubtitles: StateSync/SourceSync, docs/ACCOUNT.md); zonder account blijft alles op dit apparaat.
///
/// - `get`/`set`: gegevens die de account-sync ook kent (tot build 143 iCloud-sleutelhanger).
/// - `getLocalOnly`/`setLocalOnly`: alleen dit apparaat (sessie, apparaat-id, pincode-teller).
///
/// **Eenmalige overzetting** (`migrateIfNeeded`): op de achtergrond, ná het eerste beeld, met een time-out: wat er nog in
/// de sleutelhanger (synchroniseerbaar, oud lokaal, alleen dit apparaat) of in de oude iCloud KV-spiegel staat, gaat
/// naar dit bestand; daarna wordt het uit de sleutelhanger gehaald. Elke fout wordt stil opgevangen; lukt het niet (bijv.
/// op Apple TV), dan komen de gegevens na het inloggen via de account terug. De sync wacht hooguit 10 s op de overzetting.
enum Keychain {
    // MARK: opslag (bestand)

    private struct Store: Codable {
        var shared: [String: String] = [:]
        var device: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var store: Store?
    private static let writeQueue = DispatchQueue(label: "nl.lrvdlinden.bingr.secrets", qos: .utility)

    private static var fileURL: URL { AppDirs.support.appendingPathComponent("secrets.v144.json") }

    /// Bestand inlezen (één keer). Nooit de sleutelhanger.
    private static func loaded() -> Store {
        if let s = store { return s }
        var s = Store()
        if let d = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Store.self, from: d) { s = decoded }
        store = s
        return s
    }

    private static func update(_ change: (inout Store) -> Void) {
        lock.lock()
        var s = loaded()
        change(&s)
        store = s
        lock.unlock()
        persist(s)
    }

    private static func persist(_ s: Store) {
        let url = fileURL
        writeQueue.async {
            guard let d = try? JSONEncoder().encode(s) else { return }
            #if os(macOS)
            try? d.write(to: url, options: .atomic)
            #else
            try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
        }
    }

    // MARK: openbaar

    static func set(_ value: String?, for key: String) {
        update { s in
            if let value, !value.isEmpty { s.shared[key] = value } else { s.shared[key] = nil }
        }
        // StateSync volgt o.a. Trakt, OpenSubtitles en pincodes (zie "Alle overige gegevens via het account")
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": key]) }
    }

    /// Een geheim is op dit apparaat gezet of verwijderd (`userInfo["key"]`).
    static let didChange = Notification.Name("bingr.keychain.didChange")

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loaded().shared[key]
    }

    static func setLocalOnly(_ value: String?, for key: String) {
        update { s in
            if let value, !value.isEmpty { s.device[key] = value } else { s.device[key] = nil }
        }
    }

    static func getLocalOnly(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loaded().device[key]
    }

    /// Alle sleutels met dit voorvoegsel die een waarde hebben (bijv. `playlist.<id>.`).
    static func keys(withPrefix prefix: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loaded().shared.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    static func setCodable<T: Encodable>(_ value: T?, for key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else { set(nil, for: key); return }
        set(String(data: data, encoding: .utf8), for: key)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let s = get(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// Bestand alvast inlezen (geen sleutelhanger). Altijd gelukt.
    @discardableResult
    static func warmUp() -> Bool {
        lock.lock(); _ = loaded(); lock.unlock()
        return true
    }

    /// Niets meer van buiten (geen sleutelhanger/iCloud): niets opnieuw te lezen.
    static func revalidate() {}
    static func prefetch(_ keys: [String], localOnly: [String] = []) { warmUp() }

    // MARK: eenmalige overzetting uit de sleutelhanger en iCloud (build 144)

    private static let migratedKey = "secrets.migrated.v144"
    private static let migrationDone = DispatchSemaphore(value: 0)
    private static var migrationStarted = false
    private static var migrationFinished = false
    /// false = de oude sleutelhanger kon niet gelezen worden (dan is de account de bron: zie `waitForMigration`)
    private(set) static var migrationSucceeded = true

    /// Op de achtergrond, ná het eerste beeld (RootView). Meer dan eens aanroepen kan geen kwaad.
    static func migrateIfNeeded() {
        lock.lock()
        if migrationStarted { lock.unlock(); return }
        migrationStarted = true
        lock.unlock()
        if UserDefaults.standard.bool(forKey: migratedKey) { finishMigration(changed: []); return }
        let t = Thread {
            let r = LegacySecrets.importAll()
            lock.lock(); migrationSucceeded = r.ok; lock.unlock()
            finishMigration(changed: r.changed)
        }
        t.name = "bingr.secrets.migrate"
        t.qualityOfService = .utility
        t.start()
    }

    private static func finishMigration(changed: [String]) {
        lock.lock(); migrationFinished = true; lock.unlock()
        migrationDone.signal()
        guard !changed.isEmpty else { return }
        Task { @MainActor in
            for k in changed { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": k]) }
            Secrets.reload()
            CloudStore.shared.secretsMigrated()
        }
    }

    /// Wachten tot de overzetting klaar is (hooguit `timeout` seconden), bijv. vóór de eerste account-sync, zodat die
    /// geen lege waarden voor nieuw aanziet.
    static func waitForMigration(timeout: TimeInterval = 10) async {
        migrateIfNeeded()   // (start hem als dat nog niet gebeurd is; meestal al na het eerste beeld)
        lock.lock(); let done = migrationFinished; lock.unlock()
        if done { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                if migrationDone.wait(timeout: .now() + timeout) == .success { migrationDone.signal() }
                c.resume()
            }
        }
    }

    /// Build 144: vóór elke account-sync. Wacht op de overzetting; lukte die niet (oude sleutelhanger onleesbaar, bijv. op
    /// Apple TV), dan één keer de lokale sync-stand vergeten, zodat de account de bron is (zoals een nieuw apparaat) en
    /// lege lokale waarden nooit als "verwijderd" naar de server gaan.
    @MainActor static func settleBeforeSync() async {
        await waitForMigration()
        lock.lock(); let failed = !migrationSucceeded || !migrationFinished; let first = !settledReset; settledReset = true; lock.unlock()
        guard failed, first else { return }
        StateSync.shared.forgetLocalStamps()
        SourceSync.shared.forgetLocalStamps()
    }
    private static var settledReset = false

    /// Door de overzetting: alleen invullen wat hier nog ontbreekt (nieuwer lokaal gaat voor).
    fileprivate static func importValues(shared: [String: String], device: [String: String]) -> [String] {
        var changed: [String] = []
        update { s in
            for (k, v) in shared where !v.isEmpty && s.shared[k] == nil { s.shared[k] = v; changed.append(k) }
            for (k, v) in device where !v.isEmpty && s.device[k] == nil { s.device[k] = v }
        }
        return changed
    }

    fileprivate static func markMigrated() { UserDefaults.standard.set(true, forKey: migratedKey) }
}

/// Build 144: de oude opslag (tot build 143): iCloud-sleutelhanger (service `nl.lrvdlinden.bingr`, synchroniseerbaar en
/// oud lokaal), alleen-dit-apparaat (service `nl.lrvdlinden.bingr.device`) en de oude iCloud KV-spiegel `secrets.v1`.
/// Alleen gebruikt door de eenmalige overzetting, op een achtergrondthread; elke fout = overslaan.
private enum LegacySecrets {
    static let service = "nl.lrvdlinden.bingr"
    static let deviceService = "nl.lrvdlinden.bingr.device"

    static func importAll() -> (changed: [String], ok: Bool) {
        let started = Date()
        var shared: [String: String] = [:]
        var device: [String: String] = [:]
        var readOK = true
        // oud lokaal eerst, synchroniseerbaar gaat voor (zoals vroeger `read`)
        if let legacy = all(service, sync: kCFBooleanFalse as Any) { shared.merge(legacy) { a, _ in a } } else { readOK = false }
        if let synced = all(service, sync: kCFBooleanTrue as Any) { for (k, v) in synced { shared[k] = v } } else { readOK = false }
        if let d = all(deviceService, sync: kSecAttrSynchronizableAny) { device = d } else { readOK = false }
        // oude iCloud KV-spiegel (build ≤ 96)
        if Date().timeIntervalSince(started) < 8,
           let mirror = NSUbiquitousKeyValueStore.default.dictionary(forKey: "secrets.v1") as? [String: String] {
            for (k, v) in mirror where shared[k] == nil && !v.isEmpty { shared[k] = v }
        }
        let changed = Keychain.importValues(shared: shared, device: device)
        // pas als alles gelezen is: de oude items opruimen (geen nieuwe start vindt ze dan nog)
        if readOK {
            Keychain.markMigrated()
            var deletes = [base(service, sync: kSecAttrSynchronizableAny), base(deviceService, sync: kSecAttrSynchronizableAny)]
            #if os(macOS)
            for var q in deletes { q[kSecUseDataProtectionKeychain as String] = true; deletes.append(q) }
            #endif
            for q in deletes { _ = SecItemDelete(q as CFDictionary) }
        }
        return (changed, readOK)
    }

    /// Mac: synchroniseerbare items stonden in de data-protection-sleutelhanger, de rest in de gewone
    private static func base(_ service: String, sync: Any) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: sync]
        #if os(macOS)
        if (sync as? Bool) == true { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    /// Alle items van een service (sleutel → waarde); nil = lezen mislukt, [:] = niets gevonden.
    private static func all(_ service: String, sync: Any) -> [String: String]? {
        var q = base(service, sync: sync)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var res: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &res)
        if st == errSecItemNotFound { return [:] }
        if st == errSecSuccess, let items = res as? [[String: Any]] {
            var out: [String: String] = [:]
            for i in items {
                guard let a = i[kSecAttrAccount as String] as? String, let d = i[kSecValueData as String] as? Data,
                      let v = String(data: d, encoding: .utf8), !v.isEmpty else { continue }
                if out[a] == nil { out[a] = v }
            }
            return out
        }
        // sommige systemen staan data + alle treffers niet toe: dan per sleutel
        var q2 = base(service, sync: sync)
        q2[kSecReturnAttributes as String] = true
        q2[kSecMatchLimit as String] = kSecMatchLimitAll
        var res2: AnyObject?
        guard SecItemCopyMatching(q2 as CFDictionary, &res2) == errSecSuccess, let items = res2 as? [[String: Any]] else { return nil }
        var out: [String: String] = [:]
        for i in items {
            guard let a = i[kSecAttrAccount as String] as? String else { continue }
            var one = base(service, sync: sync)
            one[kSecAttrAccount as String] = a
            one[kSecReturnData as String] = true
            one[kSecMatchLimit as String] = kSecMatchLimitOne
            var r: AnyObject?
            if SecItemCopyMatching(one as CFDictionary, &r) == errSecSuccess, let d = r as? Data,
               let v = String(data: d, encoding: .utf8), !v.isEmpty { out[a] = v }
        }
        return out
    }
}
