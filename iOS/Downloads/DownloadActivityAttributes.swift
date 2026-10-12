import Foundation
import ActivityKit

/// Live Activity voor downloads (build 52): voortgang op het toegangsscherm en in het Dynamic Island.
/// Gedeeld tussen de app en de widget-extensie (BingrWidgets). Teksten komen al vertaald uit de app.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Titel die nu downloadt (of de laatst voltooide)
        var title: String
        /// Bijv. "2 van 5 · 1,2 GB van 3,4 GB"
        var detail: String
        /// 0...1 over alle lopende downloads
        var progress: Double
        /// Aantal downloads dat nog bezig is of wacht
        var remaining: Int
        var paused: Bool
        var finished: Bool
    }

    /// Kop, bijv. "Downloads"
    var heading: String
}
