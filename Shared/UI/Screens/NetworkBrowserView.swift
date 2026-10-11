import SwiftUI
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// Een zelf toegevoegde netwerkschijf (SMB). Wachtwoord staat in de sleutelhanger.
struct NASServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String          // bijv. 192.168.1.10 of nas.local
    var share: String         // map/share, mag leeg
    var username: String
    var passwordKey: String { "nas.\(id.uuidString).password" }

    /// smb://gebruiker:wachtwoord@host/share/
    var url: URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host.trimmingCharacters(in: .whitespaces)
        let s = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        c.path = s.isEmpty ? "/" : "/\(s)/"
        if !username.isEmpty {
            c.user = username
            c.password = Keychain.get(passwordKey)
        }
        return c.url
    }

    static let storeKey = "nas.servers"
    static func load() -> [NASServer] {
        guard let d = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([NASServer].self, from: d)) ?? []
    }
    static func save(_ list: [NASServer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: storeKey)
    }
}

/// Item op het netwerk: map of bestand.
struct NetEntry: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let name: String
    let url: URL
    let isFolder: Bool

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "wmv", "mpg",
                                                "mpeg", "webm", "flv", "vob", "iso", "3gp", "ogv", "divx", "rmvb"]
    var isVideo: Bool { !isFolder && (url.pathExtension.isEmpty || Self.videoExtensions.contains(url.pathExtension.lowercased())) }

    init(name: String, url: URL, isFolder: Bool) { self.name = name; self.url = url; self.isFolder = isFolder }

    @MainActor
    init?(_ m: VLCMedia) {
        guard let u = m.url else { return nil }
        let title = m.metaData.title
        name = (title?.isEmpty == false ? title! : u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent)
        url = u
        isFolder = m.mediaType == .directory || m.mediaType == .unknown && u.pathExtension.isEmpty && u.absoluteString.hasSuffix("/")
    }
}

/// Zoekt NAS-servers (UPnP/DLNA en SMB) op het lokale netwerk via VLC.
@MainActor
final class NetworkDiscovery: ObservableObject {
    @Published private(set) var found: [NetEntry] = []
    private var discoverers: [VLCMediaDiscoverer] = []
    private var timer: Timer?

