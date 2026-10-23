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
    /// Getikt maar nog niet opgeslagen: categorie → aan
    @State private var pending: [String: Bool] = [:]
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
        return IndexKey(pid: pid, counts: [raw.channels.count, raw.movies.count, raw.series.count],
                        servers: store.playlists.map(\.id))
    }

    private var allGroups: [String] { index.groups[kind] ?? [] }

    private var groups: [String] {
        let all = allGroups
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var prefixes: [CategoryIndex.Prefix] {
        let p = index.prefixes[kind] ?? []
        guard !filter.isEmpty else { return p }
        let visible = Set(groups)
        return p.compactMap { x in
            let g = x.groups.filter { visible.contains($0) }
            return g.isEmpty ? nil : CategoryIndex.Prefix(code: x.code, groups: g)
        }
    }

    private func servers(of g: String) -> [UUID] { index.servers[kind]?[g] ?? pid.map { [$0] } ?? [] }

    /// Aan = op geen enkele server uitgezet (een tik die nog niet is opgeslagen telt meteen mee)
    private func isOn(_ g: String, hidden: Set<String>) -> Bool {
        if let p = pending[g] { return p }
        return !servers(of: g).contains { hidden.contains(CloudStore.categoryKey($0, g)) }
    }

    private func set(_ list: [String], on: Bool) {
        for g in list { pending[g] = on }
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// De getikte keuzes in één keer opslaan (één wijziging, één keer filteren, één upload)
    private func commit() {
        commitTask = nil
        guard !pending.isEmpty else { return }
        let map = index.servers[kind] ?? [:]
        var on: [(UUID, String)] = [], off: [(UUID, String)] = []
        for (g, v) in pending {
            for sid in map[g] ?? pid.map { [$0] } ?? [] {
                if v { on.append((sid, g)) } else { off.append((sid, g)) }
            }
        }
        pending = [:]
        if !on.isEmpty { store.setCategories(on, hidden: false) }
        if !off.isEmpty { store.setCategories(off, hidden: true) }
    }

    private func serverNames(_ g: String) -> String? {
        guard store.playlists.count > 1, let ids = index.servers[kind]?[g] else { return nil }
        let names = ids.compactMap { id in store.playlists.first { $0.id == id }?.name }
        return names.isEmpty ? nil : names.joined(separator: " · ")
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
                                let onCount = p.groups.filter { isOn($0, hidden: hidden) }.count
                                let allOn = onCount == p.groups.count
                                Button { set(p.groups, on: !allOn) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: allOn ? "checkmark.circle.fill" : (onCount == 0 ? "circle" : "minus.circle.fill"))
                                        Text(p.code).fontWeight(.bold)
                                        Text("\(onCount)/\(p.groups.count)").foregroundStyle(allOn ? Theme.onAccent.opacity(0.75) : Theme.secondary)
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
                    Button(L("All on")) { set(list, on: true) }
                    Spacer()
                    Button(L("All off")) { set(list, on: false) }
                }
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
                if index.building && allGroups.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(list, id: \.self) { g in
                    Toggle(isOn: Binding(get: { isOn(g, hidden: hidden) }, set: { set([g], on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.renamed[Customization.groupKey(g)] ?? g).lineLimit(1)
                            if let names = serverNames(g) {
                                Text(names).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
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
            var lists: [(UUID, [ManageView.Kind: [String]])] = []
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
struct CategoryIndex: Sendable {
    struct Prefix: Sendable { var code: String; var groups: [String] }

    /// Per onderdeel: de categorieën (open server eerst, daarna in de volgorde van de servers, zonder dubbele)
    var groups: [ManageView.Kind: [String]] = [:]
    /// Per onderdeel: categorie → de servers waar hij voorkomt
    var servers: [ManageView.Kind: [String: [UUID]]] = [:]
    /// Per onderdeel: voorvoegsels ("NL", "BE" …) met hun categorieën
    var prefixes: [ManageView.Kind: [Prefix]] = [:]
    var building = false

    static func groups(of lib: Library) -> [ManageView.Kind: [String]] {
        [.live: orderedUnique(lib.channels.map(\.group)), .movies: orderedUnique(lib.movies.map(\.group)),
         .series: orderedUnique(lib.series.map(\.group))]
    }

    static func build(_ lists: [(UUID, [ManageView.Kind: [String]])]) -> CategoryIndex {
        var x = CategoryIndex()
        for kind in ManageView.Kind.allCases {
            var order: [String] = []
            var map: [String: [UUID]] = [:]
            for (sid, byKind) in lists {
                for g in byKind[kind] ?? [] {
                    if map[g] == nil { order.append(g) }
                    if !(map[g]?.contains(sid) ?? false) { map[g, default: []].append(sid) }
                }
            }
            x.groups[kind] = order
            x.servers[kind] = map
            var pre: [String: [String]] = [:]
            for g in order { if let p = CategoryPrefix.of(g) { pre[p, default: []].append(g) } }
            x.prefixes[kind] = pre
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
                .map { Prefix(code: $0.key, groups: $0.value) }
        }
        return x
    }
}

/// Voorvoegsel zoals "NL", "BE", "DE", "TK" vooraan een categorienaam.
enum CategoryPrefix {
    private static let prefixRE = try! NSRegularExpression(
        pattern: #"^\s*[\|\[\(\{]?\s*([A-Z]{2,4}|[A-Z]{2}\+)\s*(?:[\|\]\)\}:\-–•]|\s{1,}\|)"#)
    /// gewone woorden die toevallig vooraan staan niet als land tellen
    private static let skip: Set<String> = ["THE", "AND", "FOR", "ALL", "NEW", "TOP", "VOD", "TV"]

    static func of(_ g: String) -> String? {
        guard let m = prefixRE.firstMatch(in: g, range: NSRange(g.startIndex..., in: g)),
              let r = Range(m.range(at: 1), in: g) else { return nil }
        let p = String(g[r]).uppercased()
        return skip.contains(p) ? nil : p
    }
}

extension CategoriesView {
    /// Oude naam (andere schermen gebruiken hem nog)
    static func prefix(of g: String) -> String? { CategoryPrefix.of(g) }
}
