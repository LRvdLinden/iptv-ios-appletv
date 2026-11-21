# Build 181: Bingr Premium in de Apple-apps

Het contract met de server staat in `docs/ACCOUNT.md` ("Build 181: Bingr Premium") en de gedeelde gevallen in
`docs/build181_cases.json`. Hier staat wat er in de Apple-apps zit en wat Léon in App Store Connect moet doen.
(English version below.)


> **Build 183 (21-11-2026): nieuwe product-id's.** Bij de eerste producten (`premium.month`, `.halfyear`, `.year`,
> `lifetime49`) stond *Family Sharing* aan; dat kan bij Apple niet meer uit. Die producten worden verwijderd (nog niet
> ingediend) en vervangen door `bingr.premium.monthly`, `bingr.premium.sixmonths`, `bingr.premium.yearly` en `bingr.lifetime4999` (zonder `nl.lrvdlinden.` ervoor), met
> *Family Sharing* **uit**. De oude id's zijn bij Apple voorgoed bezet en worden nergens meer gebruikt. De interne
> plannaam `lifetime49` (database, Stripe-metadata) blijft gelijk.

## Wat er in de app zit

- **StoreKit 2** (`Shared/Account/PremiumStore.swift`), vier producten:

  | Plan | Product-id | Type | Prijs (NL) | Proef |
  |---|---|---|---|---|
  | Maandelijks | `bingr.premium.monthly` | automatisch verlengend abonnement | € 4,99 / maand | 3 dagen gratis |
  | Halfjaarlijks | `bingr.premium.sixmonths` | automatisch verlengend abonnement | € 19,99 / 6 maanden | 3 dagen gratis |
  | Jaarlijks | `bingr.premium.yearly` | automatisch verlengend abonnement | € 29,99 / jaar | 3 dagen gratis |
  | Lifetime | `bingr.lifetime4999` | niet-verbruikbaar | € 49,99 eenmalig | geen |

- Kopen met `appAccountToken` = de account-id, daarna `jwsRepresentation` naar `billing` `apple_verify` en pas dan
  `transaction.finish()` (net als Lifetime in build 167). `Transaction.updates` en `Transaction.unfinished` lopen via
  dezelfde weg; verlengingen, opzeggingen en terugbetalingen komen daarnaast via App Store Server Notifications v2
  binnen bij `apple-notify`.
- **Paywall "Kies je plan"** (`Shared/UI/Components/PremiumPaywall.swift`): schakelaar Maand / Halfjaar / Jaar, kaart
  Premium met de prijs uit StoreKit (`displayPrice`), jaar uitgelicht, "3 dagen gratis" alleen als StoreKit
  (`isEligibleForIntroOffer`) én de server zeggen dat dit account recht heeft op de proef, aparte kaart Lifetime,
  Herstel aankopen, Gebruiksvoorwaarden (Apple-EULA) en Privacy. Op iPhone, iPad, iPhone Duo, Mac en Apple TV
  (focus). Het percentage "voordeliger" rekent de app uit de StoreKit-prijzen, nooit uit vaste bedragen.
- De paywall verschijnt alleen als de server zegt dat dit account Premium nodig heeft (achter de schakelaars
  `new_from_apple` en `existing_from` in het beheer). Staan die uit, dan werkt alles zoals in build 180.
- **Instellingen > Abonnement**: plan, "verlengt op" / "loopt af op", proef tot, en *Abonnement beheren*
  (`showManageSubscriptions`, op de Mac en Apple TV de abonnementenpagina van Apple).
- Verlopen: afspelen geblokkeerd, servers, lijsten en profielen blijven bewaard; het scherm "Kies een plan" met
  Herstel aankopen.
- Bestaande Lifetime-accounts (ook via de oude `nl.lrvdlinden.bingr.lifetime`, € 3,49/€ 4,99, legacy of beheer)
  houden volledige toegang en zien nooit de paywall.
- De Apple-apps tonen geen webprijzen, geen kortingscodes en geen links of QR-codes naar het web. Alleen de bestaande
  EU-link (build 167) blijft achter zijn eigen vlag zoals hij was.
