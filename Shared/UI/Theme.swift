import SwiftUI
import ImageIO

enum Theme {
    /// Accentkleur (build 52: instelbaar onder Mijn Bingr → Uiterlijk; standaard Bingr-rood)
    static var red: Color { AccentChoice.current.color }
    /// Tekst/iconen óp een vlak in de accentkleur: wit, bij een licht accent (goud) donker
    static var onAccent: Color { AccentChoice.current.onColor }
    /// Altijd rood (foutmeldingen e.d.)
    static let alert = Color(hex: 0xE50914)
    /// Bingr-rood, vast (ook als het profiel een andere accentkleur heeft): o.a. het Lifetime-icoon
    static let brandRed = Color(hex: 0xE50914)
    static let bg = Color.black
    static let card = Color(hex: 0x181818)
    static let elevated = Color(hex: 0x232323)
    static let secondary = Color(hex: 0xB3B3B3)
    static let imdb = Color(hex: 0xF5C518)
    static let green = Color(hex: 0x46D369)
    /// Icoon voor "Andere bron(nen)" (build 58): overal hetzelfde, op detailpagina's, in de speler en bij een fout.
    static let otherSourceIcon = "square.stack.3d.up"

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

    /// Label van een `.borderedProminent`-knop in de accentkleur: bij een licht accent (goud) donkere tekst.
    /// Bij de andere kleuren niets zetten, zodat het systeem (o.a. de focus op Apple TV) zelf de tekstkleur kiest.
    @ViewBuilder func onAccentLabel() -> some View {
        if AccentChoice.current.isLight {
            self.foregroundStyle(Theme.onAccent)
        } else {
            self
        }
    }

    @ViewBuilder func plainTVButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVLiftStyle(scale: 1.06, dimWhenIdle: true))
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }
}

/// Primaire knoppen (grijs "Meer info" e.d.; "Afspelen" heeft vanaf build 58 `PlayButtonStyle`).
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

/// De afspeelknop (build 58): gevuld in de accentkleur van het actieve profiel, witte tekst en icoon
/// (bij een licht accent zoals goud donkere tekst, `Theme.onAccent`).
/// Eigen stijl die zelf `isFocused` afhandelt, zodat de systeemfocus (wit vlak) hem op Apple TV niet weer
/// wit maakt: geselecteerd = groter, iets lichter accent, witte rand en schaduw.
struct PlayButtonStyle: ButtonStyle {
    /// `nil` = capsule, anders een afgeronde rechthoek met deze straal
    var cornerRadius: CGFloat? = nil
    var scale: CGFloat = 1.06
    func makeBody(configuration: Configuration) -> some View {
        PlayBody(configuration: configuration, cornerRadius: cornerRadius, scale: scale)
    }

    private struct PlayBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat?
        let scale: CGFloat
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.onAccent)
                .background { shape.fill(Theme.red) }
                // geselecteerd: iets lichter; ingedrukt: iets donkerder
                .overlay { shape.fill(.white.opacity(isFocused ? 0.14 : 0)) }
                .overlay { shape.fill(.black.opacity(configuration.isPressed ? 0.18 : 0)) }
                .overlay { shape.stroke(.white, lineWidth: isFocused ? tvScaled(2) : 0) }
                .environment(\.tvFocused, isFocused)
                .opacity(enabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? effectiveScale * 0.97 : effectiveScale)
                .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 16, y: 10)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }

        private var shape: AnyShape {
            if let r = cornerRadius { return AnyShape(RoundedRectangle(cornerRadius: r)) }
            return AnyShape(Capsule())
        }
        /// Focus telt alleen op Apple TV (op iPad/Mac met toetsenbord geen sprong in grootte)
        private var isFocused: Bool {
            #if os(tvOS)
            return focused
            #else
            return false
            #endif
        }
        private var effectiveScale: CGFloat { isFocused ? scale : 1 }
    }
}

struct NetflixButton: View {
    /// `.play`: de primaire afspeelknop (accentkleur, zie `PlayButtonStyle`)
    enum Kind { case primary, secondary, accent, play }
    let title: String
    let icon: String
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        if kind == .play {
            Button(action: action) { NetflixButtonLabel(title: title, icon: icon, kind: kind) }
                .buttonStyle(PlayButtonStyle(cornerRadius: tvScaled(6)))
        } else {
            styled
        }
    }

    @ViewBuilder private var styled: some View {
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
            .modifier(Fill(kind: kind, isLight: isLight, background: background))
    }

    /// Bij `.play` tekent `PlayButtonStyle` zelf de achtergrond en tekstkleur.
    private struct Fill: ViewModifier {
        let kind: NetflixButton.Kind
        let isLight: Bool
        let background: Color
        func body(content: Content) -> some View {
            if kind == .play {
                content.contentShape(RoundedRectangle(cornerRadius: tvScaled(6)))
            } else {
                content
                    .foregroundStyle(kind == .accent ? Theme.onAccent : (isLight ? Color.black : Color.white))
                    .background(background, in: RoundedRectangle(cornerRadius: tvScaled(6)))
            }
        }
    }

    /// Op Apple TV wordt de geselecteerde knop wit (zoals Netflix); op iPhone is Afspelen altijd wit.
    private var isLight: Bool {
        #if os(tvOS)
        return kind != .accent && kind != .play && focused
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
            .foregroundStyle(Theme.onAccent, Theme.red)
            .shadow(radius: 3)
    }
}

/// Korte tijd ("20:45") voor lijsten en de tv-gids (build 56): één gedeelde formatter in plaats van per cel
/// opnieuw opmaken. Zelfde uitkomst als `formatted(date: .omitted, time: .shortened)` (taal/regio van het apparaat).
enum TimeText {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let lock = NSLock()

    static func short(_ d: Date) -> String { lock.withLock { formatter.string(from: d) } }
}

/// Of er nu gescrold wordt (of de focus/aanwijzer door een lijst gaat), build 56. Zwaar werk dat kan wachten
/// (opnieuw filteren na nieuwe leeftijdsclassificaties, collecties bijwerken na een sync) wacht hierop,
/// zodat het niet midden in het scrollen de hoofdthread bezet.
final class ScrollActivity: @unchecked Sendable {
    static let shared = ScrollActivity()
    /// Zo lang na de laatste beweging telt het nog als scrollen
    static let quiet: TimeInterval = 1.5
    private let lock = NSLock()
    private var last = Date.distantPast

    /// Aanroepen bij elke scroll- of focusbeweging (goedkoop; vanaf elke thread).
    func touch() {
        let now = Date()
        lock.withLock { last = now }
    }

    var isActive: Bool {
        let l = lock.withLock { last }
        return Date().timeIntervalSince(l) < Self.quiet
    }

    /// Wacht tot er even niet gescrold is (of de taak geannuleerd wordt).
    func waitUntilIdle() async {
        while isActive && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
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
        Screenshots.configure(c)   // App Store-screenshots: alleen de lokaal getekende afbeeldingen (file://)
        return URLSession(configuration: c)
    }()

    private func key(_ url: URL, _ px: Int) -> String { "\(px)|\(url.absoluteString)" }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? { memory.object(forKey: key(url, maxPixel) as NSString)?.image }
    /// Build 132: deze afbeelding in welke gangbare grootte ook al in het geheugen staat (posters 720, koppen groter).
    func cachedAny(_ url: URL) -> CGImage? {
        for px in [720, 1600, 1100, 1200, 1920, 900, 600, 360] { if let hit = cached(url, maxPixel: px) { return hit } }
        return nil
    }

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
