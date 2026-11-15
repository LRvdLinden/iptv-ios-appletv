import SwiftUI

// Build 173: panelen in de speler die onderin over het beeld openen en niet pauzeren (zoals Netflix):
// Audio en ondertitels (A), Zappen (3), Afleveringen (5), de vraag Vanaf het begin / Live kijken (2) en
// "Slaaptimer: gestopt" (9). De regels staan in Build173Player.swift.

/// Gemeenschappelijke vorm: onderin, donker, met titel en sluitknop.
struct BottomPanel173<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            HStack {
                Text(title).font(.system(size: tvScaled(17), weight: .bold))
                Spacer()
                #if !os(tvOS)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).padding(8)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close"))
                #endif
            }
            content()
        }
        .foregroundStyle(.white)
        .padding(tvScaled(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Keuzeregel met vinkje (werkt met aanraken, muis en de focus van de Apple TV).
struct PanelChoice173: View {
    let title: String
    var selected = false
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).frame(width: tvScaled(18)) }
                Text(title).font(.system(size: tvScaled(14), weight: selected ? .bold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: tvScaled(12), weight: .bold)).foregroundStyle(Theme.red) }
            }
            .padding(.horizontal, tvScaled(10)).padding(.vertical, tvScaled(7))
            .frame(minWidth: tvScaled(180), alignment: .leading)
            .background(selected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: tvScaled(8)))
            .contentShape(Rectangle())
        }
        .plainTVButton()
    }
}

// MARK: - A. Audio en ondertitels

struct AudioSubsPanel173: View {
    @ObservedObject var player: PlayerController
    var versions: [LanguageVersion] = []
    let onSwitch: (LanguageVersion) -> Void
    let onOpenSubtitles: () -> Void
    let onClose: () -> Void
    @State private var size = SubtitleSize.current

