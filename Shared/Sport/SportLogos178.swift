import Foundation

// Build 178: sport-logo's. Pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift),
// gelijk aan web/js/sportlogos.js (bingr-website) en SportLogos178Logic.kt (bingr-android). Gedeelde testgevallen:
// docs/sportlogos_cases.json.
// Werkt zoals Weekdot (SportsArtwork.swift): niets in de app of de repo; logo's worden live opgehaald en op het toestel
// bewaard, en alleen ter herkenning getoond (vermelding onderaan het sportoverzicht).
// - competitielogo's: maak-agenda.nl/images/leagues/<slug>.png, anders het favicon van de officiële site (Google);
// - vlaggen van landenteams: maak-agenda.nl/images/national/<LAND>.png;
// - clublogo's: de teamlijst van ESPN per competitie (alle clubs in één keer), zoeken op de opgeschoonde naam;
//   niet gevonden: TheSportsDB (zoeken op naam);
// - cache: index 7 dagen, niet gevonden 1 dag, afbeeldingen 7 dagen; met Data besparen alleen uit de cache (ook verlopen).

enum SportLogos178 {
    static let indexMaxAge: Double = 7 * 86400
    static let missMaxAge: Double = 1 * 86400
    static let imageMaxAge: Double = 7 * 86400

    /// Sporten met clubs (de rest heeft spelers of rijders: daar blijft de cirkel met initialen).
    static let teamSports: Set<String> = ["football", "basketball", "americanfootball", "icehockey"]

    // MARK: namen en sleutels (zelfde normalisatie als Weekdot, op de opgeschoonde naam van Sport173)

    /// Voor- en achtervoegsels die uitgevers toevoegen of weglaten.
    static let affixes: Set<String> = ["fc", "sc", "afc", "cf", "ac", "sv", "bv", "vv", "fk", "sk", "if", "bk",
                                       "club", "cd", "ud", "sd", "rc", "rcd", "ss", "as", "us", "ogc", "losc", "the"]

    /// Sleutels om een club te zoeken: alle woorden aan elkaar, en zonder clubaffixen (als dat iets anders is).
    static func keys(_ name: String) -> [String] {
        let t = Sport173.tokens(Sport173.cleanTeam(name))
        let full = t.joined()
        let stripped = t.filter { !affixes.contains($0) }.joined()
        var out: [String] = []
        for k in [full, stripped] where !k.isEmpty && !out.contains(k) { out.append(k) }
        return out
    }

    /// Zoeken in een index (sleutel → logo): eerst precies, dan een uniek voorvoegsel ("Heracles" → "Heracles Almelo").
    static func match(_ wanted: [String], in index: [String: String]) -> String? {
        for k in wanted { if let hit = index[k] { return hit } }
        for k in wanted where k.count >= 3 {
            var found = Set<String>()
            for (key, value) in index where key.hasPrefix(k) || (k.hasPrefix(key) && key.count >= 4) { found.insert(value) }
            if found.count == 1 { return found.first }
        }
        return nil
    }

    /// Index uit een teamlijst: elke naam van een team → zijn logo (alleen https; de eerste wint).
    static func buildIndex(_ teams: [(names: [String], logo: String)]) -> [String: String] {
        var index: [String: String] = [:]
        for team in teams {
            let logo = team.logo.trimmingCharacters(in: .whitespaces)
            guard logo.lowercased().hasPrefix("https://") else { continue }
            for name in team.names {
                for k in keys(name) where index[k] == nil { index[k] = logo }
            }
        }
        return index
    }

    /// Kleine versie van een TheSportsDB-badge ("…/small"), alleen https.
    static func sportsDBThumb(_ badge: String) -> String? {
        let b = badge.trimmingCharacters(in: .whitespaces)
        guard b.lowercased().hasPrefix("https://") else { return nil }
        return b.hasSuffix("/small") ? b : b + "/small"
    }

    /// Sport zoals TheSportsDB hem noemt (alleen records van die sport tellen).
    static func sportsDBSport(_ sport: String) -> String {
        switch sport {
        case "basketball": return "Basketball"
        case "americanfootball": return "American Football"
        case "icehockey": return "Ice Hockey"
        default: return "Soccer"
        }
    }

    // MARK: competities

