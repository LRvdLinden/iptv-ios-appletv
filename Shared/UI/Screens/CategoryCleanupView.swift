import SwiftUI

/// Build 172: overgeslagen voorstellen van "Categorieën opschonen" per server (`"<soort>|<id>"`), en welke doelnamen
/// het opschonen zelf heeft gezet (lokaal, zodat "Losmaken" alleen die naam weer weghaalt).
/// Gesynct in het `apple`-blok van de server (`apple.ignoredMergeSuggestions`, naast `customization`): oudere apps laten
/// onbekende sleutels in dat blok staan. Leeg = de sleutel ontbreekt (dan verandert er niets voor bestaande servers).
@MainActor
final class CleanupStore172: ObservableObject {
    static let shared = CleanupStore172()
    @Published private(set) var ignored: [UUID: [String]] = [:]
    private var made: [String: String] = [:]
    private let ignoredKey = "cleanup172.ignored.v1"
    private let madeKey = "cleanup172.made.v1"

    private init() {
        if let d = UserDefaults.standard.dictionary(forKey: ignoredKey) as? [String: [String]] {
            for (k, v) in d { if let id = UUID(uuidString: k) { ignored[id] = v } }
        }
        made = UserDefaults.standard.dictionary(forKey: madeKey) as? [String: String] ?? [:]
    }

    private func save() {
        var d: [String: [String]] = [:]
        for (k, v) in ignored where !v.isEmpty { d[k.uuidString] = v }
        UserDefaults.standard.set(d, forKey: ignoredKey)
    }

    func ignored(_ server: UUID, section: String) -> Set<String> {
        let p = section + "|"
        return Set((ignored[server] ?? []).filter { $0.hasPrefix(p) }.map { String($0.dropFirst(p.count)) })
    }

    func ignore(_ server: UUID, section: String, id: String) {
        let key = CategoryCleanup172.ignoreKey(section: section, id: id)
        var list = ignored[server] ?? []
        guard !list.contains(key) else { return }
        list.append(key)
        ignored[server] = list.sorted()
        save()
    }

    /// "Opnieuw zoeken": overgeslagen voorstellen van deze soort komen terug
    func clear(_ server: UUID, section: String) {
        let p = section + "|"
        let list = (ignored[server] ?? []).filter { !$0.hasPrefix(p) }
        guard list != (ignored[server] ?? []) else { return }
        ignored[server] = list.isEmpty ? nil : list
        save()
    }

    /// Uit de account-sync (nil/leeg = geen overgeslagen voorstellen op de server)
    func setFromSync(_ server: UUID, _ list: [String]?) {
        let v = (list ?? []).sorted()
        guard v != (ignored[server] ?? []) else { return }
        ignored[server] = v.isEmpty ? nil : v
        save()
    }

    func syncList(_ server: UUID) -> [String]? {
        guard let v = ignored[server], !v.isEmpty else { return nil }
        return v
    }

    func madeName(_ server: UUID, _ target: String) -> String? { made[server.uuidString + "|" + target] }
    func setMade(_ server: UUID, _ target: String, _ name: String?) {
        made[server.uuidString + "|" + target] = name
        UserDefaults.standard.set(made, forKey: madeKey)
    }
}

