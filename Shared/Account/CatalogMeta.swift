import Foundation

// Build 128: één lijst over alle servers (docs/ACCOUNT.md → "Build 128: één lijst over alle servers").
// Pure logica zonder app-typen (alleen Foundation), zodat tools/selftest/main.swift hem in CI los kan testen:
// sleutels, normaliseren van titels/zenders, de state-section `catalogmeta` (lezen, schrijven, samenvoegen,
// begrenzen), remap-ketens en het koppelen aan de catalogus van een andere server.

// MARK: - Sleutels

enum CatalogKey {
    /// `<server-id kleine letters>|<item-id exact>` (sleutel in `catalogmeta.items`)
    static func make(_ sid: String, _ item: String) -> String { sid.lowercased() + "|" + item }

    /// Opgeslagen sleutel (`<server-id>|<item>`, server-id in welke schrijfwijze dan ook) → vorm van `catalogmeta.items`
    static func normalize(_ key: String) -> String {
        guard let bar = key.firstIndex(of: "|") else { return key }
        return key[..<bar].lowercased() + key[bar...]
    }

    /// Sleutel van een `remap`-regel: de oude sleutel helemaal in kleine letters
    static func remapKey(_ key: String) -> String { key.lowercased() }

    static func split(_ key: String) -> (sid: String, item: String)? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        let sid = String(key[..<bar]), item = String(key[key.index(after: bar)...])
        guard !sid.isEmpty, !item.isEmpty else { return nil }
        return (sid, item)
    }

    static func sameServer(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
}

// MARK: - Normaliseren

