import Foundation

// Build 150: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
//
// Aanleiding (foto Apple TV, build 149): in "Ontdek categorieën" stonden "| NL | NETFLIX", "| MULTI / LINGO | NETFLIX"
// en "| NL | VIDEOLAND", en een rij heette "| NL | BIOSCOOP": het voorvoegsel bleef staan (o.a. andere pipe-tekens
// en "MULTI / LINGO"), Netflix stond er twee keer en het logo kwam niet (de TMDB-match zag de vieze naam).
//
// Eén plek voor het opschonen van categorienamen: `CategoryName.parse` haalt taal-, land-, kwaliteits- en
// VOD-labels weg (voor- en achteraan, in elke volgorde), zet een naam in HOOFDLETTERS in nette hoofdletters en
// geeft de weggehaalde talen terug als labels (chips). `PlaylistService.apply` gebruikt hem voor elke categorie,
// zodat Home, Films, Series, Live TV, filters, zoeken en details dezelfde naam tonen en gelijke namen één
// categorie worden.

enum CategoryName {
    struct Parsed: Sendable, Equatable {
        /// Opgeschoonde naam ("Netflix")
        var name: String
        /// Weggehaalde talen/landen en "Multi"/"Sub"/"Dub", in volgorde ("NL", "Multi")
        var labels: [String]
        /// Alleen die van vooraan (voor de snelknoppen per land/taal)
        var prefixLabels: [String]
    }

    private enum Tag { case label(String), quality, word }
    private enum Mode { case bracket, separated, spaced }

    // MARK: woordenlijsten

    /// Pipes en andere tekens die als "|" tellen (build 153: één lijst voor categorieën, titels en zenders)
    static let pipes: Set<Character> = ["¦", "│", "┃", "｜", "‖", "∣", "丨", "┆", "┇", "┊", "┋", "╎", "╏", "︱", "︳", "⏐", "⎮",
                                        "▏", "▕", "ǀ", "׀", "⼁", "∥", "❘", "❙", "❚", "￨"]
    static let separators: Set<Character> = ["|", ":", "：", "-", "–", "—", "/", "•", "·", "★", "☆", "»", "«", "›", "‹", "*", "#",
                                              "_", "▶", "►", "~", ",", ";", "=", "◆", "●", "♦"]
    private static let closer: [Character: Character] = ["[": "]", "(": ")", "{": "}", "【": "】", "「": "」", "〔": "〕"]
    private static let opener: [Character: Character] = ["]": "[", ")": "(", "}": "{", "】": "【", "」": "「", "〕": "〔"]

