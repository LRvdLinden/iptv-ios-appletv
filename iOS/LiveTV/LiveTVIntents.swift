import Foundation
import AppIntents

// Build 179: pauze/afspelen in de Live Activity van live tv. Staat in de app én in de widget-extensie; het systeem voert
// hem uit in de app (LiveActivityIntent). In de extensie (BINGR_WIDGET_EXT) doet hij zelf niets.

struct ToggleLiveTVIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause live TV"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !BINGR_WIDGET_EXT
        await MainActor.run { LiveTVActivity179.shared.toggle() }
        #endif
        return .result()
    }
}
