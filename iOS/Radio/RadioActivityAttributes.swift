import Foundation
import ActivityKit

/// Build 174: Live Activity van Bingr Radio (vergrendelscherm, Dynamic Island en vanaf iOS 26 CarPlay).
/// Gedeeld tussen de app en de widget-extensie (BingrWidgets). Teksten komen al vertaald uit de app; het logo staat als
/// bestand in de App Group (`Radio174.appGroup`, map `radio/`). Alleen lokaal bijgewerkt, geen push.
struct RadioActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stationID: String
        var station: String
        /// Wat er nu speelt (ICY of EPG), nil = onbekend
        var nowPlaying: String?
        /// Bestandsnaam van het logo in de App Group
        var logo: String?
        var isPlaying: Bool
        var isBuffering: Bool
    }

    /// Kop, bijv. "Bingr Radio"
    var heading: String
    /// Teksten voor VoiceOver bij de knoppen
    var playLabel: String
    var pauseLabel: String
    var nextLabel: String
    var previousLabel: String
}
