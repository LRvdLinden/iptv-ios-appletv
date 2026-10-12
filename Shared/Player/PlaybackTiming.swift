import Foundation
import os

/// Tijdmeting van het startpad: van de tik op Afspelen tot het eerste beeld (build 59).
/// Te zien in Console.app / Xcode met subsysteem `nl.lrvdlinden.bingr`, categorie `playback`.
@MainActor
enum PlaybackTiming {
    private static let log = Logger(subsystem: "nl.lrvdlinden.bingr", category: "playback")
    private static var t0: CFAbsoluteTime?
    private static var last: CFAbsoluteTime = 0

    /// Begin van een nieuwe meting. `keepRecent`: loopt er al een meting van minder dan 10 s (bijv. vanaf de
    /// detailpagina met leeftijdscontrole), dan alleen een tussenstap noteren.
    static func begin(_ title: String, step: String = "tap", keepRecent: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if keepRecent, let t0, now - t0 < 10 { mark(step); return }
        t0 = now; last = now
        log.info("start \(title, privacy: .public) (\(step, privacy: .public))")
    }

    /// Tussenstap: tijd sinds de vorige stap en sinds het begin.
    static func mark(_ step: String) {
        guard let t0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let delta = Int((now - last) * 1000), total = Int((now - t0) * 1000)
        log.info("\(step, privacy: .public): +\(delta) ms (total \(total) ms)")
        last = now
    }

    /// Laatste stap (eerste beeld): meting afsluiten.
    static func end(_ step: String) {
        guard t0 != nil else { return }
        mark(step)
        t0 = nil
    }
}
