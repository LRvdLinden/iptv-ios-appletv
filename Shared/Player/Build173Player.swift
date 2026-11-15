import Foundation

// Build 173 (versie 1.0.7): bediening in de speler (inspiratie: Netflix en NLZIET).
// Pure logica zonder UI, getest in tools/selftest/main.swift. Dezelfde regels staan in Build173PlayerLogic.kt (Android)
// en web/js/player173.js (webspeler).

enum Player173 {

    // MARK: 1. De belangrijkste knop van dat moment (tv: grootst, eerste focus)

    enum Primary: String, Equatable {
        case skipIntro, nextEpisode, startOver, goLive
    }

    /// Intro overslaan, anders Volgende aflevering, anders (live) Terug naar live (als je achterloopt) of Vanaf het begin.
    static func primary(inIntro: Bool, nextEpisode: Bool, isLive: Bool, canStartOver: Bool, behindLive: Double) -> Primary? {
        if inIntro { return .skipIntro }
        if nextEpisode { return .nextEpisode }
        guard isLive else { return nil }
        if behindLive > behindThreshold { return .goLive }
        if canStartOver { return .startOver }
        return nil
    }

    /// Vanaf hoeveel seconden achterstand "Terug naar live" telt
    static let behindThreshold: Double = 30

    // MARK: 2. Vanaf het begin / Terug naar live

    /// Knop "Vanaf het begin": terugkijken kan en het programma loopt al minstens een minuut (en je zit niet al aan het begin).
    static func canStartOver(hasCatchup: Bool, programStart: Date?, now: Date, behindLive: Double) -> Bool {
        guard hasCatchup, let s = programStart, s < now else { return false }
        let elapsed = now.timeIntervalSince(s)
        return elapsed >= 60 && behindLive < elapsed - 30
    }

    /// Vraag "Vanaf het begin" of "Live kijken" bij het openen: alleen met terugkijken, als het programma al minstens
    /// 2 minuten bezig is en nog minstens een minuut duurt. Zonder terugkijken: geen vraag, direct live.
    static func askStartOver(hasCatchup: Bool, programStart: Date?, programEnd: Date?, now: Date) -> Bool {
        guard hasCatchup, let s = programStart, let e = programEnd, s < e else { return false }
        return now.timeIntervalSince(s) >= 120 && e.timeIntervalSince(now) >= 60
    }

    // MARK: 3. Zappen als lijst en Vorige zender

    /// Volgorde van de zaplijst (indexen in `groups`): eerst favorieten, dan de huidige categorie, dan de rest; binnen
    /// elk deel de volgorde van de server. (Verborgen zenders en het kinderprofiel zitten al niet in de lijst.)
    static func zapOrder(groups: [String], favorite: [Bool], currentGroup: String?) -> [Int] {
        var fav: [Int] = [], same: [Int] = [], rest: [Int] = []
        for i in groups.indices {
            if i < favorite.count && favorite[i] { fav.append(i) }
            else if let g = currentGroup, groups[i] == g { same.append(i) }
            else { rest.append(i) }
        }
        return fav + same + rest
    }

    /// Onthoudt de vorige zender: één tik terug, en nog een tik weer terug.
    struct PreviousChannel: Equatable {
        private(set) var current: String?
        private(set) var previous: String?

        init(current: String? = nil, previous: String? = nil) { self.current = current; self.previous = previous }

        mutating func tuned(_ id: String) {
            guard id != current else { return }
            previous = current
            current = id
        }
    }

    // MARK: 4. Dubbeltikken (telefoon/tablet)

    /// Dubbeltik links/rechts = 10 s; elke volgende tik binnen `window` aan dezelfde kant telt 10 s op (20, 30 …).
    struct DoubleTap: Equatable {
        static let step: Double = 10
        static let window: Double = 0.8
        private(set) var forward = true
        private(set) var total: Double = 0
        private(set) var lastAt: Double = -100

        init() {}

        /// Een dubbeltik (de eerste) of een losse tik erachteraan. Geeft de nieuwe totale sprong (met teken) en
        /// hoeveel er nu bij komt.
        @discardableResult
        mutating func tap(forward f: Bool, at t: Double) -> (total: Double, delta: Double) {
            if f == forward && total != 0 && t - lastAt <= Self.window {
                total += f ? Self.step : -Self.step
            } else {
                forward = f
                total = f ? Self.step : -Self.step
            }
            lastAt = t
            return (total, f ? Self.step : -Self.step)
        }

