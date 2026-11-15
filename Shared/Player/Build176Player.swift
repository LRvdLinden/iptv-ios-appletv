import Foundation

// Build 176 (versie 1.0.8): voorvertoning op een titel (punt 11), helderheid regelen met vegen in de speler (punt 12) en
// direct spoelen met de afstandsbediening van de Apple TV (punt 15). Pure logica zonder UI, getest in
// tools/selftest/main.swift. Het contract van de voorvertoning staat in docs/ACCOUNT.md ("Build 176", punt 7).

// MARK: - 11. Voorvertoning op een titel

enum Preview176 {
    /// Lokale instelling (per apparaat, geen sync), standaard aan
    static let enabledKey = "posterPreview"
    /// Zo lang focus (tv) of de aanwijzer (iPad, Mac) op een poster, of de hero in beeld (telefoon), vóór hij start
    static let delay: Double = 2.0
    /// Een kaart speelt hoogstens zo lang, daarna weer de poster (geen eindeloze data voor een poster die blijft staan)
    static let maxCardSeconds: Double = 45

    enum Device: Equatable { case phone, pad, mac, tv }
    enum Surface: Equatable { case card, hero }
    /// trailer = de trailer zonder geluid; motion = langzaam in- en verschuiven van de afbeelding (Apple TV heeft geen
    /// WebKit, en streams uit YouTube halen mag niet; zoals de kop van de detailpagina sinds build 85)
    enum Style: Equatable { case none, trailer, motion }

    /// Wat er speelt. Telefoon: alleen in de hero (lang tikken op een poster is niet nodig). iPad en Mac: kaart en hero
    /// (aanwijzer). Apple TV: de kaart met focus beweegt.
    static func style(device: Device, surface: Surface, hasTrailer: Bool) -> Style {
        switch (device, surface) {
        case (.tv, .card): return .motion
        case (.tv, .hero): return .none
        case (.phone, .card): return .none
        default: return hasTrailer ? .trailer : .none
        }
    }

    /// Mag er nu een voorvertoning spelen? Niet als de schakelaar uit staat, bij Data besparen op mobiel (`saver`), bij
    /// een vergrendelde titel, in een kinderprofiel bij een titel zonder toegestane leeftijd, met Bewegingen beperken,
    /// of als er iets speelt.
    static func allowed(enabled: Bool, saver: Bool, locked: Bool, kidsBlocked: Bool, reduceMotion: Bool,
                        playing: Bool) -> Bool {
        enabled && !saver && !locked && !kidsBlocked && !reduceMotion && !playing
    }

    /// Focus of aanwijzer: pas starten als hij `delay` blijft staan; weg = meteen stoppen. Een nieuwe kaart begint opnieuw.
    struct Hover: Equatable {
        private(set) var since: Double?
        private(set) var id: String?

        init() {}

        mutating func enter(_ id: String, at t: Double) {
            if self.id != id || since == nil { self.id = id; since = t }
        }

        mutating func leave(_ id: String) {
            if self.id == id { self.id = nil; since = nil }
        }

        func shouldStart(_ id: String, at t: Double) -> Bool {
            guard self.id == id, let since else { return false }
            return t - since >= Preview176.delay - 0.001
        }
    }
}

// MARK: - 12. Helderheid met vegen (iPhone en iPad)

enum Brightness176 {
    /// Verticaal vegen in de linkerhelft van het beeld = helderheid. Rechts blijft zoals het was (live: zappen); volume
    /// regelt iOS zelf met de knoppen (een eigen volumeregelaar via MPVolumeView kan niet netjes).
    static let zoneFraction = 0.5
    /// Pas na zoveel punten beweging beslissen wat het vegen is
    static let decideDistance = 12.0
    /// Over 80 % van de beeldhoogte vegen = van donker naar helemaal licht
    static let travel = 0.8

    enum Kind: Equatable { case brightness, other }

    static func inZone(x: Double, width: Double) -> Bool { width > 0 && x >= 0 && x < width * zoneFraction }

    /// Wat dit vegen is; nil = nog te weinig beweging om te beslissen.
    static func classify(startX: Double, width: Double, dx: Double, dy: Double) -> Kind? {
        guard max(abs(dx), abs(dy)) >= decideDistance else { return nil }
        return abs(dy) > abs(dx) * 1.2 && inZone(x: startX, width: width) ? .brightness : .other
    }

    /// Nieuwe helderheid: omhoog vegen (dy < 0) = lichter.
    static func value(start: Double, dy: Double, height: Double) -> Double {
        let h = max(height, 1) * travel
        return min(max(start - dy / h, 0), 1)
    }

    /// Niet als de bediening vergrendeld is, tijdens casten of bij beeld op een extern scherm.
    static func enabled(locked: Bool, casting: Bool, external: Bool) -> Bool { !locked && !casting && !external }

    static func percent(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 100).rounded()) }

    /// Onthoudt de helderheid van vóór het eerste vegen, zodat het sluiten van de speler hem terugzet.
    struct Session: Equatable {
        private(set) var original: Double?

        init() {}

        /// Begin van een veeg: de huidige helderheid is het startpunt; de eerste keer ook het origineel.
        mutating func begin(current: Double) -> Double {
            if original == nil { original = current }
            return current
        }

        /// Sluiten (of naar de achtergrond): de waarde om terug te zetten, daarna vergeten. nil = niets aangepast.
        mutating func end() -> Double? {
            defer { original = nil }
            return original
        }
    }
}

// MARK: - 15. Direct spoelen met de afstandsbediening (Apple TV)

enum Skip176 {
    static let step: Double = 10
    /// Snel achter elkaar klikken telt op vanaf het vorige doel (de speler meldt de nieuwe tijd pas later)
    static let chainWindow: Double = 1.2

    /// ←/→ op de tijdbalk: met een voorbeeldpositie (na swipen of ingedrukt houden) die verschuiven, anders direct
    /// spoelen zonder pauzeren (zoals de ±10-knoppen).
    enum Click: Equatable { case direct, scrubStep }

    static func click(scrubbing: Bool) -> Click { scrubbing ? .scrubStep : .direct }

    /// Spoelen kan bij films en afleveringen, en bij live met terugkijken (timeshift of een HLS-venster).
    static func canSkip(isLive: Bool, canTimeshift: Bool, duration: Double) -> Bool {
        isLive ? canTimeshift : duration > 0
    }

    /// Opeenvolgende sprongen (films en afleveringen): het doel en het totaal sinds de eerste klik ("+20 s").
    struct Chain: Equatable {
        private(set) var target: Double?
        private(set) var origin: Double = 0
        private(set) var at: Double?

        init() {}

        mutating func jump(forward: Bool, now: Double, current: Double, duration: Double) -> (target: Double, total: Double) {
            let chained = at.map { now - $0 <= Skip176.chainWindow } ?? false
            let base = chained ? (target ?? current) : current
            if !chained { origin = current }
            var t = base + (forward ? Skip176.step : -Skip176.step)
            if duration > 0 { t = min(t, max(duration - 1, 0)) }
            t = max(t, 0)
            target = t; at = now
            return (t, t - origin)
        }

        mutating func reset() { target = nil; at = nil; origin = 0 }
    }

    /// Tekst van de melding: "+10 s", "−20 s" (echt minteken)
    static func label(_ total: Double) -> String {
        let n = Int(abs(total).rounded())
        return (total < 0 ? "−" : "+") + "\(n) s"
    }
}
