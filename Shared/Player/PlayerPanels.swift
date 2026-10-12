import SwiftUI

/// Audio- en ondertitelsporen die in de stream zitten.
struct TracksPanel: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L("Audio")) {
                    if player.audioTracks.isEmpty { Text(L("No alternative audio tracks")).foregroundStyle(Theme.secondary) }
                    ForEach(player.audioTracks) { t in
                        row(Self.flagged(t), selected: t.id == player.currentAudio) { player.selectAudio(t) }
                    }
                }
                Section(L("Subtitles")) {
                    row(L("Off"), selected: player.currentSubtitle == nil) { player.selectSubtitle(nil) }
                    if let ext = player.externalSubtitleName, player.hasExternalSubtitle {
                        row("OpenSubtitles · \(ext)", selected: true) {}
                    }
                    ForEach(player.subtitleTracks) { t in
                        row(Self.flagged(t), selected: t.id == player.currentSubtitle) { player.selectSubtitle(t) }
                    }
                }
                Section {
                    HStack {
                        Button { player.subtitleDelay -= 0.5 } label: { Image(systemName: "minus.circle.fill") }
                        Spacer()
                        Text(player.subtitleDelay == 0 ? L("In sync") : String(format: "%+.1f s", player.subtitleDelay))
                            .monospacedDigit()
                        Spacer()
                        Button { player.subtitleDelay += 0.5 } label: { Image(systemName: "plus.circle.fill") }
                    }
                    .font(.system(size: tvScaled(20)))
                    #if !os(tvOS)
                    .buttonStyle(.borderless)
                    #endif
                    if player.subtitleDelay != 0 { Button(L("Reset")) { player.subtitleDelay = 0 } }
                } header: { Text(L("Subtitle timing")) } footer: {
                    Text(L("Subtitles too early or too late? Shift them in steps of half a second."))
                }
            }
            .navigationTitle(L("Audio & subtitles"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }

    /// Spoornaam met vlag als de taal herkend wordt.
    static func flagged(_ t: MediaTrack) -> String {
        if let l = t.lang, !l.isEmpty { return "\(TrackPreferences.flag(l)) \(t.name)" }
        if let code = TrackPreferences.languages.map(\.code).first(where: { TrackPreferences.matches(t, code: $0) }) {
            return "\(TrackPreferences.flag(code)) \(t.name)"
        }
        return t.name
    }

    private func row(_ name: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(name); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(Theme.red) } }
        }
    }
}