        /// Loopt er nog een reeks (dan telt een losse tik als extra 10 s)?
        func active(at t: Double) -> Bool { total != 0 && t - lastAt <= Self.window }

        mutating func reset() { total = 0; lastAt = -100 }
    }

    // MARK: 6. Eindtijd

    /// "Eindigt om …": nu + resterende tijd gedeeld door de afspeelsnelheid. Nil zonder bekende resterende tijd.
    static func endsAt(now: Date, remaining: Double, rate: Double) -> Date? {
        guard remaining > 0, remaining.isFinite else { return nil }
        let r = rate > 0 ? rate : 1
        return now.addingTimeInterval(remaining / r)
    }

    // MARK: 7. Ondertitels even aan na terugspoelen

    /// Kort terugspoelen (10–30 s) met ondertitels uit en een passend ondertitelspoor: tijdelijk aan.
    static func rewindSubtitles(jump: Double, subtitlesOn: Bool, hasTrack: Bool, enabled: Bool) -> Bool {
        enabled && !subtitlesOn && hasTrack && jump <= -10 && jump >= -30
    }

    /// Weer voorbij het punt waar je terugspoelde (of daar ver vandaan gesprongen): ondertitels weer uit.
    static func rewindSubtitlesDone(position: Double, until: Double, startedAt: Double) -> Bool {
        position >= until || position < startedAt - 5
    }

    /// Eerste ondertitelspoor in een van de gewenste talen (app-taal of gekozen taal). `tracks` = taalcodes of namen.
    static func subtitleTrack(_ tracks: [String], wanted: [String]) -> Int? {
        let want = wanted.map { $0.lowercased() }.filter { !$0.isEmpty }
        for w in want {
            let w2 = String(w.prefix(2))
            if let i = tracks.firstIndex(where: { t in
                let x = t.lowercased()
                return x == w || x.hasPrefix(w2 + "-") || x.hasPrefix(w2 + "_") || x == w2 || languageWords(w2).contains { x.contains($0) }
            }) { return i }
        }
        return nil
    }

    /// Namen van een taal zoals spoornamen ze vaak geven (VLC: "Nederlands", "Dutch", "nld")
    static func languageWords(_ code: String) -> [String] {
        switch code {
        case "nl": return ["dutch", "nederlands", "nld", "dut"]
        case "en": return ["english", "engels", "eng"]
        case "de": return ["german", "deutsch", "duits", "ger", "deu"]
        case "fr": return ["french", "français", "francais", "frans", "fre", "fra"]
        case "es": return ["spanish", "español", "espanol", "spaans", "spa"]
        case "it": return ["italian", "italiano", "italiaans", "ita"]
        case "pt": return ["portuguese", "português", "portugues", "por"]
        case "tr": return ["turkish", "türkçe", "turkce", "turks", "tur"]
        case "pl": return ["polish", "polski", "pools", "pol"]
        case "ar": return ["arabic", "العربية", "arabisch", "ara"]
        case "zh": return ["chinese", "中文", "chinees", "chi", "zho"]
        default: return []
        }
    }

    // MARK: 9. Slaaptimer

    enum Sleep: Equatable {
        case off, endOfEpisode, minutes(Int)

        static let choices: [Sleep] = [.endOfEpisode, .minutes(30), .minutes(60), .minutes(90), .off]

        /// Opslagvorm ("off", "episode", "m30")
        var code: String {
            switch self {
            case .off: return "off"
            case .endOfEpisode: return "episode"
            case .minutes(let m): return "m\(m)"
            }
        }
    }

    /// Moment waarop de slaaptimer afgaat (nil = uit of na deze aflevering)
    static func sleepDeadline(_ s: Sleep, now: Date) -> Date? {
        if case .minutes(let m) = s, m > 0 { return now.addingTimeInterval(Double(m) * 60) }
        return nil
    }

    /// Gaat de slaaptimer nu af? "Na deze aflevering" bij het einde van de titel (films en live: na het programma).
    static func sleepDue(_ s: Sleep, deadline: Date?, now: Date, titleEnded: Bool) -> Bool {
        switch s {
        case .off: return false
        case .endOfEpisode: return titleEnded
        case .minutes: return deadline.map { now >= $0 } ?? false
        }
    }

    /// Aftellen als "m:ss" of "u:mm:ss"
    static func countdown(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}
