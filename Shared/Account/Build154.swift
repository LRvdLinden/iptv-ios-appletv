import Foundation

// Build 154: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
// Contract: docs/ACCOUNT.md, "Build 154: gezien over alle servers en betrouwbare Trakt-sync";
// gedeelde testgevallen: docs/watched_keys_cases.json (zelfde op Apple, Android en web).
//
// - `TitleRules154`: titelopschoning (weergave en sleutels): een voorvoegsel met ":" of "-" alleen weg als het een
//   taal-/landcode, kwaliteitswoord of bekend IPTV-woord is (lijsten van build 150), en een jaartal achteraan alleen
//   tussen haakjes/blokhaken of achter een scheidingsteken. "NCIS: Hawaii", "Blade Runner 2049" en "Sub Zero" blijven heel.
// - `WatchKeys`: inhoudssleutels voor "gezien" (`w:m:`, `w:s:`, `w:e:`), lezen met jaar ±1, uitvinken en migratie.
// - `TraktTokenPolicy`, `TraktQueue`, `TraktBackoff`, `TraktMatch`: regels voor de Trakt-sync.

// MARK: - Titelopschoning

enum TitleRules154 {
    /// Hoogste geldige jaar: volgend jaar
    static var maxYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) + 1 }

    static func validYear(_ y: Int) -> Bool { y >= 1900 && y <= maxYear }

    private static func hasContent<S: StringProtocol>(_ s: S) -> Bool { s.contains { $0.isLetter || $0.isNumber } }

    /// Vier cijfers die een geldig jaar zijn
    private static func yearValue<S: StringProtocol>(_ s: S) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 4, t.allSatisfy({ $0.isASCII && $0.isNumber }), let y = Int(t), validYear(y) else { return nil }
        return y
    }

    /// Voorvoegsels weg (hooguit twee): "|NL| ", "[NL] ", "NL: ", "NL - ", "4K | ", "VOD: ". Een woord dat geen
    /// taal-/landcode, kwaliteit of IPTV-woord is blijft staan ("NCIS: Hawaii", "BBC - Planet Earth", "[REC]").
    static func stripPrefixes(_ raw: String) -> String {
        var s = Substring(raw)
        for _ in 0..<2 {
            s = s.drop(while: { $0.isWhitespace })
            guard let first = s.first else { break }
            if first == "|", let end = s.dropFirst().firstIndex(of: "|"), s.distance(from: s.startIndex, to: end) <= 13 {
                let rest = s[s.index(after: end)...]
                guard hasContent(rest) else { break }
                s = rest; continue
            }
            if first == "[", let end = s.dropFirst().firstIndex(of: "]"), s.distance(from: s.startIndex, to: end) <= 13 {
                let inner = s[s.index(after: s.startIndex)..<end]
                let rest = s[s.index(after: end)...]
                guard hasContent(rest), CategoryName.isTagPhrase(inner, restHasLetters: rest.contains(where: \.isLetter)) else { break }
                s = rest; continue
            }
            guard let sep = s.firstIndex(where: { $0 == ":" || $0 == "-" || $0 == "|" || $0 == "–" }) else { break }
            let head = s[..<sep]
            let rest = s[s.index(after: sep)...]
            // "-" en ":" alleen met een spatie erachter ("NL - Dune", niet "Ex-Machina")
            if s[sep] != "|", let n = rest.first, !n.isWhitespace { break }
            guard head.count <= 16, hasContent(head), hasContent(rest),
                  CategoryName.isTagPhrase(head, restHasLetters: rest.contains(where: \.isLetter)) else { break }
            s = rest
        }
        return String(s).trimmingCharacters(in: .whitespaces)
    }

    /// Jaartal tussen haakjes of blokhaken weg (het laatste, ook als er daarna nog "[4K]" staat), anders een los
    /// jaartal achteraan achter "-", "–" of "|". Alleen 1900 … volgend jaar, en alleen als er een titel overblijft.
    static func extractYear(_ raw: String) -> (title: String, year: Int?) {
        let s = raw
        // 1. tussen haakjes: van achteren af zoeken
        var idx = s.endIndex
        while idx > s.startIndex {
            idx = s.index(before: idx)
            let c = s[idx]
            guard c == ")" || c == "]" else { continue }
            let open: Character = c == ")" ? "(" : "["
            guard let start = s[..<idx].lastIndex(of: open) else { continue }
            let inner = s[s.index(after: start)..<idx]
            guard let y = yearValue(inner) else { continue }
            let head = s[..<start], tail = s[s.index(after: idx)...]
            guard hasContent(head) else { continue }
            let joined = (String(head) + " " + String(tail))
            return (tidy(joined), y)
        }
        // 2. achter een scheidingsteken aan het eind: "Dune - 2021", "Dune | 2021"
        let t = s.trimmingCharacters(in: .whitespaces)
        if let sep = t.lastIndex(where: { $0 == "-" || $0 == "–" || $0 == "|" }) {
            let tail = t[t.index(after: sep)...], head = t[..<sep]
            if let y = yearValue(tail), hasContent(head) { return (tidy(String(head)), y) }
        }
        return (raw, nil)
    }

    private static func tidy(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–|:"))
    }

    /// Opgeschoonde titel en jaar zoals de sleutels ze gebruiken (zonder taal-, land- en pipe-aanduidingen).
    /// Gelijk aan de gedeelde gevallen `clean` in docs/watched_keys_cases.json.
    static func clean(_ raw: String) -> (title: String, year: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = CategoryName.clean(trimmed, title: true)   // pipes (build 153) en labels in hoofdletters (build 149)
        s = stripPrefixes(s)
        let y = extractYear(s)
        let title = tidy(y.title)
        return (title.isEmpty ? trimmed : title, y.year)
    }
}

