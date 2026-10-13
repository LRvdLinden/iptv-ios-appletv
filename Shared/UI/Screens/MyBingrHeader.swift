import SwiftUI

/// Bovenkant van Mijn Bingr, zoals "Mijn Netflix": je profiel, en daaronder Verder kijken en Mijn lijst.
struct MyBingrHeader: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @State private var detail: DetailTarget?
    @State private var resumeChoice: ResumeChoice?

    private var lib: Library { playlists.library }
    private var pid: UUID? { playlists.source?.id }

    /// Verder kijken van dít profiel (films + series met voortgang), nieuwste eerst.
    private struct ContinueEntry: Identifiable {
        let id: String; let target: DetailTarget; let entry: ProgressEntry
    }
    private var continueItems: [ContinueEntry] {
        let movies = Dictionary(lib.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let seriesByTitle = Dictionary(lib.series.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return store.progress
            .filter { store.belongsToActive($0.value.profileID) && ($0.value.playlistID == nil || $0.value.playlistID == pid) }
            .sorted { $0.value.updated > $1.value.updated }
            .compactMap { key, e -> ContinueEntry? in
                let t: DetailTarget? = movies[key].map { .movie($0) } ?? seriesByTitle[e.title].map { .series($0) }
                guard let t, seen.insert(t.id).inserted else { return nil }   // per serie alleen de laatste aflevering
                return ContinueEntry(id: key, target: t, entry: e)
            }
            .prefix(20).map { $0 }
    }

    private var favoriteChannels: [Channel] {
        guard let pid else { return [] }
        return lib.channels.filter { store.isFavorite(pid, $0.id) }
    }

    private var myListItems: [DetailTarget] {
        guard let pid else { return [] }
        return lib.movies.filter { store.inMyList(pid, $0.id) }.map { .movie($0) }
            + lib.series.filter { store.inMyList(pid, $0.id) }.map { .series($0) }
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
            if !cont.isEmpty { continueRow(cont) }
            row(L("My List"), myListItems.map { ($0, nil) }, empty: L("Add titles with + My List and they'll appear here."))
            let favs = favoriteChannels
            if !favs.isEmpty { channelRow(favs) }
        }
        .resumeDialog($resumeChoice) { detail = $0 }
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

    private func continueRow(_ items: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("Continue watching")).font(Theme.titleFont).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.rowSpacing) {
                    ForEach(items) { c in
                        let e = c.entry
                        let left = max(0, e.position / max(e.fraction, 0.01) - e.position)
                        Button {
                            resumeChoice = ResumeChoice(id: c.id, title: e.title, fraction: e.fraction,
                                                        position: e.position > 0 ? e.position : nil, detail: c.target)
                        } label: {
                            ContinueCard(title: e.title, poster: e.artwork ?? poster(c.target), fraction: e.fraction,
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
                        Button { app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: list) } label: {
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
                            Button { detail = t } label: {
                                switch t {
                                case .movie(let m):
                                    PosterCard(title: m.title, poster: m.poster, imdbID: trakt.imdb(for: m), progress: fraction, language: ContentLanguage.of(m))
                                case .series(let s):
                                    PosterCard(title: s.title, poster: s.poster, imdbID: trakt.imdb(for: s), progress: fraction, language: ContentLanguage.of(s))
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
    static func image(_ store: CloudStore, size side: CGFloat = 26) -> UIImage? {
        guard let p = store.activeProfile else { return nil }
        let img: UIImage
        if let d = store.photos[p.id], let i = UIImage(data: d) { img = i }
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
