import SwiftUI

/// Beheren: groepen en zenders hernoemen, herschikken, samenvoegen, verbergen en op slot zetten.
/// Alles wordt per afspeellijst via iCloud gesynchroniseerd.
struct ManageView: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var parental: ParentalControl
    @State private var section: Kind = .live
    @State private var renaming: RenameTarget?
    @State private var merging: String?
    /// Groep waarvan het actiemenu open is (tik op een film-/seriegroep, of op Apple TV)
    @State private var groupMenu: String?
    /// build 141: groep die na de pincode ontgrendeld wordt
    @State private var unlocking: UnlockTarget?

    struct UnlockTarget: Identifiable { var playlist: UUID; var group: String; var id: String { "\(playlist.uuidString)|\(group)" } }

    enum Kind: String, CaseIterable { case live, movies, series }
    struct RenameTarget: Identifiable { var id: String; var current: String }

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }

    private var rawGroups: [String] {
        let raw = playlists.rawLibrary
        switch section {
        case .live: return orderedUnique(raw.channels.map(\.group))
        case .movies: return orderedUnique(raw.movies.map(\.group))
        case .series: return orderedUnique(raw.series.map(\.group))
        }
    }

    /// Groepen in de eigen volgorde, zonder groepen die in een andere zijn samengevoegd.
    private var groups: [String] {
        let visible = rawGroups.filter { c.merged[$0] == nil }
        guard section == .live, !c.groupOrder.isEmpty else { return visible }
        let idx = Dictionary(c.groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return visible.enumerated().sorted { (idx[$0.element] ?? 10_000 + $0.offset) < (idx[$1.element] ?? 10_000 + $1.offset) }.map(\.element)
    }

    var body: some View {
        List {
            Picker("", selection: $section) {
                Text(L("Live TV")).tag(Kind.live)
                Text(L("Movies")).tag(Kind.movies)
                Text(L("Series")).tag(Kind.series)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(groups.enumerated()), id: \.element) { i, g in
                    groupRow(g, index: i)
                }
                .onMove(perform: section == .live ? move : nil)
            } header: {
                Text(L("Groups"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Hidden groups and channels don't appear anywhere in the app. Merged groups are shown as one."))
                    #if os(tvOS)
                    if section == .live { Text(L("Press and hold a group for more options.")) }
                    #endif
                }
            }

            let merged = rawGroups.filter { c.merged[$0] != nil }
            if !merged.isEmpty {
                Section(L("Merged")) {
                    ForEach(merged, id: \.self) { g in
                        HStack {
                            Text(g)
                            Image(systemName: "arrow.right").foregroundStyle(Theme.secondary)
                            Text(c.merged[g] ?? "").foregroundStyle(Theme.secondary)
                            Spacer()
                            Button(L("Undo")) { update { $0.merged[g] = nil } }
                        }
                    }
                }
            }

            Section {
                Button(L("Reset all changes"), role: .destructive) {
                    if let pid { store.updateCustomization(pid) { $0 = Customization() } }
                }
            }
        }
        .navigationTitle(L("Manage"))
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .sheet(item: $renaming) { t in RenameSheet(title: t.current) { new in update { $0.renamed[t.id] = new.isEmpty ? nil : new } } }
        // build 141: een groep ontgrendelen vraagt de pincode van het kinderslot
        .sheet(item: $unlocking) { t in
            PINPad(title: L("Enter PIN to unlock this group")) { pin in
                guard parental.verify(pin) else { return false }
                parental.setLocked(false, playlist: t.playlist, group: t.group)
                return true
            }
        }
        .confirmationDialog(groupMenu.map(display) ?? "", isPresented: Binding(get: { groupMenu != nil }, set: { if !$0 { groupMenu = nil } }),
                            titleVisibility: .visible) {
            if let g = groupMenu { groupActions(g) }
        }
        .confirmationDialog(L("Merge into…"), isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            ForEach(groups.filter { $0 != merging }, id: \.self) { target in
                Button(display(target)) { if let m = merging { update { $0.merged[m] = target } } }
            }
        }
    }

    private func display(_ g: String) -> String { c.renamed[Customization.groupKey(g)] ?? g }

    @ViewBuilder private func groupRow(_ g: String, index: Int) -> some View {
        let key = Customization.groupKey(g)
        // build 128: verbergen van een categorie = categorie uit voor dit profiel (zoals in Categorieën aan/uit)
        let hidden = pid.map { store.isCategoryHidden($0, g) } ?? false
        let locked = pid.map { CloudStore.shared.parental.lockedGroups.contains("\($0.uuidString)|\(g)") } ?? false
        let label = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(display(g)).foregroundStyle(hidden ? Theme.secondary : .white).strikethrough(hidden)
                if display(g) != g { Text(g).font(.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            if locked { Image(systemName: "lock.fill").foregroundStyle(Theme.imdb) }
            if hidden { Image(systemName: "eye.slash").foregroundStyle(Theme.secondary) }
        }
        Group {
            if section == .live {
                NavigationLink { ChannelsManageView(group: g) } label: { label }
                    .contextMenu { groupActions(g) }
            } else {
                // films/series: tik = acties (er is geen zenderlijst om te openen)
                Button { groupMenu = g } label: { label.contentShape(Rectangle()) }
                    .contextMenu { groupActions(g) }
            }
        }
        #if !os(tvOS)
        .swipeActions {
            Button { toggleCategory(g, hidden) } label: {
                Label(hidden ? L("Show") : L("Hide"), systemImage: hidden ? "eye" : "eye.slash")
            }.tint(.gray)
            Button { renaming = RenameTarget(id: key, current: display(g)) } label: { Label(L("Rename"), systemImage: "pencil") }.tint(.blue)
        }
        #endif
    }

    @ViewBuilder private func groupActions(_ g: String) -> some View {
        let key = Customization.groupKey(g)
        // build 128: verbergen van een categorie = categorie uit voor dit profiel (zoals in Categorieën aan/uit)
        let hidden = pid.map { store.isCategoryHidden($0, g) } ?? false
        let locked = pid.map { CloudStore.shared.parental.lockedGroups.contains("\($0.uuidString)|\(g)") } ?? false
        Button { renaming = RenameTarget(id: key, current: display(g)) } label: { Label(L("Rename"), systemImage: "pencil") }
        Button { toggleCategory(g, hidden) } label: {
            Label(hidden ? L("Show") : L("Hide"), systemImage: hidden ? "eye" : "eye.slash")
        }
        Button { merging = g } label: { Label(L("Merge into…"), systemImage: "arrow.triangle.merge") }
        if CloudStore.shared.parental.enabled, let pid {
            Button {
                if !locked { parental.setLocked(true, playlist: pid, group: g) }
                else if !parental.hasPIN { parental.setLocked(false, playlist: pid, group: g) }
                else {
                    // eerst het menu laten sluiten, anders verschijnt het pincodeblad niet
                    let t = UnlockTarget(playlist: pid, group: g)
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 350_000_000); unlocking = t }
                }
            } label: {
                Label(locked ? L("Unlock") : L("Lock with PIN"), systemImage: locked ? "lock.open" : "lock")
            }
        }
        if section == .live {
            Button { moveGroup(g, by: -1) } label: { Label(L("Move up"), systemImage: "arrow.up") }
            Button { moveGroup(g, by: 1) } label: { Label(L("Move down"), systemImage: "arrow.down") }
        }
    }

    private func toggleCategory(_ g: String, _ hidden: Bool) {
        guard let pid else { return }
        store.setCategories([(pid, g)], hidden: !hidden)
    }

    private func update(_ change: (inout Customization) -> Void) {
        guard let pid else { return }
        store.updateCustomization(pid, change)
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var g = groups
        g.move(fromOffsets: from, toOffset: to)
        update { $0.groupOrder = g }
    }

    private func moveGroup(_ group: String, by step: Int) {
        var g = groups
        guard let i = g.firstIndex(of: group) else { return }
        let j = min(max(i + step, 0), g.count - 1)
        g.swapAt(i, j)
        update { $0.groupOrder = g }
    }
}

