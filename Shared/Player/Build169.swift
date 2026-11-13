import Foundation

// Build 169 (versie 1.0.6): doorspoelen via de tijdbalk, zoals de standaardspeler van Apple TV. Pure logica (alleen
// Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift). Gebruikt in
// Shared/Player/PlayerScreen.swift: de focusbare tijdbalk op tvOS (swipen, klikken, bevestigen, annuleren) en de tekst
// boven de Slider op iPhone, iPad en Mac.

enum Scrub169 {
    /// Zonder bevestigen vervalt de voorbeeldpositie 5 s nadat de focus van de balk is.
    static let previewTimeout: Double = 5
    /// Klikken binnen deze tijd na de vorige (zelfde richting) tellen als herhalen (versnellen).
    static let repeatWindow: Double = 0.6

    /// Seconden voor één volle breedte van het touchoppervlak: 10 minuten, of 20% van de duur als dat minder is.
    static func fullWidthSeconds(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 600 }
        return min(600, duration * 0.2)
    }

    /// Versnelling bij snel swipen. `velocity` in breedtes van het touchoppervlak per seconde (teken doet niet mee):
    /// rustig (≤ 0,5) = 1×, daarboven oplopend tot hoogstens 5×.
    static func gain(velocity: Double) -> Double {
        let v = abs(velocity.isFinite ? velocity : 0)
        return min(max(1 + (v - 0.5) * 1.5, 1), 5)
    }

    /// Van een stukje pan (deel van de breedte, met teken) naar seconden, met versnelling.
    static func panSeconds(fraction: Double, velocity: Double, duration: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return fraction * fullWidthSeconds(duration: duration) * gain(velocity: velocity)
    }

    /// Het volgende herhaalnummer: binnen `repeatWindow` in dezelfde richting één hoger, anders weer 0.
    static func nextRepeat(previous: Int, sameDirection: Bool, interval: Double) -> Int {
        sameDirection && interval >= 0 && interval < repeatWindow ? previous + 1 : 0
    }

    /// Stap per klik: 10 s, na drie keer herhalen 30 s, na zes keer 60 s.
    static func clickStep(repeatCount: Int) -> Double {
        repeatCount < 3 ? 10 : (repeatCount < 6 ? 30 : 60)
    }

    /// Begrenzen op 0…duur.
    static func clamp(_ t: Double, duration: Double) -> Double {
        guard t.isFinite else { return 0 }
        guard duration.isFinite, duration > 0 else { return max(t, 0) }
        return min(max(t, 0), duration)
    }

    /// Tijd als m:ss of u:mm:ss.
    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded(.down)), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Verschil ten opzichte van nu: "+4:30", "−1:10" (echt minteken), "0:00" bij (bijna) geen verschil.
    static func deltaText(_ delta: Double) -> String {
        guard delta.isFinite else { return "0:00" }
        let r = delta.rounded()
        if r == 0 { return "0:00" }
        return (r > 0 ? "+" : "\u{2212}") + time(abs(r))
    }

    /// Tekst boven de kop: tijd van de voorbeeldpositie en het verschil ("12:30  +4:30").
    static func label(preview: Double, current: Double) -> String {
        time(preview) + "  " + deltaText(preview - current)
    }
}
