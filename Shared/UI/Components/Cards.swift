import SwiftUI

enum DetailTarget: Identifiable, Hashable {
    case movie(Movie), series(Series)
    var id: String { switch self { case .movie(let m): return m.id; case .series(let s): return s.id } }
}

/// Poster in 2:3 met IMDb-score, "bekeken"-vinkje en voortgangsbalk.
struct PosterCard: View {
    let title: String
    let poster: URL?
    var imdbID: String?
    var watched = false
    var progress: Double?
    var badge: String?
    var width: CGFloat = Theme.posterWidth

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RemoteImage(url: poster, placeholder: title)
                .frame(width: width, height: width * 1.5)
                .clipped()
            if watched { WatchedBadge().padding(6) }
            if let badge {
                Text(badge).font(.system(size: tvScaled(9), weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.red, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, progress == nil ? 6 : 10)
            }
            if let progress, progress > 0 {
                VStack { Spacer(); ProgressBar(value: progress).frame(height: tvScaled(3)) }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(4)))
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.3))
                Rectangle().fill(Theme.red).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
    }
}

/// Live-kanaal: logo, naam en wat er nu op is.
struct ChannelCard: View {
    let channel: Channel
    let now: EPGProgram?
    var favorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0x2A2A2A), Color(hex: 0x141414)], startPoint: .top, endPoint: .bottom)
                RemoteImage(url: channel.logo, contentMode: .fit, placeholder: channel.name)
                    .padding(tvScaled(18))
                HStack(spacing: 4) {
                    Circle().fill(Theme.red).frame(width: tvScaled(6), height: tvScaled(6))
                    Text("LIVE").font(.system(size: tvScaled(9), weight: .heavy))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule()).padding(6)
                if favorite {
                    Image(systemName: "star.fill").font(.system(size: tvScaled(11))).foregroundStyle(Theme.imdb)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                }
            }
            .frame(width: Theme.landscapeWidth, height: Theme.landscapeWidth * 0.5625)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.system(size: tvScaled(13), weight: .semibold)).lineLimit(1)
                Text(now?.title ?? L("No guide information")).font(.system(size: tvScaled(11)))
                    .foregroundStyle(Theme.secondary).lineLimit(1)
                if let now { ProgressBar(value: now.progress).frame(height: 2).padding(.top, 2) }
            }
            .padding(tvScaled(8))
            .frame(width: Theme.landscapeWidth, alignment: .leading)
            .background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(6)))
    }
}

/// Netflix "Top 10": groot cijfer met poster ernaast.
struct Top10Card: View {
    let rank: Int
    let title: String
    let poster: URL?
    var watched = false
    var body: some View {
        HStack(spacing: -tvScaled(22)) {
            Text("\(rank)")
                .font(.system(size: tvScaled(150), weight: .black))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x4A4A4A), Color(hex: 0x111111)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: .white.opacity(0.55), radius: 0.8)
                .frame(width: tvScaled(rank >= 10 ? 130 : 80), alignment: .trailing)
            PosterCard(title: title, poster: poster, watched: watched)
        }
    }
}

/// Horizontale rij met titel (Netflix "rij").
struct MediaRow<Content: View>: View {
    let title: String
    var onSeeAll: (() -> Void)?
    let content: () -> Content

    init(title: String, onSeeAll: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.onSeeAll = onSeeAll; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(Theme.titleFont).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        Text(L("See all")).font(.system(size: tvScaled(15), weight: .semibold)).foregroundStyle(.white)
                    }
                    .plainTVButton()
                }
            }
            .padding(.horizontal, Theme.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.rowSpacing) { content() }
                    .padding(.horizontal, Theme.edge)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }
}
