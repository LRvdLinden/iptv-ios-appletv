import Foundation

// Build 149: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
//
// Aanleiding (diagnose build 148): 6,6 s vast op de hoofdthread bij sync toepassen en bewaren, in het aanmaken van
// datumopmakers (ICU `udat_open`), omdat er per item een nieuwe ISO8601DateFormatter/DateFormatter werd gemaakt.
// Hier staat een snelle eigen parser/opmaker voor ISO-8601 en XMLTV, zonder ICU en zonder gedeelde staat
// (dus vanzelf thread-veilig). Voor wat hij niet kent, vallen de aanroepers terug op één gedeelde opmaker.

enum FastISO {

    // MARK: lezen

    /// ISO-8601 / RFC 3339 / Postgres → seconden sinds 1970.
    /// `yyyy-MM-ddTHH:mm[:ss][.f…](Z|±HH[:]MM|±HH)`; `T` mag ook een spatie zijn, de fractie 0–9+ cijfers.
    /// Zonder tijdzone alleen met `defaultUTC`. Alleen een datum (`yyyy-MM-dd`) → nil (zie `day`).
    static func seconds(_ s: String, defaultUTC: Bool = false) -> Double? {
        var s = s
        return s.withUTF8 { parse($0, defaultUTC: defaultUTC) }
    }

    static func date(_ s: String, defaultUTC: Bool = false) -> Date? {
        seconds(s, defaultUTC: defaultUTC).map { Date(timeIntervalSince1970: $0) }
    }

