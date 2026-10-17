# Pushmeldingen (contract)

Bingr verstuurt echte systeem-pushmeldingen zelf (geen externe pushdienst, geen script van derden): APNs voor Apple,
FCM (HTTP v1) voor Android, standaard Web Push (VAPID) voor de webspeler. Alles loopt via de Edge Function `push`
(`supabase/functions/push`, workflow *Backend*). Het beheer (bingr-beheer, functie `admin`) stuurt via `push` met het
geheim `PUSH_ADMIN_SECRET` (header `x-push-secret`), net zoals `support` met SUPPORT_ADMIN_SECRET.

## Platforms

| platform (`platform`)  | kanaal  | systeem-push | opmerking |
|---|---|---|---|
| `ios`, `ipados`        | apns    | ja  | toestemming vragen (UNUserNotificationCenter) |
| `macos`                | apns    | ja  | zelfde bundle-ID nl.lrvdlinden.bingr |
| `tvos`                 | —       | nee | tvOS toont geen meldingen: niet registreren |
| `android`              | fcm     | ja  | Android 13+: POST_NOTIFICATIONS vragen |
| `androidtv`            | —       | nee | geen meldingen in beeld op TV: niet registreren |
| `tizen`                | —       | nee | geen push voor zelf geïnstalleerde apps |
| `web`                  | webpush | ja  | service worker in /web; iPhone/iPad alleen als web-app op het beginscherm |

Waar geen systeem-push is, blijft alles zoals nu (lokale herinneringen in de app). Nergens een eigen in-app venster als
vervanging voor push; de in-app banners voor beheerberichten (Announcements) verdwijnen.

## Apparaat registreren (app → `push`, ingelogd: `Authorization: Bearer <access_token>` + `apikey`)

POST `/functions/v1/push` met JSON:
- `{action:"register", device_id, platform, channel:"apns"|"fcm"|"webpush", token, lang, app_version, app_build, sandbox?, tz?}` → `{ok}`
  - `token`: APNs-devicetoken (hex) | FCM-registratietoken | Web Push-subscription als JSON-string (`endpoint`, `keys.p256dh`, `keys.auth`).
  - `sandbox: true` voor debug-builds van Apple (APNs development).
  - `lang`: app-taal (`nl`, `en`, `de`, …). Opnieuw registreren bij taalwissel, nieuwe token, nieuwe build.
  - `tz` (optioneel): IANA-tijdzone van het apparaat (`Europe/Amsterdam`), voor de tijd in de herinneringstekst. Ontbreekt hij: Europe/Amsterdam.
  - `device_id`: hetzelfde id als bij device-auth `register_device` (dan ruimt het verwijderen van dat apparaat de push-registratie mee op).
  - Upsert op (user_id, device_id); een token die al bij een ander account hoort, gaat over naar dit account.
  - Fouten: 401 `not_signed_in`/`user_banned`; 400 `no_push_platform` (tvos/androidtv/tizen), `bad_platform`, `bad_channel`,
    `bad_token` (Web Push alleen naar bekende pushdiensten: fcm.googleapis.com, *.push.services.mozilla.com, *.push.apple.com,
    *.notify.windows.com), `bad_device_id`; 429 `rate_limited` (20 per account per minuut); 409 `too_many_devices` (30 per account).
- `{action:"unregister", device_id}` — bij uitloggen, push uitzetten in de app of toestemming ingetrokken.
- `{action:"vapid_key"}` (zonder inloggen) → `{key}` publieke VAPID-sleutel (base64url) voor de webspeler.
- Apparaat verwijderen uit het account (device-auth / beheer) en account verwijderen ruimen push_devices mee op (cascade).

## Berichten (payload naar de app)