    /// maak-agenda.nl-slug van een competitie (Sport173.competitions), of nil.
    static let leagueSlugs: [String: String] = [
        "eredivisie": "eredivisie", "kkd": "keuken-kampioen-divisie", "knvb-beker": "beker",
        "champions-league": "champions-league", "europa-league": "europa-league",
        "conference-league": "uefa-conference-league", "premier-league": "premier-league", "laliga": "primera-division",
        "serie-a": "serie-a", "bundesliga": "bundesliga", "ligue-1": "ligue-1", "jupiler-pro-league": "jupiler-pro-league",
        "wk": "fifa-world-cup-2026", "motogp": "motogp", "formula-1": "formula-1", "nba": "nba", "nfl": "nfl"
    ]

    /// Officiële site van een competitie (voor het favicon), of nil.
    static let sites: [String: String] = [
        "premier-league-darts": "pdc.tv", "wk-darts": "pdc.tv", "pdc": "pdc.tv",
        "eredivisie": "eredivisie.nl", "kkd": "keukenkampioendivisie.nl", "knvb-beker": "knvb.nl",
        "champions-league": "uefa.com", "europa-league": "uefa.com", "conference-league": "uefa.com",
        "premier-league": "premierleague.com", "laliga": "laliga.com", "serie-a": "legaseriea.it",
        "bundesliga": "bundesliga.com", "ligue-1": "ligue1.com", "jupiler-pro-league": "proleague.be",
        "wk": "fifa.com", "ek": "uefa.com", "motogp": "motogp.com", "formula-1": "formula1.com",
        "atp": "atptour.com", "wta": "wtatennis.com", "nba": "nba.com", "nfl": "nfl.com", "nhl": "nhl.com", "ufc": "ufc.com"
    ]

    static func leagueSlug(_ competitionID: String) -> String? { leagueSlugs[competitionID] }
    static func site(_ competitionID: String) -> String? { sites[competitionID] }

    /// Adressen voor het logo van een competitie, in volgorde: groot = maak-agenda.nl en dan het favicon;
    /// klein (lijsten zoals Mijn teams en competities) = eerst het favicon, zoals Weekdot.
    static func competitionURLs(_ competitionID: String, small: Bool) -> [String] {
        var out: [String] = []
        if let s = leagueSlug(competitionID) { out.append(leagueURL(s)) }
        if let d = site(competitionID) { out.append(faviconURL(d, size: 128)) }
        return small ? out.reversed() : out
    }

    // MARK: clubs

    private static let footballMajor = ["ned.1", "eng.1", "esp.1", "ger.1", "ita.1", "fra.1", "por.1", "bel.1", "tur.1",
                                        "sco.1", "uefa.champions", "uefa.europa", "uefa.europa.conf", "ned.2"]

    /// ESPN-competities waarin clubs van deze wedstrijd gezocht worden (leeg = geen clubs, bijv. landenteams of tennis).
    static func espnLeagues(sport: String, competitionID: String) -> [String] {
        switch sport {
        case "basketball": return ["basketball/nba"]
        case "americanfootball": return ["football/nfl"]
        case "icehockey": return ["hockey/nhl"]
        case "football": break
        default: return []
        }
        switch competitionID {
        case "eredivisie": return ["ned.1", "ned.2"]
        case "kkd": return ["ned.2", "ned.1"]
        case "knvb-beker": return ["ned.1", "ned.2"]
        case "champions-league": return ["uefa.champions"]
        case "europa-league": return ["uefa.europa"]
        case "conference-league": return ["uefa.europa.conf"]
        case "premier-league": return ["eng.1", "eng.2"]
        case "laliga": return ["esp.1"]
        case "serie-a": return ["ita.1"]
        case "bundesliga": return ["ger.1", "ger.2"]
        case "ligue-1": return ["fra.1"]
        case "jupiler-pro-league": return ["bel.1"]
        case "wk", "ek": return []
        default: return footballMajor
        }
    }

    // MARK: landenteams

