# Nieuwsbrief (contract)

Een e-mail "wat is nieuw aan films en series" in de huisstijl van Bingr (zwart, rood `#E50914`, het woord BINGR met de
rode streep, geen app-icoon), op **zondag 09:00** en **woensdag 18:00** Nederlandse tijd (`Europe/Amsterdam`, ook bij
zomer- en wintertijd), naar ingeschreven leden. Alles loopt via de Edge Function `newsletter`
(`supabase/functions/newsletter`, workflow *Backend*). **Standaard staat de nieuwsbrief uit**; het beheer zet hem aan.

## Ontvangers

- Ingeschreven = bevestigd e-mailadres, account niet geblokkeerd (`banned_until`) of verwijderd, **geen** `email_opt_out`
  en **geen** `newsletter_opt_out` in `public.account_email_prefs`.
- Nieuwe accounts zijn automatisch ingeschreven: geen opt-in-stap, geen rij in `account_email_prefs` = ingeschreven
  (`newsletter_opt_out boolean not null default false`). De bevestigingsmail zegt er niets extra over.
- **Het beheer (bingr-beheer) leest en zet `public.account_email_prefs.newsletter_opt_out` rechtstreeks** (met de service
  role, upsert op `user_id`). Geabonneerd = geen `email_opt_out` én geen `newsletter_opt_out`. `email_opt_out` (afmelden
  voor alle berichten, functie `admin`) geldt dus ook voor de nieuwsbrief.
- Taal per ontvanger uit `user_metadata.lang` (zoals de andere mails): leeg of `nl…` → Nederlands, elke andere taal → Engels.

## Inhoud (TMDB)

Function-secret `BINGR_TMDB_API_KEY` (gezet door *Backend* uit het GitHub-secret `TMDB_API_KEY` of `TMDB_ACCESS_TOKEN`;
een v3-API-sleutel gaat als `api_key`, een v4-leestoken als `Authorization: Bearer`). TMDB-taal `nl-NL` / `en-US`, regio NL.
Per editie, eenmalig bij het aanmaken vastgelegd in `newsletter_editions.content` (`{nl:{…}, en:{…}}`):

| blok | bron | aantal |
|---|---|---|
| Uitgelicht (achtergrond, titel, omschrijving, knoppen) | eerste titel uit "Nieuw om te kijken" (anders Populair) met achtergrond, die de **vorige 2 edities niet uitgelicht** was | 1 |
| Nieuw om te kijken | `/discover/movie` + `/discover/tv`, `watch_region=NL`, `with_watch_monetization_types=flatrate`, laatste 90 (films) / 120 (series) dagen, om en om, populairste eerst (zoals "Nieuw op Bingr" in `Shared/Metadata/Discover.swift`); titels die de vorige 2 edities niet toonden gaan voor | 6 |
| Binnenkort (met datum) | `/movie/upcoming` (regio NL) + `/discover/tv` met eerste uitzending in de komende 60 dagen; alleen toekomst, op datum | 4 |
| Top 10 deze week (films en series apart, elk 2 rijen van 5 posters met rangnummer, jaar · genre en score) | zoals de rijen "Top 10" in de apps (`TrendingStore` in `Shared/UI/Components/TitleMatcher.swift`): TMDB `/trending/movie/week` en `/trending/tv/week`, aangevuld met Trakt trending (`/movies/trending`, `/shows/trending`, function-secret `BINGR_TRAKT_CLIENT_ID`, poster en titel via TMDB-details) en als terugval TMDB populair (de eigen top uit de bibliotheek van de apps bestaat aan de serverkant niet). Volgorde van de bron, geen dubbele, niets uit de toekomst. Schakelaar `show_top10` | 10 + 10 |
| Populair (3 kolommen, soort · jaar · genre en score) | TMDB `/movie/popular` (regio NL) + `/tv/popular`, om en om, zonder titels die al in deze mail staan (ook niet in de Top 10). Schakelaar `show_popular` | 6 |

