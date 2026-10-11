import SwiftUI

/// Zoeken in de huidige afspeellijst én in alle andere afspeellijsten.
struct SearchView: View {
    /// Geopend via het vergrootglas op Home/Films/Series (met sluitknop en meteen typen)
    var modal = false
    @Environment(\.dismiss) private var dismiss
    @State private var searchActive = false
    @State private var category: CategoryTarget?
    @State private var groupHits: [(title: String, items: [DetailTarget])] = []
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
                    } else if results.isEmpty && programs.isEmpty && groupHits.isEmpty && !searching {
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
                    if !groupHits.isEmpty { categoryList }
                    if !programs.isEmpty { programList }
                    if !results.movies.isEmpty { grid(L("Movies"), results.movies.map { .movie($0) }) }
                    if !results.series.isEmpty { grid(L("Series"), results.series.map { .series($0) }) }
                    if !results.other.isEmpty && CloudStore.shared.isMainActive { otherPlaylists }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle(L("Search"))
            .modifier(SearchField(query: $query, active: $searchActive, modal: modal, close: { dismiss() }))
            .onChange(of: query) { _, q in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard q == query else { return }
                    searching = true
                    results = await playlists.search(q)
                    programs = q.count < 2 ? [] : await Self.searchGuide(q, in: playlists.library)
                    groupHits = q.count < 2 ? [] : categoryHits(q)
                    searching = false
                }
            }
        }
        .sheet(item: $program) { h in ProgramSheet(channel: h.channel, program: h.p) }
        .fullScreenCover(item: $category) { CategoryView(target: $0) }
        #if os(iOS)
        .sheet(item: $detail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    // MARK: categorieën doorzoeken (films en series, alle categorieën)

    private func categoryHits(_ q: String) -> [(title: String, items: [DetailTarget])] {
        let t = PlaylistService.fold(q.trimmingCharacters(in: .whitespaces))
        let lib = playlists.library
        var out: [(title: String, items: [DetailTarget])] = []
        for g in lib.movieGroups where PlaylistService.fold(g).contains(t) {
            out.append((g, lib.movies.filter { $0.group == g }.map { .movie($0) }))
        }
        for g in lib.seriesGroups where PlaylistService.fold(g).contains(t) {
            out.append((g, lib.series.filter { $0.group == g }.map { .series($0) }))
        }
        return Array(out.prefix(30))
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Categories")).font(Theme.titleFont).padding(.leading, Theme.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tvScaled(10)) {
                    ForEach(groupHits, id: \.title) { g in
                        Button { category = CategoryTarget(title: g.title, items: g.items) } label: {
                            HStack(spacing: 6) {
                                Text(g.title).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                Text("\(g.items.count)").font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, tvScaled(14)).padding(.vertical, tvScaled(8))
                            .background(Theme.elevated, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .plainTVButton()
                    }
                }
                .padding(.horizontal, Theme.edge)
            }
        }
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

/// Zoekveld; als los venster (vergrootglas) met sluitknop en meteen het toetsenbord open.
private struct SearchField: ViewModifier {
    @Binding var query: String
    @Binding var active: Bool
    let modal: Bool
    let close: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .searchable(text: $query, isPresented: $active, prompt: Text(L("Titles, channels, categories…")))
            .toolbar {
                if modal {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Close"), action: close) }
                }
            }
            .onAppear { if modal { active = true } }
        #else
        content.searchable(text: $query, prompt: Text(L("Titles, channels, categories…")))
        #endif
    }
}
