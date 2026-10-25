import SwiftUI
import CoreGraphics

// Build 149: rij "Ontdek categorieën" op Home (zoals "Ontdek kanalen en apps" op de Apple TV): grote tegels met een
// collage van posters uit de categorie en een gekleurde balk met de naam. Hoort de categorie bij een streamingdienst,
// dan het logo van die dienst uit TMDB (`/watch/providers`); geen logo-bestanden in de app.

/// Logo's van streamingdiensten (TMDB `/watch/providers/movie` en `/tv`, regio NL), 7 dagen bewaard in Caches.
@MainActor
final class ProviderLogos: ObservableObject {
    static let shared = ProviderLogos()
    /// TMDB `provider_name` → `logo_path`
    @Published private(set) var logos: [String: String] = [:]
    private var loading = false
    private static let maxAge: TimeInterval = 7 * 86400
    private static var file: URL { AppDirs.caches.appendingPathComponent("tmdb-watch-providers-NL.json") }

    private struct Cached: Codable { let at: Double; let logos: [String: String] }
    private struct R: Decodable {
        struct P: Decodable { let provider_name: String?; let logo_path: String? }
        let results: [P]?
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            let file = Self.file
            let cached = await Task.detached(priority: .utility) { () -> Cached? in
                guard let d = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(Cached.self, from: d)
            }.value
            if let cached, !cached.logos.isEmpty { logos = cached.logos }
            if let cached, Date().timeIntervalSince1970 - cached.at < Self.maxAge, !cached.logos.isEmpty { loading = false; return }
            var out: [String: String] = [:]
            for kind in ["movie", "tv"] {
                let r: R? = await TMDB.get("/watch/providers/\(kind)", ["watch_region": "NL", "language": TMDB.language])
                for p in r?.results ?? [] {
                    if let n = p.provider_name, let l = p.logo_path, !n.isEmpty, !l.isEmpty, out[n] == nil { out[n] = l }
                }
            }
            if !out.isEmpty {
                logos = out
                let blob = Cached(at: Date().timeIntervalSince1970, logos: out)
                Task.detached(priority: .utility) { try? JSONEncoder().encode(blob).write(to: file, options: .atomic) }
            }
            loading = false
        }
    }

    /// Logo-URL van de dienst bij deze categorie; nil = geen match of nog geen lijst (dan de naam als tekst)
    func logo(for category: String) -> (name: String, url: URL)? {
        guard let name = ProviderMatch.match(category, providers: logos), let path = logos[name],
              let url = TMDB.img(path, "w300") else { return nil }
        return (name, url)
    }
}

/// Eén categorie in de rij
struct DiscoverCategory: Identifiable {
    let id: String
    let title: String
    let covers: [URL]
    let colors: (UInt32, UInt32)
    let count: Int
    let category: BrowseCategory

    /// Vaste, smaakvolle palet (balkkleur op naam)
    static let palette: [(UInt32, UInt32)] = [
        (0xB91C1C, 0x7F1D1D), (0x1D4ED8, 0x1E3A8A), (0x047857, 0x064E3B), (0xB45309, 0x78350F),
        (0x7E22CE, 0x581C87), (0xBE185D, 0x831843), (0x0F766E, 0x134E4A), (0x334155, 0x0F172A),
        (0x4338CA, 0x312E81), (0xC2410C, 0x7C2D12),
    ]

    /// De grootste zichtbare categorieën van de server (films en series), max. `limit`. Bij een kinderprofiel alleen
    /// als alle categorieën kindercategorieën zijn.
    static func build(_ index: BrowseIndex, kids: Bool, limit: Int = 10) -> [DiscoverCategory] {
        let server = index.server.filter { $0.count(.all) > 0 && !$0.covers(.all).isEmpty }
        if kids && !server.allSatisfy({ ParentalControl.isKidsGroup($0.title) }) { return [] }
        return server.sorted { $0.count(.all) > $1.count(.all) }.prefix(limit).map { c in
            let title = CategoryName.clean(c.title)
            return DiscoverCategory(id: c.id, title: title, covers: Array(c.covers(.all).prefix(4)),
                                    colors: palette[ProviderMatch.paletteIndex(title.lowercased(), count: palette.count)],
                                    count: c.count(.all), category: c)
        }
    }
}

/// Tegel: collage van 3–4 posters (boven) en een gekleurde balk met de naam of het logo van de dienst (onder).
struct DiscoverCategoryTile: View {
    let item: DiscoverCategory
    let logo: (name: String, url: URL)?
    @Environment(\.tvFocused) private var focused
    @State private var logoColor: UInt32?

    private static let colorLock = NSLock()
    nonisolated(unsafe) private static var colorCache: [URL: UInt32] = [:]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let bar = h * 0.34
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    ForEach(Array(item.covers.prefix(4).enumerated()), id: \.offset) { _, u in
                        RemoteImage(url: u, placeholder: "", maxPixel: 300)
                            .frame(width: (w - CGFloat(max(0, min(4, item.covers.count) - 1))) / CGFloat(max(1, min(4, item.covers.count))),
                                   height: h - bar)
                            .clipped()
                    }
                }
                .frame(width: w, height: h - bar, alignment: .leading)
                .background(Color(hex: item.colors.1))
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom))
                ZStack(alignment: .leading) {
                    let base = logoColor.map { ($0, Self.darker($0)) } ?? item.colors
                    LinearGradient(colors: [Color(hex: base.0), Color(hex: base.1)], startPoint: .leading, endPoint: .trailing)
                    HStack(spacing: tvScaled(10)) {
                        if let logo {
                            RemoteImage(url: logo.url, contentMode: .fit, placeholder: "", maxPixel: 300)
                                .frame(width: bar * 0.72, height: bar * 0.72)
                                .clipShape(RoundedRectangle(cornerRadius: bar * 0.16))
                        }
                        Text(item.title)
                            .font(.system(size: tvScaled(20), weight: .black))
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.55)
                            .shadow(color: .black.opacity(0.35), radius: 3)
                    }
                    .padding(.horizontal, tvScaled(12))
                }
                .frame(width: w, height: bar)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(8)).stroke(.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: tvScaled(8)))
        .task(id: logo?.url) { await loadLogoColor() }
    }

    /// Merkkleur uit het logo (gemiddelde van de verzadigde pixels op 12×12), één keer per logo
    private func loadLogoColor() async {
        guard let url = logo?.url else { logoColor = nil; return }
        if let c = Self.colorLock.withLock({ Self.colorCache[url] }) { logoColor = c; return }
        guard let img = await ImagePipeline.shared.load(url, maxPixel: 300) else { return }
        let c = await Task.detached(priority: .utility) { Self.dominant(img) }.value
        guard let c else { return }
        Self.colorLock.withLock { Self.colorCache[url] = c }
        logoColor = c
    }

    nonisolated static func dominant(_ img: CGImage) -> UInt32? {
        let n = 12
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(px[i]) / 255 / a, pg = Double(px[i + 1]) / 255 / a, pb = Double(px[i + 2]) / 255 / a
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            guard sat > 0.35, mx > 0.25 else { continue }   // geen zwart, wit of grijs
            let w = sat * mx
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        guard wsum > 0.5 else { return nil }
        // iets donkerder, zodat witte tekst leesbaar blijft
        func c(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v / wsum * 255 * 0.8))) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }

    static func darker(_ c: UInt32) -> UInt32 {
        let r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF
        return ((r * 55 / 100) << 16) | ((g * 55 / 100) << 8) | (b * 55 / 100)
    }
}