**IMDb:** IMDb heeft geen openbare API en scrapen mag niet volgens hun voorwaarden; dat gebeurt dus nergens. De score bij
de Top 10 en Populair is de **IMDb-score via OMDb** (function-secret `BINGR_OMDB_API_KEY`, dezelfde bron als de IMDb-scores
in de apps): IMDb-id uit Trakt of TMDB `/{movie|tv}/{id}/external_ids`, score uit `omdbapi.com/?i=tt…` (hoogstens 40
titels per editie, 5 tegelijk). Zonder OMDb-sleutel, of als OMDb niets geeft: de TMDB-score (`vote_average`, alleen
met minstens 20 stemmen), als "TMDB 7,3". De sectie heet daarom "Populair" en niet "Populair op IMDb". Genres:
TMDB `/genre/movie/list` en `/genre/tv/list` per taal (eerste genre van de titel). Trakt- en OMDb-fouten zijn nooit
fataal (dan zonder die gegevens). Sleutels worden nooit gelogd; de Trakt-client-id gaat alleen in de kop `trakt-api-key`.

**Schakelaars per sectie** (`newsletter_settings.show_top10` / `show_popular`, standaard aan; beheer: actie
`set_sections`): een sectie die uit staat komt niet in een nieuwe editie (bij het aanmaken toegepast, zodat iedereen
dezelfde mail krijgt) en niet in het voorbeeld van de volgende editie. Een editie die al loopt verandert niet.

De keuze wordt op de Nederlandse lijsten gemaakt; de Engelse mail krijgt dezelfde titels met Engelse titel en omschrijving
(geen Engelse omschrijving bekend: zonder omschrijving, nooit Nederlandse tekst). Nooit namen of logo's van
streamingdiensten, geen prijzen. Vaste zin in elke mail: "Bingr levert zelf geen films of series. Of een titel bij jou te
zien is, hangt af van je eigen bron." / "Bingr doesn't provide any movies or series itself. Whether you can watch a title
depends on your own source." Voettekst: afmelden, privacy, support en klein de bronvermelding: altijd "Film- en
seriegegevens: TMDB. Deze mail gebruikt de TMDB API, maar is niet goedgekeurd of gecertificeerd door TMDB."
(TMDB-voorwaarden), en alleen als ze gebruikt zijn "Streaminggegevens: JustWatch." (Nieuw om te kijken),
"Top 10 mede op basis van Trakt." en "IMDb-scores via OMDb." (`content.<taal>.credits`, `{trakt?, omdb?}`).
Alle TMDB-tekst wordt ge-escaped; afbeeldingen alleen van `image.tmdb.org` met een gecontroleerd pad.

## Links naar een titel

Knoppen ("Bekijk in Bingr" / "Meer info"), posters en titels (ook in de Top 10 en Populair) linken naar de universele
link (zonder trackers of persoonsgegevens: alleen `type`, `id`, `q` en `y`)

```
https://bingr.online/titel/?type=movie|tv&id=<tmdb-id>&q=<titel, url-encoded>&y=<jaar>
```

(`y` ontbreekt als het jaar onbekend is.) Is de app geïnstalleerd, dan opent die (Apple universal links via
`bingr.online/.well-known/apple-app-site-association`, appID `EU3UY476T6.nl.lrvdlinden.bingr`, alleen `/titel/*`;
Android app links via `bingr.online/.well-known/assetlinks.json`, package `nl.lrvdlinden.bingr`). De app zoekt de titel in
de bibliotheek op TMDB-id, anders op titel (+ jaar). Zonder app opent `bingr.online/titel/` (build 132: PHP, zie
"Deelpreview"): backdrop, poster, titel, jaar en omschrijving met "Open in Bingr" (`bingr://title?type=movie|tv&id=<tmdb-id>&q=<titel>`),
"Kijk in je browser" (webspeler `https://bingr.online/web/#/titel?type=&id=&q=&y=`) en de TestFlight-/APK-knoppen.
Sinds build 132 stuurt de pagina niet meer vanzelf door naar de webspeler.
De webspeler zoekt na het inloggen (de route blijft bewaard) in de bibliotheek op titel (+ jaar); precies één goede match →
detailpagina, anders het zoekscherm met `q` ingevuld.

