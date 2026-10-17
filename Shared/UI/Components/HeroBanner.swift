import SwiftUI

/// Grote uitgelichte titel bovenaan Home (Netflix "billboard").
struct HeroBanner: View {
    let target: DetailTarget
    let onPlay: () -> Void
    let onInfo: () -> Void

    /// Alleen opvragen, niet volgen (build 56): anders tekende het billboard opnieuw bij elke IMDb-score die
    /// ergens in de app binnenkwam (bijv. tijdens het scrollen door een categorie)
    private var meta: MetadataService { MetadataService.shared }
    @EnvironmentObject var trakt: TraktSync
    @State private var info: TitleMetadata?

    private var title: String { switch target { case .movie(let m): return m.title; case .series(let s): return s.title } }
    private var poster: URL? {
        info?.poster ?? { () -> URL? in switch target { case .movie(let m): return m.poster; case .series(let s): return s.poster } }()
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // iPhone/iPad: grote portret-kaart met gloed van de poster erachter
    private var phoneBody: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: poster, placeholder: title, maxPixel: 1100)
                    .frame(width: 330, height: 470).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(spacing: 10) {
                    Text(title.uppercased())
                        .font(.system(size: 30, weight: .black)).kerning(1)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(radius: 8)
                    Text(tags).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 10) {
                        NetflixButton(title: L("Play"), icon: "play.fill", kind: .play, action: onPlay).frame(maxWidth: .infinity)
                        NetflixButton(title: L("Info"), icon: "info.circle", kind: .secondary, action: onInfo).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .frame(width: 330, height: 470)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
            .padding(.top, 110)
        }
        // de kaart bepaalt de breedte (schermbreedte), nooit de afbeelding erachter: een brede poster maakte het blok
        // anders breder dan het scherm en schoof de kaart (gecentreerd in dat blok) rechts uit beeld
        .frame(maxWidth: .infinity, minHeight: 620, alignment: .top)
        .background(alignment: .top) {
            // gloed van de poster: als overlay op een vlak van de juiste maat, zodat hij de opmaak niet kan oprekken
            Color.clear
                .frame(height: 620)
                .overlay {
                    RemoteImage(url: poster)
                        .blur(radius: 50).opacity(0.65)
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                }
                .clipped()
                .allowsHitTesting(false)
        }
        .task(id: target.id) { await load() }
    }

    // Apple TV: breed billboard met tekst links
    private var tvBody: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: poster, maxPixel: 600).frame(height: 820).frame(maxWidth: .infinity).blur(radius: 30).clipped().opacity(0.7)
            HStack { Spacer(); RemoteImage(url: poster, maxPixel: 1200).frame(width: 520, height: 780).clipped()
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing)) }
                .padding(.trailing, 120)
            LinearGradient(colors: [.black.opacity(0.95), .black.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.system(size: 76, weight: .black)).lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                HStack(spacing: 18) {
                    if let r = info?.imdbRating { IMDbBadge(rating: r) }
                    Text(tags).font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                if let plot = info?.plot {
                    Text(plot).font(.system(size: 26)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                HStack(spacing: 24) {
                    NetflixButton(title: L("Play"), icon: "play.fill", kind: .play, action: onPlay)
                    NetflixButton(title: L("More info"), icon: "info.circle", kind: .secondary, action: onInfo)
                }
            }
            .padding(.leading, Theme.edge).padding(.bottom, 80)
        }
        .frame(height: 820)
        .task(id: target.id) { await load() }
    }

    private var tags: String {
        let parts = [info?.year, info?.genre?.split(separator: ",").prefix(2).joined(separator: " • "), info?.runtime]
        let s = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  •  ")
        return s.isEmpty ? (target.isSeries ? L("Series") : L("Movie")) : s
    }

    private func load() async {
        switch target {
        case .movie(let m): info = await meta.metadata(m)
        case .series(let s): info = await meta.metadata(s)
        }
    }
}

extension DetailTarget {
    var isSeries: Bool { if case .series = self { return true }; return false }
}
