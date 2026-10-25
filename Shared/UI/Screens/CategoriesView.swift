import SwiftUI

/// Categorieën aan/uit per onderdeel (Live TV, Films, Series), met snelknoppen per land/taal
/// (NL, BE, DE, TK …) die alle categorieën met dat voorvoegsel in één keer aan- of uitzetten.
/// Build 140: voor het hele account (CloudStore.hiddenCategories, "<server-id>|<categorie>", alle niet-kinderprofielen)
/// en met de categorieën van alle servers; dezelfde naam op twee servers is één regel die voor beide geldt.
///
/// Build 140, snelheid: de lijst (categorieën, servers per categorie, voorvoegsels) wordt één keer per bibliotheek op de
/// achtergrond opgebouwd, niet meer bij elke schermverversing door de hele catalogus (dat gebeurde per regel). Een tik
/// zet de schakelaar meteen om; de keuzes gaan pas na een korte pauze in één keer naar de opslag (en dus één keer
/// opnieuw filteren in plaats van per tik).
struct CategoriesView: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var kind: ManageView.Kind = .live
    @State private var filter = ""
    @State private var index = CategoryIndex()
    /// Getikt maar nog niet opgeslagen: bron (server + exacte naam) → aan
    @State private var pending: [CategoryIndex.Source: Bool] = [:]
    @State private var commitTask: Task<Void, Never>?

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }

    /// Opnieuw opbouwen als de bibliotheek van de open server of de lijst met servers verandert
    private struct IndexKey: Equatable {
        var pid: UUID?
        var counts: [Int]
        var servers: [UUID]
    }
    private var indexKey: IndexKey {
        let raw = playlists.rawLibrary
        let sk = raw.skipped
        return IndexKey(pid: pid, counts: [raw.channels.count, raw.movies.count, raw.series.count,
                                           sk?.count(.live) ?? 0, sk?.count(.movie) ?? 0, sk?.count(.series) ?? 0],
                        servers: store.playlists.map(\.id))
    }

    /// Build 150: weergavenamen (opgeschoond en samengevoegd: "| NL | NETFLIX" + "| MULTI | NETFLIX" = "Netflix")
    private var allGroups: [String] { index.groups[kind] ?? [] }

    private var groups: [String] {
        let all = allGroups
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var prefixes: [CategoryIndex.Prefix] {
        let p = index.prefixes[kind] ?? []
        guard !filter.isEmpty else { return p }
        let visible = Set(groups.flatMap { sources(of: $0) })
        return p.compactMap { x in
            let g = x.sources.filter { visible.contains($0) }
            return g.isEmpty ? nil : CategoryIndex.Prefix(code: x.code, sources: g)
        }
    }

    /// De bronnen achter een weergavenaam: per server de exacte naam (zo staan ze in het account)
    private func sources(of g: String) -> [CategoryIndex.Source] {
        if let list = index.sources[kind]?[g], !list.isEmpty { return list }
        return pid.map { [CategoryIndex.Source(server: $0, name: g)] } ?? []
    }

    private func isOn(_ x: CategoryIndex.Source, hidden: Set<String>) -> Bool {
        if let p = pending[x] { return p }
        return !hidden.contains(CloudStore.categoryKey(x.server, x.name))
    }

    /// Aan = geen enkele bron uitgezet (een tik die nog niet is opgeslagen telt meteen mee)
    private func isOn(_ g: String, hidden: Set<String>) -> Bool {
        !sources(of: g).contains { !isOn($0, hidden: hidden) }
    }

    private func set(_ list: [CategoryIndex.Source], on: Bool) {
        for x in list { pending[x] = on }
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func set(groups list: [String], on: Bool) { set(list.flatMap { sources(of: $0) }, on: on) }

    /// De getikte keuzes in één keer opslaan (één wijziging, één keer filteren, één upload)
    private func commit() {
        commitTask = nil
        guard !pending.isEmpty else { return }
        var on: [(UUID, String)] = [], off: [(UUID, String)] = []
        for (x, v) in pending {
            if v { on.append((x.server, x.name)) } else { off.append((x.server, x.name)) }
        }
        pending = [:]
        if !on.isEmpty { store.setCategories(on, hidden: false) }
        if !off.isEmpty { store.setCategories(off, hidden: true) }
    }

    /// Onderregel: aantal (build 151), talen van de bronnen ("NL · Multi") en, met meer servers, de servers
    private func caption(_ g: String) -> String? {
        var parts: [String] = []
        if let n = index.counts[kind]?[g], n > 0 { parts.append(kind == .live ? L("%d channels", n) : L("%d titles", n)) }
        if let ls = index.labels[kind]?[g], !ls.isEmpty { parts.append(ls.joined(separator: " · ")) }
        if store.playlists.count > 1 {
            var ids: [UUID] = []
            for x in sources(of: g) where !ids.contains(x.server) { ids.append(x.server) }
            let names = ids.compactMap { id in store.playlists.first { $0.id == id }?.name }
            if !names.isEmpty { parts.append(names.joined(separator: " · ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func title(_ g: String) -> String {
        if let first = sources(of: g).first(where: { $0.server == pid }), let r = c.renamed[Customization.groupKey(first.name)] { return r }
        return g
    }

    var body: some View {
        let hidden = store.hiddenCategories
        let list = groups
        List {
            Picker("", selection: $kind) {
                Text(L("Live TV")).tag(ManageView.Kind.live)
                Text(L("Movies")).tag(ManageView.Kind.movies)
                Text(L("Series")).tag(ManageView.Kind.series)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            let pre = prefixes
            if !pre.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: tvScaled(10)) {
                            ForEach(pre, id: \.code) { p in
                                let onCount = p.sources.filter { isOn($0, hidden: hidden) }.count
                                let allOn = onCount == p.sources.count
                                Button { set(p.sources, on: !allOn) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: allOn ? "checkmark.circle.fill" : (onCount == 0 ? "circle" : "minus.circle.fill"))
                                        Text(p.code).fontWeight(.bold)
                                        Text("\(onCount)/\(p.sources.count)").foregroundStyle(allOn ? Theme.onAccent.opacity(0.75) : Theme.secondary)
                                    }
                                    .font(.system(size: tvScaled(14)))
                                    .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(7))
                                    .background(allOn ? Theme.red.opacity(0.85) : Theme.elevated, in: Capsule())
                                    .foregroundStyle(allOn ? Theme.onAccent : Color.white)
                                }
                                .plainTVButton()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text(L("Countries & languages")) } footer: {
                    Text(L("Tap a code to turn all its categories on or off at once."))
                }
            }

            Section {
                HStack {
                    Button(L("All on")) { set(groups: list, on: true) }
                    Spacer()
                    Button(L("All off")) { set(groups: list, on: false) }
                }
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
                if index.building && allGroups.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(list, id: \.self) { g in
                    Toggle(isOn: Binding(get: { isOn(g, hidden: hidden) }, set: { set(groups: [g], on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(g)).lineLimit(1)
                            if let cap = caption(g) {
                                Text(cap).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                    }
                    .tint(Theme.red)
                }
            } header: {
                Text(L("Categories (%d)", list.count))
            } footer: {
                Text(L("Categories that are off don't appear anywhere for this profile. This list shows the categories of all your servers."))
            }
        }
        .navigationTitle(L("Categories"))
        #if !os(tvOS)
        .searchable(text: $filter, prompt: L("Search category"))
        #endif
        .onChange(of: kind) { _, _ in
            commit()
            filter = ""
        }
        .onDisappear { commit() }
        .task(id: indexKey) { await rebuild() }
    }

    /// Categorieën van alle servers op de achtergrond verzamelen (de open server uit het geheugen, de andere uit hun cache)
    private func rebuild() async {
        index.building = true
        let raw = playlists.rawLibrary
        let active = pid
        let others = store.playlists.filter { $0.id != active }
        let built = await Task.detached(priority: .userInitiated) { () -> CategoryIndex in
            var lists: [(UUID, [ManageView.Kind: [(group: String, count: Int)]])] = []
            if let active { lists.append((active, CategoryIndex.groups(of: raw))) }
            // alleen servers die nog bestaan (een verwijderde server verdwijnt meteen uit dit scherm)
            for p in others {
                guard let (lib, _) = PlaylistService.readAnyCatalog(p) else { continue }
                lists.append((p.id, CategoryIndex.groups(of: lib)))
            }
            return CategoryIndex.build(lists)
        }.value
        guard !Task.isCancelled else { return }
        index = built
    }
}

/// Build 140: de categorieën van alle servers, één keer opgebouwd (zie `CategoriesView`).
/// Build 150: per opgeschoonde naam één regel (hoofdletterongevoelig, over talen, kwaliteit en servers heen); aan/uit
/// geldt voor alle bronnen eronder. Het account bewaart nog steeds per bron (`server|exacte naam`).
struct CategoryIndex: Sendable {
    struct Source: Sendable, Hashable { var server: UUID; var name: String }
    struct Prefix: Sendable { var code: String; var sources: [Source] }

    /// Per onderdeel: de weergavenamen (open server eerst, daarna in de volgorde van de servers, zonder dubbele)
    var groups: [ManageView.Kind: [String]] = [:]
    /// Per onderdeel: weergavenaam → de bronnen eronder
    var sources: [ManageView.Kind: [String: [Source]]] = [:]
    /// Per onderdeel: weergavenaam → talen van de bronnen ("NL", "Multi")
    var labels: [ManageView.Kind: [String: [String]]] = [:]
    /// Per onderdeel: voorvoegsels ("NL", "BE" …) met hun bronnen
    var prefixes: [ManageView.Kind: [Prefix]] = [:]
    /// Build 151: per onderdeel: weergavenaam → aantal zenders/titels (ook niet ingelezen verborgen categorieën)
    var counts: [ManageView.Kind: [String: Int]] = [:]
    var building = false

    /// Build 151: met aantallen, en ook de categorieën die niet zijn ingelezen (verborgen, `Library.skipped`)
    static func groups(of lib: Library) -> [ManageView.Kind: [(group: String, count: Int)]] {
        [.live: SkippedCatalog.groupCounts(loaded: lib.channels.map(\.group), lib.skipped, .live),
         .movies: SkippedCatalog.groupCounts(loaded: lib.movies.map(\.group), lib.skipped, .movie),
         .series: SkippedCatalog.groupCounts(loaded: lib.series.map(\.group), lib.skipped, .series)]
    }

    static func build(_ lists: [(UUID, [ManageView.Kind: [(group: String, count: Int)]])]) -> CategoryIndex {
        var x = CategoryIndex()
        for kind in ManageView.Kind.allCases {
            var order: [String] = []
            var byKey: [String: String] = [:]          // samenvoegsleutel → weergavenaam
            var map: [String: [Source]] = [:]
            var labels: [String: [String]] = [:]
            var pre: [String: [Source]] = [:]
            var counts: [String: Int] = [:]
            for (sid, byKind) in lists {
                for (g, n) in byKind[kind] ?? [] {
                    let parsed = CategoryName.parse(g)
                    let k = CategoryName.mergeKey(parsed.name)
                    let shown: String
                    if let s = byKey[k] { shown = s } else { shown = parsed.name; byKey[k] = shown; order.append(shown) }
                    let src = Source(server: sid, name: g)
                    counts[shown, default: 0] += n
                    if !(map[shown]?.contains(src) ?? false) { map[shown, default: []].append(src) }
                    for l in parsed.labels where !(labels[shown]?.contains(l) ?? false) { labels[shown, default: []].append(l) }
                    if let p = parsed.prefixLabels.first { pre[p, default: []].append(src) }
                }
            }
            x.groups[kind] = order
            x.sources[kind] = map
            x.labels[kind] = labels
            x.counts[kind] = counts
            x.prefixes[kind] = pre
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
                .map { Prefix(code: $0.key, sources: $0.value) }
        }
        return x
    }
}

/// Voorvoegsel zoals "NL", "BE", "DE", "TK" vooraan een categorienaam.
enum CategoryPrefix {
    /// Build 150: via `CategoryName` (ook "| NL |", "¦", "MULTI / LINGO", "[EN]", "NL:" …)
    static func of(_ g: String) -> String? { CategoryName.prefixLabel(g) }
}

extension CategoriesView {
    /// Oude naam (andere schermen gebruiken hem nog)
    static func prefix(of g: String) -> String? { CategoryPrefix.of(g) }
}
