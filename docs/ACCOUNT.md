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
