import SwiftUI

/// TV-gids als raster: zenders verticaal, tijd horizontaal, rode "nu"-lijn.
struct GuideGridView: View {
    /// Alle zenders van de gekozen groep; het raster toont er maximaal `limit` (anders wordt het op Apple TV te zwaar).
    let channels: [Channel]
    private static let limit = 150
    private var shown: [Channel] { Array(channels.prefix(Self.limit)) }
    var onPlay: (Channel) -> Void
    var onProgram: (Channel, EPGProgram) -> Void
    /// Zender geselecteerd (focus of aanwijzer): voor het voorbeeld
    var onSelect: ((Channel) -> Void)? = nil

    @EnvironmentObject var playlists: PlaylistService
    @State private var now = Date()

    private var pxPerMinute: CGFloat { tvScaled(5) }
    private var rowHeight: CGFloat { tvScaled(62) }
    private var channelWidth: CGFloat { tvScaled(130) }
    private var start: Date {
        let cal = Calendar.current
        let d = now.addingTimeInterval(-3600)
        let m = cal.component(.minute, from: d)
        return cal.date(byAdding: .minute, value: -(m % 30), to: d)?.zeroSeconds ?? d
    }
    /// 1 uur terug t/m ruim 12 uur vooruit (meer knoppen maakt het raster traag)
    private var hours: Double { 14 }
    private var totalWidth: CGFloat { CGFloat(hours * 60) * pxPerMinute }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // vaste zenderkolom
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: tvScaled(30))
                    ForEach(shown) { c in
                        Button { onPlay(c) } label: {
                            HStack(spacing: 8) {
                                RemoteImage(url: c.logo, contentMode: .fit, placeholder: String(c.name.prefix(3)))
                                    .frame(width: tvScaled(40), height: tvScaled(26))
                                Text(c.name).font(.system(size: tvScaled(11), weight: .semibold)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6)
                            .frame(width: channelWidth, height: rowHeight)
                            .background(Theme.card)
                            #if os(tvOS)
                            .background(FocusProbe { f in if f { onSelect?(c) } })
                            #endif
                        }
                        .plainTVButton()
                        #if !os(tvOS)
                        .onHover { inside in if inside { onSelect?(c) } }
                        #endif
                        .overlay(Rectangle().fill(Color.black).frame(height: 1), alignment: .bottom)
                    }
                }
                .zIndex(1)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                timeline
                                ForEach(shown) { c in row(c) }
                            }
                            // "nu"-lijn
                            Rectangle().fill(Theme.red).frame(width: 2)
                                .frame(height: tvScaled(30) + rowHeight * CGFloat(shown.count))
                                .offset(x: x(now))
                                .allowsHitTesting(false)
                            Color.clear.frame(width: 1, height: 1).offset(x: max(0, x(now) - tvScaled(120))).id("now")
                        }
                        .frame(width: totalWidth, alignment: .leading)
                    }
                    .onAppear { proxy.scrollTo("now", anchor: .leading) }
                }
            }
            if channels.count > Self.limit {
                Text(L("Showing %d of %d channels. Choose a group or search to see the rest.", Self.limit, channels.count))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(tvScaled(16))
            }
        }
        .background(Color.black)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                now = Date()
            }
        }
    }

    private var timeline: some View {
        ZStack(alignment: .leading) {
            ForEach(0..<Int(hours * 2), id: \.self) { i in
                let t = start.addingTimeInterval(Double(i) * 1800)
                Text(t.formatted(date: i == 0 || Calendar.current.component(.hour, from: t) == 0 ? .abbreviated : .omitted,
                                 time: .shortened))
                    .font(.system(size: tvScaled(11), weight: .semibold)).foregroundStyle(Theme.secondary)
                    .offset(x: x(t) + 4)
            }
        }
        .frame(width: totalWidth, height: tvScaled(30), alignment: .leading)
    }

    private func row(_ c: Channel) -> some View {
        let end = start.addingTimeInterval(hours * 3600)
        // programma's per zender staan op begintijd: binair zoeken naar het zichtbare stuk (build 56)
        let progs = playlists.library.programs(c, from: start, to: end)
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color(hex: 0x101010))
            if progs.isEmpty {
                Text(L("No guide information")).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                    .padding(.leading, x(now) + 8)
            }
            ForEach(progs) { p in
                let x0 = max(x(p.start), 0), x1 = min(x(p.end), totalWidth)
                if x1 > x0 + 2 {
                    Button { onProgram(c, p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.system(size: tvScaled(12), weight: .semibold)).lineLimit(1)
                            Text("\(TimeText.short(p.start)) – \(TimeText.short(p.end))")
                                .font(.system(size: tvScaled(10))).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: x1 - x0 - 2, height: rowHeight - 4, alignment: .leading)
                        .background(p.isNow ? Color(hex: 0x3A1418) : Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .topTrailing) {
                            if CloudStore.shared.hasReminder("\(c.id)-\(Int(p.start.timeIntervalSince1970))") {
                                Image(systemName: "bell.fill").font(.system(size: tvScaled(9))).foregroundStyle(Theme.imdb).padding(4)
                            }
                        }
                        #if os(tvOS)
                        .background(FocusProbe { f in if f { onSelect?(c) } })
                        #endif
                    }
                    .plainTVButton()
                    .offset(x: x0 + 1)
                }
            }
        }
        .frame(width: totalWidth, height: rowHeight, alignment: .leading)
    }

    private func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / 60) * pxPerMinute }
}

