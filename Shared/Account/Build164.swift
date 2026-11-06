import Foundation

// Build 164: pure logica van de nieuwe tv-gids (alleen Foundation), ook los gebouwd in de zelftest van CI
// (tools/selftest/main.swift). De schermen staan in Shared/UI/Screens/GuideView.swift, het live voorbeeld in
// Shared/Player/ChannelPreview.swift en de stilstaande beelden in Shared/Player/GuideStills.swift.

/// De dagbalk: gisteren t/m 7 dagen vooruit; verder terug alleen als een zender in beeld terugkijken heeft
/// (hooguit het grootste aantal terugkijkdagen).
enum GuideDays164 {
    static let ahead = 7
    /// Bovengrens voor terug in de tijd (sommige servers melden onzinnig veel terugkijkdagen)
    static let maxBack = 14

    /// Hoeveel dagen terug de balk gaat: altijd gisteren, met terugkijken tot het grootste aantal terugkijkdagen.
    static func daysBack(catchupDays: [Int]) -> Int {
        min(max(1, catchupDays.max() ?? 0), maxBack)
    }

    /// Het begin van elke dag in de balk, van oud naar nieuw (vandaag op index `daysBack`).
    static func days(today: Date, catchupDays: [Int], calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: today)
        let back = daysBack(catchupDays: catchupDays)
        return (-back...ahead).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    enum Label: Equatable { case yesterday, today, tomorrow, other }

    static func label(_ day: Date, today: Date, calendar: Calendar = .current) -> Label {
        let a = calendar.startOfDay(for: day), b = calendar.startOfDay(for: today)
        let diff = calendar.dateComponents([.day], from: b, to: a).day ?? 0
        switch diff {
        case -1: return .yesterday
        case 0: return .today
        case 1: return .tomorrow
        default: return .other
        }
    }

    /// Het stuk van de gids voor een dag: van het begin van die dag tot het begin van de volgende.
    static func window(_ day: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let from = calendar.startOfDay(for: day)
        let to = calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        return (from, to)
    }
}

/// Een programma in de lijst: voorbij (gedimd, met terugkijk-icoon als dat kan), nu (NU-blok) of later.
enum GuideState164: Equatable {
    case past(replay: Bool)
    case now
    case future

    /// `catchupDays`: terugkijkdagen van de zender (0 = geen terugkijken).
    static func of(start: Date, end: Date, now: Date, catchupDays: Int) -> GuideState164 {
        if start <= now && now < end { return .now }
        if end <= now {
            let replay = catchupDays > 0 && start > now.addingTimeInterval(-Double(catchupDays) * 86400)
            return .past(replay: replay)
        }
        return .future
    }
}

/// Waar de lijst naartoe scrolt en wat de NU-kaart is.
enum GuideNow164 {
    /// Index van het programma dat nu loopt (op begintijd gesorteerd; bij overlap het eerste dat nu loopt), of nil.
    static func index(starts: [Date], ends: [Date], now: Date) -> Int? {
        guard starts.count == ends.count, !starts.isEmpty else { return nil }
        // binair zoeken naar het eerste programma dat ná nu begint
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= now { lo = mid + 1 } else { hi = mid }
        }
        var i = max(0, lo - 4)
        while i < lo {
            if starts[i] <= now && now < ends[i] { return i }
            i += 1
        }
        return nil
    }

    /// Waar de lijst bij openen heen scrolt: NU, anders het eerste latere programma, anders het laatste.
    static func scrollTarget(starts: [Date], ends: [Date], now: Date) -> Int? {
        guard starts.count == ends.count, !starts.isEmpty else { return nil }
        if let i = index(starts: starts, ends: ends, now: now) { return i }
        if let i = starts.firstIndex(where: { $0 > now }) { return i }
        return starts.count - 1
    }

    /// Apple TV: de stukken van een kolom rond de NU-kaart (2 eerder, 4 later). Zonder NU: de eerste latere
    /// programma's als "later" en geen kaart.
    static func columnSlice(count: Int, nowIndex: Int?, firstFuture: Int?, before: Int = 2, after: Int = 4)
        -> (before: Range<Int>, now: Int?, after: Range<Int>) {
        guard count > 0 else { return (0..<0, nil, 0..<0) }
        if let n = nowIndex, n >= 0, n < count {
            return (max(0, n - before)..<n, n, (n + 1)..<min(count, n + 1 + after))
        }
        let f = min(max(firstFuture ?? count, 0), count)
        return (max(0, f - before)..<f, nil, f..<min(count, f + after))
    }

    /// Voortgang 0...1 van een programma.
    static func progress(start: Date, end: Date, now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }

    /// "Nog N min" (afgerond naar boven, minstens 1 zolang het loopt).
    static func minutesLeft(end: Date, now: Date) -> Int {
        let s = end.timeIntervalSince(now)
        guard s > 0 else { return 0 }
        return max(1, Int((s / 60).rounded(.up)))
    }
}

