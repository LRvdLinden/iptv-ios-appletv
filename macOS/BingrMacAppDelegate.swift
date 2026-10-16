import AppKit

/// App-delegate voor de Mac (native AppKit, geen Catalyst): pushmeldingen (docs/PUSH.md). Het meldingencentrum
/// krijgt zijn delegate al vóór het einde van het starten, zodat een klik op een melding die Bingr opent aankomt;
/// het APNs-devicetoken komt hier binnen.
final class BingrMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { PushService.shared.start() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushService.shared.didFailToRegister(error) }
    }
}