- Pure logica en zelftest: `Shared/Account/Build181.swift`, `tools/selftest/main.swift` (de gevallen uit
  `docs/build181_cases.json`). Lokaal testen in Xcode: `Bingr.storekit` (scheme > Run > Options > StoreKit
  Configuration).

## Waarom een nieuw Lifetime-product (`lifetime49`)

Gekozen is een **nieuw** niet-verbruikbaar product `bingr.lifetime4999`, en **niet** een prijswijziging
van het bestaande `nl.lrvdlinden.bingr.lifetime`:

- Een prijswijziging in App Store Connect gaat op een vaste datum in voor iedereen, los van de schakelaars in het
  beheer. Tot 1 december (en zolang `new_from_apple` uit staat) moet de huidige Lifetime van € 4,99 blijven werken.
- Bestaande kopers houden hun aankoop van het oude product; Herstel aankopen en Gezinsdeling blijven exact hetzelfde.
  De server accepteert **beide** product-id's als Lifetime.
- Omzet, terugbetalingen en de omzetpagina blijven per prijs uit elkaar te houden.
- Na `existing_from` kan het oude product uit de verkoop (*Remove from Sale*): wie het al heeft, houdt het en kan
  het blijven herstellen.

## Wat Léon in App Store Connect moet doen

1. **Overeenkomsten**: controleer bij *Business* dat de *Paid Apps Agreement* actief is (die is er al voor Lifetime).
2. **Abonnementsgroep**: App > *Monetization* > *Subscriptions* > *Create* groep, referentienaam `Bingr Premium`.
   - Lokalisatie van de groep (weergavenaam): NL `Bingr Premium`, EN `Bingr Premium`.
3. **Drie abonnementen in die groep** (*Create* in de groep), elk:
   - Referentienaam en product-id:
     - `Bingr Premium maand` → `bingr.premium.monthly`, duur **1 maand**, prijs **€ 4,99**.
     - `Bingr Premium halfjaar` → `bingr.premium.sixmonths`, duur **6 maanden**, prijs **€ 19,99**.
     - `Bingr Premium jaar` → `bingr.premium.yearly`, duur **1 jaar**, prijs **€ 29,99**.
   - Prijs: kies Nederland als basisland met het bedrag hierboven en laat Apple de andere landen afleiden.
   - *Family Sharing*: uit (één account per abonnement, zoals Lifetime).
   - Lokalisaties (NL en EN), zie de teksten hieronder.
   - *Introductory Offer* > *Create*: alle landen, start nu, geen einddatum, type **Free**, duur **3 days**.
   - Review-informatie: schermafbeelding van de paywall (iPhone) en de review-notitie hieronder.
4. **Niveaus in de groep** (*Subscription Levels*, sleep in deze volgorde): 1 = jaar, 2 = halfjaar, 3 = maand.
   Dan is jaar een upgrade (gaat meteen in) en maand een downgrade (gaat in bij de volgende verlenging).
5. **Lifetime € 49,99**: *In-App Purchases* > *Create*, type **Non-Consumable**, referentienaam
   `Bingr Lifetime 49,99`, product-id `bingr.lifetime4999`, prijs **€ 49,99**, *Family Sharing* uit,
   lokalisaties NL en EN (zie hieronder). Het oude `nl.lrvdlinden.bingr.lifetime` laten staan zoals het is.
6. **App Store Server Notifications**: App > *App Information* > *App Store Server Notifications*: versie **2**,
   productie- en sandbox-URL zijn de bestaande `apple-notify`-URL (zoals voor Lifetime). Niets veranderen als dat
   al zo staat; controleer het met *Request a Test Notification*.
7. **Koppelen aan de build**: bij versie 1.1.0 (build 181) onder *In-App Purchases and Subscriptions* de drie
   abonnementen en `lifetime49` toevoegen en samen met de build ter beoordeling sturen (de eerste abonnementen moeten
   met een nieuwe app-versie mee).
8. **App-beschrijving**: voeg de tekst over abonnementen hieronder toe aan de beschrijving (NL en EN). De links naar
   Gebruiksvoorwaarden (Apple-EULA) en Privacy (`https://bingr.online/privacy`) staan in de paywall; zet de
   privacy-URL ook bij *App Privacy* en de EULA bij *App Information* (standaard-EULA van Apple volstaat).
