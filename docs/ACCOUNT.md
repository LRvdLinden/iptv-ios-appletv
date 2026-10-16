# Bingr-account: contract (iOS, iPadOS, tvOS, macOS, Android, Android TV, Samsung TV/Tizen, website)

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
| Uitloggen | `POST {URL}/auth/v1/logout?scope=local` + `Authorization: Bearer <access_token>` | 204. Alleen de sessie van dít apparaat (zonder `scope=local` logt Supabase alle apparaten uit). Daarna altijd lokaal wissen, ook als dit mislukt. |
| Tv-code starten | `POST {URL}/functions/v1/device-auth` `{"action":"start","device":"Apple TV"}` | `{code, poll_secret, url, expires_in, interval}` |
| Tv-code pollen | idem `{"action":"poll","code","poll_secret"}` om de `interval` (3) seconden | `{status:"pending"}` / `{status:"expired"}` (nieuwe code starten) / `{status:"approved", token_hash, email}` |
| Tv-sessie ophalen | `POST {URL}/auth/v1/verify` `{"type":"magiclink","token_hash":…}` | 200: sessie |
| Tv koppelen (telefoon/Mac) | device-auth `{"action":"approve","code","name"?}` + `Authorization: Bearer <access_token>` | `{ok:true, device, name}` of 404 `{error:"invalid_code"}` of 400 `{error:"name_too_long"}` (naam max. 40 tekens; wordt de naam van het apparaat zodra het zich aanmeldt, en blijft staan) |
| Soort apparaat bij een code | device-auth `{"action":"code_info","code"}` + `Authorization` | `{ok:true, device, kind, label}` (voor het naamveld "Apple TV - …") of 404 `{error:"invalid_code"}` |
| Account verwijderen | device-auth `{"action":"delete_account"}` + `Authorization: Bearer <access_token>` | `{ok:true}`, daarna lokaal uitloggen |

**Sessie** = `{access_token, refresh_token, expires_in, expires_at?, user:{id, email}}`. Bewaar `refresh_token`, `access_token`, `expires_at` (nu + expires_in) en `email`. Bewaar ze **alleen op dit apparaat**: op Apple in de sleutelhanger zonder iCloud-sync (refresh tokens zijn eenmalig, dus delen tussen apparaten werkt niet), op Android in de app-opslag. Bij het starten van de app: is er een refresh_token, ga dan door naar "Wie kijkt er?" en vernieuw op de achtergrond. Komt daar 400/401 uit, ga dan terug naar het inlogscherm.

Tv-code tonen als `K7Q-4MX` (3 + 3). Bij het invoeren hoofdletters maken en `-` en spaties weghalen.

## Schermen

**Inlogscherm op telefoon, tablet en Mac** (Netflix-stijl): zwarte achtergrond met een gedimde, licht vervaagde collage van posters (covers uit de bibliotheek als die er zijn, anders een donker verloop met rood), bovenaan het Bingr-logo. Daaronder een kaart met de kop **"Sign In"** of **"Create account"**, de velden **E-mail** en **Password** (met tonen/verbergen), een rode volle knop, en een foutmelding in oranje/rood onder de velden. Daaronder: "Forgot password?", en "New to Bingr? **Sign up now.**" / "Already have an account? **Sign in.**". Wachtwoord minimaal 6 tekens. Tijdens het laden een spinner in de knop.

**Inlogscherm op tv** (Apple TV, Android TV, Fire TV), zoals Netflix:
- Links: **"Sign in with your phone"**, "Scan the QR code with your phone's camera" + grote witte QR-code (de `url` uit start) + "Or go to **bingr.online/koppelen** and enter this code:" + de code groot (`K7Q-4MX`). De code ververst automatisch als hij verloopt. Onderaan "Waiting for confirmation…" met een spinner.
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

- `bingr.online/koppelen?code=XXXXXX` (oude link `bingr.online/tv` stuurt door): inloggen (of account maken) en de tv koppelen.
- `bingr.online/bevestigen/?token_hash=…&type=…&lang=…[&next=…]`: alle links in de accountmails (bevestigen, wachtwoord, inloglink, uitnodiging, e-mailwijziging) gaan hierheen, nooit naar `…supabase.co/auth/v1/verify`. De pagina bevestigt pas na een klik (`POST /auth/v1/verify` met `token_hash`), zodat linkscanners de eenmalige link niet opmaken. Bij `recovery` gaat hij daarna door naar `bingr.online/reset`. `next` is de `redirect_to` van de aanvraag (bv. `koppelen/?code=…`, `web/`); alleen adressen op bingr.online worden gevolgd. De apps hoeven hiervoor niets te veranderen: de `redirect_to` bij wachtwoord vergeten mag blijven zoals hij is.
- `bingr.online/reset`: nieuw wachtwoord instellen (na `bevestigen/`, en voor oude links met `#access_token`).
- `assets/config.js` (`window.BINGR_SUPABASE = {url, anonKey}`) wordt bij de deploy uit de secrets gemaakt.

## Gekoppelde apparaten (max. 15, was 10 tot build 51)

Elk apparaat heeft een eigen, vaste **device_id** (UUID). Die wordt één keer aangemaakt en alleen lokaal bewaard: op Apple in de sleutelhanger zonder iCloud-sync, op Android in de app-opslag. Hij blijft bestaan na uitloggen.

Alle aanroepen gaan naar device-auth, met `Authorization: Bearer <access_token>`:

| Actie | Body | Antwoord |
|---|---|---|
| `register_device` | `{device_id, name, platform}` | `{ok, limit}`, of **403** `{error:"device_limit", limit, devices:[…]}` |
| `heartbeat` | `{device_id}` | `{ok}`, of `{revoked:true}`: het apparaat is verwijderd, dus direct lokaal uitloggen (zonder de logout-aanroep) en terug naar het inlogscherm. Sinds build 60: **401** bij een ongeldig/verlopen token (sessie vernieuwen en opnieuw proberen; alleen een mislukte refresh met 400/401 logt uit) en **503** als de server tijdelijk niet kan controleren (niets doen). |
| `list_devices` | `{device_id}` | `{limit, devices:[{device_id, name, platform, created_at, last_seen_at, signed_in_at, current}]}`, nieuwste gebruik eerst |
| `remove_device` | `{device_id}` | `{ok}`. De sessie van dat apparaat wordt ingetrokken, zodat het apparaat uitlogt. |

- **name**: de naam van het apparaat (op iOS `UIDevice.current.name`, op de Mac `Host.current().localizedName`, op Android `Settings.Global.DEVICE_NAME` of anders `Build.MODEL`).
- **platform**: een van `iPhone`, `iPad`, `Apple TV`, `Mac`, `Android`, `Android tablet`, `Android TV`, `Google TV`, `Fire TV`, `tizen` (Samsung TV, build 55), `browser` (webspeler op bingr.online, build 62).

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
| `put_sources` | `{sources:[…], mainSourceID}` | `{ok, updatedAt}`. Stuurt altijd de **hele** lijst, inclusief tombstones. Maximaal 512 KB, 100 bronnen. Sinds build 60 voegt de server samen (zie "Build 60"). |

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
| `profile.<profielID>` | per profiel: `myList`, `favorites`, `progress` (`{key: {position, duration, updatedAt, …}}`), `watched` (set van sleutels), `history` (lijst met tijd), `recentChannels`, `prefs` (kijkvoorkeuren), `pin` (de pincode zoals de app hem nu bewaart, of `null`), `updatedAt`. Sleutels voor inhoud zijn op iOS en Android al gelijk (bijvoorbeeld `ep:<serieID>\|s-e`). Het precieze formaat staat bij "Build 60". |
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
  - Samsung TV (Tizen, build 55): `tizen`. Apps tonen dit als "Samsung TV" met een tv-icoon.
  - Android: `Fire TV` als `Build.MANUFACTURER == "Amazon"`. `Google TV` als het een tv is en `packageManager.hasSystemFeature("com.google.android.feature.GOOGLE_EXPERIENCE")` waar is, of als `Build.MODEL` "Chromecast" bevat of `Build.BRAND` "google" is. Anders `Android TV`.
