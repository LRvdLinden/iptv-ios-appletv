import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// Afspeellijst toevoegen/bewerken — naam, avatar (icoon + kleur) en verbindingsgegevens.
struct AddPlaylistView: View {
    let existing: PlaylistSource?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var app: AppState

    @State private var kind: PlaylistKind = .m3u
    @State private var name = ""
    @State private var avatar = PlaylistAvatar.random()
    @State private var m3uURL = ""
    @State private var epgURL = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var mac = "00:1A:79:"
    @State private var preferHLS = false
    @State private var testing = false
    @State private var error: String?
    @State private var confirmDelete = false
    // Plex-koppeling
    @State private var plexPin: PlexClient.Pin?
    @State private var plexToken: String?
    @State private var plexTask: Task<Void, Never>?
    // profielfoto
    @State private var photo: Data?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    private var kindColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220), spacing: 24)]
        #else
        [GridItem(.adaptive(minimum: 100), spacing: 10)]
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(18)) {
                    HStack { Spacer(); AvatarTile(name: name.isEmpty ? L("New playlist") : name, avatar: avatar, photo: photo)
                        .frame(width: tvScaled(110)); Spacer() }

                    section(L("Choose the playlist type")) {
                        LazyVGrid(columns: kindColumns, spacing: tvScaled(10)) {
                            ForEach(PlaylistKind.allCases) { k in
                                Button { withAnimation(.spring(response: 0.3)) { kind = k } } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: k.symbol).font(.system(size: tvScaled(20), weight: .semibold))
                                        Text(k.title).font(.system(size: tvScaled(12), weight: .semibold)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, tvScaled(12))
                                    .foregroundStyle(.white)
                                    .background(kind == k ? AnyShapeStyle(Theme.red) : AnyShapeStyle(Theme.elevated),
                                                in: RoundedRectangle(cornerRadius: tvScaled(12)))
                                }
                                .plainTVButton()
                            }
                        }
                    }

                    section(L("Name this playlist")) { field(L("e.g. My playlist"), $name) }

                    section(L("Identify with an icon")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: tvScaled(10)) {
                                ForEach(PlaylistAvatar.symbols, id: \.self) { s in
                                    Button { withAnimation(.spring(response: 0.3)) { avatar.symbol = s } } label: {
                                        Image(systemName: s)
                                            .font(.system(size: tvScaled(20), weight: .semibold))
                                            .frame(width: tvScaled(44), height: tvScaled(44))
                                            .foregroundStyle(.white)
                                            .background(avatar.symbol == s ? AnyShapeStyle(avatar.gradient) : AnyShapeStyle(Theme.elevated),
                                                        in: RoundedRectangle(cornerRadius: tvScaled(12)))
                                    }
                                    .plainTVButton()
                                }
                            }.padding(.vertical, 4)
                        }
                        HStack(spacing: tvScaled(12)) {
                            ForEach(0..<PlaylistAvatar.palettes.count, id: \.self) { i in
                                Button { withAnimation { avatar.colorIndex = i } } label: {
                                    Circle().fill(PlaylistAvatar(symbol: "", colorIndex: i).gradient)
                                        .frame(width: tvScaled(28), height: tvScaled(28))
                                        .overlay(Circle().stroke(.white, lineWidth: avatar.colorIndex == i ? 3 : 0))
                                }
                                .plainTVButton()
                            }
                        }
                    }

                    section(L("Profile photo")) { photoControls }

                    kindFields

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: tvScaled(13))).foregroundStyle(Theme.red)
                    }

                    Button(action: save) {
                        HStack {
                            if testing { ProgressView().tint(.white) }
                            Text(testing ? L("Testing connection…") : L("Save")).font(.system(size: tvScaled(17), weight: .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, tvScaled(14))
                        .background(canSave ? Theme.red : Theme.elevated, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .plainTVButton()
                    .disabled(!canSave || testing)

                    if existing != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text(L("Delete playlist")).frame(maxWidth: .infinity)
                        }
                        .plainTVButton()
                        .foregroundStyle(Theme.red)
                    }
                }
                .padding(Theme.edge)
                .frame(maxWidth: tvScaled(640))
                .frame(maxWidth: .infinity)
            }
            .background(Color(hex: 0x141414).ignoresSafeArea())
            .navigationTitle(existing == nil ? L("Add playlist") : L("Edit playlist"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
            }
            .confirmationDialog(L("Delete?"), isPresented: $confirmDelete) {
                Button(L("Delete"), role: .destructive) {
                    if let existing {
                        store.delete(existing); app.playlists.clearCache(existing)
                        Keychain.set(nil, for: PlaylistService.sessionKey(existing))
                    }
                    dismiss()
                }
            }
        }
        .onAppear(perform: loadExisting)
        .onDisappear { plexTask?.cancel() }
    }

    // MARK: velden per type

    @ViewBuilder private var kindFields: some View {
        switch kind {
        case .m3u:
            section(L("URL to your M3U8 file")) { field("http://your-domain:port/path/file", $m3uURL, url: true) }
            section(L("URL to your EPG file")) { field(L("http://your-domain/epg.xml (optional)"), $epgURL, url: true) }
        case .xtream:
            section(L("Server")) { field("http://your-server:8080", $server, url: true) }
            section(L("Username")) { field(L("username"), $username) }
            section(L("Password")) { field(L("password"), $password, secure: true) }
            section(L("EPG (optional)")) { field(L("empty = EPG from the server"), $epgURL, url: true) }
            Toggle(L("Live TV as HLS (.m3u8) instead of .ts"), isOn: $preferHLS)
                .font(.system(size: tvScaled(14))).padding(.horizontal, 4)
        case .stalker:
            section(L("Portal URL")) { field("http://portal.example.com/c/", $server, url: true) }
            section(L("MAC address")) { field("00:1A:79:XX:XX:XX", $mac) }
            section(L("EPG (optional)")) { field("http://…/epg.xml", $epgURL, url: true) }
        case .jellyfin, .emby:
            section(L("Server")) { field(kind == .emby ? "http://192.168.1.10:8096/emby" : "http://192.168.1.10:8096", $server, url: true) }
            section(L("Username")) { field(L("username"), $username) }
            section(L("Password")) { field(L("password"), $password, secure: true) }
        case .plex:
            plexLogin
        case .stremio:
            section(L("Stremio account (optional)")) {
                field(L("e-mail"), $username)
                field(L("password"), $password, secure: true)
            }
            section(L("Extra add-ons (one manifest URL per line)")) {
                TextField("https://…/manifest.json", text: $m3uURL, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: tvScaled(14)))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #if os(iOS)
                    .padding(14).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18))
                    #endif
            }
            Text(L("Cinemeta is always added for catalogs. Only add-ons that return direct http(s) streams can be played."))
                .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
        }
    }

    private var plexLogin: some View {
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            if plexToken != nil || (existing?.kind == .plex && Keychain.get(existing!.passwordKey) != nil && plexPin == nil) {
                Label(L("Signed in with Plex"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
            }
            if let pin = plexPin, plexToken == nil {
                Text(L("Go to plex.tv/link and enter this code:")).foregroundStyle(Theme.secondary)
                Text(pin.code).font(.system(size: tvScaled(40), weight: .heavy, design: .monospaced)).kerning(6)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                ProgressView(L("Waiting for confirmation…")).tint(Theme.red)
            } else {
                Button {
                    startPlexLogin()
                } label: {
                    Label(L("Sign in with Plex"), systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity).padding(.vertical, tvScaled(12))
                        .background(Color(hex: 0xE5A00D), in: Capsule()).foregroundStyle(.black)
                }
                .plainTVButton()
            }
        }
    }

    private func startPlexLogin() {
        error = nil
        plexTask?.cancel()
        plexTask = Task {
            do {
                let pin = try await PlexClient.createPin()
                plexPin = pin
                plexToken = try await PlexClient.waitForToken(pin)
                if name.isEmpty { name = "Plex" }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; plexPin = nil }
        }
    }

    // MARK: profielfoto

    @ViewBuilder private var photoControls: some View {
        #if os(iOS)
        HStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photo == nil ? L("Choose from Photos") : L("Change photo"), systemImage: "photo.on.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Theme.elevated, in: Capsule())
            }
            if photo != nil {
                Button(role: .destructive) { withAnimation { photo = nil; photoItem = nil } } label: {
                    Label(L("Remove photo"), systemImage: "trash").font(.system(size: 15))
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let small = Self.thumbnail(data) {
                    withAnimation { photo = small }
                }
            }
        }
        Text(L("A photo replaces the icon.")).font(.caption).foregroundStyle(Theme.secondary)
        #else
        Text(photo == nil ? L("Choose a profile photo on your iPhone or iPad; it appears here automatically via iCloud.")
                          : L("Profile photo set on your iPhone or iPad."))
            .font(.system(size: 22)).foregroundStyle(Theme.secondary)
        #endif
    }

    #if os(iOS)
    /// Vierkant uitsnijden en verkleinen tot 320 px JPEG (±20 KB) zodat het via iCloud past.
    static func thumbnail(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let target = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: target)
        let out = renderer.image { _ in
            let scale = target.width / side
            img.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                width: img.size.width * scale, height: img.size.height * scale))
        }
        return out.jpegData(compressionQuality: 0.72)
    }
    #endif

    // MARK: helpers

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .m3u: return m3uURL.urlValue != nil
        case .xtream: return server.urlValue != nil && !username.isEmpty && !password.isEmpty
        case .stalker: return server.urlValue != nil && mac.count >= 17
        case .jellyfin, .emby: return server.urlValue != nil && !username.isEmpty
        case .plex: return plexToken != nil || (existing?.kind == .plex && Keychain.get(existing!.passwordKey) != nil)
        case .stremio: return true
        }
    }

    private func loadExisting() {
        guard let p = existing else { return }
        kind = p.kind; name = p.name; avatar = p.avatar; m3uURL = p.m3uURL; epgURL = p.epgURL
        server = p.serverURL; username = p.username; mac = p.macAddress; preferHLS = p.preferHLS
        if p.kind != .plex && p.kind != .stremio { password = Keychain.get(p.passwordKey) ?? "" }
        photo = store.photos[p.id]
    }

    private func save() {
        var p = existing ?? PlaylistSource(name: name, kind: kind, avatar: avatar)
        p.name = name.trimmingCharacters(in: .whitespaces); p.kind = kind; p.avatar = avatar
        p.m3uURL = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines); p.epgURL = epgURL.trimmingCharacters(in: .whitespaces)
        p.serverURL = server.trimmingCharacters(in: .whitespaces); p.username = username
        p.macAddress = mac.uppercased(); p.preferHLS = preferHLS
        testing = true; error = nil
        Task {
            defer { testing = false }
            do {
                switch kind {
                case .m3u:
                    guard let u = p.m3uURL.urlValue else { throw HTTPError.badURL }
                    var r = URLRequest(url: u); r.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
                    let (d, h) = try await HTTP.data(r)
                    guard (200..<300).contains(h.statusCode) else { throw HTTPError.status(h.statusCode, "") }
                    guard String(decoding: d.prefix(2048), as: UTF8.self).contains("#EXT") else { throw PlaylistError.notM3U }
                    Keychain.set(nil, for: p.passwordKey)
                case .xtream:
                    try await XtreamClient(source: p, password: password).authenticate()
                    Keychain.set(password, for: p.passwordKey)
                case .stalker:
                    try await StalkerClient(source: p).connect()
                case .jellyfin, .emby:
                    let session = try await JellyfinClient(source: p, session: nil).login(username: username, password: password)
                    Keychain.setCodable(session, for: PlaylistService.sessionKey(p))
                    Keychain.set(nil, for: p.passwordKey)     // wachtwoord niet bewaren, token wel
                case .plex:
                    if let t = plexToken {
                        Keychain.set(t, for: p.passwordKey)
                        let session = try await PlexClient.discoverServer(userToken: t)
                        Keychain.setCodable(session, for: PlaylistService.sessionKey(p))
                        p.serverURL = session.serverURI
                    }
                case .stremio:
                    if !username.isEmpty && !password.isEmpty {
                        let key = try await StremioClient.login(email: username, password: password)
                        Keychain.set(key, for: p.passwordKey)
                    }
                }
                store.upsert(p)
                if photo != store.photos[p.id] { store.setPhoto(photo, for: p.id) }
                app.playlists.clearCache(p)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(title).font(.system(size: tvScaled(14), weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.leading, tvScaled(14))
            content()
        }
    }

    @ViewBuilder private func field(_ placeholder: String, _ text: Binding<String>, url: Bool = false, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .font(.system(size: tvScaled(16)))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #if os(iOS)
        .keyboardType(url ? .URL : .default)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Theme.elevated, in: Capsule())
        #endif
    }
}

enum PlaylistError: LocalizedError {
    case notM3U
    var errorDescription: String? { L("This doesn't look like a valid M3U playlist.") }
}
