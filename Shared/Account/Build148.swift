import Foundation

// Build 148: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
// Contract: docs/ACCOUNT.md, "Build 148" (diagnose-schema 3).

// MARK: - Codes voor mijlpalen, taken en fasen (schema 3)

enum DiagCode {
    /// Vaste lijst uit het contract (snake_case Engels). Nieuwe codes alleen in deze stijl en altijd melden.
    static let fixed: [String] = [
        "started", "storage", "account", "first_frame", "intro_done", "profile_picker", "profile_picked", "pin_screen",
        "pin_ok", "profile", "servers", "home", "catalog", "ready", "fetch", "parse", "index", "apply", "save",
        "sync_apply", "catalog_filter", "catalog_sort", "catalog_meta", "pin_migrate", "rows_build", "guide_parse",
    ]
    /// Build 148: nieuwe code (gemeld): een hapering tijdens het afspelen
    static let playbackStall = "playback_stall"

    /// Oude (Nederlandse) namen van build 143–147 → code
    static let legacy: [String: String] = [
        "gestart": "started", "opslag": "storage", "account": "account", "eerste frame": "first_frame",
        "intro klaar": "intro_done", "profielkeuze": "profile_picker", "profiel gekozen": "profile_picked",
        "pincodescherm": "pin_screen", "pincode goed": "pin_ok", "profiel": "profile", "servers": "servers",
        "home": "home", "catalogus": "catalog", "klaar": "ready",
        "ophalen open server": "fetch", "ophalen andere server": "fetch", "binnen": "fetch", "ingelezen": "parse",
        "bewaard": "save",
        "catalogus tonen": "apply", "gefilterde catalogus tonen": "apply", "catalogus filteren": "catalog_filter",
        "catalogus sorteren": "catalog_sort", "sync toepassen": "sync_apply", "pin migreren": "pin_migrate",
        "catalogmeta en remap": "catalog_meta", "catalogmeta bijwerken": "catalog_meta",
    ]

    static func isValid(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, s.count <= 40, ("a"..."z").contains(f) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Code van een mijlpaal of taak: een oude naam wordt omgezet, een geldige code blijft; nil = onbruikbaar.
    static func code(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = legacy[n] { return c }
        if isValid(n) { return n }
        let snake = n.replacingOccurrences(of: " ", with: "_")
        return isValid(snake) ? snake : nil
    }

    /// Takenlijst ("catalog_filter, sync_apply") → de eerste geldige code (de laatst begonnen taak)
    static func task(_ list: String?) -> String? {
        guard let list else { return nil }
        for part in list.split(separator: ",") { if let c = code(String(part)) { return c } }
        return nil
    }
}

// MARK: - App-taal (schema 3: `app.lang`)

enum AppLang {
    /// `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$`, ≤ 12; anders "en"
    static func code(_ s: String) -> String {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), s.count <= 12 else { return "en" }
        let base = parts[0]
        guard (2...3).contains(base.count), base.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return "en" }
        if parts.count == 2 {
            let r = parts[1]
            guard (2...8).contains(r.count), r.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return base }
        }
        return s
    }
}

// MARK: - Grote JSON-lijsten in stukken inlezen (Xtream, build 148)

