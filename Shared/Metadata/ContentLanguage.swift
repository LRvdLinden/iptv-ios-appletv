import Foundation

/// Taal van een film of serie (build 59), zoals IPTV-servers die in de titel of de categorie zetten:
/// "Animal (IT)", "NL | Animal", "|NL| Animal", "[NL] Animal", "EN- Animal", "Animal NL SUBS", "Animal (MULTI)",
/// of een categorie als "NL Films" / "VOD | DE". Zonder label: de originele taal uit TMDB (al geladen metadata).
/// Dezelfde regels gelden in de Android- en Tizen-app.
struct ContentLanguage: Hashable, Sendable {
    enum Source: String, Sendable { case title, group, original }

    /// Gesproken taal (ISO 639-1, bijv. "nl", "it", "pt-BR"); nil = onbekend
    var audio: String?
    /// Ondertitels die al in de stream zitten (meestal ingebrand), bijv. "nl" bij "NL SUBS"
    var subtitles: String?
    var multi = false
    var dual = false
    var source: Source = .title

    var isEmpty: Bool { audio == nil && subtitles == nil && !multi && !dual }
    /// Basistaal zonder regio ("pt-BR" → "pt")
    var audioBase: String? { audio.map(Self.base) }
    var subtitlesBase: String? { subtitles.map(Self.base) }

    /// Korte code voor op de cover: "NL", "EN", "BR"
    static func label(_ code: String) -> String {
        let parts = code.split(separator: "-")
        if parts.count > 1 { return String(parts[1]).uppercased() }
        return code.uppercased()
    }
    static func base(_ code: String) -> String { String(code.lowercased().split(separator: "-").first ?? "") }