enum CatalogNorm {
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased().nativeUTF8   // build 149
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let titlePrefix = re(#"^\s*(\|[^|]{1,12}\||\[[^\]]{1,12}\]|[A-Z]{2,4}\s*[|:]\s*|[A-Z]{2,4}\s+-\s+|[A-Z]{2,3}-(?=[A-Z]))"#)
    private static let episodeMark = re(#"[Ss]\d{1,2}\s*[Ee]\d{1,3}"#)
    private static let yearRE = re(#"(?:^|[\(\[\s\-.])((?:19|20)\d{2})(?:[\)\]]|\s|$)"#)
    private static let brackets = re(#"\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}"#)
    private static let junk = re(#"(?i)\b(4k|8k|uhd|fhd|hd|sd|hevc|h\.?26[45]|x26[45]|1080p|720p|2160p|480p|multi|dual|subs?|nl ?subs?|nl ?gesproken|vost\w*|dolby|atmos|hdr10?\+?|hdr|dv|remux|bluray|web-?dl|webrip)\b"#)
    private static let trailingCode = re(#"\s+-\s+[A-Za-z]{2,3}\s*$"#)

    private static func replace(_ r: NSRegularExpression, _ s: String, _ t: String = "") -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t).nativeUTF8   // build 149
    }

    /// Titel van een film/serie → (genormaliseerd, jaar). "NL | The Batman (2022) [4K]" → ("thebatman", 2022)
    static func title(_ raw: String) -> (norm: String, year: Int?) {
        var s = raw
        for _ in 0..<2 { s = replace(titlePrefix, s) }
        if let m = episodeMark.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            s = String(s[..<r.lowerBound])
        }
        var year: Int?
        let ms = yearRE.matches(in: s, range: NSRange(s.startIndex..., in: s))
        // een titel die alleen uit een jaartal bestaat ("1917") niet leeg maken
        if let m = ms.last, let r = Range(m.range(at: 1), in: s) {
            let rest = s.replacingCharacters(in: r, with: "")
            if rest.contains(where: { $0.isLetter || $0.isNumber }) {
                year = Int(s[r])
                s = rest
            }
        }
        s = replace(brackets, s, " ")
        s = replace(trailingCode, s, " ")
        s = replace(junk, s, " ")
        let n = fold(s).filter { $0.isLetter || $0.isNumber }
        return (n.isEmpty ? fold(raw).filter { $0.isLetter || $0.isNumber } : n, year)
    }

    private static let qualityTags: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "8k", "hq", "lq", "hdr", "hevc", "h264", "h265", "x264", "x265",
        "1080", "1080p", "1080i", "720", "720p", "576p", "2160p", "50fps", "60fps", "25fps", "fps", "raw", "backup"
    ]
    private static let countryCodes: Set<String> = [
        "nl", "be", "de", "uk", "gb", "us", "fr", "es", "it", "pt", "tr", "pl", "ar", "ca", "au", "ie", "at", "ch",
        "dk", "se", "no", "fi", "ru", "ro", "gr", "al", "rs", "hr", "ba", "ex", "yu", "vl", "fl", "int", "eu"
    ]
    private static let channelPrefix = re(#"^\s*(\|[^|]{1,6}\||\[[^\]]{1,6}\]|\([A-Za-z]{2,4}\)|[A-Za-z]{2,4}\s*[|:]|[A-Za-z]{2,3}\s+-\s+)\s*"#)

    /// Zendernaam → genormaliseerd. "NL: NPO 1 FHD", "|NL| NPO1 HD", "NPO 1 (4K)" → "npo1"
    static func channel(_ raw: String) -> String {
        var s = raw
        for _ in 0..<2 { s = replace(channelPrefix, s) }
        s = fold(s)
        let cleaned = String(s.map { $0.isLetter || $0.isNumber || $0 == "+" ? $0 : " " })
        var w = cleaned.split(separator: " ").map(String.init).filter { !qualityTags.contains($0) }
        if w.count > 1, let last = w.last, countryCodes.contains(last) { w.removeLast() }
        let out = w.joined()
        return out.isEmpty ? fold(raw).filter { $0.isLetter || $0.isNumber } : out
    }

    static func epg(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// "S1:E2 · …", "S01E02", "S1 E2" → (1, 2)
    private static let seasonEpisode = re(#"[Ss](\d{1,2})\s*[:.\-]?\s*[A-Za-z]{0,3}\s*(\d{1,3})"#)
    static func seasonEpisode(_ s: String?) -> (season: Int, episode: Int)? {
        guard let s, let m = seasonEpisode.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
              let x = Int(s[a]), let y = Int(s[b]) else { return nil }
        return (x, y)
    }
}

// MARK: - Tijd

enum CatalogTime {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let lock = NSLock()

    static func iso(_ t: Double) -> String { FastISO.string(t) }   // build 149: zonder opmaker en slot

    /// ISO-8601 of een getal (seconden of milliseconden) → seconden sinds 1970
    static func parse(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d > 100_000_000_000 ? d / 1000 : d
        }
        guard let s = v as? String, !s.isEmpty else { return nil }
        if let t = FastISO.seconds(s) { return t }   // build 149
        lock.lock(); defer { lock.unlock() }
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d.timeIntervalSince1970 }
        if let d = Double(s) { return d > 100_000_000_000 ? d / 1000 : d }
        return nil
    }
}

// MARK: - catalogmeta

struct CatalogMeta: Equatable {
    enum Kind: String { case movie, series, episode, channel }

    struct EpisodeRef: Equatable {
        var series: String
        var seriesTitle: String?
        var season: Int
        var episode: Int
    }

    struct ChannelRef: Equatable {
        var name: String
        var epg: String?
    }

    struct Item: Equatable {
        var title: String
        var year: Int?
        var kind: Kind
        var tmdb: Int?
        var image: String?
        var sid: String
        var serverName: String?
        var ep: EpisodeRef?
        var ch: ChannelRef?
        var at: Double

        /// Zelfde inhoud (zonder `at`): dan hoeft er niets opnieuw geschreven te worden
        func sameContent(_ o: Item) -> Bool {
            var a = self, b = o
            a.at = 0; b.at = 0
            return a == b
        }
    }

    struct Remap: Equatable {
        var to: String
        var at: Double
    }

    var items: [String: Item] = [:]
    var remap: [String: Remap] = [:]
    var updatedAt: Double = 0
    /// Onbekende velden op het hoogste niveau (gaan onaangeroerd terug)
    var extras: [String: String] = [:]

    static let itemLifetime: Double = 90 * 86400
    static let remapLifetime: Double = 180 * 86400
    static let maxItems = 6000
    /// De server weigert boven 1 MB (JSON-tekst); ruim eronder blijven
    static let maxBytes = 900_000
    static let maxChain = 10

    // MARK: lezen en schrijven (JSON)

    init() {}

    init(json: Any?) {
        guard let j = json as? [String: Any] else { return }
        updatedAt = CatalogTime.parse(j["updatedAt"]) ?? 0
        for (k, v) in j["items"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any], let item = Self.item(d, key: k) else { continue }
            let key = CatalogKey.normalize(k)
            if let old = items[key], old.at >= item.at { continue }
            items[key] = item
        }
        for (k, v) in j["remap"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any], let to = Self.str(d["to"]) else { continue }
            let key = CatalogKey.remapKey(k)
            let r = Remap(to: to, at: CatalogTime.parse(d["at"]) ?? 0)
            if let old = remap[key], old.at >= r.at { continue }
            remap[key] = r
        }
        for (k, v) in j where !["items", "remap", "updatedAt"].contains(k) {
            if JSONSerialization.isValidJSONObject([v]),
               let d = try? JSONSerialization.data(withJSONObject: [v]), let s = String(data: d, encoding: .utf8) {
                extras[k] = s
            }
        }
    }

    func json() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, s) in extras {
            if let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [Any], let v = arr.first {
                out[k] = v
            }
        }
        out["items"] = items.mapValues(Self.itemJSON)
        out["remap"] = remap.mapValues { ["to": $0.to, "at": CatalogTime.iso($0.at)] as [String: Any] }
        out["updatedAt"] = CatalogTime.iso(updatedAt)
        return out
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func item(_ d: [String: Any], key: String) -> Item? {
        guard let kind = (d["k"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let sid = str(d["sid"]) ?? CatalogKey.split(key)?.sid ?? ""
        var ep: EpisodeRef?
        if let e = d["ep"] as? [String: Any], let s = int(e["s"]), let n = int(e["e"]) {
            ep = EpisodeRef(series: str(e["series"]) ?? "", seriesTitle: e["st"] as? String, season: s, episode: n)
        }
        var ch: ChannelRef?
        if let c = d["ch"] as? [String: Any] {
            ch = ChannelRef(name: c["name"] as? String ?? (d["t"] as? String ?? ""), epg: str(c["epg"]))
        }
        return Item(title: d["t"] as? String ?? "", year: int(d["y"]), kind: kind, tmdb: int(d["tmdb"]),
                    image: str(d["img"]), sid: sid, serverName: d["sname"] as? String, ep: ep, ch: ch,
                    at: CatalogTime.parse(d["at"]) ?? 0)
    }

    private static func itemJSON(_ i: Item) -> [String: Any] {
        func orNull(_ v: Any?) -> Any { v ?? NSNull() }
        var d: [String: Any] = ["t": i.title, "y": orNull(i.year), "k": i.kind.rawValue, "tmdb": orNull(i.tmdb),
                                "img": orNull(i.image), "sid": i.sid, "sname": orNull(i.serverName),
                                "at": CatalogTime.iso(i.at)]
        if let e = i.ep {
            d["ep"] = ["series": e.series, "st": orNull(e.seriesTitle), "s": e.season, "e": e.episode] as [String: Any]
        } else { d["ep"] = NSNull() }
        if let c = i.ch { d["ch"] = ["name": c.name, "epg": orNull(c.epg)] as [String: Any] } else { d["ch"] = NSNull() }
        return d
    }

    // MARK: opzoeken

    func item(forKey key: String) -> Item? {
        let n = CatalogKey.normalize(key)
        if let i = items[n] { return i }
        let lower = key.lowercased()
        return items.first { $0.key.lowercased() == lower }?.value
    }

    /// Eindpunt van de remap-keten voor deze sleutel (nil = geen remap). Lussen: nil.
    func resolve(_ key: String) -> String? {
        var current = key
        var seen: Set<String> = [CatalogKey.remapKey(key)]
        var steps = 0
        while let r = remap[CatalogKey.remapKey(current)] {
            steps += 1
            let next = CatalogKey.remapKey(r.to)
            if seen.contains(next) || steps > Self.maxChain { return nil }   // lus of te lang: niet toepassen
            seen.insert(next)
            current = r.to
        }
        return current == key ? nil : current
    }

    /// Nieuwe remap-regel; geweigerd als hij een lus zou maken. Geeft true als de regel er (nu) staat.
    @discardableResult
    mutating func addRemap(from: String, to: String, at: Double) -> Bool {
        let f = CatalogKey.remapKey(from)
        guard f != CatalogKey.remapKey(to) else { return false }
        // leidt `to` (via bestaande regels) terug naar `from`? Dan niet.
        var probe = self
        probe.remap[f] = nil
        var cur = to
        var steps = 0
        while let r = probe.remap[CatalogKey.remapKey(cur)], steps <= Self.maxChain {
            if CatalogKey.remapKey(r.to) == f { return false }
            cur = r.to; steps += 1
        }
        if let old = remap[f], old.to == to { return true }
        remap[f] = Remap(to: to, at: at)
        updatedAt = max(updatedAt, at)
        return true
    }

    /// Meta zetten als die ontbreekt of anders is (geeft true bij een wijziging)
    @discardableResult
    mutating func set(_ key: String, _ item: Item) -> Bool {
        let k = CatalogKey.normalize(key)
        if let old = items[k], old.sameContent(item) { return false }
        items[k] = item
        updatedAt = max(updatedAt, item.at)
        return true
    }

    // MARK: samenvoegen en begrenzen

    /// Per sleutel (items en remap apart) wint de nieuwste `at`.
    static func merge(_ a: CatalogMeta, _ b: CatalogMeta) -> CatalogMeta {
        var out = a
        for (k, v) in b.items {
            if let old = out.items[k], old.at >= v.at { continue }
            out.items[k] = v
        }
        for (k, v) in b.remap {
            if let old = out.remap[k], old.at >= v.at { continue }
            out.remap[k] = v
        }
        for (k, v) in b.extras where out.extras[k] == nil { out.extras[k] = v }
        out.updatedAt = max(a.updatedAt, b.updatedAt)
        // een samengevoegde regel mag geen lus geven: de oudste regel van een lus valt weg
        out.dropLoops()
        return out
    }

    mutating func dropLoops() {
        for k in remap.keys.sorted() where remap[k] != nil {
            if resolve(k) == nil, remap[k] != nil {
                // lus: de oudste regel in de lus weghalen
                var chain: [String] = [k]
                var cur = k
                while let r = remap[cur], chain.count <= Self.maxChain + 1 {
                    let n = CatalogKey.remapKey(r.to)
                    if chain.contains(n) { break }
                    chain.append(n); cur = n
                }
                if let oldest = chain.compactMap({ c in remap[c].map { (c, $0.at) } }).min(by: { $0.1 < $1.1 }) {
                    remap[oldest.0] = nil
                }
            }
        }
    }

    /// Opruimen: items waarnaar niet verwezen wordt en ouder dan 90 dagen weg, remap ouder dan 180 dagen weg,
    /// hooguit 6000 items en onder ~900 KB. `referenced` in de vorm van `CatalogKey.normalize`.
    mutating func prune(referenced: Set<String>, now: Double, maxBytes: Int = CatalogMeta.maxBytes) {
        let ref = Set(referenced.map(CatalogKey.normalize))
        items = items.filter { ref.contains($0.key) || now - $0.value.at < Self.itemLifetime }
        remap = remap.filter { now - $0.value.at < Self.remapLifetime }
        if items.count > Self.maxItems {
            let order = items.sorted { a, b in
                let ra = ref.contains(a.key), rb = ref.contains(b.key)
                if ra != rb { return !ra }   // eerst wat niet verwezen wordt
                return a.value.at < b.value.at
            }
            for (k, _) in order.prefix(items.count - Self.maxItems) { items[k] = nil }
        }
        // grootte: steeds de oudste 10% (eerst niet verwezen) weg tot het past
        var guardCount = 0
        while guardCount < 40, let size = encodedSize(), size > maxBytes, !items.isEmpty {
            guardCount += 1
            let order = items.sorted { a, b in
                let ra = ref.contains(a.key), rb = ref.contains(b.key)
                if ra != rb { return !ra }
                return a.value.at < b.value.at
            }
            for (k, _) in order.prefix(max(1, items.count / 10)) { items[k] = nil }
        }
    }

    func encodedSize() -> Int? {
        let j = json()
        guard JSONSerialization.isValidJSONObject(j), let d = try? JSONSerialization.data(withJSONObject: j) else { return nil }
        return d.count
    }
}

// MARK: - Remap op lijsten (pure functies op sleutels)

enum CatalogRemap {
    /// Sleutel in de vorm die de app schrijft: een server-id die een UUID is in hoofdletters (zoals iOS altijd deed)
    static func appForm(_ key: String) -> String {
        guard let (sid, item) = CatalogKey.split(key), let u = UUID(uuidString: sid) else { return key }
        return u.uuidString + "|" + item
    }

    /// Set (Mijn lijst, favorieten): oude sleutels → nieuwe. Geeft de nieuwe set en de wijzigingen (oud, nieuw).
    static func set(_ s: Set<String>, _ meta: CatalogMeta) -> (Set<String>, [(String, String)]) {
        var out = s
        var changes: [(String, String)] = []
        for k in s {
            guard let to = meta.resolve(k) else { continue }
            let n = appForm(to)
            out.remove(k)
            if !out.contains(where: { CatalogKey.normalize($0) == CatalogKey.normalize(n) }) { out.insert(n) }
            changes.append((k, n))
        }
        return (out, changes)
    }

    /// Geordende lijst (recente zenders): op dezelfde plek, zonder dubbele.
    static func list(_ l: [String], _ meta: CatalogMeta) -> ([String], [(String, String)]) {
        var out: [String] = []
        var seen = Set<String>()
        var changes: [(String, String)] = []
        for k in l {
            var n = k
            if let to = meta.resolve(k) { n = appForm(to); changes.append((k, n)) }
            if seen.insert(CatalogKey.normalize(n)).inserted { out.append(n) }
        }
        return (out, changes)
    }
}

// MARK: - Koppelen aan een catalogus

/// Lichte index van één server (alleen wat nodig is om te koppelen), op de achtergrond gebouwd.
struct CatalogIndex: Sendable {
    struct Entry: Sendable, Equatable {
        var id: String
        var kind: CatalogMeta.Kind
        var norm: String
        var year: Int?
        var tmdb: Int?
    }
    struct ChannelEntry: Sendable, Equatable {
        var id: String
        var norm: String
        var epg: String?
    }

    private(set) var byTMDB: [String: String] = [:]          // "<kind>|<tmdb>" → id
    private(set) var byNorm: [String: [Entry]] = [:]         // "<kind>|<norm>" → kandidaten
    private(set) var channelsByEPG: [String: String] = [:]
    private(set) var channelsByNorm: [String: String] = [:]

    init(titles: [Entry], channels: [ChannelEntry]) {
        for e in titles {
            if let t = e.tmdb, byTMDB["\(e.kind.rawValue)|\(t)"] == nil { byTMDB["\(e.kind.rawValue)|\(t)"] = e.id }
            guard e.norm.count > 1 else { continue }
            byNorm["\(e.kind.rawValue)|\(e.norm)", default: []].append(e)
        }
        for c in channels {
            if let epg = c.epg, channelsByEPG[epg] == nil { channelsByEPG[epg] = c.id }
            if !c.norm.isEmpty, channelsByNorm[c.norm] == nil { channelsByNorm[c.norm] = c.id }
        }
    }

    var isEmpty: Bool { byNorm.isEmpty && byTMDB.isEmpty && channelsByNorm.isEmpty && channelsByEPG.isEmpty }

    /// Film of serie: TMDB-id, anders genormaliseerde titel + jaar (±1; jaar onbekend = alleen de titel,
    /// met voorkeur voor een exact jaar).
    func title(kind: CatalogMeta.Kind, title: String, year: Int?, tmdb: Int?) -> String? {
        if let tmdb, let id = byTMDB["\(kind.rawValue)|\(tmdb)"] { return id }
        let parsed = CatalogNorm.title(title)
        let y = year ?? parsed.year
        guard let list = byNorm["\(kind.rawValue)|\(parsed.norm)"], !list.isEmpty else { return nil }
        if let y {
            if let e = list.first(where: { $0.year == y }) { return e.id }
            if let e = list.first(where: { $0.year.map { abs($0 - y) <= 1 } ?? false }) { return e.id }
            // treffers zonder jaar mogen ook (de andere kant weet het jaar niet)
            return list.first(where: { $0.year == nil })?.id
        }
        return list.first?.id
    }

    func channel(name: String, epg: String?) -> String? {
        if let e = CatalogNorm.epg(epg), let id = channelsByEPG[e] { return id }
        let n = CatalogNorm.channel(name)
        return n.isEmpty ? nil : channelsByNorm[n]
    }

    /// Een meta-item koppelen. Afleveringen: de serie (de aflevering zelf zoekt de app daarna op s/e).
    func match(_ i: CatalogMeta.Item) -> String? {
        switch i.kind {
        case .movie, .series: return title(kind: i.kind, title: i.title, year: i.year, tmdb: i.tmdb)
        case .episode:
            guard let ep = i.ep else { return nil }
            return title(kind: .series, title: ep.seriesTitle ?? i.title, year: i.year, tmdb: i.tmdb)
        case .channel: return channel(name: i.ch?.name ?? i.title, epg: i.ch?.epg)
        }
    }

    static func entry(id: String, kind: CatalogMeta.Kind, title: String, year: Int?, tmdb: Int?) -> Entry {
        let p = CatalogNorm.title(title)
        return Entry(id: id, kind: kind, norm: p.norm, year: year ?? p.year, tmdb: tmdb)
    }

    static func channelEntry(id: String, name: String, epg: String?) -> ChannelEntry {
        ChannelEntry(id: id, norm: CatalogNorm.channel(name), epg: CatalogNorm.epg(epg))
    }
}

/// Werk-identiteit: dezelfde titel op twee servers = één tegel (TMDB-id, anders genormaliseerde titel + jaar).
enum CatalogIdentity {
    static func title(kind: CatalogMeta.Kind, title: String, year: Int?, tmdb: Int?) -> String {
        if let tmdb { return "\(kind.rawValue)|tmdb:\(tmdb)" }
        let p = CatalogNorm.title(title)
        return "\(kind.rawValue)|\(p.norm)|\(year ?? p.year ?? 0)"
    }
    static func channel(name: String, epg: String?) -> String {
        if let e = CatalogNorm.epg(epg) { return "channel|epg:\(e)" }
        return "channel|" + CatalogNorm.channel(name)
    }
}
