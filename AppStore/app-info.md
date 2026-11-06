# Bingr — App-informatie voor App Store Connect (versie 1.0.5, build 166)

Alles hieronder is afgeleid uit de code van build 166 (`project.yml`, `Shared/PrivacyInfo.xcprivacy`, `Shared/Account/*`,
`docs/ACCOUNT.md`) en de privacyverklaring op bingr.online. Velden die alleen Léon kan invullen staan als **TODO**.

## Algemene informatie (General Information)

| Veld | Waarde |
|---|---|
| Name | Bingr: IPTV-speler (nl-NL) / Bingr: IPTV Player (en-US) — of de huidige naam in ASC houden |
| Bundle ID | `nl.lrvdlinden.bingr` (iOS/iPadOS, tvOS en macOS: één app-record, universele aankoop) |
| SKU | `nl.lrvdlinden.bingr` (of de bestaande SKU in ASC) |
| Apple ID | 6821401598 (apps.apple.com/nl/app/bingr/id6821401598) |
| Team ID | EU3UY476T6 |
| Versie / build | 1.0.5 / 166 (iOS, tvOS en macOS) |
| Primary Language | Dutch (nl-NL) |
| App-talen | Engels, Nederlands, Duits, Frans, Spaans, Italiaans, Portugees, Turks, Pools, Arabisch, Chinees (vereenvoudigd) — `CFBundleLocalizations` |
| Platforms | iPhone, iPad (iOS 17+), Apple TV (tvOS 17+), Mac (macOS 14+, eigen native app). Geen Apple Watch, geen Vision Pro |
| Primary category | **Entertainment** — app voor live tv, films en series kijken (komt overeen met `LSApplicationCategoryType`) |
| Secondary category | **Photo & Video** — het is een videospeler |
| Copyright | © 2026 PixelForges (verkoper/verantwoordelijke volgens de juridische pagina's; in `project.yml` staat nog "© 2026 Bingr") |
| License Agreement | Apple Standard EULA (aanvullend gelden bingr.online/voorwaarden/) |
| Support URL | https://support.bingr.online |
| Marketing URL | https://bingr.online |
| Privacy Policy URL | https://bingr.online/privacy.html |
| Encryptie | `ITSAppUsesNonExemptEncryption = false` (alleen standaard-HTTPS) |

### Content Rights
**Does your app contain, show, or access third-party content? → Yes.**
- Bingr bevat zelf geen content. Het speelt streams af van bronnen die de gebruiker zelf toevoegt (eigen IPTV-abonnement, M3U, Xtream Codes, MAC-portal, eigen mediaserver); de gebruiker is verantwoordelijk voor de rechten daarop (richtlijn 5.2.3).
- Titelinformatie en afbeeldingen in de app komen van de TMDB-API (bronvermelding in Instellingen > Over; gebruik volgens de API-voorwaarden van TMDB). Streamingdata: JustWatch (bronvermelding in Over). Trailers via YouTube.
- Geen TMDB/IMDb-posters of echte titels in de winkelafbeeldingen: alles in `screenshots/` en `marketing/` is fictief en zelfgetekend.

### Age Rating (vragenlijst)
Bingr levert zelf geen content; alle vragen over geweld, seks, grof taalgebruik, drugs, gokken, horror enz. → **None**.
- Unrestricted Web Access: **No** (geen browser in de app; trailers via de YouTube-speler, links naar eigen sites).
- User-Generated Content / chat: **No** (support-tickets zijn alleen tussen gebruiker en Bingr-support).
- Messaging, Gambling, Contests, Medical: **No**. Parental Controls: **Yes** (kinderprofielen met leeftijdsgrens en pincode).
- **TODO (keuze Léon):** gebruikers kunnen zelf elke stream laden, ook volwassenencontent van hun eigen aanbieder. Apple vraagt bij IPTV-spelers soms een hogere leeftijd; overweeg *Age Rating Override* → 18+ als App Review daarom vraagt.

## App Privacy (privacylabel)

**Tracking: No** (geen ATT, geen advertenties, geen analytics-SDK's; `NSPrivacyTracking = false`).
Externe SDK's: alleen VLCKit (afspelen, verzamelt niets). Geen Firebase, geen crash-SDK, geen advertentie-SDK.

| Datatype (ASC) | Verzameld | Gekoppeld aan gebruiker | Tracking | Doel | Waar in de code |
|---|---|---|---|---|---|
| Contact Info › Name | Ja | Ja | Nee | App Functionality | voor- en achternaam bij account maken (`/auth/v1/signup`) |
| Contact Info › Email Address | Ja | Ja | Nee | App Functionality | inloggen, account, support |
| User Content › Photos or Videos | Ja (optioneel) | Ja | Nee | App Functionality | eigen profielfoto (`uploadPhoto`) |
| User Content › Customer Support | Ja | Ja | Nee | App Functionality | support-tickets in de app |
| User Content › Other User Content | Ja | Ja | Nee | App Functionality | profielen, servers (versleuteld), lijsten, collecties |
| Identifiers › User ID | Ja | Ja | Nee | App Functionality | account-id |
| Identifiers › Device ID | Ja | Ja | Nee | App Functionality | eigen `device_id` (UUID) per apparaat, apparaatbeheer en schermlimiet |
| Usage Data › Product Interaction | Ja | Ja | Nee | App Functionality | wat er gekeken wordt (`stream_start`), kijkgeschiedenis 8 dagen, statistieken |
| Location › Coarse Location | Ja (alleen landcode uit het netwerk, geen IP) | Ja | Nee | Analytics | landoverzicht in het beheer |
| Diagnostics › Crash Data / Other Diagnostic Data | Ja (alleen als de gebruiker het zelf meestuurt bij een ticket) | Ja | Nee | App Functionality | Diagnose in Support |

Niet verzameld: precieze locatie, contacten, gezondheid, financiële info, browsegeschiedenis, zoekgeschiedenis (zoeken gebeurt lokaal/naar de eigen server), audio, gevoelige info.
Aankopen: Lifetime wordt buiten de app gekocht (website); de app leest alleen het abonnement van het account en verzamelt geen aankoopgegevens.

> **TODO (code, niet in dit pakket aangepast):** `Shared/PrivacyInfo.xcprivacy` noemt nu alleen Email Address en User ID.
> Voor een kloppend manifest horen daar ook Name, Device ID, Product Interaction, Customer Support, Other User Content,
> Photos or Videos, Coarse Location en (optioneel) Crash/Diagnostic Data bij — in een volgende Apple-build.

Privacyteksten: `metadata/privacy/` (NL/EN samenvatting en de korte tekst voor het **Apple TV Privacy Policy**-veld).

## App Accessibility (Accessibility Nutrition Labels)

Alleen geclaimd wat in de code is na te gaan:

| Functie | iPhone | iPad | Mac | Apple TV | Reden |
|---|---|---|---|---|---|
| Dark Interface | ✓ | ✓ | ✓ | ✓ | de app is altijd donker (`UIUserInterfaceStyle: Dark`) |
| VoiceOver | niet geclaimd | niet geclaimd | niet geclaimd | niet geclaimd | labels op veel knoppen (o.a. tv-gids), maar niet alle schermen nagelopen |
| Voice Control | niet geclaimd | niet geclaimd | niet geclaimd | – | niet getest |
| Larger Text | niet geclaimd | niet geclaimd | niet geclaimd | – | vaste lettergroottes (`.system(size:)`) |
| Differentiate Without Color Alone | niet geclaimd | niet geclaimd | niet geclaimd | niet geclaimd | NU heeft tekst + kleur, maar niet overal nagelopen |
| Sufficient Contrast | niet geclaimd | niet geclaimd | niet geclaimd | niet geclaimd | niet gemeten |
| Reduced Motion | niet geclaimd | niet geclaimd | niet geclaimd | niet geclaimd | deels (achtergrondbeweging en vinkje), niet overal |
| Captions / Audio Descriptions | n.v.t. | n.v.t. | n.v.t. | n.v.t. | Bingr heeft geen eigen content; ondertitels van de stream en via OpenSubtitles zijn wel af te spelen |

## Abonnementen en betalen
- Geen in-app-aankopen, geen prijzen, geen koopknoppen, geen links of QR-codes naar betalen in de Apple-apps (`upgrade.link.apple = false`).
- Lifetime wordt alleen op de website verkocht (Stripe, PixelForges) en werkt in de Apple-apps via het account.
- Beschrijving en screenshots noemen geen prijs; Lifetime staat alleen neutraal in de beschrijving.
