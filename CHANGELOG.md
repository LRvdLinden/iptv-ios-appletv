# Changelog · iPhone, iPad, Apple TV, Mac, website en server

Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website en de server. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/).

Per build, ingedeeld per apparaatsoort: **Nieuw**, **Verbeterd** en **Opgelost**.

## Versie 1.0.3 · Build 157
_30 oktober 2026_

### Alle apps, de website en de server

**Verbeterd**

- Met Gratis kun je op 2 apparaten ingelogd zijn; zijn het er meer, dan blijven de 2 apparaten ingelogd die je het laatst gebruikte
- Verder kijken, kinderprofielen en ondertitels via OpenSubtitles horen nu bij Lifetime; Mijn lijst en profielen blijven gratis

### Alle apps en de website

**Verbeterd**

- Met Gratis wordt je voortgang wel bewaard en blijft hervatten werken, zodat Verder kijken er na het upgraden meteen is; bestaande kinderprofielen blijven beschermd en ondertitels uit de stream blijven gratis

### Website

**Verbeterd**

- De vergelijking van Gratis en Lifetime op bingr.online en de hulp op support.bingr.online zijn bijgewerkt

## Versie 1.0.3 · Build 156
_30 oktober 2026_

### Server

**Nieuw**

- Maandoverzicht per e-mail: op de laatste dag van de maand om 18:00 wat er de volgende maand nieuw komt in de bioscoop, op streaming en digitaal en aan nieuwe series en seizoenen

## Versie 1.0.3 · Build 155
_30 oktober 2026_

### Website en Server

**Nieuw**

- Bij de downloadknoppen zie je nu in een rode badge welke versie live staat en welke bèta het nieuwst is

### Server

**Verbeterd**

- Een pushmelding die even niet lukt, wordt later automatisch opnieuw verstuurd
- E-mails worden betrouwbaarder verstuurd; een tijdelijke storing bij de mailserver laat geen mails meer wegvallen

**Opgelost**

- Pushmeldingen naar iPhone, iPad en Mac komen weer allemaal aan; Apple weigerde er veel omdat de server te vaak opnieuw inlogde

## Versie 1.0.3 · Build 154
_30 oktober 2026_

### Alle apps en de website

**Nieuw**

- Gezien geldt nu op al je servers: dezelfde film of aflevering staat overal als gezien, en wat je al gezien had gaat mee
- Een serie waarvan je alle uitgezonden afleveringen hebt gezien, staat als gezien

**Verbeterd**

- Gezien en niet-gezien gaan via een wachtrij naar Trakt en komen er ook aan na een netwerkstoring of herstart, met dezelfde grens voor gezien als in Bingr
- Trakt-vinkjes kloppen beter: koppelen via het TMDB-nummer van je server en IMDb, ook titels zonder IMDb-nummer, en zoeken gebruikt alleen een treffer met de juiste titel en het juiste jaar
- Wijzigingen in Trakt komen sneller binnen: elke 15 minuten en bij terugkeer naar de app

**Opgelost**

- Trakt blijft gekoppeld: de koppeling wordt alleen vernieuwd als het nodig is en een mislukte vernieuwing logt je niet meer op al je apparaten uit
- Titels als NCIS: Hawaii, Blade Runner 2049 en Sub Zero worden niet meer ingekort

## Versie 1.0.2 · Build 153
_30 oktober 2026_

### Alle apps en de website

**Opgelost**

- Landaanduidingen tussen streepjes zoals ┃NL┃, ｜DE｜, |4K| en | MULTI / LINGO | staan nergens meer: niet in zendernamen, categorieën, titels, afleveringen, de tv-gids, de speler, zoeken of meldingen

## Versie 1.0.2 · Build 152
_30 oktober 2026_

### Alle apps en de website

**Nieuw**

- Nieuwe rij Nu in de bioscoop op Home: de populairste films die nu in de bioscoop draaien, meteen af te spelen als ze op je server staan

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Verbergen en weer tonen van samengevoegde categorieën geldt nu altijd voor alle bronnen en synct goed naar je andere apparaten

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Opgelost**

- Een verborgen categorie die je weer aanzet, komt nu altijd terug: ook op je andere servers, na een herstart van de app en als er op dat moment servers werden bijgewerkt

### Windows, Website en Server

**Opgelost**

- Servers laden weer in de webspeler, en lukt het niet, dan zie je een duidelijke melding in plaats van http_502

### Website en Server

**Verbeterd**

- Samsung TV en LG-tv worden niet meer ondersteund en staan niet meer op de website, de supportsite en de statuspagina

### Server

**Nieuw**

- De nieuwsbrief heeft de secties Top 10 deze week en Populair, met IMDb-score; een klik opent de titel in Bingr

**Verbeterd**

