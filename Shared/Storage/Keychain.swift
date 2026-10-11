import Foundation
import Security

/// Wachtwoorden, tokens en app-sleutels.
///
/// Lokaal in de sleutelhanger, én gespiegeld in je privé iCloud Key-Value Store.
/// Die spiegel is nodig omdat Apple TV synchroniseerbare sleutelhanger-items van
/// apps niet betrouwbaar via iCloud ontvangt; zonder spiegel zag de Apple TV wel je
/// afspeellijst, maar niet het wachtwoord (→ serverfout 511 / inloggen mislukt).
enum Keychain {
    private static let service = "nl.lrvdlinden.bingr"
    private static let cloudKey = "secrets.v1"
    private static var kv: NSUbiquitousKeyValueStore { .default }

    static func set(_ value: String?, for key: String) {
        setLocal(value, for: key)
        var d = cloud()
        // verwijderen = een lege waarde laten staan ("grafsteen"), zodat andere apparaten het ook wissen
        // en hun oude kopie niet terugzetten (anders kwam bijv. een verwijderde pincode steeds terug)
        if let value, !value.isEmpty { d[key] = value } else { d[key] = "" }
        kv.set(d, forKey: cloudKey)
        kv.synchronize()
    }

    static func get(_ key: String) -> String? {
        let c = cloud()
        if let v = c[key], v.isEmpty {           // elders verwijderd → hier ook weg
            if getLocal(key) != nil { setLocal(nil, for: key) }
            return nil
        }
        if let v = getLocal(key) { return v }
        // nog niet lokaal (bijv. eerste keer op Apple TV): uit iCloud halen en lokaal bewaren
        if let v = c[key], !v.isEmpty {
            setLocal(v, for: key)
            return v
        }
        return nil
    }

    /// Zet lokale geheimen die nog niet in iCloud staan erbij (eenmalig na een update).
    static func pushToCloud(keys: [String]) {
        var d = cloud()
        var changed = false
        for k in keys where d[k] == nil {
            if let v = getLocal(k), !v.isEmpty { d[k] = v; changed = true }
        }
        if changed { kv.set(d, forKey: cloudKey); kv.synchronize() }
    }

    /// Na een iCloud-wijziging: nieuwe of gewijzigde geheimen lokaal overnemen.
    static func syncFromCloud() {
        for (k, v) in cloud() {
            if v.isEmpty { if getLocal(k) != nil { setLocal(nil, for: k) } }
            else if getLocal(k) != v { setLocal(v, for: k) }
        }
    }

    private static func cloud() -> [String: String] {
        (kv.dictionary(forKey: cloudKey) as? [String: String]) ?? [:]
    }

    // MARK: lokale sleutelhanger

    private static func setLocal(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func getLocal(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