    /// Tekst voor de strook onderaan de poster: "NL", "IT", "EN · NL ondertitels", "Multi"
    var banner: String? {
        if multi { return audio.map { "Multi · \(Self.label($0))" } ?? "Multi" }
        var parts: [String] = []
        if let a = audio { parts.append(Self.label(a)) }
        if dual { parts.append("Dual") }
        if let s = subtitles { parts.append(L("%@ subtitles", Self.label(s))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Voor de detailpagina: "Italiaans", "Engels (origineel) · Ondertitels: Nederlands", "Meertalig"
    var detailText: String? {
        var parts: [String] = []
        if multi { parts.append(L("Multiple languages")) }
        else if let a = audio {
            var name = TrackPreferences.name(Self.base(a))
            if source == .original { name = L("%@ (original)", name) }
            parts.append(name)
            if dual { parts.append(L("Dual audio")) }
        } else if dual { parts.append(L("Dual audio")) }
        if let s = subtitles { parts.append(L("Subtitles: %@", TrackPreferences.name(Self.base(s)))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - opzoeken (met cache)

    /// Taal van een titel: eerst uit de titel, dan uit de categorie, anders de originele taal (TMDB) als die al bekend is.
    static func resolve(title: String, group: String?, id: String?) -> ContentLanguage? {
        var t = parseTitle(title).language
        if let g = group, !g.isEmpty, let gl = parseGroup(g) {
            if t == nil { t = gl }
            else if t?.audio == nil && !(t?.multi ?? false) { t?.audio = gl.audio }   // "NL SUBS" in een "EN Films"-categorie
        }
        if var t, !t.isEmpty {
            // alleen ondertitels bekend ("NL SUBS"): gesproken taal = de originele taal, als die bekend is
            if t.audio == nil, !t.multi, let id, let o = Facts.shared.originalLanguage(id) { t.audio = o }
            return t
        }
        if let id, let o = Facts.shared.originalLanguage(id) {
            var r = t ?? ContentLanguage()
            r.audio = o; r.source = .original
            return r
        }
        return t
    }

    static func of(_ m: Movie) -> ContentLanguage? { resolve(title: m.title, group: m.group, id: m.id) }
    static func of(_ s: Series) -> ContentLanguage? { resolve(title: s.title, group: s.group, id: s.id) }

    /// Titel zonder taallabel ("Animal (IT)" → "Animal", "NL | Animal (2021)" → "Animal (2021)").
    static func displayTitle(_ raw: String) -> String { parseTitle(raw).title }

    /// Build 153: titel of naam van de server voor in beeld (film, serie, aflevering, geschiedenis, speler, meldingen):
    /// zonder taallabel en zonder stukken tussen pipes. Alleen weergave; nooit als sleutel gebruiken.
    static func shown(_ raw: String) -> String { CategoryName.display(displayTitle(raw)) }

    /// Titel voor zoeken en koppelen: zonder taallabel en zonder IPTV-rommel.
    static func searchTitle(_ raw: String) -> String { TitleCleaner.parse(displayTitle(raw)).title }

    // MARK: - originele taal en TMDB-id uit al geladen metadata

    /// Wat de detailpagina al bij TMDB vond (per titel-id), voor de cover en de ondertitels.
    final class Facts: @unchecked Sendable {
        static let shared = Facts()
        private let lock = NSLock()
        private var original: [String: String] = [:]
        private var tmdb: [String: Int] = [:]
        private let key = "contentLanguage.original"

        private init() {
            original = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        }
        func originalLanguage(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return original[id] }
        func tmdbID(_ id: String) -> Int? { lock.lock(); defer { lock.unlock() }; return tmdb[id] }
        func set(id: String, original lang: String?, tmdbID: Int?) {
            lock.lock()
            var changed = false
            if let lang, !lang.isEmpty, lang != "xx", original[id] != lang.lowercased() {
                original[id] = lang.lowercased(); changed = true
                if original.count > 4000 { original.removeAll() }   // begrensd; wordt vanzelf weer gevuld
            }
            if let tmdbID { tmdb[id] = tmdbID }
            let snapshot = changed ? original : nil
            lock.unlock()
            if let snapshot { UserDefaults.standard.set(snapshot, forKey: key) }
        }
    }

    // MARK: - parser

    struct ParsedTitle: Sendable { var title: String; var language: ContentLanguage? }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var titles: [String: ParsedTitle] = [:]
        var groups: [String: ContentLanguage?] = [:]
    }
    private static let cache = Cache()

    /// Bekende codes en namen → taal (ISO 639-1, Braziliaans als "pt-BR").
    static let table: [String: String] = [
        "NL": "nl", "NLD": "nl", "DUT": "nl", "DUTCH": "nl", "NEDERLANDS": "nl", "NEDERLANDSE": "nl",
        "VL": "nl", "VLAAMS": "nl", "VLAAMSE": "nl", "FLEMISH": "nl",
        "EN": "en", "ENG": "en", "UK": "en", "US": "en", "USA": "en", "GB": "en", "ENGLISH": "en",
        "DE": "de", "GER": "de", "DEU": "de", "GERMAN": "de", "DEUTSCH": "de",
        "FR": "fr", "FRA": "fr", "FRE": "fr", "FRENCH": "fr", "FRANCAIS": "fr", "FRANÇAIS": "fr", "VF": "fr", "VFF": "fr",
        "ES": "es", "ESP": "es", "SPA": "es", "SPANISH": "es", "ESPANOL": "es", "ESPAÑOL": "es", "CASTELLANO": "es",
        "LAT": "es", "LATINO": "es",
        "IT": "it", "ITA": "it", "ITALIAN": "it", "ITALIANO": "it",
        "PT": "pt", "POR": "pt", "PORTUGUESE": "pt", "PORTUGUES": "pt", "PORTUGUÊS": "pt",
        "BR": "pt-BR", "PTBR": "pt-BR", "BRAZIL": "pt-BR", "BRASIL": "pt-BR",
        "TR": "tr", "TUR": "tr", "TURK": "tr", "TURKISH": "tr", "TÜRK": "tr", "TURKCE": "tr", "TÜRKÇE": "tr",
        "AR": "ar", "ARA": "ar", "ARAB": "ar", "ARABIC": "ar",
        "PL": "pl", "POL": "pl", "POLISH": "pl", "POLSKI": "pl",
        "IN": "hi", "HIN": "hi", "HINDI": "hi", "BOLLYWOOD": "hi",
        "RU": "ru", "RUS": "ru", "RUSSIAN": "ru",
        "SE": "sv", "SWE": "sv", "SWEDISH": "sv", "DK": "da", "DAN": "da", "DANISH": "da",
        "NO": "no", "NOR": "no", "NORWEGIAN": "no", "FI": "fi", "FIN": "fi", "FINNISH": "fi",
        "GR": "el", "GRE": "el", "GREEK": "el", "RO": "ro", "ROM": "ro", "ROMANIAN": "ro",
        "HU": "hu", "HUN": "hu", "CZ": "cs", "CZE": "cs", "AL": "sq", "ALB": "sq", "ALBANIAN": "sq",
        "YU": "sr", "SRB": "sr", "HR": "hr", "BG": "bg", "BUL": "bg",
        "KU": "ku", "KURD": "ku", "KURDISH": "ku", "FA": "fa", "IR": "fa", "PERSIAN": "fa", "FARSI": "fa",
        "PK": "ur", "URDU": "ur", "TAMIL": "ta", "TELUGU": "te", "MALAYALAM": "ml", "PUNJABI": "pa",
        "KR": "ko", "KOR": "ko", "KOREAN": "ko", "JP": "ja", "JPN": "ja", "JAPANESE": "ja",
        "CN": "zh", "CHI": "zh", "CHINESE": "zh", "TH": "th", "THAI": "th", "VN": "vi", "VIE": "vi",
        "IL": "he", "HEB": "he", "HEBREW": "he", "SO": "so", "SOMALI": "so"
    ]

    /// Codes die ook een gewoon woord zijn: alleen tussen haken of met "|" als label ("IN | …", "(IN)"),
    /// niet bij "In: …" of "It - …" waar het de titel zelf kan zijn.
    private static let wordCodes: Set<String> = ["IN", "NO", "US", "SO", "AL", "IT"]

    private static let regionOnly: Set<String> = ["UK", "US", "USA", "GB"]
    private static let subWords: Set<String> = ["SUB", "SUBS", "SUBBED", "SUBTITLED", "SUBTITLES", "ONDERTITELD", "ONDERTITELS", "OT"]
    private static let audioWords: Set<String> = ["GESPROKEN", "DUB", "DUBBED", "NASYNCHRO", "AUDIO", "VERSION", "VERSIE", "TAAL", "LANG"]
    private static let multiWords: Set<String> = ["MULTI", "MULTIAUDIO", "MULTILANG", "MULTILANGUAGE"]

    private static let prefixRE = try! NSRegularExpression(
        pattern: #"^\s*(?:\|\s*([A-Za-z]{2,4})\s*\||\[\s*([A-Za-z]{2,4})\s*\]|\(\s*([A-Za-z]{2,4})\s*\)|([A-Z]{2,4})\s*(\||:|-|–)\s*)"#)
    private static let bracketRE = try! NSRegularExpression(pattern: #"\s*[\(\[]([^\)\]\(\[]{1,28})[\)\]]"#)
    private static let suffixFlagRE = try! NSRegularExpression(
        pattern: #"(?i)[\s\-–|]+((?:[A-Z]{2,3}[\s\-]+)?(?:SUBS?|SUBBED|MULTI(?:[\s\-]?(?:AUDIO|SUBS?))?|DUAL(?:[\s\-]?AUDIO)?)|[A-Z]{2}[\s\-]+GESPROKEN)\s*$"#)
    private static let suffixCodeRE = try! NSRegularExpression(pattern: #"\s+[\-–|]\s*([A-Z]{2,3})\s*$"#)

    /// Titel ontleden: het taallabel eruit, de rest van de titel blijft zoals hij was.
    static func parseTitle(_ raw: String) -> ParsedTitle {
        cache.lock.lock()
        if let hit = cache.titles[raw] { cache.lock.unlock(); return hit }
        cache.lock.unlock()
        let r = computeTitle(CategoryName.normalizeSeparators(raw))   // build 150: ook "¦", "│", "｜"
        cache.lock.lock()
        if cache.titles.count > 60_000 { cache.titles.removeAll(keepingCapacity: true) }
        cache.titles[raw] = r
        cache.lock.unlock()
        return r
    }

    static func parseGroup(_ group: String) -> ContentLanguage? {
        cache.lock.lock()
        if let hit = cache.groups[group] { cache.lock.unlock(); return hit }
        cache.lock.unlock()
        let r = computeGroup(CategoryName.normalizeSeparators(group))
        cache.lock.lock()
        cache.groups[group] = r
        cache.lock.unlock()
        return r
    }

    private static func computeTitle(_ raw: String) -> ParsedTitle {
        var s = raw
        var lang = ContentLanguage()

        // 0. build 153: stukken tussen pipes aan het begin of eind weg, wat er ook tussen staat ("┃NL┃The Batman",
        //    "| MULTI / LINGO | The Witcher", "|NL| |4K| Dune"); een taal daarin telt als taal van de titel.
        if let p = CategoryName.pipeBlocks(s) {
            for b in p.blocks { if let tag = bracketTag(b) { merge(tag, into: &lang) } }
            s = p.rest
        }

        // 1. labels vooraan: "NL | ", "NL: ", "|NL| ", "[NL] ", "NL - ", "EN-"
        for _ in 0..<2 {
            let ns = s as NSString
            guard let m = prefixRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { break }
            var code: String?, sep = "", bracketed = false
            for i in 1...4 where m.range(at: i).location != NSNotFound {
                code = ns.substring(with: m.range(at: i)); bracketed = i <= 3
            }
            if m.range(at: 5).location != NSNotFound { sep = ns.substring(with: m.range(at: 5)) }
            guard let c = code?.uppercased(), let iso = table[c] else { break }
            let rest = ns.substring(from: m.range.location + m.range.length)
            if !bracketed && sep != "|" && wordCodes.contains(c) {
                // "IT - …" mag (Italiaans), maar "IT: Chapter Two" / "In: …" is de titel zelf
                guard c == "IT", sep != ":", !rest.lowercased().hasPrefix("chapter"), !rest.lowercased().hasPrefix("welcome") else { break }
            }
            guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            if lang.audio == nil { lang.audio = iso }
            s = rest
        }

        // 2. labels tussen haken (overal): "(IT)", "[NL]", "(NL SUBS)", "(MULTI)", "(ITA/ENG)", "(IN)"
        var changed = true
        while changed {
            changed = false
            let ns = s as NSString
            for m in bracketRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let inner = ns.substring(with: m.range(at: 1))
                guard let tag = bracketTag(inner) else { continue }
                // "(UK)" / "(US)" is vaak de landversie ("The Office (UK)"): wel Engels, maar in de titel laten staan
                if regionOnly.contains(inner.trimmingCharacters(in: .whitespaces).uppercased()) {
                    if lang.audio == nil { lang.audio = tag.audio }
                    continue
                }
                merge(tag, into: &lang)
                s = ns.replacingCharacters(in: m.range, with: "")
                changed = true
                break
            }
        }

        // 3. achteraan zonder haken: "NL SUBS", "MULTI", "DUAL", "NL GESPROKEN", " - NL"
        for _ in 0..<2 {
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = suffixFlagRE.firstMatch(in: s, range: full), m.range.location > 0 {
                let head = ns.substring(to: m.range.location)
                guard !head.trimmingCharacters(in: .whitespaces).isEmpty, let tag = bracketTag(ns.substring(with: m.range(at: 1))) else { break }
                merge(tag, into: &lang)
                s = head
                continue
            }
            if let m = suffixCodeRE.firstMatch(in: s, range: full), m.range.location > 0 {
                let c = ns.substring(with: m.range(at: 1)).uppercased()
                guard let iso = table[c], !wordCodes.contains(c) else { break }
                if lang.audio == nil { lang.audio = iso }
                s = ns.substring(to: m.range.location)
                continue
            }
            break
        }

        let title = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–|:"))
        return ParsedTitle(title: title.isEmpty ? raw : title, language: lang.isEmpty ? nil : lang)
    }

    /// Inhoud van een label ("NL SUBS", "ITA/ENG", "Multi-Audio"); nil als het geen taallabel is (bijv. "2021", "4K").
    private static func bracketTag(_ inner: String) -> ContentLanguage? {
        let tokens = inner.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var langs: [String] = [], subs = false, multi = false, dual = false, vost = false
        for (i, t) in tokens.enumerated() {
            if let iso = table[t] { langs.append(iso); continue }
            if subWords.contains(t) { subs = true; continue }
            if multiWords.contains(t) {
                // "MULTI-SUB" = meerdere ondertitels, geen meertalig geluid
                if i + 1 < tokens.count, subWords.contains(tokens[i + 1]) { subs = true } else { multi = true }
                continue
            }
            if t == "DUAL" { dual = true; continue }
            if t == "VOSTFR" { vost = true; langs.append("fr"); continue }
            if t == "VOST" || t == "VO" { vost = true; continue }
            if audioWords.contains(t) { continue }
            return nil   // onbekend woord: geen taallabel (bijv. "(The Italian Job)")
        }
        var r = ContentLanguage()
        r.multi = multi; r.dual = dual || (!subs && !vost && langs.count == 2)
        if subs || vost {
            if langs.count >= 2 { r.audio = langs.first; r.subtitles = langs.last }
            else { r.subtitles = langs.first ?? (vost ? "fr" : nil) }
            if r.subtitles == nil && !multi && !dual { return nil }
        } else {
            r.audio = langs.first
        }
        return r.isEmpty ? nil : r
    }

    private static func merge(_ t: ContentLanguage, into l: inout ContentLanguage) {
        if l.audio == nil { l.audio = t.audio }
        if l.subtitles == nil { l.subtitles = t.subtitles }
        l.multi = l.multi || t.multi
        l.dual = l.dual || t.dual
    }

    /// Categorie: "NL Films", "VOD | DE", "|NL| Series", "Films (ITA)", "Italian Movies", "NL SUBS", "MULTI".
    private static func computeGroup(_ group: String) -> ContentLanguage? {
        let words = group.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var r = ContentLanguage(source: .group)
        var sawSubs = false
        var langs: [String] = []
        for w in words {
            let up = w.uppercased()
            if subWords.contains(up) { sawSubs = true; continue }
            if multiWords.contains(up) { r.multi = true; continue }
            guard let iso = table[up] else { continue }
            // korte codes alleen in hoofdletters ("NL Films"), zodat "Movies in 4K" niet Hindi wordt
            if up.count <= 3 && w != up { continue }
            langs.append(iso)
        }
        if sawSubs {
            // "NL SUBS": Nederlandse ondertitels (gesproken taal onbekend); "EN NL SUBS": Engels met Nederlandse ondertitels
            if langs.count >= 2 { r.audio = langs.first; r.subtitles = langs.last } else { r.subtitles = langs.first }
        } else {
            r.audio = langs.first
        }
        return r.isEmpty ? nil : r
    }
}
