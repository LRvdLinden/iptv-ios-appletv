import SwiftUI

/// Item dat aan een collectie toegevoegd kan worden ("Aan collectie toevoegen…").
struct CollectionTarget: Identifiable, Hashable {
    let item: CollectionItem
    let title: String
    var poster: URL? = nil
    var id: String { "\(item.type.rawValue)|\(item.id)" }

    static func movie(_ m: Movie) -> CollectionTarget { CollectionTarget(item: .init(type: .movie, id: m.id), title: m.title, poster: m.poster) }
    static func series(_ s: Series) -> CollectionTarget { CollectionTarget(item: .init(type: .series, id: s.id), title: s.title, poster: s.poster) }
    static func channel(_ c: Channel) -> CollectionTarget { CollectionTarget(item: .init(type: .channel, id: c.id), title: c.name, poster: c.logo) }
    static func detail(_ t: DetailTarget) -> CollectionTarget {
        switch t { case .movie(let m): return .movie(m); case .series(let s): return .series(s) }
    }
}

/// Afbeelding van een collectie: eigen plaatje of symbool op een kleurverloop.
struct CollectionArtwork: View {
    let image: CollectionImage
    var size: CGFloat = tvScaled(44)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(image.avatar.gradient)
            if let u = image.imageURL {
                RemoteImage(url: u, contentMode: .fill).frame(width: size, height: size).clipped()
            } else {
                AvatarGlyph(avatar: image.avatar, size: size * 0.45)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// Symbool en kleur kiezen (zelfde keuze als bij de profielen).
struct SymbolColorPicker: View {
    @Binding var avatar: PlaylistAvatar
    /// Is het symbool nu gekozen (en niet bijv. een foto of poster)?
    var active = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tvScaled(10)) {
                ForEach(PlaylistAvatar.symbols, id: \.self) { s in
                    Button { avatar.symbol = s } label: {
                        Image(systemName: s).font(.system(size: tvScaled(20), weight: .semibold))
                            .frame(width: tvScaled(44), height: tvScaled(44)).foregroundStyle(.white)
                            .background(avatar.symbol == s && active ? AnyShapeStyle(avatar.gradient) : AnyShapeStyle(Theme.elevated), in: Circle())
                    }
                    .plainTVButton()
                }
            }.padding(.vertical, 4)
        }
        HStack(spacing: tvScaled(12)) {
            ForEach(0..<PlaylistAvatar.palettes.count, id: \.self) { i in
                Button { avatar.colorIndex = i } label: {
                    Circle().fill(PlaylistAvatar(symbol: "", colorIndex: i).gradient)
                        .frame(width: tvScaled(28), height: tvScaled(28))
                        .overlay(Circle().stroke(.white, lineWidth: avatar.colorIndex == i ? 3 : 0))
                }
                .plainTVButton()
            }
        }
    }
}

// MARK: - Mijn Bingr → Collecties

struct CollectionsView: View {
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @State private var editing: BingrCollection?
    @State private var adding = false
    @State private var deleting: BingrCollection?

