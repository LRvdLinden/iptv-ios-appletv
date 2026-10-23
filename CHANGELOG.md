# Changelog · iPhone, iPad, Apple TV, Mac, website en server

Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website en de server. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/).

Per build, ingedeeld per apparaatsoort: **Nieuw**, **Verbeterd** en **Opgelost**.

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
