# Build 167: Lifetime kopen in de Apple-apps

Het contract met de server staat in `docs/ACCOUNT.md` ("Build 167: alleen Lifetime"). Hier staat wat er in de
Apple-apps zit en wat Léon zelf nog moet doen.

## Wat er in de app zit

- **StoreKit 2** (`Shared/Account/LifetimeStore.swift`): non-consumable `nl.lrvdlinden.bingr.lifetime`.
  - Kopen met `product.purchase(options: [.appAccountToken(<account-id>)])`.
  - Daarna `jwsRepresentation` naar `billing` `apple_verify`, en pas dan `transaction.finish()`.
  - `Transaction.updates` vanaf de start, `Transaction.unfinished` na het inloggen.
  - Herstel aankopen: `AppStore.sync()` + `Transaction.currentEntitlements`, alles naar `apple_verify`.
  - De prijs komt alleen uit StoreKit (`displayPrice`).
- De koopknop verschijnt pas als de server `entitlements.iap.apple: true` meldt (beheer: `app_settings.iap`).
- **Activeer Lifetime** (`Shared/UI/Components/LifetimeOnly.swift`): schermvullend bij `access == "activate"`,
  en ook na een 403 `activation_required` van `stream_start`.
- **Aankondiging** "Bingr wordt Lifetime op <datum>" op Home en in Instellingen > Abonnement, zonder code of korting.
- Pure logica en zelftest: `Shared/Account/Build167.swift`, `tools/selftest/main.swift`.
- De Apple-apps tonen nooit de kortingscode, een prijs van het web, een link of een QR-code naar de betaalpagina.
  De enige uitzondering is de EU-link hieronder, achter de flag.

## Wat Léon moet doen

1. **App Store Connect**
   - In-app aankoop aanmaken: type *Non-Consumable*, product-id `nl.lrvdlinden.bingr.lifetime`, prijs naar keuze.
   - Aansluiten bij het App Store Small Business Program.
   - App Store Server Notifications V2: de URL van `apple-notify` uit `docs/ACCOUNT.md` invullen (productie en sandbox).
   - De aankoop meesturen met de eerste build die hem gebruikt (bij "In-App Purchases" van de versie).
2. **Pas daarna** in het beheer `iap.apple` aanzetten. Dan pas tonen de apps de koopknop.

## Testen in Xcode (`Bingr.storekit`)

- In Xcode: *Product > Scheme > Edit Scheme… > Run > Options > StoreKit Configuration* = `Bingr.storekit`.
  Het bestand staat in de hoofdmap van de repo en zit niet in de app.
- Let op: transacties uit Xcode zijn niet door Apple ondertekend. `apple_verify` wijst ze af (geen keten tot
  Apple Root CA - G3). Met dit bestand test je dus het koopvenster en de knoppen, niet het activeren op de server.
- Voor de hele keten (kopen → `apple_verify` → Lifetime): een sandbox-account met TestFlight of een
  ontwikkelbuild zonder StoreKit-configuratie. De server slaat Sandbox-aankopen op als `test`.
- De koopknop verschijnt alleen als de server `iap.apple: true` meldt.

## EU External Purchase Link (nog niet aangezet)

De code staat klaar (alleen iPhone en iPad, iOS 17.4+). De knop "Verder naar bingr.online" verschijnt alleen als alle
drie de voorwaarden gelden:

- de server meldt `upgrade.link_eu_apple: true` (beheer: `app_settings.upgrade_link.apple_eu`);
- `ExternalPurchaseLink.canOpen` is true;
- de storefront ligt in de EU.

`ExternalPurchaseLink.open()` toont zelf het verplichte informatieblad van Apple. Zonder de entitlement is `canOpen`
false, dus nu verschijnt er niets.

De entitlement en de plist-sleutels staan bewust **niet** in het project. Zodra Apple de entitlement heeft
toegekend, voeg dan in `project.yml` bij target `Bingr` het volgende toe:

```yaml
    entitlements:
      properties:
        # StoreKit External Purchase Link Entitlement (EU), alleen na toekenning door Apple
        com.apple.developer.storekit.external-purchase-link: true
    info:
      properties:
        # één link per EU-storefront (landcode ISO 3166-1 alpha-2, kleine letters)
        SKExternalPurchaseLink:
          nl: https://bingr.online/upgrade/
          be: https://bingr.online/upgrade/
          de: https://bingr.online/upgrade/
          # … de andere EU-landen waarvoor de entitlement geldt
```

Daarna:

- Controleer de sleutelnamen tegen de actuele documentatie van Apple ("StoreKit External Purchase Link Entitlement
  (EU)"), want Apple wijzigt die regels geregeld. Doe dat ook voor `SKExternalPurchaseMultiLink`, dat vanaf iOS 18.1
  bestaat.
- Apple vraagt bij deze entitlement een maandelijkse melding van de aankopen buiten de app, via de External Purchase
  Server API, en een commissie. Dat deel zit niet in deze build en moet er dan nog bij.
- Zet daarna in het beheer `upgrade_link.apple_eu` aan.
