import Foundation

// Build 170 (versie 1.0.6): doorspoelen op Apple TV soepeler, zoals de standaardspeler. Pure logica (alleen
// Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift). Gebruikt in
// Shared/Player/TVScrub.swift (de scrub-status van de tijdbalk) en Shared/Player/PlayerScreen.swift.
// Waarden van de swipe in breedtes van het venster (zoals in build 169): `fraction` = stukje, `velocity` = breedtes/s.

enum Scrub170 {
    // MARK: swipen

    /// Dode zone aan het begin van een aanraking (≈ 23 punten bij 1920): een tik of rustende duim verschuift niets.
    static let deadZone: Double = 0.012

    /// Wat er van een stukje pan overblijft na de dode zone. `moved` = wat er in deze aanraking al bewogen is
    /// (zonder teken, vóór dit stukje). Pas als het totaal voorbij de dode zone komt, telt het verschil mee.
    static func afterDeadZone(moved: Double, delta: Double) -> Double {
        guard delta.isFinite, moved.isFinite else { return 0 }
        let before = max(moved, 0), after = before + abs(delta)
        if after <= deadZone { return 0 }
        if before >= deadZone { return delta }
        return (delta < 0 ? -1 : 1) * (after - deadZone)
    }

    /// Niet-lineaire versnelling naar de snelheid van de swipe (breedtes/s, teken doet niet mee):
    /// heel rustig = 0,5× (fijn: ±1 s per 6 punten), daarna vloeiend naar 1× (±1 s per 3 punten bij een lange film),
    /// en boven 0,6 breedte/s steeds sneller (macht 1,5) tot hoogstens 6×.
    static let slowVelocity: Double = 0.25
    static let refVelocity: Double = 0.6
    static let fineGain: Double = 0.5
    static let maxGain: Double = 6

    static func gain(velocity: Double) -> Double {
        let v = abs(velocity.isFinite ? velocity : 0)
        if v <= slowVelocity { return fineGain }
        if v <= refVelocity {
            let x = (v - slowVelocity) / (refVelocity - slowVelocity)
            let s = x * x * (3 - 2 * x)            // smoothstep: geen knik in de overgang
            return fineGain + (1 - fineGain) * s
        }
        return min(1 + 3 * pow(v - refVelocity, 1.5), maxGain)
    }

    /// Van een stukje pan naar seconden: basis = Scrub169.fullWidthSeconds (10 min per breedte, of 20% van de duur),
    /// maal de niet-lineaire versnelling.
    static func panSeconds(fraction: Double, velocity: Double, duration: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return fraction * Scrub169.fullWidthSeconds(duration: duration) * gain(velocity: velocity)
    }

    // MARK: uitrollen (inertie)

    /// Pas vanaf deze loslaatsnelheid (breedtes/s) rolt de voorbeeldpositie door.
    static let coastThreshold: Double = 1.0
    /// Tijdconstante van het afremmen (s): de snelheid halveert ongeveer elke 0,24 s.
    static let coastTau: Double = 0.35
    /// Onder deze snelheid (s/s) stopt het uitrollen.
    static let coastStopSpeed: Double = 4

    /// Hoe ver uitrollen hoogstens mag gaan: 8% van de duur, tussen 30 s en 5 minuten.
    static func maxCoast(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 120 }
        return min(max(duration * 0.08, 30), 300)
    }

    /// Beginsnelheid van het uitrollen (seconden per seconde, met teken), of 0 als de veeg te rustig was.
    /// Begrensd zodat de totale afstand (v0 · tau) niet boven `maxCoast` komt.
    static func coastVelocity(release velocity: Double, duration: Double) -> Double {
        guard velocity.isFinite, abs(velocity) >= coastThreshold else { return 0 }
        let raw = velocity * Scrub169.fullWidthSeconds(duration: duration) * gain(velocity: velocity) * 0.5
        let cap = maxCoast(duration: duration) / coastTau
        return min(max(raw, -cap), cap)
    }

    /// Eén frame uitrollen: afgelegde seconden en de nieuwe snelheid (exponentieel afremmen, exact geïntegreerd).
    /// Snelheid 0 = klaar.
    static func coastStep(velocity: Double, dt: Double) -> (delta: Double, velocity: Double) {
        guard velocity.isFinite, dt.isFinite, dt > 0, abs(velocity) >= coastStopSpeed else { return (0, 0) }
        let step = min(dt, 0.1)                     // een gemist frame geeft geen grote sprong
        let k = exp(-step / coastTau)
        let delta = velocity * coastTau * (1 - k)
        let v = velocity * k
        return (delta, abs(v) < coastStopSpeed ? 0 : v)
    }

    // MARK: klikstappen (ingedrukt houden)

    /// Na zo lang ingedrukt houden begint het herhalen (de eerste klik geeft zelf al een stap).
    static let holdDelay: Double = 0.35
    /// Vast ritme van het herhalen.
    static let holdInterval: Double = 0.25

    /// Stap bij herhaling `tick` (0, 1, 2 …): 4× 10 s, daarna 6× 30 s, daarna 60 s.
    static func holdStep(tick: Int) -> Double {
        tick < 4 ? 10 : (tick < 10 ? 30 : 60)
    }

    // MARK: beeld volgt mee (afgeknepen seeks)

    /// Hooguit één seek tegelijk, minstens zo lang na de vorige, en alleen als het doel genoeg verschilt.
    static let seekInterval: Double = 0.2
    static let seekMinDelta: Double = 0.5

    static func shouldSeek(now: Double, lastSeekAt: Double?, inFlight: Bool, lastTarget: Double?, target: Double) -> Bool {
        guard !inFlight, target.isFinite else { return false }
        if let t = lastTarget, abs(target - t) < seekMinDelta { return false }
        guard let at = lastSeekAt else { return true }
        return now - at >= seekInterval
    }

    /// Hoe lang nog wachten tot de volgende seek mag (0 = nu).
    static func seekWait(now: Double, lastSeekAt: Double?) -> Double {
        guard let at = lastSeekAt else { return 0 }
        return max(0, seekInterval - (now - at))
    }

    // MARK: na bevestigen

    /// De voorbeeldpositie blijft staan tot de speler (bijna) de nieuwe tijd meldt, of hoogstens 1,5 s.
    static let commitHold: Double = 1.5
    static let commitTolerance: Double = 1.5

    static func releaseHold(elapsed: Double, target: Double, reported: Double) -> Bool {
        if !elapsed.isFinite || elapsed >= commitHold { return true }
        guard target.isFinite, reported.isFinite else { return false }
        return abs(reported - target) <= commitTolerance
    }

    // MARK: focus

    /// Zo lang na de laatste swipe-beweging blijft de focus op de tijdbalk (geen per ongeluk ↑/↓).
    static let focusGuard: Double = 0.5

    static func guardsFocus(panning: Bool, coasting: Bool, sinceLastPan: Double) -> Bool {
        panning || coasting || (sinceLastPan.isFinite && sinceLastPan >= 0 && sinceLastPan < focusGuard)
    }

    // MARK: weergave

    /// Plek van de kop (0…1), zonder afronding op hele seconden.
    static func fraction(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }
}