## Deelpreview (build 132)

De deelknoppen in alle apps delen dezelfde universele link. Zodat WhatsApp, iMessage, Telegram, Facebook, X, Slack enz. er
een preview van maken (crawlers voeren geen JavaScript uit), rendert `bingr.online/titel/` (`titel/index.php` in
bingr-website, PHP op de hosting) de Open Graph- en Twitter-tags server-side: `og:title` "Titel (jaar)", `og:description`
(omschrijving, ingekort), `og:image` (TMDB-backdrop `w1280`, 1280×720, anders poster `w780`, 780×1170, met
`og:image:width/height`), `og:url` (canonieke link), `og:type` `video.movie` / `video.tv_show`, `og:site_name` Bingr,
`twitter:card` `summary_large_image` en `<title>`. Lukt het ophalen niet, dan de algemene Bingr-preview
(`assets/img/nl/tv_home.jpg`, 1400×788).

De gegevens komen uit de openbare Edge Function `title-meta` (`supabase/functions/title-meta`, workflow *Backend*,
`verify_jwt` uit, CORS `*`). De TMDB-sleutel blijft op de server (function-secret `BINGR_TMDB_API_KEY`, zelfde als de
nieuwsbrief); de website-repo bevat alleen de publieke Supabase-URL.

- `GET /functions/v1/title-meta?type=movie|tv&id=<tmdb-id>` (optioneel `q`, `y`: is het id onbekend, dan zoeken), of
  `?type=movie|tv&q=<titel>&y=<jaar>` (eerste zoekresultaat; zonder treffer met jaar nog één keer zonder jaar).
- 200 `{ok, type, id, year, title:{nl,en}, overview:{nl,en}, poster, backdrop, image:{url,width,height}, url}` (nl-NL,
  terugval en-US). 400 `bad_request` (type niet movie/tv, id niet numeriek, of geen id en geen q), 404 `not_found`,
  405 (alleen GET/HEAD/OPTIONS), 429 `rate_limited` (60 per minuut per bezoeker), 502 `upstream`, 503 `not_configured`.
- `Cache-Control: public, max-age=3600, s-maxage=86400` (404/400: 1 uur); de functie houdt ook 6 uur een cache in het
  geheugen. Geen logging van IP-adressen: de limiet gebruikt alleen een hash met een willekeurig zout per instantie.
- De PHP-pagina vraagt met een timeout van 3 seconden en cachet het antwoord 1 dag in een tmp-bestand op de server
  (mislukt: 10 minuten de terugval).

## Planning en versturen

- pg_cron-taak `bingr-newsletter` (gezet door *Backend*): elk uur op minuut 0 `POST newsletter {action:"cron"}` met
  `x-newsletter-secret: NEWSLETTER_CRON_SECRET`.
- De functie rekent naar `Europe/Amsterdam`. Op zo 09:00 en wo 18:00 (met 2 uur speling als een ronde mislukt) maakt hij de
  editie aan: `newsletter_editions.edition_key` uniek, bv. `2026-10-18-sun` / `2026-10-21-wed` (lokale datum). Eén keer per editie.
- Versturen in batches (`NEWSLETTER_BATCH`, standaard 150 mails per ronde, `NEWSLETTER_PAUSE_MS` = 300 ms tussen mails,
  max. ~110 s per ronde) via `_shared/mail.ts` (SMTP). Is de batch vol, dan verder bij de volgende ronde (elk uur).
  Per (editie, account) één rij in `newsletter_deliveries`: nooit twee mails van dezelfde editie naar hetzelfde account.
  Tijdelijke SMTP-fout (4xx, time-out): batch stopt, die ontvanger later opnieuw (max. 3 pogingen). Een verzending die
  30 minuten op `sending` blijft hangen wordt `failed` (niet opnieuw: liever één mail te weinig dan dubbel).
  Een editie die na 36 uur nog niet klaar is, wordt afgesloten. De wachtrij van edities ouder dan 90 dagen wordt opgeruimd.