- Nieuwsbrief overzichtelijker: per onderwerp maximaal 6 titels in rijen van 3, alle covers even groot met titel, jaar, genre en score eronder, de Top 10 doorlopend genummerd en geen titel meer twee keer in dezelfde mail

**Opgelost**

- De statuspagina meldt geen onterechte storing meer bij Apple

## Versie 1.0.1 · Build 151
_25 oktober 2026_

### Alle apps en de website

**Nieuw**

- Nieuwe rij Zenders op Home met de logo's van je eigen zenders: je recente zenders en favorieten eerst, met het programma van nu eronder; klikken start de zender meteen

**Verbeterd**

- Een titel of zender die op meerdere servers staat, staat maar één keer in de rijen op Home, uit de bron in je taal; de andere servers kies je op de detailpagina

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Grote servers met veel verborgen categorieën laden veel zuiniger: wat verborgen is wordt alleen geteld, niet ingelezen (vooral op Apple TV)
- Categorieën en Beheren tonen het aantal titels of zenders per categorie, ook van verborgen categorieën, met nette namen
- Bij dezelfde titel in samengevoegde categorieën gaat de bron in je audio- of app-taal voor

### Windows en Website

**Verbeterd**

- Synchroniseren van Mijn lijst, voortgang en geschiedenis gebeurt op de achtergrond, zonder haperingen, ook bij een groot profiel

## Versie 1.0.1 · Build 150
_25 oktober 2026_

### Alle apps en de website

**Verbeterd**

- Categorieën met dezelfde naam worden één categorie, zonder dubbele titels en met de talen als label; aan- en uitzetten geldt voor alle bronnen tegelijk

**Opgelost**

- Taal-, land- en kwaliteitsaanduidingen zoals "| NL |", "MULTI / LINGO", "[EN]" of "4K" verdwijnen overal uit de namen van categorieën, en namen in hoofdletters krijgen nette hoofdletters
- Ontdek categorieën toont Netflix niet meer twee keer en toont de logo's van streamingdiensten weer

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Bij Over staat nu ook de bronvermelding Streamingdata: JustWatch

## Versie 1.0.1 · Build 149
_25 oktober 2026_

### Alle apps en de website

**Nieuw**

- Op Home een rij Ontdek categorieën met posters, een gekleurde balk en het logo van de streamingdienst

**Verbeterd**

- Zoeken vindt meer: losse woorden in elke volgorde, zonder accenten en voorvoegsels en met een kleine typefout
- Zoeken doorzoekt ook de catalogi van Stremio-add-ons

**Opgelost**

- Geen haperingen meer bij sync toepassen en bewaren: datums worden niet meer per item opnieuw opgemaakt

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Bewaren van grote catalogi gebruikt veel minder geheugen

### iOS, iPadOS, tvOS, Android en Android TV

**Opgelost**

- Een heel grote server stopt netjes met een melding in plaats van de app te laten wegvallen

### iOS, iPadOS, tvOS, macOS, Windows en Website

**Verbeterd**

- Zoeken toont ook treffers uit verborgen categorieën, onderaan

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Opgelost**

- Diagnose: de bereikbaarheid van je eigen server en de fase toepassen worden goed gemeten

### Android, Android TV, Windows en Website

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

### iOS, iPadOS, tvOS, macOS, Android en Android TV

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
- Bij vastlopen legt de diagnose vast welke taak het was en of de app op de voorgrond stond
- De diagnose toont per server of zenders, films en series geleverd zijn, leeg waren, mislukten of allemaal verborgen zijn, plus de soort verbinding en de opslag als één totaal
- Een diagnose naar support bevat altijd de startdiagnose van deze en de vorige start

**Opgelost**

- Na het starten loopt Bingr niet meer vast bij een grote bibliotheek: zwaar werk zoals sorteren, filteren, Mijn lijst, de tv-gids, opslaan en pincodes gebeurt op de achtergrond of in kleine stukjes

### iOS, iPadOS, tvOS, macOS, Windows en Website

**Opgelost**

- Series en films van grote of trage Xtream-servers worden los van elkaar opgehaald, met meer tijd en een nieuwe poging; een trage serieslijst houdt films en zenders niet meer op

### Website en Server

**Verbeterd**

- Statuspagina: een mislukte build geeft niet meer meteen een grote storing; alleen de echte build telt, en pas na twee mislukte builds op rij (of na 2 uur) is het een storing

### Server

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

### tvOS en Android TV

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
- Kinderslot uitzetten, de pincode wijzigen en een vergrendelde groep ontgrendelen vragen nu de huidige pincode
- Na 5 foute pincodes geldt een oplopende wachttijd
- Casten naar een Chromecast is beter afgeschermd: alleen wat je cast is bereikbaar, met een nieuwe sleutel per sessie
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

### iOS, iPadOS, tvOS, macOS, Android, Android TV en Website

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
