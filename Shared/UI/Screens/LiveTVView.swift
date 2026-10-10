import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var group: String = "★ Favorieten"
    @State private var guideFor: Channel?
    @State private var filterText = ""

    private let favKey = "★ Favorieten", recentKey = "◷ Recent", allKey = "Alle zenders"
    private var lib: Library { playlists.library }
    private var pid: UUID { playlists.source?.id ?? UUID() }

    private var groups: [String] { [favKey, recentKey, allKey] + lib.channelGroups }

    private var channels: [Channel] {
        var list: [Channel]
        switch group {
        case favKey: list = lib.channels.filter { store.isFavorite(pid, $0.id) }
        case recentKey:
            let keys = store.recentChannels
            list = keys.compactMap { k in lib.channels.first { store.key(pid, $0.id) == k } }
        case allKey: list = lib.channels
        default: list = lib.channels.filter { $0.group == group }
        }
        if !filterText.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filterText) } }
        return list
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.black)
                .navigationTitle("Live TV")
                .onAppear {
                    if group == favKey && lib.channels.allSatisfy({ !store.isFavorite(pid, $0.id) }) {
                        group = lib.channelGroups.first ?? allKey
                    }
                }
        }
        .sheet(item: $guideFor) { c in GuideSheet(channel: c) }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 40) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.self) { g in
                        Button { group = g } label: {
                            Text(g).font(.system(size: 26, weight: group == g ? .bold : .regular))
                                .foregroundStyle(group == g ? .white : Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.vertical, 20)
            }
            .frame(width: 420)
            channelList
        }
        .padding(.horizontal, 60)
        #else
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups, id: \.self) { g in
                        Button { withAnimation { group = g } } label: {
                            Text(g).font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .foregroundStyle(group == g ? .black : .white)
                                .background(group == g ? Color.white : Theme.elevated, in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: group == g ? 0 : 1))
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            channelList
        }
        .searchable(text: $filterText, prompt: "Zender zoeken")
        #endif
    }

    private var channelList: some View {
        let list = channels
        return ScrollView {
            LazyVStack(spacing: tvScaled(2)) {
                if list.isEmpty {
                    Text(group == favKey ? "Nog geen favorieten. Houd een zender ingedrukt om hem toe te voegen." : "Geen zenders.")
                        .foregroundStyle(Theme.secondary).padding(.top, 40)
                }
                ForEach(list) { c in
                    Button {
                        store.pushRecentChannel(pid, c.id)
                        app.play(Playables.channel(c, now: lib.nowPlaying(c)), zap: list)
                    } label: { ChannelRow(channel: c, now: lib.nowPlaying(c), next: lib.upcoming(c, count: 2).dropFirst().first,
                                          favorite: store.isFavorite(pid, c.id)) }
                    .plainTVButton()
                    .contextMenu {
                        Button { store.toggleFavorite(pid, c.id) } label: {
                            Label(store.isFavorite(pid, c.id) ? "Verwijder uit favorieten" : "Voeg toe aan favorieten", systemImage: "star")
                        }
                        Button { guideFor = c } label: { Label(c.catchupDays > 0 ? "Gids & terugkijken" : "Gids", systemImage: "list.bullet.rectangle") }
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
                    Text("Straks \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)")
                        .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, tvScaled(8)).padding(.horizontal, tvScaled(8))
        .contentShape(Rectangle())
    }
}

/// EPG van één zender, met terugkijken (Xtream catch-up).
struct GuideSheet: View {
    let channel: Channel
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [EPGProgram] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(programs) { p in
                    let past = p.end < Date()
                    let canCatchup = past && channel.catchupDays > 0 && p.start > Date().addingTimeInterval(-Double(channel.catchupDays) * 86400)
                    Button {
                        if p.isNow { dismiss(); app.play(Playables.channel(channel, now: p)) }
                        else if canCatchup, let u = playlists.catchupURL(channel, p) {
                            dismiss()
                            app.play(PlayableItem(id: "\(channel.id)-cu-\(Int(p.start.timeIntervalSince1970))", title: p.title,
                                                  subtitle: channel.name, url: u, type: .live, artwork: channel.logo))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.secondary)
                                if p.isNow { Text("NU").font(.caption2.bold()).foregroundStyle(Theme.red) }
                                if canCatchup { Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(Theme.secondary) }
                            }
                            Text(p.title).font(.headline).foregroundStyle(past && !canCatchup ? Theme.secondary : .white)
                            if let d = p.description { Text(d).font(.caption).foregroundStyle(Theme.secondary).lineLimit(3) }
                        }
                    }
                }
            }
            .navigationTitle(channel.name)
            .task {
                let all = playlists.library.epg[channel.epgID ?? channel.id] ?? []
                if all.isEmpty { programs = await playlists.shortEPG(channel) } else { programs = all }
            }
        }
    }
}
