import SwiftUI

/// Categorieën aan/uit per onderdeel (Live TV, Films, Series), met snelknoppen per land/taal
/// (NL, BE, DE, TK …) die alle categorieën met dat voorvoegsel in één keer aan- of uitzetten.
struct CategoriesView: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var kind: ManageView.Kind = .live
    @State private var filter = ""

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }

    private var groups: [String] {
        let raw = playlists.rawLibrary
        let all: [String]
        switch kind {
        case .live: all = orderedUnique(raw.channels.map(\.group))
        case .movies: all = orderedUnique(raw.movies.map(\.group))
        case .series: all = orderedUnique(raw.series.map(\.group))
        }
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
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

    private func isOn(_ g: String) -> Bool { !c.hidden.contains(Customization.groupKey(g)) }

    private func set(_ list: [String], on: Bool) {
        guard let pid else { return }
        store.updateCustomization(pid) { cu in
            for g in list {
                if on { cu.hidden.remove(Customization.groupKey(g)) } else { cu.hidden.insert(Customization.groupKey(g)) }
            }
        }
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
                                        Text("\(onCount)/\(p.groups.count)").foregroundStyle(Theme.secondary)
                                    }
                                    .font(.system(size: tvScaled(14)))
                                    .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(7))
                                    .background(allOn ? Theme.red.opacity(0.85) : Theme.elevated, in: Capsule())
                                    .foregroundStyle(.white)
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
                        Text(c.renamed[Customization.groupKey(g)] ?? g).lineLimit(1)
                    }
                    .tint(Theme.red)
                }
            } header: {
                Text(L("Categories (%d)", groups.count))
            } footer: {
                Text(L("Categories that are off don't appear anywhere in the app. Saved per playlist and synced via iCloud."))
            }
        }
        .navigationTitle(L("Categories"))
        #if !os(tvOS)
        .searchable(text: $filter, prompt: L("Search category"))
        #endif
        .onChange(of: kind) { _, _ in filter = "" }
    }
}