    private static let iso6391 = """
    aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es \
    et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj \
    kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv \
    ny oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti \
    tk tl tn to tr ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu
    """
    private static let iso3166 = """
    ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz ca cc cd \
    cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg eh er es et fi fj fk fm fo fr ga gb gd ge gf \
    gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn \
    kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na \
    nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si \
    sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug um us uy uz va vc ve vg vi \
    vn vu wf ws ye yt za zm zw uk eu
    """
    /// Veelgebruikte drieletterige codes (ISO 639-2 en 3166-1 alpha-3)
    private static let alpha3 = """
    nld dut eng deu ger fra fre spa esp ita tur pol por prt ara rus hin bel usa gbr can aus ind chn jpn kor swe nor dnk dan \
    fin che aut irl grc gre rou ron hun cze ces alb sqi srb hrv bos mkd bgr bul ukr fas urd pak afg som kur bra mex arg col \
    isr heb tha vie idn msa phl lat exyu
    """
    /// Woorden die nooit als code tellen (ook al staan ze in een ISO-lijst)
    private static let notCodes: Set<String> = ["tv", "fm", "go", "hd", "sd", "dv", "ok", "am", "pm", "xl", "dj", "uv", "ai"]
    private static let codes: Set<String> = {
        var s = Set((iso6391 + " " + iso3166 + " " + alpha3).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        s.subtract(notCodes)
        return s
    }()
    /// Codes die ook zonder scheidingsteken herkend worden ("Kids NL", "NL Kids"), alleen in hoofdletters
    private static let spacedSuffix: Set<String> = ["nl", "be", "en", "uk", "us", "de", "fr", "es", "pt", "tr", "pl", "ar", "gb",
                                                   "nld", "eng", "deu", "ger", "fra", "ita", "spa", "tur", "pol", "por", "ara"]
    private static let spacedPrefix: Set<String> = ["nl", "uk", "fr", "tr", "pl", "pt", "ar", "gb", "nld", "eng", "deu", "ger",
                                                   "fra", "ita", "spa", "tur", "pol", "por", "ara"]

    private static let quality: Set<String> = ["4k", "8k", "uhd", "fhd", "hd", "sd", "hevc", "h265", "h264", "h.265", "h.264",
                                               "x265", "x264", "hdr", "hdr10", "dv", "1080p", "720p", "2160p", "4kuhd", "uhd4k",
                                               "60fps", "50fps", "hq", "lq", "raw", "3d", "dolby", "atmos", "fullhd", "ultrahd"]
    /// Woord → label (nil = geen label, wel weg)
    private static let multi: [String: String] = [
        "multi": "Multi", "multilang": "Multi", "multilanguage": "Multi", "multilingo": "Multi", "lingo": "Multi",
        "lang": "Multi", "langs": "Multi", "multiaudio": "Multi", "dual": "Multi", "audio": "Multi",
        "multisub": "Sub", "multisubs": "Sub", "sub": "Sub", "subs": "Sub", "subbed": "Sub", "subtitled": "Sub",
        "ondertiteld": "Sub", "vostfr": "Sub", "vost": "Sub",
        "dub": "Dub", "dubbed": "Dub", "gesproken": "Dub", "nasynchro": "Dub", "vf": "Dub", "vff": "Dub", "vo": "Multi",
    ]
    /// Alleen vooraan en alleen naast een andere naam ("VOD | Netflix", "FILMS: Actie")
    private static let prefixWords: Set<String> = ["vod", "series", "serie", "films", "film", "movies", "movie", "vip", "tvshows",
                                                  "shows", "boxset", "boxsets", "collection", "collectie"]
    /// Talen en landen voluit (NL en EN, en de eigen naam) → label
    private static let names: [String: String] = [
        "nederlands": "NL", "dutch": "NL", "nederland": "NL", "netherlands": "NL", "holland": "NL", "hollands": "NL",
        "vlaams": "BE", "flemish": "BE", "belgie": "BE", "belgium": "BE", "belgique": "BE", "belgisch": "BE",
        "engels": "EN", "english": "EN", "engeland": "UK", "england": "UK", "brits": "UK", "british": "UK",
        "amerikaans": "US", "american": "US", "america": "US",
        "duits": "DE", "german": "DE", "deutsch": "DE", "duitsland": "DE", "germany": "DE", "deutschland": "DE",
        "frans": "FR", "french": "FR", "francais": "FR", "frankrijk": "FR", "france": "FR",
        "spaans": "ES", "spanish": "ES", "espanol": "ES", "spanje": "ES", "spain": "ES", "espana": "ES", "latino": "ES",
        "italiaans": "IT", "italian": "IT", "italiano": "IT", "italie": "IT", "italy": "IT", "italia": "IT",
        "turks": "TR", "turkish": "TR", "turkce": "TR", "turkije": "TR", "turkey": "TR", "turkiye": "TR",
        "pools": "PL", "polish": "PL", "polski": "PL", "polen": "PL", "poland": "PL", "polska": "PL",
        "portugees": "PT", "portuguese": "PT", "portugues": "PT", "portugal": "PT", "brazilie": "BR", "brazil": "BR", "brasil": "BR",
        "arabisch": "AR", "arabic": "AR", "arab": "AR", "russisch": "RU", "russian": "RU", "rusland": "RU", "russia": "RU",
        "hindi": "HI", "indian": "IN", "indiaas": "IN", "grieks": "GR", "greek": "GR", "albanees": "AL", "albanian": "AL",
        "roemeens": "RO", "romanian": "RO", "koerdisch": "KU", "kurdish": "KU", "perzisch": "FA", "persian": "FA", "farsi": "FA",
        "somalisch": "SO", "somali": "SO", "zweeds": "SE", "swedish": "SE", "noors": "NO", "norwegian": "NO", "deens": "DK",
        "danish": "DK", "fins": "FI", "finnish": "FI", "scandinavisch": "Nordic", "nordic": "Nordic", "scandinavian": "Nordic",
    ]
    /// Codes → label waar dat duidelijker is
    private static let codeLabel: [String: String] = [
        "nld": "NL", "dut": "NL", "eng": "EN", "deu": "DE", "ger": "DE", "fra": "FR", "fre": "FR", "spa": "ES", "esp": "ES",
        "ita": "IT", "tur": "TR", "pol": "PL", "por": "PT", "prt": "PT", "ara": "AR", "rus": "RU", "gbr": "UK", "gb": "UK",
        "bel": "BE", "exyu": "EX-YU",
    ]

    // MARK: hoofdletters

    /// Afkortingen en merken die in hoofdletters blijven
    static let acronyms: Set<String> = [
        "HBO", "BBC", "NPO", "RTL", "SBS", "VTM", "ESPN", "TV", "F1", "MTV", "CNN", "NBC", "ABC", "CBS", "UFC", "WWE", "NBA",
        "NFL", "NHL", "MLB", "UEFA", "FIFA", "ITV", "DAZN", "BT", "TLC", "AMC", "FX", "HGTV", "CNBC", "NHK", "KBS", "MBC",
        "TVE", "RAI", "ZDF", "ARD", "ORF", "SRF", "VRT", "RTBF", "NOS", "EO", "VPRO", "BNN", "KRO", "NCRV", "AVRO", "GO",
        "VOD", "USA", "UK", "EU", "XXX", "UHD", "HD", "FHD", "SD", "DTS", "AXN", "TNT", "TBS", "HLN", "SVT", "DR", "NRK",
        "YLE", "TRT", "ATV", "ID", "DC", "MCU", "TMF", "PPV", "XL", "VIP", "LGBT", "LGBTQ", "WK", "EK", "FBI", "MGM", "DJ",
        "US", "KPN", "BVN", "AT5", "OCS", "TF1", "M6", "RMC",
        "NOVA", "TVB", "SABC", "PBS", "HBO2", "AMC+", "TV+", "XXL", "VR", "AI", "ATP", "WTA", "PGA", "NASCAR", "MMA", "IPTV",
    ]
    /// Merknamen zoals ze geschreven worden (op `ProviderMatch.key`)
    static let brands: [String: String] = [
        "netflix": "Netflix", "videoland": "Videoland", "skyshowtime": "SkyShowtime", "disneyplus": "Disney+", "disney": "Disney",
        "hbomax": "HBO Max", "hbo": "HBO", "primevideo": "Prime Video", "amazonprimevideo": "Amazon Prime Video",
        "amazonprime": "Amazon Prime", "appletvplus": "Apple TV+", "appletv": "Apple TV", "npostart": "NPO Start",
        "npoplus": "NPO Plus", "viaplay": "Viaplay", "paramountplus": "Paramount+", "vtmgo": "VTM GO", "streamz": "Streamz",
        "pathethuis": "Pathé Thuis", "dazn": "DAZN", "youtube": "YouTube", "discoveryplus": "Discovery+", "canalplus": "Canal+",
        "ziggosport": "Ziggo Sport", "espn": "ESPN", "mubi": "MUBI", "rtlxl": "RTL XL", "rtlplus": "RTL+", "kijk": "KIJK",
        "hulu": "Hulu", "peacock": "Peacock", "crunchyroll": "Crunchyroll", "starz": "Starz", "showtime": "Showtime",
        "nlziet": "NLZIET", "ketnet": "Ketnet", "nickelodeon": "Nickelodeon", "cartoonnetwork": "Cartoon Network",
    ]

    // MARK: openbaar

    /// Opgeschoonde naam van een categorie (`title: true`: voorzichtig, voor titels; zie build 149)
    static func clean(_ raw: String, title: Bool = false) -> String {
        guard title else { return parse(raw).name }
        // build 153: ook bij titels eerst de stukken tussen pipes aan het begin of eind weg ("┃NL┃The Batman")
        let n = normalizeSeparators(raw)
        return legacyClean(pipeBlocks(n)?.rest ?? n, title: true)
    }

    /// Sleutel om categorieën samen te voegen: hoofdletterongevoelig, zonder leestekens ("Netflix" = "NETFLIX" = "netflix")
    static func mergeKey(_ cleaned: String) -> String {
        let k = ProviderMatch.key(cleaned)
        return k.isEmpty ? cleaned.lowercased() : k
    }

    /// Andere pipe-tekens ("¦", "│", "｜") als "|"; voor titels én categorieën
    static func normalizeSeparators(_ s: String) -> String {
        guard s.contains(where: { pipes.contains($0) || $0 == "\u{00A0}" }) else { return s }
        return String(s.map { pipes.contains($0) ? "|" : ($0 == "\u{00A0}" ? " " : $0) })
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Parsed] = [:]

    static func parse(_ raw: String) -> Parsed {
        lock.lock()
        if let hit = cache[raw] { lock.unlock(); return hit }
        lock.unlock()
        let r = compute(raw)
        lock.lock()
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[raw] = r
        lock.unlock()
        return r
    }

    /// Het eerste land/de eerste taal vooraan ("NL | Netflix" → "NL"), voor de snelknoppen
    static func prefixLabel(_ raw: String) -> String? { parse(raw).prefixLabels.first }

    // MARK: intern

    private static func hasContent(_ s: Substring) -> Bool { s.contains { $0.isLetter || $0.isNumber } }
    private static func onlyWords(_ tags: [Tag]) -> Bool { tags.allSatisfy { if case .word = $0 { return true }; return false } }

    /// Build 153: haalt aan het begin en eind herhaald een kort stuk (≤ 25 tekens) tussen twee pipes weg, wat er ook
    /// tussen staat, ook zonder spaties: "|NL|NPO 1", "| MULTI / LINGO | Netflix", "|NL| |HD| RTL 4", "RTL 4 |NL|".
    /// Verwacht een tekst waarin de pipes al "|" zijn (`normalizeSeparators`). Geeft nil als er niets weg is of als er
    /// daarna niets overblijft (dan geldt de oude opschoning). `blocks`: de weggehaalde stukken, `leading`: hoeveel vooraan.
    static func pipeBlocks(_ text: String) -> (rest: String, blocks: [String], leading: Int)? {
        guard text.contains("|") else { return nil }
        var s = Substring(text)
        func trim() {
            s = s.drop(while: { $0.isWhitespace })
            while let l = s.last, l.isWhitespace { s = s.dropLast() }
        }
        trim()
        var blocks: [String] = []
        for _ in 0..<12 {
            guard s.first == "|", let end = s.dropFirst().firstIndex(of: "|") else { break }
            let inner = s[s.index(after: s.startIndex)..<end]
            guard inner.count <= 25 else { break }
            blocks.append(String(inner))
            s = s[s.index(after: end)...]
            trim()
        }
        let leading = blocks.count
        for _ in 0..<12 {
            guard s.count >= 2, s.last == "|" else { break }
            let body = s.dropLast()
            guard let start = body.lastIndex(of: "|") else { break }
            let inner = body[body.index(after: start)...]
            guard inner.count <= 25 else { break }
            blocks.append(String(inner))
            s = s[..<start]
            trim()
        }
        guard !blocks.isEmpty, hasContent(s) else { return nil }
        return (String(s), blocks, leading)
    }

    private static func classify(_ raw: Substring, mode: Mode, prefix: Bool) -> Tag? {
        let w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".!?'\"").union(.whitespaces))
        guard !w.isEmpty, w.count <= 16 else { return nil }
        let l = w.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let upper = w == w.uppercased()
        if quality.contains(l) { return .quality }
        if let m = multi[l] {
            // zonder scheidingsteken alleen in hoofdletters ("Kids MULTI", niet "Sub Zero")
            if mode == .spaced && !upper { return nil }
            if mode == .spaced && (l == "audio" || l == "lang" || l == "dual") { return nil }
            return .label(m)
        }
        if mode != .spaced, prefix, prefixWords.contains(l) { return .word }
        if mode != .spaced, let n = names[l] { return .label(n) }
        guard (2...4).contains(w.count), w.allSatisfy({ $0.isASCII && $0.isLetter }), codes.contains(l) else { return nil }
        switch mode {
        case .bracket: break
        case .separated: guard upper else { return nil }
        case .spaced: guard upper, (prefix ? spacedPrefix : spacedSuffix).contains(l) else { return nil }
        }
        return .label(codeLabel[l] ?? w.uppercased())
    }

    /// Een groepje labels: "NL", "MULTI LANG", "FHD/HD", "NL-EN", "MULTI-LINGO"
    private static func phrase(_ s: Substring, mode: Mode, prefix: Bool) -> [Tag]? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" || $0 == "+" || $0 == "," || $0 == "&" || $0 == "|" })
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Tag] = []
        for p in parts {
            guard let t = classify(p, mode: mode, prefix: prefix) else { return nil }
            out.append(t)
        }
        return out
    }

    private static func compute(_ raw: String) -> Parsed {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = Substring(normalizeSeparators(original))
        var labels: [String] = [], prefixLabels: [String] = []
        func take(_ tags: [Tag], prefix: Bool) {
            for t in tags {
                guard case .label(let l) = t else { continue }
                if !labels.contains(l) { labels.append(l) }
                if prefix, !prefixLabels.contains(l) { prefixLabels.append(l) }
            }
        }

        // 0. build 153: stukken tussen pipes aan het begin of eind ("┃NL┃", "| MULTI / LINGO |", "|NL| |HD|") weg,
        //    wat er ook tussen staat; herkende talen worden labels. Blijft er niets over, dan de oude opschoning.
        if let p = pipeBlocks(String(s)) {
            for (i, b) in p.blocks.enumerated() {
                if let tags = phrase(Substring(b), mode: .bracket, prefix: i < p.leading) { take(tags, prefix: i < p.leading) }
            }
            s = Substring(p.rest)
        }

        // 1. vooraan, zo vaak als nodig: "| NL | ", "| MULTI / LINGO | ", "[EN] ", "4K | UHD | ", "TR - ", "NL "
        for _ in 0..<10 {
            s = s.drop { $0.isWhitespace || separators.contains($0) }
            guard let first = s.first else { break }
            if let close = closer[first] {
                guard let end = s.dropFirst().firstIndex(of: close) else { break }
                let inner = s[s.index(after: s.startIndex)..<end]
                let rest = s[s.index(after: end)...]
                if inner.count <= 30, hasContent(rest), let tags = phrase(inner, mode: .bracket, prefix: true) {
                    take(tags, prefix: true); s = rest; continue
                }
                break
            }
            if let sep = s.firstIndex(where: { separators.contains($0) }) {
                let head = s[..<sep]
                let rest = s[s.index(after: sep)...]
                if hasContent(head), hasContent(rest), let tags = phrase(head, mode: .separated, prefix: true),
                   !onlyWords(tags) || rest.contains(where: \.isLetter) {   // build 153: "Film | 2024" blijft
                    take(tags, prefix: true); s = rest; continue
                }
            }
            if let sp = s.firstIndex(of: " ") {
                let head = s[..<sp], rest = s[s.index(after: sp)...]
                if hasContent(rest), let t = classify(head, mode: .spaced, prefix: true), case .label = t {
                    take([t], prefix: true); s = rest; continue
                }
            }
            break
        }

        // 2. achteraan: " (NL)", " [HD]", " - NL", " | MULTI", " 4K", " NL"
        for _ in 0..<10 {
            while let last = s.last, last.isWhitespace || separators.contains(last) { s = s.dropLast() }
            guard let last = s.last else { break }
            if let open = opener[last] {
                let body = s.dropLast()
                guard let start = body.lastIndex(of: open) else { break }
                let inner = body[body.index(after: start)...]
                let head = s[..<start]
                if inner.count <= 30, hasContent(head), let tags = phrase(inner, mode: .bracket, prefix: false) {
                    take(tags, prefix: false); s = head; continue
                }
                break
            }
            if let sep = s.lastIndex(where: { separators.contains($0) }) {
                let tail = s[s.index(after: sep)...]
                let head = s[..<sep]
                // "-" en "/" alleen met een spatie ervoor ("Netflix - NL"), niet in "SCI-FI" of "AC/DC"
                let spaced = sep > s.startIndex && s[s.index(before: sep)].isWhitespace
                let soft: Set<Character> = ["-", "–", "/", "_"]
                if hasContent(tail), hasContent(head), spaced || !soft.contains(s[sep]),
                   let tags = phrase(tail, mode: .separated, prefix: false) {
                    take(tags, prefix: false); s = head; continue
                }
            }
            if let sp = s.lastIndex(of: " ") {
                let tail = s[s.index(after: sp)...], head = s[..<sp]
                if hasContent(head), let t = classify(tail, mode: .spaced, prefix: false) {
                    take([t], prefix: false); s = head; continue
                }
            }
            break
        }

        var name = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !hasContent(Substring(name)) {
            // alleen labels ("NL", "4K", "| NL |"): de naam zelf, zonder losse leestekens
            var t = Substring(normalizeSeparators(original))
            t = t.drop { $0.isWhitespace || separators.contains($0) }
            while let last = t.last, last.isWhitespace || separators.contains(last) { t = t.dropLast() }
            name = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            labels = []; prefixLabels = []
            if name.isEmpty { name = original }
        }
        return Parsed(name: pretty(name), labels: labels, prefixLabels: prefixLabels)
    }

    /// "NETFLIX" → "Netflix", "BIOSCOOP" → "Bioscoop", "HBO MAX" → "HBO Max", "VTM GO" blijft; gemengde namen blijven zoals ze zijn.
    static func pretty(_ s: String) -> String {
        if let b = brands[ProviderMatch.key(s)] { return b }
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty, !letters.contains(where: \.isLowercase) else { return s }
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        // één kort woord ("NL", "4K", "BBC", "XXX") blijft staan
        if words.count == 1 && letters.count <= 3 { return s }
        return words.map(prettyWord).joined(separator: " ")
    }

    private static func prettyWord(_ w: Substring) -> String {
        if w.contains(where: \.isNumber) { return String(w) }
        let bare = String(w).trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+")).inverted).uppercased()
        if acronyms.contains(bare) { return String(w) }
        if let b = brands[ProviderMatch.key(String(w))], ProviderMatch.key(String(w)).count >= 3 {
            return String(w).replacingOccurrences(of: bare, with: b, options: .caseInsensitive)
        }
        var out = ""
        var start = true
        for ch in w {
            if ch.isLetter {
                out += start ? String(ch).uppercased() : String(ch).lowercased()
                start = false
            } else {
                out.append(ch)
                start = ch == "-" || ch == "/" || ch == "(" || ch == "." || ch == "&" || ch == "["
            }
        }
        // Nederlands: "IJSLAND" → "IJsland"
        if out.hasPrefix("Ij") { out = "IJ" + out.dropFirst(2) }
        return out
    }
}

