import SwiftUI

/// Geanimeerd intro-scherm in Netflix-"tudum"-stijl:
/// 1. letters vallen één voor één op hun plek  2. rode glow pulseert
/// 3. lichtlinten schieten door het logo  4. camera zoomt de K in en vervaagt naar zwart.
struct SplashView: View {
    let onFinished: () -> Void

    @State private var lettersIn = 0
    @State private var glow = false
    @State private var ribbons = false
    @State private var zoom = false
    @State private var fade = false

    private let letters = Array("BINGR")
    private var size: CGFloat { tvScaled(64) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // zachte rode gloed achter het logo
                RadialGradient(colors: [Theme.red.opacity(glow ? 0.45 : 0), .clear],
                               center: .center, startRadius: 0, endRadius: geo.size.width * 0.6)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.9), value: glow)

                ZStack {
                    HStack(spacing: -size * 0.04) {
                        ForEach(Array(letters.enumerated()), id: \.offset) { i, ch in
                            Text(String(ch))
                                .font(.system(size: size, weight: .black))
                                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFF3B3B), Theme.red, Color(hex: 0x8F050C)],
                                                                startPoint: .top, endPoint: .bottom))
                                .scaleEffect(x: 0.92, y: 1.15)
                                .offset(y: lettersIn > i ? 0 : -size * 0.6)
                                .opacity(lettersIn > i ? 1 : 0)
                                .rotation3DEffect(.degrees(lettersIn > i ? 0 : 75), axis: (x: 1, y: 0, z: 0))
                                .shadow(color: Theme.red.opacity(glow ? 0.9 : 0), radius: glow ? size * 0.35 : 0)
                        }
                    }

                    // lichtlinten
                    RibbonBurst(active: ribbons, height: size * 2.4)
                        .frame(width: size * 3.6, height: size * 2.4)
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }
                .scaleEffect(zoom ? 28 : 1, anchor: UnitPoint(x: 0.12, y: 0.5))
                .opacity(fade ? 0 : 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task { await run() }
    }

    private func run() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        for i in 1...letters.count {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { lettersIn = i }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: i == letters.count ? .heavy : .light).impactOccurred()
            #endif
            try? await Task.sleep(nanoseconds: 110_000_000)
        }
        glow = true
        try? await Task.sleep(nanoseconds: 450_000_000)
        withAnimation(.easeOut(duration: 0.9)) { ribbons = true }
        try? await Task.sleep(nanoseconds: 700_000_000)
        withAnimation(.easeIn(duration: 0.7)) { zoom = true }
        try? await Task.sleep(nanoseconds: 350_000_000)
        withAnimation(.easeIn(duration: 0.35)) { fade = true }
        try? await Task.sleep(nanoseconds: 380_000_000)
        onFinished()
    }
}

/// Verticale lichtstrepen in rood/roze/paars die vanuit het midden uitwaaieren.
private struct RibbonBurst: View {
    let active: Bool
    let height: CGFloat
    private let colors: [Color] = [Theme.red, Color(hex: 0xFF4D6D), Color(hex: 0xB517FF), Color(hex: 0x2E6BFF),
                                   Color(hex: 0xFF8A00), Color(hex: 0xE50914), Color(hex: 0xFF2E93)]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<28, id: \.self) { i in
                    let c = colors[i % colors.count]
                    let spread = (CGFloat(i) / 27 - 0.5) * geo.size.width * 1.1
                    Capsule()
                        .fill(LinearGradient(colors: [c.opacity(0), c, c.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: CGFloat(2 + (i * 7) % 6), height: height * (0.5 + CGFloat((i * 13) % 10) / 20))
                        .offset(x: active ? spread : 0, y: active ? CGFloat((i * 37) % 30) - 15 : 0)
                        .opacity(active ? 0.85 : 0)
                        .scaleEffect(y: active ? 1 : 0.1)
                        .animation(.easeOut(duration: 0.8).delay(Double(i % 7) * 0.03), value: active)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
