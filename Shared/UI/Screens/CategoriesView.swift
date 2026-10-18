import SwiftUI

/// Categorieën aan/uit per onderdeel (Live TV, Films, Series), met snelknoppen per land/taal
/// (NL, BE, DE, TK …) die alle categorieën met dat voorvoegsel in één keer aan- of uitzetten.
/// Build 128: per profiel (CloudStore.hiddenCategories, "<server-id>|<categorie>") en met de categorieën van alle
/// servers; dezelfde naam op twee servers is één regel die voor beide geldt.
struct CategoriesView: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var kind: ManageView.Kind = .live
    @State private var filter = ""
    /// Categorieën van de andere servers (uit hun cache, op de achtergrond gelezen)
    @State private var other: [UUID: [ManageView.Kind: [String]]] = [:]

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }

    /// Categorie → de servers waar hij voorkomt (open server eerst, dan in de volgorde van de servers)
    private var serversOf: [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for (sid, list) in allLists { for g in list where !(out[g]?.contains(sid) ?? false) { out[g, default: []].append(sid) } }
        return out
    }

    private var allLists: [(UUID, [String])] {
        var out: [(UUID, [String])] = []
        if let pid {
            let raw = playlists.rawLibrary
            switch kind {
            case .live: out.append((pid, orderedUnique(raw.channels.map(\.group))))
            case .movies: out.append((pid, orderedUnique(raw.movies.map(\.group))))
            case .series: out.append((pid, orderedUnique(raw.series.map(\.group))))
            }
        }
        // alleen servers die nog bestaan (een verwijderde server verdwijnt meteen uit dit scherm)
        for src in store.playlists where src.id != pid {
            if let l = other[src.id]?[kind] { out.append((src.id, l)) }
        }
        return out
    }

    private var groups: [String] {
        let all = orderedUnique(allLists.flatMap { $0.1 })
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func loadOtherServers() async {
        let others = store.playlists.filter { $0.id != pid }
        guard !others.isEmpty else { if !other.isEmpty { other = [:] }; return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [UUID: [ManageView.Kind: [String]]] in
            var out: [UUID: [ManageView.Kind: [String]]] = [:]
            for p in others {
                guard let (lib, _) = PlaylistService.readAnyCatalog(p) else { continue }
                out[p.id] = [.live: orderedUnique(lib.channels.map(\.group)), .movies: orderedUnique(lib.movies.map(\.group)),
                             .series: orderedUnique(lib.series.map(\.group))]
            }
            return out
        }.value
        if loaded != other { other = loaded }
    }

    /// Voorvoegsels zoals "NL", "BE", "DE", "TK" met de categorieën die erbij horen.
    private var prefixes: [(code: String, groups: [String])] {
        var map: [String: [String]] = [:]
        for g in groups { if let p = Self.prefix(of: g) { map[p, default: []].append(g) } }
        return map.filter { $0.value.count >= 1 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private static let prefixRE = try! NSRegularExpression(
        pattern: #"^\s*[\|\[\(\{]?\s*([A-Z]{2,4}|[A-Z]{2}\+)\s*(?:[\|\]\)\}:\-–•]|\s{1,}\|)"#)

    static func prefix(of g: String) -> String? {
        guard let m = prefixRE.firstMatch(in: g, range: NSRange(g.startIndex..., in: g)),
              let r = Range(m.range(at: 1), in: g) else { return nil }
        let p = String(g[r]).uppercased()
        // gewone woorden die toevallig vooraan staan niet als land tellen
        let skip: Set<String> = ["THE", "AND", "FOR", "ALL", "NEW", "TOP", "VOD", "TV"]
        return skip.contains(p) ? nil : p
    }

    /// Aan = op geen enkele server uitgezet voor dit profiel
    private func isOn(_ g: String) -> Bool {
        let servers = serversOf[g] ?? pid.map { [$0] } ?? []
        return !servers.contains { store.isCategoryHidden($0, g) }
    }

    private func set(_ list: [String], on: Bool) {
        let map = serversOf
        var items: [(UUID, String)] = []
        for g in list { for sid in map[g] ?? pid.map { [$0] } ?? [] { items.append((sid, g)) } }
        store.setCategories(items, hidden: !on)
    }

    private func serverNames(_ g: String) -> String? {
        guard store.playlists.count > 1, let ids = serversOf[g] else { return nil }
        let names = ids.compactMap { id in store.playlists.first { $0.id == id }?.name }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    var body: some View {
        List {
            Picker("", selection: $kind) {
                Text(L("Live TV")).tag(ManageView.Kind.live)
                Text(L("Movies")).tag(ManageView.Kind.movies)
                Text(L("Series")).tag(ManageView.Kind.series)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if !prefixes.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tvScaled(10)) {
                            ForEach(prefixes, id: \.code) { p in
                                let onCount = p.groups.filter(isOn).count
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
                    Button(L("All on")) { set(groups, on: true) }
                    Spacer()
                    Button(L("All off")) { set(groups, on: false) }
                }
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
                ForEach(groups, id: \.self) { g in
                    Toggle(isOn: Binding(get: { isOn(g) }, set: { set([g], on: $0) })) {
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
                Text(L("Categories (%d)", groups.count))
            } footer: {
                Text(L("Categories that are off don't appear anywhere for this profile. This list shows the categories of all your servers."))
            }
        }
        .navigationTitle(L("Categories"))
        #if !os(tvOS)
        .searchable(text: $filter, prompt: L("Search category"))
        #endif
        .onChange(of: kind) { _, _ in filter = "" }
        .task(id: store.playlists.map(\.id)) { await loadOtherServers() }
    }
}