Elke push heeft `title`, `body` en `data`:
- `data.kind`: `release` | `admin` | `reminder`
- `data.url`: universele link om te openen (altijd https, publieke fallback); ontbreekt alleen bij een beheerbericht zonder link
- `data.deeplink`: `bingr://…` voor de app (optioneel)
- `data.msg_id`: id in push_messages (dedup in de app: zelfde msg_id twee keer = één keer tonen)

Per kanaal (alle `data`-waarden zijn strings):
- **APNs**: `{aps:{alert:{title, body}, sound:"default", "thread-id":<kind>}, data:{kind, url?, deeplink?, msg_id}}` en dezelfde
  data-sleutels ook plat naast `aps` (de app leest beide). Header `apns-collapse-id` = msg_id, `apns-push-type: alert`.
- **FCM**: data-only (géén `notification`-blok), `android.priority: "high"`, `data: {title, body, kind, url?, deeplink?, msg_id}`.
  De Android-app toont de melding zelf (kanalen releases/messages/reminders) en ontdubbelt op msg_id.
- **Web Push**: versleuteld (aes128gcm) JSON `{title, body, data:{kind, url?, deeplink?, msg_id}}`.

Tikken:
- `release`: `bingr://changelog?p=<platform>&b=<build>`; app opent de changelog van precies die build (eigen scherm
  als dat bestaat, anders de URL in de browser). Publieke URL: `https://bingr.online/changelog/?p=<platform>#build-<build>`.
- `admin`: `data.url` als het beheer een link meegaf, anders de app openen.
- `reminder`: `bingr://live?channel=<id>&profile=<profiel-id>` (zelfde als de lokale herinnering).

## Releasemelding (per build, vanuit het beheer)

Niet automatisch na het plaatsen van een pakket: Apple en Google keuren een build soms pas na dagen goed. De beheerder
verstuurt hem per build in het beheer (tab Downloads, knop "Pushmelding versturen"; functie `admin`, actie `build_push`),
die `push` aanroept met `{action:"release", platform_group:"apple"|"android", version, build}` en header `x-push-secret` =
`PUSH_ADMIN_SECRET` (`PUSH_RELEASE_SECRET` wordt ook nog geaccepteerd, maar *Builds* gebruikt het niet meer) →
`{ok, message_id, devices, missing_channels}`, of bij een herhaling `{ok, duplicate:true, message_id}`. Fout geheim → 403 `forbidden`.
- `apple` → apparaten met platform ios, ipados, macos; `android` → android. (tvos/androidtv/tizen ontvangen niets.)
- Alleen apparaten met `app_build < build` (wie al bijgewerkt is, krijgt niets).
- Dedup: één melding per (platform_group, build) — tweede aanroep met dezelfde build doet niets.
- Tekst per apparaat in `lang` (nl, en, de, fr, es, it, pt, tr, pl, ar, zh-Hans; anders en), platformnaam per apparaat
  (iPhone, iPad, Mac, Android). Body is (nog) de vaste tekst hieronder, niet de changelogpunten zelf:
  - nl: titel `Bingr 1.0.0 (Build 105) is beschikbaar`, body `Nieuw voor <platformnaam>. Tik om de wijzigingen te bekijken.`
  - en: `Bingr 1.0.0 (Build 105) is available` / `New for <platform>. Tap to see what's changed.`

## Berichten uit het beheer

`{action:"admin_send", title_nl, body_nl, title_en?, body_en?, url?, target:{all:true}|{accounts:[uuid…]}|{platforms:[…]}}`
→ `{ok, message_id, devices, missing_channels}`; versturen gebeurt in batches van 200 (direct na het antwoord, daarna elke minuut
via de cron). Tekst: nl voor apparaten in het Nederlands, anders en (zonder en: nl). `url` alleen https.
`{action:"admin_progress", message_id}` → `{message_id, kind, devices, queued, sent, failed, invalid, errors:{code: aantal}, done}`
(verstuurt meteen ook een volgende batch).
`{action:"admin_history", page?}` → `{items:[{id, kind, title_nl, body_nl, title_en, body_en, url, target, platform_group, build,
version, devices, queued, sent, failed, invalid, errors, created_at, created_by, finished_at}], page, has_more, missing_channels}`
(20 per pagina, nieuwste eerst; alleen `admin` en `release`). `invalid` = token verlopen, apparaat opgeruimd. Een kanaal zonder
geheimen staat in `missing_channels` en geeft per apparaat de fout `apns_not_configured` / `fcm_not_configured` /
`webpush_not_configured` in `errors`. Alle beheeracties: header `x-push-secret` = `PUSH_ADMIN_SECRET`, anders 403.
APNs/FCM/Web Push melden alleen "geaccepteerd" of een fout; "afgeleverd op het toestel" bestaat niet bij deze kanalen.