private extension Date {
    var zeroSeconds: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: self)) ?? self
    }
}

/// Details van een programma: kijken, terugkijken of herinnering zetten.
struct ProgramSheet: View {
    let channel: Channel
    let program: EPGProgram
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var editOffset = false

    private var reminderID: String { "\(channel.id)-\(Int(program.start.timeIntervalSince1970))" }
    private var canCatchup: Bool {
        program.end < Date() && channel.catchupDays > 0
            && program.start > Date().addingTimeInterval(-Double(channel.catchupDays) * 86400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(14)) {
            Text(channel.name).font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(program.title).font(.system(size: tvScaled(24), weight: .bold))
            HStack(spacing: tvScaled(10)) {
                Text("\(program.start.formatted(date: .abbreviated, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(Theme.secondary)
                if channel.catchupDays > 0, let pid = playlists.source?.id {
                    let off = store.catchupOffset(pid, channel.id)
                    Button { editOffset = true } label: {
                        Label(off == 0 ? L("Catch-up offset") : L("Offset %@ min", (off > 0 ? "+" : "−") + "\(abs(off))"),
                              systemImage: "clock.badge.questionmark")
                            .font(.system(size: tvScaled(12), weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .plainTVButton()
                }
            }
            if let d = program.description { Text(d).font(.system(size: tvScaled(14))).foregroundStyle(.white.opacity(0.85)) }
            HStack(spacing: tvScaled(14)) {
                if program.isNow {
                    NetflixButton(title: L("Watch live"), icon: "play.fill", kind: .play) {
                        dismiss(); app.play(Playables.channel(channel, now: program), zap: playlists.library.channels)
                    }
                } else if canCatchup, let u = playlists.catchupURL(channel, program) {
                    NetflixButton(title: L("Watch from the start"), icon: "clock.arrow.circlepath", kind: .play) {
                        dismiss()
                        app.play(PlayableItem(id: "\(channel.id)-cu-\(Int(program.start.timeIntervalSince1970))", title: program.title,
                                              subtitle: channel.name, url: u, type: .movie, artwork: channel.logo))
                    }
                } else if program.start > Date() {
                    let on = store.hasReminder(reminderID)
                    NetflixButton(title: on ? L("Reminder set") : L("Remind me"), icon: on ? "bell.slash" : "bell", kind: on ? .secondary : .primary) {
                        if on { ReminderCenter.shared.remove(reminderID) }
                        else if let pid = playlists.source?.id {
                            Task { await ReminderCenter.shared.add(channel: channel, program: program, playlist: pid) }
                        }
                    }
                }
                if program.isNow, channel.catchupDays > 0, let u = playlists.catchupURL(channel, program) {
                    NetflixButton(title: L("From the start"), icon: "backward.end.fill", kind: .secondary) {
                        dismiss()
                        app.play(PlayableItem(id: "\(channel.id)-cu-\(Int(program.start.timeIntervalSince1970))", title: program.title,
                                              subtitle: channel.name, url: u, type: .movie, artwork: channel.logo))
                    }
                }
            }
            Spacer()
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #if !os(tvOS)
        .presentationDetents([.medium])
        #endif
        .sheet(isPresented: $editOffset) { CatchupOffsetSheet(channel: channel) }
    }
}
