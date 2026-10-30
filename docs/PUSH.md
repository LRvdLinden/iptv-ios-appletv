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
- `data.kind`: `release` | `admin` | `reminder` | `support_reply` (build 146)
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
- `support_reply` (build 146): `bingr://support/ticket?n=<nummer>`, extra `data.ticket` = het nummer; `url` =
  `https://support.bingr.online/ticket/?n=<nummer>` (webspeler: `https://bingr.online/web/#/support/ticket?n=<nummer>`).
  App opent de Support-tab met dat ticket; niet ingelogd of 404 = de ticketlijst (ACCOUNT.md, "Build 146" →
  "Pushmelding bij een antwoord").

## Antwoord van support (build 146)

Reageert support op een ticket met een account (beheer `admin_reply` of per mail via de inbox-import), dan zet de functie
`support` een bericht `kind: "support_reply"` in `push_messages` (`dedup_key` = `support:<id van het supportbericht>`,
`target: {accounts:[user_id]}`, `payload: {sealed}` met nummer en onderwerp versleuteld), zet alle push-apparaten van dat
account in de wachtrij (`bingr_push_enqueue`) en roept `push` `admin_progress` aan (header `x-push-secret` =
`PUSH_ADMIN_SECRET`), zodat hij meteen verstuurd wordt; anders binnen een minuut via de cron. Tekst: nl "Nieuw antwoord op
je supportvraag" / en "New reply to your support request", body `#<nummer> · <onderwerp>` (nooit de tekst van het
antwoord). TTL 3 dagen. Testaccounts van de workflow (`@example.com`) en mailtest-tickets krijgen niets. Komt niet in
`admin_history`.

## Releasemelding (per build, vanuit het beheer)

Niet automatisch na het plaatsen van een pakket: Apple en Google keuren een build soms pas na dagen goed. De beheerder
verstuurt hem per build in het beheer (tab Downloads, knop "Pushmelding versturen"; functie `admin`, actie `build_push`),
die `push` aanroept met `{action:"release", platform_group:"apple"|"android", version, build}` en header `x-push-secret` =
`PUSH_ADMIN_SECRET` (`PUSH_RELEASE_SECRET` wordt ook nog geaccepteerd, maar *Builds* gebruikt het niet meer) →
`{ok, message_id, devices, missing_channels}`, of bij een herhaling `{ok, duplicate:true, message_id}`. Fout geheim → 403 `forbidden`.
`created_by` in de geschiedenis: `beheer` bij PUSH_ADMIN_SECRET (knop in het beheer), `builds` bij PUSH_RELEASE_SECRET.
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
(20 per pagina, nieuwste eerst; alleen `admin` en `release`).
`{action:"admin_retry", message_id}` → `{ok, retried, …zelfde velden als admin_progress}`: mislukte bezorgingen (`failed`) van dat
bericht met een apparaat dat nog bestaat weer in de wachtrij (pogingen op 0; niet `too_late`/`device_removed`, niet voor
herinneringen) en meteen een batch (beheer: knop "Mislukte opnieuw proberen"). `invalid` = token verlopen, apparaat opgeruimd. Een kanaal zonder
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
  `dedup_key` = `release:<groep>:<build>`, `reminder:<account>:<herinnering-id>` of `support:<bericht-id>`, tellingen in
  `counts`; build 146: de payload van herinneringen en supportmeldingen staat versleuteld in `payload.sealed`) en `push_deliveries`
  (één rij per (bericht, apparaat), status queued/sent/failed/invalid). RLS aan, geen rechten voor anon/authenticated.
- Verwijderen: account → cascade; apparaat uit `account_devices` (device-auth `remove_device`, beheer) → trigger
  `bingr_push_device_removed` op (user_id, device_id). Ongeldige token (APNs 410/BadDeviceToken, FCM UNREGISTERED, Web Push
  404/410) → apparaat weg, bezorging `invalid`. Tijdelijke fout (429/5xx/netwerk) → opnieuw met oplopende wachttijd (1, 5, 15
  minuten, daarna elk uur), max. 5 pogingen; daarna `failed` (opnieuw te proberen vanuit het beheer).