- **Iconen per platform:** gebruik in de apparatenlijst dezelfde soort iconen als iOS.
  - iPhone: telefoon. iPad: tablet. Mac: laptop of computer. Apple TV: Apple TV-kastje.
  - Android: telefoon. Android tablet: tablet. Android TV, Google TV, Fire TV en Samsung TV (`tizen`): tv.
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
| `stream_ping` | `{device_id, title?, kind?, content_id?}` | `{ok}`, of `{stopped:true}`: deze stream telt niet meer (geen ping in 90 s, of gestopt op een ander apparaat), dus opnieuw `stream_start` (dat controleert de limiet opnieuw). Ook Multiview moet hierop reageren. |
| `stream_stop` | `{device_id}` | `{ok}` |
| `list_streams` | `{}` | `{limit, streams:[{device_id, device_name, platform, profile_id, profile_name, title, kind, started_at, last_ping, signed_in_at}]}` |
| `watch_log` | `{days: 7}` | `{entries:[{device_name, platform, profile_id, profile_name, title, kind, content_id, started_at, ended_at, minutes}]}`, nieuwste eerst (max. 1000) |

**De speler:**
- **Starten:** bij het starten van elke stream (live, film of aflevering, ook bij zappen of de volgende aflevering) roep je `stream_start` aan, met het actieve profiel en de titel. Bij een live-zender is dat de zendernaam plus het programma als dat bekend is ("NPO 1 · Journaal").
- **Bij 403** stopt het afspelen en toon je **"Too many people are watching"**: "Your account can be used on up to %d screens at the same time." met de lijst van wie er kijkt (apparaat, profiel en titel). Daaronder de knoppen **Try again** en **Close**.
- **Netwerkfout bij `stream_start`:** gewoon afspelen. Offline wordt niet geblokkeerd.
- **Tijdens het afspelen**, ook bij pauze: elke 30 s `stream_ping`.
- **Bij stoppen of sluiten** en als de app naar de achtergrond gaat (behalve bij beeld-in-beeld of AirPlay/Chromecast): `stream_stop`.
- **Multiview** telt als één stream per apparaat.
- **Limiet van de IPTV-provider (los van Bingr):** de streamlimiet van Bingr is onze eigen telling (`account_streams`) en geldt ongeacht wat de IPTV-provider toestaat; de providerlimiet wordt nooit als Bingr-limiet gebruikt. Een Xtream-provider heeft daarnaast een eigen limiet (`player_api.php` → `user_info.max_connections` / `user_info.active_cons`). De apps lezen die bij het ophalen van de accountinfo en tonen hem in de serverinfo ("Provider: max X verbindingen"). **Mislukt het afspelen** (HTTP 401/403/458/509 of de stream start niet) én is `active_cons >= max_connections` (met `max_connections > 0`), dan toont de app in plaats van een algemene fout: "Je IPTV-abonnement staat maximaal %d verbinding(en) tegelijk toe en die zijn in gebruik. Dit is een limiet van je provider, niet van Bingr." / "Your IPTV subscription allows up to %d connection(s) at the same time and they are all in use. This is a limit of your provider, not of Bingr." Er wordt **niet** vooraf geblokkeerd op `active_cons` (die telling van de provider loopt achter). Bij M3U-bronnen is er geen providerinfo en dus geen controle.

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

## Wachtwoord gewijzigd: overal uitgelogd

Een database-trigger op `auth.users` wist bij elke wachtwoordwijziging alle sessies, alle gekoppelde apparaten en alle lopende streams van dat account. Dat geldt ook voor wijzigingen via bingr.online/reset. De apps hoeven hier niets nieuws voor te doen. Bij de volgende heartbeat (bij openen, terugkeer naar de voorgrond of binnen 5 minuten) geeft de server `revoked`, en het verversen van de sessie geeft 400/401. Dan gaat de app naar het inlogscherm.

## Geblokkeerd account (build 82 apps, server build 83)

Het beheer kan een account blokkeren (met reden en einddatum, of voor onbepaalde tijd). De blokkade is de ban van het
auth-account (`banned_until`); reden, einddatum en geschiedenis staan in `account_blocks`. De klant krijgt een mail vanaf
support@bingr.online ("Je Bingr-account is geblokkeerd", met reden en tot wanneer), bij opheffen "weer actief" en bij
verwijderen een bevestiging.

**De sessies blijven bij een blokkade bestaan** (alleen lopende streams worden gestopt). Daardoor kan de app het verschil
zien tussen "geblokkeerd" en "gewoon uitgelogd". Wat de server teruggeeft:

| Waar | Antwoord bij een geblokkeerd account |
|---|---|
| Inloggen `POST /auth/v1/token?grant_type=password` | 400 `{error_code:"user_banned", msg:"User is banned"}` |
| Vernieuwen `POST /auth/v1/token?grant_type=refresh_token` | 400 `{error_code:"user_banned", msg:"Invalid Refresh Token: User Banned"}` (de refresh token bestaat nog) |
| Tv-sessie `POST /auth/v1/verify` (magiclink) | 403 `{error_code:"user_banned"}` |
| device-auth, elke actie met inloggen (`heartbeat`, `register_device`, `config`, `list_devices`, `approve`, `code_info`, …) | **401** `{error:"user_banned", banned:true, reason:"banned"}`, ook met een access token van vóór de blokkade |
| device-auth `poll` (tv-code, het goedkeurende account is geblokkeerd) | 403 `{status:"banned", error:"user_banned", banned:true}`; de code vervalt |
| support `mine` / `my_devices` | 401 `{error:"user_banned", banned:true}`; een nieuw ticket maken kan wel (als gast) |

**Herkennen in de app** (zo doen Apple, Android en Samsung TV het sinds build 82): een antwoord is "geblokkeerd" als
`banned === true`, of `error_code`/`error`/`code`/`reason` gelijk is aan `user_banned`, `banned` of `account_blocked`, of
de tekst (`msg`/`message`/`error_description`) "banned" bevat. Dan lokaal uitloggen (geen logout-aanroep) en op het
inlogscherm de melding tonen: *"Je account is geblokkeerd. Je hebt een e-mail gekregen met de reden en tot wanneer.
Vragen? Ga naar support.bingr.online."* Let op: Android en Samsung TV vernieuwen bij een 401 eerst de sessie; dat geeft
door de ban ook `user_banned`, dus beide routes komen bij de melding uit. Na opheffen kan de klant gewoon weer inloggen.

**Website:** bingr.online/account, /koppelen, de webspeler en support.bingr.online (/mijn, /nieuw) tonen dezelfde melding
bij inloggen en als een lopende sessie `user_banned` krijgt.

## Build 52: intro-markeringen, accentkleur, deinterlacing en laatste zender

