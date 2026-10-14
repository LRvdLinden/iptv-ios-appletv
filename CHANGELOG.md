# Changelog · iPhone, iPad, Apple TV, Mac, website en server

Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website en de server. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/).

Per build, ingedeeld per apparaatsoort: **Nieuw**, **Verbeterd** en **Opgelost**.

## Versie 1.0.0 · Build 93
_15 oktober 2026_

### Website en Server

**Verbeterd**

- Betere spambescherming op het supportformulier: het verborgen lokveld wordt niet meer door de browser automatisch ingevuld en spam wordt stil tegengehouden

## Versie 1.0.0 · Build 91
_14 oktober 2026_

### iOS, iPadOS, tvOS, macOS en Website

**Opgelost**

- Ondertitels die je zelf kiest of uitzet, worden niet meer overschreven door de automatische ondertitels
- Ondertitelinstellingen per profiel: een ander profiel verandert niet meer de instellingen van het hoofdprofiel, en na een profielwissel gelden de juiste talen
- OpenSubtitles logt je niet meer onterecht uit op al je apparaten, en je ziet een melding als je niet bent ingelogd of je downloads voor vandaag op zijn

### Website

**Opgelost**

- Webspeler: de gekozen ondertiteltaal wordt meteen gebruikt als de stream die heeft, ondertitels die later binnenkomen worden nog gevonden, OpenSubtitles zoekt ook op TMDB, gedownloade ondertitels worden bewaard (spaart je dagquotum) en ze staan ook in beeld bij volledig scherm op de iPhone

### Website en Server

**Opgelost**

- OpenSubtitles werkt nu in de webspeler: inloggen, zoeken en downloaden lopen via de Bingr-server, zodat de browser ze niet meer blokkeert

## Versie 1.0.0 · Build 90
_14 oktober 2026_

### Website

**Nieuw**

- De webspeler toont bij films en series dezelfde info als de apps: beschrijving in je eigen taal, genres, regisseur, speelduur, cast met foto's en aanbevelingen (wat in je bibliotheek staat, speel je meteen af)
- Eigen pagina per acteur of actrice in de webspeler: foto, biografie, wat er in Bingr te kijken is en de rest van het werk

## Versie 1.0.0 · Build 89
_14 oktober 2026_

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Een nieuw hoofdprofiel dat op een ander apparaat of op bingr.online gekozen is, wordt meteen overgenomen, met de rechten die erbij horen

### Website

**Nieuw**

- Op Mijn Bingr (bingr.online en de webspeler) maak je een ander profiel het hoofdprofiel; het huidige hoofdprofiel wordt dan een gewoon profiel

## Versie 1.0.0 · Build 88
_14 oktober 2026_

### Alle apps, de website en de server

**Nieuw**

- Twee abonnementen: Gratis (2 schermen tegelijk, 8 apparaten, 1 server) en Lifetime (€ 4,99 eenmalig: 6 schermen, 15 apparaten, onbeperkt servers, statistieken, Nu aan het kijken, Trakt en accentkleuren); bestaande accounts krijgen Lifetime cadeau

### Alle apps en de website

**Nieuw**

- Lifetime-functies hebben op Gratis een slotje met een vergelijking van beide abonnementen, en Mijn Bingr toont je abonnement met het aantal schermen, apparaten en servers

**Verbeterd**

- Bij te veel schermen of apparaten zie je de limiet van je abonnement en wat Lifetime toestaat

### Android en Website

**Nieuw**

- Upgraden naar Lifetime opent bingr.online/upgrade in je browser

### Website

**Nieuw**

- Op bingr.online een vergelijkingstabel Gratis en Lifetime, de pagina /upgrade/ (betalen volgt binnenkort) en een veelgestelde vraag over Lifetime

### Server

**Verbeterd**

- Je kijktijd wordt ook bij Gratis bijgehouden, dus na het upgraden staan je statistieken er meteen

## Versie 1.0.0 · Build 87
_14 oktober 2026_

### iOS en iPadOS

**Verbeterd**

- Home is rustiger: de knoppen Series en Films onder het logo zijn weg (Films en Series staan in de tabbalk, Categorieën in Mijn Bingr en als rij op Home)

## Versie 1.0.0 · Build 86
_14 oktober 2026_

### Alle apps en de website

**Nieuw**

- Home: nieuwe rij Categorieën met de best gevulde genres als tegels en een tegel Alle categorieën, vijf rijen onder Nu live; aan, uit en te verplaatsen bij Startscherm

**Verbeterd**

- Categorieën staan nu in Mijn Bingr (Bibliotheek; op Samsung TV in het profielmenu) in plaats van als eigen tabblad, knop of menu-item

## Versie 1.0.0 · Build 85
_14 oktober 2026_

### Alle apps en de website

**Nieuw**

- Categorieën in Netflix-stijl: blader per genre (Actie, Komedie, Drama, Horror, Sci-Fi, Animatie, …) of door de categorieën van je server, met tegels vol covers; per categorie kies je Alles, Films of Series en sorteer je op Populair, Nieuwste, A–Z of Beoordeling

### iOS, iPadOS en macOS

**Verbeterd**

- Chips Series, Films en Categorieën bovenaan Home; Categorieën ook bovenaan Films en Series

### tvOS

**Verbeterd**

- De kop van de detailpagina beweegt: langzaam inzoomen en overvloeien tussen achtergronden (stil bij Bewegingen beperken); de trailerknop opent de YouTube-app

