import Foundation

/// App-sleutels voor Trakt, OpenSubtitles, OMDb en TMDB.
///
/// Trakt en OpenSubtitles eisen dat elke app zich één keer registreert (zo doet UHF
/// dat ook). Die sleutels vul je in de app in: **Mijn Bingr → Koppelingen instellen**.
/// Ze worden in de iCloud-sleutelhanger bewaard, dus ook je Apple TV heeft ze meteen,
/// en ze komen nooit in de (openbare) GitHub-repo te staan.
///
/// Wil je ze toch vast in de app bakken, vul ze dan hieronder in `builtIn` in.
enum Secrets {
    enum Key: String, CaseIterable {
        case traktClientID, traktClientSecret, openSubtitlesAPIKey, omdbAPIKey, tmdbAPIKey
    }

    private static let builtIn: [Key: String] = [
        .traktClientID: "",
        .traktClientSecret: "",
        .openSubtitlesAPIKey: "",
        .omdbAPIKey: "",
        .tmdbAPIKey: ""
    ]

    private static let lock = NSLock()
    private static var cache: [Key: String] = [:]

    static func value(_ k: Key) -> String {
        lock.lock(); defer { lock.unlock() }
        if let v = cache[k] { return v }
        let v = Keychain.get("apikey.\(k.rawValue)") ?? builtIn[k] ?? ""
        cache[k] = v
        return v
    }

    static func set(_ k: Key, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(v.isEmpty ? nil : v, for: "apikey.\(k.rawValue)")
        lock.lock(); cache[k] = v.isEmpty ? (builtIn[k] ?? "") : v; lock.unlock()
    }

    /// Opnieuw inlezen (bijv. na wijziging op een ander apparaat via iCloud).
    static func reload() { lock.lock(); cache = [:]; lock.unlock() }

    static var traktClientID: String { value(.traktClientID) }
    static var traktClientSecret: String { value(.traktClientSecret) }
    static var openSubtitlesAPIKey: String { value(.openSubtitlesAPIKey) }
    static var omdbAPIKey: String { value(.omdbAPIKey) }
    static var tmdbAPIKey: String { value(.tmdbAPIKey) }

    /// Nieuwe Trakt-apps (sinds okt. 2026) hebben alleen een Client ID (PKCE); het secret is optioneel.
    static var traktReady: Bool { isSet(traktClientID) }
    static var openSubtitlesReady: Bool { isSet(openSubtitlesAPIKey) }

    static let userAgent = "Bingr v1.0.0"

    static func isSet(_ v: String) -> Bool { !v.isEmpty && !v.hasPrefix("VUL_") }
}
