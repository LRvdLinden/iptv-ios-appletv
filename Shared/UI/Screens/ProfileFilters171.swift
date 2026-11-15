import SwiftUI

/// Build 171: zenders verbergen (15), categorieën vastpinnen (17) en titels blokkeren (20), per profiel.
/// Sleutels en filteren: `ProfileHide171` (Shared/Account/Build171.swift); opslag en sync: `CloudStore.updateProfileSet`
/// (state-section `profile.<id>`, velden `hiddenChannels`, `pinnedCategories`, `blockedTitles`).

extension CloudStore {
    func isChannelHidden(_ server: UUID, _ item: String, profile: UUID? = nil) -> Bool {
        ProfileHide171.contains(profileSet(.hiddenChannels, profile: profile), server: server.uuidString, kind: nil, item: item)
    }

    func setChannelHidden(_ server: UUID, _ item: String, _ hidden: Bool, profile: UUID? = nil) {
        let set = profileSet(.hiddenChannels, profile: profile)
        if hidden {
            updateProfileSet(.hiddenChannels, profile: profile, insert: [ProfileHide171.channelKey(server: server.uuidString, item: item)])
        } else {
            updateProfileSet(.hiddenChannels, profile: profile,
                             remove: ProfileHide171.variants(set, server: server.uuidString, kind: nil, item: item))
        }
    }

    func isTitleBlocked(_ server: UUID, _ kind: ProfileHide171.Kind, _ item: String, profile: UUID? = nil) -> Bool {
        ProfileHide171.contains(profileSet(.blockedTitles, profile: profile), server: server.uuidString, kind: kind, item: item)
    }

    func setTitleBlocked(_ server: UUID, _ kind: ProfileHide171.Kind, _ item: String, _ blocked: Bool, profile: UUID? = nil) {
        let set = profileSet(.blockedTitles, profile: profile)
        if blocked {
            updateProfileSet(.blockedTitles, profile: profile,
                             insert: [ProfileHide171.titleKey(server: server.uuidString, kind: kind, item: item)])
        } else {
            updateProfileSet(.blockedTitles, profile: profile,
                             remove: ProfileHide171.variants(set, server: server.uuidString, kind: kind, item: item))
        }
    }

    /// Vastgepinde categorie: sleutel zoals `hiddenCategories` ("<server-id kleine letters>|<categorienaam van de server>")
    func isCategoryPinned(_ server: UUID, _ rawName: String) -> Bool {
        let k = Self.categoryKey(server, rawName)
        return pinnedCategories.contains(k) || pinnedCategories.contains { $0.caseInsensitiveCompare(k) == .orderedSame }
    }

    func setCategoryPinned(_ items: [(UUID, String)], _ pinned: Bool) {
        let keys = Set(items.map { Self.categoryKey($0.0, $0.1) })
        if pinned {
            updateProfileSet(.pinnedCategories, insert: keys)
        } else {
            let lower = Set(keys.map { $0.lowercased() })
            updateProfileSet(.pinnedCategories, remove: pinnedCategories.filter { lower.contains($0.lowercased()) })
        }
    }

    /// Het profiel waarvoor een wijziging achter de pincode van het ouderprofiel moet (kinderprofiel, ouder heeft een pincode)
    func needsParentPIN(for profile: UUID? = nil) -> Bool {
        guard let id = profile ?? activeProfileID, let p = profiles.first(where: { $0.id == id }), p.kids,
              let main = mainProfileID, main != id else { return false }
        return ParentalControl.shared.hasPIN(profile: main)
    }
}

// MARK: - Pincode van het ouderprofiel

/// Een actie die eerst de pincode van het ouderprofiel vraagt (kinderprofiel). Elke host-view heeft zijn eigen blad.
struct ParentGate171Action: Identifiable {
    let id = UUID()
    let run: () -> Void
}

private struct ParentGate171Key: EnvironmentKey {
    static let defaultValue: ((@escaping () -> Void) -> Void)? = nil
}

