import Foundation

/// Dezelfde film of serie in een andere taal in de bibliotheek, bijv. "Animal (IT)" en "Animal (NL)" (build 59).
struct LanguageVersion: Identifiable, Hashable {
    var target: DetailTarget
    var language: ContentLanguage?
    /// Categorie, om twee versies in dezelfde taal uit elkaar te houden
    var group: String

    var id: String { target.id }
    /// Kort: "IT", "EN · NL ondertitels", of "Taal onbekend"
    var label: String { language?.banner ?? L("Language unknown") }
    /// Voor in een lijst: "Italiaans", "Engels (origineel) · Ondertitels: Nederlands"
    var name: String { language?.detailText ?? L("Language unknown") }
}

/// Zoekt andere-taalversies: op TMDB-id als dat van beide bekend is, anders op opgeschoonde titel + jaar.
/// De index wordt één keer per bibliotheek op de achtergrond gebouwd.
@MainActor
final class LanguageVersions {
    static let shared = LanguageVersions()

    private struct Index: Sendable {
        var movies: [String: [Int]] = [:]
        var series: [String: [Int]] = [:]
    }
    private var key = ""
    private var index: Index?
    private var building: Task<Index, Never>?

    nonisolated static func norm(_ title: String) -> String { TitleMatcher.norm(ContentLanguage.searchTitle(title)) }

    private func index(for lib: Library, key k: String) async -> Index {
        if k == key, let index { return index }
        if k == key, let building { return await building.value }
        key = k
        index = nil
        let movies = lib.movies.map(\.title), series = lib.series.map(\.title)
        let t = Task.detached(priority: .userInitiated) { () -> Index in
            var idx = Index()
            for (i, t) in movies.enumerated() { let n = Self.norm(t); if n.count > 1 { idx.movies[n, default: []].append(i) } }
            for (i, t) in series.enumerated() { let n = Self.norm(t); if n.count > 1 { idx.series[n, default: []].append(i) } }
            return idx
        }
        building = t
        let r = await t.value
        if key == k { index = r; building = nil }
        return r
    }

    /// Andere-taalversies van deze titel (zonder de titel zelf), voorkeurstaal eerst.
    func versions(of target: DetailTarget, in lib: Library, key k: String) async -> [LanguageVersion] {
        let idx = await index(for: lib, key: k)
        var out: [LanguageVersion] = []
        switch target {
        case .movie(let m):
            let mine = ContentLanguage.of(m)
            let year = m.year ?? TitleCleaner.parse(m.title).year
            for i in idx.movies[Self.norm(m.title)] ?? [] where i < lib.movies.count {
                let o = lib.movies[i]
                guard o.id != m.id, sameTitle(m.id, o.id, year, o.year ?? TitleCleaner.parse(o.title).year) else { continue }
                let l = ContentLanguage.of(o)
                if Self.differs(l, mine) { out.append(LanguageVersion(target: .movie(o), language: l, group: o.group)) }
            }
        case .series(let s):
            let mine = ContentLanguage.of(s)
            let year = s.year ?? TitleCleaner.parse(s.title).year
            for i in idx.series[Self.norm(s.title)] ?? [] where i < lib.series.count {
                let o = lib.series[i]
                guard o.id != s.id, sameTitle(s.id, o.id, year, o.year ?? TitleCleaner.parse(o.title).year) else { continue }
                let l = ContentLanguage.of(o)
                if Self.differs(l, mine) { out.append(LanguageVersion(target: .series(o), language: l, group: o.group)) }
            }
        }
        let pref = TrackPreferences.preferredAudio
        return out.sorted { a, b in
            let pa = a.language?.audioBase == pref, pb = b.language?.audioBase == pref
            if pa != pb { return pa }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// Zelfde titel? TMDB-id's (als beide bekend) beslissen; anders het jaar (±1, of onbekend).
    private func sameTitle(_ a: String, _ b: String, _ ya: Int?, _ yb: Int?) -> Bool {
        let facts = ContentLanguage.Facts.shared
        if let ta = facts.tmdbID(a), let tb = facts.tmdbID(b) { return ta == tb }
        guard let ya, let yb else { return true }
        return abs(ya - yb) <= 1
    }

    /// Een andere taal: het label verschilt (een versie zonder label telt mee als de andere er wel een heeft).
    nonisolated static func differs(_ a: ContentLanguage?, _ b: ContentLanguage?) -> Bool {
        func sig(_ l: ContentLanguage?) -> String? {
            guard let l, !l.isEmpty else { return nil }
            return "\(l.audioBase ?? "-")|\(l.subtitlesBase ?? "-")|\(l.multi)|\(l.dual)"
        }
        let sa = sig(a), sb = sig(b)
        if sa == nil && sb == nil { return false }
        return sa != sb
    }
}
