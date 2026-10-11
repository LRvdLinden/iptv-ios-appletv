# Bingr

[![Build](https://github.com/LRvdLinden/iptv-ios-appletv/actions/workflows/build.yml/badge.svg)](https://github.com/LRvdLinden/iptv-ios-appletv/actions/workflows/build.yml)

Native IPTV- en mediaspeler voor **iPhone, iPad, Mac en Apple TV** met de look & feel van Netflix.
SwiftUI · iOS 17+ · tvOS 17+ · Apple- én VLC-engine · 11 talen.

## Screenshots

> Ontwerp-previews van de schermen (gerenderd vanuit `docs/mockups/mockups.html`, met fictieve titels en zenders). Worden vervangen door echte simulator-screenshots zodra de app draait.

### iPhone

| Splash | Afspeellijst kiezen | Home |
|:---:|:---:|:---:|
| <img src="docs/screenshots/ios_splash.png" width="240"> | <img src="docs/screenshots/ios_picker.png" width="240"> | <img src="docs/screenshots/ios_home.png" width="240"> |
| **Details** | **Details: scores, cast, aanbevelingen** | **Live TV** |
| <img src="docs/screenshots/ios_detail.png" width="240"> | <img src="docs/screenshots/ios_detail2.png" width="240"> | <img src="docs/screenshots/ios_live.png" width="240"> |
| **Tv-gids** | **Top 10 (Netflix-stijl)** | **Bekijk allemaal** |
| <img src="docs/screenshots/ios_guide.png" width="240"> | <img src="docs/screenshots/ios_top10.png" width="240"> | <img src="docs/screenshots/ios_category.png" width="240"> |
| **Afspeellijst toevoegen** | **Mijn Bingr** | **Categorieën aan/uit** |
| <img src="docs/screenshots/ios_add.png" width="240"> | <img src="docs/screenshots/ios_settings.png" width="240"> | <img src="docs/screenshots/ios_categories.png" width="240"> |

### Apple TV

| Home | Afspeellijst kiezen |
|:---:|:---:|
| <img src="docs/screenshots/tv_home.png" width="420"> | <img src="docs/screenshots/tv_picker.png" width="420"> |
| **Serie + afleveringen** | **Live TV** |
| <img src="docs/screenshots/tv_detail.png" width="420"> | <img src="docs/screenshots/tv_live.png" width="420"> |
| **Tv-gids** | **Multiview** |
| <img src="docs/screenshots/tv_guide.png" width="420"> | <img src="docs/screenshots/tv_multiview.png" width="420"> |
| **Trakt koppelen** | |
| <img src="docs/screenshots/tv_trakt.png" width="420"> | |

## Functies

**Bronnen**
- M3U/M3U8 + XMLTV-EPG, **Xtream Codes** (incl. catch-up), **Stalker/MAC-portal**
- **Plex** (inloggen met code op plex.tv/link), **Jellyfin**, **Emby** (films, series, live TV + gids)
- **Stremio**: inloggen met je Stremio-account of eigen add-on-URL's (Cinemeta-catalogi, directe streams)
- Afspeellijst-kiezer in Netflix-profielstijl met eigen **naam en avatar of profielfoto** (uit je fotobibliotheek) per lijst
- **Zoeken in al je afspeellijsten** tegelijk, ook in de **tv-gids** (nu, straks en terugkijken)
- **NAS via SMB/DLNA**: servers op je netwerk worden gevonden, of voeg zelf een SMB-share toe; bladeren en afspelen

**Kijken**
- Twee engines: **Apple (AVPlayer)** voor HLS/MP4 met **HDR, Dolby Vision, Dolby Atmos** en automatisch juiste schermmodus op Apple TV; **VLC** voor .ts, .mkv, AC3/DTS en de rest. Automatisch kiezen of zelf instellen
- **AirPlay** en **Chromecast** (zonder extra SDK), **beeld-in-beeld** op iPhone, iPad en Apple TV
- **Standaard audio- en ondertiteltaal** (automatisch gekozen als de stream ze heeft)
- **Automatisch herverbinden** bij haperende of weggevallen streams (met terugval naar de andere engine)
- **Timeshift**: live tv pauzeren en terugspoelen (HLS-venster of catch-up), knop "terug naar live"
- **Multiview**: tot 4 streams tegelijk, geluid van het geselecteerde beeld
- Audio- en ondertitelsporen, **OpenSubtitles** (zoeken op IMDb-ID of titel, taal kiezen tijdens het kijken, standaardtaal + automatisch laden), snelheid, beeldverhouding, slaaptimer, zappen ↑↓

**Gids & beheer**
- **Tv-gids als raster** met nu-lijn, programma-details, **terugkijken** en **herinneringen** (melding op iPhone/iPad, banner op Apple TV)
- **Live TV** opent op "Alle zenders"; favorieten, recent en alle groepen
- **Categorieën aan/uit** per Live TV, Films en Series, met snelknoppen per land/taal (NL, BE, DE, TK …)
- **Beheren**: groepen en zenders hernoemen, herschikken, samenvoegen en verbergen
- **Kinderslot** met pincode: groepen op slot, volwassenengroepen automatisch, **leeftijdsgrens per profiel** (IMDb-classificatie), 30 min ontgrendelen
- **Kijkgeschiedenis per profiel**, per dag, met verwijderen en wissen
- **Weergave**: startscherm kiezen en tabbladen verbergen; alle keuzes als dropdown

**Detailpagina (UHF-stijl)**
- Grote afbeelding met titel-logo, score, jaar en speelduur/seizoenen
- Eén knop "Speel seizoen 2: aflevering 4" (gaat verder waar je was), Mijn lijst, trailer, afvinken
- **Andere bronnen**: dezelfde titel in andere groepen of afspeellijsten
- Afleveringen als kaarten met foto, voortgang, vinkje, beschrijving en uitzenddatum
- Beoordelingen (IMDb, Trakt), cast met foto's en rol, aanbevelingen (direct afspelen als ze in je lijst staan)
- Werkt zonder sleutels met de info van je Xtream-server; IMDb, Trakt en TMDB vullen aan

**Netflix-ervaring**
- Geanimeerde splash, profielkeuze met ronde avatars (op Apple TV vergroot de geselecteerde), billboard, rijen
- **Top 10 zoals Netflix** (grote omlijnde cijfers, Trakt trending in jouw lijst) onder Voor jou: series en films op Home, films bij Films, series bij Series
- **Verder kijken** (verwijderbaar, zonder live tv), **Voor jou** (vergelijkbaar met wat je keek), Mijn lijst
- **Bekijk allemaal** bij elke rij: categoriepagina met sorteren (A–Z, nieuwste, score) en IMDb-score per poster
- **IMDb**-score, plot, cast (via OMDb) en **trailers** (via Trakt)
- **Trakt, 2 kanten op**: koppelcode + QR, vinkjes uit Trakt in de app, afvinken in de app → Trakt, scrobblen, watchlist

**Overal hetzelfde**
- **iCloud-sync** tussen iPhone, iPad, Mac en Apple TV: afspeellijsten, avatars, favorieten, Mijn lijst, kijkvoortgang, herinneringen, aanpassingen en kinderslot; logins via de iCloud-sleutelhanger
- **11 talen**: Engels, Nederlands, Duits, Frans, Spaans, Italiaans, Portugees, Turks, Pools, Arabisch (rechts-naar-links) en Chinees. Volgt de systeemtaal of kies zelf in Mijn Bingr
- **Mac**: draait als iPad-app op Apple-silicon-Macs

## Installeren

1. **Project genereren** (op een Mac):
   ```bash
   brew install xcodegen
   xcodegen
   open Bingr.xcodeproj
   ```
2. **Sleutels inbouwen (aanbevolen, privé-repo)**: zet ze als *Settings → Secrets and variables → Actions*: `OPENSUBTITLES_API_KEY`, `TMDB_API_KEY` (of `TMDB_ACCESS_TOKEN`), `OMDB_API_KEY`, `TRAKT_CLIENT_ID` (en `TRAKT_CLIENT_SECRET` alleen bij oude Trakt-apps; nieuwe apps gebruiken PKCE zonder secret). De CI bouwt ze in en de zip op `ci-logs` bevat ze; gebruikers loggen dan alleen nog met hun eigen account in.

   Of **koppelingen instellen** in de app: *Mijn Bingr → Koppelingen instellen* (eenmalig, gratis). Trakt en OpenSubtitles eisen dat elke app zich één keer registreert; daarna log je gewoon in met je eigen account. De sleutels staan in de iCloud-sleutelhanger, dus je Apple TV heeft ze ook, en ze komen niet in deze openbare repo:
   | Dienst | Waar aanmaken | Let op |
   |---|---|---|
   | Trakt | https://trakt.tv/oauth/applications/new | Redirect URI: `https://github.com/LRvdLinden/iptv-ios-appletv` (inloggen gaat met een code, er wordt nooit doorgestuurd) |
   | OpenSubtitles | https://www.opensubtitles.com/consumers | "API consumer" aanmaken |
   | IMDb-gegevens (OMDb) | https://www.omdbapi.com/apikey.aspx | gratis: 1000 verzoeken/dag; titels worden gecachet |
   | TMDB (optioneel) | https://www.themoviedb.org/settings/api | foto's van cast, titel-logo's, afleveringsfoto's, teksten in jouw taal |
3. **Signing**: kies in Xcode je Team voor beide targets (`Bingr` en `BingrTV`).
4. **iCloud**: zet bij beide targets de capability *iCloud → Key-value storage* aan (staat al in de entitlements) en houd dezelfde Team-ID aan.

Elke push naar `main` wordt door GitHub Actions gebouwd voor iOS en tvOS (simulator, zonder signing). Het build-rapport staat op de branch `ci-logs`.

## Vertalingen

Alle teksten staan in de code in het Engels (`L("Play")`) en worden vertaald via `Shared/Resources/Translations.json`.
`python3 tools/extract_strings.py` controleert of elke tekst in elke taal vertaald is en of de `%@`/`%d`-codes kloppen (draait ook in CI).

## Structuur

```
Shared/
  App/            app-start, AppState (splash → kiezer → app), herinneringsbanner
  Models/         playlist, zender, film, serie, EPG
  Providers/      M3U, XMLTV, Xtream, Stalker, Plex, Jellyfin/Emby, Stremio + cache en aanpassingen
  Metadata/       IMDb (OMDb) + titels opschonen
  Trakt/          login, sync, scrobble, trending
  OpenSubtitles/  login, zoeken, downloaden
  Player/         Apple/VLC-engines, Chromecast, AirPlay, multiview, panelen
  Storage/        iCloud KV-store, iCloud-sleutelhanger, kinderslot, herinneringen
  Localization/   taalsysteem (L())
  Resources/      Translations.json
  UI/             Netflix-thema, kaarten, schermen (home, live, gids, beheren, zoeken, instellingen)
iOS/  tvOS/       iconen, Info.plist & entitlements (gegenereerd door XcodeGen)
tools/            vertaalcontrole
```

## Opmerkingen

- IMDb heeft geen gratis publieke API; daarom IMDb-gegevens via OMDb en trailers/IMDb-ID's via Trakt.
- Niet overgenomen van UHF: **VPN-koppeling** (vereist afspraken met VPN-aanbieders en een speciale Apple-toestemming — gebruik gewoon je eigen VPN-app) en **opnemen (DVR)** (vereist een aparte server-app thuis; catch-up dekt veel daarvan).
- Bingr is een speler: je gebruikt je eigen, legale afspeellijsten en mediaservers.
