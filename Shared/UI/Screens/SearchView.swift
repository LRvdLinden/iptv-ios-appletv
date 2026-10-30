import SwiftUI

/// Zoeken in de huidige afspeellijst én in alle andere afspeellijsten.
struct SearchView: View {
    /// Geopend via het vergrootglas op Home/Films/Series (met sluitknop en meteen typen)
    var modal = false
    /// Build 120: met deze zoekterm openen (titel-link zonder eenduidige match)
    var initialQuery: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var searchActive = false
    @State private var category: CategoryTarget?
    @State private var groupHits: [(title: String, items: [DetailTarget])] = []
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync
    /// vinkjes en "N BEKEKEN" ook bijwerken na afvinken in Bingr (build 75)
    @EnvironmentObject var store: CloudStore
    @State private var query = ""
    @State private var results = PlaylistService.SearchResults()
    @State private var detail: DetailTarget?
    @State private var searching = false
    @State private var programs: [ProgramHit] = []
    @State private var program: ProgramHit?
    /// Acteurs/actrices bij TMDB (vanaf 3 tekens)
    @State private var people: [PersonRef] = []
    @State private var peopleTask: Task<Void, Never>?
    @State private var person: PersonRef?

    struct ProgramHit: Identifiable { var id: String { channel.id + p.id }; let channel: Channel; let p: EPGProgram }

