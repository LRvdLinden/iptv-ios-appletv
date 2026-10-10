import SwiftUI

/// Intro: covers van films en series uit je afspeellijst regenen van boven naar beneden,
/// daarna springen de letters van BINGR één voor één omhoog met een glanzende veeg erover.
struct SplashView: View {
    let onFinished: () -> Void

    @State private var posters: [URL?] = []
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

                // vallende covers
                ForEach(Array(tiles(in: geo.size).enumerated()), id: \.offset) { _, t in
                    FallingCover(url: t.url, colorSeed: t.seed)
                        .frame(width: t.width, height: t.width * 1.5)
                        .rotationEffect(.degrees(fall ? t.endRotation : t.startRotation))
                        .position(x: t.x, y: fall ? geo.size.height + t.width * 1.6 : -t.width * 1.6)
                        .animation(.easeIn(duration: t.duration).delay(t.delay), value: fall)
                }

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
        .task {
            posters = SplashPosters.load()
            await run()
        }
    }

    private struct Tile { var url: URL?; var seed: Int; var x: CGFloat; var width: CGFloat
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
                let url = posters.isEmpty ? nil : posters[i % posters.count]
                let w = colW * CGFloat(0.82 + g.next() * 0.25)
                out.append(Tile(url: url, seed: i,
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
    let url: URL?
    let colorSeed: Int
    var body: some View {
        ZStack {
            let p = PlaylistAvatar.palettes[colorSeed % PlaylistAvatar.palettes.count]
            LinearGradient(colors: p, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: ["film", "tv", "popcorn", "sparkles.tv", "play.rectangle"][colorSeed % 5])
                .font(.system(size: tvScaled(26), weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            if let url {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
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
