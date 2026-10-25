# Changelog · iPhone, iPad, Apple TV, Mac, website en server

Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website en de server. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/).

Per build, ingedeeld per apparaatsoort: **Nieuw**, **Verbeterd** en **Opgelost**.

## Versie 1.0.1 · Build 149
_25 oktober 2026_

### Alle apps en de website

**Nieuw**

- Op Home een rij Ontdek categorieën met posters, een gekleurde balk en het logo van de streamingdienst

**Verbeterd**

- Zoeken vindt meer: losse woorden in elke volgorde, zonder accenten en voorvoegsels en met een kleine typefout

**Opgelost**

- Geen haperingen meer bij sync toepassen en bewaren: datums worden niet meer per item opnieuw opgemaakt

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Bewaren van grote catalogi gebruikt veel minder geheugen

### iOS, iPadOS, tvOS, macOS, Windows en Website

**Verbeterd**

- Zoeken toont ook treffers uit verborgen categorieën, onderaan

### iOS, iPadOS, tvOS, Android, Android TV, Samsung TV (Tizen) en LG TV (webOS)

**Opgelost**

- Een heel grote server stopt netjes met een melding in plaats van de app te laten wegvallen

### iOS, iPadOS, tvOS, macOS, Android, Android TV, Windows en Website

**Verbeterd**

- Zoeken doorzoekt ook de catalogi van Stremio-add-ons

### iOS, iPadOS, tvOS, macOS, Android, Android TV, Samsung TV (Tizen) en LG TV (webOS)

**Opgelost**

- Diagnose: de bereikbaarheid van je eigen server en de fase toepassen worden goed gemeten

### Android, Android TV, Samsung TV (Tizen), Windows, LG TV (webOS) en Website

**Verbeterd**

- Grote servers laden sneller en met veel minder geheugen; verborgen categorieën worden niet meer ingelezen

## Versie 1.0.1 · Build 148
_25 oktober 2026_

### Alle apps en de website

**Verbeterd**

- Een heel grote catalogus wordt in kleine stukjes ingelezen en toegepast, zodat de app blijft reageren en minder geheugen gebruikt
- Diagnose in de taal van de app, met de langste hapering, het bijwerken per server, geleverd naast zichtbaar en haperingen tijdens het afspelen

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Live tv via VLC en HLS bouwt een grotere buffer op, zodat netwerkschommelingen niet meer tot een hapering leiden

### iOS, iPadOS, tvOS, macOS, Android, Android TV, Samsung TV (Tizen) en LG TV (webOS)

**Opgelost**

- Live tv hapert niet meer kort na een paar seconden afspelen: het audio- of ondertitelspoor wordt niet meer opnieuw gekozen als dat niet nodig is

### Server

**Verbeterd**

- Een diagnose bij een supportvraag laat nu zien waar de app bij het starten en bijwerken op wacht, hoeveel van je catalogus verborgen is en of het afspelen haperde
- Mails van Bingr: de afbeelding staat niet meer in een donker kader en een afbeelding die niet laadt geeft geen groot leeg vlak meer

## Versie 1.0.1 · Build 147
_24 oktober 2026_

### Alle apps en de website

**Verbeterd**

- De startdiagnose toont bovenaan of de start goed, traag of vastgelopen was, met app-tijd los van wachten op jou en de vorige start
- Een diagnose naar support bevat altijd de startdiagnose van deze en de vorige start

### iOS, iPadOS, tvOS, macOS, Windows en Website

**Opgelost**

- Series en films van grote of trage Xtream-servers worden los van elkaar opgehaald, met meer tijd en een nieuwe poging; een trage serieslijst houdt films en zenders niet meer op

### iOS, iPadOS, tvOS, macOS, Android, Android TV, Samsung TV (Tizen), Windows en Website

**Nieuw**

- Een LG-tv staat in je apparatenlijst en bij Wie kijkt er nu als LG TV

**Verbeterd**

- Bij vastlopen legt de diagnose vast welke taak het was en of de app op de voorgrond stond
- De diagnose toont per server of zenders, films en series geleverd zijn, leeg waren, mislukten of allemaal verborgen zijn, plus de soort verbinding en de opslag als één totaal

**Opgelost**

- Na het starten loopt Bingr niet meer vast bij een grote bibliotheek: zwaar werk zoals sorteren, filteren, Mijn lijst, de tv-gids, opslaan en pincodes gebeurt op de achtergrond of in kleine stukjes

### Website en Server

**Verbeterd**