// MARK: - Inhoudssleutels voor "gezien"

enum WatchKeys {
    /// Titel-normalisatie (contract stap 1–4): jaartal tussen haakjes achteraan weg, NFKD, diakritische tekens weg,
    /// kleine letters, `&` → "and", `+` → "plus", alleen letters en cijfers (elk schrift).
    static func norm(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // jaartal tussen haakjes achteraan
        if let last = s.last, last == ")" || last == "]" {
            let open: Character = last == ")" ? "(" : "["
            if let start = s.lastIndex(of: open) {
                let inner = s[s.index(after: start)..<s.index(before: s.endIndex)]
                if inner.count == 4, inner.allSatisfy({ $0.isASCII && $0.isNumber }),
                   s[..<start].contains(where: { $0.isLetter || $0.isNumber }) {
                    s = String(s[..<start])
                }
            }
        }
        var v = String.UnicodeScalarView()
        for u in s.decomposedStringWithCompatibilityMapping.unicodeScalars where u.properties.generalCategory != .nonspacingMark {
            v.append(u)
        }
        let lower = String(v).lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "+", with: "plus")
        var out = String.UnicodeScalarView()
        for u in lower.unicodeScalars {
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                out.append(u)
            default: continue
            }
        }
        return String(out)
    }

    static func cleanID(_ v: String?) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != "0", t.lowercased() != "null" else { return nil }
        return t
    }
    static func cleanIMDb(_ v: String?) -> String? {
        guard let t = cleanID(v)?.lowercased(), t.hasPrefix("tt"), t.count > 2 else { return nil }
        return t
    }
    static func yearPart(_ y: Int?) -> Int {
        guard let y, TitleRules154.validYear(y) else { return 0 }
        return y
    }

    /// Titel-vorm "<norm>|<jaar>" (nil als de titel niets oplevert). `year` gaat voor het jaar uit de titel.
    static func titleForm(_ raw: String, year: Int?) -> String? {
        let c = TitleRules154.clean(raw)
        let n = norm(c.title)
        guard !n.isEmpty else { return nil }
        return "\(n)|\(yearPart(year ?? c.year))"
    }

    /// Film: `w:m:tmdb:`, `w:m:imdb:`, `w:m:t:` (alle bekende)
    static func movie(title: String, year: Int?, tmdb: String?, imdb: String?) -> [String] {
        var out: [String] = []
        if let t = cleanID(tmdb) { out.append("w:m:tmdb:\(t)") }
        if let i = cleanIMDb(imdb) { out.append("w:m:imdb:\(i)") }
        if let f = titleForm(title, year: year) { out.append("w:m:t:\(f)") }
        return out
    }

    /// Show-vormen: `tmdb:<id>`, `imdb:<tt…>`, `t:<norm>|<jaar>` (alle bekende)
    static func showForms(title: String, year: Int?, tmdb: String?, imdb: String?) -> [String] {
        var out: [String] = []
        if let t = cleanID(tmdb) { out.append("tmdb:\(t)") }
        if let i = cleanIMDb(imdb) { out.append("imdb:\(i)") }
        if let f = titleForm(title, year: year) { out.append("t:\(f)") }
        return out
    }

    static func show(title: String, year: Int?, tmdb: String?, imdb: String?) -> [String] {
        showForms(title: title, year: year, tmdb: tmdb, imdb: imdb).map { "w:s:" + $0 }
    }

    static func episode(forms: [String], season: Int?, episode: Int?) -> [String] {
        guard let s = season, let e = episode, s >= 0, e >= 0 else { return [] }
        return forms.map { "w:e:\($0)|\(s)-\(e)" }
    }

    static func episode(show: String, year: Int?, tmdb: String?, imdb: String?, season: Int?, episode e: Int?) -> [String] {
        episode(forms: showForms(title: show, year: year, tmdb: tmdb, imdb: imdb), season: season, episode: e)
    }

    /// Sleutels om op te zoeken: bij een titelsleutel met een jaar ook jaar −1 en +1; jaar 0 alleen 0.
    static func candidates(_ keys: [String]) -> [String] {
        var out: [String] = []
        for k in keys {
            out.append(k)
            guard k.hasPrefix("w:m:t:") || k.hasPrefix("w:s:t:") || k.hasPrefix("w:e:t:") else { continue }
            var parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let y = Int(parts[1]), y > 0 else { continue }
            for d in [-1, 1] {
                parts[1] = String(y + d)
                out.append(parts.joined(separator: "|"))
            }
        }
        return out
    }

    /// Gezien als één van de sleutels (met jaar ±1) in de set staat.
    static func matches(_ stored: Set<String>, keys: [String]) -> Bool {
        guard !stored.isEmpty else { return false }
        for k in candidates(keys) where stored.contains(k) { return true }
        return false
    }

    /// Uitvinken: alle sleutels van het item die in de set staan (ook met jaar ±1), plus de eigen sleutels zelf.
    static func removal(_ stored: Set<String>, ownIDs: [String], keys: [String]) -> Set<String> {
        var out = Set(ownIDs).union(keys)
        for k in candidates(keys) where stored.contains(k) { out.insert(k) }
        return out
    }

    /// Nieuwste gebeurtenis wint, over alle kandidaatsleutels van het item (id-sleutel en inhoudssleutels, titel met
    /// jaar ±1): gezien als de nieuwste tijd een toevoeging is (`present`), niet als het een verwijdering is (`removed`).
    /// Bij gelijke tijd blijft het item staan (zoals `ListMerge`). `inSet`: de lokale set; een sleutel die daarin staat maar
    /// (nog) geen `at` heeft, is net lokaal toegevoegd en dus het nieuwst; sleutels buiten de set tellen dan niet als toevoeging.
    static func latestWins(present: [String: Double], removed: [String: Double], ownIDs: [String], keys: [String],
                           inSet: Set<String>? = nil) -> Bool {
        var maxP: Double?, maxR: Double?
        for k in candidates(ownIDs + keys) {
            if let set = inSet {
                if set.contains(k) { maxP = max(maxP ?? -.infinity, present[k] ?? .infinity) }
            } else if let at = present[k] {
                maxP = max(maxP ?? -.infinity, at)
            }
            if let r = removed[k] { maxR = max(maxR ?? -.infinity, r) }
        }
        guard let p = maxP else { return false }
        guard let r = maxR else { return true }
        return p >= r
    }

    static func isContentKey(_ k: String) -> Bool { k.hasPrefix("w:") }

    /// Migratie: voor elke oude id-sleutel die bij een item hoort (`resolve` geeft zijn inhoudssleutels, nil = onbekend)
    /// de nieuwe sleutels die er nog niet zijn → de oude sleutel waarvan ze de `at` overnemen. Niets raden.
    static func migration(_ stored: Set<String>, resolve: (String) -> [String]?) -> [String: String] {
        var out: [String: String] = [:]
        for old in stored.sorted() where !isContentKey(old) {
            guard let keys = resolve(old) else { continue }
            for k in keys where !stored.contains(k) && out[k] == nil { out[k] = old }
        }
        return out
    }

    /// Serie helemaal gezien: alle uitgezonden afleveringen (Trakt `aired_episodes`, anders het aantal op de server).
    static func seriesComplete(watched: Int, aired: Int?, onServer: Int) -> Bool {
        let total = (aired ?? 0) > 0 ? aired! : onServer
        return total > 0 && watched >= total
    }
}

