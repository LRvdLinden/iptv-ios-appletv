import SwiftUI

/// Build 128: de melding "niet gevonden op je andere servers" met Verwijderen / Zoeken / Annuleren.
extension View {
    func crossServerPrompt(_ prompt: Binding<CrossServer.Prompt?>) -> some View {
        modifier(CrossServerPromptModifier(prompt: prompt))
    }
}

private struct CrossServerSearch: Identifiable {
    let id = UUID()
    let text: String
}

private struct CrossServerPromptModifier: ViewModifier {
    @Binding var prompt: CrossServer.Prompt?
    @State private var search: CrossServerSearch?

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                   presenting: prompt) { p in
                Button(p.removeLabel, role: .destructive) { p.remove() }
                Button(L("Search")) { search = CrossServerSearch(text: p.searchQuery) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { p in
                Text(p.message)
            }
            .fullScreenCover(item: $search) { s in SearchView(modal: true, initialQuery: s.text) }
    }
}

/// Een item van een andere server openen dat (nog) niet gevonden is: zoeken (max. 20 seconden), anders de melding.
@MainActor
enum CrossServerOpen {
    private final class Once { var done = false }

    static func open(key: String, list: CrossServer.ListKind) async -> CrossServer.Outcome {
        let cross = CrossServer.shared
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<CrossServer.Outcome, Never>) in
            Task { @MainActor in
                let o = await cross.open(key: key, list: list)
                if !once.done { once.done = true; c.resume(returning: o) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !once.done { once.done = true; c.resume(returning: .prompt(cross.prompt(key: key, list: list))) }
            }
        }
    }

    /// Titel aangetikt: van een andere server en nog niet gevonden → eerst zoeken; anders meteen `onTarget`.
    static func title(_ t: DetailTarget, list: CrossServer.ListKind, onTarget: @escaping (DetailTarget) -> Void,
                      onPrompt: @escaping (CrossServer.Prompt) -> Void) {
        guard let sid = t.sourceID, CrossServer.shared.isMissing(t) else { onTarget(t); return }
        Task { @MainActor in
            switch await open(key: sid.uuidString + "|" + t.id, list: list) {
            case .movie(let m): onTarget(.movie(m))
            case .series(let s): onTarget(.series(s))
            case .channel: break
            case .prompt(let p): onPrompt(p)
            }
        }
    }

    /// Zender aangetikt (zelfde idee)
    static func channel(_ c: Channel, list: CrossServer.ListKind, onChannel: @escaping (Channel) -> Void,
                        onPrompt: @escaping (CrossServer.Prompt) -> Void) {
        guard let sid = c.sourceID, CrossServer.shared.isMissing(c) else { onChannel(c); return }
        Task { @MainActor in
            switch await open(key: sid.uuidString + "|" + c.id, list: list) {
            case .channel(let x): onChannel(x)
            case .prompt(let p): onPrompt(p)
            default: break
            }
        }
    }
}
