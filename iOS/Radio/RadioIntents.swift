import Foundation
import AppIntents

// Build 174: knoppen van de widget "Bingr Radio" en de Live Activity. Deze intents staan in de app én in de widget-extensie;
// het systeem voert ze uit in de app (AudioPlaybackIntent / LiveActivityIntent), ook als die nog niet open was. In de
// extensie (BINGR_WIDGET_EXT) doen ze zelf niets.

/// Zender starten (widget)
struct PlayRadioStationIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play radio station"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Station")
    var stationID: String

    init() {}
    init(stationID: String) { self.stationID = stationID }

    func perform() async throws -> some IntentResult {
        #if !BINGR_WIDGET_EXT
        await RadioIntentHandler.play(stationID)
        #endif
        return .result()
    }
}

/// Afspelen/pauze (widget en Live Activity)
struct ToggleRadioIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause radio"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !BINGR_WIDGET_EXT
        await RadioIntentHandler.toggle()
        #endif
        return .result()
    }
}

/// Vorige (-1) of volgende (1) zender (Live Activity)
struct StepRadioIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next or previous radio station"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Step")
    var step: Int

    init() {}
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        #if !BINGR_WIDGET_EXT
        await RadioIntentHandler.step(step)
        #endif
        return .result()
    }
}
