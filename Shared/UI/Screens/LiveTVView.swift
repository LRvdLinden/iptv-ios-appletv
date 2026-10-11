import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var group: String = Self.allKey
    @State private var mode: Mode = .list
    @State private var guideFor: Channel?
    @State private var program: ProgramTarget?
    @State private var filterText = ""

    enum Mode: String { case list, grid }
    struct ProgramTarget: Identifiable { var id: String { channel.id + p.id }; let channel: Channel; let p: EPGProgram }

    static let favKey = "★", recentKey = "◷", allKey = "*"
    private var lib: Library { playlists.library }
    private var pid: UUID { playlists.source?.id ?? UUID() }

    private var groups: [String] { [Self.allKey, Self.favKey, Self.recentKey] + lib.channelGroups }

    private func title(_ g: String) -> String {
        switch g {
        case Self.favKey: return "★ " + L("Favorites")
        case Self.recentKey: return "◷ " + L("Recent")
        case Self.allKey: return L("All channels")
        default: return g
        }
    }

    private var channels: [Channel] {
        var list: [Channel]
        switch group {
        case Self.favKey: list = lib.channels.filter { store.isFavorite(pid, $0.id) }
        case Self.recentKey:
            list = store.recentChannels.compactMap { k in lib.channels.first { store.key(pid, $0.id) == k } }
        case Self.allKey: list = lib.channels
        default: list = lib.channels.filter { $0.group == group }
        }
        return list
    }

    /// Zoeken gaat altijd door álle zenders (los van de gekozen groep): naam, nummer, groep en wat er nu speelt.
    private var searching: Bool { !query.isEmpty }
    private var query: String { filterText.trimmingCharacters(in: .whitespaces) }
    private var visibleChannels: [Channel] {
        guard searching else { return channels }
        let q = query
        let byName = lib.channels.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.number.map { "\($0)" == q } ?? false)
        }
        let nameIDs = Set(byName.map(\.id))
        let byOther = lib.channels.filter { c in
            !nameIDs.contains(c.id) && (c.group.localizedCaseInsensitiveContains(q)
                || (lib.nowPlaying(c)?.title.localizedCaseInsensitiveContains(q) ?? false))
        }
        return byName + byOther
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.black)
                .navigationTitle(L("Live TV"))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { withAnimation { mode = mode == .list ? .grid : .list } } label: {
                            Label(mode == .list ? L("TV guide") : L("List"),
                                  systemImage: mode == .list ? "calendar.day.timeline.left" : "list.bullet")
                        }
                        Button { app.openMultiview(start: Array(visibleChannels.prefix(1)), candidates: visibleChannels) } label: {
                            Label("Multiview", systemImage: "square.grid.2x2")
                        }
                        .disabled(lib.channels.isEmpty)
                    }
                }
        }
        .sheet(item: $guideFor) { c in GuideSheet(channel: c) }
        .sheet(item: $program) { t in ProgramSheet(channel: t.channel, program: t.p) }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 40) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        TextField(L("Search channel"), text: $filterText)
                            .font(.system(size: 26))
                    }
                    if searching {
                        Button { filterText = "" } label: {
                            Label(L("Clear search"), systemImage: "xmark.circle.fill")
                                .font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .plainTVButton()
                    }
                    Divider().padding(.vertical, 6)
                    ForEach(groups, id: \.self) { g in
                        Button { group = g; filterText = "" } label: {
                            HStack(spacing: 12) {
                                Capsule().fill(group == g && !searching ? Theme.red : .clear).frame(width: 5, height: 30)
                                Text(title(g)).font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(group == g ? .white : Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .plainTVButton()
                    }
                }.padding(.vertical, 20)
            }
            .frame(width: 420)
            channelArea
        }
        .padding(.horizontal, 60)
        #else
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups, id: \.self) { g in
                        Button { withAnimation { group = g; filterText = "" } } label: {
                            Text(title(g)).font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .foregroundStyle(group == g && !searching ? .black : .white)
                                .background(group == g && !searching ? Color.white : Theme.elevated, in: Capsule())
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            channelArea
        }
        .searchable(text: $filterText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search channel or program"))
        #endif
    }

    @ViewBuilder private var channelArea: some View {
        if mode == .grid {
            GuideGridView(channels: visibleChannels,
                          onPlay: { c in play(c) },
                          onProgram: { c, p in program = ProgramTarget(channel: c, p: p) })
        } else {
            channelList
        }
    }

    private func play(_ c: Channel) {
        store.pushRecentChannel(pid, c.id)
        app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: visibleChannels)
    }

    private var channelList: some View {
        let list = visibleChannels
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: tvScaled(2)) {
                if searching {
                    Text(L("%d channels for “%@”", list.count, query))
                        .font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, tvScaled(8)).padding(.top, tvScaled(6))
                }
                if list.isEmpty {
                    Text(searching ? L("No channels found.") :
                         group == Self.favKey ? L("No favorites yet. Hold a channel to add it.") : L("No channels."))
                        .foregroundStyle(Theme.secondary).padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                ForEach(list) { c in
                    Button { play(c) } label: {
                        ChannelRow(channel: c, now: lib.nowPlaying(c), next: lib.upcoming(c, count: 2).dropFirst().first,
                                   favorite: store.isFavorite(pid, c.id))
                    }
                    .plainTVButton()
                    .contextMenu {
                        Button { store.toggleFavorite(pid, c.id) } label: {
                            Label(store.isFavorite(pid, c.id) ? L("Remove from favorites") : L("Add to favorites"), systemImage: "star")
                        }
                        Button { guideFor = c } label: {
                            Label(c.catchupDays > 0 ? L("Guide & catch-up") : L("Guide"), systemImage: "list.bullet.rectangle")
                        }
                        Button { app.openMultiview(start: [c], candidates: list) } label: {
                            Label(L("Open in Multiview"), systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            .padding(.horizontal, tvScaled(8))
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let now: EPGProgram?
    let next: EPGProgram?
    let favorite: Bool

    var body: some View {
        HStack(spacing: tvScaled(12)) {
            if let n = channel.number {
                Text("\(n)").font(.system(size: tvScaled(12), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondary).frame(width: tvScaled(34), alignment: .trailing)
            }
            RemoteImage(url: channel.logo, contentMode: .fit, placeholder: String(channel.name.prefix(3)))
                .frame(width: tvScaled(64), height: tvScaled(40))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name).font(.system(size: tvScaled(15), weight: .semibold)).lineLimit(1)
                    if favorite { Image(systemName: "star.fill").font(.system(size: tvScaled(10))).foregroundStyle(Theme.imdb) }
                    if channel.catchupDays > 0 { Image(systemName: "clock.arrow.circlepath").font(.system(size: tvScaled(10))).foregroundStyle(Theme.secondary) }
                }
                if let now {
                    Text("\(now.start.formatted(date: .omitted, time: .shortened))  \(now.title)")
                        .font(.system(size: tvScaled(12))).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    ProgressBar(value: now.progress).frame(height: 2).frame(maxWidth: tvScaled(220))
                }
                if let next {
                    Text(L("Next %@  %@", next.start.formatted(date: .omitted, time: .shortened), next.title))
                        .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, tvScaled(8)).padding(.horizontal, tvScaled(8))
        .contentShape(Rectangle())
    }
}

/// EPG van één zender: kijken, terugkijken of herinnering zetten.
struct GuideSheet: View {
    let channel: Channel
    @EnvironmentObject var playlists: PlaylistService
    @State private var programs: [EPGProgram] = []
    @State private var selected: EPGProgram?

    var body: some View {
        NavigationStack {
            List {
                if programs.isEmpty { Text(L("No guide information")).foregroundStyle(Theme.secondary) }
                ForEach(programs) { p in
                    Button { selected = p } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.secondary)
                                if p.isNow { Text(L("NOW")).font(.caption2.bold()).foregroundStyle(Theme.red) }
                                if p.end < Date() && channel.catchupDays > 0 {
                                    Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(Theme.secondary)
                                }
                                if CloudStore.shared.hasReminder("\(channel.id)-\(Int(p.start.timeIntervalSince1970))") {
                                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(Theme.imdb)
                                }
                            }
                            Text(p.title).font(.headline)
                            if let d = p.description { Text(d).font(.caption).foregroundStyle(Theme.secondary).lineLimit(3) }
                        }
                    }
                }
            }
            .navigationTitle(channel.name)
            .task {
                let all = playlists.library.epg[channel.epgID ?? channel.id] ?? []
                let from = Date().addingTimeInterval(-Double(max(channel.catchupDays, 0)) * 86400)
                programs = all.isEmpty ? await playlists.shortEPG(channel) : all.filter { $0.end > from }
            }
            .sheet(item: $selected) { p in ProgramSheet(channel: channel, program: p) }
        }
    }
}
