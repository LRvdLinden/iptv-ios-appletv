import Foundation
import AppIntents

// Build 174: knoppen van de widget "Bingr Radio" en de Live Activity. Deze intents staan in de app én in de widget-extensie;
// het systeem voert ze uit in de app (AudioPlaybackIntent / LiveActivityIntent), ook als die nog niet open was. In de
// extensie (BINGR_WIDGET_EXT) doen ze zelf niets.
// Build 175: ook in de Mac-app en de widget-extensie van de Mac. Daar bestaat LiveActivityIntent niet: de knoppen zijn er
// AudioPlaybackIntents (ook die voert het systeem in de app uit).

#if os(iOS)
typealias RadioControlIntent = LiveActivityIntent
#else
typealias RadioControlIntent = AudioPlaybackIntent
#endif

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
struct ToggleRadioIntent: RadioControlIntent {
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
struct StepRadioIntent: RadioControlIntent {
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
