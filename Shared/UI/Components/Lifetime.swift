import SwiftUI

/// Abonnementen (build 88): slotje "Lifetime" en uitleg met de vergelijking Gratis/Lifetime.
/// build 97: op alle Apple-platforms nooit een prijs, link, knop of QR-code om te kopen, ook niet als de server
/// `upgrade.link` aanzet (App Store-regels 3.1.1/3.1.3). Alleen een neutrale regel over het account.

/// Waar de uitleg over gaat.
enum LifetimeTopic: Identifiable, Equatable {
    case feature(EntitlementsService.Feature)
    case plan
    case streams
    case devices

    var id: String {
        switch self {
        case .feature(let f): return "feature." + f.rawValue
        case .plan: return "plan"
        case .streams: return "streams"
        case .devices: return "devices"
        }
    }
}

enum PlanText {
    static func name(_ p: EntitlementsService.Plan) -> String {
        p == .free ? L("Free") : L("Lifetime")
    }

    static func servers(_ n: Int?) -> String {
        guard let n else { return L("Unlimited servers") }
        return n == 1 ? L("1 server") : L("%d servers", n)
    }

    /// "2 screens · 8 devices · 1 server"
    static func limits(_ l: EntitlementsService.Limits) -> String {
        var parts: [String] = []
        if let s = l.streams { parts.append(L("%d screens", s)) }
        if let d = l.devices { parts.append(L("%d devices", d)) }
        parts.append(servers(l.servers))
        return parts.joined(separator: " · ")
    }
}

