import SwiftUI

/// Build 175: downloaden staat altijd in Meer op de detailpagina (iPhone en iPad), ook bij series.
/// Regels in Shared/Player/Build175.swift (Download175), gelijk aan Android (Build175Logic.kt).

/// Vraag van het menu aan de detailpagina (een menu kan zelf geen bevestiging tonen)
struct DownloadConfirm175: Identifiable {
    enum Kind { case download([PlayableItem]), delete([String]) }
    let id = UUID()
    var kind: Kind
    var seriesTitle: String?
    var poster: URL?

    var count: Int {
        switch kind { case .download(let a): return a.count; case .delete(let a): return a.count }
    }

    var title: String {
        switch kind {
        case .download: return L("Download %d episodes?", count)
        case .delete: return L("Delete %d downloads?", count)
        }
    }

    /// "Alleen via wifi" geldt (instelling Downloaden via mobiele data uit)
    @MainActor var message: String {
        switch kind {
        case .download:
            return UserDefaults.standard.bool(forKey: DownloadManager.cellularKey)
                ? L("Downloads also use mobile data.") : L("Downloads only start over Wi-Fi.")
        case .delete: return L("The episodes stay available to stream.")
        }
    }
}

@MainActor
enum DownloadActions175 {
    nonisolated static func state(_ d: DownloadItem?) -> Download175.State {
        guard let d else { return .none }
        switch d.status {
        case .queued: return .queued
        case .downloading: return .downloading
        case .paused: return .paused
        case .failed: return .failed
        case .completed: return .completed
        }
    }

    /// Na elkaar in de wachtrij zetten (de link wordt per aflevering opgevraagd)
    static func enqueue(_ items: [PlayableItem], seriesTitle: String?, poster: URL?, playlists: PlaylistService) {
        let dm = DownloadManager.shared
        Task { @MainActor in
            for it in items { await dm.enqueue(it, seriesTitle: seriesTitle, poster: poster, playlists: playlists) }
        }
    }

    static func delete(_ itemIDs: [String]) {
        let dm = DownloadManager.shared
        for id in itemIDs { if let d = dm.download(for: id) { dm.delete(d.id) } }
    }

    static func run(_ c: DownloadConfirm175, playlists: PlaylistService) {
        switch c.kind {
        case .download(let items): enqueue(items, seriesTitle: c.seriesTitle, poster: c.poster, playlists: playlists)
        case .delete(let ids): delete(ids)
        }
    }
}

/// Film in Meer: Downloaden, de stand van de download, of uitgegrijsd met de reden.
struct MovieDownloadMenu175: View {
    let item: PlayableItem
    var poster: URL? = nil
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var dm = DownloadManager.shared

    var body: some View {
        let d = dm.download(for: item.id)
        switch Download175.movieMenu(canDownload: DownloadManager.canDownload(item), state: DownloadActions175.state(d)) {
        case .downloaded:
            Button {} label: { Label(L("Downloaded"), systemImage: "checkmark.circle.fill") }
                .disabled(true)
            if let d {
                Button { if let p = dm.playable(d) { app.play(p) } } label: { Label(L("Play offline"), systemImage: "play.fill") }
                Button(role: .destructive) { dm.delete(d.id) } label: { Label(L("Delete"), systemImage: "trash") }
            }
        case .active:
            if let d {
                Button { dm.pause(d.id) } label: {
                    Label(L("Pause download") + " · \(Int((d.progress * 100).rounded()))%", systemImage: "pause.circle")
                }
                Button(role: .destructive) { dm.delete(d.id) } label: { Label(L("Delete"), systemImage: "trash") }
            }
        case .resume:
            if let d {
                Button { dm.resume(d.id) } label: { Label(L("Resume download"), systemImage: "arrow.down.circle") }
                Button(role: .destructive) { dm.delete(d.id) } label: { Label(L("Delete"), systemImage: "trash") }
            }
        case .download:
            Button {
                DownloadActions175.enqueue([item], seriesTitle: nil, poster: poster, playlists: playlists)
            } label: { Label(L("Download"), systemImage: "arrow.down.circle") }
        case .unavailable:
            Button {} label: {
                Text(L("Download"))
                Text(L("This stream can't be downloaded"))
                Image(systemName: "arrow.down.circle")
            }
            .disabled(true)
        }
    }
}