### Samsung TV (Tizen) en Website

**Opgelost**

- Trailer in de kop van de detailpagina op Samsung TV: nieuwe manier van afspelen via bingr.online, en anders een rustig bewegende achtergrond

## Versie 1.0.0 · Build 84
_14 oktober 2026_

### Website

**Verbeterd**

- Homepage: de tekst bij Kijk op elk scherm is korter

## Versie 1.0.0 · Build 83
_14 oktober 2026_

### Website

**Nieuw**

- Webspeler: film- en seriepagina's spelen na 1,5 seconde de trailer zonder geluid in de kop, met geluid aan/uit; instelling Trailers automatisch afspelen

### Website en Server

**Nieuw**

- Tv koppelen op bingr.online/koppelen: geef het apparaat meteen een eigen naam, bijvoorbeeld "Apple TV - Woonkamer"

**Verbeterd**

- Films en series spelen in de browser vaker af: levert je server ze ook als HLS, dan gebruikt Bingr die, ook in Safari (MKV kan Safari zelf niet openen)
- Speelt iets niet in de browser, dan zegt de melding precies waarom (bijv. MKV in Safari, HEVC-beeld of AC3-geluid, te veel verbindingen), met een knop Details
- Supportformulier: kies je apparaat en app-versie uit je account (ook als je al was ingelogd, en je kunt op het formulier zelf inloggen); zonder versies staan de nieuwste builds per platform klaar
- Is je account geblokkeerd, dan zeggen de website, de webspeler en support.bingr.online dat duidelijk, ook als je al was ingelogd; je kunt dan nog wel een supportticket sturen
- Statuspagina: kortere namen (Android, Samsung TV, Apple (iOS, iPadOS, tvOS, macOS)) en geen aparte regel meer voor opslag

## Versie 1.0.0 · Build 82
_14 oktober 2026_

### Alle apps

**Nieuw**

- Is je account geblokkeerd, dan zegt de app dat duidelijk bij het inloggen, bij het koppelen met een code en als je al was ingelogd, met de melding dat je een e-mail hebt gekregen met de reden en tot wanneer

### iOS, iPadOS, macOS, Android, Android TV en Samsung TV (Tizen)

**Nieuw**

- Trailer automatisch: op de pagina van een film of serie speelt na 1,5 seconde de trailer zonder geluid in de kop, met geluid aan/uit; bij series de trailer van het nieuwste seizoen. Uit te zetten met Trailers automatisch afspelen; niet bij weinig data of minder beweging

## Versie 1.0.0 · Build 81
_14 oktober 2026_

### Website

**Verbeterd**

- Account maken op bingr.online: na het aanmaken en bevestigen ga je meteen naar Mijn Bingr in plaats van naar tv koppelen (behalve als je een koppelcode hebt ingevoerd)

## Versie 1.0.0 · Build 80
_14 oktober 2026_

### Website

**Opgelost**

- Uitloggen op bingr.online, in de webspeler en op support.bingr.online werkt weer altijd: je bent daarna ook echt uitgelogd in deze browser (je andere apparaten blijven ingelogd)

## Versie 1.0.0 · Build 79
_14 oktober 2026_

### Website

**Nieuw**

- Verlopen bevestigings- of wachtwoordlink? Vraag op dezelfde pagina meteen een nieuwe aan

### Website en Server

**Verbeterd**

- Links in account-e-mails (e-mailadres bevestigen, wachtwoord vergeten, inloggen met link, uitnodiging, e-mailadres wijzigen) gaan nu via bingr.online/bevestigen: je bevestigt met één klik op een Bingr-pagina, en virusscanners in je mailbox maken de link niet meer ongemerkt ongeldig

## Versie 1.0.0 · Build 78
_14 oktober 2026_

### Website

**Nieuw**

- Nieuwe statuspagina: lopende storingen en gepland onderhoud met tijdlijn, onderdelen per groep met 90-dagenbalken, afgelopen incidenten en een incidentgeschiedenis

### Website en Server

**Nieuw**

- Abonneren op statusupdates per e-mail (met bevestiging) of via een Atom/RSS-feed

### Server

**Verbeterd**

- Storingen die de monitoring vindt, verschijnen automatisch op de statuspagina en worden vanzelf afgesloten als alles weer werkt; gepland onderhoud telt niet meer als storing
- Alle e-mails van Bingr (account bevestigen, nieuw wachtwoord, inloggen, uitnodiging, e-mailadres wijzigen, verificatiecode, berichten en status) hebben dezelfde vormgeving als de supportmails, met onderaan een duidelijke uitleg waarom je de mail krijgt
- Afmelden voor berichten per e-mail kan nu met één klik vanuit je mailapp

## Versie 1.0.0 · Build 77
_14 oktober 2026_

### Website

**Nieuw**

- Supportticket aanmaken: ben je ingelogd, dan kies je bij Apparaat een van je eigen apparaten en bij App-versie een versie uit je account (vooraf ingevuld bij het gekozen apparaat); niet ingelogd kies je zoals altijd een soort apparaat, met een link om in te loggen

### Server

**Verbeterd**

- Supporttickets bewaren het gekozen apparaat (naam, platform en systeemversie); alleen apparaten van je eigen account worden geaccepteerd

## Versie 1.0.0 · Build 76
_14 oktober 2026_