    var body: some View {
        BottomPanel173(title: L("Audio & subtitles"), onClose: onClose) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: tvScaled(26)) {
                    column(L("Audio")) {
                        let tracks = player.audioTracks
                        if tracks.isEmpty {
                            Text(L("No alternative audio tracks")).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                        }
                        ForEach(tracks) { t in
                            PanelChoice173(title: TracksPanel.flagged(t), selected: t.id == player.currentAudio) { player.selectAudio(t) }
                        }
                        if !player.isLive {
                            ForEach(versions) { v in
                                PanelChoice173(title: "\(v.name) · \(v.label)", icon: "globe") { onSwitch(v) }
                            }
                        }
                    }
                    column(L("Subtitles")) {
                        PanelChoice173(title: L("Off"), selected: player.currentSubtitle == nil && !player.hasExternalSubtitle) {
                            player.selectSubtitle(nil)
                        }
                        if let ext = player.externalSubtitleName, player.hasExternalSubtitle {
                            PanelChoice173(title: "OpenSubtitles · \(ext)", selected: true) {}
                        }
                        ForEach(player.subtitleTracks) { t in
                            PanelChoice173(title: TracksPanel.flagged(t), selected: t.id == player.currentSubtitle && !player.hasExternalSubtitle) {
                                player.selectSubtitle(t)
                            }
                        }
                        if !player.isLive {
                            PanelChoice173(title: L("Search OpenSubtitles…"), icon: "captions.bubble", action: onOpenSubtitles)
                        }
                    }
                    column(L("Subtitle display")) {
                        ForEach(SubtitleSize.allCases, id: \.self) { sz in
                            PanelChoice173(title: sz.title, selected: size == sz) {
                                UserDefaults.standard.set(sz.rawValue, forKey: SubtitleSize.key)
                                size = sz
                                player.applySubtitleSize()
                            }
                        }
                        HStack(spacing: tvScaled(12)) {
                            Button { player.subtitleDelay -= 0.5 } label: { Image(systemName: "minus.circle.fill") }
                                .plainTVButton().accessibilityLabel(L("Earlier"))
                            Text(player.subtitleDelay == 0 ? L("In sync") : String(format: "%+.1f s", player.subtitleDelay))
                                .font(.system(size: tvScaled(13)).monospacedDigit())
                            Button { player.subtitleDelay += 0.5 } label: { Image(systemName: "plus.circle.fill") }
                                .plainTVButton().accessibilityLabel(L("Later"))
                        }
                        .font(.system(size: tvScaled(20)))
                        .padding(.horizontal, tvScaled(10)).padding(.top, tvScaled(4))
                    }
                }
                .padding(.vertical, tvScaled(4))
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(2)) {
            Text(title.uppercased()).font(.system(size: tvScaled(11), weight: .heavy)).tracking(0.8).foregroundStyle(Theme.secondary)
                .padding(.horizontal, tvScaled(10)).padding(.bottom, tvScaled(4))
            content()
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

// MARK: - 3. Zappen als lijst

struct ZapPanel173: View {
    let channels: [Channel]
    let currentID: String?
    let nowPlaying: (Channel) -> EPGProgram?
    let onPick: (Channel) -> Void
    let onClose: () -> Void

    var body: some View {
        BottomPanel173(title: L("Zap"), onClose: onClose) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: tvScaled(12)) {
                        ForEach(channels) { c in
                            Button { onPick(c) } label: { card(c) }
                                #if os(tvOS)
                                .buttonStyle(TVLiftStyle(scale: 1.06))
                                #else
                                .plainTVButton()
                                #endif
                                .id(c.id)
                        }
                    }
                    .padding(.vertical, tvScaled(6))
                }
                .onAppear { if let id = currentID { proxy.scrollTo(id, anchor: .center) } }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func card(_ c: Channel) -> some View {
        let now = nowPlaying(c)
        let on = c.id == currentID
        return VStack(alignment: .leading, spacing: tvScaled(6)) {
            HStack(spacing: tvScaled(8)) {
                RemoteImage(url: c.logo, contentMode: .fit, placeholder: String(c.name.prefix(3)))
                    .frame(width: tvScaled(44), height: tvScaled(28))
                Text(c.name).font(.system(size: tvScaled(13), weight: .bold)).lineLimit(1)
            }
            Text(now.map { CategoryName.display($0.title) } ?? c.group)
                .font(.system(size: tvScaled(12))).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let now { ProgressBar(value: now.progress).frame(height: 3).clipShape(Capsule()) }
        }
        .padding(tvScaled(10))
        .frame(width: tvScaled(190), height: tvScaled(104), alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: tvScaled(10)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(10)).stroke(on ? Theme.red : .white.opacity(0.1), lineWidth: on ? 2 : 1))
    }
}

// MARK: - 5. Afleveringen in de speler

struct EpisodesPanel173: View {
    let series: Series
    let episodes: [Episode]
    let currentID: String
    let onPick: (Episode) -> Void
    let onClose: () -> Void
    @State private var season: Int?
    @ObservedObject private var store = CloudStore.shared

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var shownSeason: Int { season ?? episodes.first { $0.id == currentID }?.season ?? seasons.first ?? 1 }

    var body: some View {
        BottomPanel173(title: L("Episodes"), onClose: onClose) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: tvScaled(8)) {
                        ForEach(seasons, id: \.self) { s in
                            PanelChoice173(title: L("Season %d", s), selected: s == shownSeason) { season = s }
                                .fixedSize()
                        }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: tvScaled(12)) {
                        ForEach(episodes.filter { $0.season == shownSeason }) { e in
                            Button { onPick(e) } label: { card(e) }
                                #if os(tvOS)
                                .buttonStyle(TVLiftStyle(scale: 1.06))
                                #else
                                .plainTVButton()
                                #endif
                                .id(e.id)
                        }
                    }
                    .padding(.vertical, tvScaled(6))
                }
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func card(_ e: Episode) -> some View {
        let f = min(max(store.progress[e.id]?.fraction ?? 0, 0), 1)
        let on = e.id == currentID
        return VStack(alignment: .leading, spacing: tvScaled(5)) {
            RemoteImage(url: e.still ?? series.poster, placeholder: "")
                .frame(width: tvScaled(200), height: tvScaled(112))
                .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
                .overlay(alignment: .bottom) {
                    if f > 0.01 {
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                                .overlay(alignment: .leading) { Capsule().fill(Theme.red).frame(width: g.size.width * f, height: 4) }
                        }
                        .frame(height: 4).padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: tvScaled(8)).stroke(on ? Theme.red : .clear, lineWidth: 2))
            Text("\(e.number). \(Playables.cleanEpisodeTitle(e))").font(.system(size: tvScaled(13), weight: on ? .bold : .semibold))
                .lineLimit(1).frame(width: tvScaled(200), alignment: .leading)
        }
    }
}