- Statuspagina: een mislukte build geeft niet meer meteen een grote storing; alleen de echte build telt, en pas na twee mislukte builds op rij (of na 2 uur) is het een storing

### Server

**Nieuw**

- De server kent de LG TV-app (webOS)

**Verbeterd**

- Support: de diagnose uit de app is uitgebreider en adressen en servernamen worden er beter uit gehaald

## Versie 1.0.1 · Build 146
_24 oktober 2026_

### Alle apps en de website

**Nieuw**

- Support in de app (Instellingen → Support): je tickets in Open, In behandeling en Gesloten bekijken, reageren, sluiten en een nieuw ticket maken, met een badge bij een nieuw antwoord
- Diagnose in Instellingen: startdiagnose en app-diagnose met je apparaat, systeem, netwerk, opslag en geheugen, zonder persoonsgegevens met één knop naar support te sturen
- Servers vernieuwen in het profielmenu, boven Wissel profiel

**Verbeterd**

- Instellingen opnieuw ingedeeld in tabs: Algemeen, Afspelen, Taal en ondertitels, Servers, Profielen en kinderslot, Account, Koppelingen, Support, Diagnose en Over
- De tv-gids wordt samen met je servers bijgewerkt; is hij verlopen, dan zie je een melding met Bijwerken
- Windows-apparaten heten Windows, met een eigen icoon, in de apparatenlijst en bij Wie kijkt er nu

### Alle apps, de website en de server

**Verbeterd**

- Pincodes worden alleen nog als beveiligde hash bewaard en gesynchroniseerd en zijn niet meer terug te lezen
- Profielen synchroniseren versleuteld via de Bingr-server

### iOS, iPadOS, macOS, Android, Windows en Website

**Nieuw**

- Pushmelding bij een antwoord van support; tikken opent het ticket

### Windows en Website

**Verbeterd**

- Na 5 foute pincodes geldt ook in de webspeler een oplopende wachttijd

### Website

**Verbeterd**

- Privacyverklaring: we bewaren het land waaruit je de apps gebruikt (alleen de landcode, geen IP-adres)
- Statuspagina: Windows erbij (build en download)

### Server

**Verbeterd**

- Kijkgeschiedenis, statistieken en supportberichten staan versleuteld opgeslagen

**Opgelost**

- Profielfoto's zijn beter afgeschermd per account

## Versie 1.0.1 · Build 145
_24 oktober 2026_

### Alle apps en de website

**Nieuw**

- Na het kiezen van een profiel vraagt Bingr of je je servers nu wilt bijwerken (Nu bijwerken of Later); je bewaarde lijst staat meteen klaar
- Nieuwe instelling Servers laden bij openen: Vragen, Altijd of Nooit, alleen handmatig (per apparaat)

**Verbeterd**

- Geen automatisch verversen op tijd meer: de vernieuwtermijn (elke dag, week enz.) is vervallen; je kiest zelf wanneer, of vernieuwt handmatig
- Bijwerken gaat één server tegelijk op de achtergrond, de open server eerst, en nooit tijdens het afspelen

### tvOS, Android TV en Samsung TV (Tizen)

**Verbeterd**

- Op de tv staat de focus bij de vraag standaard op Later

## Versie 1.0.1 · Build 144
_23 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Je servers, pincodes en instellingen gaan alleen nog via je Bingr-account naar je andere apparaten, niet meer via de sleutelhanger of iCloud

### tvOS

**Opgelost**

- De Apple TV-app start weer: Bingr gebruikt de sleutelhanger niet meer

## Versie 1.0.1 · Build 143
_23 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Nieuw**

- Startdiagnose onder Instellingen → Over: liep de vorige start mis, dan zie je waar en stuur je het met één tik naar support

**Verbeterd**

- Servers worden pas ververst als de app al even open is, één voor één en nooit tijdens het kijken

**Opgelost**

- Het pincodescherm van een beveiligd profiel verschijnt meteen
- Verder kijken toont de poster van de film of serie, ook bij titels die je eerder al keek

### tvOS

**Opgelost**

- De Apple TV-app haalt bij het openen niets meer op als er al een lijst bewaard is, gebruikt minder geheugen en loopt niet meer vast bij het starten

## Versie 1.0.1 · Build 142
_23 oktober 2026_

### Alle apps en de website

**Verbeterd**

- Nieuw op Bingr staat op de plek van Nieuw toegevoegd, met Film of Serie op elke tegel
- Verder kijken toont de cover van de film of serie

**Opgelost**

