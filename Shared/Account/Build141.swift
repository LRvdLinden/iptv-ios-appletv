import Foundation

// Build 141: pure logica (zonder SwiftUI), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).

// MARK: - Mijn lijst: welk id en waar de titel vandaan komt

enum MyListID {
    /// Voorvoegsel van een TMDB-titel ("tmdb-movie-123" / "tmdb-tv-123"), gelijk aan `DiscoverItem.idPrefix`
    static let externalPrefix = "tmdb-"

    /// Id waaronder een titel in Mijn lijst komt. Een titel uit een bibliotheek houdt zijn eigen id. Een aanbeveling die
    /// niet in een bibliotheek staat ("rec-…", alleen op dit apparaat bekend) krijgt zijn TMDB-id, zodat Mijn lijst
    /// hem op elk apparaat kan tonen (tot build 140 kwam "rec-…" in de lijst en verscheen hij nergens). nil = het
    /// TMDB-id is (nog) niet bekend: dan geen knop Mijn lijst.
    static func forTitle(id: String, tmdb: Int?, isShow: Bool) -> String? {
        guard id.hasPrefix("rec-") else { return id }
        guard let tmdb, tmdb > 0 else { return nil }
        return "\(externalPrefix)\(isShow ? "tv" : "movie")-\(tmdb)"
    }

    enum Origin: Equatable {
        /// op de open server (uit de bibliotheek)
        case active
        /// op een andere server van het account (via CrossServer / catalogmeta)
        case otherServer
        /// TMDB-titel (niet in een bibliotheek)
        case external
    }