// MARK: - Build 153: zendernamen

/// Build 153 (melding Léon: "overal zie ik nog ┃NL┃"): zendernamen werden nergens opgeschoond, alleen categorieën en
/// titels. `PlaylistService.apply` zet nu voor elke zender de opgeschoonde naam (Live TV, de rij Zenders, de tv-gids,
/// nu afspelen, favorieten, zoeken); id's, streams en EPG-koppeling blijven ongewijzigd.
/// Regels: stukken tussen pipes aan het begin of eind weg (wat er ook tussen staat), een voorvoegsel tot de eerste pipe
/// of een achtervoegsel na de laatste pipe weg als het een taal-/landcode, kwaliteit of bekend woord is, en nette
/// hoofdletters. Bewust niet: kwaliteit zonder pipe ("NPO 1 HD" en "NPO 1 SD" blijven twee verschillende zenders).
extension CategoryName {
    private static let channelLock = NSLock()
    nonisolated(unsafe) private static var channelCache: [String: String] = [:]

    /// Build 153: elke andere naam van de server voor in beeld (EPG-programma's, geschiedenis, speler, meldingen,
    /// downloads): dezelfde regels als bij zenders. Alleen voor weergave; sleutels en id's blijven de ruwe naam.
    static func display(_ raw: String) -> String { channel(raw) }

