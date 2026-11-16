import Foundation
import ActivityKit

/// Build 179: Live Activity bij live tv (vergrendelscherm, Dynamic Island, vanaf iOS 18 klein voor CarPlay/Apple Watch).
/// Gedeeld tussen de app en de widget-extensie (BingrWidgets). Teksten komen al vertaald uit de app; het logo staat als
/// bestand in de App Group (map `radio/`, zelfde naamgeving als de radio: `Radio174.logoFileName`). Alleen lokaal
/// bijgewerkt (zappen, programmawissel), geen push.
struct LiveTVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var channelID: String
        var channel: String
        /// Bestandsnaam van het logo in de App Group
        var logo: String?
        /// Programma van nu (titel, begin en einde) en wat er daarna komt
        var now: String?
        var nowStart: Date?
        var nowEnd: Date?
        var next: String?
        var nextStart: Date?
        var isPlaying: Bool
    }

    /// Kop, bijv. "Bingr · Live tv"
    var heading: String
    /// "Straks" / "Next" (in de app-taal)
    var nextLabel: String
    var playLabel: String
    var pauseLabel: String
}
