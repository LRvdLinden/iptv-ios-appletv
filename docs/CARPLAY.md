# CarPlay (build 171)

De code voor radio in CarPlay staat klaar (`iOS/CarPlay/CarPlaySceneDelegate.swift`): een lijst met radiozenders
(favorieten bovenaan) en Now Playing (`CPNowPlayingTemplate`). Zolang Apple de entitlement niet heeft gegeven, staat
CarPlay **uit**: de klasse compileert mee, maar wordt nooit gestart.

## Wat Léon moet doen

1. Bij Apple de CarPlay-entitlement aanvragen: <https://developer.apple.com/contact/carplay/> → soort **Audio**
   (`com.apple.developer.carplay-audio`) voor de bundle-id `nl.lrvdlinden.bingr`.
2. Na goedkeuring in het Developer-portaal het provisioningprofiel van `nl.lrvdlinden.bingr` (iOS) opnieuw laten maken
   (de entitlement moet erin staan; automatisch ondertekenen in Xcode doet dat vanzelf na het vernieuwen).
3. In `project.yml`, target **Bingr** (iOS):

   - onder `entitlements:` → `properties:` deze regel toevoegen:

     ```yaml
             com.apple.developer.carplay-audio: true
     ```

   - onder `info:` → `properties:` → `UIApplicationSceneManifest:` → `UISceneConfigurations:` (naast
     `UIWindowSceneSessionRoleExternalDisplayNonInteractive`) toevoegen:

     ```yaml
             CPTemplateApplicationSceneSessionRoleApplication:
               - UISceneConfigurationName: CarPlay
                 UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).CarPlaySceneDelegate
     ```

4. Nieuwe build: in de CarPlay-simulator (Xcode → I/O → External Displays → CarPlay) of in de auto testen.

Zonder stap 1 en 2 weigert Xcode het ondertekenen zodra de regel uit stap 3 erin staat; zet hem er dus pas daarna in.

## Hoe het werkt

- De zenderlijst komt uit `RadioPlayer.shared.stations()`: de radiozenders van de open server, al gefilterd voor het
  actieve profiel (kinderprofiel: alleen toegestane zenders), favorieten bovenaan.
- Kiezen = `RadioPlayer.play` (alleen geluid, telt als stream met `kind: "radio"`), daarna Now Playing.
- Vorige/volgende zender via de knoppen in Now Playing (`MPRemoteCommandCenter`).