    /// Landnamen (NL, EN, DE, FR, ES en een paar bijnamen) → landcode van de vlag op maak-agenda.nl.
    static let countries: [String: String] = {
        let list: [(String, [String])] = [
            ("NL", ["nederland", "netherlands", "holland", "oranje", "niederlande", "pays bas", "paises bajos"]),
            ("BE", ["belgie", "belgium", "belgien", "belgique", "belgica"]),
            ("DE", ["duitsland", "germany", "deutschland", "allemagne", "alemania"]),
            ("FR", ["frankrijk", "france", "frankreich", "francia"]),
            ("GB", ["engeland", "england", "angleterre", "inglaterra", "groot brittannie", "great britain"]),
            ("ES", ["spanje", "spain", "spanien", "espagne", "espana"]),
            ("IT", ["italie", "italy", "italien", "italia"]),
            ("PT", ["portugal"]),
            ("DK", ["denemarken", "denmark", "danemark", "dinamarca"]),
            ("SE", ["zweden", "sweden", "schweden", "suede", "suecia"]),
            ("NO", ["noorwegen", "norway", "norwegen", "norvege", "noruega"]),
            ("FI", ["finland", "finnland", "finlande", "finlandia"]),
            ("IS", ["ijsland", "iceland", "island", "islande", "islandia"]),
            ("IE", ["ierland", "ireland", "irland", "irlande", "irlanda"]),
            ("CH", ["zwitserland", "switzerland", "schweiz", "suisse", "suiza"]),
            ("AT", ["oostenrijk", "austria", "osterreich", "autriche"]),
            ("PL", ["polen", "poland", "pologne", "polonia"]),
            ("CZ", ["tsjechie", "czechia", "czech republic", "tschechien", "tchequie", "chequia"]),
            ("SK", ["slowakije", "slovakia", "slowakei", "slovaquie", "eslovaquia"]),
            ("HU", ["hongarije", "hungary", "ungarn", "hongrie", "hungria"]),
            ("RO", ["roemenie", "romania", "rumanien", "roumanie", "rumania"]),
            ("BG", ["bulgarije", "bulgaria", "bulgarien", "bulgarie"]),
            ("GR", ["griekenland", "greece", "griechenland", "grece", "grecia"]),
            ("TR", ["turkije", "turkey", "turkiye", "turkei", "turquie", "turquia"]),
            ("HR", ["kroatie", "croatia", "kroatien", "croatie", "croacia"]),
            ("RS", ["servie", "serbia", "serbien", "serbie"]),
            ("SI", ["slovenie", "slovenia", "slowenien", "eslovenia"]),
            ("BA", ["bosnie", "bosnia", "bosnie herzegovina", "bosnia and herzegovina", "bosnien"]),
            ("ME", ["montenegro"]),
            ("AL", ["albanie", "albania", "albanien"]),
            ("MK", ["noord macedonie", "north macedonia", "nordmazedonien"]),
            ("UA", ["oekraine", "ukraine", "ucrania"]),
            ("GE", ["georgie", "georgia", "georgien"]),
            ("AM", ["armenie", "armenia", "armenien"]),
            ("AZ", ["azerbeidzjan", "azerbaijan", "aserbaidschan"]),
            ("KZ", ["kazachstan", "kazakhstan", "kasachstan"]),
            ("IL", ["israel"]),
            ("CY", ["cyprus", "zypern", "chypre", "chipre"]),
            ("LU", ["luxemburg", "luxembourg"]),
            ("LT", ["litouwen", "lithuania", "litauen"]),
            ("LV", ["letland", "latvia", "lettland"]),
            ("EE", ["estland", "estonia"]),
            ("MT", ["malta"]),
            ("FO", ["faeroer", "faroe islands", "faroer"]),
            ("SM", ["san marino"]),
            ("AD", ["andorra"]),
            ("LI", ["liechtenstein"]),
            ("GI", ["gibraltar"]),
            ("MD", ["moldavie", "moldova", "moldawien"]),
            ("BY", ["wit rusland", "belarus", "weissrussland"]),
            ("RU", ["rusland", "russia", "russland", "russie", "rusia"]),
            ("US", ["verenigde staten", "united states", "usa"]),
            ("CA", ["canada", "kanada"]),
            ("MX", ["mexico", "mexiko"]),
            ("BR", ["brazilie", "brazil", "brasilien", "bresil", "brasil"]),
            ("AR", ["argentinie", "argentina", "argentinien", "argentine"]),
            ("UY", ["uruguay"]),
            ("CO", ["colombia", "kolumbien", "colombie"]),
            ("CL", ["chili", "chile"]),
            ("EC", ["ecuador"]),
            ("PE", ["peru"]),
            ("PY", ["paraguay"]),
            ("JP", ["japan", "japon"]),
            ("KR", ["zuid korea", "south korea", "korea republic", "sudkorea"]),
            ("AU", ["australie", "australia", "australien"]),
            ("MA", ["marokko", "morocco", "maroc", "marruecos"]),
            ("SN", ["senegal"]),
            ("NG", ["nigeria"]),
            ("GH", ["ghana"]),
            ("CM", ["kameroen", "cameroon", "kamerun", "cameroun"]),
            ("EG", ["egypte", "egypt", "agypten"]),
            ("TN", ["tunesie", "tunisia", "tunesien", "tunisie"]),
            ("DZ", ["algerije", "algeria", "algerien", "algerie"]),
            ("CI", ["ivoorkust", "ivory coast", "cote d ivoire", "elfenbeinkuste"]),
            ("ZA", ["zuid afrika", "south africa", "sudafrika"]),
            ("SA", ["saoedi arabie", "saudi arabia", "saudi arabien"]),
            ("QA", ["qatar", "katar"]),
            ("IR", ["iran"]),
            ("CW", ["curacao"]),
            ("SR", ["suriname"])
        ]
        var map: [String: String] = [:]
        for (code, names) in list { for n in names { map[Sport173.tokens(n).joined()] = code } }
        return map
    }()

