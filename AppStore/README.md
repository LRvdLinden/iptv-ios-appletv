# Bingr — App Store Connect-pakket 1.0.5 (build 166)

Alles voor App Store Connect voor **Bingr** (`nl.lrvdlinden.bingr`) op iPhone, iPad, Apple TV en Mac.
Niets hiervan is gepubliceerd: uploaden doet Léon zelf.

## Inhoud
| Map / bestand | Wat |
|---|---|
| `app-info.md` | algemene info, categorie, content rights, leeftijdsclassificatie, privacylabel, toegankelijkheid |
| `metadata/` | teksten per taal (fastlane-deliver-indeling): `nl-NL/`, `en-US/`, copyright en categorieën |
| `metadata/privacy/` | privacytekst NL/EN (samenvatting) en de tekst voor het Apple TV-privacyveld |
| `metadata/review_information/` | `notes.txt` (Engels, voor App Review → Notes), `notes-nl.txt` (alleen ter referentie), contact en demo-account (alleen TODO's) |
| `screenshots/<taal>/` | `iphone-6.3` (1206×2622), `iphone-6.1` (1179×2556), `ipad-13` (2064×2752), `appletv` (3840×2160 en 1920×1080), `mac` (2880×1800 en 1440×900) |
| `marketing/<taal>/` | header 5244×2950 en 3840×1646, zoekresultaat 5244×2950, 3840×2560 en 1920×1280 |
| `generator/` | bron van de afbeeldingen (`render.py`, `page.html`, `ui.js`, `art.js`); opnieuw maken: `python3 AppStore/generator/render.py` |

## Talen van de afbeeldingen
De app heeft 11 talen; de afbeeldingen zijn er in **nl-NL** en **en-US** (standaard van de skill bij meer dan twee
talen). De andere talen van de winkelpagina tonen de en-US-set als je die als standaard instelt.

## Screenshots (volgorde)
- iPhone en iPad: 1 Home · 2 Nieuwe tv-gids met live beeld · 3 Seizoenen en afleveringen · 4 Wie kijkt er? · 5 Categorieën · 6 Werkt op al je apparaten (met "Gebruik je eigen IPTV-abonnement")
- Apple TV: 1 Home · 2 Tv-gids (build 166) · 3 Detail · 4 Profielen · 5 Categorieën · 6 Inloggen met je telefoon
- Mac: 1 Home · 2 Tv-gids · 3 Detail · 4 Categorieën · 5 Alle apparaten

**Het zijn getrouwe recreaties, geen simulatoropnames.** De schermen zijn in HTML nagebouwd naar de SwiftUI-code
(o.a. `Shared/UI/Screens/GuideView.swift` en `LiveTVView.swift` voor de tv-gids van build 164–166) en met Chromium
gerenderd. Alle titels, zenders, programma's en beelden zijn verzonnen en zelfgetekend: geen posters of afbeeldingen van
TMDB/IMDb, geen echte film- of serietitels, geen echte zendernamen of -logo's, geen IMDb-logo (score als ster), geen
landcodes tussen streepjes, geen prijs of koopknop. Rijen met Lifetime-functies (Verder kijken, statistieken, pincode)
staan er niet in.

De oude afbeeldingen in `docs/screenshots/` (mockups met echte covers, 1290×2796) en `docs/appstore/out/` (oude tv-gids,
IMDb-logo, "NL | Series") zijn niet gebruikt.

## Uploadlijst
1. App Store Connect → Bingr → nieuwe versie **1.0.5**, build 166 (iOS, tvOS en macOS).
2. Per taal (nl-NL, en-US): naam, ondertitel, promotietekst, beschrijving, trefwoorden, "Wat is er nieuw", URL's uit `metadata/<taal>/`.
3. Screenshots uit `screenshots/<taal>/` per apparaat (6,3"/6,1" iPhone, 13" iPad, Apple TV, Mac).
4. Marketing: header- en zoekresultaatafbeeldingen uit `marketing/<taal>/` (alleen als ASC erom vraagt).
5. App-informatie, leeftijd, privacylabel en toegankelijkheid volgens `app-info.md`; Apple TV-privacytekst uit `metadata/privacy/`.
6. App Review Information: notities uit `metadata/review_information/notes.txt`, contact en demo-account invullen (TODO's).
7. Pas indienen na Léons eigen test.

## Open TODO's
- Telefoon en e-mail voor App Review (`review_information/phone_number.txt`, `email_address.txt`).
- Demo-account in App Store Connect (Sign-In Information), **met een testserver met legaal af te spelen streams en Lifetime** — de notities gaan daarvan uit. Nooit in deze repo.
- Keuze leeftijdsclassificatie (zie `app-info.md`).
- `Shared/PrivacyInfo.xcprivacy` aanvullen in een volgende Apple-build (zie `app-info.md`).
