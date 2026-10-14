import SwiftUI

/// Mijn Bingr → Startscherm: welke rijen Home toont en in welke volgorde (per profiel).
struct HomeLayoutView: View {
    @EnvironmentObject var store: CloudStore
    @State private var rows: [HomeLayout.Row] = []

    var body: some View {
        let collections = store.activeCollections
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                    row(r, index: i, collections: collections)
                }
                .onMove { from, to in
                    rows.move(fromOffsets: from, toOffset: to)
                    save()
                }
            } footer: {
                #if os(tvOS)
                Text(L("Turn rows on or off and move them up or down. Applies to this profile."))
                #else
                Text(L("Turn rows on or off and drag them into your own order. Applies to this profile."))
                #endif
            }
            Section {
                Button(L("Restore default")) {
                    rows = HomeLayout().effective(collections: collections)
                    save()
                }
            }
        }
        .navigationTitle(L("Home screen"))
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .onAppear { rows = store.homeLayout.effective(collections: collections) }
        .onChange(of: store.homeLayout) { _, l in
            // gewijzigd op een ander apparaat
            let fresh = l.effective(collections: store.activeCollections)
            if fresh != rows { rows = fresh }
        }
    }

    private func row(_ r: HomeLayout.Row, index i: Int, collections: [BingrCollection]) -> some View {
        HStack(spacing: tvScaled(12)) {
            Image(systemName: icon(r.key)).foregroundStyle(Theme.secondary).frame(width: tvScaled(24))
            Toggle(HomeLayout.title(r.key, collections: collections), isOn: Binding(
                get: { rows.indices.contains(i) ? rows[i].visible : false },
                set: { v in
                    guard rows.indices.contains(i) else { return }
                    rows[i].visible = v
                    save()
                }))
            #if os(tvOS)
            Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(i == 0)
            Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(i == rows.count - 1)
            #endif
        }
    }

    private func icon(_ key: String) -> String {
        switch key {
        case "continue": return "play.circle"
        case "mylist": return "heart"
        case "recent": return "sparkles"
        case "foryou": return "hand.thumbsup"
        case "top10": return "chart.bar"
        case "live": return "dot.radiowaves.left.and.right"
        case "browse": return "square.grid.2x2"
        case "categories": return "rectangle.grid.1x2"
        case "movies": return "film"
        case "series": return "rectangle.stack"
        default: return "rectangle.stack.badge.plus"
        }
    }

    private func move(_ i: Int, by step: Int) {
        guard rows.indices.contains(i), rows.indices.contains(i + step) else { return }
        rows.swapAt(i, i + step)
        save()
    }

    private func save() {
        store.setHomeLayout(store.homeLayout.applying(rows))
    }
}