Vier nieuwe sleutels in `settings.shared`, op iOS en Android gelijk. Zoals alle instellingen wint het geheel met de nieuwste `updatedAt`.

| Sleutel | Waarde | Standaard |
|---|---|---|
| `accentColor` | `"red"`, `"blue"`, `"green"`, `"purple"`, `"orange"` of `"pink"` | `"red"` |
| `deinterlace` | `"off"`, `"auto"` of `"on"` (alleen voor VLC-afspelen) | `"auto"` |
| `resumeLastChannel` | `true`/`false`: na het kiezen van een profiel meteen de laatst bekeken zender van dat profiel openen | `false` |
| `introMarkers` | `{"<serverID>:<serieID>": {introStart, introEnd, creditsStart}}`, in seconden; een veld mag ontbreken of `null` zijn | `{}` |

- **`serverID`** is de `id` van de bron zoals in `get_sources`/`put_sources`. **`serieID`** is de lokale serie-id die ook in `ep:<serieID>|s-e` staat.
- Sleutels worden zonder onderscheid tussen hoofdletters en kleine letters vergeleken.
- Een item waarvan alle drie de velden leeg zijn, telt als gewist.
- **Intro:** zonder `introStart` loopt de intro vanaf het begin van de aflevering. Zolang de speler in de intro zit, staat er een knop **Intro overslaan** in beeld.
- **Aftiteling:** vanaf `creditsStart` verschijnt de kaart **Volgende aflevering**. Na 10 seconden aftellen start die automatisch.
- Het app-icoon (alleen op Apple) wordt niet gesynchroniseerd.
- **Sinds build 54** staat `accentColor` per profiel in `account_data.profiles` (zie "Build 54"); `settings.shared.accentColor` is alleen nog de bron voor de migratie.

## Build 54: accentkleur per profiel, app-icoon alleen hoofdprofiel, collecties per profiel

### Accentkleur per profiel

Elk profiel heeft een eigen accentkleur. Die staat in `account_data.profiles`, dus bij het profiel zelf: hij blijft na een update of herinstallatie en volgt het profiel naar elk apparaat.

| Veld (per profiel in `profiles`) | Waarde | Ontbreekt |
|---|---|---|
| `accentColor` | `"red"`, `"blue"`, `"green"`, `"purple"`, `"orange"` of `"pink"` | `"red"` |

- **Wijzigen** (Mijn Bingr → Uiterlijk, elk profiel): zet `accentColor` bij het actieve profiel, zet `updatedAt` = nu en upload de profielenlijst (zoals bij naam of avatar). `accentColor` hoort bij de velden die bij "server nieuwer" worden overgenomen.
- **Samenvoegen:** is de server nieuwer en heeft hij `accentColor`, neem die over. Ontbreekt `accentColor` op de server (een oudere app), laat de lokale waarde staan. Heeft het profiel lokaal nog geen kleur en de server wel, neem die van de server over (ook als de server niet nieuwer is).
- **Toepassen:** bij het kiezen van een profiel en zodra de kleur van het actieve profiel (ook via de sync) verandert, meteen de hele interface in die kleur. "Wie kijkt er?" houdt de laatste kleur.
- **Migratie (eenmalig per apparaat):** is `settings.shared.accentColor` bekend (build 52/53) en heeft een profiel nog geen `accentColor`, kopieer die oude kleur dan naar **alle bestaande profielen** zonder eigen kleur. Doe dit pas nadat de profielen van de server zijn toegepast, zodat een kleur die een ander apparaat al per profiel bewaarde voorgaat. Daarna gaat de wijziging gewoon mee met de profielenlijst. Is er geen oude kleur, dan gebeurt er niets (rood).
- **Na de migratie** wordt `settings.shared.accentColor` niet meer gelezen en niet meer geschreven. De waarde blijft op de server staan (bij het samenvoegen van `settings` blijft hij onaangeroerd), zodat oudere apps blijven werken.

### App-icoon alleen voor het hoofdprofiel (alleen Apple)

- Alleen het hoofdprofiel (`isMain`, hetzelfde profiel dat servers, kinderslot en de kijkgeschiedenis van het account beheert) ziet de keuze voor het app-icoon. Andere profielen zien in Uiterlijk alleen de accentkleuren.
- Het icoon blijft een instelling van het apparaat (UserDefaults `ui.appIcon`) en wordt niet gesynchroniseerd. Bij het starten wordt de bewaarde keuze gelijkgetrokken met het icoon dat het systeem toont (iPhone/iPad, blijft na een update staan) of opnieuw als Dock-icoon gezet (Mac).

### Collecties per profiel

Elk profiel heeft zijn eigen collecties; elk profiel mag ze maken, wijzigen, herschikken en verwijderen, ook een kinderprofiel. De inhoud komt uit de bibliotheek van dat profiel, die al op leeftijd gefilterd is: een kinderprofiel ziet in een (slimme of handmatige) collectie dus alleen wat door het kinderfilter komt.

State-section `collections`:

```json
{
  "version": 2,
  "profiles": {
    "<profielID>": {
      "items": [ { "id": "…", "name": "…", "image": {…}, "kind": "manual|smart", "items": […], "query": "…",
                   "types": […], "group": "…", "sourceID": "…", "order": 0, "updatedAt": "ISO-8601",
                   "deleted": true, "deletedAt": "ISO-8601" } ],
      "updatedAt": "ISO-8601"
    }
  },
  "items": [ … ],
  "migratedAt": "ISO-8601",
  "updatedAt": "ISO-8601"
}
```

- **`profiles`**: per profiel-ID (zoals in `account_data.profiles[].id`, en zoals in `profile.<id>`) een emmer met `items` en `updatedAt` (= de nieuwste `updatedAt` van de items erin). Een collectie-item heeft precies het formaat van build 51 (zie hierboven).
- **`version: 2`**: de section is gemigreerd. Zonder `version` (of < 2) en zonder `profiles` is het nog het oude formaat.
- **`items`** op het hoogste niveau: de oude collecties van build 51–53 (voor het hele account). Apps van build 54 lezen ze alleen voor de migratie en laten ze daarna onaangeroerd staan (oudere apps lezen ze nog).
- **Collectie-ID's** zijn uniek binnen een profiel. Dezelfde `id` mag in meerdere profielen voorkomen (na de migratie is dat zo); `homeLayout` in `profile.<id>` blijft `collection:<id>` gebruiken.
- **Samenvoegen:** per profiel en per collectie-`id` wint de nieuwste `updatedAt`, ook een tombstone. Tombstones ouder dan 90 dagen mogen weg. Onbekende velden en emmers van profielen die het apparaat (nog) niet kent blijven onaangeroerd. De emmer van een verwijderd profiel (tombstone in `account_data.profiles`) gaat weg.
- **Migratie** (eerste build 54-app die de section leest en `version` < 2 ziet): elke oude collectie uit `items` (en lokale collecties van vóór build 54) gaat naar **elk bestaand profiel** dat nog geen collectie met die `id` heeft, met dezelfde `id`, `order` en `updatedAt`. Zo verdwijnt er niets en blijven de startscherm-rijen werken. Daarna `version: 2`, `migratedAt` = nu en uploaden. Doen twee apparaten dit tegelijk, dan levert dat dezelfde items op (zelfde `id` en `updatedAt`). Profielen die later worden aangemaakt beginnen leeg.
- **Sinds build 74 (Apple): alleen eigen collecties.** Een profiel ziet en wijzigt alleen de collecties in zijn eigen emmer, nooit die van het hoofdprofiel of van een ander profiel. De migratie hierboven zet oude collecties (uit `items` en lokale zonder profiel) alleen nog in de emmer van het **hoofdprofiel**. Kopieën die build 54–73 bij andere profielen zette en die sindsdien niet gewijzigd zijn (zelfde `id` en `updatedAt` als de oude collectie in `items` of als die van het hoofdprofiel), worden in die profielen tombstones (`deleted`, `updatedAt` = nu), zodat ze op alle apparaten verdwijnen. Het formaat (`version: 2`, emmers per profiel) blijft gelijk.
- **Uploaden:** bij elke eigen wijziging (ongeveer 3 seconden vertraging) de hele section, met alle emmers.