/// Lifetime-icoon (build 104): badge met een uitgespaard vinkje (even-odd), 24×24, in Bingr-rood.
/// Overal waar het abonnement Lifetime getoond wordt (iOS, iPadOS, tvOS en macOS); alleen SwiftUI.
struct LifetimeBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * s) / 2, dy = rect.minY + (rect.height - 24 * s) / 2
        return Self.unit.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy))
    }

    /// Het pad in het 24×24-raster (zelfde coördinaten als het SVG-icoon op de website en Android).
    private static let unit: Path = {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var p = Path()
        p.move(to: P(9.5924, 3.20027))
        p.addCurve(to: P(9.09706, 3.59874), control1: P(9.34888, 3.4078), control2: P(9.22711, 3.51158))
        p.addCurve(to: P(8.1121, 4.00672), control1: P(8.79896, 3.79854), control2: P(8.46417, 3.93721))
        p.addCurve(to: P(7.48008, 4.07522), control1: P(7.95851, 4.03705), control2: P(7.79903, 4.04977))
        p.addCurve(to: P(5.94371, 4.28923), control1: P(6.6787, 4.13918), control2: P(6.278, 4.17115))
        p.addCurve(to: P(4.28923, 5.94371), control1: P(5.17051, 4.56233), control2: P(4.56233, 5.17051))
        p.addCurve(to: P(4.07522, 7.48008), control1: P(4.17115, 6.278), control2: P(4.13918, 6.6787))
        p.addCurve(to: P(4.00672, 8.1121), control1: P(4.04977, 7.79903), control2: P(4.03705, 7.95851))
        p.addCurve(to: P(3.59874, 9.09706), control1: P(3.93721, 8.46417), control2: P(3.79854, 8.79896))
        p.addCurve(to: P(3.20027, 9.5924), control1: P(3.51158, 9.22711), control2: P(3.40781, 9.34887))
        p.addCurve(to: P(2.26522, 10.8301), control1: P(2.67883, 10.2043), control2: P(2.4181, 10.5102))
        p.addCurve(to: P(2.26522, 13.1699), control1: P(1.91159, 11.57), control2: P(1.91159, 12.43))
        p.addCurve(to: P(3.20027, 14.4076), control1: P(2.41811, 13.4898), control2: P(2.67883, 13.7957))
        p.addCurve(to: P(3.59874, 14.9029), control1: P(3.40778, 14.6511), control2: P(3.51158, 14.7729))
        p.addCurve(to: P(4.00672, 15.8879), control1: P(3.79854, 15.201), control2: P(3.93721, 15.5358))
        p.addCurve(to: P(4.07522, 16.5199), control1: P(4.03705, 16.0415), control2: P(4.04977, 16.201))
        p.addCurve(to: P(4.28923, 18.0563), control1: P(4.13918, 17.3213), control2: P(4.17115, 17.722))
        p.addCurve(to: P(5.94371, 19.7108), control1: P(4.56233, 18.8295), control2: P(5.17051, 19.4377))
        p.addCurve(to: P(7.48008, 19.9248), control1: P(6.278, 19.8288), control2: P(6.6787, 19.8608))
        p.addCurve(to: P(8.1121, 19.9933), control1: P(7.79903, 19.9502), control2: P(7.95851, 19.963))
        p.addCurve(to: P(9.09706, 20.4013), control1: P(8.46417, 20.0628), control2: P(8.79896, 20.2015))
        p.addCurve(to: P(9.5924, 20.7997), control1: P(9.22711, 20.4884), control2: P(9.34887, 20.5922))
        p.addCurve(to: P(10.8301, 21.7348), control1: P(10.2043, 21.3212), control2: P(10.5102, 21.5819))
        p.addCurve(to: P(13.1699, 21.7348), control1: P(11.57, 22.0884), control2: P(12.43, 22.0884))
        p.addCurve(to: P(14.4076, 20.7997), control1: P(13.4898, 21.5819), control2: P(13.7957, 21.3212))
        p.addCurve(to: P(14.9029, 20.4013), control1: P(14.6511, 20.5922), control2: P(14.7729, 20.4884))
        p.addCurve(to: P(15.8879, 19.9933), control1: P(15.201, 20.2015), control2: P(15.5358, 20.0628))
        p.addCurve(to: P(16.5199, 19.9248), control1: P(16.0415, 19.963), control2: P(16.201, 19.9502))
        p.addCurve(to: P(18.0563, 19.7108), control1: P(17.3213, 19.8608), control2: P(17.722, 19.8288))
        p.addCurve(to: P(19.7108, 18.0563), control1: P(18.8295, 19.4377), control2: P(19.4377, 18.8295))
        p.addCurve(to: P(19.9248, 16.5199), control1: P(19.8288, 17.722), control2: P(19.8608, 17.3213))
        p.addCurve(to: P(19.9933, 15.8879), control1: P(19.9502, 16.201), control2: P(19.963, 16.0415))
        p.addCurve(to: P(20.4013, 14.9029), control1: P(20.0628, 15.5358), control2: P(20.2015, 15.201))
        p.addCurve(to: P(20.7997, 14.4076), control1: P(20.4884, 14.7729), control2: P(20.5922, 14.6511))
        p.addCurve(to: P(21.7348, 13.1699), control1: P(21.3212, 13.7957), control2: P(21.5819, 13.4898))
        p.addCurve(to: P(21.7348, 10.8301), control1: P(22.0884, 12.43), control2: P(22.0884, 11.57))
        p.addCurve(to: P(20.7997, 9.5924), control1: P(21.5819, 10.5102), control2: P(21.3212, 10.2043))
        p.addCurve(to: P(20.4013, 9.09706), control1: P(20.5922, 9.34887), control2: P(20.4884, 9.22711))
        p.addCurve(to: P(19.9933, 8.1121), control1: P(20.2015, 8.79896), control2: P(20.0628, 8.46417))
        p.addCurve(to: P(19.9248, 7.48008), control1: P(19.963, 7.95851), control2: P(19.9502, 7.79903))
        p.addCurve(to: P(19.7108, 5.94371), control1: P(19.8608, 6.6787), control2: P(19.8288, 6.278))
        p.addCurve(to: P(18.0563, 4.28923), control1: P(19.4377, 5.17051), control2: P(18.8295, 4.56233))
        p.addCurve(to: P(16.5199, 4.07522), control1: P(17.722, 4.17115), control2: P(17.3213, 4.13918))
        p.addCurve(to: P(15.8879, 4.00672), control1: P(16.201, 4.04977), control2: P(16.0415, 4.03705))
        p.addCurve(to: P(14.9029, 3.59874), control1: P(15.5358, 3.93721), control2: P(15.201, 3.79854))
        p.addCurve(to: P(14.4076, 3.20027), control1: P(14.7729, 3.51158), control2: P(14.6511, 3.40781))
        p.addCurve(to: P(13.1699, 2.26522), control1: P(13.7957, 2.67883), control2: P(13.4898, 2.41811))
        p.addCurve(to: P(10.8301, 2.26522), control1: P(12.43, 1.91159), control2: P(11.57, 1.91159))
        p.addCurve(to: P(9.5924, 3.20027), control1: P(10.5102, 2.4181), control2: P(10.2043, 2.67883))
        p.closeSubpath()
        p.move(to: P(16.3735, 9.86314))
        p.addCurve(to: P(16.3735, 8.71216), control1: P(16.6913, 9.5453), control2: P(16.6913, 9.03))
        p.addCurve(to: P(15.2225, 8.71216), control1: P(16.0557, 8.39433), control2: P(15.5403, 8.39433))
        p.addLine(to: P(10.3723, 13.5624))
        p.addLine(to: P(8.77746, 11.9676))
        p.addCurve(to: P(7.62649, 11.9676), control1: P(8.45963, 11.6498), control2: P(7.94432, 11.6498))
        p.addCurve(to: P(7.62649, 13.1186), control1: P(7.30866, 12.2854), control2: P(7.30866, 12.8007))
        p.addLine(to: P(9.79678, 15.2889))
        p.addCurve(to: P(10.9478, 15.2889), control1: P(10.1146, 15.6067), control2: P(10.6299, 15.6067))
        p.addLine(to: P(16.3735, 9.86314))
        p.closeSubpath()
        return p
    }()
}

