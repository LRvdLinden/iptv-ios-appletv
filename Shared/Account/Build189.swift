import Foundation

// Build 189 (versie 1.1.2): pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).

/// Lijsten met gelijke namen (zes keer "Polish - [Polish]") onderscheidbaar maken zonder een spoor te verliezen.
enum TrackTitles189 {
    /// Gelijke titels krijgen " (2)", " (3)", ...; unieke titels blijven zoals ze zijn. De volgorde blijft gelijk.
    static func unique(_ names: [String]) -> [String] {
        var total: [String: Int] = [:]
        for n in names { total[n, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { n in
            guard total[n, default: 0] > 1 else { return n }
            seen[n, default: 0] += 1
            return seen[n]! == 1 ? n : "\(n) (\(seen[n]!))"
        }
    }
}

/// Pincodevakjes: het laatst getypte cijfer blijft even zichtbaar, de rest is een punt.
enum PINBoxes189 {
    /// `pin` = tot nu toe getypt (0...count cijfers), `revealLast` = het laatste cijfer tonen. Resultaat: `count` tekens, "" = leeg vakje.
    static func shown(pin: String, count: Int = 4, revealLast: Bool) -> [String] {
        (0..<count).map { i in
            guard i < pin.count else { return "" }
            return (revealLast && i == pin.count - 1) ? String(pin[pin.index(pin.startIndex, offsetBy: i)]) : "\u{2022}"
        }
    }
}
