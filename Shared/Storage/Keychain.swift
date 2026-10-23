import Foundation
import Security

/// Wachtwoorden, tokens en app-sleutels.
///
/// build 97: alleen in de sleutelhanger, als synchroniseerbaar item (iCloud-sleutelhanger, end-to-end versleuteld),
/// zodat iPhone, iPad, Apple TV en Mac ze delen. Ze staan niet meer onversleuteld in de iCloud Key-Value Store
/// (`secrets.v1`): wat daar nog staat, wordt bij het starten (en na een iCloud-wijziging van een oudere versie)
/// naar de sleutelhanger overgezet en daarna uit de Key-Value Store verwijderd (`migrateFromCloud`).
///
/// build 97: alle lees- en schrijfacties lopen via één seriële wachtrij, zodat de hoofdthread en de achtergrond
/// elkaar niet in de weg zitten (verwijderen + toevoegen is anders niet atomair).
enum Keychain {
    private static let service = "nl.lrvdlinden.bingr"
    /// build 97: oude spiegel in iCloud KV (alleen nog lezen om over te zetten, daarna weg)
    private static let cloudKey = "secrets.v1"
    private static var kv: NSUbiquitousKeyValueStore { .default }

    // MARK: seriële wachtrij (build 97)

    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "nl.lrvdlinden.bingr.keychain", qos: .userInitiated)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()

    /// build 97: werk op de wachtrij; al op de wachtrij (geneste aanroep) → direct, anders een deadlock
    private static func serial<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        #if DEBUG || BINGR_SMOKE
        // start-rooktest: een trage sleutelhanger nabootsen (op een echte Apple TV/iPhone duurt elke aanroep veel
        // langer dan in de simulator) en tellen hoe vaak de hoofdthread erop wacht
        SmokeTest.keychainCall()
        #endif
        return queue.sync(execute: work)
    }

    /// Build 143: schrijven zonder te wachten (het geheugen is al bijgewerkt); de wachtrij houdt de volgorde, en een
    /// latere leesactie op de wachtrij komt pas na dit schrijven.
    private static func serialAsync(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { work(); return }
        queue.async(execute: work)
    }

    // MARK: geheugen (build 143)
    //
    // Build 143: lezen uit het geheugen. Tot nu toe ging elke `get` (2 zoekopdrachten: synchroniseerbaar en oud
    // lokaal) en `getLocalOnly` naar de sleutelhanger, vaak op de hoofdthread: bij het starten (account, sleutels,
    // servers, pincode-teller), voor elke profieltegel in "Wie kijkt er?" (slotje) en bij het kiezen van een beveiligd
    // profiel. Op een echt toestel is de sleutelhanger veel trager dan in de simulator, en de wachtrij is bij het
    // starten bezig met de overzetting en de sync: de app hing dan seconden lang (pincodescherm kwam pas laat) en
    // bij het starten kon de watchdog van het systeem de app stoppen. Nu: één keer lezen, daarna uit het geheugen;
    // schrijven werkt het geheugen bij; `invalidate()` (app weer actief, iCloud-wijziging) leest opnieuw.

    private static let cacheLock = NSLock()
    private static var cache: [String: String?] = [:]
    private static var localCache: [String: String?] = [:]

    /// Alles in één keer gelezen (`warmUp`): een sleutel die niet in het geheugen staat, bestaat dan niet.
    private static var warm = false

    private static func cached(_ key: String, local: Bool) -> String?? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let v = local ? localCache[key] : cache[key] { return v }
        return warm ? .some(nil) : nil
    }

    /// Build 143: alle items van Bingr in drie zoekopdrachten (synchroniseerbaar, oud lokaal, alleen dit apparaat) in het
    /// geheugen, in plaats van één of twee zoekopdrachten per sleutel op de hoofdthread. Bij het starten (vóór CloudStore)
    /// en daarna op de achtergrond als de app weer actief wordt. Lukt een zoekopdracht niet, dan blijft het per sleutel.
    @discardableResult
    static func warmUp() -> Bool {
        func all(_ base: [String: Any]) -> [String: String]? {
            var q = base
            q[kSecReturnAttributes as String] = true
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            var res: AnyObject?
            let st = SecItemCopyMatching(q as CFDictionary, &res)
            if st == errSecItemNotFound { return [:] }
            guard st == errSecSuccess, let items = res as? [[String: Any]] else { return nil }
            var out: [String: String] = [:]
            for i in items {
                guard let a = i[kSecAttrAccount as String] as? String, let d = i[kSecValueData as String] as? Data,
                      let v = String(data: d, encoding: .utf8), !v.isEmpty else { continue }
                if out[a] == nil { out[a] = v }
            }
            return out
        }
        let result: (synced: [String: String]?, legacy: [String: String]?, local: [String: String]?) = serial {
            (all(syncedQuery(nil)), all(legacyQuery(nil)), all(localOnlyQuery))
        }
        guard let synced = result.synced, let legacy = result.legacy, let local = result.local else { return false }
        cacheLock.lock()
        var fresh: [String: String?] = [:]
        for (k, v) in legacy { fresh[k] = v }
        for (k, v) in synced { fresh[k] = v }   // synchroniseerbaar gaat voor (zoals `read`)
        cache = fresh
        localCache = local.mapValues { Optional($0) }
        warm = true
        cacheLock.unlock()
        return true
    }

    private static var localOnlyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: localOnlyService,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    private static func remember(_ key: String, _ value: String?, local: Bool) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if local { localCache[key] = .some(value) } else { cache[key] = .some(value) }
    }

    /// Alles opnieuw uit de sleutelhanger lezen (een ander apparaat kan synchroniseerbare items gewijzigd hebben), op de
    /// achtergrond: tot het klaar is, blijven de bekende waarden gelden (de hoofdthread wacht nooit).
    static func revalidate() {
        cacheLock.lock(); let before = cache; let wasWarm = warm; let keys = Array(cache.keys), locals = Array(localCache.keys); cacheLock.unlock()
        if wasWarm {
            DispatchQueue.global(qos: .utility).async {
                guard warmUp() else { return }
                cacheLock.lock(); let after = cache; cacheLock.unlock()
                let changed = Set(before.keys).union(after.keys).filter { (before[$0] ?? nil) != (after[$0] ?? nil) }
                guard !changed.isEmpty else { return }
                DispatchQueue.main.async {
                    for k in changed { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": k]) }
                }
            }
            return
        }
        guard !keys.isEmpty || !locals.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var changed: [String] = []
            for k in keys {
                let v = serial { read(k) }
                if cached(k, local: false) != .some(v) { remember(k, v, local: false); changed.append(k) }
            }
            for k in locals { remember(k, readLocalOnly(k), local: true) }
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async {
                for k in changed { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": k]) }
            }
        }
    }

    /// Op de achtergrond alvast in het geheugen zetten (bijv. de pincodes van alle profielen).
    static func prefetch(_ keys: [String], localOnly: [String] = []) {
        DispatchQueue.global(qos: .userInitiated).async {
            for k in keys where cached(k, local: false) == nil { _ = get(k) }
            for k in localOnly where cached(k, local: true) == nil { _ = getLocalOnly(k) }
        }
    }

    // MARK: openbaar

    static func set(_ value: String?, for key: String) {
        remember(key, (value?.isEmpty ?? true) ? nil : value, local: false)
        serialAsync {
            if let value, !value.isEmpty { writeSynced(value, for: key) } else { deleteAll(key) }
            // build 97: een oude kopie in iCloud KV mag de wijziging niet later terugzetten
            purgeCloudCopy(key)
        }
        // StateSync volgt o.a. Trakt, OpenSubtitles en pincodes (zie "Alle overige gegevens via het account")
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": key]) }
    }

    /// Een geheim is op dit apparaat gezet of verwijderd (`userInfo["key"]`).
    static let didChange = Notification.Name("bingr.keychain.didChange")

    static func get(_ key: String) -> String? {
        if let c = cached(key, local: false) { return c }
        let v = serial { read(key) }
        remember(key, v, local: false)
        return v
    }

    /// build 97: eenmalige (en herhaalbare) overzetting naar de iCloud-sleutelhanger:
    /// 1. geheimen die nog in iCloud KV staan (oude versie of een ander apparaat met een oude build) naar de
    ///    synchroniseerbare sleutelhanger, als die er hier nog geen waarde voor heeft (de sleutelhanger gaat voor);
    /// 2. oude, alleen-lokale items van eerdere builds omzetten naar synchroniseerbaar;
    /// 3. de spiegel uit iCloud KV verwijderen.
    /// Geeft de sleutels terug die veranderd zijn. Niet op de hoofdthread aanroepen (sleutelhanger is traag).
    /// Build 143: de volledige overzetting één keer per start; daarna alleen nog als er (weer) een oude spiegel in iCloud KV
    /// staat. Liep bij elke iCloud-wijziging en elke keer dat de app actief werd, en hield dan de wachtrij bezet.
    private static var migratedThisLaunch = false
    static func migrateIfNeeded() {
        let first: Bool = { cacheLock.lock(); defer { cacheLock.unlock() }; let f = !migratedThisLaunch; migratedThisLaunch = true; return f }()
        guard first || kv.object(forKey: cloudKey) != nil else { return }
        migrateFromCloud()
    }

    @discardableResult
    static func migrateFromCloud() -> [String] {
        var changed: [String] = []
        let legacy = (kv.dictionary(forKey: cloudKey) as? [String: String]) ?? [:]
        for (k, v) in legacy where !v.isEmpty {
            // per item op de wachtrij, zodat de hoofdthread tussendoor kan lezen
            let did: Bool = serial { () -> Bool in
                guard read(k) == nil else { return false }
                writeSynced(v, for: k)
                return true
            }
            if did { changed.append(k) }
        }
        for k in serial({ localOnlyAccounts() }) {
            serial { () -> Void in
                guard let v = readLegacyLocal(k) else { return }
                if readSynced(k) == nil { writeSynced(v, for: k) }
                deleteLegacyLocal(k)
            }
        }
        if kv.object(forKey: cloudKey) != nil {
            serial { () -> Void in
                kv.removeObject(forKey: cloudKey)
                kv.synchronize()
            }
        }
        if !changed.isEmpty {
            for k in changed { remember(k, serial { read(k) }, local: false) }
            DispatchQueue.main.async {
                for k in changed { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": k]) }
            }
        }
        return changed
    }

    /// Alle sleutels in de sleutelhanger met dit voorvoegsel die een waarde hebben,
    /// bijv. `playlist.<id>.` voor de wachtwoorden en tokens van één bron.
    static func keys(withPrefix prefix: String) -> [String] {
        serial { () -> [String] in
            var out = Set<String>()
            for q in [syncedQuery(nil), legacyQuery(nil)] {
                var q = q
                q[kSecReturnAttributes as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitAll
                var res: AnyObject?
                if SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let items = res as? [[String: Any]] {
                    for i in items {
                        if let a = i[kSecAttrAccount as String] as? String, a.hasPrefix(prefix) { out.insert(a) }
                    }
                }
            }
            // nog niet overgezet (oude spiegel): ook meetellen, zodat verwijderen ook die kopie opruimt
            let legacy = (kv.dictionary(forKey: cloudKey) as? [String: String]) ?? [:]
            for (k, v) in legacy where k.hasPrefix(prefix) && !v.isEmpty { out.insert(k) }
            return out.sorted()
        }
    }

    // MARK: sleutelhanger (alleen aanroepen op de wachtrij)

    /// build 97: synchroniseerbaar item (iCloud-sleutelhanger). Op de Mac in de data-protection-sleutelhanger
    /// (vereist voor synchroniseerbare items).
    private static func syncedQuery(_ key: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        if let key { q[kSecAttrAccount as String] = key }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    /// build 97: oude, alleen-lokale items van eerdere builds (niet synchroniseerbaar)
    private static func legacyQuery(_ key: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let key { q[kSecAttrAccount as String] = key }
        return q
    }

    private static func readData(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readSynced(_ key: String) -> String? { readData(syncedQuery(key)) }
    private static func readLegacyLocal(_ key: String) -> String? { readData(legacyQuery(key)) }

    /// Eerst het synchroniseerbare item, anders een oud lokaal item (nog niet omgezet).
    private static func read(_ key: String) -> String? {
        if let v = readSynced(key), !v.isEmpty { return v }
        if let v = readLegacyLocal(key), !v.isEmpty { return v }
        return nil
    }

    private static func writeSynced(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete(syncedQuery(key) as CFDictionary)
        // het oude lokale item ook weg, anders kan het later een nieuwere waarde overschaduwen
        SecItemDelete(legacyQuery(key) as CFDictionary)
        var add = syncedQuery(key)
        add[kSecValueData as String] = data
        // synchroniseerbare items mogen geen "ThisDeviceOnly" zijn
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // build 143: synchroniseerbaar lukt niet (bijv. iCloud-sleutelhanger uit op dit toestel): dan alleen hier
            // bewaren, zodat het niet verloren gaat (`read` leest dit oude lokale item ook)
            var local = legacyQuery(key)
            local[kSecValueData as String] = data
            local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(local as CFDictionary, nil)
        }
    }

    private static func deleteAll(_ key: String) {
        SecItemDelete(syncedQuery(key) as CFDictionary)
        SecItemDelete(legacyQuery(key) as CFDictionary)
    }

    private static func deleteLegacyLocal(_ key: String) {
        SecItemDelete(legacyQuery(key) as CFDictionary)
    }

    /// Sleutels van oude, alleen-lokale items.
    private static func localOnlyAccounts() -> [String] {
        var q = legacyQuery(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var res: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let items = res as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// build 97: deze sleutel uit de oude iCloud KV-spiegel halen (als die nog bestaat).
    private static func purgeCloudCopy(_ key: String) {
        guard var d = kv.dictionary(forKey: cloudKey) as? [String: String], d[key] != nil else { return }
        d[key] = nil
        if d.isEmpty { kv.removeObject(forKey: cloudKey) } else { kv.set(d, forKey: cloudKey) }
        kv.synchronize()
    }

    // MARK: alleen op dit apparaat (Bingr-account)

    /// Eigen service, dus de overzetting naar de iCloud-sleutelhanger raakt deze items nooit aan.
    /// Niet-synchroniseerbaar: refresh tokens zijn eenmalig en horen bij één apparaat.
    private static let localOnlyService = "nl.lrvdlinden.bingr.device"

    static func setLocalOnly(_ value: String?, for key: String) {
        remember(key, (value?.isEmpty ?? true) ? nil : value, local: true)
        serialAsync {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: localOnlyService,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            SecItemDelete(base as CFDictionary)
            guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
            #if os(macOS)
            // Mac: gewone (lokale) sleutelhanger, zoals de rest van de app
            let accessible = kSecAttrAccessibleAfterFirstUnlock
            #else
            let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: localOnlyService,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecAttrAccessible as String: accessible
            ]
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func getLocalOnly(_ key: String) -> String? {
        if let c = cached(key, local: true) { return c }
        let v = readLocalOnly(key)
        remember(key, v, local: true)
        return v
    }

    private static func readLocalOnly(_ key: String) -> String? {
        serial { () -> String? in
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: localOnlyService,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    static func setCodable<T: Encodable>(_ value: T?, for key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else { set(nil, for: key); return }
        set(String(data: data, encoding: .utf8), for: key)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let s = get(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
