import Foundation

// Build 174 (versie 1.0.7): detailpagina op de telefoon, trailers in de app en Bingr Radio (Live Activity, widget,
// CarPlay). Pure logica zonder UI, getest in tools/selftest/main.swift. Dezelfde regels staan in Build174Logic.kt
// (Android) en web/js/build174.js (webspeler).
//
// Let op: dit bestand gaat ook mee in de widget-extensie (BingrWidgets) en mag daarom alleen Foundation gebruiken.

// MARK: - 1. Detailpagina: knoppen onder Afspelen (telefoon)

enum Detail174 {
    enum Action: String, Equatable, CaseIterable {
        case myList, trailer, sources, watched, more
    }

    /// Smal scherm (telefoon): de vaste rij met tekst onder het icoon. Breed (iPad, Mac, tv): de brede rij blijft.
    static let compactMaxWidth: Double = 600

    static func isCompact(width: Double) -> Bool { width > 0 && width < compactMaxWidth }

    /// De rij op de telefoon: Mijn lijst · Trailer · Bronnen · Gezien · Meer. Wat niet van toepassing is valt weg en de
    /// rest schuift op. Bronnen = andere bronnen of een andere taalversie (alleen als er meer dan deze ene versie is).
    /// Gezien alleen voor films (een serie markeer je per aflevering of seizoen). Meer is er altijd.
    static func compactActions(hasListID: Bool, hasTrailer: Bool, otherSources: Int, languageVersions: Int,
                               isMovie: Bool) -> [Action] {
        var out: [Action] = []
        if hasListID { out.append(.myList) }
        if hasTrailer { out.append(.trailer) }
        if otherSources + languageVersions > 0 { out.append(.sources) }
        if isMovie { out.append(.watched) }
        out.append(.more)
        return out
    }

    /// Wat er onder Bronnen staat: één soort → meteen dat blad, twee soorten → een keuzemenu.
    enum SourcesTarget: Equatable { case none, otherSources, languages, choose }

    static func sourcesTarget(otherSources: Int, languageVersions: Int) -> SourcesTarget {
        switch (otherSources > 0, languageVersions > 0) {
        case (true, true): return .choose
        case (true, false): return .otherSources
        case (false, true): return .languages
        default: return .none
        }
    }

    /// Metaregel: "Taal: …" op een eigen regel als hij samen met de rest niet op één regel past.
    /// `parts` = geschatte breedtes van de onderdelen (punten), `spacing` tussen de onderdelen.
    static func languageOnOwnLine(parts: [Double], language: Double, spacing: Double, available: Double) -> Bool {
        guard language > 0 else { return false }
        let row = parts.reduce(0, +) + spacing * Double(parts.count)
        return row + language > available
    }
}

// MARK: - 2. Trailers: de beste uit alle bronnen

enum Trailer174 {
    enum Source: Int, Equatable { case tmdb = 0, server = 1, trakt = 2 }

    struct Candidate: Equatable {
        var key: String
        var source: Source
        /// "Trailer", "Teaser", … (TMDB); nil = onbekend (server, Trakt)
        var type: String?
        /// ISO 639-1; nil = onbekend of zonder taal
        var language: String?
        /// TMDB: officieel van de studio
        var official: Bool?
        var site: String = "YouTube"

        init(key: String, source: Source, type: String? = nil, language: String? = nil, official: Bool? = nil,
             site: String = "YouTube") {
            self.key = key; self.source = source; self.type = type; self.language = language
            self.official = official; self.site = site
        }
    }

