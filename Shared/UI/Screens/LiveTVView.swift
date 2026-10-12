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
    @ObservedObject private var preview = ChannelPreview.shared
    /// Evenementzenders (één keer per lijst uitgelezen, op de achtergrond)
    @State private var events: [(channel: Channel, info: EventInfo)] = []
    @State private var collecting: CollectionTarget?
    @State private var offsetFor: Channel?

    enum Mode: String { case list, grid }
    struct ProgramTarget: Identifiable { var id: String { channel.id + p.id }; let channel: Channel; let p: EPGProgram }

    static let favKey = "★", recentKey = "◷", allKey = "*", eventsKey = "⚡", collectionPrefix = "▤"
    private var lib: Library { playlists.library }
    private var pid: UUID { playlists.source?.id ?? UUID() }

    private var groups: [String] {
        [Self.allKey, Self.favKey, Self.recentKey] + (events.isEmpty ? [] : [Self.eventsKey])
            + channelCollections.map { Self.collectionPrefix + $0.id } + lib.channelGroups
    }

    /// Collecties waar zenders in (kunnen) staan
    private var channelCollections: [BingrCollection] {
        store.activeCollections.filter { c in
            CollectionResolver.matchesSource(c, playlists.source?.id)
                && (c.kind == .smart ? c.allows(.channel) : c.items.contains { $0.type == .channel })
        }
    }

    private func collection(for g: String) -> BingrCollection? {
        guard g.hasPrefix(Self.collectionPrefix) else { return nil }
        return store.collection(String(g.dropFirst(Self.collectionPrefix.count)))
    }

    private func title(_ g: String) -> String {
        switch g {
        case Self.favKey: return "★ " + L("Favorites")
        case Self.recentKey: return "◷ " + L("Recent")
        case Self.allKey: return L("All channels")
        case Self.eventsKey: return "⚡ " + L("Events")
        default:
            if let c = collection(for: g) { return "▤ " + c.name }
            return g
        }
    }

    private var channels: [Channel] {
        var list: [Channel]
        switch group {
        case Self.favKey: list = lib.channels.filter { store.isFavorite(pid, $0.id) }
        case Self.recentKey:
            list = store.recentChannels.compactMap { k in lib.channels.first { store.key(pid, $0.id) == k } }
        case Self.allKey: list = lib.channels
        case Self.eventsKey: list = events.map { $0.channel }
        default:
            if let c = collection(for: group) {
                list = CollectionResolver.channels(c, lib: lib, source: playlists.source?.id)
            } else {
                list = lib.channels.filter { $0.group == group }
            }
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
        .sheet(item: $collecting) { AddToCollectionSheet(target: $0) }
        .sheet(item: $offsetFor) { CatchupOffsetSheet(channel: $0) }
        .task(id: playlists.libraryVersion) {
            let chans = lib.channels
            let found = await Task.detached(priority: .utility) { EventChannels.events(chans) }.value
            events = found
            if group == Self.eventsKey && found.isEmpty { group = Self.allKey }
        }
        .onChange(of: group) { _, _ in preview.stop() }
        .onDisappear { preview.stop() }
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
        #if os(macOS)
        .searchable(text: $filterText, placement: .toolbar, prompt: L("Search channel or program"))
        #else
        .searchable(text: $filterText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search channel or program"))
        #endif
        #endif
    }

    @ViewBuilder private var channelArea: some View {
        if mode == .grid {
            GuideGridView(channels: visibleChannels,
                          onPlay: { c in play(c) },
                          onProgram: { c, p in program = ProgramTarget(channel: c, p: p) },
                          onSelect: { c in preview.select(c, playlists: playlists) })
                .overlay(alignment: .bottomTrailing) { floatingPreview }
        } else {
            #if os(tvOS)
            HStack(alignment: .top, spacing: 40) {
                channelList
                if PlayerSettings.previewEnabled { previewPane.frame(width: 560) }
            }
            #else
            channelList.overlay(alignment: .bottomTrailing) { floatingPreview }
            #endif
        }
    }

    /// Apple TV: het voorbeeld naast de lijst, met wat er nu op is.
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChannelPreviewView(placeholder: nil)
            if let c = preview.channel {
                Text(c.name).font(.system(size: 30, weight: .bold)).lineLimit(1)
                if let now = lib.nowPlaying(c) {
                    Text("\(now.start.formatted(date: .omitted, time: .shortened))–\(now.end.formatted(date: .omitted, time: .shortened))  \(now.title)")
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    ProgressBar(value: now.progress).frame(height: 4).clipShape(Capsule())
                    if let d = now.description {
                        Text(d).font(.system(size: 20)).foregroundStyle(Theme.secondary).lineLimit(4)
                    }
                }
            } else {
                Text(L("Select a channel for a preview")).font(.system(size: 22)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }

    /// iPad/Mac (aanwijzer) en de tv-gids: een klein voorbeeld rechtsonder; tik = kijken.
    @ViewBuilder private var floatingPreview: some View {
        if let c = preview.channel, preview.floating {
            #if os(tvOS)
            ChannelPreviewView(placeholder: nil).frame(width: 480).padding(30)
                .shadow(color: .black.opacity(0.6), radius: 16)
            #else
            ZStack(alignment: .topTrailing) {
                Button { play(c) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ChannelPreviewView(placeholder: nil)
                        Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).padding(.horizontal, 4)
                    }
                    .padding(6)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                Button { preview.stop() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel(L("Close"))
            }
            .frame(width: 260)
            .padding(16)
            .shadow(color: .black.opacity(0.6), radius: 12)
            .transition(.opacity)
            #endif
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
                let eventInfo: [String: EventInfo] = group == Self.eventsKey && !searching
                    ? Dictionary(events.map { ($0.channel.id, $0.info) }, uniquingKeysWith: { a, _ in a }) : [:]
                ForEach(list) { c in
                    Button { play(c) } label: {
                        Group {
                            if let info = eventInfo[c.id] {
                                EventRow(channel: c, info: info)
                            } else {
                                ChannelRow(channel: c, now: lib.nowPlaying(c), next: lib.upcoming(c, count: 2).dropFirst().first,
                                           favorite: store.isFavorite(pid, c.id))
                            }
                        }
                        #if os(tvOS)
                        .background(FocusProbe { f in if f { preview.select(c, playlists: playlists) } })
                        #endif
                    }
                    .plainTVButton()
                    #if os(iOS)
                    .onHover { inside in if inside { preview.select(c, playlists: playlists) } }
                    .contextMenu { channelMenu(c, list: list) } preview: { ContextChannelPreview(channel: c, playlists: playlists) }
                    #elseif os(macOS)
                    .onHover { inside in if inside { preview.select(c, playlists: playlists) } }
                    .contextMenu { channelMenu(c, list: list) }
                    #else
                    .contextMenu { channelMenu(c, list: list) }
                    #endif
                }
            }
            .padding(.horizontal, tvScaled(8))
        }
    }

    @ViewBuilder private func channelMenu(_ c: Channel, list: [Channel]) -> some View {
        Button { store.toggleFavorite(pid, c.id) } label: {
            Label(store.isFavorite(pid, c.id) ? L("Remove from favorites") : L("Add to favorites"), systemImage: "star")
        }
        Button { guideFor = c } label: {
            Label(c.catchupDays > 0 ? L("Guide & catch-up") : L("Guide"), systemImage: "list.bullet.rectangle")
        }
        Button { collecting = .channel(c) } label: {
            Label(L("Add to collection…"), systemImage: "rectangle.stack.badge.plus")
        }
        if c.catchupDays > 0 {
            Button { offsetFor = c } label: {
                Label(L("Catch-up offset…"), systemImage: "clock.badge.questionmark")
            }
        }
        Button { app.openMultiview(start: [c], candidates: list) } label: {
            Label(L("Open in Multiview"), systemImage: "square.grid.2x2")
        }
    }
}

#if os(iOS)
/// iPhone/iPad: lang indrukken toont het menu met een live voorbeeld (zonder geluid).
private struct ContextChannelPreview: View {
    let channel: Channel
    /// Los meegegeven: het voorbeeld van een contextmenu krijgt de omgeving van het scherm niet altijd mee
    let playlists: PlaylistService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChannelPreviewView(placeholder: channel, cornerRadius: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.headline).lineLimit(1)
                if let now = playlists.library.nowPlaying(channel) {
                    Text(now.title).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 320)
        .background(Color(hex: 0x141414))
        .onAppear { ChannelPreview.shared.select(channel, playlists: playlists, delay: 0.3, floating: false) }
        .onDisappear { ChannelPreview.shared.stop() }
    }
}
#endif

