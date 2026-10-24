import Foundation

// Build 148: diagnose-schema 3 (docs/ACCOUNT.md, "Build 148"): codes in de taal van de app, bijwerken per server,
// geleverd en zichtbaar, haperingen tijdens het afspelen.

// MARK: - Teksten in de app-taal

@MainActor
enum DiagText {
    /// Code (of oude naam) → tekst in de app-taal; onbekende code blijft de code
    static func title(_ name: String) -> String {
        guard let c = DiagCode.code(name) else { return name }
        switch c {
        case "started": return L("Started")
        case "storage": return L("Storage")
        case "account": return L("Account")
        case "first_frame": return L("First frame")
        case "intro_done": return L("Intro done")
        case "profile_picker": return L("Profile picker")
        case "profile_picked": return L("Profile chosen")
        case "pin_screen": return L("PIN screen")
        case "pin_ok": return L("PIN correct")
        case "profile": return L("Profile")
        case "servers": return L("Servers")
        case "home": return L("Home")
        case "catalog": return L("Catalog")
        case "ready": return L("Ready")
        case "fetch": return L("Fetch")
        case "parse": return L("Read in")
        case "index": return L("Index")
        case "apply": return L("Apply")
        case "save": return L("Save")
        case "sync_apply": return L("Apply sync")
        case "catalog_filter": return L("Filter catalog")
        case "catalog_sort": return L("Sort catalog")
        case "catalog_meta": return L("Catalog details")
        case "pin_migrate": return L("Migrate PIN")
        case "rows_build": return L("Build rows")
        case "guide_parse": return L("Read TV guide")
        case DiagCode.playbackStall: return L("Playback stall")
        default: return c
        }
    }

    static func s(_ d: Double) -> String { String(format: "%.1f", d) }

    static func marks(_ marks: [StartDiag.Mark]) -> String {
        marks.map { m in "\(title(m.name)) \(s(m.t)) s" + (m.mb.map { " \($0) MB" } ?? "") }.joined(separator: " · ")
    }

    /// Rapport van de vorige start in de app-taal (scherm en ticket)
    static func problem(_ p: StartDiag.Problem) -> String {
        var out: [String] = []
        let last = title(p.lastMark)
        switch p.kind {
        case .crash: out.append(L("Previous start: stopped (crash) after %@ s, at \"%@\"", s(p.seconds), last))
        case .hang:
            out.append(p.foreground == false
                       ? L("Previous start: main thread stuck for %@ s at \"%@\" (background)", s(p.seconds), last)
                       : L("Previous start: main thread stuck for %@ s at \"%@\" (foreground)", s(p.seconds), last))
            if let t = p.task { out.append(L("Task: %@", DiagCode.task(t).map(title) ?? t)) }
        case .notFinished:
            out.append(L("Previous start: not finished, last milestone \"%@\" after %@ s (stopped by the system, e.g. memory or watchdog)", last, s(p.seconds)))
        }
        if let m = p.peakMB { out.append(L("Memory: peak %d MB", m)) }
        out.append("Build \(p.build) · \(p.os)")
        out.append(L("Milestones: %@", marks(p.marks)))
        if let c = p.crash { out.append(L("Error: %@", c)) }
        if !p.stack.isEmpty { out.append(L("Stack:")); out += p.stack }
        return out.joined(separator: "\n")
    }

    /// Langste hang van deze start, of nil (geen hang van betekenis)
    static func longestHang() -> String? {
        let h = StartDiagnostics.shared.currentHang
        guard h.seconds >= 0.5 else { return nil }
        var line = L("Longest hang: %@ s", s(h.seconds))
        if let t = DiagCode.task(h.task) { line += " · " + L("Task: %@", title(t)) }
        if let m = h.milestone { line += " · " + L("after \"%@\"", title(m)) }
        return line
    }

    static func kind(_ k: String) -> String {
        switch k {
        case "live": return L("Live TV")
        case "movie": return L("Movies")
        default: return L("Series")
        }
    }

    static func n(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Localizer.shared.locale
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "36.593 geleverd · 10.286 zichtbaar (26.307 verborgen door categorieën)"
    static func delivered(_ row: [String: Any]) -> String? {
        guard let d = row["delivered"] as? Int, let v = row["visible"] as? Int else { return nil }
        var line = L("%@ delivered · %@ visible", n(d), n(v))
        if let h = row["hidden"] as? [String: Int] {
            var parts: [String] = []
            if let c = h["categories"], c > 0 { parts.append(L("%@ hidden by categories", n(c))) }
            if let c = h["kids"], c > 0 { parts.append(L("%@ hidden by the kids filter", n(c))) }
            if let c = h["duplicates"], c > 0 { parts.append(L("%@ duplicates", n(c))) }
            if let c = h["other"], c > 0 { parts.append(L("%@ hidden otherwise", n(c))) }
            if !parts.isEmpty { line += " (" + parts.joined(separator: ", ") + ")" }
        }
        return line
    }

    static func update(_ u: [String: Any]) -> String {
        let phases = (u["phases"] as? [[String: Any]] ?? []).map { p -> String in
            let ms = Double(p["ms"] as? Int ?? 0) / 1000
            return "\(title(p["code"] as? String ?? "?")) \(s(ms)) s" + ((p["memMB"] as? Int).map { " \($0) MB" } ?? "")
        }
        let result: String
        switch u["result"] as? String {
        case "failed": result = L("Failed")
        case "cancelled": result = L("Stopped")
        default: result = L("Succeeded")
        }
        var line = phases.joined(separator: " · ")
        line += (line.isEmpty ? "" : " · ") + result
        if let p = u["peakMB"] as? Int { line += " · " + L("Memory: peak %d MB", p) }
        return line
    }

    static func stalls(_ list: [PlaybackLog.Entry]) -> String {
        guard let last = list.first else { return L("No stalls") }
        return L("%d stalls, last %@ s after %@ s (%@, %@)", list.count, s(Double(last.ms) / 1000), s(last.at),
                 last.engine == "apple" ? "Apple" : "VLC", last.format)
    }
}

// MARK: - Haperingen tijdens het afspelen

/// De laatste 10 haperingen (stall/rebuffer na het eerste beeld), op het apparaat bewaard. Alleen tijden, engine en
/// formaat: geen titels, zenders of adressen.
@MainActor
final class PlaybackLog {
    static let shared = PlaybackLog()
    private let key = "diag.playback.v148"