/// Het Lifetime-icoon als view; `size` = breedte en hoogte van het 24×24-raster.
struct LifetimeBadge: View {
    var size: CGFloat = 20
    var color: Color = Theme.brandRed

    var body: some View {
        LifetimeBadgeShape()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Het label "Lifetime" met het Lifetime-icoon (op slot: dit hoort bij Lifetime).
struct LifetimePill: View {
    var body: some View {
        HStack(spacing: tvScaled(4)) {
            LifetimeBadge(size: tvScaled(14))
            Text(L("Lifetime")).font(.system(size: tvScaled(11), weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, tvScaled(8))
        .padding(.vertical, tvScaled(3))
        .background(Color(hex: 0xF5C451), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("This is a Lifetime feature"))
    }
}

/// Rij met slotje (in een lijst): tikken opent de uitleg.
struct LifetimeLockRow: View {
    let title: String
    let icon: String
    let feature: EntitlementsService.Feature
    @State private var topic: LifetimeTopic?

    var body: some View {
        Button { topic = .feature(feature) } label: {
            HStack {
                Label { Text(title).foregroundStyle(Color.primary) } icon: { Image(systemName: icon) }
                Spacer(minLength: 8)
                LifetimePill()
            }
            .contentShape(Rectangle())
        }
        .lifetimeSheet($topic)
    }
}

extension View {
    /// Toont de uitleg over Lifetime zodra `topic` gezet wordt.
    func lifetimeSheet(_ topic: Binding<LifetimeTopic?>) -> some View {
        sheet(item: topic) { t in
            LifetimeInfoView(topic: t)
                #if os(iOS)
                .presentationDragIndicator(.visible)
                #elseif os(macOS)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 640)
                #endif
        }
    }
}

/// Uitleg in een venster: titel, tekst en vergelijking (build 97: zonder weg naar een aankoop).
struct LifetimeInfoView: View {
    let topic: LifetimeTopic
    @ObservedObject private var ent = EntitlementsService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tvScaled(18)) {
                LifetimeExplanation(topic: topic)
                NetflixButton(title: L("Done"), icon: "checkmark", kind: .secondary) { dismiss() }
                    .padding(.top, tvScaled(4))
            }
            .padding(tvScaled(28))
            .frame(maxWidth: tvScaled(640), alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// Volledige pagina op slot (bijv. Statistieken op een Gratis-account).
struct LifetimeLockedView: View {
    let feature: EntitlementsService.Feature

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(18)) {
            LifetimeExplanation(topic: .feature(feature))
        }
        .padding(.vertical, tvScaled(20))
        #if os(tvOS)
        .focusable()
        #endif
    }
}

/// Kop, tekst, vergelijking en een neutrale regel over het account (build 97).
struct LifetimeExplanation: View {
    let topic: LifetimeTopic
    @ObservedObject private var ent = EntitlementsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(18)) {
            HStack(spacing: tvScaled(12)) {
                if topic == .plan && !ent.isFree {
                    LifetimeBadge(size: tvScaled(34))
                } else {
                    Image(systemName: icon).font(.system(size: tvScaled(26), weight: .semibold)).foregroundStyle(Color(hex: 0xF5C451))
                }
                Text(title).font(.system(size: tvScaled(24), weight: .bold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message).font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PlanComparison()
            LifetimeUpgradeCTA()
        }
    }

    private var icon: String {
        switch topic {
        case .feature: return "lock.fill"
        case .plan: return "person.crop.circle"  // Lifetime: LifetimeBadge
        case .streams: return "person.3.fill"
        case .devices: return "laptopcomputer.and.iphone"
        }
    }

    private var title: String {
        switch topic {
        case .feature: return L("This is a Lifetime feature")
        case .plan: return L("Plan") + ": " + PlanText.name(ent.plan ?? .lifetime)
        case .streams, .devices: return L("Compare plans")
        }
    }

    private var message: String {
        switch topic {
        case .feature(let f):
            return L("%@ is part of Lifetime. Your Bingr account uses the Free plan.", f.title)
        case .plan:
            return ent.isFree ? L("Your Bingr account uses the Free plan. Lifetime unlocks every feature of Bingr for your account.")
                              : L("Your Bingr account has Lifetime. All features are unlocked. Thank you for supporting Bingr!")
        case .streams:
            return L("Your plan allows %d screens at the same time.", ent.limits.streams ?? 0)
        case .devices:
            return L("Your plan allows %d devices.", ent.limits.devices ?? 0)
        }
    }
}

/// Vergelijking Gratis en Lifetime; het huidige abonnement is gemarkeerd.
struct PlanComparison: View {
    @ObservedObject private var ent = EntitlementsService.shared

    private var free: EntitlementsService.Limits { ent.plan == .free ? ent.limits : EntitlementsService.freeLimits }
    private var lifetime: EntitlementsService.Limits { ent.plan == .lifetime ? ent.limits : EntitlementsService.lifetimeLimits }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: tvScaled(12), verticalSpacing: tvScaled(10)) {
            GridRow {
                Text(verbatim: "")
                header(.free)
                header(.lifetime)
            }
            Divider().overlay(Color.white.opacity(0.12)).gridCellColumns(3)
            row(L("Screens at the same time"), "\(free.streams ?? 0)", "\(lifetime.streams ?? 0)")
            row(L("Devices"), "\(free.devices ?? 0)", "\(lifetime.devices ?? 0)")
            row(L("Servers"), free.servers.map { "\($0)" } ?? L("Unlimited"), lifetime.servers.map { "\($0)" } ?? L("Unlimited"))
            check(L("Statistics"))
            check(L("Watching now and watch history"))
            check("Trakt")
            check(L("Accent colors"))
        }
        .font(.system(size: tvScaled(14)))
        .padding(tvScaled(16))
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .accessibilityElement(children: .contain)
    }

    private func header(_ p: EntitlementsService.Plan) -> some View {
        let isCurrent = ent.plan == p
        return Text(PlanText.name(p))
            .font(.system(size: tvScaled(14), weight: .bold))
            .foregroundStyle(isCurrent ? .black : .white)
            .padding(.horizontal, tvScaled(8)).padding(.vertical, tvScaled(3))
            .background(isCurrent ? Color(hex: 0xF5C451) : Color.clear, in: Capsule())
            .gridColumnAlignment(.center)
    }

    private func row(_ title: String, _ a: String, _ b: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text(a).foregroundStyle(Theme.secondary).monospacedDigit().gridColumnAlignment(.center)
            Text(b).foregroundStyle(.white).bold().monospacedDigit().gridColumnAlignment(.center)
        }
    }

