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