### Apple Vision Pro

Build 54 ondersteunt Apple Vision Pro niet meer (`SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: NO`).

## Build 59: taal van titels, voorkeurstaal en automatische ondertitels

### Instellingen (`settings.shared` en `profile.<id>.prefs`)

| Sleutel | Waarde | Standaard |
|---|---|---|
| `audioLanguage` | ISO 639-1 (`"nl"`, `"en"` …); `""` = de app-taal | `""` |
| `subtitleLanguage` | voorkeurstaal ondertitels, ISO 639-1; `""` = de app-taal. Het oude `"off"` betekent nu `autoSubtitles: "off"`. In `prefs` heet dit veld `streamSubtitleLanguage` (zoals sinds build 44). | `""` |
| `autoSubtitles` | `"off"`, `"whenNeeded"` of `"always"` (was `true`/`false`). Lezen: `true` → `"always"`, `false` → `"whenNeeded"`. | `"whenNeeded"` |

- **Audio:** heeft een stream meer dan één audiotaal, dan kiest de speler bij de start de voorkeurstaal (AVPlayer via de media-selectie, VLC via `:audio-language`), daarna nog eens op naam/taalcode zodra de sporen bekend zijn.
- **`whenNeeded`:** alleen als de gesproken taal (gekozen audiospoor, anders het taallabel van de titel, anders de originele taal uit TMDB) bekend is en verschilt van de voorkeurstaal, en er nog geen ondertitels in die taal in beeld zitten (`NL SUBS`). Eerst een ondertitelspoor uit de stream, anders op de achtergrond de beste treffer van OpenSubtitles (IMDb-id, anders TMDB-id, met seizoen/aflevering; met de bestandshash als dat kan), automatisch aan, met de melding "Ondertitels: Nederlands (OpenSubtitles)".
- **`always`:** altijd ondertitels in de voorkeurstaal (eerst uit de stream, anders OpenSubtitles), behalve als ze al in beeld zitten.
- Het afspelen wacht nooit op ondertitels.

### Taal van een titel (`ContentLanguage`)

Volgorde: titel → categorie → originele taal uit TMDB (alleen als die al geladen is; op de cover iets gedimd).

- **Titel:** labels vooraan (`NL | `, `NL: `, `|NL| `, `[NL] `, `NL - `, `EN-`), tussen haken waar dan ook (`(IT)`, `[NL]`, `(NL SUBS)`, `(MULTI)`, `(ITA/ENG)` = dual), en achteraan zonder haken (`NL SUBS`, `MULTI`, `DUAL`, `NL GESPROKEN`, ` - NL`).
- **Woorden die ook een code zijn** (`IN`, `NO`, `US`, `SO`, `AL`, `IT`): alleen tussen haken of met `|`. `IT - ` mag (Italiaans), `IT: Chapter Two` niet. `(IN)` = Hindi.
- **`(UK)` / `(US)`** tellen als Engels maar blijven in de titel staan (landversie, bijv. "The Office (UK)").
- **Categorie:** codes van 2–3 letters alleen in hoofdletters (`NL Films`, `VOD | DE`), volledige namen in elke schrijfwijze (`Italian Movies`).
- **Weergave:** de titel zonder label ("Animal (IT)" → "Animal"); een strook onderaan de poster: `IT`, `EN · NL ondertitels`, `Multi`. Detailpagina: "Taal: Italiaans". Zoeken en koppelen gebruiken de opgeschoonde titel.

### Andere taal

Dezelfde titel in een andere taal: zelfde TMDB-id als die van beide bekend is, anders zelfde opgeschoonde titel en jaar (±1). Alleen versies met een ander taallabel. Detailpagina: knop **"Andere taal"**; in de speler onder Audio & ondertitels, met bij één audiospoor "Deze stream heeft één audiotaal". Wisselen in de speler hervat op dezelfde plek; elke versie houdt verder haar eigen voortgang.

## Build 60: backend-hardening en het volledige formaat van de gedeelde gegevens

### Server (device-auth)

- **Fouten** zijn altijd JSON `{error}` zonder interne details: 400 `bad_json` / `bad_section` / `bad_sources` / `device_id_missing` / `name_missing`, 401 `not_signed_in`, 403 `device_limit` / `stream_limit` / `feature_locked` (abonnementen), 404 `invalid_code`, 413 `too_large` / `too_many_sections`, 500 `server_error` / `decrypt_failed` / `delete_failed`, 503 `unavailable` / `try_again`. Een aanvraag mag maximaal 2 MB zijn.
- **401 = token ongeldig of verlopen**, voor alle acties met inloggen (ook `heartbeat` en `stream_ping`, die gaven eerder `revoked`/`stopped`): sessie vernieuwen en één keer opnieuw proberen. **503** = de server kon het token tijdelijk niet controleren: niets doen, niet uitloggen.
- **Limieten atomair:** `register_device` (apparatenlimiet) en `stream_start` (streamlimiet) tellen en schrijven in één databasetransactie met een slot per account. Gelijktijdige aanvragen kunnen de limiet niet meer overschrijden.
- **Opruimen:** verlopen tv-codes, streams zonder ping (> 1 dag) en kijkgeschiedenis ouder dan 8 dagen worden voor alle accounts opgeruimd, niet alleen bij een nieuwe stream van hetzelfde account.
- **`approve`** claimt een code alleen als hij nog vrij is (of al van jou); twee accounts kunnen niet dezelfde tv koppelen.
- **`delete_account`** verwijdert alle profielfoto's in Storage en daarna de gebruiker; alle tabellen (profielen, servers, onderdelen, apparaten, streams, geschiedenis, tv-codes) gaan mee.
- **`account_data.profiles`** is maximaal 512 KB.

### `put_sources`: samenvoegen op de server

De server voegt de binnenkomende lijst samen met wat er al staat, per `id` (zonder onderscheid tussen hoofd- en kleine letters):
- de versie met de nieuwste `updatedAt` (bij een tombstone `updatedAt`, anders `deletedAt`) wint; bij gelijke tijd de binnenkomende;
- een bron die **alleen op de server** staat blijft staan. Een apparaat met een verouderde lijst kan dus niets meer wissen; **verwijderen gaat altijd via een tombstone**;
- tombstones ouder dan 90 dagen gaan weg;
- `mainSourceID` is altijd die uit de aanvraag.
De apps hoeven hier niets voor te veranderen. De website haalt vóór elke wijziging de nieuwste lijst op en past alleen de gewijzigde velden toe.

### `settings` (section): alle gedeelde sleutels

`{shared:{…}, apple:{…}, android:{…}, updatedAt}`. Het geheel met de nieuwste `updatedAt` wint. Wie schrijft, houdt onbekende sleutels in `shared` en het blok van het andere platform onaangeroerd (lees eerst de serverversie en pas alleen eigen sleutels aan).