/// Ondertitels zoeken en inladen via OpenSubtitles (op IMDb-ID of titel, met seizoen/aflevering).
/// Taal kies je hier per keer; de standaardtaal stel je in onder Mijn Bingr → OpenSubtitles.
struct OpenSubtitlesPanel: View {
    @ObservedObject var player: PlayerController
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss
    @State private var results: [OpenSubtitles.Subtitle] = []
    @State private var loading = true
    @State private var error: String?
    @State private var downloading: Int?
    @State private var language: String = OpenSubtitles.shared.defaultLanguage
    @State private var showLogin = false
    /// App-sleutels van de server: opnieuw tekenen zodra ze binnen zijn (dan gewoon inloggen)
    @ObservedObject private var account = AccountService.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(L("Language"), selection: $language) {
                        Text(L("All languages")).tag("")
                        ForEach(TrackPreferences.sortedCodes, id: \.self) { Text(TrackPreferences.label($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if !subs.isLoggedIn {
                        Button { showLogin = true } label: {
                            Label(L("Sign in to OpenSubtitles to download"), systemImage: "person.crop.circle.badge.checkmark")
                        }
                    } else if let r = subs.remainingDownloads {
                        LabeledContent(L("Downloads left today"), value: "\(r)")
                    }
                }
                Section {
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).foregroundStyle(Theme.secondary) }
                    ForEach(results) { s in
                        Button { load(s) } label: { row(s) }
                            .disabled(downloading != nil)
                    }
                }
            }
            .navigationTitle("OpenSubtitles")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { dismiss() } } }
            .task(id: language) { await search() }
            .task { await subs.refreshUser() }
            .task { if !Secrets.openSubtitlesReady { await account.fetchConfig(force: false) } }
            .sheet(isPresented: $showLogin) {
                if Secrets.openSubtitlesReady { OpenSubtitlesLoginView() } else { ConnectionsSetupView(focus: .openSubtitles) }
            }
        }
    }

    private func row(_ s: OpenSubtitles.Subtitle) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(TrackPreferences.flag(s.language)).font(.system(size: tvScaled(24)))
                Text(s.language.uppercased()).font(.system(size: tvScaled(9), weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .frame(minWidth: tvScaled(34))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.release).font(.subheadline).lineLimit(2)
                HStack(spacing: 8) {
                    Label("\(s.downloads)", systemImage: "arrow.down.circle")
                    if s.hearingImpaired { Image(systemName: "ear") }
                    if s.fromTrusted { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green) }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if downloading == s.id { ProgressView() }
        }
    }

    private func search() async {
        loading = true; error = nil; results = []
        defer { loading = false }
        let it = player.item
        do {
            results = try await subs.search(imdbID: it.imdbID, title: it.title, year: it.subtitle.flatMap { Int($0) },
                                            season: it.season, episode: it.episode,
                                            languages: language.isEmpty ? [] : [language])
            if results.isEmpty {
                error = language.isEmpty ? L("No subtitles found for this title.")
                                         : L("No subtitles found in %@.", TrackPreferences.name(language))
            }
        } catch { self.error = error.localizedDescription }
    }

    private func load(_ s: OpenSubtitles.Subtitle) {
        guard subs.isLoggedIn else { showLogin = true; return }
        downloading = s.id
        Task {
            defer { downloading = nil }
            do {
                let file = try await subs.download(s)
                player.addSubtitle(file: file, name: "\(TrackPreferences.flag(s.language)) \(s.release)", language: s.language)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Snelheid, beeld, engine en slaaptimer.
struct OptionsPanel: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !player.isLive {
                    Section(L("Speed")) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                            check(r == 1 ? L("Normal") : "\(r.formatted())×", player.rate == r) { player.rate = r }
                        }
                    }
                }
                Section(L("Subtitle size")) {
                    ForEach(SubtitleSize.allCases, id: \.self) { sz in
                        check(sz.title, SubtitleSize.current == sz) {
                            UserDefaults.standard.set(sz.rawValue, forKey: SubtitleSize.key)
                            player.applySubtitleSize()
                        }
                    }
                }
                Section(L("Picture")) {
                    ForEach(PlayerController.Aspect.allCases, id: \.self) { a in
                        check(a.title, player.aspect == a) { player.aspect = a }
                    }
                }
                Section {
                    Text(player.usingApple ? L("Now playing with: Apple") : L("Now playing with: VLC"))
                        .foregroundStyle(Theme.secondary)
                    if !player.usingApple {
                        Button(L("Try Apple player (HDR, Dolby Vision, AirPlay)")) { player.switchToApple(); dismiss() }
                    }
                } header: { Text(L("Player engine")) }
                Section(L("Sleep timer")) {
                    ForEach([0, 15, 30, 45, 60, 90], id: \.self) { m in
                        Button {
                            player.sleepAt = m == 0 ? nil : Date().addingTimeInterval(Double(m) * 60)
                        } label: { Text(m == 0 ? L("Off") : L("In %d minutes", m)) }
                    }
                }
            }
            .navigationTitle(L("Options"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }

    private func check(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(Theme.red) } }
        }
    }
}

// MARK: - Build 52: intro markeren, andere bron, volgende aflevering

/// "Intro hier markeren": begin en einde van de intro (en het begin van de aftiteling) voor de hele serie.
struct IntroMarkerPanel: View {
    @ObservedObject var player: PlayerController
    let key: String
    @ObservedObject private var markers = IntroMarkers.shared
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @State private var endText = ""
    #endif