## Herinneringen

Programmaherinneringen staan per profiel in de gesynchroniseerde lijst `reminders` (zie ACCOUNT.md, "Herinneringen per
profiel"). De cron van `push` (elke minuut) stuurt 2 minuten voor de start een push naar de apparaten van dat account met
systeem-push, één keer per herinnering per apparaat (dedup in push_deliveries). Een app met geregistreerde push plant
voor dat account géén lokale melding meer (anders dubbel); zonder push (geen toestemming, tvOS, TV) blijft de lokale
melding/banner zoals nu. Tekst: "Voor <profiel>: <programma> begint om 20:30" in de taal van het apparaat (profielnaam
alleen als het account meer dan één profiel heeft, zoals bij de lokale melding; tijd in `tz` van het apparaat); titel =
zendernaam. Na de start wordt een herinnering niet meer verstuurd.

## Server (supabase/functions/push, supabase/schema.sql)

- Tabellen `push_devices` (één rij per (account, apparaat), token uniek per kanaal), `push_messages` (één rij per bericht,
  `dedup_key` = `release:<groep>:<build>` of `reminder:<account>:<herinnering-id>`, tellingen in `counts`) en `push_deliveries`
  (één rij per (bericht, apparaat), status queued/sent/failed/invalid). RLS aan, geen rechten voor anon/authenticated.
- Verwijderen: account → cascade; apparaat uit `account_devices` (device-auth `remove_device`, beheer) → trigger
  `bingr_push_device_removed` op (user_id, device_id). Ongeldige token (APNs 410/BadDeviceToken, FCM UNREGISTERED, Web Push
  404/410) → apparaat weg, bezorging `invalid`. Tijdelijke fout (429/5xx/netwerk) → over een minuut opnieuw, max. 3 keer.
- APNs gaat over HTTP/2: Deno-`fetch` onderhandelt h2 via ALPN (getest tegen een server die alleen h2 spreekt).
- Opruimen (pg_cron `bingr-push-cleanup`, dagelijks): herinneringsberichten na 3 dagen, details per apparaat na 30 dagen,
  berichten na 400 dagen, apparaten die 270 dagen niet opnieuw registreerden.

## Geheimen (function-secrets, nooit in de repo)

- `APNS_KEY_P8` (inhoud van de .p8-sleutel), `APNS_KEY_ID`, `APNS_TEAM_ID` (EU3UY476T6), `APNS_TOPIC` (nl.lrvdlinden.bingr)
- `FCM_SERVICE_ACCOUNT` (JSON van een Firebase-serviceaccount), `FCM_PROJECT_ID`
- `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` (mailto:support@bingr.online) — door *Backend* zelf gemaakt als ze ontbreken
- `PUSH_ADMIN_SECRET` (door *Backend* gemaakt, zoals SUPPORT_ADMIN_SECRET), `PUSH_CRON_SECRET` (planning, actie `cron`)
- `PUSH_RELEASE_SECRET` (optioneel, alleen voor `release`; niet meer nodig sinds de releasemelding vanuit het beheer gaat)
Ontbreekt een kanaalgeheim, dan slaat `push` dat kanaal over en meldt het in de geschiedenis (niet stil falen).
