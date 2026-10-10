import SwiftUI

/// Eenmalig instellen: de app-sleutels die Trakt en OpenSubtitles vereisen.
/// Daarna log je gewoon in met je eigen account. Opgeslagen in de iCloud-sleutelhanger,
/// dus je Apple TV, iPad en Mac hebben ze meteen ook.
struct ConnectionsSetupView: View {
    enum Focus { case trakt, openSubtitles, all }
    var focus: Focus = .all
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var traktID = Secrets.traktClientID
    @State private var traktSecret = Secrets.traktClientSecret
    @State private var osKey = Secrets.openSubtitlesAPIKey
    @State private var omdb = Secrets.omdbAPIKey
    @State private var tmdb = Secrets.tmdbAPIKey

    private let traktURL = "https://trakt.tv/oauth/applications/new"
    private let osURL = "https://www.opensubtitles.com/consumers"
    private let redirect = "urn:ietf:wg:oauth:2.0:oob"

    var body: some View {
        NavigationStack {
            Form {
                if focus != .openSubtitles {
                    Section {
                        step(1, L("Open the Trakt page below and sign in with your Trakt account."))
                        link(traktURL)
                        step(2, L("Name: Bingr. Redirect URI: paste the text below. Leave the rest empty and save."))
                        copyRow(redirect)
                        step(3, L("Copy the Client ID and Client Secret into the fields below."))
                        TextField("Client ID", text: $traktID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Client Secret", text: $traktSecret).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Trakt") } footer: {
                        Text(L("Trakt requires every app to register once. After that you simply sign in with your Trakt account."))
                    }
                }
                if focus != .trakt {
                    Section {
                        step(1, L("Open the OpenSubtitles page below and sign in with your account."))
                        link(osURL)
                        step(2, L("Create a new consumer called Bingr and copy the API key into the field below."))
                        TextField("API key", text: $osKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("OpenSubtitles") } footer: {
                        Text(L("Then sign in with your OpenSubtitles username and password."))
                    }
                }
                if focus == .all {
                    Section {
                        TextField(L("OMDb key (IMDb scores)"), text: $omdb).textInputAutocapitalization(.never).autocorrectionDisabled()
                        link("https://www.omdbapi.com/apikey.aspx")
                        TextField(L("TMDB key (cast photos, logos)"), text: $tmdb).textInputAutocapitalization(.never).autocorrectionDisabled()
                        link("https://www.themoviedb.org/settings/api")
                    } header: { Text(L("Optional")) }
                }
            }
            .navigationTitle(L("Set up connections"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save")) { save() } }
            }
        }
    }

    private func save() {
        Secrets.set(.traktClientID, traktID)
        Secrets.set(.traktClientSecret, traktSecret)
        Secrets.set(.openSubtitlesAPIKey, osKey)
        Secrets.set(.omdbAPIKey, omdb)
        Secrets.set(.tmdbAPIKey, tmdb)
        dismiss()
        onDone()
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 22, height: 22).background(Theme.red, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    @ViewBuilder private func link(_ url: String) -> some View {
        #if os(iOS)
        Button { if let u = URL(string: url) { openURL(u) } } label: {
            Label(url.replacingOccurrences(of: "https://", with: ""), systemImage: "safari")
        }
        #else
        HStack(spacing: 20) {
            if let qr = QRCode.image(url) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(url.replacingOccurrences(of: "https://", with: "")).font(.system(size: 26, weight: .semibold))
        }
        #endif
    }

    private func copyRow(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.body, design: .monospaced))
            Spacer()
            #if os(iOS)
            Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
            #endif
        }
    }
}
