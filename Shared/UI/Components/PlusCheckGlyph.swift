import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Gedeeld aan/uit-icoon voor Mijn lijst én favoriete zenders: een plus (+) als de titel/zender er niet in staat,
/// een vinkje (✓) als hij er wel in staat (was een hartje / ster).
/// Bij wisselen draait de plus 90° en krimpt hij weg, terwijl het vinkje zich "tekent" (± 0,3 s), met een lichte
/// schaal-bounce bij het toevoegen; bij verwijderen gaat het precies andersom. Met "Beperk beweging" (Reduce Motion)
/// wisselt hij zonder animatie. Kleur via `.foregroundStyle` van de aanroeper.
struct PlusCheckGlyph: View {
    let inList: Bool   // true = staat in Mijn lijst / is favoriet
    /// Hoogte/breedte van het icoon (zoals de `font(.system(size:))` van een SF Symbol).
    var size: CGFloat = 19
    /// Lijndikte; standaard ongeveer die van een semibold SF Symbol op deze maat.
    var lineWidth: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        PlusCheckShape(progress: inList ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: lineWidth ?? max(1.5, size * 0.13), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: inList)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: bounce) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: 0.06)
                    CubicKeyframe(1.15, duration: 0.12)
                    SpringKeyframe(1, duration: 0.18, spring: .bouncy)
                }
            }
            .onChange(of: inList) { _, on in
                if on && !reduceMotion { bounce &+= 1 }
            }
            .accessibilityHidden(true)
    }
}

/// Plus → vinkje als één vorm (`progress` 0 = plus, 1 = vinkje), zodat SwiftUI de tussenstanden zelf tekent.
/// 0…0,55: de plus draait 90° en krimpt naar het midden; 0,35…1: het vinkje tekent zich van links naar rechts.
struct PlusCheckShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let s = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()

        // plus: armen van 0,42·s vanaf het midden, draaiend en krimpend
        let plusPhase = min(1, p / 0.55)
        let arm = s * 0.42 * (1 - plusPhase)
        if arm > 0.01 {
            let angle = Double.pi / 2 * Double(plusPhase)
            for base in [0.0, Double.pi / 2] {
                let a = base + angle
                let dx = CGFloat(cos(a)) * arm, dy = CGFloat(sin(a)) * arm
                path.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                path.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
        }

        // vinkje (zelfde verhoudingen als SF Symbol "checkmark")
        let checkPhase = max(0, (p - 0.35) / 0.65)
        if checkPhase > 0.001 {
            var check = Path()
            check.move(to: CGPoint(x: rect.minX + s * 0.10, y: rect.minY + s * 0.53))
            check.addLine(to: CGPoint(x: rect.minX + s * 0.38, y: rect.minY + s * 0.80))
            check.addLine(to: CGPoint(x: rect.minX + s * 0.90, y: rect.minY + s * 0.22))
            path.addPath(checkPhase >= 0.999 ? check : check.trimmedPath(from: 0, to: checkPhase))
        }
        return path
    }
}

extension PlusCheckGlyph {
    /// SF Symbol voor menu's (contextmenu's kunnen geen eigen vorm tonen): plus of vinkje.
    static func symbol(_ on: Bool) -> String { on ? "checkmark" : "plus" }
}

/// Lichte tik (iPhone/iPad) bij het aan- of uitzetten van Mijn lijst of een favoriete zender.
enum PlusCheckFeedback {
    static func toggled() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
