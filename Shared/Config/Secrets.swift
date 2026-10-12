import Foundation

/// App-sleutels voor Trakt, OpenSubtitles, OMDb en TMDB.
///
/// De repo is openbaar, dus deze sleutels staan niet in de app. Sinds build 41 komen ze van de
/// Bingr-server (device-auth `config`, zie docs/ACCOUNT.md → "App-sleutels van de server") en worden
/// ze alleen op dit apparaat bewaard (sleutelhanger zonder iCloud).
///
/// Volgorde bij het opzoeken: eerst wat de gebruiker zelf heeft ingevuld (**Mijn Bingr → Koppelingen
/// instellen**, iCloud-sleutelhanger), dan de sleutel van de server, dan `builtIn`.
enum Secrets {
    enum Key: String, CaseIterable {
        case traktClientID, traktClientSecret, openSubtitlesAPIKey, omdbAPIKey, tmdbAPIKey
        /// Bingr-account (Supabase): alleen ingebouwd, nooit in de sleutelhanger of in de app aan te passen.
        case supabaseURL, supabaseAnonKey

        var builtInOnly: Bool { self == .supabaseURL || self == .supabaseAnonKey }
    }

    private static let builtIn: [Key: String] = [
        .traktClientID: "",
        .traktClientSecret: "",
        .openSubtitlesAPIKey: "",
        .omdbAPIKey: "",
        .tmdbAPIKey: "",
        // Bingr-accounts: openbaar bedoeld (publishable key), daarom vast in de app
        .supabaseURL: "https://vjewsncmsxmhmhnoxwqx.supabase.co",
        .supabaseAnonKey: "sb_publishable_lpIup6Omq5kW2k3oICGZ4g_HPGac5A3"
    ]

    private static let lock = NSLock()
    private static var cache: [Key: String] = [:]

    static func value(_ k: Key) -> String {
        lock.lock(); defer { lock.unlock() }
        if let v = cache[k] { return v }
        if k.builtInOnly { let v = builtIn[k] ?? ""; cache[k] = v; return v }
        let v = nonEmpty(Keychain.get(userKey(k))) ?? nonEmpty(Keychain.getLocalOnly(serverKey(k))) ?? builtIn[k] ?? ""
        cache[k] = v
        return v
    }

    /// Alleen de waarde die de gebruiker zelf heeft ingevuld (voor "Koppelingen instellen").
    static func userValue(_ k: Key) -> String {
        guard !k.builtInOnly else { return "" }
        return nonEmpty(Keychain.get(userKey(k))) ?? ""
    }

    /// Sleutels van de Bingr-server opslaan (alleen op dit apparaat, nooit in iCloud).
    /// Een lege waarde wist de opgeslagen serverwaarde. Geeft `true` als er iets veranderd is.
    @discardableResult
    static func setServerValues(_ values: [Key: String]) -> Bool {
        var changed = false
        for (k, raw) in values where !k.builtInOnly {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = Keychain.getLocalOnly(serverKey(k)) ?? ""
            guard old != v else { continue }
            Keychain.setLocalOnly(v.isEmpty ? nil : v, for: serverKey(k))
            changed = true
        }
        if changed { reload() }
        return changed
    }

    private static func userKey(_ k: Key) -> String { "apikey.\(k.rawValue)" }
    private static func serverKey(_ k: Key) -> String { "serverkey.\(k.rawValue)" }
    private static func nonEmpty(_ v: String?) -> String? {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    static func set(_ k: Key, _ value: String) {
        guard !k.builtInOnly else { return }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(v.isEmpty ? nil : v, for: userKey(k))
        // opnieuw opzoeken: leeg = terugvallen op de server of `builtIn`
        lock.lock(); cache[k] = nil; lock.unlock()
    }

    /// Opnieuw inlezen (bijv. na wijziging op een ander apparaat via iCloud).
    static func reload() { lock.lock(); cache = [:]; lock.unlock() }

    static var traktClientID: String { value(.traktClientID) }
    static var traktClientSecret: String { value(.traktClientSecret) }
    static var openSubtitlesAPIKey: String { value(.openSubtitlesAPIKey) }
    static var omdbAPIKey: String { value(.omdbAPIKey) }
    static var tmdbAPIKey: String { value(.tmdbAPIKey) }
    static var supabaseURL: String {
        let v = value(.supabaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.hasSuffix("/") ? String(v.dropLast()) : v
    }
    static var supabaseAnonKey: String { value(.supabaseAnonKey) }
    /// Bingr-accounts beschikbaar in deze build (SUPABASE_URL en SUPABASE_ANON_KEY ingebouwd).
    static var accountsConfigured: Bool {
        isSet(supabaseURL) && isSet(supabaseAnonKey) && URL(string: supabaseURL)?.host != nil
    }

    /// Nieuwe Trakt-apps (sinds okt. 2026) hebben alleen een Client ID (PKCE); het secret is optioneel.
    static var traktReady: Bool { isSet(traktClientID) }
    static var openSubtitlesReady: Bool { isSet(openSubtitlesAPIKey) }

    static let userAgent = "Bingr v1.0.0"

    static func isSet(_ v: String) -> Bool { !v.isEmpty && !v.hasPrefix("VUL_") }
}