- APNs-providertoken: Apple wil hem hoogstens één keer per 20 minuten vernieuwd zien (anders 429 `TooManyProviderTokenUpdates`).
  Eén token voor alle instanties van `push`: tabel `push_provider_tokens` (versleuteld met BINGR_SOURCES_KEY, alleen service
  role), hergebruikt tot 50 minuten oud; `iat` op een blok van 30 minuten; binnen een instantie één aanmaak tegelijk. Na 403
  `ExpiredProviderToken`/`InvalidProviderToken` hoogstens één keer per 20 minuten een nieuw token. FCM: één OAuth-aanvraag tegelijk.
- APNs gaat over HTTP/2: Deno-`fetch` onderhandelt h2 via ALPN (getest tegen een server die alleen h2 spreekt).
- Opruimen (pg_cron `bingr-push-cleanup`, dagelijks): herinneringsberichten na 3 dagen, details per apparaat na 30 dagen,
  berichten na 400 dagen, apparaten die 270 dagen niet opnieuw registreerden.

## Beheer-app (Bingr Beheer)

De beheer-app Bingr Beheer (bingr-beheer/ios, bundle `nl.lrvdlinden.bingr.beheer`; iOS, iPadOS en Mac via Catalyst) krijgt
eigen pushmeldingen via APNs. Dit staat los van de Bingr-apps: geen accounts, geen `push_devices`, nooit in de changelog.

**Registratie** (bingr-beheer, functie `admin`, ingelogd in het beheer): upsert met de service role op `device_id` in
`public.admin_push_devices`:

| kolom | type | |
|---|---|---|
| `id` | bigint identity, pk | |
| `device_id` | text, not null, uniek | id van het apparaat in de beheer-app |
| `token` | text, not null, uniek | APNs-devicetoken (hex) |
| `platform` | text, not null | `ios` \| `ipados` \| `macos` |
| `sandbox` | boolean, default false | true voor debug-builds (APNs development) |
| `prefs` | jsonb, default `{"tickets":true,"replies":true,"builds":true,"status":true}` | ontbrekende sleutel = aan |
| `app_build` | int | |
| `created_at`, `updated_at` | timestamptz, default now() | |
| `last_error` | text | alleen een foutcode (`apns_…`), door `push` gezet |

RLS aan, geen rechten voor anon/authenticated. `push` leest en verstuurt; de functie admin schrijft.

**Versturen** (stap `adminNotify` in `push`/`cron`, elke minuut; `supabase/functions/push/beheer.ts`, pure logica in
`beheer_logic.ts`, tests in `beheer_test.ts` die de deploy blokkeren). APNs met topic `BEHEER_APNS_TOPIC` (standaard
`nl.lrvdlinden.bingr.beheer`) en dezelfde `APNS_KEY_P8`/`APNS_KEY_ID`/`APNS_TEAM_ID`; sandbox per apparaat. Zonder APNs-sleutels
wordt niets verstuurd (geen fout); de watermerken lopen wel door.

| soort (`kind`) | pref | wanneer | titel | tekst | link (`url`) |
|---|---|---|---|---|---|
| `ticket` | `tickets` | nieuw supportticket (`support_tickets.number` > watermerk) | `Nieuw ticket #<nummer>` | onderwerp (max. 120 tekens) | `bingrbeheer://support/<nummer>` |
| `reply` | `replies` | nieuw klantbericht (`support_messages`, `author = 'customer'`, id > watermerk), niet het eerste bericht van een ticket (dat is het ticket zelf) | `Nieuw antwoord op #<nummer>` | begin van het bericht (max. 120 tekens) | `bingrbeheer://support/<nummer>` |
| `build` | `builds` | hogere build in `builds/manifest.json` (beheer.bingr.online, via dl.php met HMAC-token uit `BINGR_BUILDS_KEY`, hoogstens elke 5 minuten) voor android, tizen, apple of beheer | `Android-build 116 staat klaar` (Samsung TV-, Apple-, Beheer-app-build) | `In Downloads op beheer.bingr.online` | `bingrbeheer://downloads` |
| `status` | `status` | een statusmonitor (alle ingeschakelde monitors) krijgt een storing of is er weer vanaf | `Storing: <monitor>` / `Weer online: <monitor>` | `Sinds 14:25` / `Na 12 min weer bereikbaar` | `bingrbeheer://status` |

