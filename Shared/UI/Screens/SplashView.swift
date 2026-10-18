import SwiftUI
import AVFoundation
import ImageIO

/// Intro: covers van films en series uit je afspeellijst regenen van boven naar beneden,
/// daarna springen de letters van BINGR één voor één omhoog met een glanzende veeg erover.
///
/// Build 130 (vloeiend op Apple TV): de covers worden vóór de animatie op de achtergrond geladen en verkleind
/// (geen AsyncImage die midden in de val decodeert), de coverlaag wordt in één keer via Metal getekend
/// (`drawingGroup`), en de view hangt niet aan state die tijdens het opstarten verandert (`Equatable`: de
/// omringende RootView mag opnieuw tekenen zonder dat de intro opnieuw opgebouwd wordt).
struct SplashView: View, Equatable {
    let onFinished: () -> Void

    static func == (a: SplashView, b: SplashView) -> Bool { true }

    @State private var images: [CGImage] = []
    @State private var fall = false
    @State private var dim = false
    @State private var lettersIn = 0
    @State private var shine = false
    @State private var out = false

    private let letters = Array("BINGR")
    private var size: CGFloat { tvScaled(70) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // vallende covers (één laag, via Metal getekend)
                ZStack {
                    ForEach(Array(tiles(in: geo.size).enumerated()), id: \.offset) { _, t in
                        FallingCover(image: t.image, colorSeed: t.seed)
                            .frame(width: t.width, height: t.width * 1.5)
                            .rotationEffect(.degrees(fall ? t.endRotation : t.startRotation))
                            .position(x: t.x, y: fall ? geo.size.height + t.width * 1.6 : -t.width * 1.6)
                            .animation(.easeIn(duration: t.duration).delay(t.delay), value: fall)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .drawingGroup()
                .allowsHitTesting(false)

                // donker worden zodat de naam eruit springt
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.95), .black.opacity(0.2)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(dim ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: dim)
                    .ignoresSafeArea()

                // app-naam
                HStack(spacing: size * 0.02) {
                    ForEach(Array(letters.enumerated()), id: \.offset) { i, ch in
                        Text(String(ch))
                            .font(.system(size: size, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .offset(y: lettersIn > i ? 0 : size * 0.9)
                            .opacity(lettersIn > i ? 1 : 0)
                            .scaleEffect(lettersIn > i ? 1 : 0.6, anchor: .bottom)
                    }
                }
                .overlay(
                    // glanzende veeg + rode onderstreping
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: size * 1.2)
                        .rotationEffect(.degrees(20))
                        .offset(x: shine ? size * 3.2 : -size * 3.2)
                        .blendMode(.overlay)
                        .mask(HStack(spacing: size * 0.02) {
                            ForEach(Array(letters.enumerated()), id: \.offset) { _, ch in
                                Text(String(ch)).font(.system(size: size, weight: .heavy, design: .rounded))
                            }
                        })
                )
                .overlay(alignment: .bottom) {
                    Capsule().fill(Theme.red)
                        .frame(width: shine ? size * 3.4 : 0, height: size * 0.08)
                        .offset(y: size * 0.32)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: shine)
                }
                .shadow(color: .black.opacity(0.8), radius: 20)
                .scaleEffect(out ? 1.15 : 1)
                .opacity(out ? 0 : 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // hele scherm (ook achter de notch): de coverlaag wordt via drawingGroup binnen zijn kader getekend
        .ignoresSafeArea()
        .task {
            // covers eerst (achtergrond, hooguit even wachten), dan pas de animatie en de tune
            images = await SplashPosters.preload(count: Self.distinctCovers, maxPixel: Self.coverPixels, deadline: 0.6)
            await run()
        }
    }

    #if os(tvOS)
    private static let distinctCovers = 14
    private static let coverPixels = 420
    #else
    private static let distinctCovers = 12
    private static let coverPixels = 360
    #endif

    private struct Tile { var image: CGImage?; var seed: Int; var x: CGFloat; var width: CGFloat
        var delay: Double; var duration: Double; var startRotation: Double; var endRotation: Double }

    /// Kolommen met covers, elk met eigen snelheid en vertraging.
    private func tiles(in s: CGSize) -> [Tile] {
        #if os(tvOS)
        let columns = 9, perColumn = 3
        #else
        let columns = 5, perColumn = 3
        #endif
        let colW = s.width / CGFloat(columns)
        var out: [Tile] = []
        var g = SeededRandom(seed: 42)
        for c in 0..<columns {
            for r in 0..<perColumn {
                let i = c * perColumn + r
                let img = images.isEmpty ? nil : images[i % images.count]
                let w = colW * CGFloat(0.82 + g.next() * 0.25)
                out.append(Tile(image: img, seed: i,
                                x: colW * (CGFloat(c) + 0.5) + CGFloat(g.next() - 0.5) * colW * 0.3,
                                width: w,
                                delay: Double(r) * 0.32 + g.next() * 0.35,
                                duration: 1.15 + g.next() * 0.55,
                                startRotation: (g.next() - 0.5) * 16,
                                endRotation: (g.next() - 0.5) * 30))
            }
        }
        return out
    }

    private func run() async {
        SplashTune.play()   // eigen Bingr-tune, loopt synchroon met de covers en de letters
        try? await Task.sleep(nanoseconds: 120_000_000)
        fall = true
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
        try? await Task.sleep(nanoseconds: 1_150_000_000)
        dim = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        for i in 1...letters.count {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { lettersIn = i }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: i == letters.count ? .rigid : .light).impactOccurred()
            #endif
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        withAnimation(.easeInOut(duration: 0.7)) { shine = true }
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(.easeIn(duration: 0.35)) { out = true }
        try? await Task.sleep(nanoseconds: 350_000_000)
        onFinished()
    }
}

/// Eén cover; zonder afbeelding een kleurige kaart met filmicoon.
private struct FallingCover: View {
    let image: CGImage?
    let colorSeed: Int
    var body: some View {
        ZStack {
            if let image {
                // al verkleind en gedecodeerd (SplashPosters.preload): niets meer te doen tijdens de val
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                let p = PlaylistAvatar.palettes[colorSeed % PlaylistAvatar.palettes.count]
                LinearGradient(colors: p, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: ["film", "tv", "popcorn", "sparkles.tv", "play.rectangle"][colorSeed % 5])
                    .font(.system(size: tvScaled(26), weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
        .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
    }
}

/// Posters voor de intro: bewaard zodra een afspeellijst geladen is (snel, geen netwerk nodig).
enum SplashPosters {
    private static let key = "splash.posters"

    static func load() -> [URL?] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).shuffled().compactMap { URL(string: $0) }
    }

    /// Build 130: de covers voor de intro vooraf laden (eerst uit de URL-cache), verkleinen en decoderen, allemaal
    /// buiten de main thread. Wat na `deadline` seconden nog niet binnen is, wordt een gekleurde kaart.
    static func preload(count: Int, maxPixel: Int, deadline: Double) async -> [CGImage] {
        let urls = Array(load().prefix(count).compactMap { $0 })
        guard !urls.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [CGImage] in
            // `nil` = de deadline; `.some(x)` = een cover (x nil als hij niet lukte)
            await withTaskGroup(of: CGImage??.self) { g in
                for u in urls {
                    g.addTask {
                        var req = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: deadline + 0.5)
                        req.setValue("image/*", forHTTPHeaderField: "Accept")
                        guard let (d, _) = try? await URLSession.shared.data(for: req) else { return .some(nil) }
                        return .some(downsample(d, maxPixel: maxPixel))
                    }
                }
                g.addTask { try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)); return nil }
                var out: [CGImage] = []
                var done = 0
                while let r = await g.next() {
                    guard let r else { break }          // deadline: met wat er is verder
                    done += 1
                    if let img = r { out.append(img) }
                    if done == urls.count { break }     // alles binnen
                }
                g.cancelAll()
                return out
            }
        }.value
    }