    /// Alleen de datum `yyyy-MM-dd` (wat erna komt telt niet) → middernacht in `timeZone`.
    static func day(_ s: String, timeZone: TimeZone = .current) -> Date? {
        var s = s
        let utc: Double? = s.withUTF8 { b in
            var i = 0
            while i < b.count, b[i] == 32 { i += 1 }
            guard let y = num(b, &i, 4), lit(b, &i, 45), let mo = num(b, &i, 2), lit(b, &i, 45), let d = num(b, &i, 2),
                  validDate(y, mo, d) else { return nil }
            if i < b.count, isDigit(b[i]) { return nil }
            return Double(daysFromCivil(y, mo, d) * 86400)
        }
        guard let utc else { return nil }
        // tweemaal, zodat de verschuiving van die dag zelf telt (zomertijd)
        let off1 = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: utc)))
        let off2 = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: utc - off1)))
        return Date(timeIntervalSince1970: utc - off2)
    }

    /// XMLTV `yyyyMMddHHmm[ss][ ±HHMM]` → Date. Zonder (geldige) tijdzone telt UTC, zoals voorheen.
    static func xmltv(_ s: String) -> Date? {
        var s = s
        let t: Double? = s.withUTF8 { b in
            var i = 0, n = b.count
            while i < n, b[i] == 32 { i += 1 }
            while n > i, b[n - 1] == 32 || b[n - 1] == 10 || b[n - 1] == 13 || b[n - 1] == 9 { n -= 1 }
            guard let y = num(b, &i, 4), let mo = num(b, &i, 2), let d = num(b, &i, 2),
                  let h = num(b, &i, 2), let mi = num(b, &i, 2) else { return nil }
            var sec = 0
            if i + 1 < n, isDigit(b[i]), isDigit(b[i + 1]), let v = num(b, &i, 2) { sec = v }
            guard validDate(y, mo, d), h <= 23, mi <= 59, sec <= 60 else { return nil }
            while i < n, b[i] == 32 { i += 1 }
            var off = 0
            if i < n, b[i] == 43 || b[i] == 45 {
                let sign = b[i] == 45 ? -1 : 1
                var j = i + 1
                if let oh = num(b, &j, 2) {
                    var om = 0
                    if j < n, b[j] == 58 { j += 1 }
                    if j < n, let v = num(b, &j, 2) { om = v }
                    if oh <= 23, om <= 59 { off = sign * (oh * 3600 + om * 60) }
                }
            }
            return Double(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + min(sec, 59) - off)
        }
        return t.map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: schrijven

    /// `yyyy-MM-ddTHH:mm:ss.SSSZ` (UTC, milliseconden afgerond), zoals ISO8601DateFormatter met fracties.
    static func string(_ t: Double, fraction: Bool = true) -> String {
        let totalMs = Int((t * 1000).rounded())
        let secs = floorDiv(totalMs, 1000)
        let ms = totalMs - secs * 1000
        let days = floorDiv(secs, 86400)
        let rem = secs - days * 86400
        let (y, m, d) = civilFromDays(days)
        var out = [UInt8](repeating: 0, count: fraction ? 24 : 20)
        func put(_ v: Int, _ at: Int, _ width: Int) {
            var v = v
            for k in stride(from: at + width - 1, through: at, by: -1) { out[k] = UInt8(48 + v % 10); v /= 10 }
        }
        put(max(0, min(9999, y)), 0, 4); out[4] = 45; put(m, 5, 2); out[7] = 45; put(d, 8, 2); out[10] = 84
        put(rem / 3600, 11, 2); out[13] = 58; put(rem / 60 % 60, 14, 2); out[16] = 58; put(rem % 60, 17, 2)
        if fraction { out[19] = 46; put(ms, 20, 3); out[23] = 90 } else { out[19] = 90 }
        return String(decoding: out, as: UTF8.self)
    }

    static func string(_ d: Date, fraction: Bool = true) -> String { string(d.timeIntervalSince1970, fraction: fraction) }

    // MARK: intern

    private static func parse(_ b: UnsafeBufferPointer<UInt8>, defaultUTC: Bool) -> Double? {
        var i = 0, n = b.count
        while i < n, b[i] == 32 { i += 1 }
        while n > i, b[n - 1] == 32 { n -= 1 }
        guard let y = num(b, &i, 4), lit(b, &i, 45), let mo = num(b, &i, 2), lit(b, &i, 45), let d = num(b, &i, 2) else { return nil }
        guard i < n, b[i] == 84 || b[i] == 116 || b[i] == 32 else { return nil }   // T, t of spatie
        i += 1
        guard let h = num(b, &i, 2), lit(b, &i, 58), let mi = num(b, &i, 2) else { return nil }
        var sec = 0
        if i < n, b[i] == 58 {
            i += 1
            guard let v = num(b, &i, 2) else { return nil }
            sec = v
        }
        var frac = 0.0
        if i < n, b[i] == 46 || b[i] == 44 {
            i += 1
            var scale = 0.1, any = false
            while i < n, isDigit(b[i]) {
                frac += Double(b[i] - 48) * scale
                scale *= 0.1; i += 1; any = true
            }
            guard any else { return nil }
        }
        var off = 0
        if i == n {
            guard defaultUTC else { return nil }
        } else if b[i] == 90 || b[i] == 122 {   // Z
            i += 1
        } else if b[i] == 43 || b[i] == 45 {
            let sign = b[i] == 45 ? -1 : 1
            i += 1
            guard let oh = num(b, &i, 2) else { return nil }
            var om = 0
            if i < n {
                if b[i] == 58 { i += 1 }
                guard let v = num(b, &i, 2) else { return nil }
                om = v
            }
            guard oh <= 23, om <= 59 else { return nil }
            off = sign * (oh * 3600 + om * 60)
        } else { return nil }
        guard i == n, validDate(y, mo, d), h <= 23, mi <= 59, sec <= 59 else { return nil }
        return Double(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - off) + frac
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    @inline(__always) private static func lit(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ c: UInt8) -> Bool {
        guard i < b.count, b[i] == c else { return false }
        i += 1
        return true
    }

    @inline(__always) private static func num(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ count: Int) -> Int? {
        guard i + count <= b.count else { return nil }
        var v = 0
        for k in i..<(i + count) {
            let c = b[k]
            guard isDigit(c) else { return nil }
            v = v * 10 + Int(c - 48)
        }
        i += count
        return v
    }

    private static func validDate(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        guard (1...12).contains(m), d >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let len = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= len
    }

    @inline(__always) private static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : (a - b + 1) / b }

    /// Dagen sinds 1970-01-01 (proleptisch gregoriaans; H. Hinnant)
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Build 149: gedeelde opmakers voor wat geen ISO-8601 is (één per formaat, nooit per aanroep).
/// DateFormatter is thread-veilig sinds iOS 7 / macOS 10.9; het slot houdt de cache zelf veilig.
enum SharedFormatters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    /// POSIX-opmaker met vast patroon (`dateFormat`), per patroon + tijdzone één keer gemaakt.
    static func posix(_ format: String, timeZone: TimeZone = .current) -> DateFormatter {
        let key = "p|\(format)|\(timeZone.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        cache[key] = f
        return f
    }

    /// Opmaker met datum- en tijdstijl in een taal (UI), per taal + stijlen één keer gemaakt.
    static func styled(locale: Locale, date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let key = "s|\(locale.identifier)|\(date.rawValue)|\(time.rawValue)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = date
        f.timeStyle = time
        cache[key] = f
        return f
    }
}