/// Splitst een JSON-lijst (`[a, b, …]`) of een genummerd object (`{"0": a, "1": b}`) in de byte-bereiken van de
/// elementen, zonder de hele lijst als boom in het geheugen op te bouwen. Daarna worden de elementen in stukken
/// gedecodeerd: zo is er nooit meer dan één stuk tegelijk als tussenvorm in het geheugen, en is elke stap kort.
enum JSONChunks {
    /// nil = geen lijst of object (bijv. `false`, `null`, leeg); [] = lege lijst
    static func elementRanges(_ data: Data) -> [Range<Int>]? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>]? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            func ws() { while i < n, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
            /// einde van een waarde vanaf i (diepte 0): positie van de afsluitende , ] of } op het bovenste niveau
            func skipValue() -> Int? {
                var depth = 0
                var inStr = false
                while i < n {
                    let c = b[i]
                    if inStr {
                        if c == 0x5C { i += 2; continue }        // \x
                        if c == 0x22 { inStr = false }
                    } else {
                        switch c {
                        case 0x22: inStr = true
                        case 0x5B, 0x7B: depth += 1
                        case 0x5D, 0x7D:
                            if depth == 0 { return i }
                            depth -= 1
                        case 0x2C: if depth == 0 { return i }
                        default: break
                        }
                    }
                    i += 1
                }
                return nil
            }
            func trimEnd(_ start: Int, _ end: Int) -> Int {
                var e = end
                while e > start, b[e - 1] == 0x20 || b[e - 1] == 0x0A || b[e - 1] == 0x0D || b[e - 1] == 0x09 { e -= 1 }
                return e
            }
            // BOM overslaan
            if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
            ws()
            guard i < n else { return nil }
            var out: [Range<Int>] = []
            if b[i] == 0x5B {                                   // [
                i += 1
                ws()
                if i < n, b[i] == 0x5D { return [] }
                while i < n {
                    ws()
                    let start = i
                    guard let end = skipValue() else { return out.isEmpty ? nil : out }
                    let e = trimEnd(start, end)
                    if e > start { out.append(start..<e) }
                    if b[end] == 0x5D { return out }
                    i = end + 1
                }
                return out
            }
            if b[i] == 0x7B {                                   // {"0": …}
                i += 1
                var keyed: [(Int, Range<Int>)] = []
                while i < n {
                    ws()
                    if i < n, b[i] == 0x7D { break }
                    guard i < n, b[i] == 0x22 else { return nil }
                    let ks = i + 1
                    i += 1
                    while i < n, b[i] != 0x22 { if b[i] == 0x5C { i += 1 }; i += 1 }
                    let key = Int(String(decoding: UnsafeRawBufferPointer(rebasing: raw[ks..<min(i, n)]), as: UTF8.self)) ?? 0
                    i += 1
                    ws()
                    guard i < n, b[i] == 0x3A else { return nil }  // :
                    i += 1
                    ws()
                    let start = i
                    guard let end = skipValue() else { break }
                    let e = trimEnd(start, end)
                    if e > start { keyed.append((key, start..<e)) }
                    if b[end] == 0x7D { break }
                    i = end + 1
                }
                return keyed.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map { $0.element.1 }
            }
            return nil
        }
    }

    /// Element dat mag mislukken zonder de rest mee te nemen.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    struct Stats: Equatable {
        /// Aantal elementen zoals de server ze stuurde
        var elements = 0
        /// Aantal stukken en de langste stap (ms)
        var chunks = 0
        var maxChunkMs = 0.0
    }

    /// Decodeert de lijst in stukken van `chunk` elementen; `each` krijgt per stuk de gelukte items (en mag ze meteen
    /// omzetten naar de lichte modellen). Gooit alleen als de data geen lijst is (zoals de oude `LossyList` dan leeg gaf:
    /// daarom nil = geen lijst).
    @discardableResult
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, chunk: Int = 1500, decoder: JSONDecoder = JSONDecoder(),
                                     each: ([T]) -> Void) -> Stats? {
        guard let ranges = elementRanges(data) else { return nil }
        var st = Stats(elements: ranges.count)
        var start = 0
        var buf = Data()
        while start < ranges.count {
            let t0 = Date()
            let end = min(ranges.count, start + max(1, chunk))
            buf.removeAll(keepingCapacity: true)
            buf.append(0x5B)
            for k in start..<end {
                if k > start { buf.append(0x2C) }
                buf.append(data[ranges[k]])
            }
            buf.append(0x5D)
            let items = autoreleasepool { () -> [T] in
                ((try? decoder.decode([Lossy<T>].self, from: buf)) ?? []).compactMap(\.value)
            }
            each(items)
            st.chunks += 1
            st.maxChunkMs = max(st.maxChunkMs, Date().timeIntervalSince(t0) * 1000)
            start = end
        }
        return st
    }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

// MARK: - Bijwerken per server (schema 3: `updates`)

enum UpdatePhases {
    static let order = ["fetch", "parse", "index", "apply", "save"]
    enum Result: String, Codable { case ok, failed, cancelled }

    struct Phase: Codable, Equatable { var code: String; var ms: Int; var memMB: Int? }
    struct Update: Codable, Equatable {
        /// Server-id op dit apparaat (gaat nooit mee; in de bijlage s1, s2, …)
        var server: String
        var at: Double
        var phases: [Phase] = []
        var totalMs = 0
        var peakMB: Int?
        var result: Result = .ok
    }

