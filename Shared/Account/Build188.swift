import Foundation

/// Build 188: downloadwachtrij. Veel providers staan maar één verbinding toe; twee downloads tegelijk breken dan
/// elkaar af en komen nooit klaar. Downloads wachten daarom in een rij en lopen standaard één tegelijk.
/// Pure logica (geen UIKit), zodat de zelftest in CI hem draait (tools/selftest/main.swift).
enum DownloadQueue188 {
    /// Aantal gelijktijdige downloads (één verbinding, dus veilig voor providers met maar 1 verbinding)
    static let maxConcurrent = 1

    struct Waiting: Equatable {
        var id: String
        /// Moment waarop de download in de rij kwam (bij een nieuwe poging: opnieuw het moment van de fout, dus achteraan)
        var since: Date
    }

    /// Welke wachtende downloads nu mogen starten: op volgorde van binnenkomst, zoveel als er plekken vrij zijn.
    static func nextToStart(running: Int, waiting: [Waiting], limit: Int = maxConcurrent) -> [String] {
        let free = max(0, max(1, limit) - max(0, running))
        guard free > 0 else { return [] }
        let ordered = waiting.enumerated().sorted { a, b in
            a.element.since != b.element.since ? a.element.since < b.element.since : a.offset < b.offset
        }
        return Array(ordered.prefix(free).map(\.element.id))
    }
}