/// Zenders binnen één groep beheren.
struct ChannelsManageView: View {
    let group: String
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @State private var renaming: ManageView.RenameTarget?
    @State private var menuFor: Channel?

    private var pid: UUID? { playlists.source?.id }
    private var c: Customization { pid.map { store.customization($0) } ?? Customization() }

    private var channels: [Channel] {
        let list = playlists.rawLibrary.channels.filter { $0.group == group || c.merged[$0.group] == group }
        guard let order = c.channelOrder[group], !order.isEmpty else { return list }
        let idx = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { (idx[$0.element.id] ?? 10_000 + $0.offset) < (idx[$1.element.id] ?? 10_000 + $1.offset) }.map(\.element)
    }

    var body: some View {
        List {
            ForEach(channels) { ch in
                let hidden = c.hidden.contains(ch.id)
                // tikken (of op Apple TV: selecteren) opent de acties; vasthouden geeft hetzelfde menu
                Button { menuFor = ch } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: ch.logo, contentMode: .fit, placeholder: String(ch.name.prefix(3)))
                            .frame(width: tvScaled(44), height: tvScaled(28))
                        Text(c.renamed[ch.id] ?? ch.name).strikethrough(hidden).foregroundStyle(hidden ? Theme.secondary : .white)
                        Spacer()
                        if hidden { Image(systemName: "eye.slash").foregroundStyle(Theme.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .contextMenu { channelActions(ch) }
                #if !os(tvOS)
                .swipeActions {
                    Button { toggleHidden(ch.id) } label: { Label(hidden ? L("Show") : L("Hide"), systemImage: "eye.slash") }.tint(.gray)
                    Button { renaming = .init(id: ch.id, current: c.renamed[ch.id] ?? ch.name) } label: { Label(L("Rename"), systemImage: "pencil") }.tint(.blue)
                }
                #endif
            }
            .onMove(perform: move)
        }
        .navigationTitle(group)
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .confirmationDialog(menuFor.map { c.renamed[$0.id] ?? $0.name } ?? "",
                            isPresented: Binding(get: { menuFor != nil }, set: { if !$0 { menuFor = nil } }),
                            titleVisibility: .visible) {
            if let ch = menuFor { channelActions(ch) }
        }
        .sheet(item: $renaming) { t in
            RenameSheet(title: t.current) { new in
                guard let pid else { return }
                store.updateCustomization(pid) { $0.renamed[t.id] = new.isEmpty ? nil : new }
            }
        }
    }

    @ViewBuilder private func channelActions(_ ch: Channel) -> some View {
        let hidden = c.hidden.contains(ch.id)
        Button { renaming = .init(id: ch.id, current: c.renamed[ch.id] ?? ch.name) } label: { Label(L("Rename"), systemImage: "pencil") }
        Button { toggleHidden(ch.id) } label: { Label(hidden ? L("Show") : L("Hide"), systemImage: hidden ? "eye" : "eye.slash") }
        Button { moveChannel(ch.id, by: -1) } label: { Label(L("Move up"), systemImage: "arrow.up") }
        Button { moveChannel(ch.id, by: 1) } label: { Label(L("Move down"), systemImage: "arrow.down") }
    }

    private func toggleHidden(_ id: String) {
        guard let pid else { return }
        store.updateCustomization(pid) { if $0.hidden.contains(id) { $0.hidden.remove(id) } else { $0.hidden.insert(id) } }
    }
    private func move(_ from: IndexSet, _ to: Int) {
        var ids = channels.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        save(ids)
    }
    private func moveChannel(_ id: String, by step: Int) {
        var ids = channels.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        ids.swapAt(i, min(max(i + step, 0), ids.count - 1))
        save(ids)
    }
    private func save(_ ids: [String]) {
        guard let pid else { return }
        store.updateCustomization(pid) { $0.channelOrder[group] = ids }
    }
}

struct RenameSheet: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text)
                Text(L("Leave empty to restore the original name.")).font(.caption).foregroundStyle(Theme.secondary)
            }
            .navigationTitle(L("Rename"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save")) { onSave(text.trimmingCharacters(in: .whitespaces)); dismiss() } }
            }
        }
        .onAppear { text = title }
    }
}
