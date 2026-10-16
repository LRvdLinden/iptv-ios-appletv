import UIKit

/// App-delegate voor iPhone/iPad (build 52): downloads op de achtergrond. Als een download klaar is terwijl
/// Bingr niet draait, start het systeem de app op de achtergrond en geeft het een afrondings-handler mee.
/// Ook pushmeldingen (docs/PUSH.md): het meldingencentrum krijgt hier zijn delegate (zodat een tik op een melding
/// die de app start aankomt) en het APNs-devicetoken komt hier binnen.
final class BingrAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { PushService.shared.start() }
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

    // MARK: pushmeldingen (APNs)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushService.shared.didFailToRegister(error) }
    }
}