    func start() {
        guard discoverers.isEmpty else { return }
        for name in ["upnp", "dsm", "smb", "bonjour"] {
            let d = VLCMediaDiscoverer(name: name)
            if d.startDiscoverer() == 0 { discoverers.append(d) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        discoverers.forEach { $0.stopDiscoverer() }
        discoverers = []
    }

    private func poll() {
        var out: [NetEntry] = []
        for d in discoverers {
            guard let list = d.discoveredMedia else { continue }
            for i in 0..<max(list.count, 0) {
                if let m = list.media(at: UInt(i)), let e = NetEntry(m) {
                    out.append(NetEntry(name: e.name, url: e.url, isFolder: true))
                }
            }
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if out != found { found = out }
    }
}

/// NAS & netwerk: gevonden servers, eigen SMB-servers, bladeren en afspelen.
struct NetworkBrowserView: View {
    @StateObject private var discovery = NetworkDiscovery()
    @State private var servers = NASServer.load()
    @State private var editing: NASServer?

    var body: some View {
        List {
            Section {
                if discovery.found.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("Searching your network…")).foregroundStyle(Theme.secondary)
                    }
                }
                ForEach(discovery.found) { e in
                    NavigationLink { NetworkFolderView(title: e.name, url: e.url) } label: {
                        Label(e.name, systemImage: e.url.scheme == "smb" ? "externaldrive.connected.to.line.below" : "server.rack")
                    }
                }
            } header: { Text(L("Found on your network")) } footer: {
                Text(L("Media servers (DLNA/UPnP) and shared folders (SMB) on your Wi-Fi network."))
            }

            Section(L("Your servers")) {
                ForEach(servers) { s in
                    if let u = s.url {
                        NavigationLink { NetworkFolderView(title: s.name, url: u) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text("smb://\(s.host)/\(s.share)").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        .contextMenu {
                            Button { editing = s } label: { Label(L("Edit"), systemImage: "pencil") }
                            Button(role: .destructive) { delete(s) } label: { Label(L("Delete"), systemImage: "trash") }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button(role: .destructive) { delete(s) } label: { Label(L("Delete"), systemImage: "trash") }
                            Button { editing = s } label: { Label(L("Edit"), systemImage: "pencil") }
                        }
                        #endif
                    }
                }
                Button { editing = NASServer(name: "", host: "", share: "", username: "") } label: {
                    Label(L("Add SMB server"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(L("NAS & network"))
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(item: $editing) { s in
            NASServerForm(server: s) { saved in
                if let i = servers.firstIndex(where: { $0.id == saved.id }) { servers[i] = saved } else { servers.append(saved) }
                NASServer.save(servers)
            }
        }
    }

    private func delete(_ s: NASServer) {
        servers.removeAll { $0.id == s.id }
        Keychain.set(nil, for: s.passwordKey)
        NASServer.save(servers)
    }
}

private struct NASServerForm: View {
    @State var server: NASServer
    let onSave: (NASServer) -> Void
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name"), text: $server.name)
                    TextField(L("Address (e.g. 192.168.1.10)"), text: $server.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("Share / folder (optional)"), text: $server.share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField(L("Username (optional)"), text: $server.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L("Password"), text: $password)
                } footer: { Text(L("Leave empty for guest access.")) }
                Button(L("Save")) {
                    if server.name.trimmingCharacters(in: .whitespaces).isEmpty { server.name = server.host }
                    Keychain.set(password.isEmpty ? nil : password, for: server.passwordKey)
                    onSave(server)
                    dismiss()
                }
                .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle(L("SMB server"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .onAppear { password = Keychain.get(server.passwordKey) ?? "" }
        }
    }
}

/// Inhoud van een map op de NAS (via VLC: SMB, UPnP/DLNA, FTP, NFS…).
struct NetworkFolderView: View {
    let title: String
    let url: URL
    @EnvironmentObject var app: AppState
    @State private var items: [NetEntry] = []
    @State private var loading = true
    @State private var failed = false
    @State private var media: VLCMedia?

    var body: some View {
        List {
            if loading {
                HStack(spacing: 10) { ProgressView(); Text(L("Loading…")).foregroundStyle(Theme.secondary) }
            } else if failed {
                Text(L("This folder couldn't be opened. Check the address, username and password.")).foregroundStyle(Theme.secondary)
            } else if items.isEmpty {
                Text(L("No videos in this folder.")).foregroundStyle(Theme.secondary)
            }
            ForEach(items) { e in
                if e.isFolder {
                    NavigationLink { NetworkFolderView(title: e.name, url: e.url) } label: {
                        Label(e.name, systemImage: "folder.fill")
                    }
                } else {
                    Button { play(e) } label: {
                        Label(e.name, systemImage: "play.rectangle.fill")
                    }
                }
            }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        loading = true; failed = false
        let m = VLCMedia(url: url)
        media = m   // vasthouden tijdens het inlezen
        _ = m.parse(withOptions: VLCMediaParsingOptions(rawValue: 0x01 | 0x08), timeout: 15_000)  // netwerk + inloggen
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let st = m.parsedStatus
            if st == .done || st == .failed || st == .timeout || st == .skipped { break }
        }
        var out: [NetEntry] = []
        if let list = m.subitems {
            for i in 0..<max(list.count, 0) {
                if let sub = list.media(at: UInt(i)), let e = NetEntry(sub), e.isFolder || e.isVideo { out.append(e) }
            }
        }
        items = out.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        failed = out.isEmpty && (m.parsedStatus == .failed || m.parsedStatus == .timeout)
        loading = false
    }

    private func play(_ e: NetEntry) {
        // credentials uit de map-URL meegeven aan het bestand (VLC vraagt er anders opnieuw om)
        var u = e.url
        if var c = URLComponents(url: e.url, resolvingAgainstBaseURL: false), c.user == nil,
           let base = URLComponents(url: url, resolvingAgainstBaseURL: false), base.user != nil, base.host == c.host {
            c.user = base.user; c.password = base.password
            u = c.url ?? e.url
        }
        let clean = e.url.absoluteString
        let name = (e.name as NSString).deletingPathExtension
        app.play(PlayableItem(id: "nas-" + clean, title: name, subtitle: title, url: u, type: .movie))
    }
}
