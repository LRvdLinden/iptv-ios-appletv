import SwiftUI

#if !os(tvOS)
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Build 161/162: kaart "Meer apps van de ontwikkelaar" onderaan in Instellingen (iPhone, iPad en Mac; niet op Apple TV).
/// Build 162: in de huisstijl van lrvdlinden.app (blauw, het LR-logo), gelijk aan de kaart in Homey Store.
/// De teksten komen uit Translations.json (alle talen van Bingr). De hele kaart is één link naar https://lrvdlinden.app.
struct MoreAppsSection: View {
    var body: some View {
        Section {
            MoreAppsCard()
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
        } header: { Text(L("Discover")) }
    }
}

/// Huisstijl van lrvdlinden.app: accentblauw, inkt, vlak, lijn en gedempte tekst, elk met een donkere variant.
enum LRBrand {
    static let url = URL(string: "https://lrvdlinden.app")!
    static let accent = Color(lrLight: 0x2747E8, dark: 0x8A9DFF)
    static let onAccent = Color(lrLight: 0xFFFFFF, dark: 0x0D1018)
    static let muted = Color(lrLight: 0x5D6578, dark: 0x98A0B3)
    static let surface = Color(lrLight: 0xFFFFFF, dark: 0x161B27)
    static let line = Color(lrLight: 0xDDE2EC, dark: 0x262D3D)
    /// De logotegel is altijd donker, met de blauwe stip.
    static let logoTile = Color(red: 0x12 / 255, green: 0x17 / 255, blue: 0x26 / 255)
    static let logoDot = Color(red: 0x4C / 255, green: 0x6B / 255, blue: 0xFF / 255)
}

/// Het "LR"-logo van lrvdlinden.app, natively getekend (ontwerpraster 512 × 512).
struct LRLogo: View {
    var size: CGFloat = 60

    var body: some View {
        Canvas { ctx, canvas in
            let s = canvas.width / 512
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 116 * s, style: .continuous),
                     with: .color(LRBrand.logoTile))

            var letters = Path()
            // L
            letters.move(to: p(132, 146)); letters.addLine(to: p(132, 370)); letters.addLine(to: p(232, 370))
            // R: stam en boog
            letters.move(to: p(292, 370)); letters.addLine(to: p(292, 146)); letters.addLine(to: p(340, 146))
            letters.addArc(center: p(340, 208), radius: 62 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            letters.addLine(to: p(292, 270))
            // R: poot
            letters.move(to: p(338, 270)); letters.addLine(to: p(390, 370))
            ctx.stroke(letters, with: .color(.white),
                       style: StrokeStyle(lineWidth: 46 * s, lineCap: .round, lineJoin: .round))

            let dot = Path(ellipseIn: CGRect(x: (404 - 34) * s, y: (126 - 34) * s, width: 68 * s, height: 68 * s))
            ctx.fill(dot, with: .color(LRBrand.logoDot))
            ctx.stroke(dot, with: .color(LRBrand.logoTile), lineWidth: 14 * s)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MoreAppsCard: View {
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 60

    var body: some View {
        Link(destination: LRBrand.url) {
            HStack(spacing: 14) {
                LRLogo(size: logoSize)
                    .overlay(RoundedRectangle(cornerRadius: logoSize * 116 / 512, style: .continuous)
                        .strokeBorder(LRBrand.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("More apps from the developer"))
                        .font(.headline)
                        .foregroundStyle(LRBrand.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Apps for iPhone, iPad, Apple TV and Homey"))
                        .font(.subheadline)
                        .foregroundStyle(LRBrand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    Text(L("View"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LRBrand.onAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(LRBrand.accent, in: Capsule())
                    Text(verbatim: "lrvdlinden.app")
                        .font(.caption2)
                        .foregroundStyle(LRBrand.muted)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .background(LRBrand.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(LRBrand.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("More apps from the developer") + ". " + L("Apps for iPhone, iPad, Apple TV and Homey"))
        .accessibilityHint(Text(verbatim: "lrvdlinden.app"))
        .accessibilityAddTraits(.isLink)
    }
}

private extension Color {
    /// Kleur met een lichte en een donkere variant (hex 0xRRGGBB).
    init(lrLight light: UInt32, dark: UInt32) {
        func comps(_ v: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        }
        let l = comps(light), d = comps(dark)
        #if canImport(UIKit)
        self.init(UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #elseif canImport(AppKit)
        self.init(NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(red: Double(l.0), green: Double(l.1), blue: Double(l.2))
        #endif
    }
}
#endif
