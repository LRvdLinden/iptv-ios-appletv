import Foundation

// Build 147: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
// Contract: docs/ACCOUNT.md, "Build 147" (diagnose-schema 2).

// MARK: - Eerlijke starttijden (app-tijd en wachten op de gebruiker)

enum StartTiming {
    /// Mijlpalen waarop de app op de gebruiker wacht, met de mijlpaal waarop dat wachten stopt.
    static let waits: [(start: String, end: String)] = [("profielkeuze", "profiel gekozen"), ("pincodescherm", "pincode goed")]

    struct Split: Equatable { var appMs: Int; var userWaitMs: Int }

    /// App-tijd en wachttijd tot `end` (seconden; nil = de laatste mijlpaal). Een wachtmoment zonder einde loopt tot `end`.
    static func split(_ marks: [StartDiag.Mark], end: Double? = nil) -> Split {
        let stop = end ?? marks.map(\.t).max() ?? 0
        var wait = 0.0
        for w in waits {
            guard let s = marks.first(where: { $0.name == w.start }), s.t <= stop else { continue }
            let e = marks.first(where: { $0.name == w.end && $0.t >= s.t }).map { min($0.t, stop) } ?? stop
            wait += max(0, e - s.t)
        }
        wait = min(wait, stop)
        return Split(appMs: Int(((stop - wait) * 1000).rounded()), userWaitMs: Int((wait * 1000).rounded()))
    }

    enum Summary: String { case good, slow, hung }

    static let slowAppMs = 5000
    static let slowHang: Double = 2
    static let hungHang: Double = 10

    /// Goed / traag / vastgelopen. Traag = app-tijd boven 5 s of een hang boven 2 s; vastgelopen = hang boven 10 s of crash.
    static func summary(appMs: Int?, hang: Double?, crashed: Bool) -> Summary {
        if crashed || (hang ?? 0) > hungHang { return .hung }
        if (appMs ?? 0) > slowAppMs || (hang ?? 0) > slowHang { return .slow }
        return .good
    }
}

// MARK: - Taak of fase op de hoofdthread (voor de hang-diagnose)

/// Welke taken nu op de hoofdthread bezig zijn ("catalogus filteren", "sync toepassen", …). Thread-veilig: de bewaking
/// leest het op een eigen thread. Alleen vaste namen, nooit titels, servernamen of andere gegevens.
final class MainTasks: @unchecked Sendable {
    static let shared = MainTasks()
    private let lock = NSLock()
    private var active: [(id: Int, name: String)] = []
    private var next = 0

    func begin(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        next &+= 1
        active.append((next, name))
        if active.count > 32 { active.removeFirst(active.count - 32) }
        return next
    }

    func end(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        active.removeAll { $0.id == id }
    }

    /// Synchroon werk met een naam.
    @discardableResult
    func run<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let id = begin(name)
        defer { end(id) }
        return try work()
    }

    /// De laatst begonnen taak eerst (max. 3), bijv. "catalogus filteren, sync toepassen"; nil = niets bekends.
    var current: String? {
        lock.lock(); defer { lock.unlock() }
        let names = active.reversed().map(\.name)
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.prefix(3).joined(separator: ", ")
    }
}

// MARK: - Vorige start (diagnose-schema 2: `start.previous`)

enum StartPrevious {
    enum Problem: String { case none, hang, crash, notFinished = "not_finished" }

    /// Probleem van een start: crash, hang (boven 2 s, op de voorgrond), niet klaar (zonder op de gebruiker te wachten), of niets.
    static func problem(crashed: Bool, hang: Double?, finished: Bool, waitingOnUser: Bool) -> Problem {
        if crashed { return .crash }
        if (hang ?? 0) > StartTiming.slowHang { return .hang }
        if !finished && !waitingOnUser { return .notFinished }
        return .none
    }

    /// Wachtte de app bij de laatste mijlpaal op de gebruiker (profielkeuze of pincodescherm zonder einde)?
    static func waitingOnUser(_ marks: [StartDiag.Mark]) -> Bool {
        for w in StartTiming.waits {
            if marks.contains(where: { $0.name == w.start }) && !marks.contains(where: { $0.name == w.end }) { return true }
        }
        return false
    }
}

// MARK: - Ophalen per server en soort (diagnose-schema 2: `fetch`)

enum FetchStatus {
    enum Kind: String, Codable, CaseIterable { case live, movie, series }
    enum Status: String, Codable { case ok, empty, failed, hidden }

