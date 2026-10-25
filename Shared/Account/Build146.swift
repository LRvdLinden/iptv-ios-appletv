import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Build 146: pure logica (alleen Foundation en CommonCrypto), ook los gebouwd in de zelftest van CI
// (tools/selftest/main.swift). Contract: docs/ACCOUNT.md, "Build 146".

// MARK: - Pincode als hash (`pinHash`)

/// `{"alg":"pbkdf2-sha256","iter":100000,"salt":"<base64, 16 bytes>","hash":"<base64, 32 bytes>"}`.
/// PBKDF2-HMAC-SHA256 met CommonCrypto (`CCKeyDerivationPBKDF`); de pincode als ASCII-cijfers precies zoals ingetypt.
/// Lokaal staat alleen de hash (als `string`, vaste volgorde van de sleutels), nooit de pincode zelf.
struct PinHash: Equatable {
    static let alg = "pbkdf2-sha256"
    static let iterations = 100_000
    static let saltBytes = 16
    static let hashBytes = 32
    /// Grenzen bij het lezen (een latere build mag het aantal verhogen)
    static let readableIterations = 10_000...2_000_000

    var iter: Int
    var salt: Data
    var hash: Data

    /// Een geldige pincode: 4 t/m 8 cijfers (ASCII).
    static func isValidPIN(_ pin: String) -> Bool {
        (4...8).contains(pin.utf8.count) && pin.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Geldig pinHash-object van de server (anders nil). Onbekend `alg` of een vreemd aantal iteraties = geen hash.
    init?(json: Any?) {
        guard let o = json as? [String: Any], (o["alg"] as? String) == Self.alg else { return nil }
        let it: Int
        if let n = o["iter"] as? NSNumber { it = n.intValue; guard Double(it) == n.doubleValue else { return nil } }
        else if let s = o["iter"] as? String, let n = Int(s) { it = n }
        else { return nil }
        guard Self.readableIterations.contains(it),
              let s = (o["salt"] as? String).flatMap(Self.base64), (8...64).contains(s.count),
              let h = (o["hash"] as? String).flatMap(Self.base64), h.count == Self.hashBytes else { return nil }
        iter = it
        salt = s
        hash = h
    }

    /// Uit de lokale opslag (de tekst van `string`).
    init?(string: String) {
        guard string.hasPrefix("{"), let d = string.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        self.init(json: o)
    }

    init(iter: Int, salt: Data, hash: Data) {
        self.iter = iter
        self.salt = salt
        self.hash = hash
    }

    /// Voor de server (`pinHash`).
    var json: [String: Any] {
        ["alg": Self.alg, "iter": iter, "salt": salt.base64EncodedString(), "hash": hash.base64EncodedString()]
    }

    /// Voor de lokale opslag: altijd dezelfde tekst voor dezelfde hash.
    var string: String {
        "{\"alg\":\"\(Self.alg)\",\"iter\":\(iter),\"salt\":\"\(salt.base64EncodedString())\",\"hash\":\"\(hash.base64EncodedString())\"}"
    }

    /// Nieuwe hash (nieuwe salt van 16 willekeurige bytes, tenzij meegegeven voor een test). nil bij een ongeldige pincode.
    static func make(pin: String, salt: Data? = nil) -> PinHash? {
        guard isValidPIN(pin) else { return nil }
        let s = salt ?? randomSalt()
        guard let h = derive(pin: pin, salt: s, iterations: iterations) else { return nil }
        return PinHash(iter: iterations, salt: s, hash: h)
    }

    /// Klopt de pincode? Opnieuw afleiden en in vaste tijd vergelijken.
    func verify(_ pin: String) -> Bool {
        guard Self.isValidPIN(pin), let got = Self.derive(pin: pin, salt: salt, iterations: iter) else { return false }
        return Self.constantTimeEqual(got, hash)
    }

    /// Vergelijken zonder vroeg te stoppen (vaste tijd voor gelijke lengtes).
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        let x = [UInt8](a), y = [UInt8](b)
        var d = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<min(x.count, y.count) { d |= x[i] ^ y[i] }
        return d == 0
    }

