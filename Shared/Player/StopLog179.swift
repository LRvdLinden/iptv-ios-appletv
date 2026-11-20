import Foundation

// Build 179, X2: de laatste keren dat een stream stopte of opnieuw moest verbinden, op het apparaat bewaard voor
// Diagnose ("Laatste stop"). Alleen reden, tijden, speler en formaat: geen titels, zenders of adressen.

@MainActor
final class StopLog179 {
    static let shared = StopLog179()
    private let key = "diag.stops.v179"
    private(set) var entries: [Stream179.Stop] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let e = try? JSONDecoder().decode([Stream179.Stop].self, from: d) {
            entries = e
        }
    }

    func note(_ reason: Stream179.Reason, after: Double, engine: String, format: String, live: Bool) {
        Stream179.push(&entries, Stream179.Stop(when: Date().timeIntervalSince1970, reason: reason,
                                                 after: max(0, min(after, 360_000)), engine: engine, format: format, live: live))
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func title(_ r: Stream179.Reason) -> String {
        switch r {
        case .serverClosed: return L("server closed the connection")
        case .error: return L("stream error")
        case .timeout: return L("time-out (no picture for 15 s)")
        case .gaveUp: return L("reconnecting failed")
        case .limit: return L("stream limit")
        case .remotePause: return L("pause command from a remote or the TV")
        }
    }

    /// Regel voor Diagnose: "server sloot de verbinding na 27 s (VLC, ts) · 5 minuten geleden"
    func line(relative: (Date) -> String) -> String {
        guard let s = entries.first else { return L("No stops") }
        let text = L("%@ after %@ s (%@, %@)", Self.title(s.reason), String(format: "%.0f", s.after),
                     s.engine == "apple" ? "Apple" : "VLC", s.format)
        return text + " · " + relative(Date(timeIntervalSince1970: s.when))
    }
}

/// Build 179, X2: telt de voorbeeldspelers (VLC) die buiten de hoofdthread nog aan het sluiten zijn. De speler wacht
/// daar kort op voordat hij zijn eigen verbinding opent, zodat er nooit twee verbindingen naar dezelfde aanbieder
/// tegelijk open staan (aanbieders met één verbinding verbreken er dan één, vaak pas na een halve tot hele minuut).
final class PreviewTeardown179: @unchecked Sendable {
    static let shared = PreviewTeardown179()
    private let lock = NSLock()
    private var closing = 0

    func begin() { lock.lock(); closing += 1; lock.unlock() }
    func end() { lock.lock(); closing = max(0, closing - 1); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return closing }

    /// Wachten tot alle voorbeelden dicht zijn (hoogstens `Stream179.settleMax`). Niets aan het sluiten: meteen verder.
    @MainActor
    func settle() async {
        let start = Date()
        while !Stream179.mayOpen(closing: count, waited: Date().timeIntervalSince(start)) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
