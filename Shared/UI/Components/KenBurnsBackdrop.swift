import SwiftUI

/// Bewegende kop van de detailpagina op Apple TV (build 85). tvOS heeft geen WebKit, dus een YouTube-trailer kan
/// daar niet automatisch in de kop spelen (streams uit YouTube halen mag niet). In plaats daarvan: een langzame
/// zoom en verschuiving (Ken Burns) over de achtergrond, en als er meer achtergronden zijn, overvloeien naar de
/// volgende. Met Bewegingen beperken staat de eerste afbeelding stil.
struct KenBurnsBackdrop: View {
    let urls: [URL]
    let height: CGFloat
    /// Uit als er iets speelt, een blad erover ligt of de app op de achtergrond staat: dan stopt de wisseling
    var active: Bool = true
    var maxPixel: Int = 1920

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    /// Elke afbeelding zo lang in beeld; de beweging duurt iets langer, zodat hij nooit stilvalt voor de wissel
    private static let hold: Double = 9
    private static let fade: Double = 1.6

    var body: some View {
        ZStack {
            Color.black
            if urls.isEmpty {
                RemoteImage(url: nil, placeholder: "", maxPixel: maxPixel)
            } else {
                let i = min(index, urls.count - 1)
                KenBurnsLayer(url: urls[i], variant: i, animate: !reduceMotion, duration: Self.hold + Self.fade + 1,
                              maxPixel: maxPixel)
                    .id(urls[i])
                    .transition(.opacity)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: "\(urls.map(\.absoluteString).joined(separator: "|"))-\(active)-\(reduceMotion)") { await cycle() }
        .accessibilityHidden(true)
    }

    /// Volgende achtergrond pas tonen als hij geladen is (anders even een lege kop).
    private func cycle() async {
        if index >= urls.count { index = 0 }
        guard active, !reduceMotion, urls.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let next = (index + 1) % urls.count
            guard await ImagePipeline.shared.load(urls[next], maxPixel: maxPixel) != nil, !Task.isCancelled else { continue }
            withAnimation(.easeInOut(duration: Self.fade)) { index = next }
        }
    }
}

/// Eén afbeelding die langzaam inzoomt en een kant op schuift; de richting wisselt per afbeelding.
private struct KenBurnsLayer: View {
    let url: URL
    let variant: Int
    let animate: Bool
    let duration: Double
    let maxPixel: Int
    @State private var moved = false

    private var anchor: UnitPoint {
        [UnitPoint(x: 0.7, y: 0.35), UnitPoint(x: 0.3, y: 0.4), UnitPoint(x: 0.55, y: 0.6)][variant % 3]
    }
    private var drift: CGSize {
        [CGSize(width: -36, height: -10), CGSize(width: 36, height: -8), CGSize(width: -20, height: 14)][variant % 3]
    }

    var body: some View {
        RemoteImage(url: url, placeholder: "", maxPixel: maxPixel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .scaleEffect(moved ? 1.14 : 1.03, anchor: anchor)
            .offset(moved ? drift : .zero)
            .onAppear {
                guard animate else { return }
                withAnimation(.easeInOut(duration: duration)) { moved = true }
            }
    }
}