### Website

**Verbeterd**

- De hulp staat nu op support.bingr.online: artikelen per onderwerp (inloggen en koppelen, je afspeellijst, profielen, installeren op Android, Android TV, Fire TV en Samsung TV, en de webspeler) met direct een knop voor een nieuw ticket; bingr.online/support.html stuurt automatisch door en de footer linkt naar Support

### Server

**Nieuw**

- Support per e-mail: antwoord je op een mail van Bingr Support, dan komt je reactie direct bij je ticket; een mail aan support@bingr.online wordt automatisch een nieuw ticket met bevestiging

**Verbeterd**

- Supportmails hebben een duidelijke regel om boven te antwoorden; geciteerde tekst, handtekeningen en automatische antwoorden worden genegeerd, en de account-mails linken in de footer naar support.bingr.online

## Versie 1.0.0 · Build 75
_14 oktober 2026_

### Alle apps en de website

**Nieuw**

- Support onder Account en apparaten en in het profielmenu: opent support.bingr.online (op Apple TV, Android TV en Samsung TV met een QR-code); op bingr.online staat Support in het menu

**Opgelost**

- Bekeken-vinkjes kloppen beter: Trakt en Bingr tellen samen, Trakt wordt eerst op TMDB-id gekoppeld en niet meer aan een remake of serie met dezelfde naam uit een ander jaar, en covers werken meteen bij na een Trakt-sync of afvinken

### Alle apps

**Nieuw**

- Seriecovers tonen linksboven in een rood label hoeveel afleveringen je hebt bekeken ("21 BEKEKEN"), op Home, Series, zoeken, collecties, Mijn lijst en Voor jou; films in Voor jou krijgen ook een bekeken-vinkje

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Andere profielen zien nooit meer de Trakt-vinkjes van het hoofdprofiel, ook niet direct na het wisselen van profiel

### Website

**Nieuw**

- Nieuwe supportsite support.bingr.online: maak een supportticket aan, volg je ticket en reageer via de link in je e-mail, of bekijk al je tickets met je Bingr-account

**Verbeterd**

- Webspeler: de labels Serie, Film en "x bekeken" zijn weer rood (of de accentkleur van je profiel) en "Bekijk allemaal" is wit, net als in de app; vinkjes ook bij titels als Spider-Man

### Server

**Nieuw**