/// Serie: Downloaden met "Dit seizoen downloaden", "Volgende 3 afleveringen" en "Hele serie" (met bevestiging).
/// `asCircle`: ronde knop in de brede rij (iPad); anders een submenu in Meer.
struct SeriesDownloadMenu175: View {
    let series: Series
    let episodes: [Episode]
    let season: Int
    let nextUp: Episode?
    let imdb: String?
    var asCircle = false
    var circleSize: CGFloat = 50
    /// Build 190: brede donkergrijze pil onder Afspelen (telefoon) in plaats van een regel in Meer
    var pill = false
    let onConfirm: (DownloadConfirm175) -> Void
    let onMessage: (String) -> Void
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var dm = DownloadManager.shared

    private var items: [PlayableItem] { episodes.map { Playables.episode($0, of: series, imdb: imdb) } }

    private func model(_ items: [PlayableItem]) -> [Download175.Episode] {
        zip(episodes, items).map { e, it in
            Download175.Episode(id: it.id, season: e.season, number: e.number, downloadable: DownloadManager.canDownload(it),
                                state: DownloadActions175.state(dm.download(for: it.id)))
        }
    }

    var body: some View {
        let items = self.items
        let eps = model(items)
        let menu = Download175.seriesMenu(eps, season: season, nextUp: nextUp?.id)
        if !menu.available {
            if pill {
                DownloadPillLabel(title: L("Download"), icon: "arrow.down.to.line").opacity(0.5)
                    .accessibilityLabel(L("This stream can't be downloaded"))
            } else if asCircle {
                circle("arrow.down.circle", tint: .white.opacity(0.35))
                    .disabled(true)
                    .accessibilityLabel(L("This stream can't be downloaded"))
            } else {
                Button {} label: {
                    Text(L("Download"))
                    Text(L("This stream can't be downloaded"))
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(true)
            }
        } else {
            Menu {
                if menu.complete {
                    Button {} label: { Label(L("Downloaded"), systemImage: "checkmark.circle.fill") }.disabled(true)
                }
                choice(.season, L("Download this season"), "rectangle.stack", menu.season, items, eps)
                choice(.nextThree, L("Next 3 episodes"), "forward.end", menu.nextThree, items, eps)
                choice(.all, L("Entire series"), "square.stack.3d.down.right", menu.all, items, eps)
                if menu.downloaded > 0 {
                    Divider()
                    Button(role: .destructive) {
                        let ids = eps.filter { $0.state != .none }.map(\.id)
                        onConfirm(DownloadConfirm175(kind: .delete(ids)))
                    } label: { Label(L("Delete"), systemImage: "trash") }
                }
            } label: {
                if pill {
                    DownloadPillLabel(title: menu.complete ? L("Downloaded") : L("Download"),
                                      icon: menu.complete ? "checkmark" : "arrow.down.to.line")
                } else if asCircle {
                    circleLabel(menu.complete ? "checkmark.circle.fill" : "arrow.down.circle",
                                tint: menu.complete ? Theme.green : .white)
                } else if menu.complete {
                    Label(L("Downloaded"), systemImage: "checkmark.circle.fill")
                } else {
                    Label(L("Download"), systemImage: "arrow.down.circle")
                }
            }
            .accessibilityLabel(menu.complete ? L("Downloaded") : L("Download"))
        }
    }

    @ViewBuilder
    private func choice(_ scope: Download175.Scope, _ title: String, _ icon: String, _ count: Int,
                        _ items: [PlayableItem], _ eps: [Download175.Episode]) -> some View {
        Button {
            let ids = Download175.episodes(for: scope, in: eps, season: season, nextUp: nextUp?.id)
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let chosen = ids.compactMap { byID[$0] }
            guard !chosen.isEmpty else { return }
            if Download175.needsConfirmation(scope, count: chosen.count) {
                onConfirm(DownloadConfirm175(kind: .download(chosen), seriesTitle: series.title, poster: series.poster))
            } else {
                DownloadActions175.enqueue(chosen, seriesTitle: series.title, poster: series.poster, playlists: playlists)
                onMessage(chosen.count == 1 ? L("Download started") : L("%d episodes added to Downloads", chosen.count))
            }
        } label: {
            Text(title)
            Text(count == 0 ? L("Downloaded") : L("%d episodes", count))
            Image(systemName: icon)
        }
        .disabled(count == 0)
    }

    private func circleLabel(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: circleSize * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: circleSize, height: circleSize)
            .background(Color.white.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.12)))
    }

    private func circle(_ name: String, tint: Color) -> some View {
        Button {} label: { circleLabel(name, tint: tint) }.buttonStyle(.plain)
    }
}

/// Build 190: donkergrijze pil met witte tekst (tweede knop onder Afspelen, in de stijl van de streamingdiensten)
struct DownloadPillLabel: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(Color(hex: 0x2B2B2B), in: Capsule())
            .contentShape(Capsule())
    }
}
