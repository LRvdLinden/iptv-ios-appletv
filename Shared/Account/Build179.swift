import Foundation

/// Build 179 (versie 1.0.8): pure logica van Apple-agent A (punten 1, 3, 5, 12 en 13), gelijk op alle platforms
/// (Android `Build179Logic.kt`, web `web/js/build179.js`); gedeelde testgevallen: docs/build179_cases.json (tools/selftest).
/// Regels: docs/ACCOUNT.md → "Build 179". Alleen Foundation: de zelftest compileert dit bestand los van de app.
enum Build179 {

    // MARK: 1. Gids en servers vanzelf verversen

    enum CatalogInterval: String, CaseIterable, Identifiable {
        case sixHours = "6h", daily, threeDays = "3d", weekly, manual
        var id: String { rawValue }
        var seconds: Double? {
            switch self {
            case .sixHours: return 21600
            case .daily: return 86400
            case .threeDays: return 259200
            case .weekly: return 604800
            case .manual: return nil
            }
        }
        static func from(_ raw: String?) -> CatalogInterval { raw.flatMap(CatalogInterval.init(rawValue:)) ?? .daily }
    }

    enum GuideInterval: String, CaseIterable, Identifiable {
        case sixHours = "6h", twelveHours = "12h", daily
        var id: String { rawValue }
        var seconds: Double {
            switch self {
            case .sixHours: return 21600
            case .twelveHours: return 43200
            case .daily: return 86400
            }
        }
        static func from(_ raw: String?) -> GuideInterval { raw.flatMap(GuideInterval.init(rawValue:)) ?? .sixHours }
    }

    enum RefreshPlan: String, Equatable { case none, epg, full, blocked }

    static func due(_ interval: Double?, last: Double?, now: Double) -> Bool {
        guard let interval else { return false }
        guard let last else { return true }
        return now - last >= interval || last - now > 3600
    }

    /// Wat er nu ververst moet worden. `lastFull`/`lastEpg` in seconden (Unix), nil = nooit.
    static func refreshPlan(catalog: String?, epg: String?, lastFull: Double?, lastEpg: Double?, now: Double,
                            saver: Bool, allowCellular: Bool) -> RefreshPlan {
        let full = due(CatalogInterval.from(catalog).seconds, last: lastFull, now: now)
        let le: Double?
        if let lf = lastFull { le = max(lastEpg ?? lf, lf) } else { le = lastEpg }
        let kind: RefreshPlan = full ? .full : (due(GuideInterval.from(epg).seconds, last: le, now: now) ? .epg : .none)
        if kind != .none && saver && !allowCellular { return .blocked }
        return kind
    }

    /// Wanneer wordt er (zonder nieuwe verversing) weer iets `due`? nil = nooit (handmatig en … kan niet: de gids loopt altijd).
    static func nextDue(catalog: String?, epg: String?, lastFull: Double?, lastEpg: Double?, now: Double) -> Double {
        var t: [Double] = []
        if let i = CatalogInterval.from(catalog).seconds { t.append((lastFull ?? now) + i) }
        let le = max(lastEpg ?? 0, lastFull ?? 0)
        t.append((le > 0 ? le : now) + GuideInterval.from(epg).seconds)
        return max(now + 60, t.min() ?? now + 21600)
    }

    // MARK: 3. Automatisch een andere speler proberen

    static func firstEngine(order: [String], remembered: String?) -> String {
        if let r = remembered, order.contains(r) { return r }
        return order.first ?? ""
    }

    /// `sinceStart`, `stalled` en `played` in seconden.
    static func shouldSwitch(error: Bool, firstFrame: Bool, sinceStart: Double, stalled: Double, played: Double,
                             switched: Bool) -> Bool {
        if switched { return false }
        if error && played < 10 { return true }
        if !firstFrame && sinceStart >= 10 { return true }
        if firstFrame && stalled >= 10 && played < 30 { return true }
        return false
    }

    static func nextEngine(order: [String], current: String, switched: Bool) -> String? {
        if switched { return nil }
        return order.first { $0 != current }
    }

    /// Nieuw onthouden engine na afloop; nil = wissen.
    static func memoAfter(remembered: String?, started: String, switchedTo: String?, ok: Bool) -> String? {
        guard ok else { return nil }
        return switchedTo ?? started
    }

    /// Onthouden engines per stream (lokaal, max. 500, ouder dan 60 dagen weg)
    struct EngineMemo: Codable, Equatable {
        var e: String
        var at: Double
    }

    static let memoMax = 500
    static let memoMaxAge: Double = 60 * 86400

