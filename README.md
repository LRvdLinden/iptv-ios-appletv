# Bingr

[![Build](https://github.com/LRvdLinden/iptv-ios-appletv/actions/workflows/build.yml/badge.svg)](https://github.com/LRvdLinden/iptv-ios-appletv/actions/workflows/build.yml)

Native IPTV- en mediaspeler voor **iPhone, iPad, Mac en Apple TV** met de look & feel van Netflix.
SwiftUI · iOS 17+ · tvOS 17+ · macOS 14+ · Apple- én VLC-engine · 11 talen.

Wat er nieuw is per build: [CHANGELOG.md](CHANGELOG.md) · [bingr.online/changelog](https://bingr.online/changelog/)

## Screenshots

> Ontwerp-previews van de schermen (gerenderd vanuit `docs/mockups/mockups.html`, met fictieve titels en zenders). Worden vervangen door echte simulator-screenshots zodra de app draait.

### iPhone

| Splash | Wie kijkt er? | Home |
|:---:|:---:|:---:|
| <img src="docs/screenshots/ios_splash.png" width="240"> | <img src="docs/screenshots/ios_picker.png" width="240"> | <img src="docs/screenshots/ios_home.png" width="240"> |
| **Details** | **Details: scores, cast, aanbevelingen** | **Live TV** |
| <img src="docs/screenshots/ios_detail.png" width="240"> | <img src="docs/screenshots/ios_detail2.png" width="240"> | <img src="docs/screenshots/ios_live.png" width="240"> |
| **Tv-gids** | **Top 10 (Netflix-stijl)** | **Bekijk allemaal** |
| <img src="docs/screenshots/ios_guide.png" width="240"> | <img src="docs/screenshots/ios_top10.png" width="240"> | <img src="docs/screenshots/ios_category.png" width="240"> |
| **Server toevoegen** | **Mijn Bingr** | **Categorieën aan/uit** |
| <img src="docs/screenshots/ios_add.png" width="240"> | <img src="docs/screenshots/ios_settings.png" width="240"> | <img src="docs/screenshots/ios_categories.png" width="240"> |

### Apple TV

| Home | Wie kijkt er? |
|:---:|:---:|
| <img src="docs/screenshots/tv_home.png" width="420"> | <img src="docs/screenshots/tv_picker.png" width="420"> |
| **Serie + afleveringen** | **Live TV** |
| <img src="docs/screenshots/tv_detail.png" width="420"> | <img src="docs/screenshots/tv_live.png" width="420"> |
| **Tv-gids** | **Multiview** |
| <img src="docs/screenshots/tv_guide.png" width="420"> | <img src="docs/screenshots/tv_multiview.png" width="420"> |
| **Trakt koppelen** | |
| <img src="docs/screenshots/tv_trakt.png" width="420"> | |

### Mac

<img src="docs/screenshots/mac_home.png" width="720">

## Functies

**Account**
- **Verplicht inloggen** met een Bingr-account (e-mail + wachtwoord), zoals Netflix: splash → inlogscherm → "Wie kijkt er?". Met een geldige sessie ga je meteen door; account maken, wachtwoord vergeten, uitloggen en account verwijderen in de app (Mijn Bingr → Account)
- **QR-koppeling op Apple TV**: scan de QR-code met je telefoon of ga naar **bingr.online/koppelen** en voer de code in; of log op de tv in met e-mail. Op iPhone, iPad en Mac koppel je een tv met *Mijn Bingr → Account → Tv koppelen*
- **Profielen bij je account**: bij de eerste login worden je bestaande profielen aan je account gekoppeld (niets gaat verloren) en gedeeld met de Android-app. Pincodes gaan versleuteld mee met je account; eigen profielfoto's worden via je Bingr-account gedeeld met al je apparaten (ook Android)
- **Maximaal 15 apparaten per account** (de limiet komt van de server): elk apparaat registreert zich na het inloggen. Zit je aan de limiet, dan verwijder je eerst een ander apparaat ("Too many devices"). Onder *Mijn Bingr → Account → Apparaten* zie je alle gekoppelde apparaten (ook op Apple TV) met platform (iPhone, iPad, Mac, Apple TV, Android, Android-tablet, Android TV, Google TV, Fire TV), koppeldatum, laatst gebruikt en sinds wanneer het is ingelogd. Je geeft elk apparaat (ook dit apparaat) met **Naam wijzigen** een eigen naam (ook op bingr.online/account), of verwijdert er een. Een verwijderd apparaat wordt automatisch uitgelogd
- **Tegelijk kijken per abonnement** (Gratis 1, Lifetime 3; los van de limiet van je IPTV-provider): de speler meldt elke stream aan bij je account (ook bij zappen, de volgende aflevering en Multiview, dat als één stream telt) en pingt elke 30 s. Is de limiet bereikt, dan zie je "Too many people are watching" met wie er kijkt. Het hoofdprofiel ziet in *Mijn Bingr → Account* wie er nu kijkt en de kijkgeschiedenis van 7 dagen
- De sessie staat alleen op dit apparaat (sleutelhanger zonder iCloud-sync); offline blijft de app gewoon werken
- **Profielen (toevoegen, wijzigen, verwijderen) synchroniseren met al je apparaten** via je Bingr-account
- **Servers en afspeellijsten bij je account**: ze worden versleuteld bij je account bewaard (inclusief wachtwoorden, tokens en je categorieën en groepen), dus na updaten of opnieuw installeren staat alles weer klaar
- **Alles bij je account**: alles (Trakt, OpenSubtitles, instellingen, Mijn lijst, voortgang, bekeken, pincodes, herinneringen) gaat versleuteld mee met je account. Na opnieuw installeren of op een nieuw apparaat staat alles na inloggen weer klaar
- **Trakt en OpenSubtitles: gewoon inloggen**, de sleutels komen veilig van de Bingr-server

**Bronnen**
- M3U/M3U8 + XMLTV-EPG, **Xtream Codes** (incl. catch-up), **Stalker/MAC-portal**
- **Plex** (inloggen met code op plex.tv/link), **Jellyfin**, **Emby** (films, series, live TV + gids)
- **Stremio**: inloggen met je Stremio-account of eigen add-on-URL's (Cinemeta-catalogi, directe streams)
- **Eén hoofdaccount, meerdere profielen**: alleen het hoofdaccount (rood rondje met poppetje) stelt de server, Trakt, OpenSubtitles, kinderslot en categorieën in en maakt profielen aan. Elk profiel gebruikt dezelfde server maar heeft **volledig eigen gegevens**: Mijn lijst, Verder kijken, Voor jou, favorieten, bekeken, kijkgeschiedenis en leeftijdsgrens (Trakt hoort bij het hoofdaccount). Eigen **naam, avatar (icoon, een van 16 getekende figuurtjes of een eigen foto)**, eigen **pincode** en eigen kijkvoorkeuren (automatische ondertitels, ondertitel- en audiotaal) per profiel. Wisselen via je avatar of Mijn Bingr
- **Zoeken in al je afspeellijsten** tegelijk: films, series, zenders, **categorieën** en de **tv-gids** (nu, straks en terugkijken). Ook via het vergrootglas op Home, Films en Series, en dan altijd door álle content
- **NAS via SMB/DLNA**: servers op je netwerk worden gevonden, of voeg zelf een SMB-share toe; bladeren en afspelen

**Kijken**
- Twee engines: **Apple (AVPlayer)** voor HLS/MP4 met **HDR, Dolby Vision, Dolby Atmos** en automatisch juiste schermmodus op Apple TV; **VLC** voor .ts, .mkv, AC3/DTS en de rest. Automatisch kiezen of zelf instellen
- **AirPlay** en **Chromecast** (zonder extra SDK), **beeld-in-beeld** op iPhone, iPad en Apple TV
- **Standaard audio- en ondertiteltaal** (automatisch gekozen als de stream ze heeft)
- **Automatisch herverbinden** bij haperende of weggevallen streams (met terugval naar de andere engine); geen stream gevonden → duidelijke melding met "Opnieuw" in plaats van een eindeloze spinner
- **Volgende aflevering** zoals Netflix: knop in de laatste 45 seconden en automatisch door naar de volgende (ook over seizoenen heen); "Verder kijken" pakt de laatst bekeken aflevering
- **Timeshift**: live tv pauzeren en terugspoelen (HLS-venster of catch-up), knop "terug naar live"
- **Multiview**: tot 4 streams tegelijk, geluid van het geselecteerde beeld
- **Ondertitelgrootte** (klein, middel, groot; ook tijdens het kijken), audio- en ondertitelsporen, **OpenSubtitles** (zoeken op IMDb-ID of titel, taal kiezen tijdens het kijken met vlaggen, standaardtaal + automatisch laden, timing verschuiven, ook niet-UTF-8-bestanden), snelheid, beeldverhouding, slaaptimer, zappen ↑↓

**Gids & beheer**
- **Tv-gids als raster** met nu-lijn, programma-details, **terugkijken** en **herinneringen** (melding op iPhone/iPad, banner op Apple TV)
- **Live TV** opent op "Alle zenders"; favorieten, recent en alle groepen. **Zoeken op Live TV** (iPhone, iPad én Apple TV) zoekt altijd door álle zenders: op naam, zendernummer, groep en wat er nu speelt
- Tv-gids-raster blijft vlot bij duizenden zenders (toont de eerste 150 van een groep, 1 uur terug t/m 13 uur vooruit)
- **Categorieën aan/uit** per Live TV, Films en Series, met snelknoppen per land/taal (NL, BE, DE, TK …)
- **Servers** toevoegen, wisselen, wijzigen en verwijderen (hoofdaccount)
- **Beheren**: groepen en zenders hernoemen, herschikken, samenvoegen en verbergen (op Apple TV via selecteren of vasthouden)
- **Pincode** per profiel (op Apple TV een compacte rij cijfers die op elk scherm past), en met de pincode van het hoofdaccount het kinderslot: groepen op slot, volwassenengroepen automatisch, **leeftijdsgrens per profiel** (IMDb-classificatie), 30 min ontgrendelen (daarna automatisch weer op slot). Een titel boven de grens met pincode afspelen ontgrendelt alleen díe titel, niet de hele bibliotheek
- **Kinderprofiel** (krijgt meteen een vrolijk figuurtje, zonder "Kids"-label bij de naam): alleen kinderzenders, tekenfilms/familie en titels met een bekende leeftijd binnen de grens (standaard t/m 12), met een eigen **Top 10 voor kids**. Bij grenzen t/m 12 jaar wordt streng gefilterd (onbekend = verborgen)
- **Gezien per profiel, ook zonder Trakt**: Bingr houdt zelf bij wat elk profiel (hoofdaccount én subprofielen) heeft gezien — vinkjes op films en afleveringen en "X GEZIEN" op series, ook als de afleveringen pas later laden
- **Kijkgeschiedenis per profiel**, per dag, met verwijderen en wissen
- **Mijn Bingr** zoals "Mijn Netflix": je profiel bovenaan (tik om te wisselen), met Verder kijken en Mijn lijst; op iPhone je profielfoto als tabbladicoon
- **Weergave**: startscherm kiezen, tabbladen verbergen, intromuziek aan/uit; alle keuzes als dropdown
- **Speler op Apple TV**: klik = bediening, ←/→ = 10 s spoelen, ↑/↓ = zappen; in de bediening navigeer je vrij naar pauze, spoelen, audio & ondertitels en opties (blijft zichtbaar zolang je rondkijkt)
- **Apple TV-bediening** zonder grijze vlakken: geselecteerde posters worden groter, knoppen wit (zoals Netflix)

**Detailpagina (UHF-stijl)**
- Grote afbeelding met titel-logo, score, jaar en speelduur/seizoenen
- Eén knop "Speel seizoen 2: aflevering 4" (gaat verder waar je was), Mijn lijst, trailer, afvinken
- **Andere bronnen**: dezelfde titel in andere groepen of afspeellijsten
- **Delen**: deelknop bij films en series (WhatsApp, iMessage, Instagram, Facebook, Mail …) met een link naar IMDb (of Trakt/TMDB) en een tekst als "Serietip: Reacher (2022)"; vasthouden = link kopiëren. Op Apple TV een QR-code om met je telefoon te scannen
- Afleveringen als kaarten met foto, voortgang, vinkje, beschrijving en uitzenddatum
- Beoordelingen (IMDb, Trakt), cast met foto's en rol, aanbevelingen (direct afspelen als ze in je lijst staan)
- **Pagina per acteur/actrice** (Netflix-stijl, ook op Apple TV en Mac): tik op iemand uit de cast voor een grote foto, bio, geboortedatum en alle films en series. Wat in je afspeellijst staat ("Beschikbaar in Bingr") kijk je direct; de rest toont korte info. Bij **Zoeken op naam** verschijnt ook een rij **Personen** (TMDB). Kinderprofielen zien alleen toegestane titels uit hun lijst
- Werkt zonder sleutels met de info van je Xtream-server; IMDb, Trakt en TMDB vullen aan

**Netflix-ervaring**
- Geanimeerde splash met een eigen **Bingr-intro-tune** (`tools/make_tune.py`, uit te zetten), profielkeuze met ronde avatars (op Apple TV vergroot de geselecteerde), billboard, rijen
- **Top 10 zoals Netflix** (grote omlijnde cijfers; trending vandaag via TMDB en Trakt, gekoppeld aan jouw lijst, anders je best beoordeelde titels) onder Voor jou: series en films op Home, films bij Films, series bij Series
- **Verder kijken** met voortgangsbalk en resterende tijd; aantikken geeft de keuze **Hervatten (vanaf 23:14)** of **Opnieuw bekijken** (verwijderbaar, zonder live tv), **Voor jou** (vergelijkbaar met wat je keek)
- **Mijn lijst** (hartje op de detailpagina): films én series op Home en in Mijn Bingr, per profiel; bij het hoofdaccount loopt de Trakt-watchlist mee. Favoriete zenders staan ook in Mijn Bingr
- **Bekijk allemaal** bij elke rij: categoriepagina met sorteren (A–Z, nieuwste, score) en IMDb-score per poster
- **IMDb**-score, plot, cast (via OMDb) en **trailers** (via Trakt)
- **Trakt, 2 kanten op**: koppelcode + QR, vinkjes uit Trakt in de app (ook bij IPTV-titels als "NL | Reacher (2022) 4K"), afvinken in de app → Trakt, scrobblen (vanaf 80% gezien; titels zonder IMDb-ID worden bij Trakt opgezocht), watchlist. Na het kijken worden de vinkjes direct bijgewerkt. In de speler zie je kort of Trakt meekijkt; Mijn Bingr toont de sync-status (draaiende pijltjes tijdens synchroniseren) en wat er het laatst is doorgegeven. Lukt scrobblen niet, dan zet Bingr de titel direct in je Trakt-geschiedenis

**Overal hetzelfde**
- **iCloud-sync** tussen iPhone, iPad, Mac en Apple TV: server(s), profielen met foto, per profiel favorieten, Mijn lijst en kijkvoortgang, herinneringen, aanpassingen en kinderslot; logins via de iCloud-sleutelhanger
- **11 talen**: Engels, Nederlands, Duits, Frans, Spaans, Italiaans, Portugees, Turks, Pools, Arabisch (rechts-naar-links) en Chinees. Volgt de systeemtaal of kies zelf in Mijn Bingr
- **Alle Apple TV's met apps**: Apple TV HD (4e generatie) en alle Apple TV 4K-modellen (tvOS 17+); schermen passen binnen de veilige marge van elke tv (ook bij overscan)
- **Meerdere Apple TV-gebruikers**: wissel je van gebruiker op de Apple TV, dan zie je de Bingr (playlists, voortgang, Trakt) van díe gebruiker via zijn eigen iCloud
- **Eigen Mac-app** (macOS 14+, Apple silicon én Intel): zelfde functies en iCloud-sync, met VLC voor .ts/.mkv, AirPlay, Chromecast en beeld-in-beeld. Bediening met het toetsenbord: spatie = pauze, ←/→ = 10 s, ↑/↓ = zappen, Esc = sluiten

## Website (bingr.online)

Op [bingr.online](https://bingr.online) vind je de downloads, de [hulppagina](https://support.bingr.online/hulp/) (ook voor installeren), de webspeler [bingr.online/web](https://bingr.online/web/) en [bingr.online/koppelen](https://bingr.online/koppelen/) om een tv aan je account te koppelen. De broncode van de site staat in [LRvdLinden/bingr-website](https://github.com/LRvdLinden/bingr-website).

## Android

De Android-versie (telefoon, tablet, Android TV / Google TV / Fire TV) staat in een eigen repo: [LRvdLinden/bingr-android](https://github.com/LRvdLinden/bingr-android).

## Opmerkingen

- IMDb heeft geen gratis publieke API; daarom IMDb-gegevens via OMDb en trailers/IMDb-ID's via Trakt.
- Niet overgenomen van UHF: **VPN-koppeling** (vereist afspraken met VPN-aanbieders en een speciale Apple-toestemming — gebruik gewoon je eigen VPN-app) en **opnemen (DVR)** (vereist een aparte server-app thuis; catch-up dekt veel daarvan).
- Bingr is een speler: je gebruikt je eigen, legale afspeellijsten en mediaservers.