    private static let womenWords: Set<String> = ["vrouwen", "women", "womens", "dames", "frauen", "femmes", "w"]

    /// Landcode als deze naam een landenteam is ("Nederland", "Oranje", "Germany", "Nederland Vrouwen"), anders nil.
    static func countryCode(_ name: String) -> String? {
        let t = Sport173.tokens(Sport173.cleanTeam(name))
        let k = t.filter { !womenWords.contains($0) }.joined()
        guard !k.isEmpty else { return nil }
        return countries[k]
    }

    /// Wat er bij een team staat: "flag:<LAND>" (landenteam), "club" (clublogo zoeken) of "" (cirkel met initialen).
    static func teamArt(_ name: String, sport: String, competitionID: String) -> String {
        guard teamSports.contains(sport) else { return "" }
        if let c = countryCode(name) { return "flag:" + c }
        return espnLeagues(sport: sport, competitionID: competitionID).isEmpty ? "" : "club"
    }

    // MARK: adressen

    static func leagueURL(_ slug: String) -> String {
        let clean = slug.split(separator: "/").first.map(String.init) ?? slug
        return "https://maak-agenda.nl/images/leagues/\(clean).png"
    }
    static func flagURL(_ code: String) -> String { "https://maak-agenda.nl/images/national/\(code.uppercased()).png" }
    static func faviconURL(_ domain: String, size: Int) -> String {
        "https://www.google.com/s2/favicons?domain=\(encode(domain))&sz=\(size)"
    }
    static func espnTeamsURL(_ code: String) -> String {
        "https://site.api.espn.com/apis/site/v2/sports/" + (code.contains("/") ? code : "soccer/" + code) + "/teams"
    }
    static func sportsDBSearchURL(_ name: String) -> String {
        "https://www.thesportsdb.com/api/v1/json/123/searchteams.php?t=" + encode(Sport173.cleanTeam(name))
    }

    /// Procent-codering zoals encodeURIComponent zonder ! ' ( ) *: alles behalve A-Z a-z 0-9 - . _ ~ (UTF-8).
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: out.append(Character(Unicode.Scalar(b)))
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    // MARK: cache

    /// Mag een bewaard item (index, niet-gevonden of afbeelding) gebruikt worden? Vers: jonger dan de maximale leeftijd.
    /// Met Data besparen (geen netwerk) telt alles wat er is, ook verlopen.
    static func usable(kind: String, age: Double, saver: Bool) -> Bool {
        if saver { return true }
        let max: Double
        switch kind {
        case "index": max = indexMaxAge
        case "miss": max = missMaxAge
        default: max = imageMaxAge
        }
        return age >= 0 && age < max
    }

    /// Naam van een cachebestand: voorvoegsel + FNV-1a (hex) van de sleutel, bijv. "crests2-1a2b3c4d.json".
    static func cacheName(_ prefix: String, _ key: String, ext: String) -> String {
        prefix + "-" + String(format: "%08x", Sport173.hash(key)) + (ext.isEmpty ? "" : "." + ext)
    }
}
