import Foundation

// Build 166: pure logica van de dagbalk van de tv-gids (alleen Foundation), ook los gebouwd in de zelftest van CI
// (tools/selftest/main.swift). Gebruikt in Shared/UI/Screens/GuideView.swift (alle Apple-platforms).

/// De gids van één zender in de steekproef: begin- en eindtijden op begintijd gesorteerd, en de terugkijkdagen.
struct GuideSample166: Equatable {
    var starts: [Date]
    var ends: [Date]
    var catchupDays: Int

    init(starts: [Date], ends: [Date], catchupDays: Int) {
        self.starts = starts
        self.ends = ends
        self.catchupDays = catchupDays
    }

    /// Staat er een programma (deels) tussen `from` en `to`? Binair zoeken op begintijd, daarna een paar terug voor
    /// lange programma's die vóór `from` begonnen.
    func hasProgram(from: Date, to: Date) -> Bool {
        guard starts.count == ends.count, !starts.isEmpty, from < to else { return false }
        // eerste programma dat op of na `to` begint: alles daarvoor begint vóór `to`
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < to { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0 && i >= lo - 8 {
            if ends[i] > from { return true }   // begint vóór `to` (zie boven) en eindigt na `from`
            i -= 1
        }
        return false
    }
}

/// Build 166: alleen dagen in de dagbalk waarvoor er gids-info is.
/// - "Vandaag" staat er altijd.
/// - Een andere dag alleen als minstens één zender uit de steekproef op die dag programma's heeft.
/// - Gisteren en eerder bovendien alleen als zo'n zender terugkijken heeft dat tot die dag teruggaat.
enum GuideAvailableDays166 {
    /// Hoeveel zenders met gids (vanaf het begin van de lijst) meetellen
    static let sampleSize = 50
    /// Hoe ver in de lijst er naar zenders met gids gezocht wordt
    static let scanLimit = 400

    /// `candidates`: de dagen van `GuideDays164.days` (begin van elke dag, oud naar nieuw).
    static func days(candidates: [Date], today: Date, samples: [GuideSample166],
                     calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: today)
        let sample = Array(samples.prefix(sampleSize))
        var out: [Date] = []
        var hasToday = false
        for d in candidates {
            let day = calendar.startOfDay(for: d)
            if day == start {
                if !hasToday { out.append(day); hasToday = true }
                continue
            }
            let w = GuideDays164.window(day, calendar: calendar)
            let back = calendar.dateComponents([.day], from: day, to: start).day ?? 0
            let ok: Bool
            if back > 0 {
                // verleden: gids-info én terugkijken dat zo ver teruggaat, bij dezelfde zender
                ok = sample.contains { $0.catchupDays >= back && $0.hasProgram(from: w.from, to: w.to) }
            } else {
                ok = sample.contains { $0.hasProgram(from: w.from, to: w.to) }
            }
            if ok && !out.contains(day) { out.append(day) }
        }
        if !hasToday {
            // vandaag ontbrak in de kandidaten: op zijn plek (op volgorde) toevoegen
            let i = out.firstIndex(where: { $0 > start }) ?? out.count
            out.insert(start, at: i)
        }
        return out
    }

    /// De gekozen dag houden als hij er nog is, anders vandaag.
    static func keep(_ day: Date, in days: [Date], today: Date, calendar: Calendar = .current) -> Date {
        let d = calendar.startOfDay(for: day)
        return days.contains(d) ? d : calendar.startOfDay(for: today)
    }
}