- Afzender `From: Bingr <noreply@bingr.online>` (function-secret `BINGR_NEWSLETTER_FROM`, optioneel als GitHub-secret),
  zonder Reply-To (vragen via support.bingr.online, link in de footer). De SMTP-login (`BINGR_SMTP_USER`) moet met dit adres mogen versturen (alias/afzender bij
  de mailhost).
- Uitgezet (`enabled = false`): de cron verstuurt niets, ook niet de rest van een lopende editie.

## Afmelden

- Elke mail heeft `List-Unsubscribe: <https://<ref>.supabase.co/functions/v1/newsletter?unsubscribe=<t>>` en
  `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058) en een zichtbare link
  `https://bingr.online/unsubscribe/?k=news&t=<t>`.
- Token `t` = `<account-id>.<18 bytes HMAC-SHA256, base64url>` met sleutel `bingr-news-unsub-v1|BINGR_SOURCES_KEY` over
  `news-unsub:<account-id>`: zelfde vorm als het afmeldtoken van de berichten (functie `admin`), maar een andere sleutel en
  boodschap, dus ze zijn niet uitwisselbaar. Afmelden zet alleen `newsletter_opt_out = true`.
- `POST newsletter?unsubscribe=<t>` (mailclient) → 200 `unsubscribed` / 400 `invalid link`; `GET` → 303 naar de afmeldpagina.
- `POST newsletter {action:"unsubscribe", t}` (vanaf bingr.online/unsubscribe/?k=news, CORS alleen `https://bingr.online`)
  → `{ok:true}` | 400 `{error:"invalid_token"}` | 429 `{error:"rate_limited"}` (20 per 10 min per IP).
  Zonder `k=news` handelt de pagina het berichten-token af via `admin` (zoals vroeger).

## Beheeracties (functie `admin` in bingr-beheer → `newsletter`)

`POST /functions/v1/newsletter` met header `x-newsletter-secret: NEWSLETTER_ADMIN_SECRET` (function-secret, één keer
aangemaakt door *Backend*; zonder of fout geheim → 403 `{error:"forbidden"}`).

| actie | invoer | antwoord |
|---|---|---|
| `status` | `{}` | `{enabled, sections:{top10, popular}, next:{key, at}, recipients:{nl, en, total}, editions:[{key, created_at, recipients, sent, failed, done}], welcome:{sent_7d, pending} \| null}` (laatste 10 edities, nieuwste eerst; `at` = ISO-tijd in UTC; `welcome` = welkomstmails, alleen aantallen) |
| `set_enabled` | `{enabled: true\|false}` | `{ok, enabled}`; 400 `bad_enabled` |
| `set_sections` | `{top10?: true\|false, popular?: true\|false}` | `{ok, sections:{top10, popular}}`; 400 `bad_sections` (geen of geen boolean). `status` geeft ook `sections:{top10, popular}` |
| `preview` | `{to, lang?: "nl"\|"en"}` | `{ok}`: de huidige editie (die nu verstuurd wordt, anders een concept van de volgende) alleen naar dat adres, onderwerp begint met `[Voorbeeld]`. 400 `bad_email`, 429 `rate_limited` (10 per uur), 503 `smtp_not_configured` / `tmdb_not_configured`, 502 `{error:"send_failed", code}` |
| `render` | `{lang: "nl"\|"en"}` | `{subject, html}` van de huidige editie (zonder aanhef, afmeldlink zonder token) |
| `welcome_preview` | `{to, lang?: "nl"\|"en"}` | `{ok}`: de welkomstmail alleen naar dat adres, onderwerp `[Voorbeeld] …`, aanhef met de voorbeeldnaam *Alex*. Zelfde limiet als `preview` (samen 10 per uur), zelfde fouten |
| `welcome_render` | `{lang: "nl"\|"en"}` | `{subject, html}` van de welkomstmail (voorbeeldnaam, afmeldlink zonder token) |