    /// 16 bytes uit de CSPRNG van het systeem.
    static func randomSalt() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<saltBytes).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// PBKDF2-HMAC-SHA256 (CommonCrypto). nil als CommonCrypto er niet is of een fout geeft.
    static func derive(pin: String, salt: Data, iterations: Int, length: Int = hashBytes) -> Data? {
        #if canImport(CommonCrypto)
        guard iterations > 0, length > 0, !salt.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        let password = Array(pin.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        let status = out.withUnsafeMutableBufferPointer { op -> Int32 in
            password.withUnsafeBufferPointer { pp -> Int32 in
                saltBytes.withUnsafeBufferPointer { sp -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp.baseAddress, pp.count,
                                         sp.baseAddress, sp.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         op.baseAddress, op.count)
                }
            }
        }
        return status == Int32(kCCSuccess) ? Data(out) : nil
        #else
        return nil
        #endif
    }

    /// Standaard-base64 (RFC 4648 §4).
    static func base64(_ s: String) -> Data? {
        guard s.count % 4 == 0 else { return nil }
        return Data(base64Encoded: s)
    }

    /// Oude lokale waarde (t/m build 145): de pincode zelf (alleen cijfers).
    static func isLegacyPlain(_ stored: String?) -> Bool {
        guard let s = stored, !s.isEmpty else { return false }
        return s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Lokale waarde controleren: een hash (build 146) of nog de oude pincode zelf (vaste tijd vergelijken).
    static func matches(stored: String?, pin: String) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        if let h = PinHash(string: stored) { return h.verify(pin) }
        if isLegacyPlain(stored) { return constantTimeEqual(Data(stored.utf8), Data(pin.utf8)) }
        return false
    }
}

/// Wat de server in `profile.<id>` over de pincode zegt (regels uit het contract).
enum PinState: Equatable {
    /// niets over de pincode (geen `pin`, geen `pinHash`)
    case absent
    /// verwijderd (`pin`/`pinHash` null) op `at`
    case removed(at: Double)
    /// geldige hash; `pin` wordt dan genegeerd
    case hash(PinHash, at: Double)
    /// alleen `pin` als tekst (oude app): meteen hashen, met dezelfde `pinUpdatedAt`
    case legacy(String, at: Double)

    /// `time` zet een ISO-tijd of getal om naar seconden sinds 1970; `sectionAt` = tijd van de hele section.
    static func read(_ data: [String: Any], sectionAt: Double, time: (Any?) -> Double?) -> PinState {
        let at = time(data["pinUpdatedAt"])
        if let h = PinHash(json: data["pinHash"]) { return .hash(h, at: at ?? sectionAt) }
        if let p = data["pin"] as? String, !p.isEmpty { return .legacy(p, at: at ?? sectionAt) }
        // een onbekend hash-formaat (latere build) is geen verwijdering
        if let raw = data["pinHash"], !(raw is NSNull) { return .absent }
        if data.keys.contains("pin") || data.keys.contains("pinHash") { return .removed(at: at ?? 0) }
        return .absent
    }

    var at: Double? {
        switch self {
        case .absent: return nil
        case .removed(let t), .hash(_, let t), .legacy(_, let t): return t
        }
    }
}

// MARK: - Support vanuit de app

enum SupportLogic {
    /// Tabs: Open (new), In behandeling (open, pending), Gesloten (resolved, closed).
    enum Group: String, CaseIterable, Identifiable {
        case open, inProgress = "in_progress", closed
        var id: String { rawValue }
    }

    static func group(status: String?, group: String?) -> Group {
        if let g = group.flatMap(Group.init(rawValue:)) { return g }
        switch (status ?? "").lowercased() {
        case "new": return .open
        case "resolved", "closed": return .closed
        default: return .inProgress
        }
    }

    static let categories = ["account", "afspelen", "apps", "website", "overig"]

    /// Controle zoals de server (subject 3–120, bericht 10–5000, reactie 1–5000, max. 6 links). nil = goed.
    static func validate(subject: String?, message: String, reply: Bool) -> String? {
        if let s = subject?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if s.isEmpty { return "subject_missing" }
            if s.count < 3 { return "subject_missing" }
            if s.count > 120 { return "subject_too_long" }
        }
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return "message_missing" }
        if !reply && m.count < 10 { return "message_too_short" }
        if m.count > 5000 { return "message_too_long" }
        if links(in: m) > 6 { return "too_many_links" }
        return nil
    }

    static func links(in s: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"(https?://|www\.)"#, options: [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// Deeplink `bingr://support` (lijst) of `bingr://support/ticket?n=<nr>` (dat ticket). nil = geen supportlink.
    /// `number` nil = de ticketlijst.
    static func deeplink(_ url: URL) -> (isSupport: Bool, number: Int?) {
        guard url.scheme?.lowercased() == "bingr", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (false, nil)
        }
        var parts = (c.host.map { [$0] } ?? []) + c.path.split(separator: "/").map(String.init)
        parts = parts.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard parts.first == "support" else { return (false, nil) }
        let n = c.queryItems?.first { $0.name == "n" || $0.name == "number" }?.value
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 2, parts[1] == "ticket", let n, n > 0 { return (true, n) }
        return (true, nil)
    }
}