// MARK: - Ontdek categorieën (Home)

/// Build 149 (vanaf build 150 alleen nog voor titels, zie `CategoryName.clean` in Build150.swift): categorienaam van de server opschonen voor de rij "Ontdek categorieën":
/// voorvoegsels als "NL | ", "|EN| ", "[NL] ", "4K - ", "VOD: " en kwaliteitslabels eraf, "Netflix" blijft "Netflix".
extension CategoryName {
    private static let legacyTags: Set<String> = ["4k", "uhd", "fhd", "hd", "sd", "hevc", "h265", "vod", "vip", "multi", "multisub",
                                            "nl", "be", "en", "uk", "us", "de", "fr", "es", "it", "tr", "pl", "pt", "ar", "nld", "eng",
                                            "ex", "exyu", "fhd/hd", "hd/fhd", "movies", "series"]
    private static let legacySeparators: Set<Character> = ["|", "-", ":", "•", "·", "/", "_", "–", "—", "»", "▶", "★", "*", "#"]

    /// `title`: voor titels voorzichtiger: alleen labels in hoofdletters ("NL | ", "4K - ", "[NL]"), zodat
    /// "Ex-Machina" en "(500) Days of Summer" heel blijven.
    static func legacyClean(_ raw: String, title: Bool = false) -> String {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // voorvoegsels, zo vaak als nodig ("NL | 4K - Netflix")
        for _ in 0..<4 {
            let before = s
            s = s.drop { $0 == " " || legacySeparators.contains($0) }
            if let open = s.first, open == "[" || open == "(" || open == "{",
               let close = s.firstIndex(of: open == "[" ? "]" : open == "(" ? ")" : "}"), s.distance(from: s.startIndex, to: close) <= 12,
               !title || legacyIsLabel(s[s.index(after: s.startIndex)..<close]) {
                s = s[s.index(after: close)...]
                continue
            }
            // eerste woord tot een scheidingsteken
            if let sep = s.firstIndex(where: { legacySeparators.contains($0) }) {
                let head = s[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                let rawHead = s[..<sep].trimmingCharacters(in: .whitespaces)
                let titleOK = !title || (rawHead == rawHead.uppercased() && (s[sep] == "|" || s[sep] == ":" || s.index(after: sep) == s.endIndex || s[s.index(after: sep)] == " "))
                if titleOK, !head.isEmpty, head.count <= 8, legacyTags.contains(head) || head.split(separator: " ").allSatisfy({ legacyTags.contains(String($0)) }) {
                    s = s[s.index(after: sep)...]
                    continue
                }
            }
            if s == before { break }
        }
        var out = String(s).trimmingCharacters(in: .whitespaces)
        // achteraan: " 4K", " (NL)", " [HD]", " - NL"
        for _ in 0..<3 {
            let words = out.split(separator: " ")
            guard words.count > 1, let last = words.last else { break }
            let rawW = last.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}|-"))
            let w = rawW.lowercased()
            guard legacyTags.contains(w), !title || rawW == rawW.uppercased() else { break }
            out = words.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
        }
        return out.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : out
    }

    /// Inhoud tussen haakjes is een label ("NL", "4K", "EN"): een bekend label in hoofdletters
    private static func legacyIsLabel(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t == t.uppercased() && legacyTags.contains(t.lowercased())
    }
}