    var body: some View {
        let list = store.activeCollections
        List {
            Section {
                if list.isEmpty {
                    Text(L("No collections yet. Make your own rows with your favorite channels, movies and series."))
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(list) { c in
                    row(c, list: list)
                }
                .onDelete { idx in for i in idx { store.deleteCollection(list[i].id) } }
                .onMove { from, to in
                    var ids = list.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    store.reorderCollections(ids)
                }
                Button { adding = true } label: { Label(L("New collection"), systemImage: "plus") }
            } footer: {
                Text(L("Collections are shared with all your devices and appear as rows on Home, and in Live TV, Movies and Series. Hold a channel, movie or series to add it."))
            }
        }
        .navigationTitle(L("Collections"))
        #if os(iOS)
        .toolbar { if !list.isEmpty { EditButton() } }
        #endif
        .sheet(item: $editing) { CollectionEditor(existing: $0) }
        .sheet(isPresented: $adding) { CollectionEditor(existing: nil) }
        .confirmationDialog(L("Delete collection"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { c in
            Button(L("Delete %@", c.name), role: .destructive) { store.deleteCollection(c.id); deleting = nil }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private func row(_ c: BingrCollection, list: [BingrCollection]) -> some View {
        let index = list.firstIndex { $0.id == c.id } ?? 0
        return HStack(spacing: tvScaled(12)) {
            Button { editing = c } label: {
                HStack(spacing: tvScaled(12)) {
                    CollectionArtwork(image: c.image, size: tvScaled(40))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).foregroundStyle(.white)
                        Text(subtitle(c)).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            #if os(tvOS)
            Button { move(c, by: -1, list: list) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
            Button { move(c, by: 1, list: list) } label: { Image(systemName: "chevron.down") }
                .disabled(index == list.count - 1)
            #endif
        }
        .contextMenu {
            Button { editing = c } label: { Label(L("Edit"), systemImage: "pencil") }
            Button(role: .destructive) { deleting = c } label: { Label(L("Delete"), systemImage: "trash") }
        }
    }

    private func subtitle(_ c: BingrCollection) -> String {
        switch c.kind {
        case .manual: return c.items.count == 1 ? L("1 item") : L("%d items", c.items.count)
        case .smart: return L("Smart: %@", c.query)
        }
    }

    private func move(_ c: BingrCollection, by step: Int, list: [BingrCollection]) {
        var ids = list.map(\.id)
        guard let i = ids.firstIndex(of: c.id), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step)
        store.reorderCollections(ids)
    }
}

// MARK: - Collectie maken of bewerken

struct CollectionEditor: View {
    let existing: BingrCollection?
    /// Nieuw vanuit "Aan collectie toevoegen…": dit item komt er meteen in
    var initialItem: CollectionItem? = nil

    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: BingrCollection.Kind = .manual
    @State private var avatar = PlaylistAvatar(symbol: "star", colorIndex: 0)
    @State private var imageURL: String?
    @State private var items: [CollectionItem] = []
    @State private var query = ""
    @State private var channels = true
    @State private var movies = true
    @State private var series = true
    @State private var group = ""
    @State private var sourceID = ""
    @State private var confirmDelete = false
    @State private var loaded = false

    private var draft: BingrCollection {
        var c = existing ?? BingrCollection(name: "")
        c.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        c.kind = kind
        c.image = imageURL != nil ? CollectionImage(symbol: avatar.symbol, colorIndex: avatar.colorIndex, url: imageURL)
                                  : CollectionImage(symbol: avatar.symbol, colorIndex: avatar.colorIndex, url: nil)
        c.items = kind == .manual ? items : []
        c.query = kind == .smart ? query : ""
        var t: [String] = []
        if channels { t.append("channel") }
        if movies { t.append("movie") }
        if series { t.append("series") }
        c.types = t
        c.group = group.isEmpty ? nil : group
        c.sourceID = sourceID.isEmpty ? nil : sourceID
        return c
    }

    private var content: CollectionContent {
        CollectionResolver.resolve(draft, lib: playlists.library, source: playlists.source?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CollectionArtwork(image: draft.image, size: tvScaled(90))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField(L("Name"), text: $name)
                }
                Section {
                    Picker(L("Type"), selection: $kind) {
                        Text(L("Manual")).tag(BingrCollection.Kind.manual)
                        Text(L("Smart")).tag(BingrCollection.Kind.smart)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind == .manual
                         ? L("Add channels, movies and series yourself: hold an item and choose “Add to collection…”.")
                         : L("Fills itself with everything whose title or category contains one of the keywords."))
                }
                if kind == .smart { smartSection } else { manualSection }
                imageSection
                if existing != nil {
                    Section {
                        Button(L("Delete collection"), role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? L("New collection") : L("Edit collection"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (kind == .smart && (query.trimmingCharacters(in: .whitespaces).isEmpty || !(channels || movies || series))))
                }
            }
            .confirmationDialog(L("Delete collection"), isPresented: $confirmDelete) {
                Button(L("Delete"), role: .destructive) {
                    if let existing { store.deleteCollection(existing.id) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder private var smartSection: some View {
        Section {
            TextField(L("Keywords, e.g. sport, football, F1"), text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Toggle(L("Channels"), isOn: $channels)
            Toggle(L("Movies"), isOn: $movies)
            Toggle(L("Series"), isOn: $series)
            Picker(L("Category"), selection: $group) {
                Text(L("All categories")).tag("")
                ForEach(groups, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            if store.playlists.count > 1 || !sourceID.isEmpty {
                Picker(L("Server"), selection: $sourceID) {
                    Text(L("All servers")).tag("")
                    ForEach(store.playlists) { p in Text(p.name).tag(p.id.uuidString) }
                }
                .pickerStyle(.menu)
            }
        } header: { Text(L("Smart collection")) } footer: {
            let c = content
            Text(L("%d channels · %d movies · %d series", c.channels.count, c.movies.count, c.series.count))
        }
    }

    private var groups: [String] {
        let lib = playlists.library
        var out = orderedUnique(lib.channelGroups + lib.movieGroups + lib.seriesGroups)
        if !group.isEmpty && !out.contains(group) { out.insert(group, at: 0) }
        return out
    }

    @ViewBuilder private var manualSection: some View {
        Section {
            if items.isEmpty {
                Text(L("Nothing in this collection yet.")).foregroundStyle(Theme.secondary)
            }
            ForEach(items, id: \.self) { item in
                HStack(spacing: tvScaled(12)) {
                    Image(systemName: icon(item.type)).foregroundStyle(Theme.secondary).frame(width: tvScaled(22))
                    Text(title(item)).lineLimit(1)
                    Spacer()
                    Button { items.removeAll { $0 == item } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove"))
                }
            }
            .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
        } header: { Text(L("Items")) }
    }

    @ViewBuilder private var imageSection: some View {
        Section(L("Image")) {
            SymbolColorPicker(avatar: Binding(get: { avatar }, set: { avatar = $0; imageURL = nil }), active: imageURL == nil)
            let posters = posterChoices
            if !posters.isEmpty {
                Text(L("Or use a poster")).font(.caption).foregroundStyle(Theme.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: tvScaled(10)) {
                        ForEach(posters, id: \.self) { u in
                            Button { imageURL = u.absoluteString } label: {
                                RemoteImage(url: u, contentMode: .fill)
                                    .frame(width: tvScaled(54), height: tvScaled(80)).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(.white, lineWidth: imageURL == u.absoluteString ? 3 : 0))
                            }
                            .plainTVButton()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var posterChoices: [URL] {
        let c = content
        let urls = c.movies.compactMap(\.poster) + c.series.compactMap(\.poster)
        return Array(orderedUnique(urls).prefix(24))
    }

    private func icon(_ t: CollectionItem.Kind) -> String {
        switch t { case .channel: return "tv"; case .movie: return "film"; case .series: return "rectangle.stack" }
    }

    private func title(_ item: CollectionItem) -> String {
        let lib = playlists.library
        switch item.type {
        case .channel: return lib.channels.first { $0.id == item.id }?.name ?? item.id
        case .movie: return lib.movies.first { $0.id == item.id }?.title ?? item.id
        case .series: return lib.series.first { $0.id == item.id }?.title ?? item.id
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let e = existing {
            name = e.name; kind = e.kind; avatar = e.image.avatar; imageURL = e.image.url
            items = e.items; query = e.query
            channels = e.types.contains("channel"); movies = e.types.contains("movie"); series = e.types.contains("series")
            group = e.group ?? ""; sourceID = e.sourceID ?? ""
        } else {
            avatar = PlaylistAvatar.random()
            if PlaylistAvatar.illustrations.contains(avatar.symbol) { avatar.symbol = "star" }
            if let i = initialItem { items = [i] }
        }
    }

    private func save() {
        store.upsertCollection(draft)
        dismiss()
    }
}

// MARK: - Aan collectie toevoegen…

struct AddToCollectionSheet: View {
    let target: CollectionTarget
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let manual = store.activeCollections.filter { $0.kind == .manual }
                    if manual.isEmpty {
                        Text(L("No collections yet.")).foregroundStyle(Theme.secondary)
                    }
                    ForEach(manual) { c in
                        Button { store.toggleInCollection(c.id, target.item) } label: {
                            HStack(spacing: tvScaled(12)) {
                                CollectionArtwork(image: c.image, size: tvScaled(36))
                                Text(c.name).foregroundStyle(.white)
                                Spacer()
                                if c.contains(target.item) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.red)
                                }
                            }
                        }
                    }
                    Button { creating = true } label: { Label(L("New collection"), systemImage: "plus") }
                } header: { Text(target.title) }
            }
            .navigationTitle(L("Add to collection"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
            .sheet(isPresented: $creating) { CollectionEditor(existing: nil, initialItem: target.item) }
        }
    }
}
