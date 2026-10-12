import SwiftUI

/// Downloads (iPhone/iPad, build 52): voortgang, pauzeren/hervatten, verwijderen, opslag en offline afspelen.
struct DownloadsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var dm = DownloadManager.shared
    @AppStorage(DownloadManager.cellularKey) private var cellular = false
    @State private var deleting: DownloadItem?

    var body: some View {
        let list = dm.visibleItems
        List {
            Section {
                HStack {
                    Label(L("Storage used"), systemImage: "internaldrive")
                    Spacer()
                    Text(DownloadManager.bytes(dm.usedBytes)).foregroundStyle(Theme.secondary)
                }
                HStack {
                    Label(L("Free on this device"), systemImage: "externaldrive")
                    Spacer()
                    Text(DownloadManager.bytes(dm.freeBytes)).foregroundStyle(Theme.secondary)
                }
                Toggle(isOn: $cellular) { Label(L("Download over mobile data"), systemImage: "antenna.radiowaves.left.and.right") }
            } footer: {
                Text(L("Downloads continue in the background and resume automatically after an interruption. Downloaded titles play without an internet connection."))
            }
            let active = list.filter { $0.status != .completed }
            if !active.isEmpty {
                Section(L("Downloading")) {
                    ForEach(active) { row($0) }
                }
            }
            let done = list.filter { $0.status == .completed }
            Section(L("Ready to watch")) {
                if done.isEmpty {
                    Text(L("Download movies and episodes with the download button on their page to watch them offline."))
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(done) { row($0) }
            }
        }
        .navigationTitle(L("Downloads"))
        .onAppear { dm.start(); dm.recalcUsage() }
        .confirmationDialog(L("Delete download"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { d in
            Button(L("Delete %@", DownloadManager.displayTitle(d)), role: .destructive) { dm.delete(d.id); deleting = nil }
            Button(L("Cancel"), role: .cancel) { deleting = nil }
        }
    }

    private func row(_ d: DownloadItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: d.posterFile.map { DownloadManager.folder.appendingPathComponent($0) } ?? d.posterURL,
                        placeholder: String(d.title.prefix(2)))
                .frame(width: 54, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(d.title).font(.headline).lineLimit(1)
                if let s = d.subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1) }
                status(d)
            }
            Spacer(minLength: 8)
            controls(d)
        }
        .contentShape(Rectangle())
        .onTapGesture { play(d) }
        .swipeActions {
            Button(role: .destructive) { deleting = d } label: { Label(L("Delete"), systemImage: "trash") }
        }
        .contextMenu {
            if d.status == .completed { Button { play(d) } label: { Label(L("Play"), systemImage: "play.fill") } }
            Button(role: .destructive) { deleting = d } label: { Label(L("Delete download"), systemImage: "trash") }
        }
    }

    @ViewBuilder private func status(_ d: DownloadItem) -> some View {
        switch d.status {
        case .completed:
            let watched = CloudStore.shared.progress[d.itemID]?.fraction ?? 0
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(d.bytesExpected > 0 ? DownloadManager.bytes(d.bytesExpected) : L("Downloaded"))
                if watched > 0.02 { Text("· " + L("%d%% watched", Int(watched * 100))) }
            }
            .font(.caption).foregroundStyle(Theme.secondary)
        case .failed:
            Text(d.error ?? L("Download failed.")).font(.caption).foregroundStyle(Theme.alert).lineLimit(2)
        default:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: d.progress).tint(Theme.red)
                Group {
                    if d.status == .paused { Text(L("Paused")) }
                    else if d.status == .queued { Text(d.error.map { L("Retrying… (%@)", $0) } ?? L("Waiting…")) }
                    else if d.bytesExpected > 0 {
                        Text(L("%@ of %@", DownloadManager.bytes(d.bytesWritten), DownloadManager.bytes(d.bytesExpected)))
                    } else { Text("\(Int(d.progress * 100))%") }
                }
                .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func controls(_ d: DownloadItem) -> some View {
        switch d.status {
        case .completed:
            Button { play(d) } label: { Image(systemName: "play.circle.fill").font(.title) }
                .buttonStyle(.borderless).foregroundStyle(.white)
        case .downloading, .queued:
            Button { dm.pause(d.id) } label: { Image(systemName: "pause.circle").font(.title2) }
                .buttonStyle(.borderless).accessibilityLabel(L("Pause"))
        case .paused, .failed:
            Button { dm.resume(d.id) } label: {
                Image(systemName: d.status == .failed ? "arrow.clockwise.circle" : "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.borderless).accessibilityLabel(L("Resume"))
        }
    }

    private func play(_ d: DownloadItem) {
        guard let p = dm.playable(d) else { return }
        app.play(p)
    }
}

/// Downloadknop voor een film (detailpagina) of aflevering (kaart).
struct DownloadButton: View {
    let item: PlayableItem
    var seriesTitle: String? = nil
    var poster: URL? = nil
    /// Kleine variant op een afleveringskaart
    var compact = false
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var dm = DownloadManager.shared
    @State private var confirmDelete = false

    var body: some View {
        let d = dm.download(for: item.id)
        let size: CGFloat = compact ? 34 : tvScaled(50)
        Group {
            if let d, d.status == .completed {
                Menu {
                    Button { if let p = dm.playable(d) { app.play(p) } } label: { Label(L("Play offline"), systemImage: "play.fill") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("Delete download"), systemImage: "trash") }
                } label: { icon("arrow.down.circle.fill", size: size, tint: Theme.green) }
            } else if let d, d.isActive {
                Button { dm.pause(d.id) } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.02, d.progress)).stroke(Theme.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.system(size: size * 0.28)).foregroundStyle(.white)
                    }
                    .padding(size * 0.12)
                    .frame(width: size, height: size)
                    .background(Color.black.opacity(compact ? 0.55 : 0.12), in: Circle())
                }
                .accessibilityLabel(L("Pause download"))
            } else if let d, d.status == .paused || d.status == .failed {
                Button { dm.resume(d.id) } label: {
                    icon(d.status == .failed ? "exclamationmark.arrow.circlepath" : "pause.circle", size: size,
                         tint: d.status == .failed ? Theme.alert : .white)
                }
                .accessibilityLabel(L("Resume download"))
            } else {
                Button {
                    let it = item, st = seriesTitle, po = poster, pl = playlists
                    Task { await dm.enqueue(it, seriesTitle: st, poster: po, playlists: pl) }
                } label: { icon("arrow.down.circle", size: size, tint: .white) }
                .accessibilityLabel(L("Download"))
            }
        }
        .buttonStyle(.plain)
        .confirmationDialog(L("Delete download"), isPresented: $confirmDelete) {
            Button(L("Delete download"), role: .destructive) { if let d { dm.delete(d.id) } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private func icon(_ name: String, size: CGFloat, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(compact ? Color.black.opacity(0.55) : Color.white.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.12)))
    }
}
