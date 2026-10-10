import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var trakt: TraktSync
    @EnvironmentObject var subs: OpenSubtitles
    @AppStorage("autoSubtitles") private var autoSubtitles = false
    @State private var showTraktLogin = false
    @State private var showOSLogin = false
    @State private var editing: PlaylistSource?

    var body: some View {
        NavigationStack {
            List {
                Section("Afspeellijst") {
                    if let s = playlists.source {
                        HStack(spacing: 14) {
                            AvatarTile(name: "", avatar: s.avatar).frame(width: tvScaled(44))
                            VStack(alignment: .leading) {
                                Text(s.name).font(.headline)
                                Text("\(s.kind.rawValue) · \(playlists.library.channels.count) zenders · \(playlists.library.movies.count) films · \(playlists.library.series.count) series")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        Button { editing = s } label: { Label("Bewerken (naam, avatar, gegevens)", systemImage: "pencil") }
                        Button { Task { await playlists.select(s, forceRefresh: true) } } label: {
                            Label("Nu verversen", systemImage: "arrow.clockwise")
                        }
                    }
                    Button { app.switchPlaylist() } label: { Label("Andere afspeellijst kiezen", systemImage: "rectangle.stack.person.crop") }
                }

                Section {
                    if trakt.isLoggedIn {
                        LabeledContent("Ingelogd als", value: trakt.username ?? "Trakt-gebruiker")
                        LabeledContent("Bekeken", value: "\(trakt.watchedMovies.count) films · \(trakt.watchedEpisodes.values.reduce(0) { $0 + $1.count }) afleveringen")
                        if let d = trakt.lastRefresh {
                            LabeledContent("Laatst gesynchroniseerd", value: d.formatted(date: .omitted, time: .shortened))
                        }
                        Button { Task { await trakt.refresh(force: true) } } label: { Label("Nu synchroniseren", systemImage: "arrow.triangle.2.circlepath") }
                        Button(role: .destructive) { Task { await trakt.logout() } } label: { Label("Uitloggen bij Trakt", systemImage: "rectangle.portrait.and.arrow.right") }
                    } else {
                        Button { showTraktLogin = true } label: { Label("Koppel Trakt", systemImage: "link") }
                            .disabled(!Secrets.isSet(Secrets.traktClientID))
                        if !Secrets.isSet(Secrets.traktClientID) {
                            Text("Vul eerst je Trakt Client ID in Secrets.swift in.").font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    if let e = trakt.lastError { Text(e).font(.caption).foregroundStyle(Theme.red) }
                } header: { Text("Trakt") } footer: {
                    Text("Wat je in Bingr kijkt wordt automatisch gescrobbeld. Wat je op Trakt (of in een andere app) hebt gezien wordt hier afgevinkt.")
                }

                Section {
                    if subs.isLoggedIn {
                        LabeledContent("Ingelogd als", value: subs.username ?? "")
                        if let r = subs.remainingDownloads { LabeledContent("Downloads over vandaag", value: "\(r)") }
                        Button(role: .destructive) { Task { await subs.logout() } } label: { Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right") }
                    } else {
                        Button { showOSLogin = true } label: { Label("Inloggen bij OpenSubtitles", systemImage: "captions.bubble") }
                            .disabled(!Secrets.isSet(Secrets.openSubtitlesAPIKey))
                    }
                    Toggle("Automatisch ondertitels zoeken bij afspelen", isOn: $autoSubtitles)
                    NavigationLink("Talen: \(subs.preferredLanguages.joined(separator: ", "))") { LanguagePicker() }
                } header: { Text("OpenSubtitles") }

                Section {
                    LabeledContent("Afspeellijsten", value: "\(store.playlists.count)")
                    LabeledContent("Kijkvoortgang", value: "\(store.progress.count) titels")
                    if let d = store.lastSync { LabeledContent("Laatste sync", value: d.formatted(date: .omitted, time: .shortened)) }
                } header: { Text("iCloud") } footer: {
                    Text("Afspeellijsten, avatars, favorieten, Mijn lijst, kijkvoortgang en je Trakt/OpenSubtitles-login worden via iCloud gedeeld tussen iPhone, iPad en Apple TV.")
                }

                Section("Over") {
                    LabeledContent("Versie", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("IMDb-gegevens", value: Secrets.isSet(Secrets.omdbAPIKey) ? "Actief (OMDb)" : "Geen OMDb-sleutel")
                }
            }
            .navigationTitle("Mijn Bingr")
        }
        .sheet(isPresented: $showTraktLogin) { TraktLoginView() }
        .sheet(isPresented: $showOSLogin) { OpenSubtitlesLoginView() }
        .sheet(item: $editing) { AddPlaylistView(existing: $0) }
    }
}

struct TraktLoginView: View {
    @EnvironmentObject var trakt: TraktSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TraktDeviceCode?
    @State private var error: String?

    var body: some View {
        VStack(spacing: tvScaled(20)) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: tvScaled(54))).foregroundStyle(Theme.red)
            Text("Koppel je Trakt-account").font(.system(size: tvScaled(22), weight: .bold))
            if let code {
                Text("Ga op je telefoon of computer naar").foregroundStyle(Theme.secondary)
                Text(code.verification_url).font(.system(size: tvScaled(18), weight: .semibold))
                Text("en voer deze code in:").foregroundStyle(Theme.secondary)
                Text(code.user_code).font(.system(size: tvScaled(40), weight: .heavy, design: .monospaced)).kerning(6)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                if let qr = QRCode.image(code.verification_url) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: tvScaled(140), height: tvScaled(140))
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
                #if os(iOS)
                Button("Open trakt.tv/activate") {
                    UIPasteboard.general.string = code.user_code
                    if let u = URL(string: code.verification_url) { openURL(u) }
                }
                Text("De code staat al op je klembord.").font(.caption).foregroundStyle(Theme.secondary)
                #endif
                ProgressView("Wachten op bevestiging…").tint(Theme.red)
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.red).multilineTextAlignment(.center) }
            Button("Annuleer") { dismiss() }.padding(.top)
        }
        .padding(Theme.edge)
        .task {
            do {
                let c = try await trakt.startLogin()
                code = c
                try await trakt.finishLogin(c)
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct OpenSubtitlesLoginView: View {
    @EnvironmentObject var subs: OpenSubtitles
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Gebruikersnaam", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wachtwoord", text: $pass)
                } footer: { Text("Nog geen account? Maak er gratis een aan op opensubtitles.com.") }
                if let error { Text(error).foregroundStyle(Theme.red) }
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await subs.login(username: user, password: pass); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { if busy { ProgressView() } else { Text("Inloggen") } }
                .disabled(user.isEmpty || pass.isEmpty || busy)
            }
            .navigationTitle("OpenSubtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } } }
        }
    }
}

private struct LanguagePicker: View {
    @EnvironmentObject var subs: OpenSubtitles
    var body: some View {
        List(OpenSubtitles.languages, id: \.code) { l in
            Button {
                if let i = subs.preferredLanguages.firstIndex(of: l.code) { subs.preferredLanguages.remove(at: i) }
                else { subs.preferredLanguages.append(l.code) }
            } label: {
                HStack {
                    Text(l.name)
                    Spacer()
                    if let i = subs.preferredLanguages.firstIndex(of: l.code) {
                        Text("\(i + 1)").font(.caption.bold()).padding(6).background(Theme.red, in: Circle())
                    }
                }
            }
        }
        .navigationTitle("Ondertiteltalen")
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