- Supporttickets met een eigen nummer (#1001) en gebrande e-mails bij ontvangst, antwoord en oplossing, in het Nederlands of Engels

## Versie 1.0.0 · Build 74
_14 oktober 2026_

### Alle apps en de website

**Verbeterd**

- Apple TV heeft overal hetzelfde Apple TV-icoon, in de apparatenlijst, bij Nu aan het kijken en op bingr.online

**Opgelost**

- Profielen zien alleen nog hun eigen collecties, niet meer die van het hoofdprofiel of van andere profielen; kopieën die eerder bij andere profielen terechtkwamen, worden opgeruimd
- Uitloggen logt alleen dit apparaat of deze browser uit; je andere apparaten blijven ingelogd

### iOS, iPadOS, tvOS, macOS, Android, Android TV en Website

**Verbeterd**

- Voor jou: het label Serie/Film staat linksboven op de cover en de rij staat altijd op alfabet, series en films door elkaar

### Website

**Opgelost**

- Webspeler: films en series spelen weer af, ook MKV in Chrome, Edge en Firefox; lukt het niet, dan zegt de speler waarom

### Server

**Opgelost**

- Films via de doorgifte van Bingr spelen ook in Safari en bij servers die geen deelverzoeken ondersteunen

## Versie 1.0.0 · Build 73
_14 oktober 2026_

### Website

**Verbeterd**

- Alle pagina's van bingr.online (changelog, status, tv koppelen, Mijn Bingr, support, privacy, wachtwoord herstellen en afmelden) hebben nu dezelfde stijl, menubalk en footer als de homepage

## Versie 1.0.0 · Build 72
_13 oktober 2026_

### iOS, iPadOS, macOS en Android

**Nieuw**

- Profielmenu achter je profielfoto in de bovenbalk: wissel direct naar een ander profiel (met pincode als die is ingesteld), of ga naar Wissel van profiel, Profielen beheren, Mijn Bingr, Instellingen, Account en apparaten of Uitloggen, net als op bingr.online

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Mijn Bingr is overzichtelijker, zoals op bingr.online: Bibliotheek (kijkgeschiedenis, collecties, statistieken, Trakt) en Profiel (profielen beheren, startscherm, instellingen, account en apparaten); alle andere instellingen staan onder Instellingen

### tvOS, Android TV en Samsung TV (Tizen)

**Nieuw**

- Profielmenu op de tv: kies je profielfoto om meteen van profiel te wisselen of naar Instellingen, Account en apparaten of Uitloggen te gaan (Apple TV: bovenaan Mijn Bingr, Android TV: rechts in de bovenbalk, Samsung TV: bovenaan het zijmenu)

### Website

**Opgelost**

- Webspeler: de Trakt-status in Mijn Bingr toont weer de juiste tijd in plaats van "bijgewerkt om Bijgewerkt"

## Versie 1.0.0 · Build 71
_13 oktober 2026_

### Website

**Verbeterd**

- Apple TV-apparaten hebben op bingr.online en in de webspeler hetzelfde icoon als in de iOS-app

## Versie 1.0.0 · Build 70
_13 oktober 2026_

### Website

**Verbeterd**

- Nieuwe homepage op bingr.online: in één oogopslag op welke apparaten Bingr werkt en dat je je eigen IPTV-server of -abonnement nodig hebt, met screenshots, uitleg hoe je begint, alle downloads op één plek en meer veelgestelde vragen

## Versie 1.0.0 · Build 69
_13 oktober 2026_

### Website

**Nieuw**

- Webspeler: Trakt koppelen, synchroniseren en scrobbelen vanuit het hoofdprofiel
- Webspeler: zien wat je al hebt gekeken, met vinkjes op posters en afleveringen en een kijkgeschiedenis per dag
- Webspeler: films, afleveringen en hele seizoenen als bekeken of onbekeken markeren
- Webspeler: collecties maken, wijzigen en verwijderen, handmatig of slim, en titels en zenders aan een collectie toevoegen
- Webspeler: profielen toevoegen, wijzigen en verwijderen, met foto, leeftijdsgrens en pincode, alleen vanuit het hoofdprofiel
- Webspeler: Mijn Bingr, indeling van het startscherm en de rij Voor jou

**Verbeterd**

- Webspeler: menu met acties op kaarten via rechtsklik of lang indrukken
- Webspeler: inloggen bij OpenSubtitles, startscherm en tabbladen kiezen en kinderslot instellen vanuit het hoofdprofiel

## Versie 1.0.0 · Build 68
_13 oktober 2026_

### Alle apps en de website

**Nieuw**

- Statistieken in Mijn Bingr: zie per week, maand of jaar hoeveel je hebt gekeken, met uren, films, series en live tv, een grafiek per dag of maand en je meest gekeken series, films en zenders
- Het hoofdprofiel ziet de statistieken van alle profielen samen of per profiel; andere profielen zien alleen hun eigen cijfers
- Statistieken wissen: het hoofdprofiel voor alle profielen of één profiel, andere profielen voor zichzelf

### Alle apps

**Verbeterd**

- Afleveringen tellen per serie mee en terugkijken telt bij de zender

### Server

**Nieuw**

- Kijkstatistieken: de server houdt per profiel bij hoeveel er gekeken wordt (films, series en live tv), per dag, met de meest gekeken titels; 400 dagen bewaard en zelf te wissen

## Versie 1.0.0 · Build 67
_13 oktober 2026_

### Website

**Verbeterd**

- Webspeler op de telefoon: bovenaan Home staat nu een grote cover met titel, Afspelen en Info, net als in de iPhone-app
- Webspeler: de knop Afspelen is gevuld in je accentkleur, net als in de apps

## Versie 1.0.0 · Build 66
_13 oktober 2026_

### Website

**Verbeterd**

- Webspeler: het Bingr-logo is nu hetzelfde als in de apps: witte letters met een streep in je accentkleur eronder

## Versie 1.0.0 · Build 65
_13 oktober 2026_

### Website

**Nieuw**

- Nieuwe statuspagina op bingr.online/status: per onderdeel zie je of het werkt, de uptime van de afgelopen 90 dagen en eerdere storingen. De pagina werkt zichzelf elke minuut bij

**Verbeterd**

- In de footer van de website staat nu een link naar de statuspagina

### Server

**Nieuw**

- Bingr controleert elke 5 minuten zelf de accounts, de webspeler-doorgifte, de website en de downloads, en houdt storingen automatisch bij

## Versie 1.0.0 · Build 64
_13 oktober 2026_

### Website

**Verbeterd**

- Webspeler: inloggen met de QR-code ziet er nu hetzelfde uit als op Apple TV, met je covers vervaagd op de achtergrond

## Versie 1.0.0 · Build 63
_13 oktober 2026_

### Website

**Nieuw**

- Webspeler: dezelfde intro als in de apps (vallende covers en de letters van BINGR) in plaats van een logo met laadrondje
- Webspeler: servers op http werken nu ook. Alles loopt dan via de server van Bingr, ook video in Safari op iPhone en iPad

**Verbeterd**

- Webspeler: profielfoto's zijn overal rond, net als in de apps; het pincodescherm toont het profiel
- Privacy: uitgelegd dat bij een http-server ook de video via de doorgifte loopt, zonder dat Bingr er iets van bewaart

### Server

**Nieuw**

- De doorgifte voor de webspeler ondersteunt ook http-servers en haalt live-tv, films en afbeeldingen veilig op, alleen voor de servers in je eigen account

## Versie 1.0.0 · Build 62
_13 oktober 2026_

### Alle apps, de website en de server

**Nieuw**

- Apparaten: de browser verschijnt als eigen apparaattype (bijv. "Chrome op Mac") met een browser-icoon

**Verbeterd**

- Apparaat koppelen gaat nu via bingr.online/koppelen (de QR-code en de code op je tv of computer wijzen daarheen); de oude link bingr.online/tv blijft werken

### Website

**Nieuw**

- Kijk Bingr in je browser op bingr.online/web: inloggen met e-mail op je telefoon of met een QR-code op iPad en computer, met je profielen, Live TV met tv-gids, films, series, Mijn lijst en voortgang, sneltoetsen, beeld-in-beeld en volledig scherm
- Changelog: per apparaat zie je de nieuwste versie en build, bovenaan op je telefoon en rechts op je computer; tik erop om alleen dat apparaat te zien
- Changelog: elke build heeft een eigen link met een knop Link kopiëren; wie de link opent, komt direct bij die build en ziet hem opengeklapt

**Verbeterd**

- Changelog: de nieuwste build staat open en oudere builds zijn ingeklapt; dicht zie je versie, build, datum, hoeveel er nieuw, verbeterd en opgelost is en voor welke apparaten

### Server

**Nieuw**

- Servers zonder CORS werken ook in de browser via een beveiligde doorgifte, alleen voor je eigen servers

## Versie 1.0.0 · Build 61
_13 oktober 2026_

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Apparaten: Naam wijzigen en Verwijderen staan nu naast elkaar onder de tekst, zodat naam en gegevens goed leesbaar zijn

## Versie 1.0.0 · Build 60
_13 oktober 2026_

### Alle apps en de server

**Verbeterd**

- Het maximum van 6 schermen en 15 apparaten klopt nu ook als apparaten precies tegelijk starten of inloggen; kijkgeschiedenis ouder dan 8 dagen wordt altijd gewist

**Opgelost**

- Je wordt niet meer onterecht uitgelogd als je sessie net verlopen is of de server even niet bereikbaar is

### Alle apps, de website en de server

**Opgelost**

- Servers die je op een ander apparaat of op de website toevoegt, verdwijnen niet meer als een ander apparaat tegelijk een oudere lijst opslaat

### Alle apps

**Verbeterd**

- Audiotaal 'Zoals in de stream' en de ondertitelinstellingen werken op alle apps hetzelfde

**Opgelost**

- Wat je uit Verder kijken of je geschiedenis haalt, komt niet meer terug op je andere apparaten

### iOS en iPadOS

**Opgelost**

- Downloads: geen dubbele Live Activity meer, half gedownloade bestanden worden opgeruimd en offline weet de speler taal en hervatplek

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Multiview stopt echt als het scherm sluit; Opnieuw na een afspeelfout gaat verder waar het misging, met automatische ondertitels; audio- en ondertitelsporen laden op de achtergrond

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Opgelost**

- Plex crasht niet meer bij een onbruikbaar serveradres; Chromecast-sessies sluiten netjes af; OpenSubtitles vindt betere treffers

### tvOS

**Opgelost**

- Volgende aflevering en Intro overslaan zijn bereikbaar met de afstandsbediening, ook als de bediening verborgen is

### macOS

**Opgelost**

- Sneltoetsen in de speler (spatie, pijltjes, Esc) werken meteen

### Website

**Verbeterd**

- Mijn Bingr: een server wijzigen overschrijft geen wijzigingen van je andere apparaten meer; support- en privacypagina ook in het Engels; het changelogfilter onthoudt je keuze

## Versie 1.0.0 · Build 59
_12 oktober 2026_

### Alle apps

**Nieuw**

- Taal op covers: een strookje onderaan de poster toont de taal van de versie (bijv. NL, IT, EN · NL ondertitels, Multi); het taallabel verdwijnt uit de titel en de detailpagina toont de taal
- Andere taal: staat dezelfde film of serie in een andere taal in je lijst, dan kies je die op de detailpagina of tijdens het kijken, en kijk je verder op dezelfde plek
- Ondertitels automatisch (uit, als nodig, altijd) met een voorkeurstaal: is de audio in een andere taal, dan gaan ondertitels in jouw taal vanzelf aan, eerst uit de stream en anders van OpenSubtitles

**Verbeterd**

- Audiotaal: je voorkeurstaal (standaard de taal van de app) wordt automatisch gekozen; wisselen werkt betrouwbaarder en bij een stream met één audiotaal zie je dat meteen
- Sneller starten: kleinere buffer, direct verder op de juiste plek en niets wacht meer op de server, de leeftijdscontrole of ondertitels voordat het beeld begint

## Versie 1.0.0 · Build 58
_12 oktober 2026_

### Alle apps

**Verbeterd**

- De knop Afspelen is nu gevuld in de accentkleur van je profiel (standaard rood) met witte tekst en icoon; op tv's blijft de selectie duidelijk zichtbaar
- De knop Andere bronnen heeft overal een eigen icoon: op de detailpagina, in de speler en bij een afspeelfout

## Versie 1.0.0 · Build 57
_12 oktober 2026_

### Alle apps, de website en de server

**Nieuw**

- Bij Nu aan het kijken en in de kijkgeschiedenis staat de profielfoto van elk profiel voor de regel (alleen voor het hoofdaccount, met alle profielen)

### iOS, iPadOS en macOS

**Verbeterd**

- Ondertitels via AirPlay: OpenSubtitles-ondertitels verschijnen bij HLS-streams ook op de Apple TV, en het gekozen ondertitelspoor blijft staan als je naar AirPlay overschakelt

### iOS, iPadOS, macOS en Android

**Nieuw**

- Ondertitels gaan mee naar de Chromecast: gedownloade ondertitels (OpenSubtitles) en ondertitelsporen uit HLS-streams, ook als je tijdens het casten wisselt

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Een ingeladen ondertitel blijft staan als je van speler wisselt en gaat niet meer mee naar de volgende titel

### Website

**Verbeterd**

- Mijn Bingr: Kijkgeschiedenis en Collecties zijn in- en uitklapbaar en staan standaard dicht; bij apparaten en collecties staan Naam wijzigen en Verwijderen onder de tekst

## Versie 1.0.0 · Build 56
_12 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Synchroniseren bouwt het scherm niet meer onnodig opnieuw op, en collecties bewerken reageert direct tijdens het typen

### iOS, iPadOS, tvOS, macOS, Android en Android TV

**Verbeterd**

- Soepeler scrollen: collecties en leeftijdsclassificaties worden op de achtergrond bijgewerkt, alleen als er echt iets veranderd is, zonder dat lijsten haperen of verspringen
- Live TV: het zendervoorbeeld start pas als je even op een zender blijft staan en hapert niet meer bij snel scrollen; de tv-gids reageert sneller

## Versie 1.0.0 · Build 55
_12 oktober 2026_

### iOS, iPadOS, tvOS, macOS, Android, Android TV en Website

**Verbeterd**

- Samsung TV verschijnt met eigen icoon in je apparatenlijst, bij Wie kijkt er nu en in de kijkgeschiedenis

### Website

**Nieuw**

- Website: Samsung TV bij de apparaten, een downloadknop voor het .wgt-bestand en uitleg over installeren op je Samsung TV

## Versie 1.0.0 · Build 54
_12 oktober 2026_

### Alle apps

**Nieuw**

- Elk profiel heeft een eigen accentkleur; die wisselt mee als je van profiel wisselt en gaat mee naar al je apparaten

### Alle apps en de website

**Nieuw**

- Collecties per profiel: elk profiel, ook een kinderprofiel, maakt zijn eigen collecties. Bestaande collecties staan bij elk profiel, er verdwijnt niets

### iOS en iPadOS

**Verbeterd**

- Ondersteuning voor Apple Vision Pro is weer verwijderd

### iOS, iPadOS en macOS

**Opgelost**

- Het gekozen app-icoon blijft na een update goed staan

### iOS, iPadOS, macOS en Android

**Verbeterd**

- Alleen het hoofdprofiel kan het app-icoon wijzigen; andere profielen kiezen alleen hun accentkleur

## Versie 1.0.0 · Build 53
_12 oktober 2026_

### Alle apps

**Nieuw**

- Kijkvoortgang in procenten: hoeveel van de serie en van elk seizoen je hebt gezien
- Trailer per seizoen: de trailerknop speelt de trailer van het gekozen seizoen

**Verbeterd**

- Een serie opent bij de aflevering waar je bent: de afleveringenlijst scrolt er direct naartoe

**Opgelost**

- Kinderprofielen filteren nu echt op leeftijd, overal in de app: met Kijkwijzer-classificaties via TMDB, en titels zonder leeftijd alleen als ze duidelijk voor kinderen zijn
- Live tv en de tv-gids tonen op een kinderprofiel alleen kinderzenders

## Versie 1.0.0 · Build 52
_12 oktober 2026_

### Alle apps

**Nieuw**

- Intro overslaan: markeer de intro en de aftiteling één keer per serie; daarna krijg je bij elke aflevering een knop Intro overslaan en start bij de aftiteling de volgende aflevering na een aftelling
- Uiterlijk: kies een accentkleur voor de hele app (rood, blauw, groen, paars, oranje of roze)
- Reservebron bij live tv: valt een zender weg, dan schakelt Bingr automatisch over naar dezelfde zender op een andere server; zelf kiezen kan via Andere bron in de speler
- Deinterlacing voor oude SD- en sportzenders: Uit, Automatisch of Aan
- Start bij laatste zender: na het kiezen van je profiel meteen verder met de zender die je het laatst keek (optioneel)

**Verbeterd**

- Slim foutherstel: eerst stil opnieuw proberen, daarna Opnieuw, Andere bron of Andere speler, en je kijkt verder op dezelfde plek

### iOS, iPadOS en Android

**Nieuw**

- Downloads: films en afleveringen downloaden en offline kijken, met een eigen Downloads-overzicht. Het downloaden gaat door op de achtergrond en je ziet de voortgang op het toegangsscherm

### iOS, iPadOS, macOS en Android

**Nieuw**

- Kies een ander app-icoon: donker, licht, blauw of goud (op de Mac het Dock-icoon zolang Bingr open is)

### iPadOS

**Verbeterd**

- Bingr is geschikt voor Apple Vision Pro als iPad-app

## Versie 1.0.0 · Build 51
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Tegelijk kijken: met één account kijk je op maximaal 6 schermen tegelijk; zijn het er meer, dan zie je wie er kijkt
- Apparaten: je account werkt nu op maximaal 15 apparaten, met per apparaat sinds wanneer het is ingelogd
- Wie kijkt er nu (hoofdaccount): Mijn Bingr → Account toont welk apparaat en profiel wat kijkt, en hoe lang al
- Kijkgeschiedenis van 7 dagen (hoofdaccount): per dag wat er op welk apparaat en profiel gekeken is

### Alle apps

**Nieuw**

- Collecties: maak je eigen rijen met naam en afbeelding, handmatig (Aan collectie toevoegen…) of slim met zoekwoorden
- Startscherm per profiel: zet rijen aan of uit en in je eigen volgorde (Mijn Bingr → Startscherm)
- Zappen: veeg in de live-speler omhoog of omlaag naar de volgende of vorige zender, met zenderbalk en instelbare zapvertraging
- Zendervoorbeeld: in Live TV en de tv-gids speelt de geselecteerde zender na een seconde zonder geluid mee
- Terugkijk-correctie per zender: verschuif het begin van terugkijken met −120 tot +120 minuten
- Evenementzenders (PPV, events) in een eigen groep Evenementen, op begintijd met LIVE-label
- Zoeken: resultaten tonen de kleur van hun bron als je meerdere bronnen hebt

**Verbeterd**

- Direct laden: je bewaarde lijst staat meteen in beeld en wordt op de achtergrond bijgewerkt

### Alle apps, de website en de server

**Nieuw**

- Na het wijzigen van je wachtwoord word je op al je apparaten automatisch uitgelogd

### iOS, iPadOS en Android

**Nieuw**

- Extern scherm: op een aangesloten monitor of tv speelt de video schermvullend, de bediening blijft op je telefoon of tablet

### tvOS en Android TV

**Nieuw**

- Beeldfrequentie aanpassen: de tv schakelt naar de beeldfrequentie van de stream (op Apple TV ook HDR/Dolby Vision)

### Website

**Nieuw**

- Website: servers, collecties, wie kijkt er nu en kijkgeschiedenis in Mijn Bingr

**Verbeterd**

- Website: Apparaten in Mijn Bingr in- en uitklapbaar

## Versie 1.0.0 · Build 50
_12 oktober 2026_

### Alle apps

**Nieuw**

- Nieuw in Mijn Bingr: Bron controleren — zie precies hoeveel zenders, films en series je server aanbiedt en hoeveel Bingr inleest

**Verbeterd**

- Seriepagina opent standaard op het nieuwste seizoen (of op het seizoen waar je gebleven bent)

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Xtream: films, live-zenders en series worden tolerant ingelezen — één afwijkend item op de server kost niet meer de hele lijst, dus je ziet weer alles
- Filminfo (beschrijving, cast, trailer) laadt ook bij servers die velden anders aanleveren

## Versie 1.0.0 · Build 49
_12 oktober 2026_

### Alle apps

**Nieuw**

- Tik op een acteur of actrice voor een eigen pagina met foto, bio en alle films en series waarin die speelt — wat in je afspeellijst staat kijk je direct
- Zoeken op naam van een acteur of actrice toont ook personen

**Verbeterd**

- Copyright onderaan Mijn Bingr: © 2026 Bingr

## Versie 1.0.0 · Build 48
_12 oktober 2026_

### Alle apps

**Verbeterd**

- Lukt het ophalen van afleveringen even niet, dan probeert Bingr het de volgende keer opnieuw

**Opgelost**

- Series van Xtream-servers tonen weer alle seizoenen en afleveringen, ook als de server ze in een andere vorm stuurt

## Versie 1.0.0 · Build 47
_12 oktober 2026_

### Alle apps

**Nieuw**

- Onderaan Mijn Bingr: app-icoon, versie- en buildnummer en copyright

### Website

**Verbeterd**

- Website: hero op mobiel opgeknapt (telefoon en tv netjes naast elkaar) en een kleiner cookie-bolletje

## Versie 1.0.0 · Build 46
_12 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Ondertekening voor iPhone, iPad, Apple TV en Mac staat vast ingesteld (team en automatisch ondertekenen)

## Versie 1.0.0 · Build 45
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Gekoppelde apparaten een eigen naam geven of wijzigen, in de app en op bingr.online/account

### tvOS en Android TV

**Verbeterd**

- Geen deelknop meer op de detailpagina op Apple TV, Android TV, Google TV en Fire TV

### Website

**Nieuw**

- Website: overzicht van alle apparaten waarop je Bingr kijkt, apparaat-iconen in Mijn Bingr en een cookiemelding die je keuze onthoudt
- Website: cookie-bolletje links onderin om je cookiekeuze altijd te wijzigen

**Verbeterd**

- Changelog toont nu versie, build en datum

## Versie 1.0.0 · Build 44
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Alles gaat mee met je account: Trakt- en OpenSubtitles-login, instellingen, Mijn lijst, Verder kijken, bekeken, kijkgeschiedenis, pincodes en herinneringen — na opnieuw installeren of op een nieuw apparaat staat alles weer klaar

## Versie 1.0.0 · Build 43
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Servers en afspeellijsten worden versleuteld bij je Bingr-account bewaard: na updaten, opnieuw installeren of op een nieuw apparaat staat alles na inloggen weer klaar

## Versie 1.0.0 · Build 42
_12 oktober 2026_

### Alle apps

**Opgelost**

- Trakt koppelen werkt weer: na 'Apparaat goedgekeurd' op trakt.tv logt Bingr nu meteen in, ook als de app even op de achtergrond stond

## Versie 1.0.0 · Build 41
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Profielen toevoegen, wijzigen en verwijderen synchroniseert met al je apparaten

**Verbeterd**

- Trakt en OpenSubtitles: gewoon inloggen, de sleutels komen veilig van de Bingr-server

### Website

**Nieuw**

- Website: Mijn Bingr met je profielen, apparaten en account, en je profielfoto rechtsboven; changelog-pagina

## Versie 1.0.0 · Build 40
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Eigen profielfoto's worden via je Bingr-account gedeeld met al je apparaten, ook Android

## Versie 1.0.0 · Build 39
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Maximaal 10 apparaten per account
- Apparaten beheren: gekoppeld op, laatst gebruikt en verwijderen (in de app en op bingr.online/account)

### Alle apps

**Nieuw**

- Een verwijderd apparaat logt automatisch uit

## Versie 1.0.0 · Build 38
_12 oktober 2026_

### Alle apps en de server

**Nieuw**

- Bingr-account: inloggen of account maken na de splash, in Netflix-stijl
- Bestaande profielen worden aan je account gekoppeld en gedeeld met al je apparaten

### Alle apps, de website en de server

**Nieuw**

- E-mails in Bingr-stijl (NL/EN), wachtwoord herstellen via bingr.online/reset

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Versie- en buildnummer worden nu goed meegegeven aan de App Store

### tvOS, Android TV en Website

**Nieuw**

- Apple TV, Android TV en Fire TV: inloggen met een QR-code via bingr.online/tv

## Versie 1.0.0 · Build 37
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Vloeiender scrollen; Verder kijken staat boven Mijn lijst

**Opgelost**

- Een verwijderde pincode blijft op alle apparaten verwijderd

## Versie 1.0.0 · Build 36
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Nieuw**

- Ondertitelgrootte instellen (klein, middel, groot), ook tijdens het kijken

**Opgelost**

- Detailpagina's lopen niet meer vast

### tvOS

**Opgelost**

- Apple TV: pauze, spoelen en ondertitels bereikbaar in de speler

## Versie 1.0.0 · Build 35
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Verbeterd**

- Profiel opent veel sneller na het invoeren van de pincode

## Versie 1.0.0 · Build 34
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Nieuw**

- Bingr houdt zelf per profiel bij wat je gezien hebt, ook zonder Trakt

### Website

**Nieuw**

- Nieuwe website bingr.online met echte covers

## Versie 1.0.0 · Build 33
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Nieuw**

- Zichtbare Trakt-synchronisatie (draaiende pijltjes) en melding bij scrobblen

## Versie 1.0.0 · Build 32
_11 oktober 2026_

### iOS, iPadOS, tvOS en macOS

**Opgelost**

- Afspelen na het invoeren van de pincode werkt altijd

### tvOS

**Verbeterd**

- Compacte pincode op Apple TV die op elk scherm past

## Versie 1.0.0 · Build 31
_11 oktober 2026_

### macOS

**Nieuw**

- Eigen Mac-app (macOS 14+)

## Versie 1.0.0 · Build 30
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- 16 getekende profielfiguurtjes; geen 'Kids'-label meer bij de naam

## Versie 1.0.0 · Build 29
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Delen vanaf de detailpagina (WhatsApp, iMessage …), QR-code op Apple TV

## Versie 1.0.0 · Build 28
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Opgelost**

- Betrouwbare Trakt-synchronisatie van wat je gezien hebt

## Versie 1.0.0 · Build 27
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Verder kijken met voortgangsbalk en de keuze hervatten of opnieuw kijken

**Opgelost**

- Mijn lijst werkt weer

## Versie 1.0.0 · Build 26
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Zoeken op Live TV (iPhone, iPad en Apple TV)
- Volgende aflevering automatisch

**Verbeterd**

- Sneller en soepeler

## Versie 1.0.0 · Build 25
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Kinderprofiel met strenge leeftijdsfilter en een eigen Top 10 voor kids

## Versie 1.0.0 · Build 24
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Kijkgeschiedenis en Verder kijken per profiel
- Mijn Bingr zoals Mijn Netflix

## Versie 1.0.0 · Build 23
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Automatische ondertitels en talen per profiel

## Versie 1.0.0 · Build 22
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Pincode per profiel; Trakt alleen voor het hoofdaccount

## Versie 1.0.0 · Build 21
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Servers verwijderen, sneller wisselen van profiel

## Versie 1.0.0 · Build 20
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Hoofdaccount beheert server, koppelingen, kinderslot en profielen

## Versie 1.0.0 · Build 19
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Profielen: 'Wie kijkt er?' en eigen Bingr-intro

## Versie 1.0.0 · Build 18
_11 oktober 2026_

### tvOS

**Nieuw**

- Apple TV zonder grijze focusvlakken, zoals Netflix

## Versie 1.0.0 · Build 17
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Verbeterd**

- Ondertitels met vlaggen, juiste tekens en timing verschuiven; snellere start

## Versie 1.0.0 · Build 16
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Zoeken door alle content en categorieën

## Versie 1.0.0 · Build 14
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Top 10 altijd zichtbaar (TMDB en Trakt trending)

### tvOS

**Nieuw**

- Elke Apple TV-gebruiker zijn eigen Bingr

## Versie 1.0.0 · Build 13
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Opgelost**

- Trakt werkt met nieuwe apps zonder client secret

## Versie 1.0.0 · Build 11
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- OpenSubtitles: taal kiezen tijdens het kijken, automatisch laden

## Versie 1.0.0 · Build 10
_11 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Standaard audio- en ondertiteltaal, beeld-in-beeld, kijkgeschiedenis, NAS (SMB/DLNA)

## Versie 1.0.0 · Build 8
_10 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Bekijk allemaal met sorteren en scores

## Versie 1.0.0 · Build 6
_10 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Nieuw Bingr-logo in app, icoon en Top Shelf

## Versie 1.0.0 · Build 1
_10 oktober 2026_

### iOS, iPadOS en tvOS

**Nieuw**

- Eerste versie: IPTV in Netflix-stijl voor iPhone, iPad en Apple TV (M3U, Xtream, Stalker, Plex, Jellyfin, Emby, Stremio)
