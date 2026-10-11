import SwiftUI

/// Zoeken in de huidige afspeellijst én in alle andere afspeellijsten.
struct SearchView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    @State private var query = ""
    @State private var results = PlaylistService.SearchResults()
    @State private var detail: DetailTarget?
    @State private var searching = false
    @State private var programs: [ProgramHit] = []
    @State private var program: ProgramHit?

    struct ProgramHit: Identifiable { var id: String { channel.id + p.id }; let channel: Channel; let p: EPGProgram }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 20), spacing: Theme.rowSpacing)] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(22)) {
                    if query.count < 2 {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: tvScaled(40)))
                            Text(L("Search movies, series, channels and the TV guide in all your playlists")).font(.system(size: tvScaled(15)))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if results.isEmpty && programs.isEmpty && !searching {
                        Text(L("Nothing found for “%@”.", query)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if !results.channels.isEmpty {
                        MediaRow(title: L("Channels")) {
                            ForEach(results.channels) { c in
                                Button { app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)), zap: results.channels) } label: {
                                    ChannelCard(channel: c, now: playlists.library.nowPlaying(c))
                                }.cardButton()
                            }
                        }
                    }
                    if !programs.isEmpty { programList }
                    if !results.movies.isEmpty { grid(L("Movies"), results.movies.map { .movie($0) }) }
                    if !results.series.isEmpty { grid(L("Series"), results.series.map { .series($0) }) }
                    if !results.other.isEmpty { otherPlaylists }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle(L("Search"))
            .searchable(text: $query, prompt: L("Titles, channels…"))
            .onChange(of: query) { _, q in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard q == query else { return }
                    searching = true
                    results = await playlists.search(q)
                    programs = q.count < 2 ? [] : await Self.searchGuide(q, in: playlists.library)
                    searching = false
                }
            }
        }
        .sheet(item: $program) { h in ProgramSheet(channel: h.channel, program: h.p) }
        #if os(iOS)
        .sheet(item: $detail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    // MARK: tv-gids doorzoeken

    /// Zoekt in titels en omschrijvingen van de tv-gids: wat nu en straks speelt, en wat nog terug te kijken is.
    nonisolated static func searchGuide(_ q: String, in lib: Library) async -> [ProgramHit] {
        await Task.detached(priority: .userInitiated) {
            let now = Date()
            var hits: [ProgramHit] = []
            for c in lib.channels {
                guard let list = lib.epg[c.epgID ?? c.id] else { continue }
                let from = now.addingTimeInterval(-Double(max(c.catchupDays, 0)) * 86400)
                for p in list where p.end > from && p.title.localizedCaseInsensitiveContains(q) {
                    hits.append(ProgramHit(channel: c, p: p))
                }
                if hits.count > 400 { break }
            }
            // eerst wat nu speelt, dan de toekomst, dan terugkijken
            return hits.sorted { a, b in
                let ra = a.p.isNow ? 0 : (a.p.start > now ? 1 : 2), rb = b.p.isNow ? 0 : (b.p.start > now ? 1 : 2)
                if ra != rb { return ra < rb }
                return ra == 2 ? a.p.start > b.p.start : a.p.start < b.p.start
            }
            .prefix(60).map { $0 }
        }.value
    }

    private var programList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("TV guide")).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVStack(spacing: 4) {
                ForEach(programs) { h in
                    Button { program = h } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: h.channel.logo, contentMode: .fit, placeholder: String(h.channel.name.prefix(3)))
                                .frame(width: tvScaled(56), height: tvScaled(36))
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if h.p.isNow {
                                        Text(L("NOW")).font(.system(size: tvScaled(10), weight: .heavy)).foregroundStyle(Theme.red)
                                    } else if h.p.end < Date() {
                                        Image(systemName: "clock.arrow.circlepath").font(.system(size: tvScaled(10))).foregroundStyle(Theme.secondary)
                                    }
                                    Text(h.p.title).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                }
                                Text("\(h.channel.name) · \(h.p.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                                    .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.edge).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .plainTVButton()
                }
            }
        }
    }

    private func grid(_ title: String, _ items: [DetailTarget]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVGrid(columns: columns, spacing: Theme.rowSpacing * 2) {
                ForEach(items) { t in
                    Button { detail = t } label: {
                        switch t {
                        case .movie(let m):
                            PosterCard(title: m.title, poster: m.poster,
                                       watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)))
                        case .series(let s):
                            PosterCard(title: s.title, poster: s.poster)
                        }
                    }
                    .cardButton()
                }
            }
            .padding(.horizontal, Theme.edge)
        }
    }

    /// Treffers in andere afspeellijsten: tik → wissel van afspeellijst en open het item.
    private var otherPlaylists: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("In your other playlists")).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVStack(spacing: 4) {
                ForEach(results.other) { h in
                    Button { app.open(h.playlist, thenShow: h.itemID) } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: h.artwork, contentMode: .fill, placeholder: String(h.title.prefix(2)))
                                .frame(width: tvScaled(44), height: tvScaled(62)).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.title).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                Text(h.subtitle).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                MiniAvatar(playlist: h.playlist, size: tvScaled(22))
                                Text(h.playlist.name).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.horizontal, Theme.edge).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .plainTVButton()
                }
            }
        }
    }
}
