# Bingr op de iPhone Duo (build 179)

iPhone Duo (iOS 27): binnenscherm 1878×2670 px = **626×890 pt** (@3x, reguliere breedte en hoogte), buitenscherm
1398×2034 px = **466×678 pt** (@3x; portret compact/regulier, landschap compact/compact). Bronnen: Apples
richtlijn *Designing for iPhone Duo* (HIG), de tech talks *Prepare your app for iPhone Duo*, *Raise the bar with
iPhone Duo* en *Strike a pose with adaptive layouts on iPhone Duo*, en de SwiftUI-interface van de iOS 27.2-SDK
(Xcode 27.2 op de runner `xcode-27`).

## Xcode en SDK

- `ReservedRegion`, `GeometryProxy.reservedRegions(kind:options:)`, `ArrangementView`, `toolbarVerticalEdge`,
  `toolbarVerticalBehavior` en `onHingeChange` bestaan vanaf de **iOS 27.1-SDK** (`@available(anyAppleOS 27.1, *)`).
  Pas met Xcode 27.1 of nieuwer gebruikt de app het hele scherm en staan tabbalk en toolbars verticaal aan de zijkant.
- De gewone CI (`compileren`) draait nog op Xcode 16; die code staat daarom achter `#if compiler(>=6.4) && canImport(SwiftUICore, _version: 8.0.85)` (SwiftUICore 8.0.85 = Xcode 27.1; Xcode 27.0 heeft 8.0.84 zonder `ReservedRegion`, Swift is in beide 6.4) en
  `if #available(iOS 27.1, *)`. De job `sdk27` in `build.yml` (alleen op verzoek: `inputs[sdk27]=true`) compileert iOS
  met de nieuwste Xcode 27 op de runner `xcode-27`, zodat die code ook echt gecontroleerd wordt.
- **Léon: maak de TestFlight-build met Xcode 27.1 of nieuwer**, anders draait Bingr op de iPhone Duo in de
  compatibiliteitsmodus (iPhone-verhouding met zwarte randen) en zie je de aanpassingen hieronder niet.

## Wat is aangepast

- **Tabbladen per size class** (`MainTabView`, regels in `Duo179.tabs`): compact (buitenscherm, iPhone, iPad in een
  smal venster) = de iPhone-tabbladen (max. 5), regulier (binnenscherm, iPad) = ook Categorieën, Zoeken en Downloads.
  Bingr gebruikt de systeem-`TabView`; die zet de tabbalk met de iOS 27.1-SDK zelf verticaal aan de zijkant. Zelfde
  tabbladen in dezelfde volgorde; staat je op Zoeken of Downloads bij dichtklappen, dan naar Home (Zoeken zit daar als
  vergrootglas, Downloads in Mijn Bingr).
- **Radio-minispeler**: met de tabbalk aan de zijkant onderin naast de zijbalk in plaats van 58 pt boven een tabbalk
  die er niet is.
- **Tv-gids** en **Sport-kaarten**: telefoon- of brede layout per size class (niet meer "is dit een iPhone"). De gekozen
  zender en dag blijven bij open- en dichtklappen.
- **Rasters** (categorie met films/series): op reguliere breedte een even aantal kolommen (binnenscherm portret 2,
  landschap 4), zodat de vouw tussen twee kolommen valt.
- **Speler in tafelstand** (half open, vouw horizontaal): beeld boven de vouw, ondertitels net boven de vouw,
  bediening eronder. Plat of dicht: schermvullend zoals altijd. Doorspelen bij vouwen doet het systeem (geen herladen:
  het is een wijziging van size class, geen nieuwe scene).
- **Diagnose**: schermresolutie van het scherm waar Bingr nu op staat (niet meer `UIScreen.main`).
- **AirPlay-video / CarPlay** (iOS 26, auto staat stil): de Apple-speler heeft `allowsExternalPlayback`; wordt er een
  AirPlay-route actief terwijl VLC speelt, dan wisselt Bingr vanzelf naar de Apple-speler op dezelfde positie (VLC
  eerst dicht, één verbinding). Eén keer per route; rtsp/rtmp blijft VLC. CarPlay-audio tijdens het rijden wisselt niet.

Al in orde (geen wijziging nodig): de detailpagina kiest de brede of smalle knoppenrij op de breedte van de pagina
(`Detail174.isCompact`); bladen, meldingen en menu's zijn systeemonderdelen die zelf om de vouw heen gaan; de app
ondersteunt alle oriëntaties en heeft `UIRequiresFullScreen = false` (Split View op het binnenscherm werkt).

Niet gedaan (bewust): `ArrangementView` voor de speler. De tafelstand is met `ReservedRegion` zelf ingedeeld, omdat
`ArrangementView` op álle iPhones met iOS 27.1 actief wordt en de speler (gebaren, vergrendelen, panelen) daar niet
op gebouwd is. Geen `defaultTabBarPlacement(.sidebar)`: Apple raadt aan de standaardplaatsing te houden.

## Controleren op het toestel (Léon)

1. Dicht (buitenscherm), portret en landschap: tabbalk aan de zijkant, 5 tabbladen, niets onder de camera rechtsboven;
   radio-minispeler naast de tabbalk.
2. Openklappen tijdens het scrollen in Films: zelfde plek in de lijst, tabbladen erbij (Categorieën, Zoeken,
   Downloads), raster 2 (portret) of 4 (landschap) kolommen.
3. Split View op het binnenscherm, Bingr links en rechts: de tabbalk aan de buitenkant, niets onder de bediening.
4. Tv-gids en Sport: brede gids open, telefoon-gids dicht; gekozen zender blijft.
5. Speler: open- en dichtklappen tijdens een live zender en een film: speelt door zonder herladen. Half open op tafel
   (landschap): beeld boven, bediening onder, ondertitels niet in de vouw.
6. Detailpagina (Meer-menu), profielmenu, instellingen, onboarding en het Lifetime-scherm op beide schermen: niets
   afgesneden of onder de camera.
7. Widgets en Live Activity (downloads, radio) in het Dynamic Island van beide schermen.
8. AirPlay: VLC-zender starten, AirPlay naar een Apple TV kiezen via het Bedieningspaneel: Bingr wisselt naar de
   Apple-speler en het beeld gaat naar de tv. In de auto (CarPlay met AirPlay-video, geparkeerd): zelfde.
9. Diagnose: schermresolutie klopt met het scherm waar Bingr op staat.

## App Store-screenshots

Voor de iPhone Duo vraagt App Store Connect (Screenshot specifications) eigen maten. Volgens de schermen:
binnenscherm **1878×2670** (portret) / **2670×1878** (landschap) en buitenscherm **1398×2034** / **2034×1398**.
Controleer in App Store Connect welke van de twee als verplichte maat geldt; nog niet gemaakt.