    struct Entry: Codable, Equatable {
        var when: Double
        /// Seconden na het eerste beeld, duur in ms
        var at: Double
        var ms: Int
        var engine: String
        var format: String
        var live: Bool
    }

    private(set) var entries: [Entry] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func note(_ s: StallTracker.Stall, engine: String, format: String, live: Bool) {
        // korter dan 300 ms is geen zichtbare hapering
        guard s.ms >= 300 else { return }
        entries.insert(Entry(when: Date().timeIntervalSince1970, at: s.at, ms: min(s.ms, 3_600_000), engine: engine,
                             format: format, live: live), at: 0)
        if entries.count > 10 { entries.removeLast(entries.count - 10) }
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func format(_ url: URL?) -> String {
        guard let url else { return "other" }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || url.absoluteString.lowercased().contains(".m3u8") { return "hls" }
        if ["ts", "mp4", "mkv", "m4v", "mov", "avi"].contains(ext) { return ext }
        return url.isFileURL ? "file" : "other"
    }

    /// Bijlage (`playback`): `{stalls:[{code, at, atMs, ms, engine, format, live}]}`
    var json: [String: Any]? {
        guard !entries.isEmpty else { return nil }
        return ["stalls": entries.map { e -> [String: Any] in
            ["code": DiagCode.playbackStall, "at": SupportDiagnostics.iso(Date(timeIntervalSince1970: e.when)),
             "atMs": Int(e.at * 1000), "ms": e.ms, "engine": e.engine, "format": e.format, "live": e.live]
        }]
    }
}

// MARK: - Bijwerken per server

/// De laatste 5 keer bijwerken (alle servers), met per fase ms en geheugen. `PlaylistService.refresh` schrijft het.
@MainActor
final class UpdateLog {
    static let shared = UpdateLog()
    private let key = "diag.updates.v148"
    private(set) var list: [UpdatePhases.Update] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let e = try? JSONDecoder().decode([UpdatePhases.Update].self, from: d) { list = e }
    }

    func save(_ u: UpdatePhases.Update) {
        UpdatePhases.push(&list, u)
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }

    var rows: [[String: Any]] {
        UpdatePhases.rows(list, servers: CloudStore.shared.playlists.map(\.id.uuidString), iso: SupportDiagnostics.iso)
    }
}

/// Eén keer bijwerken van een server: fasen met hun duur en het geheugen aan het eind. Thread-veilig (het ophalen en
/// inlezen lopen buiten de hoofdthread).
final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var u: UpdatePhases.Update
    private var last: Date
    private let t0 = Date()

    init(server: UUID) {
        u = UpdatePhases.Update(server: server.uuidString, at: Date().timeIntervalSince1970)
        last = Date()
    }

    /// De fase `code` is klaar (sinds het vorige ijkpunt)
    func end(_ code: String) {
        let mb = StartDiagnostics.footprintMB()
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        UpdatePhases.add(&u, code: code, ms: now.timeIntervalSince(last) * 1000, memMB: mb)
        last = now
    }

    /// Een fase met een gemeten duur (bijv. het filteren op de achtergrond)
    func add(_ code: String, ms: Double) {
        let mb = StartDiagnostics.footprintMB()
        lock.lock(); defer { lock.unlock() }
        UpdatePhases.add(&u, code: code, ms: ms, memMB: mb)
        last = Date()
    }

    func finish(_ r: UpdatePhases.Result) -> UpdatePhases.Update {
        lock.lock(); defer { lock.unlock() }
        u.result = r
        u.totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        if let p = StartDiagnostics.shared.peakMB { u.peakMB = max(u.peakMB ?? 0, p) }
        return u
    }
}

// MARK: - Grote waarden buiten de hoofdthread vrijgeven

enum OffMain {
    /// Een oude catalogus (tienduizenden titels, de gids) vrijgeven op een achtergrondthread: het opruimen van
    /// honderdduizenden strings en URL's kostte op de hoofdthread seconden. Even wachten, zodat de verwijzing op de
    /// hoofdthread zeker eerst weg is.
    static func release<T>(_ value: T) {
        let box = Box(value)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { box.drop() }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
        init(_ v: T) { value = v }
        func drop() { value = nil }
    }
}
