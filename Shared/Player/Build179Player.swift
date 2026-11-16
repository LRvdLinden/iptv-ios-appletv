import SwiftUI

// Build 179 (versie 1.0.8), punt 5: de zaplijst in de speler met tabs (Alle, Favorieten, categorieën) en zoeken.
// Regels: docs/ACCOUNT.md → "Build 179"; `Build179.zapSearch` en `Build179.zapCategories`.

struct ZapPanel179: View {
    let channels: [Channel]
    let currentID: String?
    let isFavorite: (Channel) -> Bool
    let isLocked: (Channel) -> Bool
    let nowPlaying: (Channel) -> EPGProgram?
    let onPick: (Channel) -> Void
    let onClose: () -> Void

    /// nil = Alle
    @State private var tab: String?
    @State private var tabChosen = false
    @State private var query = ""

    private var tabs: [String] {
        Build179.zapCategories(groups: channels.map(\.group), favorites: channels.map(isFavorite))
    }

    private var currentTab: String? {
        if tabChosen { return tab }
        return channels.first { $0.id == currentID }?.group
    }

    private var shown: [Channel] {
        let inTab: [Channel]
        switch currentTab {
        case nil: inTab = channels
        case Build179.favoritesTab?: inTab = channels.filter(isFavorite)
        case let g?: inTab = channels.filter { $0.group == g }
        }
        // zoeken gaat over alle zenders van het tabblad
        let idx = Build179.zapSearch(query, names: inTab.map(\.name), numbers: inTab.map(\.number))
        return idx.map { inTab[$0] }
    }

    var body: some View {
        BottomPanel173(title: L("Zap"), onClose: onClose) {
            HStack(spacing: tvScaled(10)) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7))
                    TextField(L("Search channels"), text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .font(.system(size: tvScaled(14)))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .plainTVButton()
                            .accessibilityLabel(L("Clear"))
                    }
                }
                .padding(.horizontal, tvScaled(10)).padding(.vertical, tvScaled(6))
                .frame(maxWidth: tvScaled(300))
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: tvScaled(8)))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: tvScaled(6)) {
                        chip(L("All"), selected: currentTab == nil) { tab = nil; tabChosen = true }
                        ForEach(tabs, id: \.self) { t in
                            chip(t == Build179.favoritesTab ? L("Favorites") : CategoryName.display(t), selected: currentTab == t) {
                                tab = t; tabChosen = true
                            }
                        }
                    }
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: tvScaled(12)) {
                        ForEach(shown) { c in
                            Button { onPick(c) } label: { card(c) }
                                #if os(tvOS)
                                .buttonStyle(TVLiftStyle(scale: 1.06))
                                #else
                                .plainTVButton()
                                #endif
                                .id(c.id)
                        }
                        if shown.isEmpty {
                            Text(L("No channels found"))
                                .font(.system(size: tvScaled(13))).foregroundStyle(.white.opacity(0.7))
                                .frame(height: tvScaled(104))
                        }
                    }
                    .padding(.vertical, tvScaled(6))
                }
                .onAppear { if let id = currentID { proxy.scrollTo(id, anchor: .center) } }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: tvScaled(13), weight: selected ? .bold : .regular)).lineLimit(1)
                .padding(.horizontal, tvScaled(12)).padding(.vertical, tvScaled(6))
                .background(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(selected ? Theme.red : .clear, lineWidth: 1.5))
        }
        .plainTVButton()
    }

    private func card(_ c: Channel) -> some View {
        let now = nowPlaying(c)
        let on = c.id == currentID
        return VStack(alignment: .leading, spacing: tvScaled(6)) {
            HStack(spacing: tvScaled(8)) {
                RemoteImage(url: c.logo, contentMode: .fit, placeholder: String(c.name.prefix(3)))
                    .frame(width: tvScaled(44), height: tvScaled(28))
                Text(c.name).font(.system(size: tvScaled(13), weight: .bold)).lineLimit(1)
                if isLocked(c) {
                    Image(systemName: "lock.fill").font(.system(size: tvScaled(10))).foregroundStyle(.white.opacity(0.8))
                }
            }
            Text(now.map { CategoryName.display($0.title) } ?? c.group)
                .font(.system(size: tvScaled(12))).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let now { ProgressBar(value: now.progress).frame(height: 3).clipShape(Capsule()) }
        }
        .padding(tvScaled(10))
        .frame(width: tvScaled(190), height: tvScaled(104), alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: tvScaled(10)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(10)).stroke(on ? Theme.red : .white.opacity(0.1), lineWidth: on ? 2 : 1))
    }
}
