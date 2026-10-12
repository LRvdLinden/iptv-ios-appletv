import SwiftUI
import ImageIO

enum Theme {
    /// Accentkleur (build 52: instelbaar onder Mijn Bingr → Uiterlijk; standaard Bingr-rood)
    static var red: Color { AccentChoice.current.color }
    /// Altijd rood (foutmeldingen e.d.)
    static let alert = Color(hex: 0xE50914)
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
        self.buttonStyle(TVLiftStyle(scale: 1.1))
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }

    @ViewBuilder func plainTVButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVLiftStyle(scale: 1.06, dimWhenIdle: true))
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }
}

/// Primaire knoppen (wit "Afspelen", grijs "Meer info").
/// Apple TV-focus zonder grijze vlakken: iets groter, schaduw, en (optioneel) gedimd als niet geselecteerd.
struct TVLiftStyle: ButtonStyle {
    var scale: CGFloat = 1.08
    var dimWhenIdle = false
    func makeBody(configuration: Configuration) -> some View { Lift(configuration: configuration, scale: scale, dim: dimWhenIdle) }

    private struct Lift: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        let dim: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .environment(\.tvFocused, focused)
                .scaleEffect(configuration.isPressed ? scale * 0.97 : (focused ? scale : 1))
                .opacity(dim && !focused ? 0.75 : 1)
                .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: 16, y: 10)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: focused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

private struct TVFocusedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Is de knop waar dit in staat geselecteerd (Apple TV)?
    var tvFocused: Bool {
        get { self[TVFocusedKey.self] }
        set { self[TVFocusedKey.self] = newValue }
    }
}

struct NetflixButton: View {
    enum Kind { case primary, secondary, accent }
    let title: String
    let icon: String
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) { NetflixButtonLabel(title: title, icon: icon, kind: kind) }
        #if os(tvOS)
        .buttonStyle(TVLiftStyle(scale: 1.06))
        #else
        .plainTVButton()
        #endif
    }
}

private struct NetflixButtonLabel: View {
    let title: String
    let icon: String
    let kind: NetflixButton.Kind
    @Environment(\.tvFocused) private var focused

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: tvScaled(16), weight: .bold))
            .padding(.horizontal, tvScaled(22)).padding(.vertical, tvScaled(10))
            .frame(minWidth: tvScaled(120))
            .foregroundStyle(isLight ? Color.black : Color.white)
            .background(background, in: RoundedRectangle(cornerRadius: tvScaled(6)))
    }

    /// Op Apple TV wordt de geselecteerde knop wit (zoals Netflix); op iPhone is Afspelen altijd wit.
    private var isLight: Bool {
        #if os(tvOS)
        return kind != .accent && focused
        #else
        return kind == .primary
        #endif
    }
    private var background: Color {
        if kind == .accent { return Theme.red }
        return isLight ? .white : Color.white.opacity(0.22)
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
/// Afbeelding van internet, snel: verkleind gedecodeerd op de achtergrond en in het geheugen bewaard,
/// zodat terugscrollen niet opnieuw laadt of hapert (AsyncImage deed beide niet).
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholder: String = ""
    /// Maximale grootte in pixels (posters ~720, achtergronden groter)
    var maxPixel: Int = 720
    @State private var image: CGImage?

    init(url: URL?, contentMode: ContentMode = .fill, placeholder: String = "", maxPixel: Int = 720) {
        self.url = url; self.contentMode = contentMode; self.placeholder = placeholder; self.maxPixel = maxPixel
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Theme.elevated, Theme.card], startPoint: .top, endPoint: .bottom)
                if !placeholder.isEmpty {
                    Text(placeholder).font(.system(size: tvScaled(13), weight: .bold))
                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).padding(8)
                }
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
            let loaded = await ImagePipeline.shared.load(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { image = loaded }
        }
    }
}

/// Laadt en verkleint afbeeldingen buiten de hoofdthread; houdt ze in een geheugencache en op schijf (URLCache).
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let memory: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private func key(_ url: URL, _ px: Int) -> String { "\(px)|\(url.absoluteString)" }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? { memory.object(forKey: key(url, maxPixel) as NSString)?.image }

    func load(_ url: URL, maxPixel: Int) async -> CGImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k as NSString) { return hit.image }
        let session = self.session
        let task: Task<CGImage?, Never> = lock.withLock {
            if let t = inFlight[k] { return t }
            let t = Task.detached(priority: .utility) { () -> CGImage? in
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                return Self.downsample(data, maxPixel: maxPixel)
            }
            inFlight[k] = t
            return t
        }
        let img = await task.value
        lock.withLock { inFlight[k] = nil }
        if let img { memory.setObject(Box(img), forKey: k as NSString, cost: img.width * img.height * 4) }
        return img
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }
}