// MARK: - Apparaat voor de diagnose

enum DeviceModelName {
    /// Leesbare naam van een hardware-identifier (`hw.machine`/`hw.model`); onbekend = de identifier zelf.
    static func name(_ identifier: String) -> String {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = table[id] { return n }
        // Mac: familie uit de identifier (MacBookPro18,3 → MacBook Pro)
        for (prefix, family) in macFamilies where id.hasPrefix(prefix) {
            let rest = id.dropFirst(prefix.count)
            if let f = rest.first, f.isNumber { return family }
        }
        return id.isEmpty ? "Apple" : String(id.prefix(80))
    }

    private static let macFamilies: [(String, String)] = [
        ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("Macmini", "Mac mini"),
        ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"), ("iMac", "iMac"),
    ]

    static let table: [String: String] = {
        var t: [String: String] = [
            // Apple TV
            "AppleTV5,3": "Apple TV HD", "AppleTV6,2": "Apple TV 4K",
            "AppleTV11,1": "Apple TV 4K (2nd generation)", "AppleTV14,1": "Apple TV 4K (3rd generation)",
            // iPhone
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        ]
        let ipads: [(String, [String])] = [
            ("iPad (7th generation)", ["iPad7,11", "iPad7,12"]),
            ("iPad (8th generation)", ["iPad11,6", "iPad11,7"]),
            ("iPad (9th generation)", ["iPad12,1", "iPad12,2"]),
            ("iPad (10th generation)", ["iPad13,18", "iPad13,19"]),
            ("iPad (A16)", ["iPad15,7", "iPad15,8"]),
            ("iPad mini (5th generation)", ["iPad11,1", "iPad11,2"]),
            ("iPad mini (6th generation)", ["iPad14,1", "iPad14,2"]),
            ("iPad mini (A17 Pro)", ["iPad16,1", "iPad16,2"]),
            ("iPad Air (3rd generation)", ["iPad11,3", "iPad11,4"]),
            ("iPad Air (4th generation)", ["iPad13,1", "iPad13,2"]),
            ("iPad Air (5th generation)", ["iPad13,16", "iPad13,17"]),
            ("iPad Air 11-inch (M2)", ["iPad14,8", "iPad14,9"]),
            ("iPad Air 13-inch (M2)", ["iPad14,10", "iPad14,11"]),
            ("iPad Air 11-inch (M3)", ["iPad15,3", "iPad15,4"]),
            ("iPad Air 13-inch (M3)", ["iPad15,5", "iPad15,6"]),
            ("iPad Pro 11-inch", ["iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4"]),
            ("iPad Pro 12.9-inch (3rd generation)", ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"]),
            ("iPad Pro 11-inch (2nd generation)", ["iPad8,9", "iPad8,10"]),
            ("iPad Pro 12.9-inch (4th generation)", ["iPad8,11", "iPad8,12"]),
            ("iPad Pro 11-inch (3rd generation)", ["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7"]),
            ("iPad Pro 12.9-inch (5th generation)", ["iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11"]),
            ("iPad Pro 11-inch (4th generation)", ["iPad14,3", "iPad14,4"]),
            ("iPad Pro 12.9-inch (6th generation)", ["iPad14,5", "iPad14,6"]),
            ("iPad Pro 11-inch (M4)", ["iPad16,3", "iPad16,4"]),
            ("iPad Pro 13-inch (M4)", ["iPad16,5", "iPad16,6"]),
        ]
        for (name, ids) in ipads { for i in ids { t[i] = name } }
        return t
    }()
}

// MARK: - Diagnose-bijlage (`diagnostics`, schema 1; build 147: schema 2)

/// Bouwt de bijlage volgens het contract. Alleen vaste velden; tekst gaat door `StartDiag.scrub` (geen URL's, e-mail,
/// paden met een gebruikersmap). Nooit namen, servernamen, gebruikersnamen of titels.
struct SupportDiagnostics {
    enum Kind: String { case start, app }

    var kind: Kind
    var createdAt = Date()
    var platform: String
    var version: String
    var build: Int?
    var engine: String?
    var deviceType: String
    var model: String
    var manufacturer = "Apple"
    var os: String
    var osVersion: String
    var language: String
    var screen: String?
    /// mijlpalen: naam en seconden sinds de start
    var milestones: [(name: String, seconds: Double, ok: Bool?)] = []
    var memory: [String: Any]?
    var crash: [String: Any]?
    var state: [String: Any]?
    /// Build 147 (schema 2): `start` (summary, appMs, userWaitMs, maxHangMs, previous), `fetch` per server en soort,
    /// `network` (type, online, …) en `storage` (totalMB, cacheMB, catalogMB, downloadsMB, freeMB)
    var start: [String: Any]?
    var fetch: [[String: Any]] = []
    var network: [String: Any]?
    var storage: [String: Any]?
    /// Build 148 (schema 3): app-taal, de laatste keren bijwerken per server en haperingen tijdens het afspelen
    var lang: String?
    var updates: [[String: Any]] = []
    var playback: [String: Any]?