    /// Meerdere bronnen: elk resultaat krijgt de kleur (avatar) van zijn bron
    private var showSources: Bool { CloudStore.shared.playlists.count > 1 }
    private var currentSource: PlaylistSource? { showSources ? playlists.source : nil }

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
                    } else if results.isEmpty && programs.isEmpty && groupHits.isEmpty && people.isEmpty && !searching {
                        Text(L("Nothing found for “%@”.", query)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if !people.isEmpty { peopleRow }
                    if !groupHits.isEmpty { categoryList }
                    if !results.movies.isEmpty { grid(L("Movies"), results.movies.map { .movie($0) }) }
                    if !results.series.isEmpty { grid(L("Series"), results.series.map { .series($0) }) }
                    if !results.other.isEmpty { otherPlaylists }   // build 130: voor elk profiel
                    // build 149: treffers in verborgen categorieën, onderaan met label
                    if !results.hiddenMovies.isEmpty || !results.hiddenSeries.isEmpty {
                        grid(L("In hidden categories"), results.hiddenMovies.map { .movie($0) } + results.hiddenSeries.map { .series($0) })
                    }
                    // Live TV (zenders en tv-gids) altijd als laatste, na films en series; de tvOS-focus volgt deze volgorde
                    if !results.channels.isEmpty { channelRow }
                    if !programs.isEmpty { programList }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle(L("Search"))
            .modifier(SearchField(query: $query, active: $searchActive, modal: modal, close: { dismiss() }))
            .onAppear { if query.isEmpty, let q = initialQuery, !q.isEmpty { query = q } }
            .onChange(of: query) { _, q in
                searchPeople(q)
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard q == query else { return }
                    searching = true
                    let r = await playlists.search(q)
                    let p = q.count < 2 ? [] : await Self.searchGuide(q, in: playlists.library)
                    // intussen verder getypt → deze (oude) resultaten niet meer tonen
                    guard q == query else { return }
                    results = r
                    programs = p
                    groupHits = q.count < 2 ? [] : categoryHits(q)
                    searching = false
                }
            }
        }
        .sheet(item: $program) { h in ProgramSheet(channel: h.channel, program: h.p) }
        #if os(iOS)
        .sheet(item: $person) { PersonView(person: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $person) { PersonView(person: $0) }
        #endif
        .fullScreenCover(item: $category) { CategoryView(target: $0) }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    /// Zenders (Live TV): staan onderaan, na films en series.
    private var channelRow: some View {
        MediaRow(title: L("Channels")) {
            ForEach(results.channels) { c in
                Button { app.play(Playables.channel(c, now: playlists.library.nowPlaying(c)), zap: results.channels) } label: {
                    ChannelCard(channel: c, now: playlists.library.nowPlaying(c))
                        .sourceAccent(currentSource)
                }.cardButton()
            }
        }
    }

    // MARK: personen (TMDB)

    /// Zoekt acteurs/actrices op naam: met vertraging, en een vorige zoekopdracht wordt afgebroken.
    private func searchPeople(_ q: String) {
        peopleTask?.cancel()
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 3, PersonService.shared.available else { people = []; return }
        peopleTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let found = await PersonService.shared.search(term)
            guard !Task.isCancelled, term == query.trimmingCharacters(in: .whitespaces) else { return }
            people = found
        }
    }

    private var peopleRow: some View {
        MediaRow(title: L("People")) {
            ForEach(people) { p in
                Button { person = p } label: {
                    PersonBubble(name: p.name, photo: p.photo, subtitle: p.department.map(PersonView.department), size: tvScaled(84))
                }
                .plainTVButton()
            }
        }
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
            // eerst wat nu speelt, dan de toekomst, dan terugkijken
            func before(_ a: ProgramHit, _ b: ProgramHit) -> Bool {
                let ra = a.p.isNow ? 0 : (a.p.start > now ? 1 : 2), rb = b.p.isNow ? 0 : (b.p.start > now ? 1 : 2)
                if ra != rb { return ra < rb }
                return ra == 2 ? a.p.start > b.p.start : a.p.start < b.p.start
            }
            // build 97: per zender sorteren en de beste paar houden (vroeger stopte het bij 400 treffers vóór het
            // sorteren, waardoor de eerste zenders in de lijst altijd voorgingen)
            let perChannel = 8
            var hits: [ProgramHit] = []
            for c in lib.channels {
                guard let list = lib.epg[c.epgID ?? c.id] else { continue }
                let from = now.addingTimeInterval(-Double(max(c.catchupDays, 0)) * 86400)
                var mine: [ProgramHit] = []
                for p in list where p.end > from && p.title.localizedCaseInsensitiveContains(q) {
                    mine.append(ProgramHit(channel: c, p: p))
                }
                guard !mine.isEmpty else { continue }
                hits.append(contentsOf: mine.sorted(by: before).prefix(perChannel))
            }
            return Array(hits.sorted(by: before).prefix(60))
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
                                    Text(CategoryName.display(h.p.title)).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
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
                                       watched: Playables.isWatched(movie: m, imdb: trakt.imdb(for: m)), language: ContentLanguage.of(m))
                                .sourceAccent(currentSource)
                        case .series(let s):
                            PosterCard(title: s.title, poster: s.poster,
                                       watchedEpisodes: Playables.watchedEpisodeCount(s, imdb: trakt.imdb(for: s)), language: ContentLanguage.of(s))
                                .sourceAccent(currentSource)
                        }
                    }
                    .cardButton()
                }
            }
            .padding(.horizontal, Theme.edge)
        }
    }

    /// Build 129: een treffer op een andere server openen en afspelen via die server, zonder te wisselen. Alleen als het
    /// item niet meer in de catalogus van die server staat: zoals voorheen naar die server.
    private func openOther(_ h: PlaylistService.OtherHit) {
        Task { @MainActor in
            guard let f = await playlists.foreignItem(h) else { app.open(h.playlist, thenShow: h.itemID); return }
            if let m = f.movie { detail = .movie(m) }
            else if let s = f.series { detail = .series(s) }
            else if let c = f.channel {
                store.pushRecentChannel(h.playlist.id, c.id)
                app.play(Playables.channel(c, now: nil), zap: [c])
            }
        }
    }

    /// Treffers in andere afspeellijsten: tik → het item openen via zijn eigen server (build 129: zonder te wisselen).
    private var otherPlaylists: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("In your other playlists")).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVStack(spacing: 4) {
                ForEach(results.other) { h in
                    Button { openOther(h) } label: {
                        HStack(spacing: 12) {
                            Capsule().fill(h.playlist.avatar.gradient).frame(width: tvScaled(4), height: tvScaled(52))
                            RemoteImage(url: h.artwork, contentMode: .fill, placeholder: String(h.title.prefix(2)))
                                .frame(width: tvScaled(44), height: tvScaled(62)).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ContentLanguage.shown(h.title)).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                Text(h.subtitle).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            SourceBadge(source: h.playlist)
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

/// Bron van een zoekresultaat: naam op de kleur van de avatar van die bron.
struct SourceBadge: View {
    let source: PlaylistSource
    var body: some View {
        HStack(spacing: 4) {
            AvatarGlyph(avatar: source.avatar, size: tvScaled(8))
                .frame(width: tvScaled(14), height: tvScaled(14))
                .clipShape(Circle())
            Text(source.name).font(.system(size: tvScaled(10), weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 2)
        .background(source.avatar.gradient, in: Capsule())
    }
}

extension View {
    /// Kleuraccent en naam van de bron (alleen als er meerdere bronnen zijn).
    @ViewBuilder func sourceAccent(_ source: PlaylistSource?) -> some View {
        if let source {
            self
                .overlay(alignment: .bottom) { Rectangle().fill(source.avatar.gradient).frame(height: tvScaled(3)) }
                .overlay(alignment: .topLeading) {
                    SourceBadge(source: source).frame(maxWidth: Theme.posterWidth - 8, alignment: .leading).padding(4)
                }
        } else {
            self
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
        #if !os(tvOS)
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
