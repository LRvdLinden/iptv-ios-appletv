import SwiftUI
#if os(tvOS)
import MediaPlayer
#endif
#if os(iOS)
import UIKit
#endif

// Build 176: de UI-kant van punt 12 (helderheid met vegen, iPhone en iPad) en punt 15 (direct spoelen op de Apple TV).
// De regels staan in Build176Player.swift.

#if os(tvOS)
/// ±10-knoppen van de Remote-app (Bedieningspaneel op iPhone/iPad) en andere afstandsbedieningen komen als
/// systeemopdrachten binnen. Alleen zolang de speler open is.
@MainActor
final class RemoteSkip176 {
    private var targets: [(MPRemoteCommand, Any)] = []

    func attach(_ skip: @escaping @MainActor (Bool) -> Void) {
        detach()
        let cc = MPRemoteCommandCenter.shared()
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: Skip176.step)]
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: Skip176.step)]
        cc.skipForwardCommand.isEnabled = true
        cc.skipBackwardCommand.isEnabled = true
        let f = cc.skipForwardCommand.addTarget { _ in
            Task { @MainActor in skip(true) }
            return .success
        }
        let b = cc.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in skip(false) }
            return .success
        }
        targets = [(cc.skipForwardCommand, f), (cc.skipBackwardCommand, b)]
    }

    func detach() {
        for (c, t) in targets { c.removeTarget(t) }
        if !targets.isEmpty {
            let cc = MPRemoteCommandCenter.shared()
            cc.skipForwardCommand.isEnabled = false
            cc.skipBackwardCommand.isEnabled = false
        }
        targets = []
    }
}
#endif

#if os(iOS)
/// Helderheid van het scherm waar de speler op staat (geen `UIScreen.main`, dat is verouderd).
@MainActor
enum ScreenBrightness176 {
    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    static var current: Double { Double(screen?.brightness ?? 0.5) }

    static func set(_ v: Double) { screen?.brightness = CGFloat(min(max(v, 0), 1)) }
}

/// Indicator links in beeld tijdens het vegen: zonnetje met een verticale balk en het percentage.
struct BrightnessHUD176: View {
    let value: Double

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: value < 0.35 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 18, weight: .semibold))
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(height: g.size.height * min(max(value, 0), 1))
                }
            }
            .frame(width: 6, height: 120)
            Text("\(Brightness176.percent(value))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.vertical, 14).padding(.horizontal, 12)
        .background(.black.opacity(0.55), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 36)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Brightness"))
        .accessibilityValue("\(Brightness176.percent(value))%")
    }
}
#endif
