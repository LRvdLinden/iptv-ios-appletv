import SwiftUI

/// Build 176: "Nieuw en populair" (Binnenkort, Nieuwe seizoenen, Populair) via de bestaande TMDB-route, met per titel
/// een belletje (herinnering op de releasedatum, `ReminderCenter.toggleRelease`) en "Nu beschikbaar" als de titel al op
/// een server van het account staat (bestaande matching). Contract: docs/ACCOUNT.md → "Build 176" (4).
actor NewPopular176 {
    static let shared = NewPopular176()

    struct Item: Identifiable, Hashable, Sendable {
        var item: DiscoverItem
        /// Nieuw seizoen (series uit Mijn lijst / Verder kijken)
        var season: Int?
        var id: String { item.id + (season.map { "-s\($0)" } ?? "") }
    }

    private var cache: [String: (Date, [Item])] = [:]

    private struct Trending: Decodable {
        struct R: Decodable {
            let id: Int
            let media_type: String?
            let title: String?, name: String?, original_title: String?, original_name: String?
            let release_date: String?, first_air_date: String?
            let poster_path: String?, backdrop_path: String?, overview: String?
            let adult: Bool?
        }
        let results: [R]?
    }

    private struct Show: Decodable {
        struct Ep: Decodable { let air_date: String?; let season_number: Int? }
        struct Season: Decodable { let air_date: String?; let season_number: Int? }
        let id: Int
        let name: String?, original_name: String?
        let poster_path: String?, backdrop_path: String?, overview: String?
        let next_episode_to_air: Ep?
        let seasons: [Season]?
    }

    /// Populair deze week (films en series); niet voor een kinderprofiel
    func popular() async -> [Item] {
        let k = "popular.\(TMDB.language)"
        if let c = cache[k], Date().timeIntervalSince(c.0) < 12 * 3600 { return c.1 }
        guard let p: Trending = await TMDB.get("/trending/all/week", ["language": TMDB.language]) else { return cache[k]?.1 ?? [] }
        let out = (p.results ?? []).compactMap { r -> Item? in
            guard r.adult != true, r.media_type == "movie" || r.media_type == "tv" else { return nil }
            let show = r.media_type == "tv"
            guard let t = (show ? r.name : r.title), !t.isEmpty, let poster = r.poster_path, !poster.isEmpty else { return nil }
            let o = show ? r.original_name : r.original_title
            return Item(item: DiscoverItem(tmdbID: r.id, isShow: show, title: t, originalTitle: o == t ? nil : o,
                                           date: (show ? r.first_air_date : r.release_date).flatMap { $0.isEmpty ? nil : $0 },
                                           posterPath: poster, backdropPath: r.backdrop_path,
                                           overview: r.overview.flatMap { $0.isEmpty ? nil : $0 }, kind: .streaming))
        }
        cache[k] = (Date(), out)
        DiscoverKnown.shared.remember(out.map(\.item))
        return out
    }

    /// Nieuwe seizoenen van series uit Mijn lijst en Verder kijken (TMDB-id van de bron): volgende aflevering of een
    /// seizoen dat binnen 60 dagen begint (max. 25 series)
    func newSeasons(tmdbIDs: [Int]) async -> [Item] {
        let ids = Array(orderedUnique(tmdbIDs).prefix(25))
        let k = "seasons.\(TMDB.language).\(ids.map(String.init).joined(separator: ","))"
        if let c = cache[k], Date().timeIntervalSince(c.0) < 12 * 3600 { return c.1 }
        let today = DiscoverItem.day(Date())
        let limit = DiscoverItem.day(Date().addingTimeInterval(60 * 86400))
        var out: [Item] = []
        for id in ids {
            guard let s: Show = await TMDB.get("/tv/\(id)", ["language": TMDB.language]),
                  let name = s.name, !name.isEmpty else { continue }
            var day: String?, season: Int?
            if let n = s.next_episode_to_air, let d = n.air_date, d >= today, d <= limit {
                day = d; season = n.season_number
            } else if let x = (s.seasons ?? []).first(where: { ($0.air_date ?? "") >= today && ($0.air_date ?? "") <= limit }) {
                day = x.air_date; season = x.season_number
            }
            guard let day else { continue }
            let o = s.original_name
            out.append(Item(item: DiscoverItem(tmdbID: s.id, isShow: true, title: name, originalTitle: o == name ? nil : o,
                                               date: day, posterPath: s.poster_path, backdropPath: s.backdrop_path,
                                               overview: s.overview, kind: .upcoming),
                            season: season))
        }
        out.sort { ($0.item.date ?? "") < ($1.item.date ?? "") }
        cache[k] = (Date(), out)
        return out
    }
}