- Titels die je na zoeken aan Mijn lijst toevoegt (ook van een andere server of een aanbeveling) staan er meteen in, ook op je andere apparaten

### Alle apps, de website en de server

**Verbeterd**

- Inloggen is beter beschermd tegen raden, met een duidelijke melding bij te veel pogingen
- Een nieuw wachtwoord moet minstens 8 tekens hebben

### iOS, iPadOS, macOS en Android

**Verbeterd**

- Tv koppelen toont eerst welk apparaat het is en vraagt om bevestiging

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Trailers zijn veiliger: alleen geldige YouTube-trailers worden geladen

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Bij het openen ververst eerst alleen de open server; je andere servers volgen later op de achtergrond
- Casten naar een Chromecast is beter afgeschermd: alleen wat je cast is bereikbaar, met een nieuwe sleutel per sessie

### iOS, iPadOS, tvOS, macOS, Android, Android TV en Samsung TV (Tizen)

**Verbeterd**

- Kinderslot uitzetten, de pincode wijzigen en een vergrendelde groep ontgrendelen vragen nu de huidige pincode
- Na 5 foute pincodes geldt een oplopende wachttijd
- Inloggegevens van je servers en je accountsessie worden versleuteld bewaard (sleutelhanger op Apple)
- Verbindingen met Bingr en de eigen diensten gaan altijd via HTTPS

### tvOS

**Opgelost**

- De Apple TV-app stopt niet meer direct na het openen

### macOS

**Verbeterd**

- De Mac-app gebruikt alleen uitgaande verbindingen; eigen ondertitels gaan niet naar de Chromecast, ondertitels uit de stream wel

### Windows en Website

**Verbeterd**

- De webspeler is strenger beveiligd: alle scripts komen van Bingr zelf

### Website en Server

**Verbeterd**

- Een supportticket koppel je aan je account en is alleen voor jou zichtbaar

### Server

**Verbeterd**

- De webproxy werkt alleen nog voor je eigen servers, met limieten per account

## Versie 1.0.1 · Build 140
_23 oktober 2026_

### iOS, iPadOS, tvOS, macOS, Android, Android TV, Samsung TV (Tizen) en Website

**Nieuw**

- Kinderprofielen tonen alleen kinderinhoud, afgestemd op de leeftijdsgrens; een kinderprofiel verlaten kan pas na een rekensom (Vraag een volwassene)
- Categorieën staat in het menu naast Series; Mijn Bingr open je via je profiel

**Verbeterd**

- Verborgen categorieën gelden nu voor je hele account (alle profielen behalve kinderprofielen)
- Categorieën aan- en uitzetten in Instellingen gaat veel sneller
- Voor jou is gebaseerd op wat dit profiel kijkt; zonder kijkgeschiedenis heet de rij Populair
- Nieuw op Bingr toont wat het laatst aan je bibliotheek is toegevoegd, over al je servers
- Uitgelicht op Home toont een vaste selectie die vanzelf om de 8 seconden wisselt

**Opgelost**

- Servers automatisch vernieuwen volgt weer je instelling en werkt al je servers bij, ook als de app lang openstaat
- Wat je aan Mijn lijst toevoegt, blijft er nu altijd in staan, ook op je andere apparaten

### Website

**Verbeterd**

- Bingr staat in de App Store voor iPhone en iPad: op bingr.online en support.bingr.online staat nu een App Store-knop naast TestFlight
- Windows staat op bingr.online, met een downloadknop voor de testversie (bingr.online/windows) en uitleg over Windows SmartScreen; de changelog toont het Windows-logo

**Opgelost**

- Na het wisselen van profiel via het profielmenu openden pagina's in de webspeler niet meer

### Server

**Opgelost**

- Mails aan support@bingr.online worden weer altijd een ticket, ook als ze al gelezen waren; reacties komen in het bestaande ticket en niets wordt dubbel geïmporteerd

## Versie 1.0.0 · Build 139
_22 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Nieuw**

- Bingr staat officieel in de App Store

## Versie 1.0.0 · Build 138
_19 oktober 2026_

### Alle apps en de website

**Verbeterd**

- Voorbereiding op de eerste release (versie 1.0.0)

### Website

**Verbeterd**

- Account maken op bingr.online en in de webspeler is beter beschermd tegen bots, zonder captcha

### Server

**Opgelost**

- Betere bescherming tegen nepaccounts: aanmeldingen van bots via de website worden herkend en geweigerd
- E-mails van Bingr tonen weer een afzendernaam (Bingr of Bingr Support) in plaats van alleen het adres
