import SwiftUI

#if !os(tvOS)
/// Build 161: kaart "Meer apps van de ontwikkelaar" onderaan in Instellingen (iPhone, iPad en Mac; niet op Apple TV).
/// De hele rij is één link naar https://lrvdlinden.app en opent in de externe browser (Safari / standaardbrowser).
struct MoreAppsSection: View {
    var body: some View {
        Section {
            MoreAppsCard()
        } header: { Text(L("Discover")) }
    }
}

struct MoreAppsCard: View {
    static let url = URL(string: "https://lrvdlinden.app")!
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(Self.url) } label: {
            HStack(spacing: 12) {
                // app-icoon: verloop in Bingr-rood naar donkerrood met een raster van 4 vakjes
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.brandRed, Color(hex: 0x7A0410)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("More apps from the developer"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(L("Apps for iPhone, iPad, Apple TV and Homey"))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("View"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.red)
                    Text(verbatim: "lrvdlinden.app")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("More apps from the developer"))
        .accessibilityValue(Text(verbatim: "lrvdlinden.app"))
        .accessibilityHint(L("Apps for iPhone, iPad, Apple TV and Homey"))
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
    }
}
#endif