/// Build 172: Instellingen > server > "Categorieën opschonen". Zoekt op het apparaat naar categorieën die bij elkaar
/// horen (merken, zelfde begin, landvarianten) en voegt ze pas samen na akkoord, in het bestaande formaat van
/// `Customization` (`merged`, `renamed`, `groupOrder`). Alleen het hoofdaccount.
struct CategoryCleanupView: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @ObservedObject private var cleanup = CleanupStore172.shared
    @State private var section: ManageView.Kind = .movies
    @State private var suggestions: [CategoryCleanup172.Suggestion] = []
    @State private var searching = false
    @State private var searched = false
    /// Voorstel mee in "Alles toepassen"
    @State private var picked: [String: Bool] = [:]
    /// "<id>|<groep>" uitgevinkt
    @State private var unchecked: Set<String> = []
    @State private var names: [String: String] = [:]
    @State private var renaming: CategoryCleanup172.Suggestion?
    @State private var confirming: Confirm?
    @State private var undo: Undo?
    @State private var generation = 0

    typealias CC = CategoryCleanup172
    struct Confirm: Identifiable { let id = UUID(); let picks: [CC.Suggestion] }
    struct Undo { let snapshot: Customization; let token: UUID }
    struct Target: Identifiable { let target: String; let sources: [String]; var id: String { target } }

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }
    private var sectionKey: String { section == .live ? "live" : section == .movies ? "movie" : "series" }

    private var groupCounts: [(group: String, count: Int)] {
        let raw = playlists.rawLibrary
        switch section {
        case .live: return SkippedCatalog.groupCounts(loaded: raw.channels.map(\.group), raw.skipped, .live)
        case .movies: return SkippedCatalog.groupCounts(loaded: raw.movies.map(\.group), raw.skipped, .movie)
        case .series: return SkippedCatalog.groupCounts(loaded: raw.series.map(\.group), raw.skipped, .series)
        }
    }

    private func display(_ g: String) -> String { c.renamed[Customization.groupKey(g)] ?? CategoryName.clean(g) }
    private func countText(_ n: Int) -> String { section == .live ? L("%d channels", n) : L("%d titles", n) }
    private func name(_ s: CC.Suggestion) -> String { names[s.id] ?? s.target }
    private func checked(_ s: CC.Suggestion) -> [String] { s.groups.filter { !unchecked.contains(s.id + "|" + $0) } }
    private func isPicked(_ s: CC.Suggestion) -> Bool { picked[s.id] ?? s.on }
    private var pickedList: [CC.Suggestion] { suggestions.filter { isPicked($0) && checked($0).count >= 2 } }

    var body: some View {
        List {
            Picker("", selection: $section) {
                Text(L("Live TV")).tag(ManageView.Kind.live)
                Text(L("Movies")).tag(ManageView.Kind.movies)
                Text(L("Series")).tag(ManageView.Kind.series)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let undo { undoRow(undo) }

            Section {
                if searching {
                    HStack(spacing: 12) { ProgressView(); Text(L("Searching for categories that belong together…")) }
                } else if searched && suggestions.isEmpty {
                    Text(L("No suggestions. Your categories look tidy.")).foregroundStyle(Theme.secondary)
                }
                if !suggestions.isEmpty {
                    Button { if !pickedList.isEmpty { confirming = Confirm(picks: pickedList) } } label: {
                        Label(L("Apply all (%d)", pickedList.count), systemImage: "checkmark.circle")
                    }
                    .disabled(pickedList.isEmpty)
                }
                Button { searchAgain() } label: { Label(L("Search again"), systemImage: "magnifyingglass") }
                    .disabled(searching)
            } footer: {
                Text(L("Bingr looks for categories that belong together, such as Netflix, Netflix Movies and Netflix Documentaries. Nothing changes until you tap Merge. Brands are selected by default; country variants and same-beginning suggestions are not."))
            }

            ForEach(suggestions) { s in suggestionSection(s) }

            mergedSection
        }
        .navigationTitle(L("Clean up categories"))
        .onAppear { search() }
        .onChange(of: section) { _, _ in search() }
        .sheet(item: $renaming) { s in
            RenameSheet(title: name(s)) { new in names[s.id] = new.isEmpty ? nil : new }
        }
        .alert(L("Merge categories?"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { conf in
            Button(L("Merge")) { apply(conf.picks) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { conf in
            let sum = CC.summary(conf.picks.map { s -> CC.Suggestion in var x = s; x.groups = checked(s); return x })
            Text(L("%d categories become %d. You can always undo this.", sum.from, sum.to))
        }
    }

    // MARK: voorstellen

    private func kindText(_ k: CC.Kind) -> String {
        switch k {
        case .brand: return L("Brand")
        case .country: return L("Country variants")
        case .prefix: return L("Same beginning")
        }
    }

    @ViewBuilder private func suggestionSection(_ s: CC.Suggestion) -> some View {
        let on = isPicked(s)
        let chosen = checked(s)
        Section {
            Button { picked[s.id] = !on } label: {
                HStack {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.red : Theme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(s)).font(.headline)
                        Text(L("%d categories", chosen.count) + " · " + countText(chosen.reduce(0) { $0 + (s.counts[$1] ?? 0) }))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(kindText(s.kind)).font(.caption).foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            ForEach(s.groups, id: \.self) { g in
                let key = s.id + "|" + g
                let isOn = !unchecked.contains(key)
                Button {
                    if isOn { unchecked.insert(key) } else { unchecked.remove(key) }
                } label: {
                    HStack {
                        Image(systemName: isOn ? "checkmark.square.fill" : "square").foregroundStyle(isOn ? Theme.red : Theme.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g).lineLimit(1)
                            if s.renamed.contains(g) {
                                Label(L("You renamed this category yourself (%@)", c.renamed[Customization.groupKey(g)] ?? ""),
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(countText(s.counts[g] ?? 0)).font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
            #if os(tvOS)
            Button { confirming = Confirm(picks: [s]) } label: { Label(L("Merge"), systemImage: "arrow.triangle.merge") }
                .disabled(chosen.count < 2)
            Button { renaming = s } label: { Label(L("Change target name"), systemImage: "pencil") }
            Button { skip(s) } label: { Label(L("Skip"), systemImage: "xmark") }
            #else
            HStack(spacing: 16) {
                Button(L("Merge")) { confirming = Confirm(picks: [s]) }.disabled(chosen.count < 2)
                Button(L("Change target name")) { renaming = s }
                Spacer()
                Button(L("Skip")) { skip(s) }.foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.borderless)
            #endif
        } header: {
            Text(name(s))
        }
    }

    // MARK: samengevoegd

    @ViewBuilder private var mergedSection: some View {
        let groups = groupCounts.map(\.group)
        let here = Set(groups)
        let targets = CC.mergedTargets(c.merged, order: groups)
            .filter { t in here.contains(t.target) || t.sources.contains(where: { here.contains($0) }) }
            .map { Target(target: $0.target, sources: $0.sources) }
        if !targets.isEmpty {
            Section(L("Merged")) {
                ForEach(targets) { t in
                    Button { detach(t.target, nil) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display(t.target)).font(.headline)
                                Text(L("%d categories", t.sources.count + 1)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(L("Detach all")).foregroundStyle(Theme.red)
                        }
                        .contentShape(Rectangle())
                    }
                    ForEach(t.sources, id: \.self) { src in
                        Button { detach(t.target, [src]) } label: {
                            HStack {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.secondary)
                                Text(src).lineLimit(1)
                                Spacer()
                                Text(L("Take out")).foregroundStyle(Theme.red)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func undoRow(_ u: Undo) -> some View {
        Section {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Categories merged."))
                Spacer()
                #if !os(tvOS)
                Button(L("Undo")) { restore(u) }.buttonStyle(.borderless)
                #endif
            }
            #if os(tvOS)
            Button(L("Undo")) { restore(u) }
            #endif
        }
    }

    // MARK: acties

    private func search() {
        guard let pid else { suggestions = []; return }
        generation += 1
        let gen = generation
        let groups = groupCounts.map { CC.Group(name: $0.group, count: $0.count) }
        var hidden = store.hiddenGroups(for: pid)
        for h in c.hidden where h.hasPrefix("group:") { hidden.insert(String(h.dropFirst(6))) }
        let merged = c.merged, renamed = c.renamed
        let ignored = cleanup.ignored(pid, section: sectionKey)
        searching = true
        Task {
            let out = await Task.detached(priority: .userInitiated) {
                CC.suggest(groups: groups, merged: merged, renamed: renamed, hidden: hidden, ignored: ignored)
            }.value
            guard gen == generation else { return }
            suggestions = out
            picked = [:]; unchecked = []; names = [:]
            searching = false
            searched = true
        }
    }

    private func searchAgain() {
        if let pid { cleanup.clear(pid, section: sectionKey) }
        search()
    }

    private func skip(_ s: CC.Suggestion) {
        guard let pid else { return }
        cleanup.ignore(pid, section: sectionKey, id: s.id)
        suggestions.removeAll { $0.id == s.id }
    }

    private func apply(_ picks: [CC.Suggestion]) {
        guard let pid else { return }
        let before = store.customization(pid)
        let live = section == .live
        var done: Set<String> = []
        for s in picks {
            let gs = checked(s)
            guard gs.count >= 2 else { continue }
            let target = gs.contains(s.targetGroup) ? s.targetGroup : gs[0]
            let nm = name(s).trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = CategoryName.clean(target)
            store.updateCustomization(pid) { cu in
                let r = CC.apply(CC.Custom(merged: cu.merged, renamed: cu.renamed, groupOrder: live ? cu.groupOrder : []),
                                 groups: gs, targetGroup: target, name: nm, cleanName: clean)
                cu.merged = r.merged
                cu.renamed = r.renamed
                if live { cu.groupOrder = r.groupOrder }
            }
            cleanup.setMade(pid, target, !nm.isEmpty && nm != clean ? nm : nil)
            done.insert(s.id)
        }
        guard !done.isEmpty else { return }
        suggestions.removeAll { done.contains($0.id) }
        playlists.applyCustomizations()
        let u = Undo(snapshot: before, token: UUID())
        withAnimation { undo = u }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if undo?.token == u.token { withAnimation { undo = nil } }
        }
    }

    private func restore(_ u: Undo) {
        guard let pid else { return }
        store.updateCustomization(pid) { $0 = u.snapshot }
        playlists.applyCustomizations()
        undo = nil
        search()
    }

    private func detach(_ target: String, _ sources: [String]?) {
        guard let pid else { return }
        let made = cleanup.madeName(pid, target)
        store.updateCustomization(pid) { cu in
            let r = CC.detach(CC.Custom(merged: cu.merged, renamed: cu.renamed, groupOrder: cu.groupOrder),
                              target: target, sources: sources, madeName: made)
            cu.merged = r.merged
            cu.renamed = r.renamed
        }
        if !store.customization(pid).merged.values.contains(target) { cleanup.setMade(pid, target, nil) }
        playlists.applyCustomizations()
    }
}
