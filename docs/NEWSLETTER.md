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
| Populair deze week | `/trending/all/week` (films en series, geen personen) | 5 |

De keuze wordt op de Nederlandse lijsten gemaakt; de Engelse mail krijgt dezelfde titels met Engelse titel en omschrijving
(geen Engelse omschrijving bekend: zonder omschrijving, nooit Nederlandse tekst). Nooit namen of logo's van
streamingdiensten, geen prijzen. Vaste zin in elke mail: "Bingr levert zelf geen films of series. Of een titel bij jou te
zien is, hangt af van je eigen bron." / "Bingr doesn't provide any movies or series itself. Whether you can watch a title
depends on your own source." Voettekst: afmelden, privacy, support en klein "Film- en seriegegevens: TMDB" (TMDB-voorwaarden).
Alle TMDB-tekst wordt ge-escaped; afbeeldingen alleen van `image.tmdb.org` met een gecontroleerd pad.

## Links naar een titel

Knoppen ("Bekijk in Bingr" / "Meer info"), posters en titels linken naar de universele link

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
| `status` | `{}` | `{enabled, next:{key, at}, recipients:{nl, en, total}, editions:[{key, created_at, recipients, sent, failed, done}], welcome:{sent_7d, pending} \| null}` (laatste 10 edities, nieuwste eerst; `at` = ISO-tijd in UTC; `welcome` = welkomstmails, alleen aantallen) |
| `set_enabled` | `{enabled: true\|false}` | `{ok, enabled}`; 400 `bad_enabled` |
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
