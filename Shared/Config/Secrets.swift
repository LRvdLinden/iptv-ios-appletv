import Foundation

/// Vul hier je eigen developer-sleutels in (zie README.md, stap 2).
/// Dit zijn app-sleutels, géén persoonlijke inloggegevens: inloggen bij Trakt en
/// OpenSubtitles gebeurt in de app zelf.
enum Secrets {
    /// https://trakt.tv/oauth/applications/new  — Redirect URI: urn:ietf:wg:oauth:2.0:oob
    static let traktClientID = "VUL_TRAKT_CLIENT_ID_IN"
    static let traktClientSecret = "VUL_TRAKT_CLIENT_SECRET_IN"

    /// https://www.opensubtitles.com/consumers  — maak een "API consumer" aan
    static let openSubtitlesAPIKey = "VUL_OPENSUBTITLES_API_KEY_IN"

    /// https://www.omdbapi.com/apikey.aspx  — IMDb-gegevens (score, poster, plot, cast)
    static let omdbAPIKey = "VUL_OMDB_API_KEY_IN"

    static let userAgent = "Bingr v1.0.0"

    static func isSet(_ v: String) -> Bool { !v.hasPrefix("VUL_") && !v.isEmpty }
}
