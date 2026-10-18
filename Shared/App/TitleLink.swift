import Foundation

/// Link naar een film of serie (build 120), uit de wekelijkse e-mail van Bingr:
/// - universele link `https://bingr.online/titel/?type=movie|tv&id=<tmdb-id>&q=<titel>&y=<jaar>`
/// - custom scheme `bingr://title?type=&id=&q=&y=` (fallbackknop op die pagina)
/// De app zoekt de titel in de bibliotheek van de actieve bron: eerst op TMDB-id (als de items die kennen), anders op
/// titel (+ jaar). Eén goede match → detailpagina, anders het zoekscherm met de titel ingevuld.
struct TitleLink: Equatable, Sendable {
    enum Kind: String, Sendable { case movie, tv }

    var kind: Kind?
    var tmdbID: Int?
    var query: String
    var year: Int?

    /// `nil` als de URL geen titel-link is (of niets bruikbaars bevat).
    static func parse(_ url: URL) -> TitleLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https", "http":
            let host = (c.host ?? "").lowercased()
            guard host == "bingr.online" || host == "www.bingr.online" else { return nil }
            let path = c.path.lowercased()
            guard path == "/titel" || path.hasPrefix("/titel/") else { return nil }
        case "bingr":
            // bingr://title?… (host) of bingr:title?… (pad)
            let target = (c.host?.isEmpty == false ? c.host! : c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
            guard target == "title" || target == "titel" else { return nil }
        default:
            return nil
        }
        func q(_ name: String) -> String? {
            let v = c.queryItems?.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        var link = TitleLink(kind: nil, tmdbID: nil, query: "", year: nil)
        switch q("type")?.lowercased() {
        case "movie", "film": link.kind = .movie
        case "tv", "series", "serie", "show": link.kind = .tv
        default: break
        }
        if let id = q("id").flatMap(Int.init), id > 0 { link.tmdbID = id }
        // URLComponents decodeert %xx al; een "+" uit een formulier-encoding is een spatie
        link.query = String((q("q") ?? "").replacingOccurrences(of: "+", with: " ").prefix(200))
        if let y = q("y").flatMap({ Int($0.prefix(4)) }), (1870...2200).contains(y) { link.year = y }
        guard !link.query.isEmpty || link.tmdbID != nil else { return nil }
        return link
    }

    /// Build 132: de eigen deellink (deelknop op de detailpagina): spiegel van `parse(_:)`, dus
    /// `https://bingr.online/titel/?type=movie|tv&id=<tmdb-id>&q=<titel>&y=<jaar>` (of `bingr://title?…`). Waarden
    /// strikt percent-encoded (ook `+`, `&`, `=`, `#`), zodat parse() precies dezelfde titel terugleest. Zonder titel én
    /// zonder TMDB-id: nil (parse() zou hem ook weigeren).
    func shareURL(scheme: String = "https") -> URL? {
        let title = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let id = tmdbID.flatMap { $0 > 0 ? $0 : nil }
        guard !title.isEmpty || id != nil else { return nil }
        var parts: [String] = []
        if let kind { parts.append("type=\(kind.rawValue)") }
        if let id { parts.append("id=\(id)") }
        if !title.isEmpty { parts.append("q=\(Self.encode(title))") }
        if let year, (1870...2200).contains(year) { parts.append("y=\(year)") }
        let base = scheme.lowercased() == "bingr" ? "bingr://title" : "https://bingr.online/titel/"
        return URL(string: base + "?" + parts.joined(separator: "&"))
    }

    static func shareURL(kind: Kind, tmdbID: Int?, title: String, year: Int?) -> URL? {
        TitleLink(kind: kind, tmdbID: tmdbID, query: title, year: year).shareURL()
    }

    /// Alleen RFC 3986-"unreserved" ongemoeid; de rest (spatie → %20, + → %2B, & → %26, …) gecodeerd.
    private static let unreserved: CharacterSet = {
        var c = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        c.insert(charactersIn: "-._~")
        return c
    }()
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    enum Resolution: Sendable { case detail(DetailTarget), search(String) }

    /// Zoekt de titel in de (gefilterde) bibliotheek. Zwaar bij grote lijsten: buiten de hoofdthread aanroepen.
    static func resolve(_ link: TitleLink, movies: [Movie], series: [Series], preferredAudio pref: String) -> Resolution {
        let lookMovies = link.kind != .tv, lookSeries = link.kind != .movie
        let facts = ContentLanguage.Facts.shared
        // 1. TMDB-id (Xtream "tmdb", of wat de detailpagina eerder bij TMDB vond)
        if let id = link.tmdbID {
            let m = lookMovies ? movies.filter { ($0.tmdbID ?? facts.tmdbID($0.id)) == id } : []
            let s = lookSeries ? series.filter { ($0.tmdbID ?? facts.tmdbID($0.id)) == id } : []
            if let t = pick(m.map(DetailTarget.movie) + s.map(DetailTarget.series), pref) { return .detail(t) }
        }
        // 2. titel (+ jaar), genormaliseerd zoals de rest van de app (taallabels en jaartal uit de titel weg)
        let wanted = TitleMatcher.norm(link.query)
        let wantedClean = TitleMatcher.norm(TitleCleaner.parse(link.query).title)
        guard wanted.count > 1 || wantedClean.count > 1 else { return .search(link.query) }
        func same(_ raw: String) -> Bool {
            let n = TitleMatcher.norm(TitleCleaner.parse(raw).title)
            return n.count > 1 && (n == wanted || n == wantedClean)
        }
        var strong: [DetailTarget] = [], weak: [DetailTarget] = []
        func consider(_ t: DetailTarget, title: String, year: Int?) {
            guard same(title) else { return }
            let y = year ?? TitleCleaner.parse(title).year
            if let want = link.year {
                if let y { if abs(y - want) <= 1 { strong.append(t) } } else { weak.append(t) }
            } else {
                weak.append(t)
            }
        }
        if lookMovies { for m in movies { consider(.movie(m), title: m.title, year: m.year) } }
        if lookSeries { for s in series { consider(.series(s), title: s.title, year: s.year) } }
        if let t = pick(strong, pref) { return .detail(t) }
        // zonder (passend) jaar alleen als het er precies één is: anders kan het een andere titel met dezelfde naam zijn
        if strong.isEmpty, weak.count == 1 { return .detail(weak[0]) }
        return .search(link.query)
    }

    /// Eén titel, eventueel in meerdere taalversies (de detailpagina toont de andere versies zelf): de versie in de
    /// voorkeurstaal, anders de eerste. Films én series met dezelfde match = niet eenduidig.
    private static func pick(_ list: [DetailTarget], _ pref: String) -> DetailTarget? {
        guard let first = list.first else { return nil }
        let movies = list.filter { if case .movie = $0 { return true }; return false }
        guard movies.isEmpty || movies.count == list.count else { return nil }
        let preferred = list.first { t in
            switch t {
            case .movie(let m): return ContentLanguage.of(m)?.audioBase == pref
            case .series(let s): return ContentLanguage.of(s)?.audioBase == pref
            }
        }
        return preferred ?? first
    }
}