    static func channel(_ raw: String) -> String {
        channelLock.lock()
        if let hit = channelCache[raw] { channelLock.unlock(); return hit }
        channelLock.unlock()
        let r = computeChannel(raw)
        channelLock.lock()
        if channelCache.count > 50_000 { channelCache.removeAll(keepingCapacity: true) }
        channelCache[raw] = r
        channelLock.unlock()
        return r
    }

    private static func computeChannel(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = normalizeSeparators(original)
        guard norm.contains("|") else { return original.isEmpty ? raw : original }
        var s = Substring(pipeBlocks(norm)?.rest ?? norm)
        func trim() {
            s = s.drop(while: { $0.isWhitespace || $0 == "|" })
            while let l = s.last, l.isWhitespace || l == "|" { s = s.dropLast() }
        }
        trim()
        // voorvoegsel tot de eerste pipe: "NL| Netflix", "NL ┃ NPO 1", "4K | RTL 4"
        for _ in 0..<6 {
            guard let sep = s.firstIndex(of: "|") else { break }
            let head = s[..<sep], rest = s[s.index(after: sep)...]
            guard hasContent(head), hasContent(rest), let tags = phrase(head, mode: .separated, prefix: true),
                  !onlyWords(tags) || rest.contains(where: \.isLetter) else { break }
            s = rest; trim()
        }
        // achtervoegsel na de laatste pipe: "Kids | NL", "RTL 4 | HD"
        for _ in 0..<6 {
            guard let sep = s.lastIndex(of: "|") else { break }
            let head = s[..<sep], tail = s[s.index(after: sep)...]
            guard hasContent(head), hasContent(tail), let tags = phrase(tail, mode: .separated, prefix: false),
                  !onlyWords(tags) else { break }
            s = head; trim()
        }
        var name = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !hasContent(Substring(name)) {
            // alleen pipes en labels ("|NL|"): de naam zelf zonder losse pipes, nooit leeg
            var t = Substring(norm)
            t = t.drop(while: { $0.isWhitespace || $0 == "|" })
            while let l = t.last, l.isWhitespace || l == "|" { t = t.dropLast() }
            name = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if name.isEmpty { return original.isEmpty ? raw : original }
        }
        return pretty(name)
    }
}