// MARK: - Trakt

enum TraktTokenPolicy {
    /// Verversen pas als het token minder dan 1 uur geldig is (of na een 401, zie `TraktClient`).
    static func needsRefresh(expiresAt: Date, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 3600
    }

    enum AfterFailure: Equatable {
        /// Een nieuwer token uit het account overnemen
        case adopt
        /// Het huidige token houden (nooit `trakt: null` in het account)
        case keep
    }
    /// Mislukte verversing: alleen een token uit het account dat anders is én later verloopt telt.
    /// Er is bewust geen uitkomst "wissen": alleen een bewuste uitlog zet `trakt: null`.
    static func afterFailedRefresh(local: (access: String, expiresAt: Date), account: (access: String, expiresAt: Date)?) -> AfterFailure {
        guard let a = account, a.access != local.access, a.expiresAt > local.expiresAt else { return .keep }
        return .adopt
    }
}

enum TraktBackoff {
    /// Wachttijd na `attempts` mislukte pogingen: 30 s, 1, 2, 4 … min, hooguit 30 min; `Retry-After` (429) gaat voor.
    static func delay(attempts: Int, retryAfter: Double? = nil) -> Double {
        if let r = retryAfter, r > 0 { return min(r, 3600) }
        let n = max(1, attempts)
        return min(1800, 30 * pow(2, Double(min(n - 1, 10))))
    }