extension EnvironmentValues {
    /// Build 171: voert een actie uit, in een kinderprofiel pas na de pincode van het ouderprofiel
    var parentGate171: ((@escaping () -> Void) -> Void)? {
        get { self[ParentGate171Key.self] }
        set { self[ParentGate171Key.self] = newValue }
    }
}

private struct ParentGate171Host: ViewModifier {
    @State private var pending: ParentGate171Action?

    func body(content: Content) -> some View {
        content
            .environment(\.parentGate171) { action in
                if CloudStore.shared.needsParentPIN() { pending = ParentGate171Action(run: action) } else { action() }
            }
            .sheet(item: $pending) { p in
                PINPad(title: L("Enter the PIN of the parent profile")) { pin in
                    guard let main = CloudStore.shared.mainProfileID, ParentalControl.shared.verify(pin, profile: main) else { return false }
                    p.run()
                    return true
                }
            }
    }
}

extension View {
    /// Build 171: menu-items voor verbergen/blokkeren in deze view vragen in een kinderprofiel de ouderpincode
    func parentGate171() -> some View { modifier(ParentGate171Host()) }
}

// MARK: - Menu-items

/// "Zender verbergen" in het contextmenu van een zender
struct HideChannelMenuItem: View {
    let channel: Channel
    let server: UUID?
    @Environment(\.parentGate171) private var gate

    var body: some View {
        if let server = channel.sourceID ?? server {
            Button(role: .destructive) {
                let run = { CloudStore.shared.setChannelHidden(server, channel.id, true) }
                if let gate { gate(run) } else if !CloudStore.shared.needsParentPIN() { run() }
            } label: {
                Label(L("Hide channel"), systemImage: "eye.slash")
            }
        }
    }
}

/// "Verbergen voor dit profiel" in het contextmenu of op de detailpagina van een film of serie
struct BlockTitleMenuItem: View {
    let target: DetailTarget
    let server: UUID?
    @Environment(\.parentGate171) private var gate

    var body: some View {
        if let server = target.sourceID ?? server, !DiscoverItem.isExternal(target.id) {
            Button(role: .destructive) {
                let kind: ProfileHide171.Kind
                if case .series = target { kind = .series } else { kind = .movie }
                let id = target.id
                let run = { CloudStore.shared.setTitleBlocked(server, kind, id, true) }
                if let gate { gate(run) } else if !CloudStore.shared.needsParentPIN() { run() }
            } label: {
                Label(L("Hide for this profile"), systemImage: "hand.raised")
            }
        }
    }
}

extension DetailTarget {
    var hideKind171: ProfileHide171.Kind { if case .series = self { return .series }; return .movie }
}

/// Melding op de detailpagina (deeplink, zoeken): de titel is voor dit profiel verborgen
struct BlockedTitleNotice: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: tvScaled(16)) {
                Image(systemName: "hand.raised.fill").font(.system(size: tvScaled(40))).foregroundStyle(Theme.red)
                Text(L("This title is hidden for this profile"))
                    .font(.system(size: tvScaled(22), weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(L("You can show it again in Settings under Blocked titles."))
                    .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary) { onClose() }
            }
            .padding(Theme.edge)
            .frame(maxWidth: tvScaled(560))
        }
    }
}

// MARK: - Instellingen → Profiel

/// Instellingen → Profielen: "Verborgen zenders" en "Geblokkeerde titels"
struct ProfileFiltersSection: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        Section {
            NavigationLink { ProfileFilterListView(field: .hiddenChannels) } label: {
                HStack {
                    Label(L("Hidden channels"), systemImage: "eye.slash")
                    Spacer()
                    if !store.hiddenChannels.isEmpty { Text("\(store.hiddenChannels.count)").foregroundStyle(Theme.secondary) }
                }
            }
            NavigationLink { ProfileFilterListView(field: .blockedTitles) } label: {
                HStack {
                    Label(L("Blocked titles"), systemImage: "hand.raised")
                    Spacer()
                    if !store.blockedTitles.isEmpty { Text("\(store.blockedTitles.count)").foregroundStyle(Theme.secondary) }
                }
            }
        } header: {
            Text(L("Hidden for this profile"))
        } footer: {
            Text(L("Hide a channel or a movie or series with a long press. It disappears from all rows, the guide, search and zapping of this profile."))
        }
    }
}

