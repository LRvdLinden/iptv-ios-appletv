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
                        row(t.name, selected: t.id == player.currentAudio) { player.selectAudio(t) }
                    }
                }
                Section(L("Subtitles")) {
                    row(L("Off"), selected: player.currentSubtitle == nil) { player.selectSubtitle(nil) }
                    if player.hasExternalSubtitle { row("OpenSubtitles", selected: true) {} }
                    ForEach(player.subtitleTracks) { t in
                        row(t.name, selected: t.id == player.currentSubtitle) { player.selectSubtitle(t) }
                    }
                }
            }
            .navigationTitle(L("Audio & subtitles"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }

    private func row(_ name: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(name); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(Theme.red) } }
        }
    }
}

/// Ondertitels zoeken en inladen via OpenSubtitles (op IMDb-ID, met seizoen/aflevering).
struct OpenSubtitlesPanel: View {
    @ObservedObject var player: PlayerController
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss
    @State private var results: [OpenSubtitles.Subtitle] = []
    @State private var loading = true
    @State private var error: String?
    @State private var downloading: Int?

    var body: some View {
        NavigationStack {
            List {
                if !subs.isLoggedIn {
                    Text(L("Sign in to OpenSubtitles under My Bingr → OpenSubtitles to download subtitles."))
                        .foregroundStyle(Theme.secondary)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(Theme.red) }
                ForEach(results) { s in
                    Button {
                        downloading = s.id
                        Task {
                            defer { downloading = nil }
                            do {
                                let file = try await subs.download(s)
                                player.addSubtitle(file: file)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(s.language.uppercased()).font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
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
                    .disabled(!subs.isLoggedIn || downloading != nil)
                }
            }
            .navigationTitle("OpenSubtitles")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { dismiss() } } }
            .task {
                defer { loading = false }
                guard let imdb = player.item.imdbID else { error = L("No IMDb ID known for this title."); return }
                do {
                    results = try await subs.search(imdbID: imdb, season: player.item.season, episode: player.item.episode)
                    if results.isEmpty { error = L("No subtitles found in %@.", subs.preferredLanguages.joined(separator: ", ")) }
                } catch { self.error = error.localizedDescription }
            }
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