/// Build 149: categorie → streamingdienst van TMDB (`/watch/providers`, `provider_name`), voor het logo in de balk.
/// Alleen een duidelijke match; anders nil (dan de naam als tekst).
enum ProviderMatch {
    /// Ingekorte naam → TMDB-namen (zoals TMDB ze in NL noemt; build 150: meer dan één, TMDB hernoemt diensten soms)
    static let aliases: [String: [String]] = [
        "hbo": ["HBO Max", "Max"], "hbomax": ["HBO Max", "Max"], "max": ["HBO Max", "Max"],
        "prime": ["Amazon Prime Video", "Prime Video", "Amazon Video"], "primevideo": ["Amazon Prime Video", "Prime Video"],
        "amazon": ["Amazon Prime Video", "Prime Video", "Amazon Video"], "amazonprime": ["Amazon Prime Video", "Prime Video"],
        "amazonprimevideo": ["Amazon Prime Video", "Prime Video"],
        "disney": ["Disney Plus", "Disney+"], "disneyplus": ["Disney Plus", "Disney+"],
        "skyshowtime": ["SkyShowtime", "Sky Showtime"], "netflix": ["Netflix", "Netflix basic with Ads", "Netflix Standard with Ads"],
        "viaplay": ["Viaplay"], "videoland": ["Videoland"],
        "appletv": ["Apple TV+", "Apple TV Plus", "Apple TV"], "appletvplus": ["Apple TV+", "Apple TV Plus", "Apple TV"],
        "paramount": ["Paramount Plus", "Paramount+"], "paramountplus": ["Paramount Plus", "Paramount+"],
        "npo": ["NPO Start", "NPO Plus"], "npostart": ["NPO Start", "NPO Plus"], "npoplus": ["NPO Plus", "NPO Start"],
        "pathethuis": ["Pathé Thuis", "Pathe Thuis"], "canalplus": ["Canal+", "Canal Plus"],
        "vtmgo": ["VTM GO", "VTM Go"], "streamz": ["Streamz"], "discoveryplus": ["Discovery+", "Discovery Plus"],
        "mubi": ["MUBI", "Mubi"], "dazn": ["DAZN"], "nlziet": ["NLZIET", "NLZiet"], "kijk": ["KIJK", "Kijk"],
    ]

    /// Eerste alias die TMDB kent (exact of op sleutel)
    private static func alias(_ k: String, _ providers: [String: String], _ byKey: [String: String]) -> String? {
        for a in aliases[k] ?? [] {
            if providers[a] != nil { return a }
            if let n = byKey[key(a)] { return n }
        }
        return nil
    }

    /// Kleine letters en cijfers; "+" telt als "plus"
    static func key(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.utf8.count)
        for u in s.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            if u == "+" { out += "plus" }
            else if ("a"..."z").contains(u) || ("0"..."9").contains(u) { out.unicodeScalars.append(u) }
        }
        return out
    }

    /// `providers`: TMDB-naam → logo-pad. Geeft de TMDB-naam terug.
    static func match(_ category: String, providers: [String: String]) -> String? {
        guard !providers.isEmpty else { return nil }
        let k = key(CategoryName.clean(category))
        guard k.count >= 3 else { return nil }
        var byKey: [String: String] = [:]
        for name in providers.keys { byKey[key(name)] = name }
        if let n = byKey[k] { return n }
        if let a = alias(k, providers, byKey) { return a }
        // "Netflix Films", "Disney+ Series": de categorie begint met de dienst (langste eerst)
        let words = CategoryName.clean(category).lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "|" })
        for n in stride(from: min(3, words.count), through: 1, by: -1) {
            let head = key(words.prefix(n).joined())
            guard head.count >= 3 else { continue }
            if let name = byKey[head] { return name }
            if let a = alias(head, providers, byKey) { return a }
        }
        return nil
    }

    /// Vaste kleur uit de palet op naam (zelfde naam = zelfde kleur)
    static func paletteIndex(_ name: String, count: Int) -> Int {
        var h: UInt32 = 5381
        for u in name.unicodeScalars { h = (h &* 33) &+ u.value }
        return Int(h % UInt32(max(1, count)))
    }
}

// MARK: - Bewaren in stukken

/// Build 149: een JSON-object met grote lijsten in stukken naar een bestand schrijven, zonder de hele JSON eerst als
/// één `Data` in het geheugen te bouwen (bij 123k films ging het geheugen bij bewaren van 945 MB naar 1,7 GB).
/// De uitkomst is precies wat `JSONEncoder` van het hele object maakt (zelfde sleutels en waarden), dus lezen werkt
/// ongewijzigd. Atomisch: eerst een tijdelijk bestand, daarna verwisselen.
final class ChunkedJSONWriter {
    private let handle: FileHandle
    private let tmp: URL
    private let target: URL
    private let encoder: JSONEncoder
    private var first = true
    private(set) var bytes = 0
    let chunk: Int

