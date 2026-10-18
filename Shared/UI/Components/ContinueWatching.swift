import SwiftUI

/// Kaart voor "Verder kijken": poster met afspeelicoon, daaronder een duidelijke voortgangsbalk en de resterende tijd.
struct ContinueCard: View {
    let title: String
    let poster: URL?
    let fraction: Double
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(5)) {
            PosterCard(title: title, poster: poster)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: tvScaled(16), weight: .bold)).foregroundStyle(.white)
                        .frame(width: tvScaled(38), height: tvScaled(38))
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                }
            ProgressBar(value: max(fraction, 0.03))
                .frame(width: Theme.posterWidth, height: tvScaled(4))
                .clipShape(Capsule())
            if let caption {
                Text(caption).font(.system(size: tvScaled(10))).foregroundStyle(Theme.secondary).lineLimit(1)
                    .frame(width: Theme.posterWidth, alignment: .leading)
            }
        }
    }
}

/// Een aangetikte titel uit "Verder kijken": kiezen tussen hervatten en opnieuw kijken.
struct ResumeChoice: Identifiable {
    /// voortgangssleutel (film- of aflevering-id)
    let id: String
    let title: String
    let fraction: Double
    var position: Double?
    var detail: DetailTarget?
    /// Build 128: server van de voortgang als dat niet de open server is
    var source: UUID? = nil
}

extension View {
    /// Toont "Hervatten / Opnieuw kijken / Meer info" voor een titel uit Verder kijken.
    func resumeDialog(_ choice: Binding<ResumeChoice?>, onDetail: @escaping (DetailTarget) -> Void) -> some View {
        modifier(ResumeDialog(choice: choice, onDetail: onDetail))
    }
}

private struct ResumeDialog: ViewModifier {
    @Binding var choice: ResumeChoice?
    let onDetail: (DetailTarget) -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var trakt: TraktSync

    func body(content: Content) -> some View {
        content.confirmationDialog(choice?.title ?? "",
                                   isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                                   titleVisibility: .visible, presenting: choice) { c in
            Button(c.position.map { L("Resume from %@", PlayerController.format($0)) } ?? L("Resume")) { run(c, restart: false) }
            Button(L("Watch from the beginning")) { run(c, restart: true) }
            if let d = c.detail { Button(L("More info")) { onDetail(d) } }
            Button(L("Cancel"), role: .cancel) {}
        } message: { c in
            Text(L("%d%% watched", Int((c.fraction * 100).rounded())))
        }
    }

    private func run(_ c: ResumeChoice, restart: Bool) {
        Task {
            if let fallback = await ResumePlayer.play(key: c.id, title: c.title, restart: restart, source: c.source,
                                                      detail: c.detail, app: app, playlists: playlists, trakt: trakt) {
                onDetail(fallback)
            }
        }
    }
}

@MainActor
enum ResumePlayer {
    /// Speelt een film of aflevering af op basis van de voortgangssleutel. Lukt dat niet, dan de serie/film om te openen.
    static func play(key: String, title: String, restart: Bool, source: UUID? = nil, detail: DetailTarget? = nil,
                     app: AppState, playlists: PlaylistService, trakt: TraktSync) async -> DetailTarget? {
        // build 128: voortgang van een andere server: afspelen via die server (zonder te wisselen)
        if let source, source != playlists.source?.id {
            switch detail {
            case .movie(let m)?:
                var it = Playables.movie(m, imdb: trakt.imdb(for: m))
                if restart { it.resumeAt = 0 }
                app.play(it)
                return nil
            case .series(let s)?:
                let eps = await playlists.episodes(for: s)
                if let e = eps.first(where: { $0.id == key }) {
                    var it = Playables.episode(e, of: s, imdb: trakt.imdb(for: s))
                    if restart { it.resumeAt = 0 }
                    app.play(it)
                    return nil
                }
                return .series(s)
            case nil:
                return nil
            }
        }
        let lib = playlists.library
        if let m = lib.movies.first(where: { $0.id == key }) {
            var it = Playables.movie(m, imdb: trakt.imdb(for: m))
            if restart { it.resumeAt = 0 }
            app.play(it)
            return nil
        }
        // aflevering: eerst de serie met dezelfde titel, anders de serie waar de aflevering in zit
        var candidates = lib.series.filter { $0.title == title }
        if candidates.isEmpty { candidates = lib.series.filter { s in s.episodes.contains { $0.id == key } } }
        for s in candidates {
            let eps = s.episodes.contains(where: { $0.id == key }) ? s.episodes : await playlists.episodes(for: s)
            if let e = eps.first(where: { $0.id == key }) {
                var it = Playables.episode(e, of: s, imdb: trakt.imdb(for: s))
                if restart { it.resumeAt = 0 }
                app.play(it)
                return nil
            }
        }
        return candidates.first.map { .series($0) }
    }
}