    /// Fase toevoegen of optellen (bijv. ophalen van de lijsten + de gids), in de vaste volgorde
    static func add(_ u: inout Update, code: String, ms: Double, memMB: Int?) {
        guard order.contains(code) else { return }
        let m = Int(max(0, ms).rounded())
        if let i = u.phases.firstIndex(where: { $0.code == code }) {
            u.phases[i].ms += m
            if let memMB { u.phases[i].memMB = memMB }
        } else {
            u.phases.append(Phase(code: code, ms: m, memMB: memMB))
            u.phases.sort { (order.firstIndex(of: $0.code) ?? 9) < (order.firstIndex(of: $1.code) ?? 9) }
        }
        if let memMB { u.peakMB = max(u.peakMB ?? 0, memMB) }
    }

    /// Nieuwste eerst, max. `limit` bewaard
    static func push(_ list: inout [Update], _ u: Update, limit: Int = 5) {
        list.insert(u, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
    }

    /// Bijlage: servers als s1, s2, … op volgorde van `servers` (onbekende servers vallen weg), max. 5
    static func rows(_ list: [Update], servers: [String], iso: (Date) -> String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for u in list {
            guard let i = servers.firstIndex(of: u.server), i < 99 else { continue }
            var r: [String: Any] = ["server": "s\(i + 1)", "at": iso(Date(timeIntervalSince1970: u.at)),
                                    "totalMs": min(3_600_000, u.totalMs), "result": u.result.rawValue]
            r["phases"] = u.phases.prefix(5).map { p -> [String: Any] in
                var d: [String: Any] = ["code": p.code, "ms": min(3_600_000, p.ms)]
                if let m = p.memMB { d["memMB"] = min(100_000, m) }
                return d
            }
            if let p = u.peakMB { r["peakMB"] = min(100_000, p) }
            out.append(r)
            if out.count == 5 { break }
        }
        return out
    }
}

// MARK: - Geleverd en zichtbaar (schema 3: `fetch[].delivered/visible/hidden`)

enum HiddenCounts {
    struct Counts: Codable, Equatable { var categories = 0; var kids = 0; var duplicates = 0; var other = 0 }

    /// De rest van het verschil (leeftijd, kinderslot, eigen verborgen titels) telt als `other`; nooit negatief.
    static func make(delivered: Int, visible: Int, categories: Int, kids: Int, duplicates: Int) -> Counts {
        let diff = max(0, delivered - visible)
        let c = min(categories, diff)
        let k = min(kids, diff - c)
        let d = min(duplicates, diff - c - k)
        return Counts(categories: c, kids: k, duplicates: d, other: diff - c - k - d)
    }
}

// MARK: - Haperingen tijdens het afspelen (build 148: `playback_stall`)

/// Volgt de staat van de speler (elke halve seconde) en geeft een hapering terug zodra het beeld na een stilstand weer
/// loopt. Bufferen vóór het eerste beeld telt niet (dat is opstarten).
struct StallTracker {
    enum State { case playing, buffering, other }
    struct Stall: Codable, Equatable {
        /// Seconden na het eerste beeld
        var at: Double
        var ms: Int
    }
    private(set) var started: Double?
    private var stallFrom: Double?

    mutating func tick(_ s: State, now: Double) -> Stall? {
        switch s {
        case .playing:
            if started == nil { started = now; return nil }
            guard let from = stallFrom else { return nil }
            stallFrom = nil
            return Stall(at: ((from - (started ?? from)) * 10).rounded() / 10, ms: Int(((now - from) * 1000).rounded()))
        case .buffering:
            if started != nil, stallFrom == nil { stallFrom = now }
        case .other:
            stallFrom = nil
        }
        return nil
    }
}

// MARK: - Langste hang van deze start (schema 3: `start.longestHang`)

enum LongestHang {
    static func json(seconds: Double, task: String?, milestone: String?, foreground: Bool, stack: [String]) -> [String: Any] {
        var o: [String: Any] = ["ms": Int(min(3_600_000, max(0, seconds * 1000)).rounded()), "foreground": foreground]
        if let t = DiagCode.task(task) { o["task"] = t }
        if let m = milestone.flatMap(DiagCode.code) { o["milestone"] = m }
        if !stack.isEmpty { o["stack"] = Array(stack.prefix(30).map { String($0.prefix(200)) }) }
        return o
    }
}