    init(url: URL, encoder: JSONEncoder = JSONEncoder(), chunk: Int = 2000) throws {
        target = url
        tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: tmp)
        self.encoder = encoder
        self.chunk = max(1, chunk)
        try put("{")
    }

    private func put(_ s: String) throws { try put(Data(s.utf8)) }
    private func put(_ d: Data) throws { try handle.write(contentsOf: d); bytes += d.count }

    private func key(_ k: String) throws {
        try put((first ? "" : ",") + String(decoding: try encoder.encode(k), as: UTF8.self) + ":")
        first = false
    }

    /// `"key":[…]`, per `chunk` elementen gecodeerd
    func array<T: Encodable>(_ k: String, _ xs: [T]) throws {
        try key(k)
        try put("[")
        var i = 0
        while i < xs.count {
            let j = min(xs.count, i + chunk)
            let d = try Self.pool { try encoder.encode(Array(xs[i..<j])) }
            if i > 0 { try put(",") }
            try put(d.subdata(in: 1..<(d.count - 1)))   // zonder [ ]
            i = j
        }
        try put("]")
    }

    /// `"key":{…}`, per `chunk` sleutels gecodeerd
    func dictionary<V: Encodable>(_ k: String, _ dict: [String: V]) throws {
        try key(k)
        try put("{")
        let keys = Array(dict.keys)
        var i = 0
        while i < keys.count {
            let j = min(keys.count, i + chunk)
            var part: [String: V] = [:]
            part.reserveCapacity(j - i)
            for x in keys[i..<j] { part[x] = dict[x] }
            let d = try Self.pool { try encoder.encode(part) }
            if i > 0 { try put(",") }
            try put(d.subdata(in: 1..<(d.count - 1)))   // zonder { }
            i = j
        }
        try put("}")
    }

    /// Afronden: sluiten en het bestand op zijn plek zetten
    func finish() throws {
        try put("}")
        try handle.close()
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
    }

    /// Afbreken: tijdelijk bestand weg
    func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func pool<R>(_ work: () throws -> R) throws -> R {
        #if canImport(ObjectiveC)
        return try autoreleasepool { try work() }
        #else
        return try work()
        #endif
    }
}

// MARK: - Native strings

extension String {
    /// Build 149: als native UTF-8-string (geen overbrugde NSString). Uitkomsten van `folding`, `lowercased` op
    /// Foundation-strings en NSRegularExpression zijn vaak overbrugd; teken voor teken doorlopen kostte daardoor
    /// seconden over tienduizenden titels (`_foreignIndex`). Eén keer omzetten is goedkoop.
    var nativeUTF8: String {
        var s = self
        s.makeContiguousUTF8()
        return s
    }
}

// MARK: - Zoeken (punt 7)

/// Build 149: zoeken op woorden in plaats van de letterlijke zin. Zoekterm en titel worden op dezelfde manier
/// genormaliseerd (hoofdletters, accenten, leestekens, `&` = `and`, voorvoegsels als "NL |", "4K -", "[NL]",
/// jaartal tussen haakjes apart); elk woord moet voorkomen, in willekeurige volgorde, als woordbegin of als deel
/// van een woord. Woorden van 5+ letters mogen één typefout hebben.
enum SearchMatch {
    struct Query: Sendable {
        let full: String        // genormaliseerd, woorden met één spatie
        let words: [String]     // zonder "and"
        let year: Int?
        var isEmpty: Bool { words.isEmpty && year == nil }
    }