/// De pagina "Nieuw en populair"
struct NewPopularView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @ObservedObject private var reminders = ReminderCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var upcoming: [Entry] = []
    @State private var seasons: [Entry] = []
    @State private var popular: [Entry] = []
    @State private var loading = true
    @State private var detail: DetailTarget?
    @State private var toast: String?

    struct Entry: Identifiable {
        let it: NewPopular176.Item
        let match: DetailTarget?
        var id: String { it.id }
    }

    private var kids: Bool { store.activeProfile?.kids ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(24)) {
                    if loading && upcoming.isEmpty && seasons.isEmpty && popular.isEmpty {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if upcoming.isEmpty && seasons.isEmpty && popular.isEmpty {
                        Text(L("Nothing to show right now.")).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    section(L("Coming soon"), upcoming)
                    section(L("New seasons"), seasons)
                    section(L("Popular"), popular)
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle(L("New & Popular"))
            #if !os(tvOS)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            #endif
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: tvScaled(13), weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 40)
                        .transition(.opacity)
                }
            }
        }
        .task(id: "\(playlists.libraryVersion)-\(store.activeProfileID?.uuidString ?? "")") { await load() }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    @ViewBuilder private func section(_ title: String, _ items: [Entry]) -> some View {
        if !items.isEmpty {
            MediaRow(title: title) {
                ForEach(items) { e in card(e) }
            }
        }
    }

    private func card(_ e: Entry) -> some View {
        let i = e.it.item
        let on = reminders.hasRelease(tmdb: i.tmdbID, isShow: i.isShow, season: e.it.season)
        let future = (i.date ?? "") > DiscoverItem.day(Date())
        return VStack(alignment: .leading, spacing: tvScaled(6)) {
            Button { detail = e.match ?? i.target } label: {
                PosterCard(title: i.title, poster: i.poster, badge: label(e), badgeAlignment: .topLeading)
            }
            .cardButton()
            HStack(spacing: tvScaled(6)) {
                if e.match != nil {
                    Label(L("Available now"), systemImage: "play.circle.fill")
                        .font(.system(size: tvScaled(11), weight: .semibold)).foregroundStyle(Theme.green)
                        .lineLimit(1)
                } else if future, let day = i.date {
                    Button {
                        Task {
                            let now = await reminders.toggleRelease(tmdb: i.tmdbID, isShow: i.isShow, season: e.it.season,
                                                                    title: e.it.season.map { L("%@ season %d", i.title, $0) } ?? i.title,
                                                                    day: day)
                            flash(now ? L("We'll remind you on the release date") : L("Reminder off"))
                        }
                    } label: {
                        Image(systemName: on ? "bell.fill" : "bell")
                            .font(.system(size: tvScaled(15), weight: .semibold))
                            .foregroundStyle(on ? Theme.red : .white)
                            .symbolEffect(.bounce, value: on)   // build 176: kleine animatie
                            .padding(tvScaled(6))
                    }
                    .plainTVButton()
                    .accessibilityLabel(on ? L("Reminder on") : L("Remind me"))
                }
                Spacer(minLength: 0)
            }
            .frame(width: Theme.posterWidth)
        }
    }

    /// Datum ("4 dec") of seizoen
    private func label(_ e: Entry) -> String? {
        guard let d = e.it.item.releaseDate, (e.it.item.date ?? "") > DiscoverItem.day(Date()) else { return nil }
        var s = d.formatted(.dateTime.day().month(.abbreviated).locale(Localizer.shared.locale))
        if s.hasSuffix(".") { s.removeLast() }
        if let n = e.it.season { s = L("S%d", n) + " · " + s }
        return s
    }

    private func flash(_ t: String) {
        withAnimation { toast = t }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { if toast == t { toast = nil } } }
    }

    private func load() async {
        let lib = playlists.library
        let pid = playlists.source?.id
        let key = "\(pid?.uuidString ?? "")-\(lib.movies.count)-\(lib.series.count)"
        let idx = await HomeIndexCache.shared.index(for: lib, version: playlists.libraryVersion)
        let matcher = await MatcherCache.shared.matcher(for: lib, key: key)
        let limited = store.activeProfile?.effectiveAgeLimit != nil
        func entries(_ items: [NewPopular176.Item]) async -> [Entry] {
            let m = await DiscoverStore.match(items.map(\.item), matcher: matcher, index: idx, onlyLibrary: false, limit: 60)
            var byID: [String: DetailTarget] = [:]
            for x in m { if let t = x.match { byID[x.item.id] = t } }
            return items.compactMap { it in
                let match = byID[it.item.id]
                // profiel met een leeftijdsgrens: alleen wat in de (gefilterde) bibliotheek staat
                if limited && match == nil { return nil }
                return Entry(it: it, match: match)
            }
        }
        let up = await DiscoverStore.shared.get(.upcoming, kids: kids).map { NewPopular176.Item(item: $0, season: nil) }
        upcoming = await entries(up)
        // series uit Mijn lijst en Verder kijken (TMDB-id van de bron)
        let seriesByID = Dictionary(lib.series.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids: [Int] = []
        for k in store.myList {
            guard let bar = k.firstIndex(of: "|") else { continue }
            if let s = seriesByID[String(k[k.index(after: bar)...])], let t = s.tmdbID { ids.append(t) }
        }
        let titles = Set(store.progress.values.map(\.title))
        for s in lib.series where titles.contains(s.title) { if let t = s.tmdbID { ids.append(t) } }
        seasons = await entries(await NewPopular176.shared.newSeasons(tmdbIDs: ids))
        popular = kids ? [] : await entries(await NewPopular176.shared.popular())
        loading = false
    }
}