    /// `Retry-After` in seconden (of als HTTP-datum)
    static func retryAfter(_ header: String?, now: Date = Date()) -> Double? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if let s = Double(h) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: h).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Eén wijziging voor Trakt in de blijvende wachtrij (`/sync/history` of `/sync/history/remove`).
struct TraktQueueEntry: Codable, Equatable {
    enum Op: String, Codable { case add, remove }
    enum Kind: String, Codable { case movie, episode }
    var op: Op
    var kind: Kind
    var tmdb: Int?
    var imdb: String?
    var title: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    /// Tijd van kijken (seconden sinds 1970), als `watched_at`
    var watchedAt: Double
    var attempts: Int = 0
    var nextAt: Double = 0

    /// Zelfde item (en dus: een nieuwere wijziging vervangt de oudere)
    var itemKey: String {
        let id = tmdb.map { "t\($0)" } ?? imdb.map { "i" + $0.lowercased() } ?? "n" + WatchKeys.norm(title ?? "") + "|\(year ?? 0)"
        return "\(kind.rawValue)|\(id)|\(season ?? -1)-\(episode ?? -1)"
    }
    var hasIDs: Bool { (tmdb ?? 0) > 0 || WatchKeys.cleanIMDb(imdb) != nil }

    /// `ids` met tmdb en/of imdb, wat bekend is
    var ids: [String: Any] {
        var d: [String: Any] = [:]
        if let t = tmdb, t > 0 { d["tmdb"] = t }
        if let i = WatchKeys.cleanIMDb(imdb) { d["imdb"] = i }
        return d
    }
}

struct TraktQueue: Codable, Equatable {
    var entries: [TraktQueueEntry] = []
    /// Laatste uitkomsten voor de diagnose (zonder tokens)
    var notFound: [String] = []

    /// Toevoegen; een eerdere wijziging aan hetzelfde item vervalt.
    mutating func enqueue(_ e: TraktQueueEntry) {
        entries.removeAll { $0.itemKey == e.itemKey }
        entries.append(e)
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
    }

    func due(now: Double) -> [TraktQueueEntry] { entries.filter { $0.nextAt <= now && $0.hasIDs } }

    mutating func remove(_ done: [TraktQueueEntry]) {
        let keys = Set(done.map { $0.itemKey + "|\($0.op.rawValue)|\($0.watchedAt)" })
        entries.removeAll { keys.contains($0.itemKey + "|\($0.op.rawValue)|\($0.watchedAt)") }
    }

    mutating func failed(_ batch: [TraktQueueEntry], now: Double, retryAfter: Double? = nil) {
        let keys = Set(batch.map(\.itemKey))
        for i in entries.indices where keys.contains(entries[i].itemKey) {
            entries[i].attempts += 1
            entries[i].nextAt = now + TraktBackoff.delay(attempts: entries[i].attempts, retryAfter: retryAfter)
        }
    }

    mutating func noteNotFound(_ names: [String]) {
        notFound = Array((names + notFound).prefix(20))
    }

