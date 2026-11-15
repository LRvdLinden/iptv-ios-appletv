import Foundation

/// Build 178 (versie 1.0.8): terugkijken in de tv-gids (zoals NLZIET). Pure logica, gelijk op alle platforms (Android
/// `Build178Logic.kt`, web `web/js/build178.js`); gedeelde testgevallen: docs/build178_cases.json (tools/selftest).
/// Alleen Foundation: de zelftest compileert dit bestand los van de app.
///
/// - Herkennen per zender: Xtream/Stalker `tv_archive` + `tv_archive_duration` (getal of tekst, dagen of uren),
///   M3U `catchup`, `catchup-type`, `catchup-days`, `catchup-source`, `tvg-rec`, `timeshift`, `tv_archive(_duration)`,
///   ook als standaard op `#EXTM3U`.
/// - De terugkijk-URL: Xtream in de tijdzone van de server (`server_info.timezone`), M3U volgens het catchup-type.
/// - De gids van vroeger: Xtream `get_simple_data_table` (met `has_archive`), samengevoegd met de gewone gids.
enum Build178 {

    // MARK: 1. Herkennen

    /// Dagen uit een duurveld. Boven de 31 zijn het uren (72 = 3 dagen); "72h" / "3d" mag ook. Naar boven afgerond.
    static func days(fromDuration raw: String?) -> Int {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return 0 }
        var hours = false, explicitDays = false
        if s.hasSuffix("h") { hours = true; s.removeLast() }
        else if s.hasSuffix("d") { explicitDays = true; s.removeLast() }
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else { return 0 }
        if hours || (!explicitDays && v > 31) { return Int((v / 24).rounded(.up)) }
        return Int(v.rounded(.up))
    }

    /// Aan/uit-veld: nil = ontbreekt of leeg, anders aan (1, true, yes, on, elk getal ≠ 0) of uit.
    static func flag(_ raw: String?) -> Bool? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "0", "false", "no", "off", "none", "disabled", "null": return false
        case "1", "true", "yes", "on": return true
        default:
            if let d = Double(s) { return d != 0 }
            return true
        }
    }

    /// Xtream `get_live_streams` en Stalker: archief aan met de duur in dagen (of uren); aan zonder duur = 1 dag;
    /// zonder `tv_archive`-veld telt de duur.
    static func xtreamDays(archive: String?, duration: String?) -> Int {
        let d = days(fromDuration: duration)
        switch flag(archive) {
        case false?: return 0
        case true?: return max(d, 1)
        case nil: return d
        }
    }

    /// Stalker-portal: `tv_archive` (of `archive`) en `tv_archive_duration`, die altijd in uren is
    static func stalkerDays(archive: String?, duration: String?) -> Int {
        let d = duration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return xtreamDays(archive: archive, duration: d.isEmpty ? nil : d + "h")
    }

    /// Terugkijken van een M3U-zender
    struct M3UCatchup: Equatable {
        var days: Int
        /// catchup-type in kleine letters ("default", "append", "shift", "flussonic", "xc" …), nil = niet opgegeven
        var type: String?
        /// catchup-source (sjabloon), nil = niet opgegeven
        var source: String?
    }

    /// `attrs`: de attributen van #EXTINF, `header`: die van #EXTM3U (standaard voor alle zenders). Sleutels in kleine
    /// letters. Expliciet uit (catchup="none"/"0", tv_archive="0") op de zender wint van alles.
    static func m3u(attrs a: [String: String], header h: [String: String]) -> M3UCatchup {
        func low(_ d: [String: String]) -> [String: String] {
            var o: [String: String] = [:]
            for (k, v) in d { o[k.lowercased()] = v }
            return o
        }
        let attrs = low(a), header = low(h)
        func val(_ k: String, _ d: [String: String]) -> String? {
            guard let v = d[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let off = M3UCatchup(days: 0, type: nil, source: nil)
        // de zender zelf
        let chType = val("catchup", attrs) ?? val("catchup-type", attrs)
        if let t = chType, flag(t) == false { return off }
        if flag(val("tv_archive", attrs)) == false { return off }
        let durKeys = ["catchup-days", "tv_archive_duration", "tvg-rec", "timeshift"]
        var days = durKeys.lazy.map { Self.days(fromDuration: val($0, attrs)) }.first { $0 > 0 } ?? 0
        var type = chType
        var source = val("catchup-source", attrs)
        let chOn = chType != nil || source != nil || flag(val("tv_archive", attrs)) == true
        // standaard van #EXTM3U
        let hType = val("catchup", header) ?? val("catchup-type", header)
        let headerOff = (hType.map { flag($0) == false } ?? false) || flag(val("tv_archive", header)) == false
        if !headerOff {
            if type == nil { type = hType }
            if source == nil { source = val("catchup-source", header) }
            if days == 0 { days = durKeys.lazy.map { Self.days(fromDuration: val($0, header)) }.first { $0 > 0 } ?? 0 }
        }
        let hOn = !headerOff && (hType != nil || val("catchup-source", header) != nil || flag(val("tv_archive", header)) == true)
        if days == 0 && (chOn || hOn) { days = 1 }
        guard days > 0 else { return off }
        return M3UCatchup(days: days, type: type?.lowercased(), source: source)
    }

    // MARK: 2. Terugkijk-URL

    /// Datum in een tijdzone als losse velden (jaar, maand, dag, uur, minuut, seconde)
    private static func parts(_ t: Double, _ tz: TimeZone) -> [Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: t))
        return [c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
    }

    private static func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// Xtream: `/timeshift/{user}/{pass}/{minuten}/{YYYY-MM-DD:HH-MM}/{id}.ts`, tijd in de tijdzone van de server
    static func xtreamURL(server: String, user: String, pass: String, streamID: String, start: Double, end: Double,
                          timeZone: TimeZone) -> String {
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        let minutes = max(1, Int(((end - start) / 60).rounded(.up)))
        let p = parts(start, timeZone)
        let when = "\(p[0])-\(two(p[1]))-\(two(p[2])):\(two(p[3]))-\(two(p[4]))"
        return "\(base)/timeshift/\(user)/\(pass)/\(minutes)/\(when)/\(streamID).ts"
    }

    /// Xtream-achtige stream-URL (`http://host/live/user/pass/123.ts` of `http://host/user/pass/123`):
    /// (server, gebruiker, wachtwoord, stream-id)
    static func xtreamParts(_ url: String) -> (server: String, user: String, pass: String, id: String)? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let afterScheme = url[schemeEnd.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let server = String(url[..<slash])
        var path = String(afterScheme[slash...])
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        var segs = path.split(separator: "/").map(String.init)
        if segs.count == 4, segs[0].lowercased() == "live" { segs.removeFirst() }
        guard segs.count == 3 else { return nil }
        var id = segs[2]
        if let dot = id.lastIndex(of: ".") { id = String(id[..<dot]) }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return (server, segs[0], segs[1], id)
    }

    /// Datum volgens een opmaak met Y m d H M S (overige tekens blijven staan), in UTC
    private static func format(_ fmt: String, _ t: Double) -> String {
        let p = parts(t, TimeZone(identifier: "UTC")!)
        var out = ""
        for ch in fmt {
            switch ch {
            case "Y": out += "\(p[0])"
            case "m": out += two(p[1])
            case "d": out += two(p[2])
            case "H": out += two(p[3])
            case "M": out += two(p[4])
            case "S": out += two(p[5])
            default: out.append(ch)
            }
        }
        return out
    }

    /// Sjabloon invullen: {utc} {start} ${start} = begin (Unix), {utcend} {end} ${end} = einde, {lutc} {now} ${now}
    /// {timestamp} ${timestamp} = nu, {duration} = seconden, {duration:N} = seconden / N, {offset:N} = (nu − begin) / N,
    /// {Y} {m} {d} {H} {M} {S} = begin in UTC, {utc:FMT} ${start:FMT} {start:FMT} / {utcend:FMT} ${end:FMT} {end:FMT}.
    static func fill(_ template: String, start: Double, end: Double, now: Double) -> String {
        let s = Int(start), e = Int(end), n = Int(now), dur = max(0, e - s)
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            var open = i
            if ch == "$", template.index(after: i) < template.endIndex, template[template.index(after: i)] == "{" {
                open = template.index(after: i)
            } else if ch != "{" {
                out.append(ch); i = template.index(after: i); continue
            }
            guard let close = template[open...].firstIndex(of: "}") else {
                out += template[i...]; break
            }
            let body = String(template[template.index(after: open)..<close])
            let name: String, arg: String?
            if let c = body.firstIndex(of: ":") { name = String(body[..<c]); arg = String(body[body.index(after: c)...]) }
            else { name = body; arg = nil }
            var rep: String?
            switch name.lowercased() {
            case "utc", "start":
                rep = arg.map { format($0, start) } ?? "\(s)"
            case "utcend", "end":
                rep = arg.map { format($0, end) } ?? "\(e)"
            case "lutc", "now", "timestamp":
                rep = arg.map { format($0, now) } ?? "\(n)"
            case "duration":
                let div = arg.flatMap { Int($0) } ?? 1
                rep = "\(div > 0 ? dur / div : dur)"
            case "offset":
                let div = arg.flatMap { Int($0) } ?? 1
                rep = "\(div > 0 ? max(0, n - s) / div : max(0, n - s))"
            default:
                if arg == nil, name.count == 1, "YmdHMS".contains(name) { rep = format(name, start) }
            }
            if let rep { out += rep } else { out += template[i...close] }
            i = template.index(after: close)
        }
        return out
    }

    /// Stream-URL plus een stuk (`?a=b` of `&a=b`): een tweede `?` wordt `&`
    private static func append(_ url: String, _ part: String) -> String {
        guard !part.isEmpty else { return url }
        if part.hasPrefix("?") && url.contains("?") { return url + "&" + part.dropFirst() }
        if part.hasPrefix("&") && !url.contains("?") { return url + "?" + part.dropFirst() }
        return url + part
    }

    /// De terugkijk-URL van een M3U-zender (nil = kan niet). `timeZone`: voor Xtream-achtige URL's.
    static func m3uURL(stream: String, type: String?, source: String?, start: Double, end: Double, now: Double,
                       timeZone: TimeZone) -> String? {
        let t = type?.lowercased() ?? ""
        let src = source?.trimmingCharacters(in: .whitespacesAndNewlines).flatMap { $0.isEmpty ? nil : $0 }
        func xc() -> String? {
            guard let x = xtreamParts(stream) else { return nil }
            return xtreamURL(server: x.server, user: x.user, pass: x.pass, streamID: x.id, start: start, end: end, timeZone: timeZone)
        }
        switch t {
        case "xc":
            return xc()
        case "", "default", "append":
            if let src {
                let filled = fill(src, start: start, end: end, now: now)
                if t != "append" && filled.contains("://") { return filled }
                guard !stream.isEmpty else { return nil }
                return append(stream, filled)
            }
            return xc()
        case "shift", "timeshift":
            guard !stream.isEmpty else { return nil }
            return append(stream, "?utc=\(Int(start))&lutc=\(Int(now))")
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            guard !stream.isEmpty else { return nil }
            var path = stream, query = ""
            if let q = stream.firstIndex(of: "?") { path = String(stream[..<q]); query = String(stream[q...]) }
            guard let slash = path.lastIndex(of: "/") else { return nil }
            let dir = path[...slash], last = String(path[path.index(after: slash)...])
            let s = Int(start), d = max(0, Int(end) - Int(start))
            if last.lowercased() == "mpegts" || last.lowercased().hasSuffix(".ts") {
                return "\(dir)timeshift_abs-\(s).ts\(query)"
            }
            let name = last.lowercased().hasSuffix(".m3u8") ? String(last.dropLast(5)) : (last.isEmpty ? "index" : last)
            return "\(dir)\(name)-\(s)-\(d).m3u8\(query)"
        default:
            return nil
        }
    }

    // MARK: 3. Gids van vroeger (Xtream get_simple_data_table)

    struct TableProgram: Equatable {
        var title: String
        var description: String?
        var start: Double
        var end: Double
        /// has_archive (nil = niet meegestuurd)
        var archive: Bool?
    }

    /// Base64-tekst van Xtream uitpakken; geen geldige base64 of geen leesbare tekst = de tekst zelf
    static func text(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "" }
        if raw.count % 4 == 0, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }),
           let d = Data(base64Encoded: raw), let s = String(data: d, encoding: .utf8),
           !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            return n.stringValue
        default: return nil
        }
    }

    /// Het antwoord van `get_simple_data_table` (of `get_short_epg`): op begintijd gesorteerd, zonder tijden overgeslagen
    static func simpleTable(_ data: Data) -> [TableProgram] {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else { return [] }
        let list: [Any]
        if let a = dict["epg_listings"] as? [Any] { list = a }
        else if let d = dict["epg_listings"] as? [String: Any] { list = Array(d.values) }
        else { return [] }
        var out: [TableProgram] = []
        for case let item as [String: Any] in list {
            guard let s = string(item["start_timestamp"]).flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  let e = string(item["stop_timestamp"] ?? item["end_timestamp"]).flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  e > s else { continue }
            let desc = text(string(item["description"]))
            out.append(TableProgram(title: text(string(item["title"])), description: desc.isEmpty ? nil : desc,
                                    start: s, end: e, archive: flag(string(item["has_archive"]))))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Gids en archief samen: zelfde begin (binnen 2 minuten) = zelfde programma (titel uit de gids, has_archive uit
    /// het archief); de rest van het archief komt erbij. Op begintijd gesorteerd.
    struct Slot: Equatable {
        var title: String
        var start: Double
        var end: Double
        var archive: Bool?
        /// Index in de gids (≥ 0) of in het archief (−1 − index)
        var source: Int
    }

    static func merge(guide: [(title: String, start: Double, end: Double)],
                      archive: [(title: String, start: Double, end: Double, archive: Bool?)]) -> [Slot] {
        var out = guide.enumerated().map { Slot(title: $1.title, start: $1.start, end: $1.end, archive: nil, source: $0) }
        out.sort { $0.start < $1.start }
        let starts = out.map(\.start)
        var extra: [Slot] = []
        for (j, a) in archive.enumerated() {
            // binair zoeken naar het programma in de gids met (bijna) hetzelfde begin
            var lo = 0, hi = starts.count
            while lo < hi { let m = (lo + hi) / 2; if starts[m] < a.start - 120 { lo = m + 1 } else { hi = m } }
            if lo < starts.count, abs(starts[lo] - a.start) <= 120 {
                if a.archive != nil { out[lo].archive = a.archive }
            } else {
                extra.append(Slot(title: a.title, start: a.start, end: a.end, archive: a.archive, source: -1 - j))
            }
        }
        guard !extra.isEmpty else { return out }
        return (out + extra).sorted { $0.start < $1.start }
    }

    // MARK: 4. Gids: wat terug te kijken is, welke dagen, welk venster

    /// Terug te kijken: voorbij, en volgens de server (has_archive) of binnen de termijn van de zender
    static func replayable(start: Double, end: Double, now: Double, catchupDays: Int, archive: Bool?) -> Bool {
        guard end <= now else { return false }
        if let archive { return archive }
        return catchupDays > 0 && start > now - Double(catchupDays) * 86400
    }

    /// Hooguit zoveel dagen terug en vooruit in de dagbalk
    static let maxBack = 14
    static let maxAhead = 7

    /// De dagbalk als offsets (0 = vandaag): terug tot de terugkijktermijn (hooguit 14) ook zonder gids, vooruit alleen
    /// de dagen met gids (hooguit 7)
    static func dayOffsets(maxCatchupDays: Int, futureWithGuide: [Int]) -> [Int] {
        let back = min(max(0, maxCatchupDays), maxBack)
        var out = Array(stride(from: -back, through: 0, by: 1))
        out += Set(futureWithGuide.filter { $0 > 0 && $0 <= maxAhead }).sorted()
        return out
    }

    /// Venster van de gids (XMLTV): programma's die eindigen na nu − `back` dagen en beginnen vóór nu + `ahead` dagen
    static func keep(start: Double, end: Double, now: Double, back: Int, ahead: Int) -> Bool {
        end > now - Double(back) * 86400 && start < now + Double(ahead) * 86400
    }

    /// Diagnose: aantal zenders met terugkijken en het grootste aantal dagen
    static func summary(_ catchupDays: [Int]) -> (channels: Int, days: Int) {
        var n = 0, m = 0
        for d in catchupDays where d > 0 { n += 1; m = max(m, d) }
        return (n, m)
    }
}
