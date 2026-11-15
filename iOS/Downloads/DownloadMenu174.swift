import SwiftUI

/// Build 174: downloaden in het menu Meer van de detailpagina (telefoon), met de stand van de download.
struct DownloadMenuItems174: View {
    let item: PlayableItem
    var poster: URL? = nil
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var dm = DownloadManager.shared

    var body: some View {
        let d = dm.download(for: item.id)
        if let d, d.status == .completed {
            Button { if let p = dm.playable(d) { app.play(p) } } label: { Label(L("Play offline"), systemImage: "play.fill") }
            Button(role: .destructive) { dm.delete(d.id) } label: { Label(L("Delete download"), systemImage: "trash") }
        } else if let d, d.isActive {
            Button { dm.pause(d.id) } label: {
                Label(L("Pause download") + " · \(Int((d.progress * 100).rounded()))%", systemImage: "pause.circle")
            }
        } else if let d, d.status == .paused || d.status == .failed {
            Button { dm.resume(d.id) } label: { Label(L("Resume download"), systemImage: "arrow.down.circle") }
        } else {
            Button {
                let it = item, po = poster, pl = playlists
                Task { await dm.enqueue(it, seriesTitle: nil, poster: po, playlists: pl) }
            } label: { Label(L("Download"), systemImage: "arrow.down.circle") }
        }
    }
}