Fouten: 400 `unknown_action` / `bad_json`, 500 `server_error`. Logs bevatten nooit e-mailadressen, tokens of geheimen,
alleen tellingen en foutcodes (`smtp_550`, `etimedout`, …).

## Welkomstmail

Nieuwe leden krijgen één keer een welkomstmail zodra ze hun e-mailadres hebben bevestigd. Zelfde functie (`newsletter`),
SMTP, huisstijl en afzender (`Bingr <noreply@bingr.online>`, geen Reply-To) als de nieuwsbrief; code in
`supabase/functions/newsletter/welcome.ts`, tests in `welcome_test.ts`.

- **Inhoud** (nl/en, taal uit `user_metadata.lang` zoals de accountmails; aanhef *Hoi <voornaam>,* / *Hi <first name>,*
  als `first_name` bestaat, opgeschoond en ge-escaped): welkom, daarna vijf genummerde stappen met knoppen:
  1. eigen bron toevoegen (Xtream Codes of M3U van je eigen aanbieder) → `https://support.bingr.online/hulp/afspeellijst/`
  2. kijken in de browser → `https://bingr.online/web/`
  3. tv koppelen (QR-code op de tv) → `https://bingr.online/koppelen/`
  4. de apps: iPhone/iPad/Apple TV/Mac via de bèta (`https://testflight.apple.com/join/JW915fdA`), Android/Android TV/Fire TV
     via `https://bingr.online/apk`, Samsung TV binnenkort
  5. hulp → `https://support.bingr.online`

  Daaronder de nieuwsbrief ("twee keer per week (zondag en woensdag) … uitschrijven met één klik onderaan elke nieuwsbrief")
  met een directe uitschrijflink (`https://bingr.online/unsubscribe/?k=news&t=<t>`, hetzelfde afmeldtoken als de
  nieuwsbrief), de vaste zin "Bingr levert zelf geen zenders, films of series. Je kijkt wat je eigen bron aanbiedt." en de
  voettekst (reden, bingr.online, support, privacy). Nooit de naam of link van een aanbieder, geen prijzen.
- **Nieuwsbriefalinea alleen als die klopt:** de alinea (en `List-Unsubscribe`) staat alleen in de mail als de nieuwsbrief
  aan staat (`newsletter_settings.enabled`) én het lid ingeschreven is (`bingr_news_subscribed`). Voorbeeld en weergave in
  het beheer tonen hem altijd.
- **Keuze `email_opt_out`:** de welkomstmail is transactioneel (de bevestiging dat hun account klaar is) en gaat dus ook als
  `email_opt_out` aan staat; dan zonder de nieuwsbriefalinea. Niet naar geblokkeerde (`banned_until` in de toekomst) of
  verwijderde accounts.
- **Versturen:** pg_cron-taak `bingr-welcome` (gezet door *Backend*) elke 5 minuten `POST newsletter {action:"welcome_cron"}`
  met `x-newsletter-secret: NEWSLETTER_CRON_SECRET` → `{ok, smtp, sent, failed, retry, errors}`. Los van de aan/uit-knop van
  de nieuwsbrief. Per ronde max. 50 mails (`bingr_welcome_take`), 300 ms pauze, max. ~100 s. Ontvangers: `email_confirmed_at`
  in de laatste 7 dagen en nog geen rij in `account_welcome`. De claim is een rij in `account_welcome` (primaire sleutel
  `user_id`, dus nooit twee welkomstmails). Tijdelijke SMTP-fout of niet aan toegekomen: de rij gaat weg en de volgende ronde
  probeert opnieuw (binnen de 7 dagen); blijvende fout: `error = smtp_5xx`, niet opnieuw; een claim die 30 minuten blijft
  hangen wordt `stuck` (niet opnieuw: liever geen mail dan twee).
