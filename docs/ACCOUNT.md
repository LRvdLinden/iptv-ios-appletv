# Bingr-account: contract (iOS, iPadOS, tvOS, macOS, Android, Android TV, website)

Inloggen is **verplicht**. Flow: **splash → (geen geldige sessie) inlogscherm → "Wie kijkt er?" → app**. Met een geldige sessie gaat de app na de splash direct naar "Wie kijkt er?". Uitloggen brengt je terug naar het inlogscherm.

De account regelt in deze versie alleen het inloggen. Servers, profielen en voortgang blijven zoals ze zijn (iCloud op Apple, lokaal op Android).

## Configuratie

- `SUPABASE_URL` (bv. `https://abcd1234.supabase.co`) en `SUPABASE_ANON_KEY` (publiek, `eyJ…` of `sb_publishable_…`).
- iOS: `Secrets.supabaseURL` / `Secrets.supabaseAnonKey`, ingebouwd door `tools/inject_keys.py` uit de omgevingsvariabelen. Ze staan alleen in `builtIn` en worden **niet** in de sleutelhanger gezet en niet in de app aangepast.
- Android: `BuildConfig.SUPABASE_URL` / `BuildConfig.SUPABASE_ANON_KEY` (build.gradle: `key("SUPABASE_URL")`, `key("SUPABASE_ANON_KEY")`).
- Zijn ze leeg, dan toont het inlogscherm "Accounts are not configured in this build." en is er (alleen dan) een knop "Continue without account". Zo blijft een build zonder sleutels bruikbaar.

## Endpoints (gewone REST, geen SDK)

Elke aanvraag krijgt de header `apikey: <ANON_KEY>` en `Content-Type: application/json`.

| Wat | Aanvraag | Antwoord |
|---|---|---|
| Account maken | `POST {URL}/auth/v1/signup` `{email, password}` | 200: sessie (zie onder) **of** een user zonder `access_token`. Dan moet het e-mailadres eerst bevestigd worden: toon "Check your inbox to confirm your email address, then sign in." |
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