    /// Genormaliseerde titel: woorden met één spatie, en het jaar tussen haakjes apart
    static func normalize(_ raw: String) -> (text: String, year: Int?) {
        var s = CategoryName.clean(raw, title: true)
        var year: Int?
        // "(2022)" of "[2022]" apart
        if s.contains("(") || s.contains("["), let r = s.range(of: #"[\(\[]\s*(19|20)\d{2}\s*[\)\]]"#, options: .regularExpression) {
            year = Int(s[r].filter(\.isNumber))
            s.removeSubrange(r)
        }
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased().nativeUTF8
        var out = ""
        out.reserveCapacity(folded.utf8.count + 4)
        var space = true
        for ch in folded {
            if ch == "+" {
                if !space { out.append(" ") }
                out += "plus "
                space = true
            } else if ch.isLetter || ch.isNumber {
                out.append(ch); space = false
            } else if ch == "'" || ch == "’" {
                continue   // "Schindler's" = "schindlers"
            } else if !space {
                out.append(" "); space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        // "&" en "and" tellen niet mee ("Fast & Furious" = "Fast and Furious" = "fast furious")
        let words = out.split(separator: " ").filter { $0 != "and" }
        return (words.isEmpty ? out : words.joined(separator: " "), year)
    }

    static func query(_ q: String) -> Query {
        let n = normalize(q)
        var words = n.text.split(separator: " ").map(String.init).filter { $0 != "and" }
        var year = n.year
        // los jaartal in de zoekterm ("batman 2022") telt ook als jaar, maar blijft ook een woord (titels als "1917")
        if year == nil, let last = words.last, last.count == 4, let y = Int(last), (1900...2099).contains(y), words.count > 1 { year = y; words.removeLast() }
        return Query(full: words.joined(separator: " "), words: words, year: year)
    }

    /// Score: exacte titel 1000, begint met 800, alle woorden als woordbegin 600, alle woorden erin 400,
    /// met één typefout 200; nil = geen treffer. `text` = `normalize(titel).text` (vooraf berekend).
    static func score(_ q: Query, text: String, year: Int? = nil) -> Int? {
        guard !q.words.isEmpty else { return nil }
        var base: Int
        if text == q.full {
            base = 1000
        } else if text.hasPrefix(q.full) && (text.count == q.full.count || text.dropFirst(q.full.count).first == " ") {
            base = 800
        } else if text.hasPrefix(q.full) {
            base = 750
        } else {
            let tw = text.split(separator: " ")
            var allPrefix = true, allContained = true, typos = 0
            for w in q.words {
                if tw.contains(where: { $0.hasPrefix(w) }) { continue }
                allPrefix = false
                if text.contains(w) { continue }
                allContained = false
                if w.count >= 5, typos == 0, tw.contains(where: { oneEdit(w, $0) }) { typos += 1; continue }
                return nil
            }
            base = allPrefix ? 600 : (allContained ? 400 : 200)
        }
        if let qy = q.year, let y = year {
            if qy == y { base += 50 } else { base -= 100 }
        }
        return base
    }

    /// Hoogstens één bewerking (vervangen, invoegen, weglaten, of twee buren omgewisseld) tussen `a` en `b`
    /// (of het begin van `b` even lang als `a`).
    static func oneEdit(_ a: String, _ b: Substring) -> Bool {
        let x = Array(a.unicodeScalars), full = Array(b.unicodeScalars)
        if abs(x.count - full.count) > 1 && full.count < x.count { return false }
        func within(_ y: [Unicode.Scalar]) -> Bool {
            if abs(x.count - y.count) > 1 { return false }
            var i = 0, j = 0, edits = 0
            while i < x.count && j < y.count {
                if x[i] == y[j] { i += 1; j += 1; continue }
                edits += 1
                if edits > 1 { return false }
                if x.count == y.count {
                    // omwisseling ("bamtan" ↔ "batman"-achtig: buren)
                    if i + 1 < x.count, x[i] == y[j + 1], x[i + 1] == y[j] { i += 2; j += 2; continue }
                    i += 1; j += 1
                } else if x.count > y.count { i += 1 } else { j += 1 }
            }
            return edits + (x.count - i) + (y.count - j) <= 1
        }
        if within(full) { return true }
        // begin van een langer woord ("interstelar" in "interstellarr…")
        if full.count > x.count + 1 {
            return within(Array(full.prefix(x.count))) || within(Array(full.prefix(x.count + 1)))
        }
        return false
    }

    /// Kleine bonus voor recente en populaire titels (max. 40), zodat ze bij gelijke score hoger staan
    static func boost(rating: Double?, added: Date?, now: Date = Date()) -> Int {
        var b = 0
        if let r = rating, r > 0 { b += Int(min(10, r) * 2) }                 // tot 20
        if let a = added { let days = now.timeIntervalSince(a) / 86400; if days < 30 { b += 20 } else if days < 180 { b += 10 } }
        return b
    }
}
