import Foundation

// Build 160: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
//
// Beoordelingsprompt (StoreKit `requestReview`) op iPhone, iPad en Mac; Apple TV heeft geen beoordelingsvenster.
// - De eerste keer pas 4 uur na het eerste gebruik op dit apparaat (lokaal bewaard, gaat niet mee met het account).
// - Daarna hooguit één keer per 7 dagen (Apple begrenst het zelf ook: 3 keer per 365 dagen).
// - Alleen op een rustig moment: een paar seconden na het openen of na terugkeer naar de voorgrond, op Home, met minstens
//   één server of afspeellijst, en nooit bij een kinderprofiel, tijdens het afspelen (ook beeld-in-beeld), op de intro,
//   het inlogscherm, "Wie kijkt er?" (pincode, ouderpoort), het toevoegen van een server, of met een melding of blad open.
// De app (`ReviewPromptHost` in Shared/App/ReviewPrompt.swift) verzamelt de toestand; hier staat alleen de beslisregel.

/// De toestand van de app op het moment van de vraag. Standaard = alles rustig (behalve: nog geen server).
struct ReviewConditions160: Equatable {
    /// SmokeMode of ScreenshotMode (CI, App Store-screenshots): nooit vragen
    var specialMode = false
    /// App op de voorgrond (scenePhase .active)
    var appActive = true
    /// Hoofdscherm (niet intro, inlogscherm, "Wie kijkt er?"/pincode/ouderpoort, te veel apparaten)
    var inMain = true
    /// Tabblad Home geselecteerd
    var onHome = true
    /// Een profiel met pincode is (nog) niet ontgrendeld
    var locked = false
    /// Er speelt iets: speler of multiview open
    var playing = false
    /// Beeld-in-beeld loopt
    var pip = false
    /// Actief profiel is een kinderprofiel
    var kidsProfile = false
    /// Aantal servers/afspeellijsten op dit apparaat
    var serverCount = 0
    /// Een blad, volledig scherm, melding, foutmelding, vraag of ouderpoort staat open (of de lijst wordt geladen)
    var presenting = false

    /// Elke toestand die de vraag tegenhoudt (leeg = rustig moment)
    var blockers: [String] {
        var b: [String] = []
        if specialMode { b.append("specialMode") }
        if !appActive { b.append("inactive") }
        if !inMain { b.append("notMain") }
        if !onHome { b.append("notHome") }
        if locked { b.append("locked") }
        if playing { b.append("playing") }
        if pip { b.append("pip") }
        if kidsProfile { b.append("kids") }
        if serverCount < 1 { b.append("noServer") }
        if presenting { b.append("presenting") }
        return b
    }
}

enum ReviewPolicy160 {
    /// Eerste keer: 4 uur na het eerste gebruik op dit apparaat
    static let firstDelay: TimeInterval = 4 * 3600
    /// Daarna: hooguit eens per 7 dagen
    static let interval: TimeInterval = 7 * 24 * 3600
    /// Zoveel seconden na het openen of terugkeer naar de voorgrond (op Home) pas kijken
    static let settleSeconds: Double = 5

    /// De beslisregel. `firstUse` nil = nog niet bewaard (dan nu niet vragen).
    static func shouldAsk(now: Date, firstUse: Date?, lastAsked: Date?, conditions: ReviewConditions160) -> Bool {
        guard conditions.blockers.isEmpty, let firstUse else { return false }
        guard now.timeIntervalSince(firstUse) >= firstDelay else { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < interval { return false }
        return true
    }

    /// Tijdstippen in de toekomst (klok van het apparaat teruggezet) gelden als "nu", zodat de vraag niet voor altijd
    /// wegblijft. Geeft de gecorrigeerde waarden (en of er iets veranderd is, om te bewaren).
    static func normalize(now: Date, firstUse: Date?, lastAsked: Date?) -> (firstUse: Date?, lastAsked: Date?, changed: Bool) {
        var f = firstUse, l = lastAsked, changed = false
        if let x = f, x > now { f = now; changed = true }
        if let x = l, x > now { l = now; changed = true }
        return (f, l, changed)
    }
}

/// Opslag van de twee tijdstippen: kleine sleutels in UserDefaults, alleen op dit apparaat (niet in StateSync, niet in
/// het account, niet in iCloud).
struct ReviewStore160 {
    static let firstUseKey = "review.firstUse.v1"
    static let lastAskedKey = "review.lastAsked.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var firstUse: Date? { date(Self.firstUseKey) }
    var lastAsked: Date? { date(Self.lastAskedKey) }

    /// Eerste gebruik op dit apparaat vastleggen (alleen als het er nog niet is). Geeft het bewaarde tijdstip.
    @discardableResult
    func recordFirstUseIfNeeded(now: Date = Date()) -> Date {
        if let f = firstUse { return f }
        defaults.set(now.timeIntervalSince1970, forKey: Self.firstUseKey)
        return now
    }

    func markAsked(now: Date = Date()) { defaults.set(now.timeIntervalSince1970, forKey: Self.lastAskedKey) }

    /// Tijdstippen in de toekomst terugzetten naar nu (zie `ReviewPolicy160.normalize`)
    func normalize(now: Date = Date()) {
        let n = ReviewPolicy160.normalize(now: now, firstUse: firstUse, lastAsked: lastAsked)
        guard n.changed else { return }
        if let f = n.firstUse { defaults.set(f.timeIntervalSince1970, forKey: Self.firstUseKey) }
        if let l = n.lastAsked { defaults.set(l.timeIntervalSince1970, forKey: Self.lastAskedKey) }
    }

    /// Nu vragen? (met de bewaarde tijdstippen)
    func shouldAsk(now: Date = Date(), conditions: ReviewConditions160) -> Bool {
        ReviewPolicy160.shouldAsk(now: now, firstUse: firstUse, lastAsked: lastAsked, conditions: conditions)
    }

    private func date(_ key: String) -> Date? {
        guard let t = defaults.object(forKey: key) as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}