    /// Body voor `/sync/history` (met `watched_at`) of `/sync/history/remove`
    static func body(_ batch: [TraktQueueEntry]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var movies: [[String: Any]] = []
        var shows: [String: (ids: [String: Any], seasons: [Int: [[String: Any]]])] = [:]
        var order: [String] = []
        for e in batch where e.hasIDs {
            let at = iso.string(from: Date(timeIntervalSince1970: e.watchedAt))
            switch e.kind {
            case .movie:
                var m: [String: Any] = ["ids": e.ids]
                if e.op == .add { m["watched_at"] = at }
                movies.append(m)
            case .episode:
                guard let s = e.season, let n = e.episode else { continue }
                let k = e.tmdb.map { "t\($0)" } ?? "i" + (e.imdb ?? "")
                if shows[k] == nil { shows[k] = (e.ids, [:]); order.append(k) }
                var ep: [String: Any] = ["number": n]
                if e.op == .add { ep["watched_at"] = at }
                shows[k]!.seasons[s, default: []].append(ep)
            }
        }
        var out: [String: Any] = [:]
        if !movies.isEmpty { out["movies"] = movies }
        if !order.isEmpty {
            out["shows"] = order.map { k -> [String: Any] in
                let x = shows[k]!
                return ["ids": x.ids,
                        "seasons": x.seasons.keys.sorted().map { ["number": $0, "episodes": x.seasons[$0]!] as [String: Any] }]
            }
        }
        return out
    }

    /// Welke items uit de batch Trakt niet kent (`not_found` in het antwoord), op id.
    static func notFound(in response: [String: Any], batch: [TraktQueueEntry]) -> [TraktQueueEntry] {
        guard let nf = response["not_found"] as? [String: Any] else { return [] }
        var tmdbs = Set<Int>(), imdbs = Set<String>()
        for k in ["movies", "shows", "episodes"] {
            for x in (nf[k] as? [[String: Any]]) ?? [] {
                let ids = (x["ids"] as? [String: Any]) ?? [:]
                if let t = ids["tmdb"] as? Int { tmdbs.insert(t) }
                if let t = ids["tmdb"] as? String, let i = Int(t) { tmdbs.insert(i) }
                if let i = ids["imdb"] as? String { imdbs.insert(i.lowercased()) }
            }
        }
        return batch.filter { e in
            (e.tmdb.map { tmdbs.contains($0) } ?? false) || (e.imdb.map { imdbs.contains($0.lowercased()) } ?? false)
        }
    }

    // MARK: bewaren (overleeft een herstart)

    static func load(_ url: URL) -> TraktQueue {
        guard let d = try? Data(contentsOf: url), let q = try? JSONDecoder().decode(TraktQueue.self, from: d) else { return TraktQueue() }
        return q
    }
    func save(_ url: URL) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

enum TraktMatch {
    /// Een zoektreffer telt alleen met de juiste titel (norm) en het juiste jaar (±1). Zonder jaar alleen de titel.
    static func accept(title: String, year: Int?, hitTitle: String?, hitYear: Int?) -> Bool {
        guard let ht = hitTitle else { return false }
        let a = WatchKeys.norm(TitleRules154.clean(title).title), b = WatchKeys.norm(ht)
        guard !a.isEmpty, a == b else { return false }
        guard let y = year, y > 0 else { return true }
        guard let hy = hitYear else { return false }
        return abs(hy - y) <= 1
    }

    /// Beste treffer: de eerste die klopt; zonder jaar alleen als er precies één klopt.
    static func pick<T>(_ hits: [T], title: String, year: Int?, hitTitle: (T) -> String?, hitYear: (T) -> Int?) -> T? {
        let ok = hits.filter { accept(title: title, year: year, hitTitle: hitTitle($0), hitYear: hitYear($0)) }
        if year == nil || year == 0 { return ok.count == 1 ? ok[0] : nil }
        return ok.first
    }
}

/// Gezien-grens (zelfde als lokaal): 85%, of meer dan 70% met minder dan 3 minuten over, of in de aftiteling.
enum WatchedThreshold {
    static func reached(position: Double, duration: Double, currentTime: Double, inCredits: Bool = false) -> Bool {
        let left = duration - currentTime
        return position >= 0.85 || (duration > 600 && left < 180 && position > 0.7) || (inCredits && position > 0.5)
    }
}
