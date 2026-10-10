# Bingr

Native IPTV-app voor **iPhone, iPad en Apple TV** met de look & feel van Netflix.
SwiftUI · iOS 17+ · tvOS 17+ · VLC-engine.

## Functies

- **Geanimeerde splash** ("tudum"-stijl: vallende letters, rode gloed, lichtlinten, zoom-in)
- **Afspeellijst-kiezer** in Netflix-profielstijl: elke afspeellijst heeft een eigen **naam en avatar** (icoon + kleur)
- Bronnen: **M3U/M3U8 + XMLTV-EPG**, **Xtream Codes** (incl. catch-up/terugkijken), **Stalker/MAC-portal**
- **iCloud-sync** tussen iPhone, iPad en Apple TV: afspeellijsten, avatars, favorieten, Mijn lijst, kijkvoortgang (iCloud Key-Value Store) en wachtwoorden + Trakt/OpenSubtitles-login (iCloud-sleutelhanger)
- **Netflix-UI**: billboard, rijen per categorie, Top 10, Verder kijken, Mijn lijst, detailpagina met seizoenen/afleveringen
- **IMDb**: score, plot, cast, regie, genres (via OMDb, op IMDb-ID) + link naar IMDb
- **Trailers** (YouTube, via Trakt): in-app op iOS, YouTube-app op Apple TV
- **Trakt, 2 kanten op**
  - inloggen met koppelcode + QR (werkt ook op Apple TV)
  - wat je op Trakt/elders hebt gezien → **vinkjes in Bingr**
  - afvinken in Bingr (film, aflevering, heel seizoen) → **Trakt-history**
  - automatisch **scrobblen** tijdens afspelen, Trakt-voortgang = hervatten
  - Mijn lijst ↔ Trakt-watchlist, Top 10 = Trakt trending in jouw afspeellijst
- **OpenSubtitles**: inloggen met je account, zoeken op IMDb-ID (+ seizoen/aflevering), taalvoorkeur, automatisch ondertitels laden
- **Player (VLC)**: .ts / .mkv / HLS, audio- en ondertitelsporen, snelheid, beeldverhouding, slaaptimer, zappen ↑↓ bij live TV
- **Live TV** (UHF/IPTV+-stijl): groepen, favorieten, recent, nu/straks uit de EPG, gids per zender met terugkijken

## Installeren

1. **Project genereren** (op een Mac):
   ```bash
   brew install xcodegen
   xcodegen
   open Bingr.xcodeproj
   ```
2. **API-sleutels** invullen in `Shared/Config/Secrets.swift` (allemaal gratis):
   | Dienst | Waar aanmaken | Let op |
   |---|---|---|
   | Trakt | https://trakt.tv/oauth/applications/new | Redirect URI: `urn:ietf:wg:oauth:2.0:oob` |
   | OpenSubtitles | https://www.opensubtitles.com/consumers | "API consumer" aanmaken |
   | IMDb-gegevens (OMDb) | https://www.omdbapi.com/apikey.aspx | gratis: 1000 verzoeken/dag; titels worden gecachet |
3. **Signing**: kies in Xcode je Team voor beide targets (`Bingr` en `BingrTV`).
4. **iCloud**: zet bij beide targets de capability *iCloud → Key-value storage* aan (staat al in de entitlements) en houd dezelfde Team-ID aan, dan delen iOS en tvOS automatisch dezelfde data.

## Structuur

```
Shared/
  App/            app-start, AppState (splash → kiezer → app)
  Models/         playlist, zender, film, serie, EPG
  Providers/      M3U-, XMLTV-, Xtream- en Stalker-clients + cache
  Metadata/       IMDb (OMDb) + titels opschonen
  Trakt/          login, sync, scrobble, trending
  OpenSubtitles/  login, zoeken, downloaden
  Player/         VLC-player + bedieningspanelen
  Storage/        iCloud KV-store + iCloud-sleutelhanger
  UI/             Netflix-thema, kaarten, schermen
iOS/  tvOS/       iconen, Info.plist & entitlements (gegenereerd door XcodeGen)
```

## Opmerkingen

- IMDb heeft geen gratis publieke API; daarom IMDb-gegevens via OMDb en trailers/IMDb-ID's via Trakt.
- Bingr is een speler: je gebruikt je eigen, legale afspeellijsten.