    /// Verkleinen en meteen decoderen (ImageIO), zodat het tekenen tijdens de animatie niets meer kost.
    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func save(from lib: Library) {
        var urls = lib.movies.prefix(300).compactMap(\.poster) + lib.series.prefix(200).compactMap(\.poster)
        urls.shuffle()
        let list = Array(urls.prefix(40)).map(\.absoluteString)
        guard !list.isEmpty else { return }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// Voorspelbare "willekeur" zodat de compositie elke keer mooi verdeeld is.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}


/// De Bingr-intro-tune (Shared/Resources/bingr_tune.m4a, gemaakt met tools/make_tune.py).
/// Speelt mee met andere audio. Staat altijd aan: de instelling is vervallen, een oude
/// waarde "splash.sound" = false (lokaal of via sync) wordt genegeerd.
enum SplashTune {
    private static var player: AVAudioPlayer?

    /// Build 130: de audiosessie en de speler buiten de main thread klaarzetten (`setActive` kan even blokkeren,
    /// wat op Apple TV de eerste frames van de intro deed haperen).
    static func play() {
        guard let url = Bundle.main.url(forResource: "bingr_tune", withExtension: "m4a") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // .playback: ook hoorbaar met de stil-schakelaar aan (zoals de Netflix-intro); mengt met andere audio
            #if !os(macOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            #endif
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.volume = 1.0
            p.prepareToPlay()
            p.play(atTime: p.deviceCurrentTime + 0.02)
            DispatchQueue.main.async {
                player = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { player = nil }
            }
        }
    }
}