// MARK: - 2. Vanaf het begin of Live kijken

struct StartOverPrompt173: View {
    let program: EPGProgram
    let onStartOver: () -> Void
    let onLive: () -> Void
    #if os(tvOS)
    @FocusState private var focus: Int?
    #endif

    var body: some View {
        VStack(spacing: tvScaled(14)) {
            Text(L("This programme has already started")).font(.system(size: tvScaled(17), weight: .bold))
            Text(CategoryName.display(program.title)).font(.system(size: tvScaled(14))).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            HStack(spacing: tvScaled(12)) {
                NetflixButton(title: L("From the start"), icon: "backward.end.fill", kind: .play, action: onStartOver)
                    #if os(tvOS)
                    .focused($focus, equals: 0)
                    #endif
                NetflixButton(title: L("Watch live"), icon: "dot.radiowaves.left.and.right", kind: .secondary, action: onLive)
                    #if os(tvOS)
                    .focused($focus, equals: 1)
                    #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .foregroundStyle(.white)
        .padding(tvScaled(22))
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: tvScaled(16)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(16)).stroke(.white.opacity(0.12)))
        .padding(Theme.edge)
        #if os(tvOS)
        .onAppear { DispatchQueue.main.async { focus = 0 } }
        #endif
    }
}

// MARK: - 9. Slaaptimer gestopt

struct SleepStopped173: View {
    let onContinue: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: tvScaled(16)) {
                Image(systemName: "moon.zzz.fill").font(.system(size: tvScaled(40))).foregroundStyle(Theme.secondary)
                Text(L("Sleep timer: stopped")).font(.system(size: tvScaled(22), weight: .bold))
                HStack(spacing: tvScaled(12)) {
                    NetflixButton(title: L("Continue watching"), icon: "play.fill", kind: .play, action: onContinue)
                    #if !os(tvOS)
                    NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary, action: onClose)
                    #endif
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .foregroundStyle(.white)
        }
        .transition(.opacity)
    }
}

/// Keuze van de slaaptimer met het aftellen (Opties in de speler)
struct SleepTimerSection173: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        Section {
            if let at = player.sleepAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Label(L("Stops in %@", Player173.countdown(at.timeIntervalSince(ctx.date))), systemImage: "moon.zzz.fill")
                        .monospacedDigit().foregroundStyle(Theme.secondary)
                }
            } else if player.sleep == .endOfEpisode {
                Label(player.isLive ? L("Stops after this programme") : L("Stops after this episode"), systemImage: "moon.zzz.fill")
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(Player173.Sleep.choices, id: \.code) { s in
                Button {
                    player.setSleep(s, programEnd: player.sleepProgramEndProvider?())
                } label: {
                    HStack {
                        Text(Self.title(s, live: player.isLive)); Spacer()
                        if player.sleep == s { Image(systemName: "checkmark").foregroundStyle(Theme.red) }
                    }
                }
            }
        } header: { Text(L("Sleep timer")) }
    }

    static func title(_ s: Player173.Sleep, live: Bool) -> String {
        switch s {
        case .off: return L("Off")
        case .endOfEpisode: return live ? L("After this programme") : L("After this episode")
        case .minutes(let m): return L("%d minutes", m)
        }
    }
}
