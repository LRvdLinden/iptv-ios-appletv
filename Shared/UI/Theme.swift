import SwiftUI

enum Theme {
    static let red = Color(hex: 0xE50914)
    static let bg = Color.black
    static let card = Color(hex: 0x181818)
    static let elevated = Color(hex: 0x232323)
    static let secondary = Color(hex: 0xB3B3B3)
    static let imdb = Color(hex: 0xF5C518)
    static let green = Color(hex: 0x46D369)

    #if os(tvOS)
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 400
    static let rowSpacing: CGFloat = 40
    static let edge: CGFloat = 80
    static let titleFont = Font.system(size: 38, weight: .bold)
    #else
    static let posterWidth: CGFloat = 112
    static let landscapeWidth: CGFloat = 230
    static let rowSpacing: CGFloat = 8
    static let edge: CGFloat = 16
    static let titleFont = Font.system(size: 19, weight: .bold)
    #endif
    static var posterHeight: CGFloat { posterWidth * 1.5 }
}

/// Netflix-achtige "N"-wordmark voor Bingr.
/// Bingr-logo (zelfde als in de intro): witte afgeronde letters met een rode streep eronder.
struct BingrLogo: View {
    var size: CGFloat = 34
    var body: some View {
        VStack(alignment: .center, spacing: size * 0.1) {
            Text("BINGR")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .kerning(size * 0.02)
                .foregroundStyle(.white)
            Capsule().fill(Theme.red)
                .frame(height: max(2, size * 0.09))
                .padding(.horizontal, size * 0.04)
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.5), radius: size * 0.15)
        .accessibilityLabel("Bingr")
    }
}

/// Knopstijl die op tvOS meeschaalt met focus en op iOS licht indrukt.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Poster/kaart-knoppen: op tvOS de systeem "card"-focus (lift + parallax), op iOS licht indrukken.
    @ViewBuilder func cardButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }

    @ViewBuilder func plainTVButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.plain)
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }
}

/// Primaire knoppen (wit "Afspelen", grijs "Meer info").
struct NetflixButton: View {
    enum Kind { case primary, secondary, accent }
    let title: String
    let icon: String
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: tvScaled(16), weight: .bold))
                .padding(.horizontal, tvScaled(22)).padding(.vertical, tvScaled(10))
                .frame(minWidth: tvScaled(120))
                .foregroundStyle(kind == .primary ? .black : .white)
                .background(background, in: RoundedRectangle(cornerRadius: tvScaled(6)))
        }
        .plainTVButton()
    }

    private var background: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Color.white.opacity(0.22)
        case .accent: return Theme.red
        }
    }
}

func tvScaled(_ v: CGFloat) -> CGFloat {
    #if os(tvOS)
    return v * 1.9
    #else
    return v
    #endif
}

struct IMDbBadge: View {
    let rating: String
    var body: some View {
        HStack(spacing: 4) {
            Text("IMDb").font(.system(size: tvScaled(10), weight: .black))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.imdb, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
            Text(rating).font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(.white)
        }
    }
}

struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: tvScaled(18)))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Theme.red)
            .shadow(radius: 3)
    }
}

/// Asynchroon geladen afbeelding met placeholder.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholder: String = ""

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
            default:
                ZStack {
                    LinearGradient(colors: [Theme.elevated, Theme.card], startPoint: .top, endPoint: .bottom)
                    if !placeholder.isEmpty {
                        Text(placeholder).font(.system(size: tvScaled(13), weight: .bold))
                            .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).padding(8)
                    }
                }
            }
        }
    }
}