    /// Alleen een echte YouTube-id (11 tekens A-Z, a-z, 0-9, - en _)
    static func isValidID(_ s: String) -> Bool {
        s.utf8.count == 11 && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    /// Volgorde: soort (Trailer, dan onbekend (server/Trakt), dan Teaser), taal (app-taal, Engels, zonder taal, rest),
    /// officieel eerst, bron (TMDB, server, Trakt). Andere video's (clips, featurettes) en niet-YouTube vallen weg.
    static func rank(_ c: Candidate, appLanguage: String) -> [Int] {
        let base = String(appLanguage.lowercased().prefix(2))
        let typeRank: Int
        switch c.type?.lowercased() {
        case "trailer": typeRank = 0
        case nil: typeRank = 1
        case "teaser": typeRank = 2
        default: typeRank = 9
        }
        let lang = c.language?.lowercased()
        let langRank: Int
        if lang == nil { langRank = c.source == .tmdb ? 2 : 1 }
        else if lang == base { langRank = 0 }
        else if lang == "en" { langRank = base == "en" ? 0 : 1 }
        else { langRank = 3 }
        let officialRank = c.official == false ? 1 : 0
        return [typeRank, langRank, officialRank, c.source.rawValue]
    }

    static func best(_ candidates: [Candidate], appLanguage: String) -> String? {
        let ok = candidates.filter { $0.site.lowercased() == "youtube" && isValidID($0.key) }
            .filter { rank($0, appLanguage: appLanguage)[0] < 9 }
        return ok.enumerated().min { a, b in
            let ra = rank(a.element, appLanguage: appLanguage), rb = rank(b.element, appLanguage: appLanguage)
            return ra == rb ? a.offset < b.offset : ra.lexicographicallyPrecedes(rb)
        }?.element.key
    }

    /// Hoe de trailer opent
    enum Opening: Equatable { case inApp, youtubeApp, browser, notInstalled }

    /// iOS/macOS/Android/web: in de app (YouTube-embed). Apple TV: geen WebKit en zelf de stream ophalen mag niet →
    /// de YouTube-app; is die er niet, dan een melding met de App Store-link. Android zonder WebView: YouTube-app, anders
    /// de browser.
    static func opening(canEmbed: Bool, hasYouTubeApp: Bool, hasBrowser: Bool) -> Opening {
        if canEmbed { return .inApp }
        if hasYouTubeApp { return .youtubeApp }
        return hasBrowser ? .browser : .notInstalled
    }

    /// App Store-pagina van de YouTube-app (Apple TV-melding)
    static let youtubeAppStoreURL = "https://apps.apple.com/app/youtube/id544007664"
}

// MARK: - 3. Bingr Radio: Live Activity, widget en CarPlay

enum Radio174 {
    /// Zender zoals de widget, de Live Activity en CarPlay hem kennen (gedeeld via de App Group)
    struct Station: Codable, Equatable {
        var id: String
        var name: String
        /// Bestandsnaam van het logo in de App Group (`radio/<bestand>`), nil = geen logo
        var logo: String?
        var favorite: Bool
        var group: String

        init(id: String, name: String, logo: String? = nil, favorite: Bool = false, group: String = "") {
            self.id = id; self.name = name; self.logo = logo; self.favorite = favorite; self.group = group
        }
    }

    /// Wat de app in de App Group zet voor de widget
    struct Snapshot: Codable, Equatable {
        var stations: [Station]
        /// Zender die nu speelt (of gepauzeerd is)
        var currentID: String?
        var isPlaying: Bool
        var nowPlaying: String?
        var updated: Date
        /// Teksten in de app-taal voor de widget (die heeft zelf geen vertalingen)
        var texts: [String: String]?

        init(stations: [Station], currentID: String? = nil, isPlaying: Bool = false, nowPlaying: String? = nil,
             updated: Date = Date(), texts: [String: String]? = nil) {
            self.stations = stations; self.currentID = currentID; self.isPlaying = isPlaying
            self.nowPlaying = nowPlaying; self.updated = updated; self.texts = texts
        }

        /// Zonder tijdstip (om te zien of er echt iets veranderd is)
        var withoutDate: Snapshot { var c = self; c.updated = .distantPast; return c }

        func text(_ key: String, _ fallback: String) -> String { texts?[key] ?? fallback }

        func encoded() -> Data? {
            let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
            return try? e.encode(self)
        }

        static func decode(_ data: Data?) -> Snapshot? {
            guard let data else { return nil }
            let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
            return try? d.decode(Snapshot.self, from: data)
        }
    }

    static let appGroup = "group.nl.lrvdlinden.bingr"
    static let snapshotFile = "radio/stations.json"
    static let widgetKind = "BingrRadio"
    /// Instelling: Live Activity bij radio (standaard aan)
    static let liveActivityKey = "radio.liveActivity"
    /// Zender die de widget wil starten terwijl de app nog laadt (wordt gestart zodra de bibliotheek er is)
    static let pendingKey = "radio.pendingStation"
    /// Max. zenders in de snapshot (genoeg voor de widget en CarPlay-lijsten; houdt het bestand klein)
    static let maxStations = 300

