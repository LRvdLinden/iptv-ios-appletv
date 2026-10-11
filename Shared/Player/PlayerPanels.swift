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
                player.addSubtitle(file: file, name: "\(TrackPreferences.flag(s.language)) \(s.release)")
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
