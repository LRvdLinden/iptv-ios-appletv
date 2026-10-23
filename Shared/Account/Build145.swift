import Foundation

// Build 145: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).

// MARK: - Servers laden bij openen

/// Build 145: de gebruiker kiest zelf wanneer servers geladen worden. Automatisch verversen op tijd (elke dag, week …)
/// en het verversen na ±45 s zijn vervallen. Per apparaat (UserDefaults `playlist.startLoad`), niet gesynct: een tv en
/// een telefoon mogen verschillen.
///
/// Het enige automatische laden:
/// - de open server heeft nog geen bewaarde lijst (eerste keer, nieuwe server): meteen laden met de laadmelding, zonder
///   vraag (dat doet `PlaylistService.select`);
/// - de instelling is Altijd: alle servers van het account bijwerken, één voor één, de open server eerst.
///
/// Met Vragen verschijnt na de profielkeuze (en de juiste pincode) één keer per keer openen de vraag "Servers bijwerken?".
/// Niet bij een kinderprofiel (daar geldt Later, tenzij Altijd), niet opnieuw bij terugkeer uit de achtergrond.
enum StartLoad {
    static let key = "playlist.startLoad"
    /// Oude instelling (t/m build 144): de vernieuwtermijn (manual, launch, sixHours, daily, weekly)
    static let legacyKey = "playlist.refresh"
    static let migratedKey = "playlist.startLoad.migrated.v145"

    enum Mode: String, CaseIterable, Identifiable {
        case ask, always, never
        var id: String { rawValue }
    }

    enum Decision: Equatable {
        /// niets doen (Later, Nooit, kinderprofiel of al beslist deze sessie)
        case none
        /// de vraag tonen
        case ask
        /// meteen alle servers bijwerken, op de achtergrond
        case update
    }

    /// De instelling uit opgeslagen tekst; onbekend of leeg = Vragen (de standaard).
    static func mode(_ raw: String?) -> Mode { raw.flatMap(Mode.init(rawValue:)) ?? .ask }

    /// Eenmalige omzetting van de oude termijn: wat het ook was, het wordt Vragen. Een al gekozen nieuwe instelling
    /// blijft staan.
    static func migrated(legacy: String?, current: String?) -> Mode {
        if let current, let m = Mode(rawValue: current) { return m }
        return .ask
    }

    /// Wat er na het openen van een profiel (op het hoofdscherm, met de server open) gebeurt.
    /// - `hasCache`: de open server had een bewaarde lijst (anders is hij net met de laadmelding geladen)
    /// - `kids`: het actieve profiel is een kinderprofiel
    /// - `decided`: deze sessie is er al beslist (gevraagd of bijgewerkt)
    static func decide(mode: Mode, hasCache: Bool, kids: Bool, decided: Bool) -> Decision {
        if decided { return .none }
        switch mode {
        case .always: return .update
        case .never: return .none
        case .ask: return hasCache && !kids ? .ask : .none
        }
    }

    /// Telt dit openen als "deze sessie beslist"? Niet bij een kinderprofiel met Vragen of Nooit: kiest iemand daarna in
    /// dezelfde sessie een gewoon profiel, dan komt de vraag daar alsnog (één keer).
    static func consumes(mode: Mode, kids: Bool, decided: Bool) -> Bool {
        if decided { return true }
        return !(kids && mode != .always)
    }

    /// Bij Altijd zonder bewaarde lijst is de open server net geladen: die niet meteen nog een keer ophalen.
    /// `age` = leeftijd van de bewaarde lijst in seconden (nil = geen).
    static func skipJustLoaded(age: TimeInterval?, justLoaded: Bool) -> Bool {
        guard justLoaded, let age else { return false }
        return age < 5 * 60
    }
}
