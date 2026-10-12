import Foundation

/// Standaard audio- en ondertiteltaal (Mijn Bingr → Speler).
/// Wordt toegepast zodra een stream zijn sporen bekendmaakt, in beide engines.
enum TrackPreferences {
    static let audioKey = "player.audioLanguage"       // "" = zoals de stream
    static let subtitleKey = "player.subtitleLanguage" // "" = zoals de stream, "off" = uit

    static var audio: String { UserDefaults.standard.string(forKey: audioKey) ?? "" }
    static var subtitle: String { UserDefaults.standard.string(forKey: subtitleKey) ?? "" }

    /// Talen die je kunt kiezen (ISO 639-1) met hun ISO 639-2-varianten (zoals streams ze vaak noemen).
    static let languages: [(code: String, alt: [String])] = [
        ("nl", ["nld", "dut", "vlaams", "flemish"]), ("en", ["eng"]), ("de", ["deu", "ger"]), ("fr", ["fra", "fre"]),
        ("es", ["spa", "esp", "castellano", "latino"]), ("it", ["ita"]), ("pt", ["por", "brazil", "brasil"]), ("tr", ["tur"]),
        ("ar", ["ara"]), ("pl", ["pol"]), ("zh", ["zho", "chi", "chs", "cht", "mandarin", "cantonese"]), ("ja", ["jpn"]),
        ("ko", ["kor"]), ("ru", ["rus"]), ("uk", ["ukr"]), ("hi", ["hin"]), ("sv", ["swe"]), ("da", ["dan"]),
        ("no", ["nor", "nob", "nno"]), ("fi", ["fin"]), ("el", ["ell", "gre"]), ("he", ["heb"]), ("hu", ["hun"]),
        ("cs", ["ces", "cze"]), ("ro", ["ron", "rum"]), ("bg", ["bul"]), ("hr", ["hrv"]), ("sr", ["srp"]),
        ("fa", ["fas", "per"]), ("ur", ["urd"]), ("th", ["tha"]), ("vi", ["vie"]), ("id", ["ind"]), ("ms", ["msa", "may"]),
        ("ta", ["tam"]), ("pa", ["pan"]), ("bn", ["ben"]), ("sq", ["sqi", "alb"]), ("ku", ["kur"]), ("so", ["som"])
    ]

    /// Taalnaam in de taal van de app.
    static func name(_ code: String) -> String {
        let loc = Locale(identifier: Localizer.shared.language)
        return (loc.localizedString(forLanguageCode: code) ?? code).capitalized(with: loc)
    }

    /// Vlag-emoji voor een taal of OpenSubtitles-code ("nl", "pt-BR", "zh-CN", "eng" …).
    static func flag(_ code: String) -> String {
        let c = code.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = c.split(separator: "-").map(String.init)
        var base = parts.first ?? c
        if base.count == 3, let hit = languages.first(where: { $0.alt.contains(base) }) { base = hit.code }
        // regio uit de code zelf (pt-BR, zh-TW, en-US)
        if parts.count > 1, parts[1].count == 2 { return emoji(parts[1]) }
        let region: [String: String] = [
            "en": "GB", "nl": "NL", "de": "DE", "fr": "FR", "es": "ES", "it": "IT", "pt": "PT", "tr": "TR", "ar": "SA",
            "pl": "PL", "zh": "CN", "ja": "JP", "ko": "KR", "ru": "RU", "uk": "UA", "hi": "IN", "sv": "SE", "da": "DK",
            "no": "NO", "nb": "NO", "fi": "FI", "el": "GR", "he": "IL", "hu": "HU", "cs": "CZ", "ro": "RO", "bg": "BG",
            "hr": "HR", "sr": "RS", "fa": "IR", "ur": "PK", "th": "TH", "vi": "VN", "id": "ID", "ms": "MY", "ta": "LK",
            "pa": "IN", "bn": "BD", "sq": "AL", "ku": "IQ", "so": "SO", "sk": "SK", "sl": "SI", "et": "EE", "lv": "LV",
            "lt": "LT", "is": "IS", "ga": "IE", "ca": "AD", "eu": "ES", "gl": "ES", "tl": "PH", "mk": "MK", "bs": "BA",
            "ka": "GE", "hy": "AM", "az": "AZ", "kk": "KZ", "mn": "MN", "ne": "NP", "si": "LK", "af": "ZA", "sw": "KE"
        ]
        return region[base].map(emoji) ?? "🌐"
    }
    private static func emoji(_ region: String) -> String {
        String(String.UnicodeScalarView(region.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
    /// "🇳🇱 Nederlands" voor keuzelijsten.
    static func label(_ code: String) -> String { "\(flag(code)) \(name(code))" }

    /// "nld" / "nl-NL" / "pt-BR" → "nl" / "nl" / "pt" (ISO 639-1, zoals in `languages`) (build 57)
    static func baseCode(_ code: String) -> String {
        let base = String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if base.count == 3, let hit = languages.first(where: { $0.alt.contains(base) }) { return hit.code }
        return base
    }

    /// Talen alfabetisch op naam.
    static var sortedCodes: [String] {
        languages.map(\.code).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// Past een spoor bij deze taal? Kijkt naar de taalcode (AVPlayer) en naar de naam (VLC: "Dutch - [Nederlands]").
    static func matches(_ t: MediaTrack, code: String) -> Bool {
        if let l = t.lang?.lowercased() {
            let base = String(l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            let alts = languages.first { $0.code == code }?.alt ?? []
            if base == code || alts.contains(base) { return true }
        }
        let n = t.name.lowercased()
        let words = Set(n.split(whereSeparator: { !$0.isLetter }).map(String.init))
        var needles = [code] + (languages.first { $0.code == code }?.alt ?? [])
        for id in ["en", code, Localizer.shared.language] {
            if let s = Locale(identifier: id).localizedString(forLanguageCode: code)?.lowercased() { needles.append(s) }
        }
        return needles.contains { s in s.count <= 3 ? words.contains(s) : n.contains(s) }
    }
}
