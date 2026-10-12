import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Accentkleur: knoppen en accenten in plaats van vast rood ("red", "blue", "green", "purple", "orange", "pink").
/// Build 52/53: één kleur voor het hele account (`settings.shared.accentColor`).
/// Build 54: per profiel, in `account_data.profiles[].accentColor` (zie docs/ACCOUNT.md → "Build 54").
enum AccentChoice: String, CaseIterable, Identifiable {
    case red, blue, green, purple, orange, pink
    var id: String { rawValue }
    /// De kleur waarmee de app nu tekent: die van het actieve profiel (alleen op dit apparaat, volgt het profiel)
    static let key = "ui.accentColor.active"
    /// De oude kleur van het account (build 52/53, `settings.shared.accentColor`): alleen nog voor de migratie
    static let legacyKey = "ui.accentColor"
    /// De oude kleur is (op dit apparaat) naar de profielen gekopieerd; daarna wordt hij niet meer gelezen
    static let migratedKey = "ui.accentColor.migrated.v54"

    static var current: AccentChoice {
        if let c = UserDefaults.standard.string(forKey: key).flatMap(AccentChoice.init(rawValue:)) { return c }
        return legacy ?? .red
    }

    /// De oude, account-brede kleur (zolang de migratie nog niet gedaan is)
    static var legacy: AccentChoice? {
        UserDefaults.standard.string(forKey: legacyKey).flatMap(AccentChoice.init(rawValue:))
    }

    /// Kleur van een profiel. Zonder eigen kleur: vóór de migratie de oude kleur (zodat niets verandert), daarna rood.
    static func of(_ p: ViewerProfile?) -> AccentChoice {
        if let c = p?.accentColor.flatMap(AccentChoice.init(rawValue:)) { return c }
        if !UserDefaults.standard.bool(forKey: migratedKey), let l = legacy { return l }
        return .red
    }

    var color: Color {
        switch self {
        case .red: return Color(hex: 0xE50914)
        case .blue: return Color(hex: 0x2F7CF6)
        case .green: return Color(hex: 0x1DB954)
        case .purple: return Color(hex: 0x9B5CF6)
        case .orange: return Color(hex: 0xF97316)
        case .pink: return Color(hex: 0xEC4899)
        }
    }

    var title: String {
        switch self {
        case .red: return L("Red")
        case .blue: return L("Blue")
        case .green: return L("Green")
        case .purple: return L("Purple")
        case .orange: return L("Orange")
        case .pink: return L("Pink")
        }
    }
}

/// App-icoon (build 52), alleen lokaal: iPhone/iPad via alternatieve app-iconen, Mac via het Dock-icoon.
/// Build 54: alleen het hoofdprofiel mag het wijzigen. De keuze staat in UserDefaults (blijft na een update staan)
/// en wordt bij het starten gelijkgetrokken met wat het systeem toont (`reconcile()`).
enum AppIconChoice: String, CaseIterable, Identifiable {
    case standard = "Default", dark = "Dark", light = "Light", blue = "Blue", gold = "Gold"
    var id: String { rawValue }
    static let key = "ui.appIcon"

    static var current: AppIconChoice {
        AppIconChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard
    }

    /// Naam van de icoonset in de asset-catalogus (nil = het standaardicoon)
    var iconName: String? { self == .standard ? nil : "AppIcon-\(rawValue)" }
    /// Voorbeeldafbeelding in de asset-catalogus
    var previewName: String { "IconPreview-\(rawValue)" }

    var title: String {
        switch self {
        case .standard: return L("Classic")
        case .dark: return L("Dark")
        case .light: return L("Light")
        case .blue: return L("Blue")
        case .gold: return L("Gold")
        }
    }

