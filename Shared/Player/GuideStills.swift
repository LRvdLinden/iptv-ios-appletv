import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Build 164: stilstaande beelden per zender voor de tv-gids. Een klein jpg (±320 breed) in Caches/GuideStills, gemaakt
/// als de zender speelde of als voorbeeld draaide; hooguit 30 minuten oud voor gebruik en maximaal 200 zenders (de oudste
/// eerst weg, `GuideStillPolicy164`). Nooit in UserDefaults (build 158). Kan de engine geen beeld geven, dan niets
/// (de gids toont dan het logo).
@MainActor
final class GuideStills: ObservableObject {
    static let shared = GuideStills()

    /// Telt op bij elk nieuw beeld, zodat de beelden in de gids opnieuw laden
    @Published private(set) var version = 0
    /// Bestandsnaam → moment van bewaren (van schijf gelezen bij de eerste vraag)
    private var savedAt: [String: Date] = [:]
    private var loaded = false
    private let memory = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "bingr.guide.stills", qos: .utility)
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private init() { memory.countLimit = 60 }

    nonisolated static var directory: URL { AppDirs.caches.appendingPathComponent("GuideStills", isDirectory: true) }

    /// Sleutel van een zender: server + zender-id (zenders van andere servers hebben een eigen beeld).
    static func key(channelID: String, sourceID: UUID?) -> String {
        ((sourceID ?? CloudStore.shared.activePlaylistID)?.uuidString ?? "-") + "|" + channelID
    }
    static func key(_ c: Channel) -> String { key(channelID: c.id, sourceID: c.sourceID) }

    private func loadIndex() {
        guard !loaded else { return }
        loaded = true
        let dir = Self.directory
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        for f in files where f.pathExtension == "jpg" {
            if let d = try? f.resourceValues(forKeys: Set(keys)).contentModificationDate { savedAt[f.lastPathComponent] = d }
        }
    }

    /// Moment van het bewaarde beeld van deze zender (nil = geen).
    func savedDate(_ key: String) -> Date? {
        loadIndex()
        return savedAt[GuideStillPolicy164.fileName(for: key)]
    }

    /// Een vers beeld (hooguit 30 min oud), uit het geheugen of van schijf.
    func image(_ key: String) async -> CGImage? {
        let name = GuideStillPolicy164.fileName(for: key)
        guard let d = savedDate(key), GuideStillPolicy164.isFresh(savedAt: d, now: Date()) else { return nil }
        if let hit = memory.object(forKey: name as NSString) { return hit }
        let url = Self.directory.appendingPathComponent(name)
        let img: CGImage? = await withCheckedContinuation { cont in
            queue.async {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let i = CGImageSourceCreateImageAtIndex(src, 0, nil) else { cont.resume(returning: nil); return }
                cont.resume(returning: i)
            }
        }
        if let img { memory.setObject(img, forKey: name as NSString) }
        return img
    }

    /// Een beeld van de speler bewaren (live; Apple-engine via de video-uitvoer, VLC via een momentopname).
    func capture(_ ctrl: PlayerController, key: String) {
        guard !Screenshots.isActive else { return }
        let name = GuideStillPolicy164.fileName(for: key)
        loadIndex()
        guard GuideStillPolicy164.shouldSave(lastSavedAt: savedAt[name], now: Date()) else { return }
        let width = GuideStillPolicy164.width
        if let av = ctrl.engine as? AVEngine {
            guard let pb = av.stillPixelBuffer() else { return }
            let ci = CIImage(cvPixelBuffer: pb)
            let scale = min(1, CGFloat(width) / max(ci.extent.width, 1))
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = Self.ciContext.createCGImage(scaled, from: scaled.extent) else { return }
            store(cg, name: name)
        } else if let vlc = ctrl.engine as? VLCEngine {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).png")
            vlc.snapshot(to: tmp.path, width: width)
            Task { @MainActor [weak self] in
                // VLC schrijft het beeld vanaf zijn eigen thread weg: even wachten tot het er staat
                for _ in 0..<12 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if FileManager.default.fileExists(atPath: tmp.path) { break }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let self, let src = CGImageSourceCreateWithURL(tmp as CFURL, nil) else { return }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceThumbnailMaxPixelSize: width]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
                self.store(cg, name: name)
            }
        }
    }

    private func store(_ cg: CGImage, name: String) {
        let now = Date()
        savedAt[name] = now
        memory.setObject(cg, forKey: name as NSString)
        version += 1
        let dir = Self.directory
        let entries = savedAt.map { (key: $0.key, savedAt: $0.value) }
        let gone = GuideStillPolicy164.evict(entries)
        for g in gone { savedAt[g] = nil; memory.removeObject(forKey: g as NSString) }
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            for g in gone { try? FileManager.default.removeItem(at: dir.appendingPathComponent(g)) }
        }
    }
}

/// Het beeld van een zender in de gids: een vers stilstaand beeld, anders het zenderlogo groot op een donker vlak.
struct GuideStillView: View {
    let channel: Channel
    /// Build 166 (NU-kaart op de Apple TV): zonder beeld het logo los gecentreerd op het donkere vlak, zonder eigen
    /// vlak en rand (geen kader in een kader)
    var plainLogo = false
    @ObservedObject private var stills = GuideStills.shared
    @State private var image: CGImage?

    var body: some View {
        let key = GuideStills.key(channel)
        // het beeld vult het vak (de grootte komt van het vak, niet van het beeld)
        Color(hex: 0x141414)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else if plainLogo {
                    GuideLogoMark(channel: channel)
                } else {
                    GuideLogo(channel: channel, large: true).padding(tvScaled(18))
                }
            }
            .clipped()
        .task(id: "\(key)#\(stills.version)") { image = await stills.image(key) }
    }
}

/// Build 166: alleen het zenderlogo (of de opgeschoonde naam), gecentreerd, zonder eigen vlak of rand.
struct GuideLogoMark: View {
    let channel: Channel
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { g in
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: g.size.width * 0.5, height: g.size.height * 0.5)
                } else {
                    // zonder logo (of tijdens het laden) de opgeschoonde naam, ook zonder vlak
                    Text(CategoryName.channel(channel.name)).font(.system(size: tvScaled(16), weight: .heavy))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                        .foregroundStyle(.white.opacity(0.9)).padding(tvScaled(8))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .task(id: channel.logo) {
            guard let url = channel.logo else { image = nil; return }
            if let hit = ImagePipeline.shared.cached(url, maxPixel: 480) { image = hit; return }
            let loaded = await ImagePipeline.shared.load(url, maxPixel: 480)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Zenderlogo van de server op een donker vlak met een dunne rand; zonder logo de opgeschoonde zendernaam.
struct GuideLogo: View {
    let channel: Channel
    var large = false

    var body: some View {
        let name = CategoryName.channel(channel.name)
        ZStack {
            RoundedRectangle(cornerRadius: tvScaled(6)).fill(Color(hex: 0x1F1F1F))
            if channel.logo != nil {
                RemoteImage(url: channel.logo, contentMode: .fit, placeholder: name, maxPixel: large ? 480 : 240)
                    .padding(tvScaled(large ? 10 : 4))
            } else {
                Text(name).font(.system(size: tvScaled(large ? 16 : 11), weight: .heavy))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(.white).padding(tvScaled(4))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: tvScaled(6)).stroke(Color(hex: 0x2C2C2C), lineWidth: 1))
    }
}
