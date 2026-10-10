import SwiftUI

/// Tot 4 live-streams tegelijk. Het geselecteerde beeld heeft geluid.
struct MultiviewScreen: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.dismiss) private var dismiss

    @State private var tiles: [Tile] = []
    @State private var active: UUID?
    @State private var picking = false

    struct Tile: Identifiable {
        let id = UUID()
        let channel: Channel
        let controller: PlayerController
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let cols = tiles.count <= 1 ? 1 : 2
                let rows = tiles.count <= 2 ? 1 : 2
                let w = geo.size.width / CGFloat(cols), h = geo.size.height / CGFloat(rows)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 0), count: cols), spacing: 0) {
                    ForEach(tiles) { t in
                        tile(t).frame(width: w, height: h)
                    }
                }
            }
            .ignoresSafeArea()

            HStack(spacing: 14) {
                #if os(iOS)
                Button { closeAll() } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).padding(10) }
                #endif
                Text("Multiview").font(.system(size: tvScaled(15), weight: .bold))
                Spacer()
                if tiles.count < 4 {
                    Button { picking = true } label: {
                        Label(L("Add channel"), systemImage: "plus").font(.system(size: tvScaled(13), weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.6), in: Capsule())
                    }
                    .plainTVButton()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.edge).padding(.top, tvScaled(8))
        }
        #if os(tvOS)
        .onExitCommand { closeAll() }
        #endif
        .sheet(isPresented: $picking) {
            ChannelPicker(channels: playlists.library.channels) { c in add(c) }
        }
        .onAppear {
            if tiles.isEmpty {
                for c in app.multiviewStart.prefix(4) { add(c) }
                if tiles.isEmpty { picking = true }
            }
        }
    }

    private func tile(_ t: Tile) -> some View {
        Button { focus(t) } label: {
            ZStack(alignment: .bottomLeading) {
                EngineView(controller: t.controller)
                BufferingOverlay(controller: t.controller)
                HStack(spacing: 6) {
                    Image(systemName: active == t.id ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Text(t.channel.name).lineLimit(1)
                }
                .font(.system(size: tvScaled(12), weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(8)
            }
            .overlay(Rectangle().stroke(active == t.id ? Theme.red : .clear, lineWidth: 3))
        }
        .plainTVButton()
        .contextMenu {
            Button { fullscreen(t) } label: { Label(L("Full screen"), systemImage: "arrow.up.left.and.arrow.down.right") }
            Button(role: .destructive) { remove(t) } label: { Label(L("Remove"), systemImage: "xmark") }
        }
    }

    private func add(_ c: Channel) {
        guard tiles.count < 4 else { return }
        let ctrl = PlayerController(item: Playables.channel(c, now: playlists.library.nowPlaying(c)))
        ctrl.isPreview = true
        let t = Tile(channel: c, controller: ctrl)
        tiles.append(t)
        Task {
            if let u = await playlists.resolve(ctrl.item) { ctrl.start(url: u) }
            if active == nil { focus(t) } else { t.controller.muted = true }
        }
    }

    private func focus(_ t: Tile) {
        if active == t.id { fullscreen(t); return }
        active = t.id
        for x in tiles { x.controller.muted = x.id != t.id }
    }

    private func remove(_ t: Tile) {
        t.controller.stop()
        tiles.removeAll { $0.id == t.id }
        if active == t.id, let f = tiles.first { active = nil; focus(f) }
    }

    private func fullscreen(_ t: Tile) {
        let zap = app.liveZapList
        closeAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            app.play(Playables.channel(t.channel, now: playlists.library.nowPlaying(t.channel)), zap: zap)
        }
    }

    private func closeAll() {
        tiles.forEach { $0.controller.stop() }
        tiles = []
        app.showMultiview = false
        dismiss()
    }
}

/// Zender kiezen (met zoeken).
struct ChannelPicker: View {
    let channels: [Channel]
    let onPick: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button { onPick(c); dismiss() } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: c.logo, contentMode: .fit, placeholder: String(c.name.prefix(3)))
                            .frame(width: tvScaled(48), height: tvScaled(30))
                        VStack(alignment: .leading) {
                            Text(c.name)
                            Text(c.group).font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .searchable(text: $q, prompt: L("Search channel"))
            .navigationTitle(L("Add channel"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }

    private var filtered: [Channel] {
        let list = q.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return Array(list.prefix(300))
    }
}

private struct BufferingOverlay: View {
    @ObservedObject var controller: PlayerController
    var body: some View {
        if controller.isBuffering || controller.reconnecting {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