| Sleutel in `shared` | Waarde |
|---|---|
| `appLanguage` | taalcode (`"nl"`, `"en"` …) of `""` = systeemtaal. Oud: `language`. |
| `playerEngine` | `"auto"`, `"apple"`, `"exo"` of `"vlc"`; een onbekende waarde betekent `"auto"` en blijft op de server staan |
| `subtitleSize` | `"small"`, `"medium"` of `"large"` |
| `audioLanguage` | ISO 639-1, `""` = app-taal, `"stream"` = niets kiezen (zoals de stream) |
| `subtitleLanguage` | taal van **ondertitels in de stream**, ISO 639-1; `""` = app-taal; oud `"off"` = `autoSubtitles: "off"` |
| `autoSubtitles` | `"off"`, `"whenNeeded"` of `"always"`; oud `true` → `"always"`, `false` → `"whenNeeded"` |
| `openSubtitlesLanguage` | standaardtaal voor zoeken bij OpenSubtitles (`""` = alle) |
| `openSubtitlesLanguages` | lijst met taalcodes |
| `startScreen` | `"home"`, `"live"`, `"movies"` of `"series"` |
| `hiddenTabs` | lijst met `"live"`, `"movies"`, `"series"` |
| `introMusic` | true/false |
| `refreshInterval` | de raw value van het verversbeleid (gelijk op iOS en Android) |
| `categorySort` | `"standard"` of een andere sorteerwijze |
| `parentalControl`, `parentalAutoLockAdult` | true/false (lezen: ook een object `parentalControl: {enabled, autoLockAdult}`) |
| `traktScrobble`, `traktAskRating` | true/false |
| `deinterlace`, `resumeLastChannel`, `introMarkers` | zie build 52 |
| `accentColor` | alleen nog voor de migratie (build 54); niet meer schrijven, wel laten staan |

### `profile.<id>` (section): het volledige formaat

| Veld | Inhoud |
|---|---|
| `myList`, `favorites`, `watched`, `recentChannels` | lijst `[{id, at}]` (aanwezig). Een verwijdering mag ook in de lijst staan als `{id, removed:true, at}`. |
| `progress` | `{"<sleutel>": {position, duration, fraction, updatedAt, title, artwork?, playlistID?}}` (seconden; `fraction` 0…1) |
| `history` | lijst `{id, itemID, playlistID?, title, subtitle?, artwork?, type ("live"\|"movie"\|"series"\|"episode"), channelID?, at, date}`, nieuwste eerst, max. 500. `at` en `date` zijn dezelfde tijd (iOS schreef `at`, Android/Tizen `date`); schrijf allebei, lees wat er is. |
| `removed` | **verwijderingen**: `{"myList": {id: at}, "favorites": {…}, "watched": {…}, "recentChannels": {…}, "progress": {sleutel: at}, "history": {id: at}}`. Per item wint de nieuwste tijd. Verwijderingen ouder dan 90 dagen mogen weg. |
| `prefs` | `{autoSubtitles, audioLanguage, streamSubtitleLanguage, subtitleLanguage, updatedAt}`; `null` = niet ingesteld (dan geldt `settings.shared`). **Let op:** in `prefs` is `subtitleLanguage` de **OpenSubtitles**-taal en `streamSubtitleLanguage` de taal van ondertitels in de stream (in `settings.shared` heten die `openSubtitlesLanguage` en `subtitleLanguage`). Oud `autoSubtitles: false` in `prefs` = niet ingesteld. |
| `pin`, `pinUpdatedAt` | pincode of `null`, met eigen tijd |
| `homeLayout` | zie build 51 |
| `updatedAt` | tijd van de laatste upload |

- **Lezen:** accepteer verwijderingen in alle drie de vormen: `removed.<veld>`, `{removed:true}` in de lijst/in een `progress`-item, en de oudere iOS-velden `progressRemoved` / `historyRemoved` (en `<veld>Removed`).
- **Schrijven:** zet verwijderingen altijd in `removed` (Android en Tizen lezen alleen die vorm voor `progress` en `history`). Haal `removed` nooit weg; iOS-apps van vóór build 60 schrijven daarnaast `progressRemoved` / `historyRemoved`, laat die staan.

### `collections`: wanneer is het gemigreerd

Gemigreerd (version 2) als `version >= 2` **of** als er een object `profiles` is. Alleen dan niet opnieuw migreren.

### Profielen (`account_data.profiles`): alle velden

`id`, `name`, `avatar {symbol, colorIndex, emoji?}`, `kids`, `ageLimit` (getal of `null`), `isMain`, `order`, `accentColor` (build 54), `photo` (build 40, `{path, updated}` of `null`), `updatedAt`, en bij een tombstone `deleted`, `deletedAt`. Onbekende velden blijven staan.

## Build 62: appversies, berichten en de webspeler

### `register_device` en `heartbeat`: app- en systeemversie

Beide acties accepteren twee optionele velden. De server bewaart ze bij het apparaat (`account_devices.app_version` / `os_version`) en werkt ze bij elke aanroep bij; ontbreekt een veld of is het leeg, dan blijft de oude waarde staan.

| Veld | Inhoud | Voorbeeld |
|---|---|---|
| `app_version` | versie en build, max. 40 tekens | `"1.0.0 (62)"` |
| `os_version` | systeem en versie, max. 40 tekens | `"iOS 26.1"`, `"tvOS 26.0"`, `"macOS 26.1"`, `"Android 15"`, `"Tizen 9.0"`, `"Chrome 141 / macOS"` |

Stuur ze bij **elke** `register_device` en `heartbeat`. Antwoorden en foutcodes blijven gelijk.

**Webspeler:** `platform` = `"browser"`, `name` = browser + systeem, bijvoorbeeld `"Chrome op Mac"`, `"Safari op iPhone"`, `"Edge op Windows"`. De apps tonen `browser` in de apparatenlijst als "Webbrowser" met een globe-icoon (Apple: `globe`, Android: `Icons.Default.Language`).

### Berichten (`announcements`)

device-auth `{"action":"announcements","lang":"nl"}` met `Authorization: Bearer <access_token>`:

```json
{"items":[{"id":"<uuid>","title":"…","body":"…","created_at":"ISO-8601"}]}
```