    /// Naam van een mijlpaal volgens `^[a-z][a-z0-9_.-]{0,39}$` ("profiel gekozen" → "profiel_gekozen"); nil = onbruikbaar.
    static func milestoneName(_ s: String) -> String? {
        var out = ""
        for ch in s.lowercased() {
            if ch == " " { out.append("_") }
            else if ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" { out.append(ch) }
        }
        while let f = out.first, !(f.isASCII && f.isLetter) { out.removeFirst() }
        guard !out.isEmpty else { return nil }
        return String(out.prefix(40))
    }

    /// Build als getal uit "1.0.1 (146)" of "146".
    static func buildNumber(_ s: String) -> Int? {
        if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        guard let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        return Int(s[s.index(after: open)..<close])
    }

    /// Crash-object uit de startdiagnose (type ≤ 80, reden ≤ 300, max. 50 stackregels van ≤ 200 tekens).
    static func crash(from p: StartDiag.Problem) -> [String: Any]? {
        guard p.kind == .crash else { return nil }
        let full = StartDiag.scrub(p.crash ?? "")
        var type = full, reason = ""
        if let r = full.range(of: ": ") {
            type = String(full[..<r.lowerBound])
            reason = String(full[r.upperBound...])
        }
        var c: [String: Any] = [
            "at": iso(Date(timeIntervalSince1970: p.at)),
            "type": String((type.isEmpty ? "crash" : type).prefix(80)),
            "stack": StartDiag.scrub(lines: p.stack).prefix(50).map { String($0.prefix(200)) },
        ]
        if !reason.isEmpty { c["reason"] = String(reason.prefix(300)) }
        if let b = buildNumber(p.build) { c["build"] = b }
        return c
    }

    static func iso(_ d: Date) -> String { FastISO.string(d) }   // build 149

    var json: [String: Any] {
        var app: [String: Any] = ["platform": platform, "version": String(version.prefix(20))]
        if let build { app["build"] = build }
        if let engine { app["engine"] = String(engine.prefix(30)) }
        if let lang { app["lang"] = AppLang.code(lang) }
        var device: [String: Any] = [
            "type": deviceType, "model": String(StartDiag.scrub(model).prefix(80)), "manufacturer": manufacturer,
            "os": String(os.prefix(20)), "osVersion": String(osVersion.prefix(30)), "language": language,
        ]
        if let screen { device["screen"] = screen }
        var out: [String: Any] = ["schema": 3, "kind": kind.rawValue, "createdAt": Self.iso(createdAt), "app": app, "device": device]
        var seen = Set<String>()
        let ms: [[String: Any]] = milestones.compactMap { m in
            // build 148 (schema 3): `code` in plaats van de oude naam
            guard let n = DiagCode.code(m.name) ?? Self.milestoneName(m.name), seen.insert(n).inserted else { return nil }
            var d: [String: Any] = ["code": n, "ms": Int(min(3_600_000, max(0, (m.seconds * 1000).rounded())))]
            if let ok = m.ok { d["ok"] = ok }
            return d
        }
        if !ms.isEmpty { out["milestones"] = Array(ms.prefix(40)) }
        if let memory { out["memory"] = memory }
        if let crash { out["crash"] = crash }
        if let state { out["state"] = state }
        if let start { out["start"] = start }
        if !fetch.isEmpty { out["fetch"] = Array(fetch.prefix(30)) }
        if let network { out["network"] = network }
        if let storage { out["storage"] = storage }
        if !updates.isEmpty { out["updates"] = Array(updates.prefix(5)) }
        if let playback { out["playback"] = playback }
        return out
    }

    /// Leesbare weergave ("Bekijken"): precies wat er meegaat.
    var prettyText: String {
        guard let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Tv-gids verlopen

enum GuideExpiry {
    /// De gids is verlopen: er is een gids, maar geen programma loopt nog langer dan `margin` na nu (standaard 1 uur).
    static func isExpired(latestEnd: Date?, now: Date = Date(), margin: TimeInterval = 3600) -> Bool {
        guard let latestEnd else { return false }
        return latestEnd < now.addingTimeInterval(margin)
    }
}