    /// Uitkomst van het laatste ophalen van één soort op één server (bewaard op het apparaat, zonder URL of naam).
    struct Entry: Codable, Equatable {
        var kind: Kind
        /// Wat de provider leverde (nil = ophalen mislukt)
        var delivered: Int?
        /// Korte foutcode zonder URL (bijv. "timeout", "http_503", "decode")
        var error: String?
        var at: Double
    }

    /// Status voor de diagnose: geleverd (ok), provider leverde niets (empty), mislukt (failed) of alles verborgen
    /// (hidden: geleverd, maar na verborgen categorieën of het kinderfilter blijft er niets over).
    static func status(delivered: Int?, visible: Int?) -> Status {
        guard let delivered else { return .failed }
        if delivered == 0 { return .empty }
        if let visible, visible == 0 { return .hidden }
        return .ok
    }

    /// Korte foutcode zonder URL of tekst van de server.
    static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "offline"
            case .cannotFindHost, .dnsLookupFailed: return "dns"
            case .cannotConnectToHost: return "connect"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "tls"
            case .cancelled: return "cancelled"
            case .badServerResponse: return "bad_response"
            default: return "url_\(u.code.rawValue)"
            }
        }
        if error is DecodingError { return "decode" }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (3840...3851).contains(ns.code) { return "decode" }
        return "error"
    }

    /// Regels voor de bijlage: servers als s1, s2, … (volgorde van de lijst); per soort status, aantal en fout.
    static func rows(servers: [[Entry]], visible: [[Kind: Int]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (i, entries) in servers.enumerated() where i < 20 {
            for e in entries {
                let v = i < visible.count ? visible[i][e.kind] : nil
                let st = status(delivered: e.delivered, visible: v)
                var r: [String: Any] = ["server": "s\(i + 1)", "kind": e.kind.rawValue, "status": st.rawValue]
                if let d = e.delivered { r["count"] = d }
                if let err = e.error, st == .failed { r["error"] = String(err.prefix(40)) }
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - Opslag (diagnose-schema 2: `storage`)

enum StorageBreakdown {
    struct Result: Equatable { var totalMB: Int; var cacheMB: Int; var catalogMB: Int; var downloadsMB: Int; var freeMB: Int? }

    /// Eén totaal met daaronder cache, catalogus en downloads die samen precies het totaal zijn. `appBytes` = alles wat
    /// Bingr op het apparaat bewaart (caches, Application Support, tmp); catalogus en downloads zitten daarin.
    static func make(appBytes: Int64, catalogBytes: Int64, downloadBytes: Int64, freeBytes: Int64?) -> Result {
        let mb: Int64 = 1_048_576
        let catalog = Int(max(0, catalogBytes) / mb)
        let downloads = Int(max(0, downloadBytes) / mb)
        let total = max(Int(max(0, appBytes) / mb), catalog + downloads)
        return Result(totalMB: total, cacheMB: total - catalog - downloads, catalogMB: catalog, downloadsMB: downloads,
                      freeMB: freeBytes.map { Int(max(0, $0) / mb) })
    }
}

// MARK: - Sleutels van Mijn lijst en favorieten (build 147: zonder de hele set door te lopen)

enum ListKeys {
    /// Staat dit item in de set? De server-id kan met hoofdletters (deze app) of kleine letters (web, Android, Samsung TV)
    /// zijn opgeslagen; het item-id is exact. Twee opzoekingen, nooit de hele set doorlopen (dat was per item O(n) en bij
    /// tienduizenden films per schermverversing te zwaar voor de hoofdthread).
    static func contains(_ set: Set<String>, playlist: String, item: String) -> Bool {
        let up = playlist.uppercased(), low = playlist.lowercased()
        return set.contains(up + "|" + item) || set.contains(low + "|" + item)
    }
}

// MARK: - Hoofdthread-stack (regels voor de diagnose)

enum StackFormat {
    /// "3 Bingr PlaylistService.apply + 120" of zonder symbool "3 Bingr +0x1a2b3c" (zelf te symboliseren met de dSYM).
    static func line(_ i: Int, image: String, symbol: String?, offset: UInt, imageOffset: UInt) -> String {
        let img = String((image.split(separator: "/").last.map(String.init) ?? image).prefix(40))
        if let symbol, !symbol.isEmpty {
            return String("\(i) \(img) \(symbol.prefix(120)) + \(offset)".prefix(200))
        }
        return "\(i) \(img) +0x\(String(imageOffset, radix: 16))"
    }
}