- **Eerste uitrol:** het schema maakt `account_welcome` aan en markeert in dezelfde stap alle bevestigde accounts als
  `error = 'existing'` (geen welkomstmail aan bestaande leden). Daarna doet dat blok niets meer.
- **Beheer:** `status.welcome = {sent_7d, pending}` (alleen aantallen), `welcome_preview` en `welcome_render` (zie de tabel
  hierboven); in bingr-beheer de acties `welcome_preview` / `welcome_render` en het blok *Welkomstmail* in de tab Nieuwsbrief.

## Eigen mailing vanuit het beheer

Naast de automatische nieuwsbrief kan de beheerder in het beheer (bingr-beheer, tab **Nieuwsbrief**, blok *Eigen mailing*;
ook in de app BingrBeheer) zelf een mail opstellen en versturen. Zelfde functie (`newsletter`), SMTP, huisstijl
(`_shared/layout.ts`: zwart, BINGR met rode streep) en afzender `Bingr <noreply@bingr.online>`, zonder Reply-To; elke mail
heeft een tekstversie, een eigen `Message-ID` (`<bingr-mailing-<id>.<willekeurig>@bingr.online>`) en `Date`.
Code: `supabase/functions/newsletter/mailing.ts` (logica, opmaak, mail), tests `mailing_test.ts` (deno) en
`supabase/tests/mailing_test.sh` (doelgroep en wachtrij op Postgres); beide blokkeren de deploy in *Backend*.

### Opstellen

- Onderwerp NL + EN (max. 150 tekens), tekst NL + EN (max. 8000 tekens per taal), optioneel een afbeelding (https-URL,
  bovenaan, 500 px breed) en een knop (tekst NL + EN, max. 40 tekens, en één https-URL).