- Status volgt de storingen van de functie `status` (`status_incidents`): die opent pas na 2 mislukte controles op rij en sluit
  na 2 goede, dus flapperen geeft geen meldingen. Onderhoud opent geen storing, dus ook geen melding.
- Meer dan 3 per soort in één ronde: één samenvatting (`5 nieuwe tickets`, `4 nieuwe antwoorden`, `4 nieuwe builds staan klaar`,
  `5 statuswijzigingen` met `3 storingen, 2 weer online`).
- Payload: `{aps:{alert:{title, body}, sound:"default", "thread-id":<kind>}, kind, url}`; `kind` = ticket | reply | build | status.
- Ongeldige token (410, BadDeviceToken, Unregistered, DeviceTokenNotForTopic, ExpiredToken) → rij verwijderd; andere fout →
  `last_error` (alleen de code). Na een geslaagde melding wordt `last_error` weer leeg.
- Antwoord van `cron` bevat `beheer: {notices, sent, invalid, failed, skipped?}` (alleen tellingen; `skipped` = `busy`,
  `apns_not_configured` of `no_devices`). Logs bevatten nooit tokens, onderwerpen, berichten of e-mailadressen.

**Watermerken** in `public.admin_push_state` (één rij, `id = 1`): `last_ticket_number`, `last_message_id`, `builds`
(`{platform: build}`), `monitors` (`{monitor-id: {s: "up"|"down", since}}`), `builds_checked_at` (laatste keer manifest),
`updated_at`. Ontbreekt de rij of een veld, dan zet de cron dat op de huidige stand zonder te melden (geen stortvloed aan oude
meldingen); een nieuwe monitor of een nieuw platform in het manifest wordt ook eerst stil vastgelegd. De watermerken worden
vóór het versturen weggeschreven met een controle op `updated_at`, zodat twee gelijktijdige rondes niets dubbel versturen.

## Pushdiensten op de statuspagina

Monitors in de groep Server (functie `status`, elke 5 minuten, openbaar op bingr.online/status en in het beheer):
- `push` "Pushmeldingen": de eigen functie `push`, actie `vapid_key` moet de publieke Web Push-sleutel geven (soort `push`).
- `push-apple` "Pushmeldingen Apple-apparaten": api.push.apple.com bereikbaar via HTTPS (soort `reach`: elk HTTP-antwoord = up,
  geen verbinding/TLS-fout/time-out = fout; er gaat geen sleutel of token mee).
- `push-android` "Pushmeldingen Android": fcm.googleapis.com bereikbaar (soort `reach`). Web Push in Chrome loopt ook via deze
  dienst; Safari via Apple, Firefox via Mozilla (die laatste wordt niet apart gecontroleerd).

## Geheimen (function-secrets, nooit in de repo)

- `APNS_KEY_P8` (inhoud van de .p8-sleutel), `APNS_KEY_ID`, `APNS_TEAM_ID` (EU3UY476T6), `APNS_TOPIC` (nl.lrvdlinden.bingr)
- `BEHEER_APNS_TOPIC` (optioneel, standaard nl.lrvdlinden.bingr.beheer) en `BINGR_BUILDS_KEY` (al gezet door bingr-beheer; voor de buildmeldingen)
- `FCM_SERVICE_ACCOUNT` (JSON van een Firebase-serviceaccount), `FCM_PROJECT_ID`
- `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` (mailto:support@bingr.online) — door *Backend* zelf gemaakt als ze ontbreken
- `PUSH_ADMIN_SECRET` (door *Backend* gemaakt, zoals SUPPORT_ADMIN_SECRET), `PUSH_CRON_SECRET` (planning, actie `cron`)
- `PUSH_RELEASE_SECRET` (optioneel, alleen voor `release`; niet meer nodig sinds de releasemelding vanuit het beheer gaat)
Ontbreekt een kanaalgeheim, dan slaat `push` dat kanaal over en meldt het in de geschiedenis (niet stil falen).
