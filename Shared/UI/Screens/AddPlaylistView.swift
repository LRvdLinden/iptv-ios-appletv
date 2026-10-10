import SwiftUI

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(18)) {
                    // live preview van de avatar
                    HStack { Spacer(); AvatarTile(name: name.isEmpty ? "Nieuwe lijst" : name, avatar: avatar)
                        .frame(width: tvScaled(110)); Spacer() }

                    section("Kies het type afspeellijst") {
                        Picker("Type", selection: $kind) {
                            ForEach(PlaylistKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    section("Noem deze afspeellijst") { field("bijv. Mijn afspeellijst", $name) }

                    section("Identificeer met een icoon") {
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

                    switch kind {
                    case .m3u:
                        section("URL naar je M3U8-bestand") { field("http://jouw-domein:poort/pad/bestand", $m3uURL, url: true) }
                        section("URL naar je EPG-bestand") { field("http://jouw-domein/epg.xml (optioneel)", $epgURL, url: true) }
                    case .xtream:
                        section("Server") { field("http://jouw-server:8080", $server, url: true) }
                        section("Gebruikersnaam") { field("gebruikersnaam", $username) }
                        section("Wachtwoord") { field("wachtwoord", $password, secure: true) }
                        section("EPG (optioneel)") { field("leeg = EPG van de server", $epgURL, url: true) }
                        Toggle("Live TV als HLS (.m3u8) i.p.v. .ts", isOn: $preferHLS)
                            .font(.system(size: tvScaled(14))).padding(.horizontal, 4)
                    case .stalker:
                        section("Portal-URL") { field("http://portal.example.com/c/", $server, url: true) }
                        section("MAC-adres") { field("00:1A:79:XX:XX:XX", $mac) }
                        section("EPG (optioneel)") { field("http://…/epg.xml", $epgURL, url: true) }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: tvScaled(13))).foregroundStyle(Theme.red)
                    }

                    Button(action: save) {
                        HStack {
                            if testing { ProgressView().tint(.white) }
                            Text(testing ? "Verbinding testen…" : "Opslaan").font(.system(size: tvScaled(17), weight: .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, tvScaled(14))
                        .background(canSave ? Theme.red : Theme.elevated, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .plainTVButton()
                    .disabled(!canSave || testing)

                    if existing != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Afspeellijst verwijderen").frame(maxWidth: .infinity)
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
            .navigationTitle(existing == nil ? "Afspeellijst toevoegen" : "Afspeellijst bewerken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
            }
            .confirmationDialog("Verwijderen?", isPresented: $confirmDelete) {
                Button("Verwijderen", role: .destructive) {
                    if let existing { store.delete(existing); app.playlists.clearCache(existing) }
                    dismiss()
                }
            }
        }
        .onAppear(perform: loadExisting)
    }

    // MARK: helpers

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .m3u: return m3uURL.urlValue != nil
        case .xtream: return server.urlValue != nil && !username.isEmpty && !password.isEmpty
        case .stalker: return server.urlValue != nil && mac.count >= 17
        }
    }

    private func loadExisting() {
        guard let p = existing else { return }
        kind = p.kind; name = p.name; avatar = p.avatar; m3uURL = p.m3uURL; epgURL = p.epgURL
        server = p.serverURL; username = p.username; mac = p.macAddress; preferHLS = p.preferHLS
        password = Keychain.get(p.passwordKey) ?? ""
    }

    private func save() {
        var p = existing ?? PlaylistSource(name: name, kind: kind, avatar: avatar)
        p.name = name.trimmingCharacters(in: .whitespaces); p.kind = kind; p.avatar = avatar
        p.m3uURL = m3uURL.trimmingCharacters(in: .whitespaces); p.epgURL = epgURL.trimmingCharacters(in: .whitespaces)
        p.serverURL = server.trimmingCharacters(in: .whitespaces); p.username = username
        p.macAddress = mac.uppercased(); p.preferHLS = preferHLS
        testing = true; error = nil
        let src = p
        Task {
            defer { testing = false }
            do {
                switch kind {
                case .m3u:
                    guard let u = src.m3uURL.urlValue else { throw HTTPError.badURL }
                    var r = URLRequest(url: u); r.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
                    let (d, h) = try await HTTP.data(r)
                    guard (200..<300).contains(h.statusCode) else { throw HTTPError.status(h.statusCode, "") }
                    guard String(decoding: d.prefix(2048), as: UTF8.self).contains("#EXT") else {
                        throw PlaylistError.notM3U
                    }
                case .xtream:
                    try await XtreamClient(source: src, password: password).authenticate()
                case .stalker:
                    try await StalkerClient(source: src).connect()
                }
                Keychain.set(password.isEmpty ? nil : password, for: src.passwordKey)
                store.upsert(src)
                app.playlists.clearCache(src)
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
    var errorDescription: String? { "Dit lijkt geen geldige M3U-afspeellijst." }
}
