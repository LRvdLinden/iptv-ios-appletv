import Foundation

// Build 172: categorieën slim samenvoegen ("Categorieën opschonen"), pure logica (alleen Foundation), ook los gebouwd in
// de zelftest van CI (tools/selftest/main.swift). Dezelfde regels als Android (Build172Logic.kt) en web
// (web/js/catmerge.js); vaste testgevallen in docs/merge_cases.json.
//
// Opslag: precies het bestaande formaat van `Customization`: `merged[bron] = doelgroep`, een doelnaam als
// `renamed["group:<doel>"]` en de volgorde in `groupOrder`. Oudere apps zien het samenvoegen dus ook.

enum CategoryCleanup172 {
    struct Group: Equatable, Sendable {
        var name: String
        var count: Int
    }

    enum Kind: String, Sendable { case brand, country, prefix }

    struct Suggestion: Identifiable, Equatable, Sendable {
        var id: String
        var kind: Kind
        /// Doelnaam ("Netflix"); aan te passen
        var target: String
        /// De groep waarin de andere worden samengevoegd
        var targetGroup: String
        /// Groepen in volgorde (de doelgroep hoort erbij)
        var groups: [String]
        var counts: [String: Int]
        var total: Int
        /// Standaard aangevinkt
        var on: Bool
        /// Groepen met een eigen naam van de gebruiker (waarschuwing)
        var renamed: [String]
    }

    /// Het bestaande formaat van `Customization` (alleen wat samenvoegen raakt)
    struct Custom: Equatable, Sendable {
        var merged: [String: String] = [:]
        var renamed: [String: String] = [:]
        var groupOrder: [String] = []
    }

    struct Brand: Sendable {
        let id: String
        let name: String
        let on: Bool
        let aliases: [String]
    }

    /// Merken en diensten (makkelijk uit te breiden). `!` = streng: alleen de hele naam of de naam + soortwoorden.
    static let brands: [Brand] = [
        Brand(id: "netflix", name: "Netflix", on: true, aliases: ["netflix"]),
        Brand(id: "disneyplus", name: "Disney+", on: true, aliases: ["disney plus"]),
        Brand(id: "hulu", name: "Hulu", on: true, aliases: ["hulu"]),
        Brand(id: "primevideo", name: "Prime Video", on: true, aliases: ["prime video", "amazon prime video", "amazon prime", "amazon video", "amazon"]),
        Brand(id: "hbomax", name: "HBO Max", on: true, aliases: ["hbo max", "hbo", "!max"]),
        Brand(id: "appletvplus", name: "Apple TV+", on: true, aliases: ["apple tv plus"]),
        Brand(id: "paramountplus", name: "Paramount+", on: true, aliases: ["paramount plus"]),
        Brand(id: "peacock", name: "Peacock", on: true, aliases: ["peacock"]),
        Brand(id: "videoland", name: "Videoland", on: true, aliases: ["videoland"]),
        Brand(id: "viaplay", name: "Viaplay", on: true, aliases: ["viaplay"]),
        Brand(id: "skyshowtime", name: "SkyShowtime", on: true, aliases: ["skyshowtime"]),
        Brand(id: "nlziet", name: "NLZIET", on: true, aliases: ["nlziet"]),
        Brand(id: "npo", name: "NPO", on: true, aliases: ["npo start", "npo plus", "npo"]),
        Brand(id: "discoveryplus", name: "Discovery+", on: true, aliases: ["discovery plus"]),
        Brand(id: "canalplus", name: "Canal+", on: true, aliases: ["canal plus"]),
        // Sky: wel als merk, maar standaard uit (Sky Sports, Sky Cinema en Sky News blijven vaak bewust apart)
        Brand(id: "sky", name: "Sky", on: false, aliases: ["sky"]),
        Brand(id: "bbciplayer", name: "BBC iPlayer", on: true, aliases: ["bbc iplayer"]),
        Brand(id: "itvx", name: "ITVX", on: true, aliases: ["itvx"]),
        Brand(id: "crunchyroll", name: "Crunchyroll", on: true, aliases: ["crunchyroll"]),
        Brand(id: "starz", name: "Starz", on: true, aliases: ["starz"]),
        Brand(id: "showtime", name: "Showtime", on: true, aliases: ["showtime"]),
        Brand(id: "amcplus", name: "AMC+", on: true, aliases: ["amc plus"]),
        Brand(id: "hallmark", name: "Hallmark", on: true, aliases: ["hallmark"]),
        Brand(id: "pathethuis", name: "Pathé Thuis", on: true, aliases: ["pathe thuis"]),
        Brand(id: "streamz", name: "Streamz", on: true, aliases: ["streamz"]),
        Brand(id: "vtmgo", name: "VTM GO", on: true, aliases: ["vtm go"]),
        Brand(id: "rtlplus", name: "RTL+", on: true, aliases: ["rtl plus"]),
        Brand(id: "joyn", name: "Joyn", on: true, aliases: ["joyn"]),
    ]

