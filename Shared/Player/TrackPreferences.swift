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