    private func check(_ title: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "minus").foregroundStyle(Theme.secondary)
                .accessibilityLabel(L("Not included"))
            Image(systemName: "checkmark").foregroundStyle(Theme.green).bold()
                .accessibilityLabel(L("Included"))
        }
    }
}

/// build 97: neutrale regel op een Gratis-account: "Beschikbaar met Lifetime" en "Je beheert je account op
/// bingr.online", zonder link, knop, QR-code of prijs (hard uit, los van `upgrade` van de server).
struct LifetimeUpgradeCTA: View {
    @ObservedObject private var ent = EntitlementsService.shared

    var body: some View {
        if ent.isFree {
            VStack(alignment: .leading, spacing: tvScaled(4)) {
                Text(L("Available with Lifetime"))
                    .font(.system(size: tvScaled(15), weight: .semibold)).foregroundStyle(.white)
                Text(L("You manage your account at bingr.online."))
                    .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Mijn Bingr: "Abonnement: Gratis / Lifetime" met de limieten; tikken opent de vergelijking.
struct PlanRow: View {
    @ObservedObject private var ent = EntitlementsService.shared
    @State private var topic: LifetimeTopic?

    var body: some View {
        if let plan = ent.plan {
            Button { topic = .plan } label: {
                HStack(spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Plan") + ": " + PlanText.name(plan)).foregroundStyle(Color.primary)
                            Text(PlanText.limits(ent.limits)).font(.caption).foregroundStyle(Theme.secondary)
                        }
                    } icon: {
                        if plan == .lifetime {
                            LifetimeBadge(size: tvScaled(24))
                        } else {
                            Image(systemName: "person.crop.circle").foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .lifetimeSheet($topic)
        }
    }
}

/// Bij "Too many people are watching" en "Too many devices": het abonnement en de vergelijking (alleen op Gratis).
struct PlanLimitNote: View {
    let topic: LifetimeTopic
    /// `plan` uit de 403 van de server (`stream_limit` / `device_limit`), als die er was
    var plan: String? = nil
    @ObservedObject private var ent = EntitlementsService.shared
    @State private var shown: LifetimeTopic?

    var body: some View {
        Group {
            if ent.isFree || plan == "free" { note }
        }
        .task {
            // de server noemt een ander abonnement dan bekend: opnieuw ophalen
            if let plan, plan != ent.plan?.rawValue { await ent.refresh(force: true) }
        }
    }

    @ViewBuilder private var note: some View {
            VStack(alignment: .leading, spacing: tvScaled(10)) {
                HStack(spacing: tvScaled(8)) {
                    LifetimePill()
                    Text(text).font(.system(size: tvScaled(14))).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { shown = topic } label: {
                    Text(L("Compare plans")).font(.system(size: tvScaled(14), weight: .semibold)).underline()
                        .foregroundStyle(.white)
                }
                .plainTVButton()
            }
            .lifetimeSheet($shown)
    }

    private var text: String {
        switch topic {
        case .streams:
            return L("Lifetime allows %d screens at the same time.", EntitlementsService.lifetimeLimits.streams ?? 6)
        case .devices:
            return L("Lifetime allows %d devices.", EntitlementsService.lifetimeLimits.devices ?? 15)
        default:
            return L("This is a Lifetime feature")
        }
    }
}
