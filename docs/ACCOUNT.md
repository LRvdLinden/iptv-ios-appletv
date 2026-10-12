# Bingr-account: contract (iOS, iPadOS, tvOS, macOS, Android, Android TV, website)

Inloggen is **verplicht**. Flow: **splash → (geen geldige sessie) inlogscherm → "Wie kijkt er?" → app**. Met een geldige sessie gaat de app na de splash direct naar "Wie kijkt er?". Uitloggen brengt je terug naar het inlogscherm.

De account regelt het inloggen en bewaart de **profielen** (zonder pincodes en eigen foto's). Servers, voortgang, lijsten en pincodes blijven zoals ze zijn (iCloud op Apple, lokaal op Android).

## Profielen migreren en delen

Bestaande gebruikers houden al hun profielen: het inlogscherm komt vóór "Wie kijkt er?" en raakt geen lokale gegevens aan.

Tabel `account_data`: één rij per account, `{user_id, profiles, updated_at}`. Lezen en schrijven gaat via PostgREST met de sessie van de gebruiker:
- Lezen: `GET {URL}/rest/v1/account_data?select=profiles,updated_at` + `apikey` + `Authorization: Bearer <access_token>`. Antwoord: `[]` of `[{profiles, updated_at}]`.
- Schrijven: `POST {URL}/rest/v1/account_data` + dezelfde headers + `Prefer: resolution=merge-duplicates,return=minimal`, body `{"user_id":"<user.id>","profiles":[…],"updated_at":"<ISO-8601 nu>"}`.

`profiles` is een lijst van objecten met deze velden:
- `id`: het bestaande profiel-ID
- `name`
- `avatar`: emoji, kleur en/of figuur `kidNN`, zoals de app het al opslaat; een eigen foto wordt niet meegestuurd
- `kids`: true of false
- `ageLimit`: getal of null
- `isMain`: true of false
- `order`: getal

Extra velden negeren en bewaren.

Na inloggen (en bij het starten met een geldige sessie):
1. Lees `account_data`.
2. Leeg op de server en lokaal wel profielen: **migreren**, dus de lokale profielen uploaden.
3. Lokaal geen profielen (alleen het automatische hoofdprofiel of niets) en op de server wel: **importeren**, dus de profielen lokaal aanmaken met hetzelfde `id` en zonder pincode.
4. Allebei: samenvoegen op `id`. Lokale profielen blijven. Profielen die alleen op de server staan, worden lokaal toegevoegd. Daarna wordt de samengevoegde lijst geüpload.

Wijzigingen in profielen (toevoegen, hernoemen, avatar, kinderprofiel, verwijderen) worden daarna geüpload: de hele lijst, met een korte vertraging. Een fout bij synchroniseren blokkeert de app nooit; het gebeurt stil op de achtergrond.

## Configuratie

- `SUPABASE_URL` (bv. `https://abcd1234.supabase.co`) en `SUPABASE_ANON_KEY` (publiek, `eyJ…` of `sb_publishable_…`).
- iOS: `Secrets.supabaseURL` / `Secrets.supabaseAnonKey`, ingebouwd door `tools/inject_keys.py` uit de omgevingsvariabelen. Ze staan alleen in `builtIn` en worden **niet** in de sleutelhanger gezet en niet in de app aangepast.
- Android: `BuildConfig.SUPABASE_URL` / `BuildConfig.SUPABASE_ANON_KEY` (build.gradle: `key("SUPABASE_URL")`, `key("SUPABASE_ANON_KEY")`).
- Zijn ze leeg, dan toont het inlogscherm "Accounts are not configured in this build." en is er (alleen dan) een knop "Continue without account". Zo blijft een build zonder sleutels bruikbaar.

## Endpoints (gewone REST, geen SDK)

Elke aanvraag krijgt de header `apikey: <ANON_KEY>` en `Content-Type: application/json`.

| Wat | Aanvraag | Antwoord |
|---|---|---|
| Account maken | `POST {URL}/auth/v1/signup` `{email, password, data:{lang}}` (`lang` = huidige app-taal, bv. `"nl"`; bepaalt de taal van de e-mails) | 200: sessie (zie onder) **of** een user zonder `access_token`. Dan moet het e-mailadres eerst bevestigd worden: toon "Check your inbox to confirm your email address, then sign in." |
| Inloggen | `POST {URL}/auth/v1/token?grant_type=password` `{email, password}` | 200: sessie. 400: `error_code` is `invalid_credentials` ("Incorrect email or password.") of `email_not_confirmed` ("Confirm your email address first. Check your inbox.") |
| Vernieuwen | `POST {URL}/auth/v1/token?grant_type=refresh_token` `{refresh_token}` | 200: nieuwe sessie (sla het **nieuwe** refresh_token op). 400/401: sessie ongeldig, dus uitloggen. Netwerkfout: sessie houden (offline blijft de app werken). |
| Wachtwoord vergeten | `POST {URL}/auth/v1/recover?redirect_to=https%3A%2F%2Fbingr.online%2Freset` `{email}` | 200: altijd "If an account exists, you'll receive an email to reset your password." |
| Uitloggen | `POST {URL}/auth/v1/logout` + `Authorization: Bearer <access_token>` | 204. Daarna altijd lokaal wissen, ook als dit mislukt. |
| Tv-code starten | `POST {URL}/functions/v1/device-auth` `{"action":"start","device":"Apple TV"}` | `{code, poll_secret, url, expires_in, interval}` |
| Tv-code pollen | idem `{"action":"poll","code","poll_secret"}` om de `interval` (3) seconden | `{status:"pending"}` / `{status:"expired"}` (nieuwe code starten) / `{status:"approved", token_hash, email}` |
| Tv-sessie ophalen | `POST {URL}/auth/v1/verify` `{"type":"magiclink","token_hash":…}` | 200: sessie |
| Tv koppelen (telefoon/Mac) | device-auth `{"action":"approve","code"}` + `Authorization: Bearer <access_token>` | `{ok:true, device}` of 404 `{error:"invalid_code"}` |
| Account verwijderen | device-auth `{"action":"delete_account"}` + `Authorization: Bearer <access_token>` | `{ok:true}`, daarna lokaal uitloggen |

**Sessie** = `{access_token, refresh_token, expires_in, expires_at?, user:{id, email}}`. Bewaar `refresh_token`, `access_token`, `expires_at` (nu + expires_in) en `email`. Bewaar ze **alleen op dit apparaat**: op Apple in de sleutelhanger zonder iCloud-sync (refresh tokens zijn eenmalig, dus delen tussen apparaten werkt niet), op Android in de app-opslag. Bij het starten van de app: is er een refresh_token, ga dan door naar "Wie kijkt er?" en vernieuw op de achtergrond. Komt daar 400/401 uit, ga dan terug naar het inlogscherm.

Tv-code tonen als `K7Q-4MX` (3 + 3). Bij het invoeren hoofdletters maken en `-` en spaties weghalen.

## Schermen

**Inlogscherm op telefoon, tablet en Mac** (Netflix-stijl): zwarte achtergrond met een gedimde, licht vervaagde collage van posters (covers uit de bibliotheek als die er zijn, anders een donker verloop met rood), bovenaan het Bingr-logo. Daaronder een kaart met de kop **"Sign In"** of **"Create account"**, de velden **E-mail** en **Password** (met tonen/verbergen), een rode volle knop, en een foutmelding in oranje/rood onder de velden. Daaronder: "Forgot password?", en "New to Bingr? **Sign up now.**" / "Already have an account? **Sign in.**". Wachtwoord minimaal 6 tekens. Tijdens het laden een spinner in de knop.

**Inlogscherm op tv** (Apple TV, Android TV, Fire TV), zoals Netflix:
- Links: **"Sign in with your phone"**, "Scan the QR code with your phone's camera" + grote witte QR-code (de `url` uit start) + "Or go to **bingr.online/tv** and enter this code:" + de code groot (`K7Q-4MX`). De code ververst automatisch als hij verloopt. Onderaan "Waiting for confirmation…" met een spinner.
- Rechts, gescheiden door "OR": knop **"Sign in with email"**, die het e-mailformulier opent (tv-toetsenbord). Daarin ook "Create account".
- Is de tv gekoppeld, dan kort "Signed in as %@" en door naar "Wie kijkt er?".

**Mijn Bingr / Instellingen → sectie "Account"** (hoofdaccount en alle profielen zien de e-mail):
- "Signed in as %@"
- **"Link a TV"** (niet op tv): veld "Enter the code shown on your TV" + knop "Link". Bij succes "%@ is now signed in." (apparaatnaam), bij een fout "That code is invalid or has expired."
- **"Sign out"** met bevestiging "Sign out of Bingr on this device?"
- **"Delete account"** (verplicht volgens App Store-regels) met bevestiging "Delete your Bingr account? This can't be undone." Daarna uitloggen.

## Teksten (Engels = sleutel in Translations.json, 11 talen)

Sign In · Create account · Email · Password · Show · Hide · Sign up now. · New to Bingr? · Already have an account? · Sign in. · Forgot password? · Reset password · Send reset link · If an account exists, you'll receive an email to reset your password. · Incorrect email or password. · Confirm your email address first. Check your inbox. · Check your inbox to confirm your email address, then sign in. · Enter a valid email address. · Password must be at least 6 characters. · An account with this email already exists. · Something went wrong. Please try again. · No internet connection. · Sign in with your phone · Scan the QR code with your phone's camera · Or go to · and enter this code: · Waiting for confirmation… · Sign in with email · OR · Signed in as %@ · Account · Link a TV · Enter the code shown on your TV · Link · %@ is now signed in. · That code is invalid or has expired. · Sign out · Sign out of Bingr on this device? · Delete account · Delete your Bingr account? This can't be undone. · Accounts are not configured in this build. · Continue without account

## Website

- `bingr.online/tv?code=XXXXXX`: inloggen (of account maken) en de tv koppelen.
- `bingr.online/reset`: nieuw wachtwoord instellen via de link uit de e-mail.
- `assets/config.js` (`window.BINGR_SUPABASE = {url, anonKey}`) wordt bij de deploy uit de secrets gemaakt.

## Gekoppelde apparaten (max. 10)

Elk apparaat heeft een eigen, vaste **device_id** (UUID). Die wordt één keer aangemaakt en alleen lokaal bewaard: op Apple in de sleutelhanger zonder iCloud-sync, op Android in de app-opslag. Hij blijft bestaan na uitloggen.

Alle aanroepen gaan naar device-auth, met `Authorization: Bearer <access_token>`:

| Actie | Body | Antwoord |
|---|---|---|
| `register_device` | `{device_id, name, platform}` | `{ok}`, of **403** `{error:"device_limit", limit:10, devices:[…]}` |
| `heartbeat` | `{device_id}` | `{ok}`, of `{revoked:true}`: het apparaat is verwijderd, dus direct lokaal uitloggen (zonder de logout-aanroep) en terug naar het inlogscherm |
| `list_devices` | `{device_id}` | `{limit, devices:[{device_id, name, platform, created_at, last_seen_at, current}]}`, nieuwste gebruik eerst |
| `remove_device` | `{device_id}` | `{ok}`. De sessie van dat apparaat wordt ingetrokken, zodat het apparaat uitlogt. |

- **name**: de naam van het apparaat (op iOS `UIDevice.current.name`, op de Mac `Host.current().localizedName`, op Android `Settings.Global.DEVICE_NAME` of anders `Build.MODEL`).
- **platform**: een van `iPhone`, `iPad`, `Apple TV`, `Mac`, `Android`, `Android tablet`, `Android TV`, `Fire TV`.

**Wanneer de app wat aanroept**
- **Na elke geslaagde login** (e-mail of tv-koppeling): `register_device`.
  - Geeft dat `device_limit`, toon dan het scherm **"Too many devices"**: "Your account can be used on up to %d devices. Remove a device to sign in on this one." met de lijst en per apparaat een knop **Remove**.
  - Na het verwijderen opnieuw `register_device`. Lukt het daarna, ga dan door naar "Wie kijkt er?".
  - Met **Cancel** log je uit.
  - Lokaal onthouden: `deviceRegistered = true`.
- **Bij het starten, bij terugkeer naar de voorgrond en elke 5 minuten zolang de app open is**:
  - Als `deviceRegistered`: `heartbeat`. Geeft die `revoked`, dan uitloggen.
  - Zo niet (bijvoorbeeld bij een sessie van vóór build 39): `register_device`, met dezelfde afhandeling van de limiet.
- **Uitloggen** door de gebruiker: eerst `remove_device` voor het eigen apparaat, daarna de logout-aanroep en lokaal wissen.
- **Refresh met 400/401**: uitloggen (dit gebeurt al).

**Mijn Bingr → Account → "Devices"** (op alle platforms, ook op tv):
- Kop: "%d of %d devices".
- Lijst met:
  - een icoon per platform;
  - de **naam**, en het platform eronder;
  - "Linked %@" (datum, bijvoorbeeld 12 okt 2026);
  - "Last used %@" (relatieve tijd: "just now", "5 min ago", "yesterday", of een datum).
- Het eigen apparaat krijgt het label **"This device"** en als laatst gebruikt "Now".
- Per apparaat een knop **"Remove"**, met de bevestiging "Remove %@? It will be signed out." Remove bij het eigen apparaat betekent hetzelfde als uitloggen.

**Nieuwe teksten:** Devices · %d of %d devices · Linked %@ · Last used %@ · This device · Now · Remove · Remove %@? It will be signed out. · Too many devices · Your account can be used on up to %d devices. Remove a device to sign in on this one. · Cancel · just now · %d min ago · yesterday

Op de website staat hetzelfde beheer op `bingr.online/account`.

## Profielfoto's delen (build 40)

Eigen profielfoto's horen bij het account. Iedereen die met hetzelfde account inlogt, ziet dezelfde foto, op elk platform en los van iCloud of Apple ID.

**Opslag:** de privé-bucket `avatars`. Elk bestand staat op `<user_id>/<profiel_id>.jpg`, is JPEG, maximaal 512×512 pixels (vierkant bijgesneden) met kwaliteit 0,8, en maximaal 1 MB. Alleen de eigenaar heeft toegang. Alle aanvragen hebben de headers `apikey` en `Authorization: Bearer <access_token>`.

| Wat | Aanvraag |
|---|---|
| Uploaden of vervangen | `POST {URL}/storage/v1/object/avatars/<user_id>/<profiel_id>.jpg` met de headers `Content-Type: image/jpeg` en `x-upsert: true`, body: de JPEG-bytes |
| Downloaden | `GET {URL}/storage/v1/object/authenticated/avatars/<user_id>/<profiel_id>.jpg` |
| Verwijderen | `DELETE {URL}/storage/v1/object/avatars/<user_id>/<profiel_id>.jpg` |

**In `account_data.profiles`** krijgt elk profiel het veld `photo`:
- met foto: `{"path": "<user_id>/<profiel_id>.jpg", "updated": "<ISO-8601>"}`;
- zonder foto: `null`.

Het avatar-icoon wordt ook gewoon meegestuurd, zodat er altijd iets te tonen is.

**Lokaal bijhouden:** per profiel de `updated` van de foto die het apparaat heeft, de *photoVersion*.

**Synchroniseren**
- **Foto gekozen of gewijzigd op dit apparaat:** verklein de foto, upload hem, zet `photo` met `updated` = nu, sla die waarde lokaal op als *photoVersion* en upload de profiellijst (met de vertraging die er al is).
- **Foto verwijderd:** stuur DELETE (fouten negeren), zet `photo: null` en upload de lijst.
- **Bij lezen, migreren, importeren of samenvoegen:**
  - Is `photo.updated` op de server nieuwer dan de lokale *photoVersion*, of heeft het apparaat geen foto: download en bewaar de foto als profielfoto. Op Apple gaat hij ook zoals nu via iCloud.
  - Is `photo` `null` en kwam de lokale foto eerder uit de sync (er staat een *photoVersion*): verwijder de lokale foto.
- **Migratie:** heeft een profiel lokaal een foto en op de server niet (`photo` ontbreekt of is `null`, en het apparaat heeft geen *photoVersion*), upload de foto dan.
- **Wanneer:** bij het starten en bij elke heartbeat (elke 5 minuten) de `account_data` opnieuw lezen en deze regels toepassen. Zo verschijnt een nieuwe foto ook op apparaten die al open staan.
- **Fouten:** altijd stil, de app nooit blokkeren.

## App-sleutels van de server (build 41)

De repo is openbaar, dus de sleutels voor Trakt, OpenSubtitles, OMDb en TMDB worden niet in de app gebouwd. De app haalt ze op bij de server:

- **Aanroep:** device-auth `{"action":"config"}` met `Authorization: Bearer <access_token>`.
- **Antwoord:** `{traktClientID, traktClientSecret, openSubtitlesAPIKey, omdbAPIKey, tmdbAPIKey}`. Een waarde kan `""` zijn.
- **Wanneer:** na elke login en bij het starten met een geldige sessie, op de achtergrond.
- **Bewaren:** alleen lokaal, op Apple in de sleutelhanger zonder iCloud, op Android in privé-instellingen. Zo werkt de app daarna ook offline.
- **Uitloggen:** de opgehaalde sleutels blijven staan.
- **Volgorde bij het opzoeken van een sleutel:** eerst wat de gebruiker zelf heeft ingevuld (de bestaande instelling), dan de sleutel van de server, dan de ingebouwde (`builtIn`, op Android `BuildConfig`).
- **Is de sleutel van de server binnen,** dan is `traktReady` / `openSubtitlesReady` waar. De gebruiker ziet dan gewoon **"Inloggen bij Trakt"** (koppelcode en QR) en **"Inloggen bij OpenSubtitles"** (gebruikersnaam en wachtwoord), en nooit het scherm "Koppelingen instellen".
- **"Koppelingen instellen"** blijft alleen bereikbaar als een sleutel ontbreekt, en als geavanceerde optie onderaan in Mijn Bingr.
- **Na het ophalen van de config:** UI verversen en `Secrets.reload()`, of iets vergelijkbaars, zodat Trakt en OpenSubtitles direct werken.

## Profielen volledig synchroniseren (build 41)

`account_data.profiles` wordt de bron van waarheid voor de profielen van een account: toevoegen, wijzigen en verwijderen. Pincodes blijven lokaal.

**Extra velden per profiel**
- `updatedAt` (ISO-8601): wanneer naam, avatar, `kids`, `ageLimit` of `order` voor het laatst lokaal is gewijzigd.
- `deleted: true` en `deletedAt` (ISO-8601): een tombstone. Een verwijderd profiel blijft als tombstone in de lijst staan, met alleen `id`, `deleted`, `deletedAt` en `updatedAt`, zodat andere apparaten het ook verwijderen. Tombstones ouder dan 90 dagen mogen bij het uploaden weg.

**Lokaal bijhouden:** per profiel de `updatedAt` van de versie die het apparaat heeft (de *localUpdatedAt*).

**Lokaal wijzigen**
- Profiel aanmaken, naam, avatar, kinderprofiel, leeftijdsgrens of volgorde wijzigen: zet `updatedAt` = nu, sla het lokaal op en upload de lijst (met de vertraging die er al is).
- Profiel verwijderen: verwijder het lokaal (met de lokale gegevens), zet er een tombstone voor in de lijst, verwijder de foto (DELETE in Storage) en upload de lijst.
- **Het hoofdprofiel** (`isMain`) kan nooit verwijderd worden en wordt nooit door een tombstone verwijderd.

**Toepassen van de server.** Dit gebeurt bij elke lezing: na login, bij het starten, bij terugkeer naar de voorgrond en bij elke heartbeat (elke 5 minuten). Per `id`:
- **Server-tombstone en lokaal profiel bestaat:** verwijder het lokaal, met de foto en de gegevens van dat profiel. Is dit het actieve profiel, ga dan terug naar "Wie kijkt er?".
- **Server actief en lokaal ontbreekt:** voeg het toe, zonder pincode.
- **Allebei actief:** is de `updatedAt` van de server nieuwer dan de lokale *localUpdatedAt*, neem dan `name`, `avatar`, `kids`, `ageLimit` en `order` van de server over. Anders blijft lokaal staan.
- **Lokaal actief en niet op de server:** dat is een nieuw lokaal profiel of een migratie, dus houden en uploaden.
- **Sortering:** op `order`.
- **Daarna:** is lokaal iets nieuwer dan de server, of ontbreekt het op de server, upload dan de samengevoegde lijst. Tombstones van de server blijven daarin staan.

**Ouder formaat zonder `updatedAt`:** behandel dat als heel oud (epoch). De regels voor migreren en importeren van build 38 blijven gelden.

## Servers en afspeellijsten via het account (build 43)

Servers horen bij het account. Na het (opnieuw) installeren, na een update en op een nieuw apparaat staat alles weer klaar zodra je inlogt. Opslag gebeurt via de Edge Function, die alles versleutelt (AES-GCM) met een sleutel die alleen de server kent. De database ziet de gegevens nooit leesbaar.

| Actie (device-auth, met `Authorization: Bearer <access_token>`) | Body | Antwoord |
|---|---|---|
| `get_sources` | `{}` | `{sources:[…], mainSourceID, updatedAt}`. Voor een nieuw account: `sources: []`, `updatedAt: null`. |
| `put_sources` | `{sources:[…], mainSourceID}` | `{ok, updatedAt}`. Stuurt altijd de **hele** lijst, inclusief tombstones. Maximaal 512 KB. |

**Bron (gedeeld formaat, gelijk op iOS en Android)**

| Veld | Inhoud |
|---|---|
| `id` | UUID als tekst. Bewaar het exact; iOS gebruikt hoofdletters. |
| `name` | naam |
| `kind` | de raw value: `"M3U / M3U8"`, `"Xtream Codes"`, `"Stalker / MAC-portal"`, `"Plex"`, `"Jellyfin"`, `"Emby"` of `"Stremio"` |
| `avatar` | `{symbol, colorIndex, emoji?}`, net als bij profielen (iOS-symboolnaam, Android vertaalt met `AvatarMap`) |
| `m3uURL`, `epgURL`, `serverURL`, `username`, `macAddress` | tekst, `""` als het leeg is |
| `preferHLS` | true of false |
| `secrets` | `{ "<naam>": "<waarde>" }`: **alle** geheime velden die nu lokaal in de sleutelhanger of privé-opslag staan onder `playlist.<id>.<naam>`. Bijvoorbeeld `password`, en bij Plex, Jellyfin, Emby en Stremio ook tokens. Zoek alle sleutels met dat voorvoegsel op. |
| `apple`, `android` | optioneel, per platform een eigen blok met instellingen die bij deze bron horen. Denk aan categorieën aan/uit, hernoemde, verborgen of herschikte groepen en zenders. Elk platform leest alleen zijn eigen blok en bewaart het blok van het andere platform onaangeroerd. |
| `updatedAt` | ISO-8601 |
| `deleted`, `deletedAt` | `deleted: true` met `deletedAt` maakt er een tombstone van, zelfde regels als bij profielen. Tombstones ouder dan 90 dagen weg. |

`mainSourceID` is de actieve server van het account.

**Wie beheert:** alleen het hoofdaccount voegt servers toe, wijzigt ze en verwijdert ze; dat is al zo. Elk apparaat van het account leest ze en past ze toe, ongeacht het actieve profiel.

**Synchroniseren** volgt hetzelfde patroon als profielen. Het gebeurt na login (vóór "Wie kijkt er?", met maximaal 8 seconden wachten), bij het starten, bij terugkeer naar de voorgrond en bij elke heartbeat:
- **Server leeg en lokaal bronnen:** uploaden. Dat is de migratie van bestaande gebruikers, inclusief de wachtwoorden en tokens uit de sleutelhanger.
- **Lokaal leeg en server bronnen:** alles lokaal aanmaken met hetzelfde `id`, de `secrets` terugzetten in de sleutelhanger of opslag, het eigen platformblok toepassen, `mainSourceID` instellen en de bibliotheek laden. Dit is het geval na herinstallatie of op een nieuw apparaat.
- **Allebei:** per `id` geldt de nieuwste `updatedAt`. Tombstones verwijderen lokaal, inclusief de secrets en de cache van die bron. Daarna uploaden als lokaal iets nieuwer is of ontbreekt.
- **Lokaal wijzigen:** server toevoegen, wijzigen (ook wachtwoord) of verwijderen, en wijzigingen aan categorieën of groepen. Zet `updatedAt` = nu en upload met ongeveer 2 seconden vertraging.
- **Fouten:** stil. De app blijft werken met wat lokaal staat.

Op Apple blijft de bestaande iCloud-sync van servers ook werken. Omdat de `id`'s gelijk zijn, botst dat niet.

**Uitloggen:** de lokale servers blijven staan. Logt een **ander** account in op het apparaat, wis dan eerst de lokale servers, profielen en gegevens van het vorige account. Op Apple, waar iCloud ook servers kan leveren: wis lokaal en importeer daarna van het nieuwe account. Om dit te kunnen zien, onthoud je de user-id van het laatst ingelogde account.

## Alle overige gegevens via het account (build 44)

Alles wat iemand in Bingr instelt of opbouwt, komt na het (opnieuw) installeren of op een nieuw apparaat terug. De gegevens worden versleuteld opgeslagen per **onderdeel** (section), via device-auth met `Authorization: Bearer <access_token>`:

| Actie | Body | Antwoord |
|---|---|---|
| `get_state` | `{sections?: ["…"]}` (leeg = alles) | `{sections: {"<naam>": {data, updatedAt}}}` |
| `put_state` | `{section, data}` (`data` = JSON, max. 1 MB) | `{ok, updatedAt}` |
| `delete_state` | `{section}` | `{ok}` |

**Onderdelen.** Gedeelde sleutels hebben op iOS en Android dezelfde naam en betekenis. Platform-specifieke sleutels gaan in een blok `apple` of `android`; een platform bewaart het blok van het andere platform onaangeroerd.

| Section | Inhoud |
|---|---|
| `connections` | `trakt: {accessToken, refreshToken, expiresAt (ISO), username}` of `null`; `opensubtitles: {token, username, password?, baseURL?}` of `null` (precies wat de app nu lokaal bewaart om ingelogd te blijven). Plus `updatedAt`. |
| `settings` | `shared`: instellingen met dezelfde betekenis op beide platforms, zoals app-taal, speler-engine (`auto`/`apple`/`exo`/`vlc`, elk platform vertaalt naar wat het heeft), ondertitelgrootte, standaard audio- en ondertiteltaal, automatisch ondertitels, OpenSubtitles-standaardtaal, startscherm, verborgen tabbladen, intromuziek, verversinterval en kinderslot-instellingen die niet per server zijn. Daarnaast `apple: {…}` en `android: {…}` met de rest. Plus `updatedAt`. |
| `profile.<profielID>` | per profiel: `myList`, `favorites`, `progress` (`{key: {position, duration, updatedAt, …}}`), `watched` (set van sleutels), `history` (lijst met tijd), `recentChannels`, `prefs` (kijkvoorkeuren), `pin` (de pincode zoals de app hem nu bewaart, of `null`), `updatedAt`. Sleutels voor inhoud zijn op iOS en Android al gelijk (bijvoorbeeld `ep:<serieID>\|s-e`). |
| `reminders` | lijst met herinneringen, plus `updatedAt` |

**Samenvoegen** (bij lezen: na login, bij het starten, bij terugkeer naar de voorgrond en bij elke heartbeat):
- **Lijsten en sets** (`myList`, `favorites`, `watched`, `recentChannels`): samenvoegen, maar een **verwijdering** moet doorkomen. Houd daarom per item `{id, removed?, at}` bij, of een aparte lijst `removed: {id: at}`. Per item wint de nieuwste `at`.
- **`progress`**: per sleutel wint de nieuwste `updatedAt`.
- **`history`**: samenvoegen op id of tijd, nieuwste eerst, maximaal 500 items.
- **Instellingen, `connections`, `pin` en `prefs`**: het geheel met de nieuwste `updatedAt` wint, niet per veld.
- **Trakt-tokens zijn eenmalig bij verversen.** Lees daarom eerst `connections` voordat je een Trakt-token ververst. Heeft de server nieuwere tokens (een later `updatedAt`), gebruik die en ververs niet. Na het verversen meteen `put_state` voor `connections`.
- **Uploaden:** bij elke lokale wijziging, met ongeveer 3 seconden vertraging. Voortgang tijdens het afspelen maximaal eens per 30 seconden en bij stoppen.
- **Profiel verwijderd** (tombstone): `delete_state` voor `profile.<id>`.
- **Ander account op dit apparaat:** zoals bij build 43 alles lokaal wissen, daarna alles importeren.
- **Fouten:** altijd stil. Lokaal blijft leidend tot er weer verbinding is.
- **Migratie:** is een onderdeel op de server leeg en is er lokaal iets, dan uploaden.

## Apparaten hernoemen en platformnamen (build 45)

- **Hernoemen:** device-auth `{"action":"rename_device","device_id","name"}` met `Authorization: Bearer <access_token>` geeft `{ok}`. De naam mag maximaal 60 tekens zijn. Daarna overschrijft `register_device` de naam niet meer.
- **Waar:** in de app bij Mijn Bingr → Account → Apparaten, per apparaat (ook het eigen apparaat). Dat geldt op iPhone, iPad, Mac, Apple TV, Android-telefoon, -tablet, Android TV, Google TV en Fire TV, en op bingr.online/account.
  - Er is een knop **"Rename"**. Die opent een tekstveld met de huidige naam, met de knoppen **Save** en **Cancel**. Op tv's gebruik je het tv-toetsenbord.
  - Nieuwe teksten: "Rename" · "Device name" · "Save".
- **Platformnamen** (`platform` bij `register_device`):
  - `iPhone`, `iPad`, `Mac`, `Apple TV`
  - `Android` (telefoon), `Android tablet`, `Android TV`, `Google TV`, `Fire TV`
  - Android: `Fire TV` als `Build.MANUFACTURER == "Amazon"`. `Google TV` als het een tv is en `packageManager.hasSystemFeature("com.google.android.feature.GOOGLE_EXPERIENCE")` waar is, of als `Build.MODEL` "Chromecast" bevat of `Build.BRAND` "google" is. Anders `Android TV`.
- **Iconen per platform:** gebruik in de apparatenlijst dezelfde soort iconen als iOS.
  - iPhone: telefoon. iPad: tablet. Mac: laptop of computer. Apple TV: Apple TV-kastje.
  - Android: telefoon. Android tablet: tablet. Android TV, Google TV en Fire TV: tv.
- **Delen op tv's:** op Apple TV, Android TV, Google TV en Fire TV staat **geen** deelknop (ook geen QR) op de detailpagina.

## Build 51: collecties, startscherm, terugkijk-correctie en webconsole

**Collecties** (eigen rijen, voor het hele account). State-section `collections` = `{items:[…], updatedAt}`. Elk item:

| Veld | Inhoud |
|---|---|
| `id` | UUID als tekst |
| `name` | naam |
| `image` | `{symbol, colorIndex}` zoals een avatar, of `{url}` voor een eigen plaatje (https-URL of TMDB-poster) |
| `kind` | `"manual"` of `"smart"` |
| `items` | bij manual: lijst `{type:"channel"\|"movie"\|"series", id}` met de lokale id's zoals de app ze gebruikt (bijvoorbeeld `x123`, `xv456`, `xs789`); die zijn op iOS en Android gelijk voor dezelfde server |
| `query` | bij smart: zoekwoorden, gescheiden door komma's (bijvoorbeeld `"sport, voetbal, F1"`) |
| `types` | bij smart: welke soorten mogen erin, bijvoorbeeld `["channel","movie","series"]` |
| `group` | optioneel: beperkt tot een categorie |
| `sourceID` | optioneel: beperkt tot één server |
| `order` | volgorde |
| `updatedAt` | ISO-8601 |
| `deleted`, `deletedAt` | tombstone, zelfde regels als bij profielen |

Samenvoegen: per item wint de nieuwste `updatedAt`.

**Startscherm per profiel.** In `profile.<id>` het veld `homeLayout` = `{rows:[{key, visible}], updatedAt}`.
- Vaste rij-sleutels:
  - `continue` (Verder kijken), `mylist`, `top10`, `foryou` (Voor jou), `recent` (Onlangs toegevoegd)
  - `live` (Live nu / favoriete zenders), `movies`, `series`
  - `categories` (rijen per categorie)
  - `collection:<id>` voor elke collectie
- Onbekende sleutels negeren. Nieuwe collecties komen standaard zichtbaar onderaan.
- Het hele object wint op `updatedAt`.

**Terugkijk-correctie per zender.** Elke bron in `get_sources`/`put_sources` krijgt het gedeelde veld `catchupOffsets: {"<channelID>": minuten}`. Een getal, mag negatief zijn, van −120 tot 120. Bij het afspelen van terugkijken wordt het begintijdstip met dit aantal minuten verschoven. Op iOS en Android gelijk; ook de website bewaart het onaangeroerd.

**Kleur per bron.** Elke bron heeft al `avatar.colorIndex`. Gebruik die kleur, uit dezelfde 8 paletten, als badge en accent bij zoekresultaten en waar meerdere bronnen door elkaar staan.

**Evenementzenders.** Herkennen gebeurt alleen lokaal en wordt niet gesynchroniseerd:
- **Herkenning:** zenders in een groep met `PPV`, `EVENT`, `EVENTS`, `LIVE EVENT`, `SPORTS EVENT` of `UFC/WWE/BOXING EVENTS` in de naam, of zendernamen met een datum/tijd en "vs"/"v"/"-" tussen twee namen.
- **Uitlezen** uit de naam: de wedstrijd, de datum en de tijd. Formaten zoals `12/10 20:45`, `2026-10-12 20:45`, `Oct 12 8:45pm`, met tijdzone als die erbij staat, anders lokaal.
- **Tonen:** een nette kaart met de titel (bijvoorbeeld "Ajax – PSV"), de begintijd in de lokale tijd ("vandaag 20:45") en het label **LIVE** zodra die begonnen is.
- **Live TV:** een eigen groep "Evenementen", gesorteerd op begintijd, met verlopen evenementen (meer dan 6 uur oud) onderaan of weg.

**Webconsole** (bingr.online/account → Servers):
- **Wie:** alleen het hoofdaccount; de website kan dat niet controleren, dus iedereen met de inlog kan het, net als in de apps.
- **Bekijken:** de lijst uit `get_sources`.
- **Toevoegen en wijzigen:** M3U (URL en EPG-URL), Xtream (server, gebruikersnaam, wachtwoord, HLS aan of uit) en Stalker (portal-URL en MAC-adres).
- **Plex, Jellyfin, Emby en Stremio:** alleen hernoemen en verwijderen, want daar is een login in de app nodig.
- **Hoofdserver** instellen.
- **Verwijderen** maakt een tombstone.
- **Bewaren:** onbekende velden, het `apple`- en `android`-blok, `secrets` die niet gewijzigd zijn, en `catchupOffsets` blijven onaangeroerd.
- **Wachtwoorden** worden nooit getoond; leeg laten betekent "ongewijzigd".
- **Tijd:** `updatedAt` wordt op nu gezet bij elke wijziging.
- **Collecties:** bekijken, hernoemen, verwijderen en smart-collecties maken via state-section `collections`.


## Build 51: maximaal 6 tegelijk kijken, 15 apparaten, wie kijkt er nu, kijkgeschiedenis van 7 dagen

- **Apparaten:** een account kan op maximaal **15** apparaten ingelogd zijn (dit was 10). Gebruik overal de `limit` uit het antwoord van de server, nooit een vast getal in de app.
- **Tegelijk kijken:** maximaal **6** apparaten tegelijk. device-auth, met `Authorization: Bearer <access_token>`:

| Actie | Body | Antwoord |
|---|---|---|
| `stream_start` | `{device_id, profile_id, profile_name, title, kind ("live"\|"movie"\|"episode"), content_id}` | `{ok}`, of **403** `{error:"stream_limit", limit, streams:[…]}` |
| `stream_ping` | `{device_id, title?}` | `{ok}`, of `{stopped:true}`: deze stream telt niet meer (bijvoorbeeld door een te lange pauze), dus opnieuw `stream_start` |
| `stream_stop` | `{device_id}` | `{ok}` |
| `list_streams` | `{}` | `{limit, streams:[{device_id, device_name, platform, profile_name, title, kind, started_at, last_ping, signed_in_at}]}` |
| `watch_log` | `{days: 7}` | `{entries:[{device_name, platform, profile_name, title, kind, content_id, started_at, ended_at, minutes}]}`, nieuwste eerst |

**De speler:**
- **Starten:** bij het starten van elke stream (live, film of aflevering, ook bij zappen of de volgende aflevering) roep je `stream_start` aan, met het actieve profiel en de titel. Bij een live-zender is dat de zendernaam plus het programma als dat bekend is ("NPO 1 · Journaal").
- **Bij 403** stopt het afspelen en toon je **"Too many people are watching"**: "Your account can be used on up to %d screens at the same time." met de lijst van wie er kijkt (apparaat, profiel en titel). Daaronder de knoppen **Try again** en **Close**.
- **Netwerkfout bij `stream_start`:** gewoon afspelen. Offline wordt niet geblokkeerd.
- **Tijdens het afspelen**, ook bij pauze: elke 30 s `stream_ping`.
- **Bij stoppen of sluiten** en als de app naar de achtergrond gaat (behalve bij beeld-in-beeld of AirPlay/Chromecast): `stream_stop`.
- **Multiview** telt als één stream per apparaat.

**Alleen voor het hoofdprofiel** in Mijn Bingr → Account:
- **Nu aan het kijken**: de rij toont "%d van %d kijken nu". Een tik opent een detailscherm met per stream:
  - het apparaat-icoon en de naam;
  - het profiel;
  - de titel;
  - hoe lang al ("kijkt al 42 min", vanaf `started_at`);
  - "Ingelogd sinds %@" (`signed_in_at`).
  
  Het scherm ververst elke 30 s.
- **Kijkgeschiedenis (7 dagen)**: gegroepeerd per dag, met als kop "Vandaag", "Gisteren" of de dag en datum ("maandag 12 oktober"). Per regel: tijd, titel, profiel, apparaat en hoe lang er gekeken is ("45 min"). Bij een film of aflevering die in de bibliotheek staat, opent een tik de detailpagina.
- **Op de website** staat hetzelfde in bingr.online/account, onder Apparaten.