    /// Kan dit apparaat het app-icoon wisselen?
    @MainActor static var isSupported: Bool {
        #if os(iOS)
        return UIApplication.shared.supportsAlternateIcons
        #elseif os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Icoon instellen. iPhone/iPad: het systeem toont daarna zelf een melding.
    @MainActor func apply(completion: ((Bool) -> Void)? = nil) {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else { completion?(false); return }
        guard UIApplication.shared.alternateIconName != iconName else { completion?(true); return }
        UIApplication.shared.setAlternateIconName(iconName) { error in
            Task { @MainActor in completion?(error == nil) }
        }
        #elseif os(macOS)
        Self.applyDockIcon()
        completion?(true)
        #else
        completion?(false)
        #endif
    }

    /// Bij het starten: de bewaarde keuze en het icoon van het systeem gelijktrekken. Op iPhone/iPad geldt wat het
    /// systeem toont (dat blijft na een update staan; opnieuw instellen zou een melding geven). Op de Mac het Dock-icoon.
    @MainActor static func reconcile() {
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let system = UIApplication.shared.alternateIconName
        let choice = allCases.first { $0.iconName == system } ?? .standard
        if UserDefaults.standard.string(forKey: key) != choice.rawValue {
            UserDefaults.standard.set(choice.rawValue, forKey: key)
        }
        #elseif os(macOS)
        applyDockIcon()
        #endif
    }

    #if os(macOS)
    /// Mac: het Dock-icoon zolang Bingr open is (macOS kent geen alternatieve app-iconen).
    @MainActor static func applyDockIcon() {
        let c = current
        NSApplication.shared.applicationIconImage = c == .standard ? nil : NSImage(named: c.previewName)
    }
    #endif
}

/// Voorbeeld van een app-icoon (uit de asset-catalogus).
struct AppIconPreview: View {
    let choice: AppIconChoice
    var body: some View {
        #if os(iOS)
        if let img = UIImage(named: choice.previewName) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Theme.card)
        }
        #elseif os(macOS)
        if let img = NSImage(named: choice.previewName) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Theme.card)
        }
        #else
        RoundedRectangle(cornerRadius: 12).fill(Theme.card)
        #endif
    }
}

/// Mijn Bingr → Uiterlijk: app-icoon (alleen het hoofdprofiel, waar het kan) en de accentkleur van dit profiel.
struct AppearanceView: View {
    @EnvironmentObject var store: CloudStore
    @State private var icon = AppIconChoice.current

    /// Hoofdprofiel (of nog geen profielen): alleen dan het app-icoon tonen
    private var isMain: Bool { store.isMainActive || store.profiles.isEmpty || store.activeProfileID == nil }
    /// De accentkleur van het actieve profiel
    private var accent: String { AccentChoice.of(store.activeProfile).rawValue }

    var body: some View {
        List {
            if isMain && AppIconChoice.isSupported {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tvScaled(16)) {
                            ForEach(AppIconChoice.allCases) { c in
                                Button {
                                    icon = c
                                    c.apply()
                                } label: {
                                    VStack(spacing: 6) {
                                        AppIconPreview(choice: c)
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(icon == c ? Theme.red : .white.opacity(0.15), lineWidth: icon == c ? 3 : 1))
                                        Text(c.title).font(.caption)
                                            .foregroundStyle(icon == c ? .white : Theme.secondary)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(icon == c ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                } header: { Text(L("App icon")) } footer: {
                    #if os(macOS)
                    Text(L("On the Mac the icon is shown in the Dock while Bingr is open."))
                    #else
                    Text(L("The app icon is only changed on this device."))
                    #endif
                }
            }
            Section {
                ForEach(AccentChoice.allCases) { c in
                    Button { setAccent(c) } label: {
                        HStack(spacing: 14) {
                            Circle().fill(c.color).frame(width: tvScaled(22), height: tvScaled(22))
                            Text(c.title)
                            Spacer()
                            if accent == c.rawValue { Image(systemName: "checkmark").foregroundStyle(c.color) }
                        }
                    }
                }
            } header: { Text(L("Accent color")) } footer: {
                Text(L("Applies to this profile only, on all your devices. Used for buttons, progress bars and highlights."))
            }
        }
        .navigationTitle(L("Appearance"))
    }

    /// Kleur bij het actieve profiel bewaren (gaat via ProfileSync naar de account); zonder profiel alleen lokaal.
    private func setAccent(_ c: AccentChoice) {
        if store.activeProfile != nil {
            store.updateActivePreferences { $0.accentColor = c.rawValue }
        } else {
            UserDefaults.standard.set(c.rawValue, forKey: AccentChoice.key)
        }
    }
}
