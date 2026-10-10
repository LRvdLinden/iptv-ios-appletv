import Foundation
import SwiftUI

/// Eigen vertaalsysteem: Engelse tekst is de sleutel, vertalingen staan in
/// `Translations.json` (per taalcode). Zo kan de taal ook in de app zelf
/// gekozen worden, los van de systeemtaal.
///
/// Gebruik: `L("Play")`, `L("%d seasons", n)`, `L("Logged in as %@", name)`.
final class Localizer: ObservableObject {
    static let shared = Localizer()

    static let supported: [(code: String, name: String)] = [
        ("en", "English"), ("nl", "Nederlands"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("tr", "Türkçe"),
        ("pl", "Polski"), ("ar", "العربية"), ("zh-Hans", "简体中文")
    ]

    /// "" = volg het systeem
    @Published var override: String {
        didSet {
            UserDefaults.standard.set(override, forKey: "app.language")
            language = Self.resolve(override)
        }
    }
    @Published private(set) var language: String

    private let table: [String: [String: String]]

    private init() {
        let o = UserDefaults.standard.string(forKey: "app.language") ?? ""
        override = o
        language = Self.resolve(o)
        if let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let t = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            table = t
        } else {
            table = [:]
        }
    }

    static func resolve(_ override: String) -> String {
        if !override.isEmpty { return override }
        let codes = supported.map(\.code)
        for pref in Locale.preferredLanguages {
            if pref.hasPrefix("zh") { return "zh-Hans" }
            let base = String(pref.prefix(while: { $0 != "-" && $0 != "_" }))
            if codes.contains(base) { return base }
        }
        return "en"
    }

    func text(_ key: String) -> String {
        guard language != "en" else { return key }
        return table[language]?[key] ?? key
    }

    var isRTL: Bool { language == "ar" }
    var locale: Locale { Locale(identifier: language) }
}

/// Vertaal een Engelse tekst naar de actieve taal.
func L(_ key: String) -> String { Localizer.shared.text(key) }

/// Vertaal met opmaak-argumenten (`%@`, `%d`).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.text(key), locale: Localizer.shared.locale, arguments: args)
}