- Alleen actieve berichten: niet verlopen en jonger dan 30 dagen; nieuwste eerst, max. 5.
- `lang` `"en"` (of `"en-…"`) geeft de Engelse tekst als die er is; elke andere taal (en ontbrekend) geeft Nederlands.
- `body` is platte tekst; regels gescheiden door `\n`, alinea's door `\n\n`. Https-links mogen klikbaar worden.
- **Wanneer:** na login en bij het starten met een geldige sessie, en bij terugkeer naar de voorgrond (hooguit eens per uur).
- **Tonen:** elk nog niet gezien bericht één keer, oudste eerst, als melding met titel, tekst en een knop **OK** (NL "OK"). Daarna het `id` lokaal als gezien bewaren (per apparaat, niet per profiel; max. 50 id's onthouden).
- **Fouten:** stil, nooit blokkeren. 401/503 zoals elders.

### Webproxy (`web-proxy`) voor de webspeler

IPTV-servers sturen zelden CORS-headers en draaien vaak op **http**. Een https-pagina (bingr.online) mag niets van http laden (mixed content: de browser blokkeert API, M3U, XMLTV, afbeeldingen én video). De webspeler haalt daarom alles van een http-server via deze Edge Function op (aan de serverkant geldt die beperking niet); https-servers eerst direct, en alleen bij een CORS-/netwerkfout via de proxy.

**POST** `{URL}/functions/v1/web-proxy`, headers `apikey`, `Authorization: Bearer <access_token>`, `Content-Type: application/json`, body:

| Veld | Inhoud |
|---|---|
| `url` | volledige **http**- of **https**-URL |
| `range` | optioneel, bv. `"bytes=0-1048575"` |

**Token** voor de GET-vorm: `POST {"action":"token"}` (met JWT) geeft `{token, expires_at}`. Het token (`<user-id>.<verloopt>.<HMAC-SHA256>`, sleutel afgeleid van `BINGR_SOURCES_KEY`, dus geen extra secret) is **6 uur** geldig; de webspeler haalt het na het inloggen op en ververst het ruim voor het verloopt.

**GET** `{URL}/functions/v1/web-proxy?u=<base64url van de URL>&t=<token>` voor `<video>`, hls.js en Safari's eigen HLS-speler (die geen `Authorization`-header kunnen meesturen). De `Range`-header van de browser gaat mee; een open bereik (`bytes=N-`) voor een bestand wordt per 8 MB beantwoord (206 met `Content-Range`), zodat één aanvraag binnen de tijdslimiet blijft en de browser zelf het volgende stuk vraagt. Afbeeldingen krijgen `Cache-Control: private, max-age=86400`.

- **HLS-afspeellijsten herschrijven (alleen GET):** is het antwoord een HLS-afspeellijst (content-type `mpegurl` of een pad op `.m3u8`, én de inhoud heeft `#EXT-X-`-regels; een IPTV-zenderlijst in M3U-vorm blijft ongemoeid), dan wordt elke URI absoluut gemaakt t.o.v. het adres ná doorverwijzingen en vervangen door een GET-URL van de proxy: regels zonder `#` (varianten, segmenten) en `URI="…"` in `#EXT-X-KEY`, `-MAP`, `-MEDIA`, `-I-FRAME-STREAM-INF`, `-SESSION-KEY`, `-PART`, `-PRELOAD-HINT`, `-RENDITION-REPORT`. Andere schema's (`skd://`, `data:`) blijven staan. Zo haalt de browser varianten, segmenten en sleutels ook via de proxy op. Die URL's dragen een extra parameter `s` (HMAC over gebruiker + URL): daarmee mag de proxy ook naar de host waar de afspeellijst naar verwijst (Xtream-servers sturen streams vaak door naar een ander IP of CDN).
- **Segmenten en MP4** gaan gestreamd door (niet gebufferd), met `Range`. Een doorlopende live-`.ts`-stream loopt tegen de tijdslimiet aan: de webspeler gebruikt voor Xtream live en terugkijken daarom HLS (`/live/<user>/<pw>/<id>.m3u8`, `/timeshift/…/<id>.m3u8`).
- **Antwoord:** de body van de server met dezelfde status (200, 206, 404 …) en `Content-Type`, `Content-Length`, `Content-Range`, `Accept-Ranges`. De header **`X-Final-URL`** geeft het adres na doorverwijzingen.
- **Alleen eigen servers:** de begin-URL moet een host hebben uit de eigen bronnen van het account (`get_sources`: `m3uURL`, `epgURL`, `serverURL`; ook subdomeinen van hetzelfde domein), of een door de proxy zelf ondertekende URL uit een afspeellijst zijn (`s`). Doorverwijzingen (max. 5) volgt de proxy zelf, http ↔ https en naar elke publieke host. Nooit naar interne adressen (localhost, 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, IPv6-literals …), ook niet via een doorverwijzing, en waar de runtime het kan ook na DNS-opvraging. Een net toegevoegde bron werkt binnen ongeveer een minuut.
- **Grenzen:** max. 200 MB per aanvraag (afspeellijsten 4 MB), 120 s per aanvraag, 600 aanvragen per minuut per account (POST en GET samen).
- **Fouten van de proxy zelf** zijn JSON `{error}`: 400 `bad_json` / `bad_url` / `bad_range`, 401 `not_signed_in` (POST) / `bad_token` (GET), 403 `host_not_allowed`, 413 `too_large`, 429 `rate_limited`, 502 `upstream_failed`, 503 `unavailable`, 504 `timeout`. Een fout van de IPTV-server zelf komt gewoon door met zijn eigen status.
- **CORS:** alleen voor `https://bingr.online` (en `http://localhost` / `127.0.0.1` om te testen); methoden GET, POST, OPTIONS; header `Range` toegestaan.
- **Kosten:** alles via de proxy (bij http-servers ook alle video) kost dataverkeer en aanroepen van Supabase. Sommige aanbieders blokkeren datacenter-IP's of staan maar één verbinding tegelijk toe; dan werkt de webspeler voor die server niet of alleen als er niet tegelijk in een app wordt gekeken.

### Beheer (alleen intern)

Er is een aparte Edge Function `admin` voor het beheer-dashboard (https://beheer.bingr.online). Beide staan in de privé-repo LRvdLinden/bingr-beheer en worden daar gedeployd; de Backend-workflow hier raakt de functie niet. De tabellen en `bingr_admin_*`-functies die hij gebruikt staan wel hier in `supabase/schema.sql`. Apps roepen `admin` nooit aan; de enige openbare actie is `unsubscribe` (vanaf `bingr.online`). Het enige wat apps ervan merken: berichten (hierboven), en dat e-mails met berichten een afmeldlink naar `bingr.online/unsubscribe/` hebben. Accountmails (bevestigen, wachtwoord) worden altijd verstuurd.

## Status en monitoring (bingr.online/status)

Een aparte Edge Function `status` controleert elke 5 minuten de backend, de website en de downloads. Apps roepen die niet aan; ze hoeven er niets voor te doen.

- **`ping`** (nieuw in device-auth en web-proxy): `{action:"ping"}` geeft `{ok:true}`, zonder inloggen en zonder database. Alleen voor de statuscontrole.
- **Openbaar:** `GET /functions/v1/status?action=public` (of POST `{action:"public"}`), zonder sleutel, ~60 s in de cache. Antwoord: `{generated_at, overall:{state, down, degraded}, groups:[{id, name:{nl,en}, monitors:[{id, name:{nl,en}, state, checked_at, ms24, uptime:{d1,d7,d30,d90}, days:[{d, u, s}] (90 dagen)}]}], incidents:[{id, monitor_id, name, started_at, ended_at, duration_s}] (30 dagen)}`. `state` is `up`, `degraded` (verminderd) of `down`; `s` per dag ook `none` (geen gegevens). Alleen openbare monitors; nooit gebruikers- of apparaataantallen.
- **Intern** (header `x-status-secret` = function-secret `STATUS_CRON_SECRET`, alleen pg_cron en de functie `admin`): `run` (controleren), `admin` (alles, ook niet-openbare monitors, actieve apparaten per platform en de planning), `checks`, `monitor_save`, `monitor_delete`. Het beheer gebruikt dit via `admin` `{action:"status", op:…}`.
- **Regels:** time-out 10 s per controle. Eén fout = verminderd, twee fouten op rij = storing (incident open), twee goede controles op rij = storing voorbij. Trager dan 5 s = verminderd; TLS-certificaat van bingr.online minder dan 14 dagen geldig = verminderd. Uptime telt alleen storingen als uit.
- **Tabellen:** `status_monitors`, `status_checks` (ruwe controles, 90 dagen bewaard), `status_daily` (dagtotalen, Nederlandse tijd), `status_incidents`. Alleen de service role kan erbij.
- **Planning:** pg_cron-taak `bingr-status` (elke 5 min) roept via pg_net de functie aan. De Backend-workflow zet de taak bij elke deploy opnieuw klaar met het geheim; dat staat nooit in de repo.
- **Meldingen:** bij het openen en sluiten van een storing een e-mail naar `BINGR_ALERT_EMAIL` (optioneel), via dezelfde SMTP-instellingen als de berichten.

## Build 68: kijkstatistieken (zoals Trakt)

De server houdt per profiel bij hoeveel er gekeken is: per lokale dag, per soort (film, serie, live) en per titel. Hij telt dat zelf op uit `stream_start` / `stream_ping` / `stream_stop`; de apps sturen alleen een paar extra velden mee en lezen het resultaat met `watch_stats`.

### `stream_start`: extra velden (optioneel)

| Veld | Inhoud |
|---|---|
| `series_id` | bij een aflevering: de serie-id van de app (max. 200 tekens), dezelfde id als in `ep:<serieID>\|s-e`, voortgang en collecties |
| `series_title` | bij een aflevering: de serietitel (max. 200) |
| `tz` | IANA-tijdzone van het apparaat, bv. `"Europe/Amsterdam"`; bepaalt op welke dag de kijktijd valt |

- `kind`: `"movie"`, `"episode"` of `"live"`; `"catchup"` (terugkijken) telt als live. Een andere waarde telt niet mee (wel voor de limiet en de geschiedenis).
- `content_id` blijft: bij een film de film-id, bij een aflevering de afleverings-id, bij live de zender-id.
- `stream_ping` accepteert ook `series_id` / `series_title` (alleen nodig als de titel wisselt zonder nieuwe `stream_start`; normaal: bij elke nieuwe titel `stream_start`).
- **Oudere apps** sturen deze velden niet. Dan: tijdzone `Europe/Amsterdam`; serie = de titel vóór `S<n>E<n>` / `S<n>:E<n>` (en vóór ` · `), sleutel `t:<serietitel in kleine letters>`. Die sleutel is anders dan de `series_id` van nieuwe apps, dus dezelfde serie kan in de overgangsperiode twee keer in de lijst staan.
- **Live:** de zendernaam is het deel van `title` vóór ` · ` ("NPO 1 · Journaal" → "NPO 1"). Stuur dus zoals nu de zendernaam vooraan.

### Hoe de server telt

- **Tabel** `account_watch_stats` (alleen service role, RLS zonder policies): `user_id, profile_id, profile_name, day (lokale dag in tz), kind (movie|episode|live), item_key, title, episodes (text[], unieke afleverings-id's, max. 500), minutes (numeric), plays (int), updated_at`. Sleutel: `(user_id, profile_id, day, kind, item_key)`.
- **`item_key`**: film = `content_id`; aflevering = `series_id` (oude apps: `t:<serietitel>`); live = `content_id` van de zender. Zonder `content_id`: `t:<titel>`.
- **`title`**: filmtitel (deel vóór ` · `), serietitel, zendernaam.
- **Kijktijd:** bij elke `stream_ping` en `stream_stop` (en bij een nieuwe `stream_start` op hetzelfde apparaat) telt de server de tijd sinds het laatst getelde moment (`account_streams.last_accounted_at`) bij de titel die liep, **max. 3 minuten per keer** (een gat telt niet). Was de stream al verlopen (geen ping in 90 s), dan alleen tot de laatste ping. Pauze telt mee zolang de app pingt (zoals bij de limiet).
- **Weergaven:** één `plays` per `stream_start`.
- **Afleveringen:** elke afleverings-`content_id` waarvoor kijktijd is geteld, komt (uniek) in `episodes`.
- **Bewaren:** 400 dagen (opruimen in `bingr_cleanup`). `delete_account` wist alles (on delete cascade).
- **Start:** eenmalig gevuld uit de bestaande kijkgeschiedenis (max. 8 dagen terug, Nederlandse tijd). Echte telling vanaf 13 oktober 2026.

### `watch_stats` (ingelogd)

Body: `{period: "week"|"month"|"year" (standaard "month"), offset: 0 (0 = huidig, -1 = vorige …, min. -600; positief = 0), profile_id?: string (ontbreekt/null/"" = alle profielen), tz?: IANA (standaard Europe/Amsterdam)}`. Een week loopt van maandag t/m zondag; "vandaag" is de datum in `tz`.

```json
{
  "period": "month", "offset": 0, "from": "2026-10-01", "to": "2026-10-31", "label_hint": "2026-10",
  "tz": "Europe/Amsterdam", "profile_id": null,
  "totals": {
    "minutes": 1260,
    "movies": {"count": 4, "minutes": 410},
    "series": {"shows": 3, "episodes": 17, "minutes": 690},
    "live": {"channels": 6, "minutes": 160}
  },
  "by_bucket": [{"key": "2026-10-01", "minutes": 95, "movie_minutes": 0, "episode_minutes": 80, "live_minutes": 15}, …],
  "top": {
    "series": [{"title": "Bluey", "item_key": "xs7", "minutes": 300, "episodes": 9}],
    "movies": [{"title": "Dune", "item_key": "xv5", "minutes": 155}],
    "channels": [{"title": "NPO 1", "item_key": "x12", "minutes": 90}]
  },
  "profiles": [{"profile_id": "…", "profile_name": "Léon", "minutes": 900}],
  "since": "2026-10-06"
}
```

- **Alle minuten zijn hele getallen** (afgerond); `totals.minutes` is de afgeronde som, dus niet altijd precies de som van de afgeronde delen.
- **`label_hint`**: week `"2026-W42"` (ISO-week), maand `"2026-10"`, jaar `"2026"`. Apps maken hun eigen label uit `from`/`to` ("12–18 okt", "oktober 2026", "2026").
- **`by_bucket`**: altijd compleet en op volgorde, ook dagen zonder kijktijd (0): per dag (`"YYYY-MM-DD"`) bij week en maand, per maand (`"YYYY-MM"`, 12 stuks) bij jaar.
- **`top`**: max. 10 per soort, meeste minuten eerst; alleen titels met minstens 1 minuut. Tellers (`count`, `shows`, `channels`) tellen ook alleen titels met minstens 1 minuut. `episodes` = unieke afleveringen in de periode.
- **`profiles`**: alleen bij alle profielen (`profile_id` null), anders `[]`. Naam zoals het profiel nu heet (`account_data`), anders de naam van toen. `profile_id` `null` = kijktijd van een oude app zonder profiel.
- **`since`**: eerste dag met gegevens (voor dit profiel / alle profielen), of `null` als er nog niets is. Toon dan de lege staat: "Statistieken worden bijgehouden vanaf 13 oktober 2026" (EN "Statistics are being kept since 13 October 2026").
- `item_key` is bij nieuwe apps de eigen id (film-id, `series_id`, zender-id): een tik kan de detailpagina openen als die titel in de bibliotheek staat. `t:…` = afgeleid van de titel (geen id).

### `delete_watch_stats` (ingelogd)

`{profile_id?}` → `{ok:true}`. Met `profile_id`: alleen dat profiel; zonder (of `null`/`""`): het hele account. Roep dit ook aan bij het verwijderen van een profiel (tombstone), zodat de statistieken van dat profiel meteen weg zijn.

### Wie ziet wat (in de apps)

- **Hoofdprofiel** (`isMain`): Mijn Bingr → **Statistieken** met alle profielen samen, en een filter "Alle profielen" + per profiel (rond avatar). Mag ook de statistieken van een ander profiel of alles wissen.
- **Ander profiel en kinderprofiel:** alleen de eigen statistieken (`profile_id` = het actieve profiel), zonder filter; "Statistieken wissen" wist alleen het eigen profiel.
- De server weet niet welk profiel actief is: deze beperking gebeurt in de app, net als bij de andere onderdelen die alleen het hoofdprofiel ziet (nu aan het kijken, kijkgeschiedenis).
- **Website** (bingr.online/account, sectie Statistieken): alles, met het profielfilter (hoofdaccount). **Webspeler** (Instellingen → Statistieken): zoals de apps.

### Scherm (alle platforms)

Periode **Week / Maand (standaard) / Jaar** met ‹ › om terug en (tot de huidige periode) vooruit te gaan; tegels **Uren gekeken**, **Films** (aantal + uren), **Series** (series, afleveringen, uren), **Live TV** (zenders, uren); een staafgrafiek per dag (week/maand) of per maand (jaar), gestapeld: films in de accentkleur (rood), series blauw `#3B82F6`, live oranje `#F59E0B`; toplijsten series, films en zenders; **Statistieken wissen** met bevestiging.

## Abonnementen: Gratis en Lifetime

Er zijn twee abonnementen. Betalen kan nog niet (de betaalpagina komt later op bingr.online/upgrade/); de server regelt wat elk abonnement mag.

| | **Gratis** (€ 0) | **Lifetime** (€ 4,99 eenmalig) |
|---|---|---|
| Tegelijk kijken (`limits.streams`) | 1 | 3 |
| Ingelogde apparaten (`limits.devices`) | 8 | 15 |
| Servers (`limits.servers`) | 1 | onbeperkt (`null`) |
| Statistieken (`features.stats`) | – | ✓ |
| Nu aan het kijken + kijkgeschiedenis 7 dagen (`features.now_watching`) | – | ✓ |
| Trakt-koppeling (`features.trakt`) | – | ✓ |
| Meer dan één server (`features.multi_server`) | – | ✓ |
| Thema's en accentkleuren (`features.themes`) | – | ✓ |

- **Opslag:** tabel `account_plans` (`user_id` pk → `auth.users` on delete cascade, `plan` `'free'|'lifetime'` standaard `'free'`, `max_streams` / `max_devices` (null = standaard van het abonnement), `source` `'legacy'|'admin'|'purchase'`, `note`, `granted_by`, `created_at`, `updated_at`). RLS: de gebruiker leest alleen zijn eigen rij; schrijven alleen de functies (service role). **Geen rij = Gratis.**
- **Bestaande accounts:** alle accounts die bestonden toen de abonnementen werden ingevoerd, kregen Lifetime cadeau (`source:'legacy'`). Dat gebeurt één keer (markering `plans_legacy_done` in `app_settings`); nieuwe accounts daarna beginnen op Gratis.
- **Beheer:** kan een account Lifetime geven (`source:'admin'`, gratis) en per account `max_streams` (1–50) en `max_devices` (1–200) verhogen, ook bij Gratis.
- **Standaardwaarden** staan in `supabase/functions/_shared/plans.ts` (met unittests in `plans_test.ts`); apps gebruiken altijd de getallen uit `entitlements`, nooit een vast getal.

### `entitlements` (device-auth, ingelogd)

Body `{platform?, device_id?}`; `platform` is één van `ios`, `ipados`, `tvos`, `macos`, `android`, `androidtv`, `tizen`, `web`. Zonder `platform` neemt de server het platform van het geregistreerde apparaat (`device_id`); onbekend = geen upgrade-link.

```json
{
  "plan": "free",
  "limits": { "streams": 1, "devices": 8, "servers": 1 },
  "features": { "stats": false, "now_watching": false, "trakt": false, "multi_server": false, "themes": false },
  "upgrade": { "url": "https://bingr.online/upgrade/", "link": true, "price": "€ 4,99", "price_en": "€4.99" }
}
```

- Hetzelfde object staat als `entitlements` in het antwoord van **`heartbeat`** (platform van dat apparaat, of `platform` in de body) en **`config`** (met `platform`/`device_id` in de body). Kon de server het niet bepalen, dan ontbreekt het veld: houd dan de laatst bekende waarde aan.
- **`upgrade.link`**: per platform in te stellen in het beheer (`app_settings`, sleutel `upgrade_link` = `{"apple": false, "android": true, "androidtv": true, "tizen": true, "web": true}`; `apple` geldt voor ios, ipados, tvos en macos). Standaard **uit voor Apple**: de Apple-apps tonen dan wel de vergelijking Gratis/Lifetime, maar **geen link, knop of QR-code** naar de betaalpagina. Staat het aan, dan opent de app `upgrade.url` (mag `?from=app&platform=<platform>` meegeven; op een tv als QR-code).
- Prijs: `price` (Nederlands) en `price_en` (Engels).

### Afdwingen

| Wat | Waar | Gratis-account |
|---|---|---|
| Tegelijk kijken | server: `stream_start` | **403** `{error:"stream_limit", limit, plan, streams:[…]}` (zelfde vorm als voorheen, plus `plan`) |
| Ingelogde apparaten | server: `register_device` | **403** `{error:"device_limit", limit, plan, devices:[…]}` (bestaande apparaten blijven ingelogd) |
| Statistieken | server: `watch_stats` | **403** `{error:"feature_locked", feature:"stats", plan:"free"}` |
| Nu aan het kijken / kijkgeschiedenis | server: `list_streams`, `watch_log` | **403** `{error:"feature_locked", feature:"now_watching", plan:"free"}` |
| Trakt, aantal servers, thema's en accentkleuren | alleen in de apps, op `features` / `limits.servers` | – |

- `register_device`, `list_devices`, `stream_start` en `list_streams` geven `limit` = de limiet van het abonnement (of de eigen limiet).
- De kijktijd wordt ook voor Gratis-accounts bijgehouden (`stream_start/ping/stop`), zodat de statistieken er na het upgraden meteen zijn. `delete_watch_stats` werkt altijd.
- **In de apps bij `feature_locked`:** een slotje met de vergelijking en (als `upgrade.link`) de knop **Upgrade naar Lifetime**. Bij Gratis met meer servers dan `limits.servers`: alleen de hoofdserver gebruiken; servers worden nooit gewist.

### Website

- **bingr.online** (homepage): vergelijkingstabel Gratis / Lifetime met **Maak gratis een account** en **Upgrade naar Lifetime** (→ /upgrade/).
- **bingr.online/upgrade/**: ingelogd het huidige abonnement (`entitlements` met `platform:"web"`) en de vergelijking; zolang betalen niet gekoppeld is een uitgeschakelde knop "Betalen — binnenkort beschikbaar". Niet ingelogd: eerst inloggen, daarna terug naar /upgrade/. Parameters `?from=app&platform=…` worden geaccepteerd.
- **Mijn Bingr** (/account/): "Abonnement: Gratis/Lifetime" met de limieten en een Upgrade-link; Statistieken en Nu aan het kijken met een slotje voor Gratis.