- Afbeelding: uploaden in het beheer (openbare bucket `mail-assets` in `supabase/schema.sql`: PNG, JPEG of GIF tot 2 MB,
  schrijven alleen via de functie `admin` met de service role, willekeurige bestandsnaam) of een directe link. De functie
  `admin` controleert een link vóór voorbeeld, testmail en versturen (https, openbare host, max. 3 doorverwijzingen,
  content-type en inhoud PNG/JPEG/GIF, max. 2 MB; SVG, WebP, webpagina's en deellinks van Drive/iCloud/Dropbox geweigerd).
  In de mail staat de afbeelding zonder achtergrond en met `height:auto` en een korte alt-tekst (onderwerp, max. 60 tekens),
  zodat een afbeelding die toch niet laadt geen groot donker vlak geeft. De workflow Backend meldt (stap *Eigen mailing -
  afbeeldingen van recente mailings*) per recente mailing alleen de soort probleem, nooit de URL.
- Opmaak (markdown-achtig, alles wordt ge-escaped; geen eigen HTML of stijlen): lege regel = nieuwe alinea, `# Kop`,
  `## Kleinere kop`, `**vet**`, `[linktekst](https://…)` en losse `https://`-links, `- punt` / `* punt` (opsomming),
  `1. punt` (genummerd). Alleen https-links en -afbeeldingen (geen http, javascript:, IP-adressen of inloggegevens in de URL).
- Aanhef *Hoi <voornaam>,* / *Hi <first name>,* als het account een voornaam heeft (zoals de nieuwsbrief).

### Doelgroep

| doelgroep | wie | afmelden |
|---|---|---|
| `newsletter` **Nieuwsbrief-abonnees** (standaard) | bevestigd adres, niet geblokkeerd/verwijderd, geen `email_opt_out` en geen `newsletter_opt_out` (zelfde regels als de nieuwsbrief) | `List-Unsubscribe` (1 klik, RFC 8058) + zichtbare afmeldlink `bingr.online/unsubscribe/?k=news&t=…` (zelfde token als de nieuwsbrief) |
| `service` **Servicebericht aan alle gebruikers** | álle accounts met een bevestigd adres die niet geblokkeerd of verwijderd zijn, ook wie zich voor de nieuwsbrief of alle berichten afmeldde | geen `List-Unsubscribe`; voettekst legt uit waarom ("Je krijgt dit servicebericht omdat je een Bingr-account hebt …"); label *Servicebericht* in de kop |

Een servicebericht is **alleen** voor belangrijke service-informatie (wijziging van voorwaarden of privacyverklaring,
storingen, beveiliging, einde van een functie), **nooit voor reclame of nieuws** (AVG en art. 11.7 Telecommunicatiewet:
reclame per e-mail alleen aan wie zich niet heeft afgemeld). Het beheer toont een waarschuwing en vraagt een extra
bevestiging; de functie weigert `service` zonder `service_ack: true` (400 `service_ack_required`).
Geblokkeerde (`banned_until` in de toekomst), verwijderde, onbevestigde accounts en accounts zonder adres krijgen nooit een mailing.

Taal per ontvanger uit `user_metadata.lang`: leeg of `nl…` → NL-versie, elke andere taal → EN-versie.

### Versturen

1. **Voorbeeld** (`mailing_render`): de mail in NL of EN in het beheer (met de voorbeeldnaam *Alex*).
2. **Testmail** (`mailing_test`): naar één adres dat de beheerder invult (NL, EN of beide; onderwerp `[Test] …`; zelfde
   kopregels als de echte verzending). Het adres wordt niet bewaard en niet gelogd. Limiet gedeeld met de andere
   voorbeelden (samen 10 per uur).
3. **Versturen** (`mailing_send`): het beheer toont eerst een bevestiging met het aantal ontvangers per taal. Daarna legt
   `bingr_mailing_create` de ontvangers één keer vast in `mailing_recipients` (primaire sleutel mailing + account: iedereen
   hoogstens één mail per mailing). Dezelfde `request_id` (uuid per verzendopdracht uit het beheer) geeft de bestaande
   mailing terug in plaats van een tweede (dubbelklik, opnieuw proberen). Hoogstens één mailing tegelijk (409 `mailing_busy`);
   zonder ontvangers 409 `no_recipients`.
4. **Wachtrij**: pg_cron-taak `bingr-mailing` (gezet door *Backend*) elke 5 minuten (minuut 2, 7, …)
   `POST newsletter {action:"mailing_cron"}` met `x-newsletter-secret: NEWSLETTER_CRON_SECRET`. Per ronde max.
   `MAILING_BATCH` (standaard 50) mails, 300 ms pauze, ~100 s; **max. `MAILING_PER_HOUR` per uur** (standaard **200**, alle
   mailings samen, verstuurd + mislukt in het laatste uur; function-secret, optioneel als GitHub-secret `MAILING_PER_HOUR`,
   10–2000). Vlak voor het versturen wordt de doelgroep opnieuw gecontroleerd: wie zich intussen afmeldde (bij `newsletter`)
   of geblokkeerd/verwijderd werd, wordt overgeslagen (`skipped`). Tijdelijke SMTP-fout (4xx, time-out): ronde stopt, die
   ontvanger later opnieuw (max. 3 pogingen); blijvende fout: `failed`. Een rij die 30 minuten op `sending` blijft wordt
   `failed` en niet opnieuw verstuurd (liever één mail te weinig dan dubbel).
   Voorbeeld: 1.000 abonnees bij 200 per uur ≈ 5 uur.
5. **Voortgang en annuleren**: het beheer toont verstuurd / mislukt / overgeslagen / te gaan en kan annuleren zolang de
   mailing niet klaar is (`mailing_cancel`): wat nog in de wachtrij staat gaat niet meer; een batch die op dat moment loopt
   maakt zijn mails af.
6. **Klaar**: `status = done`; de cron van de functie `push` stuurt de beheer-app één keer "Mailing verstuurd (x ontvangers)"
   (soort `mailing`, voorkeur `mailings`, link `bingrbeheer://newsletter`).

Geschiedenis: `mailings` bewaart per mailing de inhoud (onderwerp, tekst), doelgroep, datum en aantallen; het beheer toont
alleen onderwerpen en aantallen, nooit adressen. De ontvangerslijst (`mailing_recipients`, alleen account-id, taal en status)
wordt 90 dagen na afloop opgeruimd.

### Acties (`x-newsletter-secret: NEWSLETTER_ADMIN_SECRET`, via de functie `admin`)

| actie | invoer | antwoord |
|---|---|---|
| `mailing_status` | `{}` | `{active, mailings:[{id, created_at, finished_at, audience, status: sending\|done\|cancelled, subject:{nl, en}, recipients:{nl, en, total}, sent, failed, skipped, cancelled, left}], audiences:{newsletter:{nl, en, total}, service:{…}}, per_hour, batch, sent_last_hour}` (laatste 20) |
| `mailing_render` | `{content, audience, lang}` | `{subject, html}`; 400 `bad_*` |
| `mailing_test` | `{to, content, audience, lang: nl\|en\|both}` | `{ok, sent}`; 400 `bad_email` / `bad_*`, 429 `rate_limited`, 502 `send_failed`, 503 `smtp_not_configured`. Ook met de mailtest-header (Diagnose), dan alleen naar `support+ci-…@bingr.online` |
| `mailing_send` | `{request_id, content, audience, service_ack?}` | `{ok, id, duplicate, recipients:{nl, en, total}}`; 400 `bad_*` / `service_ack_required`, 409 `mailing_busy` / `no_recipients` |
| `mailing_cancel` | `{id}` | `{ok, cancelled}`; 409 `not_active` |

`content` = `{nl:{subject, body, button}, en:{subject, body, button}, image, button_url}`. Fouten bij de invoer:
`bad_content`, `bad_subject_nl|en`, `bad_body_nl|en`, `bad_button_text_nl|en`, `bad_image_url`, `bad_button_url`, `bad_audience`.

### Database

`mailings` (`id`, `request_id` uniek, `audience`, `content` jsonb, `status`, `recipients`, `recipients_nl`, `recipients_en`,
`sent`, `failed`, `skipped`, `cancelled`, `created_at`, `finished_at`, `push_notified_at`; unieke index: hoogstens één met
status `sending`) en `mailing_recipients` (`mailing_id`, `user_id`, `lang`, `state` queued/sending/sent/failed/skipped/cancelled,
`attempts`, `claimed_at`, `done_at`; primaire sleutel (mailing, account)). Functies `bingr_mailing_audience`,
`bingr_mailing_eligible`, `bingr_mailing_count`, `bingr_mailing_create`, `bingr_mailing_take`, `bingr_mailing_mark`,
`bingr_mailing_cancel`, `bingr_mailing_sent_last_hour`, `bingr_mailing_open`, `bingr_mailing_cleanup` (alleen service role).
RLS aan, alles ingetrokken voor anon en authenticated.

## Database (`supabase/schema.sql`)

- `account_email_prefs.newsletter_opt_out boolean not null default false`
- `newsletter_settings` (`id = 1`, `enabled` standaard `false`)
- `newsletter_editions` (`id`, `edition_key` uniek, `created_at`, `content` jsonb, `recipients`, `sent`, `failed`, `cursor`, `finished_at`)
- `newsletter_deliveries` (`edition_id`, `user_id`, `state` queued/sending/sent/failed/skipped, `attempts`, …), primaire sleutel (editie, account)
- functies `bingr_news_subscribed`, `bingr_news_recipients`, `bingr_news_take`, `bingr_news_mark`, `bingr_news_cleanup`
  (alleen service role). RLS aan, alles ingetrokken voor anon en authenticated.
- `account_welcome` (`user_id` pk → `auth.users` on delete cascade, `claimed_at`, `sent_at`, `error`) en de functies
  `bingr_welcome_take`, `bingr_welcome_mark`, `bingr_welcome_counts` (alleen service role). RLS aan, ingetrokken voor anon en
  authenticated.
