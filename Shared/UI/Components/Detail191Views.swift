import SwiftUI

// Build 191: onderdelen van de detailpagina (tabbladen, actierij met symbool en tekst, trailers).

/// Eén trailer in het tabblad Trailers.
struct Trailer191Entry: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Knop in de actierij: symbool met de tekst eronder (iPad, Mac en Apple TV).
struct DetailActionLabel191<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: tvScaled(6)) {
            icon().frame(height: tvScaled(26))
            Text(title)
                .font(.system(size: tvScaled(12), weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: tvScaled(54))
        .contentShape(Rectangle())
    }
}

/// Tabblad: iOS, iPadOS en macOS een rode streep boven het actieve tabblad en grijze tekst voor de andere;
/// Apple TV een focusbare knop met witte focus.
struct DetailTabStyle191: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabBody(label: configuration.label, active: active, pressed: configuration.isPressed)
    }

    private struct TabBody<L: View>: View {
        let label: L
        let active: Bool
        let pressed: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            #if os(tvOS)
            VStack(spacing: 6) {
                label
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(focused ? Color.black : (active ? Color.white : Theme.secondary))
                Rectangle().fill(active ? Theme.red : Color.clear).frame(height: 4)
            }
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            #else
            VStack(spacing: 8) {
                Rectangle().fill(active ? Theme.red : Color.clear).frame(height: 3)
                label
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Theme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .fixedSize(horizontal: true, vertical: false)
            .opacity(pressed ? 0.6 : 1)
            .contentShape(Rectangle())
            #endif
        }
    }
}
