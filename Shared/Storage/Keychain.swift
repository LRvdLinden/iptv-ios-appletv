import Foundation
import Security

/// iCloud-sleutelhanger (synchronizable). Omdat beide apps dezelfde
/// keychain-access-group als eerste groep hebben, zien iOS en tvOS dezelfde items.
enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nl.lrvdlinden.bingr",
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue!
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nl.lrvdlinden.bingr",
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
