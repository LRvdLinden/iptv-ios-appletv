import SwiftUI

/// Abonnementen (build 88): slotje "Lifetime", uitleg met de vergelijking Gratis/Lifetime en (alleen als de
/// server `upgrade.link` toestaat) de weg naar de website: iPhone, iPad en Mac openen de link in de browser,
/// Apple TV toont een QR-code. Zonder `upgrade.link` geen link, knop, QR-code, prijs of verwijzing naar de website
/// (App Store-regels 3.1.1/3.1.3).

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

/// Het slotje: "🔒 Lifetime".
struct LifetimeBadge: View {
    var body: some View {
        HStack(spacing: tvScaled(4)) {
            Image(systemName: "lock.fill").font(.system(size: tvScaled(10), weight: .bold))
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
                LifetimeBadge()
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

/// Uitleg in een venster: titel, tekst, vergelijking en (als het mag) de weg naar de website.
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

/// Kop, tekst, vergelijking en de weg naar de website (alleen met `upgrade.link`).
struct LifetimeExplanation: View {
    let topic: LifetimeTopic
    @ObservedObject private var ent = EntitlementsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(18)) {
            HStack(spacing: tvScaled(12)) {
                Image(systemName: icon).font(.system(size: tvScaled(26), weight: .semibold)).foregroundStyle(Color(hex: 0xF5C451))
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
        case .plan: return ent.isFree ? "person.crop.circle" : "crown.fill"
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

/// De weg naar de website: alleen op een Gratis-account én als de server `upgrade.link` toestaat.
/// iPhone, iPad en Mac: de link in de browser (Safari, niet in de app); Apple TV: QR-code.
struct LifetimeUpgradeCTA: View {
    @ObservedObject private var ent = EntitlementsService.shared
    #if !os(tvOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        if ent.isFree, let url = ent.upgradeURL {
            #if os(tvOS)
            HStack(alignment: .center, spacing: tvScaled(24)) {
                if let qr = QRCode.image(url.absoluteString) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Scan the QR code with your phone to upgrade to Lifetime."))
                        .font(.system(size: 24)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: displayURL(url)).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    if let p = ent.upgradePrice {
                        Text(L("One-time %@", p)).font(.system(size: 22)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            #else
            VStack(alignment: .leading, spacing: tvScaled(8)) {
                NetflixButton(title: ent.upgradePrice.map { L("Upgrade to Lifetime · %@", $0) } ?? L("Upgrade to Lifetime"),
                              icon: "arrow.up.right", kind: .accent) { openURL(url) }
                Text(L("Opens %@ in your browser.", displayURL(url)))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
            }
            #endif
        }
    }

    private func displayURL(_ u: URL) -> String {
        var s = u.absoluteString.replacingOccurrences(of: "https://", with: "")
        if s.hasSuffix("/") { s.removeLast() }
        return s
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
                        Image(systemName: plan == .lifetime ? "crown.fill" : "person.crop.circle")
                            .foregroundStyle(plan == .lifetime ? Color(hex: 0xF5C451) : Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    if plan == .lifetime {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0xF5C451))
                    }
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
                    LifetimeBadge()
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
