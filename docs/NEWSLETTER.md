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
de bibliotheek op TMDB-id, anders op titel (+ jaar). Zonder app opent `bingr.online/titel/`: die toont de titel met
"Open in de app" (`bingr://title?type=movie|tv&id=<tmdb-id>&q=<titel>`) en "Kijk in je browser", en stuurt door naar de
webspeler `https://bingr.online/web/#/titel?type=&id=&q=&y=` (op een computer meteen, op telefoon/tablet na 3 seconden).
De webspeler zoekt na het inloggen (de route blijft bewaard) in de bibliotheek op titel (+ jaar); precies één goede match →
detailpagina, anders het zoekscherm met `q` ingevuld.

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
  `Reply-To: support@bingr.online`. De SMTP-login (`BINGR_SMTP_USER`) moet met dit adres mogen versturen (alias/afzender bij
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
| `status` | `{}` | `{enabled, next:{key, at}, recipients:{nl, en, total}, editions:[{key, created_at, recipients, sent, failed, done}]}` (laatste 10 edities, nieuwste eerst; `at` = ISO-tijd in UTC) |
| `set_enabled` | `{enabled: true\|false}` | `{ok, enabled}`; 400 `bad_enabled` |
| `preview` | `{to, lang?: "nl"\|"en"}` | `{ok}`: de huidige editie (die nu verstuurd wordt, anders een concept van de volgende) alleen naar dat adres, onderwerp begint met `[Voorbeeld]`. 400 `bad_email`, 429 `rate_limited` (10 per uur), 503 `smtp_not_configured` / `tmdb_not_configured`, 502 `{error:"send_failed", code}` |
| `render` | `{lang: "nl"\|"en"}` | `{subject, html}` van de huidige editie (zonder aanhef, afmeldlink zonder token) |

Fouten: 400 `unknown_action` / `bad_json`, 500 `server_error`. Logs bevatten nooit e-mailadressen, tokens of geheimen,
alleen tellingen en foutcodes (`smtp_550`, `etimedout`, …).

## Database (`supabase/schema.sql`)

- `account_email_prefs.newsletter_opt_out boolean not null default false`
- `newsletter_settings` (`id = 1`, `enabled` standaard `false`)
- `newsletter_editions` (`id`, `edition_key` uniek, `created_at`, `content` jsonb, `recipients`, `sent`, `failed`, `cursor`, `finished_at`)
- `newsletter_deliveries` (`edition_id`, `user_id`, `state` queued/sending/sent/failed/skipped, `attempts`, …), primaire sleutel (editie, account)
- functies `bingr_news_subscribed`, `bingr_news_recipients`, `bingr_news_take`, `bingr_news_mark`, `bingr_news_cleanup`
  (alleen service role). RLS aan, alles ingetrokken voor anon en authenticated.