/// Evenement: titel, begintijd in de lokale tijd en LIVE zodra het begonnen is.
private struct EventRow: View {
    let channel: Channel
    let info: EventInfo

    var body: some View {
        let live = info.isLive()
        HStack(spacing: tvScaled(12)) {
            RemoteImage(url: channel.logo, contentMode: .fit, placeholder: String(channel.name.prefix(3)))
                .frame(width: tvScaled(64), height: tvScaled(40))
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.system(size: tvScaled(15), weight: .bold)).lineLimit(2)
                HStack(spacing: 8) {
                    if live {
                        Text("LIVE").font(.system(size: tvScaled(10), weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.red, in: Capsule())
                    }
                    if let t = info.startText {
                        Label(t, systemImage: "calendar").font(.system(size: tvScaled(12), weight: .medium))
                            .foregroundStyle(live ? .white : Theme.secondary)
                    }
                    Text(channel.group).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(tvScaled(10))
        .background(live ? Color(hex: 0x2A1215) : Theme.card, in: RoundedRectangle(cornerRadius: tvScaled(10)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(10)).stroke(live ? Theme.red.opacity(0.6) : .clear, lineWidth: 1))
        .opacity(info.isExpired() ? 0.5 : 1)
        .padding(.vertical, tvScaled(2))
        .contentShape(Rectangle())
    }
}

/// Terugkijk-correctie per zender: −120…+120 minuten, gedeeld met al je apparaten (en Android).
struct CatchupOffsetSheet: View {
    let channel: Channel
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 0
    @State private var loaded = false

    var body: some View {
        VStack(spacing: tvScaled(18)) {
            Text(L("Catch-up offset")).font(.system(size: tvScaled(22), weight: .bold))
            Text(channel.name).foregroundStyle(Theme.secondary)
            Text(minutes == 0 ? L("No offset") : (minutes > 0 ? "+" : "−") + L("%d min", abs(minutes)))
                .font(.system(size: tvScaled(40), weight: .heavy).monospacedDigit())
            HStack(spacing: tvScaled(12)) {
                stepButton("−10", -10)
                stepButton("−1", -1)
                stepButton("+1", 1)
                stepButton("+10", 10)
            }
            Text(L("Shifts the start time of catch-up for this channel, for when programs start too early or too late."))
                .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            HStack(spacing: tvScaled(14)) {
                NetflixButton(title: L("Reset"), icon: "arrow.counterclockwise", kind: .secondary) { minutes = 0 }
                NetflixButton(title: L("Save"), icon: "checkmark", kind: .accent) {
                    if let pid = playlists.source?.id { store.setCatchupOffset(pid, channel.id, minutes) }
                    dismiss()
                }
            }
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #if !os(tvOS)
        .presentationDetents([.medium])
        #endif
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let pid = playlists.source?.id { minutes = store.catchupOffset(pid, channel.id) }
        }
    }

    private func stepButton(_ title: String, _ step: Int) -> some View {
        Button { minutes = min(max(minutes + step, -120), 120) } label: {
            Text(title).font(.system(size: tvScaled(16), weight: .bold).monospacedDigit())
                .frame(minWidth: tvScaled(56)).padding(.vertical, tvScaled(10))
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: tvScaled(8)))
        }
        .plainTVButton()
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
