import SwiftUI

/// Bovenkant van Mijn Bingr, zoals "Mijn Netflix": je profiel, en daaronder Verder kijken en Mijn lijst.
struct MyBingrHeader: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @State private var detail: DetailTarget?
    @State private var resumeChoice: ResumeChoice?
    /// Build 128: items van andere servers
    @ObservedObject private var cross = CrossServer.shared
    /// build 157: Verder kijken is Lifetime
    @ObservedObject private var ent = EntitlementsService.shared
    @State private var prompt: CrossServer.Prompt?
    /// Build 147: de gedeelde index (op de achtergrond gebouwd) i.p.v. per schermverversing door de hele bibliotheek
    @State private var index = HomeIndex()
    @State private var indexVersion = -1

    private var lib: Library { playlists.library }
    private var pid: UUID? { playlists.source?.id }

    /// Verder kijken van dít profiel (films + series met voortgang), nieuwste eerst.
    private struct ContinueEntry: Identifiable {
        let id: String; let target: DetailTarget; let entry: ProgressEntry
        /// Build 128: server als dat niet de open server is
        var source: UUID? = nil
    }
    /// Build 128: over alle servers (andere servers via CrossServer)
    private var continueItems: [ContinueEntry] {
        _ = cross.version
        let movies = index.movieByID
        let seriesByTitle = index.seriesByTitle
        var seen = Set<String>()
        return store.progress
            .filter { store.belongsToActive($0.value.profileID) }
            .sorted { $0.value.updated > $1.value.updated }
            .compactMap { key, e -> ContinueEntry? in
                var t: DetailTarget?
                var source: UUID?
                if let other = e.playlistID, other != pid {
                    let full = other.uuidString + "|" + key
                    t = cross.movie(forKey: full).map { .movie($0) } ?? cross.episodeSeries(playlist: other, key: key).map { .series($0) }
                    source = other
                } else {
                    t = movies[key].map { .movie($0) } ?? seriesByTitle[e.title].map { .series($0) }
                }
                guard let t, seen.insert(t.id).inserted else { return nil }   // per serie alleen de laatste aflevering
                return ContinueEntry(id: key, target: t, entry: e, source: source)
            }
            .prefix(20).map { $0 }
    }

    private func isActive(_ key: String) -> Bool {
        guard let pid, let bar = key.firstIndex(of: "|") else { return false }
        return key[..<bar].caseInsensitiveCompare(pid.uuidString) == .orderedSame
    }

    private var favoriteChannels: [Channel] {
        _ = cross.version
        // build 147: via de sleutels en de index (niet elke zender langs de favorieten)
        let active: [Channel] = pid.map { p in
            store.favorites.filter { isActive($0) }
                .sorted { cross.addedAt($0, field: "favorites") > cross.addedAt($1, field: "favorites") }
                .compactMap { index.channel(forKey: $0, playlist: p) }
        } ?? []
        let other = store.favorites.filter { !isActive($0) }
            .sorted { cross.addedAt($0, field: "favorites") > cross.addedAt($1, field: "favorites") }
            .compactMap { cross.channel(forKey: $0) }
        return CrossServer.dedupe(uniqueByID(active + other), identity: CrossServer.identity)
    }

    private var myListItems: [DetailTarget] {
        _ = cross.version
        var out: [DetailTarget] = []
        // build 147: via de sleutels van Mijn lijst en de index, laatst toegevoegd eerst (niet elke film langs de lijst)
        let keys = store.myList.sorted { cross.addedAt($0, field: "myList") > cross.addedAt($1, field: "myList") }
        if let pid {
            for k in keys where MyListID.origin(of: k, activeSID: pid.uuidString) == .active {
                if let m = index.movie(forKey: k, playlist: pid) { out.append(.movie(m)) }
                else if let x = index.series(forKey: k, playlist: pid) { out.append(.series(x)) }
            }
        }
        for k in keys {
            // build 141: ook TMDB-titels (bijv. een aanbeveling uit zoeken), zoals de rij Mijn lijst op Home
            switch MyListID.origin(of: k, activeSID: pid?.uuidString) {
            case .otherServer?:
                if let m = cross.movie(forKey: k) { out.append(.movie(m)) } else if let s = cross.series(forKey: k) { out.append(.series(s)) }
            case .external?:
                if store.activeProfile?.effectiveAgeLimit == nil, let p = pid, let i = DiscoverKnown.shared.item(forKey: k, playlist: p) {
                    out.append(i.target)
                }
            default: break
            }
        }
        var seen = Set<String>()
        return out.filter { t in
            let id: String
            switch t { case .movie(let m): id = CrossServer.identity(m); case .series(let s): id = CrossServer.identity(s) }
            return seen.insert(t.id).inserted && seen.insert(id).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(18)) {
            VStack(spacing: tvScaled(8)) {
                // build 72: avatar en naam openen het profielmenu (andere profielen, Instellingen, Account, Uitloggen)
                ProfileMenuButton {
                    VStack(spacing: tvScaled(8)) {
                        ProfileAvatar(size: tvScaled(84))
                        HStack(spacing: 6) {
                            Text(store.activeProfile?.name ?? L("My Bingr")).font(.system(size: tvScaled(20), weight: .bold))
                            Image(systemName: "chevron.down").font(.system(size: tvScaled(13), weight: .bold))
                        }
                        .foregroundStyle(.white)
                    }
                    .contentShape(Rectangle())
                }
                if trakt.isLoggedIn { traktStatus }
            }
            .frame(maxWidth: .infinity)

            let cont = continueItems
            switch ContinueWatching157.row(allowed: ent.allows(.continueWatching), hasItems: !cont.isEmpty) {
            case .hidden: EmptyView()
            case .locked: lockedContinueRow   // build 157: Gratis, de voortgang blijft bewaard
            case .items: continueRow(cont)
            }
            row(L("My List"), myListItems.map { ($0, nil) }, empty: L("Add titles with + My List and they'll appear here."))
            let favs = favoriteChannels
            if !favs.isEmpty { channelRow(favs) }
        }
        .resumeDialog($resumeChoice) { detail = $0 }
        .crossServerPrompt($prompt)
        .task(id: playlists.libraryVersion) {
            let v = playlists.libraryVersion
            guard v != indexVersion else { return }
            let built = await HomeIndexCache.shared.index(for: playlists.library, version: v)
            guard !Task.isCancelled else { return }
            index = built
            indexVersion = v
        }
        .padding(.vertical, tvScaled(8))
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    /// Trakt-status: draaiende pijltjes tijdens synchroniseren, anders de laatste sync; tik = nu synchroniseren.
    private var traktStatus: some View {
        Button { Task { await trakt.refresh(force: true) } } label: {
            HStack(spacing: 6) {
                if trakt.isSyncing { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
                else { Image(systemName: trakt.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trakt.lastError == nil ? Theme.green : Theme.red) }
                Text(trakt.isSyncing ? L("Syncing with Trakt…") : trakt.justSynced ? L("Up to date")
                     : trakt.lastRefresh.map { L("Trakt synced %@", $0.formatted(date: .omitted, time: .shortened)) } ?? L("Sync now"))
            }
            .font(.system(size: tvScaled(12), weight: .medium))
            .foregroundStyle(Theme.secondary)
        }
        .plainTVButton()
        .disabled(trakt.isSyncing)
    }

    /// build 157: Verder kijken op slot (Gratis): het slotje met de vergelijking
    private var lockedContinueRow: some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("Continue watching")).font(Theme.titleFont).foregroundStyle(.white)
            LifetimeLockCard(feature: .continueWatching, text: L("Your progress is saved. Continue watching is part of Lifetime."))
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
        }
    }

    private func continueRow(_ items: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("Continue watching")).font(Theme.titleFont).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.rowSpacing) {
                    ForEach(items) { c in
                        let e = c.entry
                        let left = max(0, e.position / max(e.fraction, 0.01) - e.position)
                        Button {
                            let choice = ResumeChoice(id: c.id, title: e.title, fraction: e.fraction,
                                                      position: e.position > 0 ? e.position : nil, detail: c.target, source: c.source)
                            CrossServerOpen.title(c.target, list: .continueWatching,
                                                  onTarget: { t in
                                                      var x = choice
                                                      if t.id != c.target.id { x = ResumeChoice(id: t.id, title: e.title, fraction: e.fraction, position: x.position, detail: t, source: t.sourceID) }
                                                      resumeChoice = x
                                                  },
                                                  onPrompt: { prompt = $0 })
                        } label: {
                            ContinueCard(title: e.title, poster: cover(c.target) ?? e.artwork, fraction: e.fraction,   // build 141/143: cover eerst
                                         caption: L("%d min left", Int(left / 60)))
                        }
                        .cardButton()
                    }
                }
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
        }
    }

    private func channelRow(_ list: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("Favorite channels")).font(Theme.titleFont).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.rowSpacing) {
                    ForEach(list) { c in
                        Button {
                            CrossServerOpen.channel(c, list: .favorites,
                                                    onChannel: { app.play(Playables.channel($0, now: lib.nowPlaying($0)), zap: list) },
                                                    onPrompt: { prompt = $0 })
                        } label: {
                            ChannelCard(channel: c, now: lib.nowPlaying(c), favorite: true)
                        }
                        .cardButton()
                    }
                }
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
        }
    }

    /// Build 143: de TMDB-poster (Verder kijken, zie ContinueCovers), anders de poster uit de bibliotheek
    private func cover(_ t: DetailTarget) -> URL? {
        switch t {
        case .movie(let m): return ContinueCovers.shared.cover(title: m.title, year: m.year, isShow: false) ?? m.poster
        case .series(let s): return ContinueCovers.shared.cover(title: s.title, year: s.year, isShow: true) ?? s.poster
        }
    }

    private func poster(_ t: DetailTarget) -> URL? {
        switch t { case .movie(let m): return m.poster; case .series(let s): return s.poster }
    }

    @ViewBuilder private func row(_ title: String, _ items: [(DetailTarget, Double?)], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(title).font(Theme.titleFont).foregroundStyle(.white)
            if items.isEmpty, let empty {
                Text(empty).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.rowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                            let (t, fraction) = pair
                            Button { CrossServerOpen.title(t, list: .myList, onTarget: { detail = $0 }, onPrompt: { prompt = $0 }) } label: {
                                switch t {
                                case .movie(let m):
                                    let imdb = trakt.imdb(for: m)
                                    PosterCard(title: m.title, poster: m.poster, imdbID: imdb,
                                               watched: Playables.isWatched(movie: m, imdb: imdb),
                                               progress: fraction, language: ContentLanguage.of(m))
                                case .series(let s):
                                    let imdb = trakt.imdb(for: s)
                                    PosterCard(title: s.title, poster: s.poster, imdbID: imdb, watched: Playables.isSeriesWatched(s, imdb: imdb), progress: fraction,
                                               watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: imdb),
                                               language: ContentLanguage.of(s))
                                }
                            }
                            .cardButton()
                        }
                    }
                    #if os(tvOS)
                    .padding(.vertical, 20)
                    #endif
                }
            }
        }
    }
}

