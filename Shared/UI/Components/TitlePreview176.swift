import SwiftUI
#if os(iOS)
import UIKit
#endif

// Build 176, punt 11: voorvertoning op een titel. Na 2 s focus (Apple TV) of de aanwijzer (iPad, Mac) op een poster,
// of de hero in beeld (iPhone, iPad, Mac), speelt de trailer zonder geluid in de kaart of de hero. Apple TV heeft geen
// WebKit: daar beweegt de poster langzaam (Ken Burns), zoals de kop van de detailpagina. Regels in Build176Player.swift;
// contract in docs/ACCOUNT.md ("Build 176", punt 7). Telt niet als stream (YouTube, nooit de IPTV-stream).

@MainActor
enum TitlePreview176 {
    static var device: Preview176.Device {
        #if os(tvOS)
        return .tv
        #elseif os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    /// Data besparen op mobiel netwerk (punt 6)
    static var saver: Bool { DataSaver176.active }

    /// Vergrendelde titel (punt 5): geen voorvertoning
    static func isLocked(_ t: DetailTarget) -> Bool {
        CloudStore.shared.lockedTitleKey(t.sourceID, t.hideKind171, t.id) != nil
    }

    static func allowed(_ t: DetailTarget, enabled: Bool, reduceMotion: Bool) -> Bool {
        Preview176.allowed(enabled: enabled, saver: saver, locked: isLocked(t), kidsBlocked: false,
                           reduceMotion: reduceMotion, playing: false)
    }

    /// Trailer van een titel (YouTube-id), onthouden per titel; eerst de lichte metadata (Trakt), dan TMDB.
    private static var cache: [String: String] = [:]
    private static var missing: Set<String> = []

    static func trailerID(_ t: DetailTarget) async -> String? {
        let key = (t.sourceID?.uuidString ?? "") + "|" + t.id
        if let c = cache[key] { return c }
        if missing.contains(key) { return nil }
        let meta = MetadataService.shared
        var id: String?
        var title = "", year: Int?, imdb: String?, tmdb: Int?, show = false
        switch t {
        case .movie(let m):
            id = await meta.metadata(m)?.trailerYouTubeID
            title = m.title; year = m.year; imdb = m.imdbID; tmdb = m.tmdbID
        case .series(let s):
            id = await meta.metadata(s)?.trailerYouTubeID
            title = s.title; year = s.year; imdb = s.imdbID; tmdb = s.tmdbID; show = true
        }
        if Trailer.safeID(id) == nil {
            id = await TMDB.details(imdb: imdb, tmdbID: tmdb, title: ContentLanguage.searchTitle(title), year: year,
                                    isShow: show)?.trailer
        }
        guard let safe = Trailer.safeID(id) else { missing.insert(key); return nil }
        cache[key] = safe
        return safe
    }

    static func poster(_ t: DetailTarget) -> URL? {
        switch t { case .movie(let m): return m.poster; case .series(let s): return s.poster }
    }
}

extension View {
    /// Voorvertoning op een poster (in het label van de knop, zodat de focus van de tv meekomt).
    func titlePreview176(_ target: DetailTarget) -> some View { modifier(CardPreview176(target: target)) }
}

/// Voorvertoning in een kaart: Apple TV beweging, iPad en Mac de trailer (aanwijzer). iPhone: niets.
private struct CardPreview176: ViewModifier {
    let target: DetailTarget
    @AppStorage(Preview176.enabledKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tvFocused) private var tvFocused
    @State private var hovering = false
    @State private var showing = false
    @State private var moved = false
    #if !os(tvOS)
    @StateObject private var trailer = HeroTrailerModel()
    #endif

    private var device: Preview176.Device { TitlePreview176.device }

    @ViewBuilder func body(content: Content) -> some View {
        if Preview176.style(device: device, surface: .card, hasTrailer: true) == .none {
            content
        } else {
            content
                .overlay { previewLayer }
                #if !os(tvOS)
                .onHover { hovering = $0 }
                #endif
                .task(id: active) { await run() }
                .onDisappear { stop() }
        }
    }

    private var active: Bool {
        #if os(tvOS)
        return tvFocused
        #else
        return hovering
        #endif
    }

    @ViewBuilder private var previewLayer: some View {
        #if os(tvOS)
        if showing {
            RemoteImage(url: TitlePreview176.poster(target), maxPixel: 720)
                .scaleEffect(moved ? 1.16 : 1.0, anchor: UnitPoint(x: 0.5, y: 0.3))
                .offset(y: moved ? -10 : 0)
                .clipped()
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        if let id = trailer.videoID {
            ZStack {
                Color.black
                HeroTrailerView(id: id, model: trailer).id(trailer.token)
            }
            .clipped()
            .opacity(trailer.isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: trailer.isVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    private func run() async {
        guard active else { stop(); return }
        try? await Task.sleep(nanoseconds: UInt64(Preview176.delay * 1_000_000_000))
        guard !Task.isCancelled, active, TitlePreview176.allowed(target, enabled: enabled, reduceMotion: reduceMotion)
        else { return }
        #if os(tvOS)
        withAnimation(.easeIn(duration: 0.4)) { showing = true }
        withAnimation(.easeInOut(duration: 12)) { moved = true }
        #else
        guard let id = await TitlePreview176.trailerID(target), !Task.isCancelled, active else { return }
        trailer.start(id)
        #endif
        // niet eindeloos: na een tijdje weer de poster
        try? await Task.sleep(nanoseconds: UInt64(Preview176.maxCardSeconds * 1_000_000_000))
        if !Task.isCancelled { stop() }
    }

    private func stop() {
        #if os(tvOS)
        if showing { withAnimation(.easeOut(duration: 0.3)) { showing = false } }
        moved = false
        #else
        trailer.stop()
        #endif
    }
}

#if !os(tvOS)
/// Voorvertoning in de hero bovenaan Home (iPhone, iPad, Mac): na 2 s in beeld de trailer zonder geluid over de poster.
struct HeroPreview176: View {
    let target: DetailTarget
    @AppStorage(Preview176.enabledKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var trailer = HeroTrailerModel()

    var body: some View {
        ZStack {
            if let id = trailer.videoID {
                Color.black
                HeroTrailerView(id: id, model: trailer).id(trailer.token)
            }
        }
        .opacity(trailer.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.8), value: trailer.isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: "\(target.id)-\(enabled)-\(scenePhase == .active)") { await run() }
        .onDisappear { trailer.stop() }
    }

    private func run() async {
        trailer.stop()
        guard Preview176.style(device: TitlePreview176.device, surface: .hero, hasTrailer: true) == .trailer,
              scenePhase == .active else { return }
        try? await Task.sleep(nanoseconds: UInt64(Preview176.delay * 1_000_000_000))
        guard !Task.isCancelled, TitlePreview176.allowed(target, enabled: enabled, reduceMotion: reduceMotion),
              let id = await TitlePreview176.trailerID(target), !Task.isCancelled else { return }
        trailer.start(id)
    }
}
#endif