9. **Sandbox testen**: TestFlight gebruikt de sandbox; abonnementen verlengen daar versneld (1 maand ≈ 5 minuten).
   Laat in het beheer *Test met mijn account* aanstaan om de paywall op je eigen account te zien.
10. **Pas daarna** in het beheer `new_from_apple` aanzetten (zie het rapport bij build 181 voor de volgorde).

### Teksten (NL)

- Groep: **Bingr Premium**
- Maand: weergavenaam **Bingr Premium (maand)**, beschrijving *Alles van Bingr, per maand.*
- Halfjaar: weergavenaam **Bingr Premium (halfjaar)**, beschrijving *Alles van Bingr, per half jaar.*
- Jaar: weergavenaam **Bingr Premium (jaar)**, beschrijving *Alles van Bingr, per jaar.*
- Lifetime: weergavenaam **Bingr Lifetime**, beschrijving *Alles van Bingr, voor altijd. Eenmalig.*
- Beschrijving App Store (blok onderaan):
  > Bingr Premium: kies een maand-, halfjaar- of jaarabonnement (nieuwe accounts krijgen de eerste 3 dagen gratis) of
  > Lifetime met één aankoop. Het abonnement wordt via je Apple-account betaald en verlengt automatisch, tenzij je het
  > ten minste 24 uur voor het einde van de periode opzegt in Instellingen > Apple-account > Abonnementen. Een ongebruikt
  > deel van de gratis proef vervalt bij aankoop van een abonnement.
  > Gebruiksvoorwaarden: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ · Privacy: https://bingr.online/privacy

### Texts (EN)

- Group: **Bingr Premium**
- Month: display name **Bingr Premium (monthly)**, description *All of Bingr, billed monthly.*
- Half year: display name **Bingr Premium (6 months)**, description *All of Bingr, billed every 6 months.*
- Year: display name **Bingr Premium (yearly)**, description *All of Bingr, billed yearly.*
- Lifetime: display name **Bingr Lifetime**, description *All of Bingr, forever. One-time purchase.*
- App Store description (block at the end):
  > Bingr Premium: choose a monthly, 6-month or yearly subscription (new accounts get the first 3 days free) or
  > Lifetime with a single purchase. Payment is charged to your Apple Account and the subscription renews
  > automatically unless cancelled at least 24 hours before the end of the period in Settings > Apple Account >
  > Subscriptions. Any unused part of a free trial is forfeited when you purchase a subscription.
  > Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ · Privacy: https://bingr.online/privacy

### Review-notitie (EN, voor App Review)

> Bingr is an IPTV player; users add their own playlist or Xtream server. Bingr Premium (monthly, 6-month or yearly
> auto-renewable subscription with a 3-day free trial for new accounts, or a one-time Lifetime purchase) unlocks
> playback. Purchases are made with StoreKit only; there are no external links or prices in the app. "Restore
> purchases" is on the plan screen and in Settings > Account > Subscription, where "Manage subscription" opens
> Apple's subscription management. Demo account: (fill in the review account from App Review Information).

---

# Build 181: Bingr Premium in the Apple apps (EN)

- Four StoreKit 2 products: `bingr.premium.monthly` (€ 4.99 / month), `.halfyear` (€ 19.99 / 6 months)
  and `.year` (€ 29.99 / year) in the subscription group *Bingr Premium*, each with a 3-day free introductory offer,
  plus the non-consumable `bingr.lifetime4999` (€ 49.99, no trial). The existing
  `nl.lrvdlinden.bingr.lifetime` stays as it is for existing buyers (restore keeps working); the server accepts both
  as Lifetime.
- The paywall "Choose your plan" appears only when the server says this account needs Premium (switches
  `new_from_apple` / `existing_from` in the admin). With the switches off everything works as in build 180.
- Steps in App Store Connect: see the Dutch list above (group, three subscriptions with levels year > half year >
  month and a 3-day free introductory offer, the non-consumable `lifetime49`, Server Notifications v2 to the existing
  `apple-notify` URL, attach all four to version 1.1.0, subscription text in the description, then turn on
  `new_from_apple` in the admin).