// MARK: - Samenvoegen en ontdubbelen

/// Build 150: categorieën met dezelfde opgeschoonde naam zijn één categorie; daarin dezelfde titel maar één keer.
enum CategoryMerge {
    /// Sleutel voor "zelfde titel": TMDB-id, anders IMDb-id, anders titel + jaar (zonder jaar: het eigen id, dus niet samen).
    static func titleKey(id: String, title: String, year: Int?, tmdb: Int?, imdb: String?) -> String {
        if let t = tmdb, t > 0 { return "t\(t)" }
        if let i = imdb, !i.isEmpty { return "i" + i.lowercased() }
        if let y = year, y > 0 {
            let k = ProviderMatch.key(title)
            if !k.isEmpty { return "n\(k)|\(y)" }
        }
        return "#" + id
    }

    /// Op volgorde, zonder dubbele sleutels. `better(nieuw, oud)`: de nieuwe bron heeft de voorkeur (bijv. de app-taal).
    static func unique<T>(_ items: [T], key: (T) -> String, better: ((T, T) -> Bool)? = nil) -> [T] {
        var seen: [String: Int] = [:]
        seen.reserveCapacity(items.count)
        var out: [T] = []
        out.reserveCapacity(items.count)
        for x in items {
            let k = key(x)
            if let i = seen[k] {
                if let better, better(x, out[i]) { out[i] = x }
                continue
            }
            seen[k] = out.count
            out.append(x)
        }
        return out
    }

    /// Weergavenaam (na opschonen) → de labels van alle bronnen ("NL", "Multi"); gevuld door `PlaylistService.apply`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var labelsByName: [String: [String]] = [:]

    static func note(display: String, raw: String) {
        let ls = CategoryName.parse(raw).labels
        guard !ls.isEmpty else { return }
        let k = CategoryName.mergeKey(display)
        lock.lock(); defer { lock.unlock() }
        var cur = labelsByName[k] ?? []
        for l in ls where !cur.contains(l) { cur.append(l) }
        if cur.count > 6 { cur = Array(cur.prefix(6)) }
        if labelsByName.count > 5_000 { labelsByName.removeAll(keepingCapacity: true) }
        labelsByName[k] = cur
    }

    /// Chips voor een (samengevoegde) categorie: "NL · Multi"; nil als er niets bekend is
    static func labels(_ display: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return labelsByName[CategoryName.mergeKey(display)] ?? []
    }
}