    /// Knoppen in de widget: favorieten eerst (in hun volgorde), aangevuld met de eerste zenders; de zender die nu
    /// speelt niet dubbel als hij al bovenaan staat.
    static func widgetStations(_ s: [Station], max: Int) -> [Station] {
        guard max > 0 else { return [] }
        let fav = s.filter(\.favorite)
        let rest = s.filter { !$0.favorite }
        return Array((fav + rest).prefix(max))
    }

    /// De zender die de kleine widget toont: die nu speelt, anders de eerste favoriet, anders de eerste zender.
    static func featured(_ snap: Snapshot) -> Station? {
        if let id = snap.currentID, let c = snap.stations.first(where: { $0.id == id }) { return c }
        return snap.stations.first(where: \.favorite) ?? snap.stations.first
    }

    /// Volgende/vorige zender (rondgaand). nil bij een lege lijst.
    static func step(_ ids: [String], current: String?, by d: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let i = current.flatMap { ids.firstIndex(of: $0) } ?? -1
        if i < 0 { return d >= 0 ? ids[0] : ids[ids.count - 1] }
        let n = ids.count
        return ids[((i + d) % n + n) % n]
    }

    /// ICY-metadata ("StreamTitle='Artiest - Titel';" of alleen de titel) → nette tekst. Lege titels, alleen streepjes,
    /// de zendernaam zelf en reclame-/jinglemarkeringen tellen niet.
    static func cleanStreamTitle(_ raw: String?, station: String? = nil) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let r = s.range(of: "StreamTitle='") {
            s = String(s[r.upperBound...])
            if let end = s.range(of: "';") ?? s.range(of: "'") { s = String(s[..<end.lowerBound]) }
        }
        s = s.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        if s.hasSuffix(" -") { s = String(s.dropLast(2)) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let lower = s.lowercased()
        if let st = station?.lowercased().trimmingCharacters(in: .whitespaces), !st.isEmpty, lower == st { return nil }
        let junk = ["unknown", "advert", "advertisement", "commercial", "reclame", "jingle", "spot", "unknown - unknown",
                    "n/a", "-", "untitled"]
        if junk.contains(lower) || lower.hasPrefix("adbreak") || lower.hasPrefix("ad break") { return nil }
        return String(s.prefix(120))
    }

    /// Wat er nu speelt: de stream (ICY) gaat voor de EPG, die gaat voor niets.
    static func nowPlaying(icy: String?, epg: String?, station: String?) -> String? {
        cleanStreamTitle(icy, station: station) ?? cleanStreamTitle(epg, station: station)
    }

    enum ActivityStep: Equatable { case none, start, update, end }

    /// Live Activity: starten bij radio afspelen (als de instelling aan staat en het mag), bijwerken bij een andere
    /// zender of een andere stand, beëindigen bij stoppen (ook na de slaaptimer) of als de instelling uit gaat.
    static func activityStep(enabled: Bool, allowed: Bool, playingStation: String?, running: Bool,
                             changed: Bool) -> ActivityStep {
        let want = enabled && allowed && playingStation != nil
        switch (want, running) {
        case (true, false): return .start
        case (true, true): return changed ? .update : .none
        case (false, true): return .end
        default: return .none
        }
    }

    /// Bestandsnaam voor een logo in de App Group (stabiel per adres, alleen veilige tekens)
    static func logoFileName(_ url: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "logo-%016llx.png", h)
    }

    /// CarPlay-tabbladen: Favorieten (als er favorieten zijn), Alle zenders, en per categorie (alleen als er meer dan
    /// één categorie is; max. `maxGroups`, de grootste eerst, verder op naam).
    static func carPlayGroups(_ s: [Station], maxGroups: Int) -> [(name: String, ids: [String])] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for st in s {
            let g = st.group.trimmingCharacters(in: .whitespaces)
            guard !g.isEmpty else { continue }
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(st.id)
        }
        guard order.count > 1 else { return [] }
        let sorted = order.sorted { a, b in
            let ca = map[a]!.count, cb = map[b]!.count
            return ca == cb ? a.localizedCaseInsensitiveCompare(b) == .orderedAscending : ca > cb
        }
        return sorted.prefix(max(0, maxGroups)).map { ($0, map[$0]!) }
    }
}
