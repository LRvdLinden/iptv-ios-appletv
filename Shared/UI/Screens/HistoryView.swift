import SwiftUI

/// Kijkgeschiedenis van het huidige profiel: films, afleveringen en zenders, per dag.
struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var detail: DetailTarget?
    @State private var confirmClear = false
    /// Build 128: geschiedenis van alle servers
    @ObservedObject private var cross = CrossServer.shared
    @State private var prompt: CrossServer.Prompt?

    private var pid: UUID? { playlists.source?.id }
    private var entries: [HistoryEntry] { store.history.filter { store.belongsToActive($0.profileID) } }

    private var days: [(day: Date, items: [HistoryEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text(L("Nothing watched yet on this profile."))
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(days, id: \.day) { d in
                Section(dayTitle(d.day)) {
                    ForEach(d.items) { e in
                        Button { open(e) } label: { row(e) }
                            .contextMenu {
                                Button(role: .destructive) { store.removeHistory(e) } label: {
                                    Label(L("Remove from history"), systemImage: "trash")
                                }
                            }
                            #if !os(tvOS)
                            .swipeActions {
                                Button(role: .destructive) { store.removeHistory(e) } label: { Label(L("Remove"), systemImage: "trash") }
                            }
                            #endif
                    }
                }
            }
            if !entries.isEmpty {
                Section {
                    Button(L("Clear watch history"), role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle(L("Watch history"))
        .crossServerPrompt($prompt)
        .confirmationDialog(L("Clear watch history"), isPresented: $confirmClear) {
            Button(L("Clear watch history"), role: .destructive) {
                for p in Set(entries.map(\.playlistID)) { store.clearHistory(playlist: p) }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
    }

    private func row(_ e: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: e.artwork, contentMode: e.type == .live ? .fit : .fill, placeholder: String(e.title.prefix(2)))
                .frame(width: tvScaled(e.type == .live ? 56 : 40), height: tvScaled(e.type == .live ? 36 : 60))
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.system(size: tvScaled(15), weight: .semibold)).lineLimit(1)
                if let s = e.subtitle { Text(s).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Image(systemName: icon(e.type)).foregroundStyle(Theme.secondary)
                Text(e.date.formatted(date: .omitted, time: .shortened)).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func icon(_ t: MediaType) -> String {
        switch t { case .live: return "dot.radiowaves.left.and.right"; case .movie: return "film"; default: return "rectangle.stack" }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L("Today") }
        if cal.isDateInYesterday(d) { return L("Yesterday") }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func open(_ e: HistoryEntry) {
        // build 128: van een andere server: via die server (nog niet gevonden → zoeken, anders de melding)
        if let other = e.playlistID, other != pid {
            let key = other.uuidString + "|" + e.itemID
            if e.type == .live, let c = cross.channel(forKey: key) {
                CrossServerOpen.channel(c, list: .history, onChannel: { app.play(Playables.channel($0, now: nil), zap: [$0]) },
                                        onPrompt: { prompt = $0 })
            } else if let m = cross.movie(forKey: key) {
                CrossServerOpen.title(.movie(m), list: .history, onTarget: { detail = $0 }, onPrompt: { prompt = $0 })
            } else if let s = cross.series(forKey: key) ?? cross.episodeSeries(playlist: other, key: e.itemID) {
                CrossServerOpen.title(.series(s), list: .history, onTarget: { detail = $0 }, onPrompt: { prompt = $0 })
            } else {
                Task { @MainActor in
                    switch await CrossServerOpen.open(key: key, list: .history) {
                    case .movie(let m): detail = .movie(m)
                    case .series(let s): detail = .series(s)
                    case .channel(let c): app.play(Playables.channel(c, now: nil), zap: [c])
                    case .prompt(let p): prompt = p
                    }
                }
            }
            return
        }
        let lib = playlists.library
        if e.type == .live, let c = lib.channels.first(where: { $0.id == (e.channelID ?? e.itemID) }) {
            app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: lib.channels)
        } else if let m = lib.movies.first(where: { $0.id == e.itemID }) {
            detail = .movie(m)
        } else if let s = lib.series.first(where: { $0.id == e.itemID || $0.episodes.contains { $0.id == e.itemID } })
                    ?? lib.series.first(where: { $0.title == e.title }) {
            detail = .series(s)
        }
    }
}