    static func pruneMemo(_ m: [String: EngineMemo], now: Double) -> [String: EngineMemo] {
        var out = m.filter { now - $0.value.at <= memoMaxAge }
        if out.count > memoMax {
            let keep = out.sorted { $0.value.at > $1.value.at }.prefix(memoMax)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return out
    }

    static func memoKey(server: String, live: Bool, kind: String, id: String) -> String {
        let s = server.lowercased()
        return live ? "\(s)|\(id)" : "\(s)|\(kind):\(id)"
    }

    // MARK: 5. Zaplijst

    /// Indices van de zenders die passen. `numbers[i]` = zendernummer of nil.
    static func zapSearch(_ q: String, names: [String], numbers: [Int?]) -> [Int] {
        let all = Array(names.indices)
        let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if qs.isEmpty { return all }
        if qs.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let n = Int(qs)
            let byNumber = names.indices.filter { i in n != nil && i < numbers.count && numbers[i] == n }
            if !byNumber.isEmpty { return byNumber }
            return names.indices.filter { Build176.foldString(names[$0]).replacingOccurrences(of: " ", with: "").contains(qs) }
        }
        let words = Build176.foldString(qs).split(separator: " ").map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
        if words.isEmpty { return all }
        return names.indices.filter { i in
            let n = Build176.foldString(names[i])
            return words.allSatisfy { n.contains($0) }
        }
    }

    static let favoritesTab = "*favorites"

    static func zapCategories(groups: [String], favorites: [Bool]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        if favorites.contains(true) { out.append(favoritesTab); seen.insert(favoritesTab) }
        for g in groups where !seen.contains(g) { seen.insert(g); out.append(g) }
        return out
    }

    // MARK: 12. Sorteren per categorie

    enum SortMode: String, CaseIterable, Identifiable {
        case server, name, year, added, rating
        var id: String { rawValue }
        static func from(_ raw: String?) -> SortMode { raw.flatMap(SortMode.init(rawValue:)) ?? .server }
    }

    struct SortItem: Equatable {
        var name: String
        var year: Int?
        var added: Double?
        var rating: Double?
    }

    private static let articles = ["the ", "de ", "het ", "een ", "a ", "an "]

    static func sortName(_ s: String) -> String {
        let n = Build176.foldString(s).split(separator: " ").joined(separator: " ")
        for a in articles where n.hasPrefix(a) && n.count > a.count { return String(n.dropFirst(a.count)) }
        return n
    }

    /// Volgorde (indices) voor een sortering; gelijk = volgorde van de server.
    static func sortOrder(_ items: [SortItem], mode: SortMode) -> [Int] {
        let idx = Array(items.indices)
        switch mode {
        case .server:
            return idx
        case .name:
            let keys = items.map { sortName($0.name) }
            return idx.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        case .year, .added, .rating:
            func v(_ i: Int) -> Double? {
                let x: Double?
                switch mode {
                case .year: x = items[i].year.map(Double.init)
                case .added: x = items[i].added
                default: x = items[i].rating
                }
                guard let x, x > 0 else { return nil }
                return x
            }
            let vals = idx.map(v)
            return idx.sorted { a, b in
                switch (vals[a], vals[b]) {
                case let (x?, y?): return x != y ? x > y : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a < b
                }
            }
        }
    }

    /// Sleutel in `profile.<id>.categorySort`; `server` = "*" voor de lijsten over alle servers.
    static func sortKey(server: String, kind: String, category: String) -> String {
        "\(server.lowercased())|\(kind)|\(category)"
    }

    struct SortEntry: Equatable {
        var value: String
        var at: String
    }

    /// Per sleutel de nieuwste `at` (ISO-8601, vergelijkbaar als tekst in UTC); gelijk: `a` blijft.
    static func sortMerge(_ a: [String: SortEntry], _ b: [String: SortEntry]) -> [String: SortEntry] {
        var out = a
        for (k, v) in b {
            if let cur = out[k], !(isoTime(v.at) > isoTime(cur.at)) { continue }
            out[k] = v
        }
        return out
    }

    static func isoTime(_ s: String) -> Double {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }

    // MARK: 13. Opruimen

    static func cleanupAllowed(old: Int, new: Int, complete: Bool) -> Bool {
        if !complete || new == 0 { return false }
        if old >= 100 && Double(new) < Double(old) * 0.5 { return false }
        return true
    }

    enum CleanupAction: String { case keep, remap, remove }

    static func cleanupAction(present: Bool, elsewhere: Bool) -> CleanupAction {
        if present { return .keep }
        return elsewhere ? .remap : .remove
    }
}