    private static func set(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let pipes: Set<Character> = Set("¦│┃｜‖∣丨┆┇┊┋╎╏︱︳⏐⎮▏▕ǀ׀⼁∥❘❙❚￨")
    private static let codes = set("nl be uk us en de fr es it tr pl pt ar gb nld dut eng deu ger fra fre ita spa esp tur pol por ara int eu ca au " +
        "ie se no dk fi ch at in br mx ru gr ro al ma rs hr ba bg hu cz sk si ua il ir pk ph th vn jp kr cn hk za eg sa ae " +
        "lu is nz lat latam exyu")
    private static let spaced = set("nl be uk us en de fr es tr pl pt ar gb nld eng deu ger fra ita spa tur pol por ara")
    private static let canon: [String: String] = ["eng": "en", "gb": "uk", "nld": "nl", "dut": "nl", "deu": "de", "ger": "de", "fra": "fr",
                                                  "fre": "fr", "ita": "it", "spa": "es", "esp": "es", "tur": "tr", "pol": "pl", "por": "pt", "ara": "ar"]
    private static let quality = set("4k 8k uhd fhd hd sd hevc h265 h264 x265 x264 60fps 50fps hdr hdr10 fullhd 1080p 720p 2160p")
    private static let tags = set("multi vip vod sub subs dub dubbed subbed")
    static let typeWords = set("films film movies movie series serie documentaires documentaire documentaries documentary docs doc kids " +
        "kinderen anime comedy drama action actie horror thriller romance sci fi scifi collection collectie originals specials " +
        "nl en dubbed subbed gesproken ondertiteld")
    private static let skip = set("vod films film movies movie series serie tv shows top new nieuw all alle")
    private static let generic = set("nl uk us en be de movies movie films film series serie kids new nieuw top best 4k vod live tv the het een " +
        "a all alle hd")
    private static let lead: Set<Character> = Set(" \t|:-–—*•·#~_=»>/.,")
    private static let openers: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
    private static let closers: [Character: Character] = ["]": "[", ")": "(", "}": "{"]
    private static let seps: Set<Character> = ["|", ":", "-", "–", "—"]

    private static func isAZ(_ c: Character) -> Bool { guard let a = c.asciiValue else { return false }; return a >= 97 && a <= 122 }
    private static func isAN(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (a >= 97 && a <= 122) || (a >= 48 && a <= 57)
    }

    private static func words(_ s: ArraySlice<Character>) -> [String] {
        var out: [String] = [], cur = ""
        for c in s {
            if isAN(c) { cur.append(c) } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    private static func words(_ s: String) -> [String] { words(ArraySlice(Array(s))) }

    private static func canonical(_ w: String) -> String { canon[w] ?? w }

    /// Inhoud tussen haken een label? nil = nee; "" = ja zonder land; anders het land.
    private static func tagLike(_ inner: ArraySlice<Character>) -> String? {
        let w = words(inner)
        guard !w.isEmpty else { return nil }
        for x in w where !codes.contains(x) && !tags.contains(x) && !quality.contains(x) { return nil }
        for x in w where codes.contains(x) { return canonical(x) }
        return ""
    }

    private static func trimLead(_ s: ArraySlice<Character>) -> ArraySlice<Character> {
        var i = s.startIndex
        while i < s.endIndex, lead.contains(s[i]) { i += 1 }
        return s[i...]
    }
    private static func trimTail(_ s: ArraySlice<Character>) -> ArraySlice<Character> {
        var i = s.endIndex
        while i > s.startIndex, lead.contains(s[i - 1]) { i -= 1 }
        return s[..<i]
    }

    private static func isYear(_ t: String) -> Bool {
        guard t.count == 4, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return t.hasPrefix("19") || t.hasPrefix("20")
    }
    private static func isDigits(_ t: String) -> Bool { !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isNumber } }

    /// Naam → woorden en land. Kleine letters, zonder accenten, pipes als "|", "+" als "plus", land-/taalvoorvoegsels
    /// en -achtervoegsels (met scheidingsteken of haken) en kwaliteitslabels weg.
    static func norm(_ raw: String) -> (tokens: [String], country: String) {
        var t = ""
        for c in raw { t.append(pipes.contains(c) ? "|" : c) }
        let d = t.decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for u in d.unicodeScalars where !(u.value >= 0x300 && u.value <= 0x36F) { scalars.append(u) }
        let low = String(scalars).lowercased().replacingOccurrences(of: "+", with: " plus ")
        let all = Array(low)
        var s = all[...]
        var country = ""
        func note(_ c: String) { if country.isEmpty && !c.isEmpty { country = c } }
        for _ in 0..<6 {
            s = trimLead(s)
            guard let c0 = s.first else { break }
            if let closer = openers[c0] {
                if let close = s.dropFirst().firstIndex(of: closer),
                   let tag = tagLike(s[(s.startIndex + 1)..<close]), !trimLead(s[(close + 1)...]).isEmpty {
                    note(tag); s = s[(close + 1)...]; continue
                }
                break
            }
            var k = s.startIndex
            while k < s.endIndex, isAN(s[k]) { k += 1 }
            let w = String(s[s.startIndex..<k]), len = k - s.startIndex
            var r = k
            while r < s.endIndex, s[r] == " " { r += 1 }
            if len >= 2, r < s.endIndex, seps.contains(s[r]) || s[r] == "]" || s[r] == ")", !trimLead(s[(r + 1)...]).isEmpty {
                if len <= 3, codes.contains(w), let f = w.first, isAZ(f) { note(canonical(w)); s = s[(r + 1)...]; continue }
                if tags.contains(w) || quality.contains(w) { s = s[(r + 1)...]; continue }
            }
            break
        }
        for _ in 0..<4 {
            s = trimTail(s)
            guard let cl = s.last else { break }
            if let opener = closers[cl] {
                let body = s[s.startIndex..<(s.endIndex - 1)]
                if let op = body.lastIndex(of: opener),
                   let tg = tagLike(s[(op + 1)..<(s.endIndex - 1)]), !trimTail(s[s.startIndex..<op]).isEmpty {
                    note(tg); s = s[s.startIndex..<op]; continue
                }
                break
            }
            var e = s.endIndex
            while e > s.startIndex, isAN(s[e - 1]) { e -= 1 }
            let tw = String(s[e..<s.endIndex]), len = s.endIndex - e
            var q = e
            while q > s.startIndex, s[q - 1] == " " { q -= 1 }
            if len >= 2, q > s.startIndex, seps.contains(s[q - 1]), !trimTail(s[s.startIndex..<(q - 1)]).isEmpty {
                if len <= 3, codes.contains(tw), let f = tw.first, isAZ(f) { note(canonical(tw)); s = s[s.startIndex..<(q - 1)]; continue }
                if tags.contains(tw) || quality.contains(tw) { s = s[s.startIndex..<(q - 1)]; continue }
            }
            break
        }
        let tokens = words(s).filter { !quality.contains($0) }
        if tokens.count > 1, let last = tokens.last, spaced.contains(last) { note(canonical(last)) }
        return (tokens, country)
    }

    private struct Alias: Sendable { let brand: Int; let compact: String; let strict: Bool }
    private static let aliases: [Alias] = {
        var out: [Alias] = []
        for (i, b) in brands.enumerated() {
            for a in b.aliases {
                let strict = a.hasPrefix("!")
                out.append(Alias(brand: i, compact: words(strict ? String(a.dropFirst()) : a).joined(), strict: strict))
            }
        }
        return out
    }()

    private static func matchFrom(_ tokens: [String], _ start: Int) -> Int? {
        var compact = ""
        var endIdx: [Int: Int] = [:]
        for i in start..<tokens.count { compact += tokens[i]; endIdx[compact.utf8.count] = i + 1 }
        let bytes = Array(compact.utf8)
        var best: (brand: Int, len: Int)?
        for al in aliases {
            let a = Array(al.compact.utf8), l = a.count
            guard let end = endIdx[l], bytes.count >= l, Array(bytes[0..<l]) == a else { continue }
            if al.strict, tokens[end...].contains(where: { !typeWords.contains($0) && !spaced.contains($0) }) { continue }
            if best == nil || l > best!.len { best = (al.brand, l) }
        }
        return best?.brand
    }

    /// Merk van genormaliseerde woorden: index in `brands` (of nil) en het land van een overgeslagen code vooraan.
    private static func brandOf(tokens t: [String]) -> (brand: Int?, country: String) {
        guard !t.isEmpty else { return (nil, "") }
        if let b = matchFrom(t, 0) { return (b, "") }
        var s = 0, c = ""
        while s < t.count - 1, skip.contains(t[s]) || spaced.contains(t[s]) {
            if c.isEmpty, spaced.contains(t[s]) { c = canonical(t[s]) }
            s += 1
        }
        if s > 0, let b = matchFrom(t, s) { return (b, c) }
        return (nil, "")
    }

    /// Merk-id van een categorienaam (nil = geen merk)
    static func brandOf(_ raw: String) -> String? { brandOf(tokens: norm(raw).tokens).brand.map { brands[$0].id } }

    private static func stemOK(_ st: ArraySlice<String>) -> Bool {
        guard let first = st.first, !generic.contains(first), !codes.contains(first) else { return false }
        return !st.contains { typeWords.contains($0) || isYear($0) || isDigits($0) }
    }

    private static func titleCase(_ st: [String]) -> String {
        st.map { w -> String in
            if w.count <= 3 && !w.contains(where: { "aeiouy".contains($0) }) { return w.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    private final class Item {
        let name: String, idx: Int, tokens: [String], ncountry: String, count: Int
        var country = ""
        init(name: String, idx: Int, tokens: [String], ncountry: String, count: Int) {
            self.name = name; self.idx = idx; self.tokens = tokens; self.ncountry = ncountry; self.count = count
        }
    }

    /// Voorstellen voor één server en één soort (Live TV, Films of Series). Op de achtergrond aanroepen.
    static func suggest(groups: [Group], merged: [String: String] = [:], renamed: [String: String] = [:],
                        hidden: Set<String> = [], ignored: Set<String> = []) -> [Suggestion] {
        var countOf: [String: Int] = [:]
        for g in groups { countOf[g.name, default: 0] += g.count }
        var isTarget = Set<String>(), extra: [String: Int] = [:]
        for (src, tgt) in merged where tgt != src {
            isTarget.insert(tgt)
            extra[tgt, default: 0] += countOf[src] ?? 0
        }
        var list: [Item] = [], seen = Set<String>()
        for g in groups {
            let n = g.name
            if seen.contains(n) || hidden.contains(n) { continue }
            if let m = merged[n], m != n { continue }
            seen.insert(n)
            let nm = norm(n)
            if nm.tokens.isEmpty { continue }
            list.append(Item(name: n, idx: list.count, tokens: nm.tokens, ncountry: nm.country, count: (countOf[n] ?? 0) + (extra[n] ?? 0)))
        }
        var out: [(s: Suggestion, o0: Int, o1: Int)] = []
        var claimed = Set<String>()
        func make(_ kind: Kind, _ id: String, _ target: String, _ gs: [Item], _ on: Bool) -> Suggestion {
            var tg = gs[0].name
            if kind != .country, let t = gs.first(where: { isTarget.contains($0.name) }) { tg = t.name }
            var counts: [String: Int] = [:], total = 0, ren: [String] = []
            for g in gs {
                counts[g.name] = g.count; total += g.count
                if renamed["group:" + g.name] != nil { ren.append(g.name) }
            }
            return Suggestion(id: id, kind: kind, target: target, targetGroup: tg, groups: gs.map(\.name), counts: counts,
                              total: total, on: on, renamed: ren)
        }
        // 1. merken
        var byBrand: [Int: [Item]] = [:], brandOrder: [Int] = []
        for g in list {
            let b = brandOf(tokens: g.tokens)
            guard let bi = b.brand else { continue }
            g.country = g.ncountry.isEmpty ? b.country : g.ncountry
            if byBrand[bi] == nil { byBrand[bi] = []; brandOrder.append(bi) }
            byBrand[bi]!.append(g)
        }
        for bi in brandOrder {
            let gs = byBrand[bi]!, br = brands[bi]
            guard gs.count >= 2 else { continue }
            for g in gs { claimed.insert(g.name) }
            var countries: [String] = [], per: [String: Int] = [:]
            for g in gs where !g.country.isEmpty {
                if per[g.country] == nil { per[g.country] = 0; countries.append(g.country) }
                per[g.country]! += 1
            }
            var sugg: [(Suggestion, Int, Int)] = []
            if countries.count <= 1 {
                sugg.append((make(.brand, "brand:" + br.id, br.name, gs, br.on), gs[0].idx, 0))
            } else {
                var dom = countries[0]
                for c in countries where per[c]! > per[dom]! { dom = c }
                let main = gs.filter { $0.country.isEmpty || $0.country == dom }
                let rest = gs.filter { !$0.country.isEmpty && $0.country != dom }
                if main.count >= 2 {
                    let ms = make(.brand, "brand:" + br.id, br.name, main, br.on)
                    sugg.append((ms, main[0].idx, 0))
                    let head = main.filter { $0.name == ms.targetGroup }
                    sugg.append((make(.country, "country:" + br.id, br.name, head + rest, false), main[0].idx, 1))
                } else {
                    sugg.append((make(.country, "country:" + br.id, br.name, main + rest, false), gs[0].idx, 1))
                }
            }
            for x in sugg where !ignored.contains(x.0.id) { out.append((s: x.0, o0: x.1, o1: x.2)) }
        }
        // 2. zelfde begin
        final class Bucket { let st: [String]; let first: Int; var items: [(g: Item, cont: Bool)] = []
            init(st: [String], first: Int) { self.st = st; self.first = first } }
        var buckets: [String: Bucket] = [:], bucketList: [Bucket] = []
        for g in list where !claimed.contains(g.name) {
            let t = g.tokens
            var cands: [([String], Bool)] = []
            for k in stride(from: 2, through: 1, by: -1) where t.count > k && typeWords.contains(t[k]) && stemOK(t[0..<k]) {
                cands.append((Array(t[0..<k]), true))
            }
            if t.count <= 2 && stemOK(t[...]) { cands.append((t, false)) }
            for (st, cont) in cands {
                let key = st.joined(separator: " ")
                let b: Bucket
                if let x = buckets[key] { b = x } else { b = Bucket(st: st, first: g.idx); buckets[key] = b; bucketList.append(b) }
                if !b.items.contains(where: { $0.g === g }) { b.items.append((g, cont)) }
            }
        }
        bucketList.sort { a, b in a.st.count != b.st.count ? a.st.count > b.st.count : a.first < b.first }
        var used = Set<String>()
        for b in bucketList {
            var items = b.items.filter { !used.contains($0.g.name) }
            guard items.count >= 2, items.contains(where: { $0.cont }) else { continue }
            items.sort { $0.g.idx < $1.g.idx }
            for x in items { used.insert(x.g.name) }
            let id = "prefix:" + b.st.joined(separator: "-")
            if ignored.contains(id) { continue }
            let gs = items.map { $0.g }
            out.append((s: make(.prefix, id, titleCase(b.st), gs, false), o0: gs[0].idx, o1: 2))
        }
        // stabiel sorteren op (eerste groep, soort)
        return out.enumerated().sorted { a, b in
            if a.element.o0 != b.element.o0 { return a.element.o0 < b.element.o0 }
            if a.element.o1 != b.element.o1 { return a.element.o1 < b.element.o1 }
            return a.offset < b.offset
        }.map { $0.element.s }
    }

    /// Samenvoegen in het bestaande formaat. `groups`: de aangevinkte groepen (in volgorde); doel = `targetGroup` als die
    /// aangevinkt is, anders de eerste. `cleanName`: hoe het doel zonder eigen naam heet (opgeschoond).
    static func apply(_ custom: Custom, groups: [String], targetGroup: String, name: String, cleanName: String) -> Custom {
        var c = custom
        guard groups.count >= 2 else { return c }
        let target = groups.contains(targetGroup) ? targetGroup : groups[0]
        for g in groups where g != target {
            c.merged[g] = target
            for (x, v) in c.merged where v == g { c.merged[x] = target }
        }
        c.merged[target] = nil
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines), key = "group:" + target
        if !nm.isEmpty && nm != cleanName { c.renamed[key] = nm } else if !nm.isEmpty && nm == cleanName { c.renamed[key] = nil }
        if !c.groupOrder.isEmpty {
            var pos = -1
            for g in groups { if let i = c.groupOrder.firstIndex(of: g), pos < 0 || i < pos { pos = i } }
            if pos >= 0 {
                let ti = c.groupOrder.firstIndex(of: target)
                if ti != pos {
                    if let ti { c.groupOrder.remove(at: ti) }
                    c.groupOrder.insert(target, at: (ti != nil && ti! < pos) ? pos - 1 : pos)
                }
            }
        }
        return c
    }

    /// Losmaken: `sources` nil = alle bronnen van `target`. Is er daarna geen bron meer en is de eigen naam van het doel
    /// een merknaam of `madeName` (door het opschonen gezet), dan gaat die eigen naam ook weg.
    static func detach(_ custom: Custom, target: String, sources: [String]?, madeName: String?) -> Custom {
        var c = custom
        for (s, t) in custom.merged where t == target && (sources == nil || sources!.contains(s)) { c.merged[s] = nil }
        let left = c.merged.values.contains(target)
        let key = "group:" + target
        if !left, let r = c.renamed[key], r == madeName || brands.contains(where: { $0.name == r }) { c.renamed[key] = nil }
        return c
    }

    /// Doelgroepen met hun bronnen (voor "Samengevoegd"), in de volgorde van `order` (de groepen van de server).
    static func mergedTargets(_ merged: [String: String], order: [String]) -> [(target: String, sources: [String])] {
        var by: [String: [String]] = [:]
        for (s, t) in merged where t != s { by[t, default: []].append(s) }
        var pos: [String: Int] = [:]
        for (i, g) in order.enumerated() where pos[g] == nil { pos[g] = i }
        func less(_ a: String, _ b: String) -> Bool {
            let pa = pos[a] ?? 1_000_000_000, pb = pos[b] ?? 1_000_000_000
            return pa != pb ? pa < pb : a < b
        }
        return by.keys.sorted(by: less).map { ($0, by[$0]!.sorted(by: less)) }
    }

    /// "12 categorieën worden 3": aantal unieke groepen en aantal unieke doelgroepen.
    static func summary(_ picks: [Suggestion]) -> (from: Int, to: Int) {
        var all = Set<String>(), tg = Set<String>()
        for p in picks { all.formUnion(p.groups); tg.insert(p.targetGroup) }
        return (all.count, tg.count)
    }

    /// Sleutel van een overgeslagen voorstel: per soort ("live", "movie", "series"), dan het id
    static func ignoreKey(section: String, id: String) -> String { section + "|" + id }
}