    private var m: IntroMarker { markers.marker(key) ?? IntroMarker() }
    private var now: Double { player.currentTime }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(L("Now"), value: PlayerController.format(now))
                    Button { markers.update(key) { $0.introStart = now } } label: {
                        Label(L("Intro starts here"), systemImage: "arrow.right.to.line")
                    }
                    Button {
                        markers.update(key) { m in
                            m.introEnd = now
                            if let s = m.introStart, s >= now { m.introStart = nil }
                        }
                    } label: { Label(L("Intro ends here"), systemImage: "arrow.left.to.line") }
                    adjustRow(L("Intro starts at"), m.introStart) { v in markers.update(key) { $0.introStart = v } }
                    adjustRow(L("Intro ends at"), m.introEnd) { v in markers.update(key) { $0.introEnd = v } }
                    #if !os(tvOS)
                    HStack {
                        TextField(L("Intro ends at (mm:ss)"), text: $endText)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                            .onSubmit(applyEndText)
                        Button(L("Set"), action: applyEndText).disabled(Self.parse(endText) == nil)
                    }
                    #endif
                } header: { Text(L("Intro")) } footer: {
                    Text(L("Without a start, the intro counts from the beginning of the episode."))
                }
                Section {
                    Button { markers.update(key) { $0.creditsStart = now } } label: {
                        Label(L("Credits start here"), systemImage: "text.alignleft")
                    }
                    adjustRow(L("Credits start at"), m.creditsStart) { v in markers.update(key) { $0.creditsStart = v } }
                } header: { Text(L("Credits")) } footer: {
                    Text(L("When the credits start, the next episode begins after a short countdown."))
                }
                if !m.isEmpty {
                    Section {
                        Button(L("Remove markers"), role: .destructive) { markers.update(key) { $0 = IntroMarker() } }
                    }
                }
            }
            .navigationTitle(L("Mark intro here"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
            #if !os(tvOS)
            .onAppear { endText = m.introEnd.map(PlayerController.format) ?? "" }
            #endif
        }
    }

    /// Tijd met −5 / +5 seconden
    @ViewBuilder
    private func adjustRow(_ title: String, _ value: Double?, _ set: @escaping (Double?) -> Void) -> some View {
        if let v = value {
            HStack {
                Text(title)
                Spacer()
                Button { set(max(0, v - 5)) } label: { Image(systemName: "minus.circle.fill") }
                Text(PlayerController.format(v)).monospacedDigit().frame(minWidth: tvScaled(60))
                Button { set(v + 5) } label: { Image(systemName: "plus.circle.fill") }
                Button { set(nil) } label: { Image(systemName: "xmark.circle") }.foregroundStyle(Theme.secondary)
            }
            #if !os(tvOS)
            .buttonStyle(.borderless)
            #endif
        }
    }

    #if !os(tvOS)
    private func applyEndText() {
        guard let v = Self.parse(endText) else { return }
        markers.update(key) { m in
            m.introEnd = v
            if let s = m.introStart, s >= v { m.introStart = nil }
        }
    }
    #endif

    /// "1:30", "01:30", "90" of "1:02:03" → seconden
    static func parse(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let v = parts.reduce(0.0) { $0 * 60 + ($1 ?? 0) }
        return v > 0 ? v : nil
    }
}

/// "Andere bron": dezelfde zender of titel elders.
struct AlternativesPanel: View {
    let items: [AlternativeSource]
    let loading: Bool
    let currentURL: URL?
    let onPick: (AlternativeSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if loading && items.isEmpty {
                    HStack { ProgressView(); Text(L("Searching other sources…")).foregroundStyle(Theme.secondary) }
                } else if items.isEmpty {
                    Text(L("No other sources found for this title.")).foregroundStyle(Theme.secondary)
                }
                ForEach(items) { a in
                    Button { onPick(a) } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: a.logo, contentMode: .fit, placeholder: String(a.name.prefix(3)))
                                .frame(width: tvScaled(56), height: tvScaled(34))
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(a.isCurrentSource ? L("This server") : a.source.name)
                                    if a.byEPG { Text("· EPG") }
                                }
                                .font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if a.url != nil && a.url == currentURL { Image(systemName: "checkmark").foregroundStyle(Theme.red) }
                        }
                    }
                }
            }
            .navigationTitle(L("Other source"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { dismiss() } } }
        }
    }
}

/// Kaart "Volgende aflevering" met aftellen (aftiteling of laatste seconden).
struct NextEpisodeCard: View {
    let next: PlayableItem
    let secondsLeft: Int
    /// Na het aftellen zelf starten (aftiteling gemarkeerd); anders start hij aan het einde van de aflevering
    let autoplay: Bool
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: tvScaled(14)) {
            RemoteImage(url: next.artwork, placeholder: "")
                .frame(width: tvScaled(120), height: tvScaled(68))
                .clipShape(RoundedRectangle(cornerRadius: tvScaled(8)))
            VStack(alignment: .leading, spacing: tvScaled(6)) {
                Text(L("Next episode")).font(.system(size: tvScaled(12), weight: .bold)).foregroundStyle(Theme.secondary)
                Text(next.subtitle ?? next.title).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                HStack(spacing: tvScaled(10)) {
                    Button(action: onPlay) {
                        Label(L("Starts in %d s", secondsLeft), systemImage: "play.fill")
                            .font(.system(size: tvScaled(13), weight: .bold))
                            .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(7))
                            .foregroundStyle(.black)
                            .background(.white, in: RoundedRectangle(cornerRadius: tvScaled(6)))
                    }
                    .plainTVButton()
                    Button(action: onDismiss) {
                        Text(autoplay ? L("Watch credits") : L("Hide"))
                            .font(.system(size: tvScaled(13), weight: .semibold))
                            .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(7))
                            .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: tvScaled(6)))
                    }
                    .plainTVButton()
                }
            }
        }
        .padding(tvScaled(12))
        .frame(maxWidth: tvScaled(460), alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(.white.opacity(0.12)))
    }
}
