import UIKit

/// App-delegate voor iPhone/iPad (build 52): downloads op de achtergrond. Als een download klaar is terwijl
/// Bingr niet draait, start het systeem de app op de achtergrond en geeft het een afrondings-handler mee.
final class BingrAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in DownloadManager.shared.start() }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let m = DownloadManager.shared
            m.backgroundCompletion[identifier] = completionHandler
            m.start()
        }
    }
}
