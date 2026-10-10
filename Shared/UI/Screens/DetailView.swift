import SwiftUI

struct DetailView: View {
    let target: DetailTarget

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @EnvironmentObject var meta: MetadataService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var info: TitleMetadata?
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loadingEpisodes = false
    @State private var showTrailer = false
    @State private var xtreamTrailer: String?

    private var pid: UUID? { playlists.source?.id }
    private var title: String { switch target { case .movie(let m): return m.title; case .series(let s): return s.title } }
    private var poster: URL? {
        switch target { case .movie(let m): return m.poster ?? info?.poster; case .series(let s): return s.poster ?? info?.poster }
    }
    private var imdb: String? {
        switch target { case .movie(let m): return trakt.imdb(for: m) ?? info?.imdbID; case .series(let s): return trakt.imdb(for: s) ?? info?.imdbID }
    }
    private var trailerID: String? { info?.trailerYouTubeID ?? xtreamTrailer }
    private var seasons: [Int] { orderedUnique(episodes.map(\.season)).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tvScaled(14)) {
                header
                VStack(alignment: .leading, spacing: tvScaled(14)) {
                    Text(title).font(.system(size: tvScaled(26), weight: .heavy))
                    metaLine
                    primaryButtons
                    if let plot = info?.plot ?? plotFallback {
                        Text(plot).font(.system(size: tvScaled(14))).foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    credits
                    actionBar
                    if case .series(let s) = target { episodesSection(s) }
                }
                .padding(.horizontal, Theme.edge)
            }
            .padding(.bottom, 40)
            #if os(tvOS)
            .frame(maxWidth: 1500).frame(maxWidth: .infinity)
            #endif
        }
        .background(Color(hex: 0x141414).ignoresSafeArea())
        .task(id: target.id) { await load() }
        #if os(iOS)
        .sheet(isPresented: $showTrailer) {
            if let t = trailerID { TrailerSheet(youtubeID: t, title: title) }
        }
        #endif
    }

    // MARK: onderdelen

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: poster).frame(height: tvScaled(240)).frame(maxWidth: .infinity).blur(radius: 26).clipped().opacity(0.8)
            LinearGradient(colors: [.clear, Color(hex: 0x141414)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: tvScaled(16)) {
                RemoteImage(url: poster, placeholder: title)
                    .frame(width: tvScaled(120), height: tvScaled(180)).clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 14)
                Spacer()
                #if os(iOS)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).padding(10)
                        .background(.black.opacity(0.7), in: Circle())
                }
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14)
                #endif
            }
            .padding(.horizontal, Theme.edge)
        }
        .frame(height: tvScaled(240))
    }

    private var metaLine: some View {
        HStack(spacing: tvScaled(10)) {
            if let r = info?.imdbRating { IMDbBadge(rating: r) }
            if let y = info?.year ?? yearFallback { Text(y) }
            if let rated = info?.rated {
                Text(rated).font(.system(size: tvScaled(11), weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.secondary))
            }
            if let rt = info?.runtime { Text(rt) }
            if case .series = target, !seasons.isEmpty { Text(seasons.count == 1 ? L("1 season") : L("%d seasons", seasons.count)) }
            if isWatchedTitle { Label(L("Watched"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green) }
        }
        .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
    }

    @ViewBuilder private var primaryButtons: some View {
        let stack = Group {
            switch target {
            case .movie(let m):
                let resume = Playables.resume(m.id, imdb: imdb)
                NetflixButton(title: resume > 0.02 ? L("Resume") : L("Play"), icon: "play.fill") {
                    app.play(Playables.movie(m, imdb: imdb))
                }
                .frame(maxWidth: .infinity)
                if resume > 0.02 { ProgressBar(value: resume).frame(height: 3) }
            case .series(let s):
                if let next = nextEpisode {
                    NetflixButton(title: L("Play S%d:E%d", next.season, next.number), icon: "play.fill") {
                        app.play(Playables.episode(next, of: s, imdb: imdb))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if trailerID != nil {
                NetflixButton(title: "Trailer", icon: "film", kind: .secondary) { openTrailer() }
                    .frame(maxWidth: .infinity)
            }
        }
        #if os(tvOS)
        HStack(spacing: 30) { stack }.frame(maxWidth: 900, alignment: .leading)
        #else
        VStack(spacing: 8) { stack }
        #endif
    }

    @ViewBuilder private var credits: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = info?.actors { creditLine(L("Cast"), a) }
            if let d = info?.director { creditLine(L("Director"), d) }
            if let g = info?.genre { creditLine(L("Genres"), g) }
        }
    }

    private func creditLine(_ k: String, _ v: String) -> some View {
        (Text("\(k): ").foregroundStyle(Theme.secondary) + Text(v).foregroundStyle(.white.opacity(0.85)))
            .font(.system(size: tvScaled(12))).lineLimit(2)
    }

    private var actionBar: some View {
        HStack(spacing: tvScaled(36)) {
            actionButton(inMyList ? "checkmark" : "plus", L("My List")) {
                guard let pid else { return }
                store.toggleMyList(pid, target.id)
                if let imdb { Task { await trakt.toggleWatchlist(imdb: imdb, isShow: target.isSeries) } }
            }
            if case .movie(let m) = target {
                let w = Playables.isWatched(movie: m, imdb: imdb)
                actionButton(w ? "checkmark.circle.fill" : "checkmark.circle", w ? L("Watched") : L("Mark watched")) {
                    store.setLocalWatched(m.id, !w)
                    Task { await trakt.setWatched(Playables.movie(m, imdb: imdb), !w) }
                }
            }
            if let imdb {
                actionButton("star.circle", "IMDb") { openURL(URL(string: "https://www.imdb.com/title/\(imdb)/")!) }
            }
            if let slug = info?.traktSlug {
                actionButton("arrow.triangle.2.circlepath", "Trakt") {
                    openURL(URL(string: "https://trakt.tv/\(target.isSeries ? "shows" : "movies")/\(slug)")!)
                }
            }
        }
        .padding(.vertical, tvScaled(6))
    }

    private func actionButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: tvScaled(22)))
                Text(label).font(.system(size: tvScaled(10))).foregroundStyle(Theme.secondary)
            }
            .frame(minWidth: tvScaled(52))
        }
        .plainTVButton()
    }

    // MARK: afleveringen

    @ViewBuilder private func episodesSection(_ s: Series) -> some View {
        Divider().background(Theme.elevated)
        HStack {
            Text(L("Episodes")).font(.system(size: tvScaled(18), weight: .bold))
            Spacer()
            if seasons.count > 1 {
                Menu {
                    ForEach(seasons, id: \.self) { n in Button(L("Season %d", n)) { season = n } }
                } label: {
                    Label(L("Season %d", season), systemImage: "chevron.down")
                        .font(.system(size: tvScaled(14), weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        if loadingEpisodes { ProgressView().frame(maxWidth: .infinity).padding() }
        let list = episodes.filter { $0.season == season }
        if !list.isEmpty, imdb != nil {
            let allWatched = list.allSatisfy { Playables.isWatched($0, imdb: imdb) }
            Button {
                for e in list { store.setLocalWatched(e.id, !allWatched) }
                if let imdb { Task { await trakt.setWatched(show: imdb, episodes: list, !allWatched) } }
            } label: {
                Label(allWatched ? L("Mark season as unwatched") : L("Mark whole season watched"),
                      systemImage: allWatched ? "eye.slash" : "checkmark.circle")
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
            }
            .plainTVButton()
        }
        ForEach(list) { e in episodeRow(e, s) }
    }

    private func episodeRow(_ e: Episode, _ s: Series) -> some View {
        let watched = Playables.isWatched(e, imdb: imdb)
        let progress = store.progress[e.id]?.fraction
        return HStack(spacing: tvScaled(12)) {
            Button { app.play(Playables.episode(e, of: s, imdb: imdb)) } label: {
                HStack(spacing: tvScaled(12)) {
                    ZStack {
                        RemoteImage(url: e.still ?? s.poster).frame(width: tvScaled(124), height: tvScaled(70)).clipped()
                        Image(systemName: "play.circle").font(.system(size: tvScaled(26))).foregroundStyle(.white).shadow(radius: 4)
                        if let progress { VStack { Spacer(); ProgressBar(value: progress).frame(height: 3) } }
                    }
                    .frame(width: tvScaled(124), height: tvScaled(70))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(e.number). \(Playables.cleanEpisodeTitle(e))").font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(2)
                        if let d = e.durationSeconds { Text(L("%d min", d / 60)).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary) }
                        if let p = e.plot { Text(p).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .plainTVButton()
            Button {
                store.setLocalWatched(e.id, !watched)
                Task { await trakt.setWatched(Playables.episode(e, of: s, imdb: imdb), !watched) }
            } label: {
                Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: tvScaled(24)))
                    .foregroundStyle(watched ? Theme.red : Theme.secondary)
            }
            .plainTVButton()
        }
        .padding(.vertical, 4)
    }

    // MARK: logica

    private var isWatchedTitle: Bool {
        if case .movie(let m) = target { return Playables.isWatched(movie: m, imdb: imdb) }
        return false
    }

    private var inMyList: Bool {
        if let imdb, trakt.watchlist.contains(imdb) { return true }
        return pid.map { store.inMyList($0, target.id) } ?? false
    }

    private var nextEpisode: Episode? {
        if let resumed = episodes.first(where: { (store.progress[$0.id]?.fraction ?? 0) > 0.02 }) { return resumed }
        return episodes.first { !Playables.isWatched($0, imdb: imdb) } ?? episodes.first
    }

    private var plotFallback: String? {
        switch target { case .movie(let m): return m.plot; case .series(let s): return s.plot }
    }
    private var yearFallback: String? {
        switch target { case .movie(let m): return m.year.map(String.init); case .series(let s): return s.year.map(String.init) }
    }

    private func openTrailer() {
        guard let t = trailerID else { return }
        #if os(iOS)
        showTrailer = true
        #else
        if let u = Trailer.appURL(t) {
            openURL(u) { ok in if !ok, let w = Trailer.webURL(t) { openURL(w) } }
        }
        #endif
    }

    private func load() async {
        switch target {
        case .movie(let m):
            async let x = playlists.xtreamVodInfo(m)
            info = await meta.metadata(m, knownIMDb: trakt.imdb(for: m))
            if let vi = await x {
                if info == nil, let i = vi.imdb_id, !i.isEmpty { info = await meta.fetch(title: m.title, year: m.year, isShow: false, imdb: i) }
                if let yt = vi.youtube_trailer, !yt.isEmpty { xtreamTrailer = yt }
            }
        case .series(let s):
            loadingEpisodes = true
            async let eps = playlists.episodes(for: s)
            info = await meta.metadata(s)
            episodes = await eps
            loadingEpisodes = false
            season = nextEpisode?.season ?? seasons.first ?? 1
        }
    }
}