/// Instelling "Live voorbeeld in de gids": Altijd, Alleen wifi (standaard) of Nooit.
enum GuidePreviewMode164: String, CaseIterable, Equatable {
    case always, wifi, never

    static let key = "guide.livePreview"
    static let `default`: GuidePreviewMode164 = .wifi

    /// Bewaarde waarde lezen. Zonder eigen keuze: de oude schakelaar "Zendervoorbeeld" (`live.preview`) uit = Nooit.
    static func resolve(stored: String?, legacyPreview: Bool?) -> GuidePreviewMode164 {
        if let s = stored, let m = GuidePreviewMode164(rawValue: s) { return m }
        if legacyPreview == false { return .never }
        return .default
    }

    /// Mag het voorbeeld vanzelf starten (zonder tik)? Tv's zijn altijd wifi of kabel: "Alleen wifi" = aan.
    func autoStart(isTV: Bool, cellular: Bool) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .wifi: return isTV || !cellular
        }
    }

    /// Mag het voorbeeld na een tik starten? (Op mobiel netwerk start het vak pas na een tik.)
    var allowsTap: Bool { self != .never }
}

/// Stilstaande beelden per zender: klein jpg in de cache, hooguit 30 minuten oud, maximaal 200 zenders.
enum GuideStillPolicy164 {
    static let maxAge: TimeInterval = 30 * 60
    static let maxCount = 200
    static let width = 320
    /// Niet vaker dan dit een nieuw beeld van dezelfde zender maken
    static let minInterval: TimeInterval = 60

    static func isFresh(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= -60 && age <= maxAge   // een klein stukje in de toekomst (klok) mag
    }

    /// Welk beeld tonen: het live voorbeeld als dat speelt, anders een vers stilstaand beeld, anders het logo.
    enum Pick: Equatable { case live, still, logo }
    static func pick(isLive: Bool, stillSavedAt: Date?, now: Date) -> Pick {
        if isLive { return .live }
        if let s = stillSavedAt, isFresh(savedAt: s, now: now) { return .still }
        return .logo
    }

    /// Mag er nu een nieuw beeld bewaard worden (niet steeds opnieuw schrijven)?
    static func shouldSave(lastSavedAt: Date?, now: Date) -> Bool {
        guard let l = lastSavedAt else { return true }
        return now.timeIntervalSince(l) >= minInterval || l > now
    }

    /// Welke beelden weg moeten: alles boven `maxCount`, de oudste eerst.
    static func evict(_ entries: [(key: String, savedAt: Date)], max: Int = maxCount) -> [String] {
        guard entries.count > max else { return [] }
        let sorted = entries.sorted { $0.savedAt == $1.savedAt ? $0.key < $1.key : $0.savedAt < $1.savedAt }
        return sorted.prefix(entries.count - max).map(\.key)
    }

    /// Bestandsnaam voor een zender ("<server>|<zender-id>"): vaste, korte hash (FNV-1a, 64 bit), geen tekens van de
    /// server in de naam.
    static func fileName(for key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.lowercased().utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex + ".jpg"
    }
}