/// Lijst met verborgen zenders of geblokkeerde titels van een profiel, met "Weer tonen" / "Deblokkeren".
/// Het hoofdprofiel kan ook een ander profiel kiezen (een kinderprofiel: na de pincode van het ouderprofiel).
struct ProfileFilterListView: View {
    let field: CloudStore.ProfileSet171
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    @State private var profile: UUID?
    @State private var askPIN: UUID?

    private var current: UUID? { profile ?? store.activeProfileID }
    private var keys: [String] { store.profileSet(field, profile: current).sorted() }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let image: URL?
    }

    private var rows: [Row] {
        let raw = playlists.rawLibrary
        var channels: [String: Channel] = [:], movies: [String: Movie] = [:], series: [String: Series] = [:]
        for c in raw.channels where channels[c.id] == nil { channels[c.id] = c }
        for m in raw.movies where movies[m.id] == nil { movies[m.id] = m }
        for s in raw.series where series[s.id] == nil { series[s.id] = s }
        return keys.compactMap { k in
            guard let p = ProfileHide171.parse(k) else { return nil }
            let server = store.playlists.first { $0.id.uuidString.lowercased() == p.server }?.name
            switch p.kind {
            case nil:
                let c = channels[p.item]
                return Row(id: k, title: c.map { CategoryName.channel($0.name) } ?? p.item, detail: server, image: c?.logo)
            case .movie?:
                let m = movies[p.item]
                return Row(id: k, title: m?.title ?? p.item, detail: [L("Movie"), server].compactMap { $0 }.joined(separator: " · "), image: m?.poster)
            case .series?:
                let s = series[p.item]
                return Row(id: k, title: s?.title ?? p.item, detail: [L("Series"), server].compactMap { $0 }.joined(separator: " · "), image: s?.poster)
            }
        }
    }

    var body: some View {
        List {
            if store.isMainActive && store.profiles.count > 1 {
                Section {
                    Picker(L("Profile"), selection: Binding(get: { current ?? UUID() }, set: { choose($0) })) {
                        ForEach(store.profiles) { p in Text(p.name).tag(p.id) }
                    }
                }
            }
            Section {
                let list = rows
                if list.isEmpty {
                    Text(field == .hiddenChannels ? L("No hidden channels.") : L("No blocked titles."))
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(list) { r in
                    HStack(spacing: tvScaled(12)) {
                        RemoteImage(url: r.image, contentMode: .fit, placeholder: field == .hiddenChannels ? "tv" : "film", maxPixel: 160)
                            .frame(width: tvScaled(44), height: tvScaled(44))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).lineLimit(2)
                            if let d = r.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Theme.secondary) }
                        }
                        Spacer()
                        Button(field == .hiddenChannels ? L("Show again") : L("Unblock")) {
                            store.updateProfileSet(field, profile: current, remove: [r.id])
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle(field == .hiddenChannels ? L("Hidden channels") : L("Blocked titles"))
        .sheet(item: Binding(get: { askPIN.map { PendingProfile(id: $0) } }, set: { askPIN = $0?.id })) { p in
            PINPad(title: L("Enter the PIN of the parent profile")) { pin in
                guard let main = store.mainProfileID, ParentalControl.shared.verify(pin, profile: main) else { return false }
                profile = p.id
                return true
            }
        }
    }

    private struct PendingProfile: Identifiable { let id: UUID }

    private func choose(_ id: UUID) {
        if store.needsParentPIN(for: id) { askPIN = id } else { profile = id }
    }
}

// MARK: - 17. Categorieën: weergavenaam → namen op de server

/// Build 171: per opgeschoonde weergavenaam de categorienamen zoals de server(s) ze leveren, om vanuit het overzicht
/// "Alle categorieën" vast te pinnen of te verbergen (de sleutels gebruiken de naam van de server, zoals
/// `hiddenCategories`). Gevuld door `PlaylistService.apply` (ook op de achtergrond, dus met een slot).
enum CategoryRaw171 {
    struct Source: Hashable { let server: UUID; let name: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byName: [String: Set<Source>] = [:]

    static func note(display: String, raw: String, server: UUID) {
        let k = CategoryName.mergeKey(display)
        lock.lock(); defer { lock.unlock() }
        if byName.count > 8_000 { byName.removeAll(keepingCapacity: true) }
        var cur = byName[k] ?? []
        guard cur.count < 12 else { return }
        cur.insert(Source(server: server, name: raw))
        byName[k] = cur
    }

    static func sources(_ display: String) -> [Source] {
        lock.lock(); defer { lock.unlock() }
        return Array(byName[CategoryName.mergeKey(display)] ?? [])
    }

    /// Land/regio van een weergavenaam (uit de labels van de bronnen, "NL", "BE" …)
    static func region(_ display: String) -> String? { CategoryRegion171.region(CategoryMerge.labels(display)) }
}

extension CloudStore {
    /// Vastgepind (een van de bronnen achter de weergavenaam)
    func isPinned171(_ display: String) -> Bool {
        guard !pinnedCategories.isEmpty else { return false }
        return CategoryRaw171.sources(display).contains { isCategoryPinned($0.server, $0.name) }
    }

    func setPinned171(_ display: String, _ on: Bool) {
        let src = CategoryRaw171.sources(display)
        guard !src.isEmpty else { return }
        setCategoryPinned(src.map { ($0.server, $0.name) }, on)
    }

    /// Verbergen = de bestaande `hiddenCategories` (voor het hele account)
    func hideCategory171(_ display: String) {
        let src = CategoryRaw171.sources(display)
        guard !src.isEmpty else { return }
        setCategories(src.map { ($0.server, $0.name) }, hidden: true)
    }
}

/// Filterchips boven "Alle categorieën": Alle, Vastgepind en per land/regio
struct CategoryRegionChips: View {
    let regions: [String]
    let hasPinned: Bool
    /// nil = Alle, "★" = vastgepinde categorieën, anders een regio
    @Binding var selection: String?
    static let pinnedTag = "★"

    var body: some View {
        if !regions.isEmpty || hasPinned {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tvScaled(10)) {
                    chip(L("All"), nil)
                    if hasPinned { chip(L("Pinned categories"), Self.pinnedTag, icon: "pin.fill") }
                    ForEach(regions, id: \.self) { r in chip(r, r) }
                }
                .padding(.horizontal, Theme.edge)
                #if os(tvOS)
                .padding(.vertical, 12)
                #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func chip(_ title: String, _ tag: String?, icon: String? = nil) -> some View {
        let on = selection == tag
        return Button { selection = tag } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: tvScaled(13), weight: .semibold))
            .padding(.horizontal, tvScaled(14)).padding(.vertical, tvScaled(7))
            .foregroundStyle(on ? Color.black : .white)
            .background(on ? Color.white : Theme.elevated, in: Capsule())
        }
        .plainTVButton()
    }
}

/// Contextmenu van een categorietegel: vastpinnen/losmaken en verbergen
struct CategoryTileMenu: View {
    let display: String
    @ObservedObject private var store = CloudStore.shared

    var body: some View {
        if !CategoryRaw171.sources(display).isEmpty {
            let pinned = store.isPinned171(display)
            Button { store.setPinned171(display, !pinned) } label: {
                Label(pinned ? L("Unpin") : L("Pin to top"), systemImage: pinned ? "pin.slash" : "pin")
            }
            if !(store.activeProfile?.kids ?? false) {
                Button(role: .destructive) { store.hideCategory171(display) } label: {
                    Label(L("Hide category"), systemImage: "eye.slash")
                }
            }
        }
    }
}
