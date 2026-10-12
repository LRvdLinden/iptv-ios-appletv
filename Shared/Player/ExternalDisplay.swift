#if os(iOS)
import UIKit
import SwiftUI

/// Extern scherm (HDMI-adapter of AirPlay-schermdeling) op iPhone/iPad: de video schermvullend op het
/// externe scherm, de bediening op het apparaat zelf. Het systeem maakt daarvoor een eigen scene met de rol
/// `.windowExternalDisplayNonInteractive` (zie `UIApplicationSceneManifest` in project.yml); daarin zet Bingr
/// een eigen venster met alleen het beeld.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    @Published private(set) var isConnected = false
    private var window: UIWindow?
    private weak var scene: UIWindowScene?
    /// Hier komt het beeld van de speler in
    private let host = UIView()
    private var observers: [NSObjectProtocol] = []

    private init() {
        host.backgroundColor = .clear
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    /// Volgen welke schermen er (bij)komen; ook als een scene zonder onze scene-delegate verbonden wordt.
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { n in
            guard let s = n.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { ExternalDisplay.shared.sceneConnected(s) }
        })
        observers.append(nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { n in
            guard let s = n.object as? UIScene else { return }
            MainActor.assumeIsolated { ExternalDisplay.shared.disconnect(s) }
        })
        for s in UIApplication.shared.connectedScenes {
            if let ws = s as? UIWindowScene { sceneConnected(ws) }
        }
    }

    private func sceneConnected(_ s: UIWindowScene) {
        guard s.session.role == .windowExternalDisplayNonInteractive else { return }
        // even wachten: de scene-delegate (als die er is) kan het venster zelf al maken
        Task { @MainActor in self.connect(s) }
    }

    func connect(_ s: UIWindowScene) {
        guard window?.windowScene !== s else { return }
        window?.isHidden = true
        let w = UIWindow(windowScene: s)
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        // Bingr-logo zolang er niets speelt
        let logo = UILabel()
        logo.text = "BINGR"
        logo.font = .systemFont(ofSize: 72, weight: .heavy)
        logo.textColor = UIColor.white.withAlphaComponent(0.18)
        logo.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(logo)
        NSLayoutConstraint.activate([logo.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                                     logo.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor)])
        host.frame = vc.view.bounds
        vc.view.addSubview(host)
        w.rootViewController = vc
        w.windowLevel = .normal + 1
        w.isHidden = false
        window = w
        scene = s
        isConnected = true
    }

    func disconnect(_ s: UIScene) {
        guard let w = window, w.windowScene === s || scene == nil else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        w.isHidden = true
        window = nil
        scene = nil
        isConnected = false
    }

    /// Het beeld van de speler naar het externe scherm.
    func attach(_ v: UIView) {
        guard isConnected, v.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        v.frame = host.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(v)
    }

    /// Speler gesloten: het beeld weer van het externe scherm halen (daar staat dan het logo).
    func detach(_ v: UIView) {
        if v.superview === host { v.removeFromSuperview() }
    }
}

/// Scene-delegate voor het externe scherm (rol `.windowExternalDisplayNonInteractive`).
@objc(ExternalDisplaySceneDelegate)
@MainActor
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.connect(ws)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.disconnect(scene)
    }
}
#endif