    /// Waar een sleutel uit Mijn lijst ("<server-id>|<item-id>") vandaan komt, gezien vanaf de open server.
    /// Server-id hoofdletterongevoelig, item-id exact. nil = geen geldige sleutel.
    static func origin(of key: String, activeSID: String?) -> Origin? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        let sid = key[..<bar], item = key[key.index(after: bar)...]
        guard !sid.isEmpty, !item.isEmpty else { return nil }
        let isActive = activeSID.map { sid.caseInsensitiveCompare($0) == .orderedSame } ?? false
        // een TMDB-titel hoort bij geen enkele server (ook als hij onder een andere server-id is bewaard)
        if item.hasPrefix(externalPrefix) { return .external }
        return isActive ? .active : .otherServer
    }

    /// De tegels van Mijn lijst: per sleutel de titel als die te tonen is. `active`: items van de open server (op
    /// item-id), `other`: gevonden of net toegevoegde items van andere servers (op genormaliseerde sleutel),
    /// `external`: bekende TMDB-titels (op id). Volgorde: laatst toegevoegd eerst.
    static func visible<T>(keys: [(key: String, at: Double)], activeSID: String?, active: [String: T], other: [String: T],
                           external: [String: T]) -> [T] {
        var out: [(T, Double)] = []
        for (k, at) in keys {
            guard let o = origin(of: k, activeSID: activeSID), let bar = k.firstIndex(of: "|") else { continue }
            let item = String(k[k.index(after: bar)...])
            let norm = k[..<bar].lowercased() + "|" + item
            switch o {
            case .active: if let t = active[item] { out.append((t, at)) }
            case .external: if let t = external[item] { out.append((t, at)) }
            case .otherServer: if let t = other[norm] { out.append((t, at)) }
            }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

// MARK: - Home: Nieuw op Bingr op de plek van Nieuw toegevoegd

enum HomeRowOrder {
    /// "Nieuw toegevoegd" (`recent`) staat niet meer op Home; Nieuw op Bingr (`streaming`) komt op zijn plek, met zijn
    /// eigen aan/uit (of dat van `recent` als `streaming` er nog niet stond). Daarna is er één rij Nieuw op Bingr.
    static func newOnBingrAtRecent<R>(_ rows: [R], key: (R) -> String, visible: (R) -> Bool,
                                      make: (String, Bool) -> R) -> [R] {
        guard let ri = rows.firstIndex(where: { key($0) == "recent" }) else { return rows }
        let v = rows.first(where: { key($0) == "streaming" }).map(visible) ?? visible(rows[ri])
        var out: [R] = []
        for (i, r) in rows.enumerated() {
            if i == ri { out.append(make("streaming", v)) }
            else if key(r) != "streaming" && key(r) != "recent" { out.append(r) }
        }
        return out
    }
}

// MARK: - Build 143: startdiagnose (mijlpalen, vorige start niet klaar, crash of hang)

/// Pure logica van de startdiagnose (`StartDiagnostics` in Shared/App/StartDiagnostics.swift), ook in de zelftest.
/// Alleen mijlpalen, tijden, build, OS en stack-symbolen: geen URL's, servernamen, gebruikersnamen of e-mail.
enum StartDiag {
    /// Mijlpaal: naam, seconden sinds de start en het geheugengebruik van de app op dat moment (MB, phys_footprint)
    struct Mark: Codable, Equatable { var name: String; var t: Double; var mb: Int? = nil }
    struct Record: Codable, Equatable {
        var build: String
        var os: String
        var started: Double
        var marks: [Mark] = []
        /// Hoofdthread langer dan 10 s vast (gezien door de bewaking op de achtergrond)
        var hang: Double? = nil
        var hangAt: String? = nil
        var finished = false
        var crash: String? = nil
        var stack: [String] = []
        /// Hoogste geheugengebruik tijdens de start (MB)
        var peakMB: Int? = nil
        /// Build 147: bij de langste hang: de taak/fase op de hoofdthread, of de app op de voorgrond stond, en een
        /// momentopname van de stack van de hoofdthread (alleen code-symbolen)
        var hangTask: String? = nil
        var hangFg: Bool? = nil
        var hangStack: [String]? = nil
        /// Build 147: aantal hangs boven 2 s (op de voorgrond)
        var hangs: Int? = nil
    }
    struct Problem: Codable, Equatable {
        enum Kind: String, Codable { case crash, hang, notFinished }
        var kind: Kind
        var build: String
        var os: String
        var at: Double
        var lastMark: String
        var seconds: Double
        var marks: [Mark]
        var crash: String?
        var stack: [String]
        var peakMB: Int? = nil
        /// Build 147: taak/fase op de hoofdthread tijdens de hang en of de app op de voorgrond stond
        var task: String? = nil
        var foreground: Bool? = nil
    }

    static let hangLimit: Double = 10
    static let finalMark = "klaar"

    /// Wat er mis was met de vorige start (nil = die kwam gewoon bij "klaar", zonder crash of lange hang).
    static func analyze(_ r: Record?, crashLog: String? = nil) -> Problem? {
        guard let r else { return nil }
        let stack = scrub(lines: (crashLog.map { $0.split(separator: "\n").map(String.init) } ?? []) + r.stack)
        let last = r.marks.last?.name ?? "gestart"
        let dur = r.marks.last?.t ?? 0
        let crashName = r.crash ?? crashLog.flatMap { log in log.split(separator: "\n").first.map(String.init) }
        if let c = crashName, !c.isEmpty {
            return Problem(kind: .crash, build: r.build, os: r.os, at: r.started, lastMark: last, seconds: dur, marks: r.marks,
                           crash: scrub(c), stack: Array(stack.prefix(60)), peakMB: r.peakMB)
        }
        if let h = r.hang, h >= hangLimit {
            return Problem(kind: .hang, build: r.build, os: r.os, at: r.started, lastMark: r.hangAt ?? last, seconds: h,
                           marks: r.marks, crash: nil, stack: scrub(lines: r.hangStack ?? []), peakMB: r.peakMB,
                           task: r.hangTask, foreground: r.hangFg)
        }
        // build 147: wachten op de gebruiker (profielkeuze, pincodescherm) is geen vastgelopen start
        if !r.finished && !StartPrevious.waitingOnUser(r.marks) {
            return Problem(kind: .notFinished, build: r.build, os: r.os, at: r.started, lastMark: last, seconds: dur,
                           marks: r.marks, crash: nil, stack: [], peakMB: r.peakMB)
        }
        return nil
    }

    /// Tekst voor het scherm en het supportticket.
    static func text(_ p: Problem) -> String {
        var out: [String] = []
        switch p.kind {
        case .crash: out.append("Vorige start: gestopt (crash) na \(fmt(p.seconds)) s, bij \"\(p.lastMark)\"")
        case .hang:
            out.append("Vorige start: hoofdthread \(fmt(p.seconds)) s vast bij \"\(p.lastMark)\""
                       + (p.foreground == false ? " (achtergrond)" : " (voorgrond)"))
            if let t = p.task { out.append("Taak: \(t)") }
        case .notFinished: out.append("Vorige start: niet klaar, laatste mijlpaal \"\(p.lastMark)\" na \(fmt(p.seconds)) s (gestopt door het systeem, bijv. geheugen of watchdog)")
        }
        if let m = p.peakMB { out.append("Geheugen: hoogste \(m) MB") }
        out.append("Build \(p.build) · \(p.os)")
        out.append("Mijlpalen: " + p.marks.map { m in "\(m.name) \(fmt(m.t))s" + (m.mb.map { " \($0)MB" } ?? "") }.joined(separator: " · "))
        if let c = p.crash { out.append("Fout: \(c)") }
        if !p.stack.isEmpty { out.append("Stack:"); out += p.stack }
        return out.joined(separator: "\n")
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    /// Geen persoonsgegevens: e-mail, URL's, paden met gebruikersnaam en lange tekenreeksen tussen aanhalingstekens weg.
    static func scrub(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, "<url>"),
            (#"[^\s"'<>]+@[^\s"'<>]+\.[A-Za-z]{2,}"#, "<e>"),
            (#"/(Users|home|var/mobile)/[^/\s]+"#, "/~"),
            (#""[^"]{24,}""#, "\"…\""),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return String(t.prefix(300))
    }

    static func scrub(lines: [String]) -> [String] { lines.map { scrub($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}
