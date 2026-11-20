import Foundation

// Build 179 (versie 1.0.8), X2: "stream stopt vaak na ±27 seconden of ±1 minuut". Pure logica zonder UI, getest in
// tools/selftest/main.swift:
// - herverbinden bij live: meer dan één poging, met oplopende wachttijd (een door de server gesloten stream hoort
//   vanzelf weer te gaan spelen)
// - respijt na (her)laden: de oude status van de speler ("afgelopen", "fout") telt niet als nieuwe storing
// - één verbinding tegelijk: pas openen als het voorbeeld echt dicht is
// - het voorbeeld: kale MPEG-TS meteen met VLC (geen extra verbinding via de Apple-speler)
// - reden van de laatste stop, voor Diagnose

enum Stream179 {
    // MARK: herverbinden

    /// Wachttijden bij live nadat er al beeld was: snel beginnen (de server sloot de verbinding, de stream zelf is er nog)
    /// en daarna rustiger (een aanbieder telt een net gesloten verbinding soms nog even mee)
    static let liveDelays: [Double] = [0.5, 1.5, 3, 5, 8]
    /// Live zonder dat er ooit beeld was: twee pogingen, daarna de back-upbron of de foutmelding (niet eindeloos wachten)
    static let coldDelays: [Double] = [1.5, 3]
    /// Films en series: één stille poging (zoals sinds build 52)
    static let vodDelays: [Double] = [1.5]

    /// Wachttijd vóór poging `attempt` (0 = de eerste); nil = opgeven (back-upbron of foutmelding).
    static func retryDelay(attempt: Int, live: Bool, hadPicture: Bool) -> Double? {
        let list = !live ? vodDelays : (hadPicture ? liveDelays : coldDelays)
        return attempt >= 0 && attempt < list.count ? list[attempt] : nil
    }

    /// Zo lang mag één storing (alle pogingen samen, vanaf de eerste) duren; daarna de back-upbron of de foutmelding
    static let outageMax: Double = 45

    /// Nog een poging? `outage` = seconden sinds de eerste poging van deze storing.
    static func retryDelay(attempt: Int, live: Bool, hadPicture: Bool, outage: Double) -> Double? {
        outage > outageMax ? nil : retryDelay(attempt: attempt, live: live, hadPicture: hadPicture)
    }

    /// Zo lang stabiel beeld (seconden) en de pogingen tellen weer vanaf nul
    static let stableSeconds: Double = 10

    // MARK: respijt na (her)laden

    /// Zo lang na het laden mag de speler nog de status van de vorige stream melden
    static let staleGrace: Double = 4

    /// "Afgelopen" of "fout" vlak na het laden, terwijl de speler die status sinds het laden nog niet verlaten heeft:
    /// dat is de vorige stream (VLC meldt zijn nieuwe status later, zeker als het laden buiten de hoofdthread gebeurt).
    static func terminalIsStale(sinceLoad: Double, leftTerminal: Bool) -> Bool {
        !leftTerminal && sinceLoad >= 0 && sinceLoad < staleGrace
    }

    // MARK: één verbinding tegelijk

    /// Hoogstens zo lang wachten tot het voorbeeld dicht is (daarna toch starten: liever beeld dan blijven wachten)
    static let settleMax: Double = 2.5

    /// Mag de speler zijn verbinding nu openen? Niet zolang er nog een voorbeeld aan het sluiten is.
    static func mayOpen(closing: Int, waited: Double) -> Bool { closing <= 0 || waited >= settleMax }

    // MARK: voorbeeld

    /// Bestandsvormen die de Apple-speler niet via http kan afspelen: het voorbeeld opent die meteen met VLC, in
    /// plaats van eerst een (mislukkende) verbinding met de Apple-speler te maken
    static let vlcOnly: Set<String> = ["ts", "mpegts", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "webm"]

    /// Begint het voorbeeld met de Apple-speler? Alleen http(s), en niet bij een vorm die alleen VLC kan.
    static func previewApple(scheme: String?, pathExtension: String) -> Bool {
        guard let s = scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return !vlcOnly.contains(pathExtension.lowercased())
    }

    // MARK: reden van de laatste stop

    enum Reason: String, Codable, CaseIterable {
        /// de server sloot de verbinding (live liep af)
        case serverClosed
        /// de speler meldde een fout
        case error
        /// 15 s geen beeld
        case timeout
        /// herverbinden lukte niet: back-upbron of foutmelding
        case gaveUp
        /// streamlimiet van het Bingr-account
        case limit
        /// pauze-opdracht van een afstandsbediening, de tv (HDMI-CEC) of het systeem
        case remotePause
    }

    struct Stop: Codable, Equatable {
        var when: Double
        var reason: Reason
        /// seconden beeld sinds het (her)laden
        var after: Double
        var engine: String
        var format: String
        var live: Bool
    }

    /// Waarom greep de speler in? nil = geen storing.
    static func reason(error: Bool, ended: Bool, live: Bool, stalledFor: Double) -> Reason? {
        if error { return .error }
        if ended && live { return .serverClosed }
        if live && stalledFor > 15 { return .timeout }
        return nil
    }

    /// Nieuwste eerst, hoogstens `keep`.
    static func push(_ list: inout [Stop], _ s: Stop, keep: Int = 10) {
        list.insert(s, at: 0)
        if list.count > keep { list.removeLast(list.count - keep) }
    }
}