#if !os(macOS)
/// Tabbladicoon "Mijn Bingr": de profielfoto (rond), zoals bij Netflix.
@MainActor
enum ProfileTabIcon {
    /// Build 147: één keer per profiel/foto/grootte tekenen (dit stond in de body van de tabbalk: bij elke
    /// schermverversing de foto opnieuw decoderen en tekenen op de hoofdthread)
    @MainActor private static var cache: (key: String, image: UIImage?)?

    @MainActor static func image(_ store: CloudStore, size side: CGFloat = 26) -> UIImage? {
        guard let p = store.activeProfile else { return nil }
        let photo = store.photos[p.id]
        var fp = -1
        if let photo { fp = photo.count &+ photo.prefix(64).hashValue &+ photo.suffix(64).hashValue }
        let key = "\(p.id.uuidString)|\(fp)|\(p.avatar.symbol)|\(side)"
        if let c = cache, c.key == key { return c.image }
        let out = render(p, photo: photo, side: side)
        cache = (key, out)
        return out
    }

    private static func render(_ p: ViewerProfile, photo: Data?, side: CGFloat) -> UIImage? {
        let img: UIImage
        if let d = photo, let i = UIImage(data: d) { img = i }
        else if p.avatar.isIllustration, let i = UIImage(named: p.avatar.symbol) { img = i }
        else { return nil }
        let size = CGSize(width: side, height: side)
        let out = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.withRenderingMode(.alwaysOriginal)
    }
}
#endif
