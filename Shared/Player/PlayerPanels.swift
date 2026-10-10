import SwiftUI

/// Audio- en ondertitelsporen die in de stream zitten (VLC).
struct TracksPanel: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ForEach(player.audioTracks) { t in
                        row(t.name, selected: t.id == player.currentAudio) { player.selectAudio(t) }
                    }
                }
                Section("Ondertitels") {
                    ForEach(player.subtitleTracks) { t in
                        row(t.id == -1 ? "Uit" : t.name, selected: t.id == player.currentSubtitle) { player.selectSubtitle(t) }
                    }
                }
            }
            .navigationTitle("Audio & ondertitels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
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
                    Text("Log in bij OpenSubtitles via Mijn Bingr → OpenSubtitles om ondertitels te downloaden.")
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Sluit") { dismiss() } } }
            .task {
                defer { loading = false }
                guard let imdb = player.item.imdbID else { error = "Geen IMDb-ID bekend voor deze titel."; return }
                do {
                    results = try await subs.search(imdbID: imdb, season: player.item.season, episode: player.item.episode)
                    if results.isEmpty { error = "Geen ondertitels gevonden in \(subs.preferredLanguages.joined(separator: ", "))." }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

/// Snelheid, beeldverhouding en slaaptimer.
struct OptionsPanel: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !player.isLive {
                    Section("Snelheid") {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                            Button { player.rate = r } label: {
                                HStack { Text(r == 1 ? "Normaal" : "\(r.formatted())×"); Spacer()
                                    if player.rate == r { Image(systemName: "checkmark").foregroundStyle(Theme.red) } }
                            }
                        }
                    }
                }
                Section("Beeld") {
                    ForEach(PlayerController.Aspect.allCases, id: \.self) { a in
                        Button { player.aspect = a } label: {
                            HStack { Text(a.rawValue); Spacer()
                                if player.aspect == a { Image(systemName: "checkmark").foregroundStyle(Theme.red) } }
                        }
                    }
                }
                Section("Slaaptimer") {
                    ForEach([0, 15, 30, 45, 60, 90], id: \.self) { m in
                        Button {
                            player.sleepAt = m == 0 ? nil : Date().addingTimeInterval(Double(m) * 60)
                        } label: { Text(m == 0 ? "Uit" : "Over \(m) minuten") }
                    }
                }
            }
            .navigationTitle("Opties")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
        }
    }
}
