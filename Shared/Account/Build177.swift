import Foundation

/// Build 177 (versie 1.0.8): tv-gids per zender. Pure logica, gelijk op alle platforms (Android `Build177Logic.kt`,
/// web `web/js/build177.js`); gedeelde testgevallen: docs/build177_cases.json (tools/selftest).
/// Alleen Foundation: de zelftest compileert dit bestand los van de app (samen met Build164.swift).
enum Build177 {

    // MARK: 1. Hele dag in de kolom, scrollen en focus

    /// Zoveel programma's vóór NU staan bovenaan als de lijst naar NU scrolt
    static let before = 2

    /// Een regel in een gidskolom: een programma (index in de programma's van de dag) of de NU-kaart (Apple TV;
    /// nil = er loopt nu niets volgens de gids, de kaart toont dan alleen de zender).
    enum Row: Equatable, Hashable {
        case program(Int)
        case now(Int?)
    }

    /// De regels van een kolom: altijd de hele dag. Vandaag met NU-kaart (`nowCard`) op de plek van NU (of vóór het
    /// eerste latere programma); `focus` = de regel die de focus krijgt (NU, andere dagen de eerste);
    /// `anchor` = de regel waar de lijst bij openen bovenaan staat (twee vóór NU, andere dagen de eerste).
    struct Column: Equatable {
        var rows: [Row]
        var focus: Int?
        var anchor: Int?
    }

    static func column(count: Int, nowIndex: Int?, firstFuture: Int?, today: Bool, nowCard: Bool) -> Column {
        guard today else {
            let rows = (0..<max(0, count)).map { Row.program($0) }
            return Column(rows: rows, focus: rows.isEmpty ? nil : 0, anchor: rows.isEmpty ? nil : 0)
        }
        var rows: [Row] = []
        rows.reserveCapacity(count + 1)
        let at: Int
        if let n = nowIndex, n >= 0, n < count {
            at = n
            rows += (0..<n).map { Row.program($0) }
            rows.append(nowCard ? .now(n) : .program(n))
            rows += (n + 1 < count ? Array((n + 1)..<count) : []).map { Row.program($0) }
        } else {
            let f = min(max(firstFuture ?? count, 0), max(0, count))
            rows += (0..<f).map { Row.program($0) }
            if nowCard {
                at = f
                rows.append(.now(nil))
            } else {
                // zonder kaart: het eerste latere programma (of het laatste als de dag voorbij is)
                at = count == 0 ? -1 : min(f, count - 1)
            }
            rows += (f < count ? Array(f..<count) : []).map { Row.program($0) }
        }
        guard at >= 0, !rows.isEmpty else { return Column(rows: rows, focus: nil, anchor: nil) }
        return Column(rows: rows, focus: at, anchor: max(0, at - before))
    }

    // MARK: 2. Programma's per zender: op volgorde, zonder dubbelen

    /// Zelfde titel die binnen zoveel seconden na een al getoond programma begint = dubbel (twee bronnen in de gids)
    static let mergeWindow: Double = 300
    /// Overlapt een programma hooguit zoveel seconden met het vorige, dan begint het pas als het vorige afloopt
    /// (valt het er helemaal binnen, dan weg): zo staat een programma dat binnen het NU-programma valt niet als "later"
    static let overlapWindow: Double = 300

    /// Titel om dubbelen te vinden: kleine letters, spaties samengevoegd
    static func titleKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Een opgeschoonde regel: index van het programma in de invoer, met mogelijk een ander begin of einde
    struct Cleaned: Equatable {
        var index: Int
        var start: Double
        var end: Double
    }

    /// Sorteren op begin (bij gelijk begin het langste eerst), dubbelen samenvoegen (zelfde titel, begint binnen
    /// `mergeWindow` na een getoond programma: het langste einde telt) en kleine overlap wegwerken.
    /// Tijden in seconden sinds 1970.
    static func clean(titles: [String], starts: [Double], ends: [Double]) -> [Cleaned] {
        let n = min(titles.count, starts.count, ends.count)
        guard n > 0 else { return [] }
        let order = (0..<n).sorted {
            starts[$0] != starts[$1] ? starts[$0] < starts[$1] : (ends[$0] != ends[$1] ? ends[$0] > ends[$1] : $0 < $1)
        }
        var out: [Cleaned] = []
        var keys: [String] = []
        out.reserveCapacity(n)
        for i in order {
            var p = Cleaned(index: i, start: starts[i], end: ends[i])
            let key = titleKey(titles[i])
            // 1. dubbel van een programma dat kort ervoor begon
            var merged = false
            var j = out.count - 1
            while j >= 0, out[j].start >= p.start - mergeWindow {
                if keys[j] == key {
                    out[j].end = max(out[j].end, p.end)
                    merged = true
                    break
                }
                j -= 1
            }
            if merged { continue }
            // 2. kleine overlap met het vorige programma
            if let k = out.last, p.start < k.end, k.end - p.start <= overlapWindow {
                if p.end <= k.end { continue }
                p.start = k.end
            }
            out.append(p)
            keys.append(key)
        }
        return out
    }

    // MARK: 3. Live voorbeeld bij focus

    /// Zo lang wacht het stoppen van het voorbeeld nadat de focus van de NU-kaart weggaat: komt de focus binnen die
    /// tijd terug (of op een andere NU-kaart), dan wordt er niet gestopt en opnieuw gestart
    static let releaseGrace: Double = 0.3

    /// Stopt het loslaten van zender `releasing` het voorbeeld? Niet als er al een andere zender klaarstaat.
    static func releaseStops(releasing: String, pending: String?, playing: String?) -> Bool {
        if let p = pending, p != releasing { return false }
        return pending == releasing || playing == releasing
    }

    /// Voert VLC stoppen en een nieuwe stream openen buiten de hoofdthread uit? Stil voorbeeld en het voorbeeld in de
    /// gids altijd; een speler die eenmaal zo werkte blijft zo (ook na volledig scherm met dezelfde stream).
    static func vlcOffMain(silent: Bool, preview: Bool, wasOffMain: Bool) -> Bool {
        silent || preview || wasOffMain
    }

    // MARK: 4. Klok van de gids

    /// Seconden tot de volgende hele minuut (programma's beginnen op hele minuten), minstens 1
    static func secondsToNextMinute(_ now: Double) -> Double {
        let r = now.truncatingRemainder(dividingBy: 60)
        return max(1, 60 - (r < 0 ? r + 60 : r))
    }
}
