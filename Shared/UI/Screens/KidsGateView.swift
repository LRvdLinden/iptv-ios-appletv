import SwiftUI

/// Build 140: ouderpoort. Een kinderprofiel verlaten (profiel wisselen, Mijn Bingr/Instellingen, uitloggen) kan pas
/// na een rekensom, zoals bij NLziet (docs/ACCOUNT.md → "Ouderpoort"). Alleen lokaal; er gaat niets naar de server.
@MainActor
final class KidsGate: ObservableObject {
    static let shared = KidsGate()

    struct Request: Identifiable {
        let id = UUID()
        let action: () -> Void
    }

    /// Wacht op een rekensom (RootView toont dan `KidsGateView`)
    @Published var request: Request?
    /// Mijn Bingr is met een rekensom geopend: acties daarbinnen (profiel wisselen, uitloggen) vragen niet nog eens
    var adultSession = false
    /// Na de rekensom voor "Wissel van profiel": de keuze in "Wie kijkt er?" mag zonder nieuwe som
    private var pickPass = false

    var kidsActive: Bool { CloudStore.shared.activeProfile?.kids == true }

    /// Eerst de rekensom als er een kinderprofiel actief is; anders meteen.
    func require(_ action: @escaping () -> Void) {
        guard kidsActive, !adultSession, !Screenshots.isActive else { action(); return }
        request = Request(action: action)
    }

    /// "Wissel van profiel" of een ander profiel kiezen vanuit een kinderprofiel.
    func requireSwitch(_ action: @escaping () -> Void) {
        require { [weak self] in
            self?.pickPass = true
            action()
        }
    }

    /// "Wie kijkt er?": een profiel kiezen. Was het laatst actieve profiel een kinderprofiel en is het gekozen profiel
    /// dat niet, dan eerst de rekensom (ook na een herstart van de app).
    func pick(_ p: ViewerProfile, _ action: @escaping () -> Void) {
        if p.kids || !kidsActive || pickPass || Screenshots.isActive {
            pickPass = false
            action()
            return
        }
        request = Request(action: action)
    }

    func finish(_ r: Request, passed: Bool) {
        request = nil
        guard passed else { return }
        // eerst het venster laten sluiten, dan pas het volgende scherm (Mijn Bingr, "Wie kijkt er?", bevestiging)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            r.action()
        }
    }
}

/// De rekensom: cijfers met het cijferpaneel (op Apple TV met de afstandsbediening), maximaal 3 pogingen, daarna een
/// nieuwe som. Fout of annuleren = je blijft in het kinderprofiel.
struct KidsGateView: View {
    let onDone: (Bool) -> Void

    @State private var state = ParentGateState()
    @State private var input = ""
    @State private var message: String?
    @State private var shake = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: 0x141414).ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        VStack(spacing: 30) {
            header(icon: 44, title: 40, sum: 64)
            HStack(spacing: 14) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "⌫"], id: \.self) { k in
                    Button { tap(k) } label: {
                        Group { if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) } }
                            .font(.system(size: 34, weight: .semibold))
                            .frame(width: 84, height: 84)
                            .background(Theme.elevated, in: Circle())
                    }
                    .plainTVButton()
                }
            }
            .focusSection()
            HStack(spacing: 40) {
                Button(L("Cancel")) { onDone(false) }
                Button("OK") { check() }.disabled(input.isEmpty)
            }
            .focusSection()
        }
        .padding(.vertical, 50).padding(.horizontal, 60)
        #else
        ScrollView {
            VStack(spacing: 20) {
                header(icon: 36, title: 22, sum: 40)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 14), count: 3), spacing: 14) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK"], id: \.self) { k in
                        Button { tap(k) } label: {
                            Group {
                                if k == "⌫" { Image(systemName: "delete.left") }
                                else { Text(k) }
                            }
                            .font(.system(size: k == "OK" ? 20 : 26, weight: .semibold))
                            .frame(width: 70, height: 70)
                            .background(k == "OK" ? Theme.red.opacity(input.isEmpty ? 0.35 : 0.9) : Theme.elevated, in: Circle())
                        }
                        .plainTVButton()
                        .accessibilityLabel(k == "⌫" ? L("Delete") : k)
                    }
                }
                Button(L("Cancel")) { onDone(false) }.foregroundStyle(Theme.secondary)
            }
            .padding(Theme.edge)
            .padding(.top, 30)
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    private func header(icon: CGFloat, title: CGFloat, sum: CGFloat) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.and.child.holdinghands").font(.system(size: icon)).foregroundStyle(Theme.red)
            Text(L("Ask a grown-up")).font(.system(size: title, weight: .bold)).multilineTextAlignment(.center)
            Text(L("Solve this sum to leave the kids profile."))
                .font(.system(size: title * 0.6)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Text(verbatim: state.sum.text)
                .font(.system(size: sum, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .padding(.top, 6)
                .accessibilityLabel(state.sum.text.replacingOccurrences(of: "×", with: "x"))
            Text(verbatim: input.isEmpty ? " " : input)
                .font(.system(size: sum * 0.8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: sum * 2.6, minHeight: sum * 1.1)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                .offset(x: shake ? -10 : 0)
                .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: shake)
            Text(message ?? " ")
                .font(.system(size: title * 0.6, weight: .semibold))
                .foregroundStyle(Theme.red)
        }
    }

    private func tap(_ k: String) {
        switch k {
        case "⌫": if !input.isEmpty { input.removeLast() }
        case "OK": check()
        default:
            guard input.count < ParentGateState.maxDigits else { return }
            input = ParentGateState.sanitize(input + k)
            message = nil
            if state.readyToCheck(input) { check() }
        }
    }

    private func check() {
        guard !input.isEmpty else { return }
        switch state.submit(input) {
        case .correct:
            onDone(true)
        case .wrong:
            message = L("That's not right. Try again.")
            shake.toggle()
        case .newSum:
            message = L("New sum")
            shake.toggle()
        }
        input = ""
    }
}

extension View {
    /// RootView: de rekensom van `KidsGate` tonen.
    func kidsGateHost(_ gate: KidsGate) -> some View {
        modifier(KidsGateHost(gate: gate))
    }
}

private struct KidsGateHost: ViewModifier {
    @ObservedObject var gate: KidsGate

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $gate.request) { r in
            KidsGateView { passed in gate.finish(r, passed: passed) }
        }
    }
}

/// Mijn Bingr in een kinderprofiel: eerst de rekensom (in het scherm zelf, ook als tabblad op Apple TV).
struct KidsGateInline: View {
    let onPassed: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(spacing: tvScaled(18)) {
            Image(systemName: "figure.and.child.holdinghands").font(.system(size: tvScaled(40))).foregroundStyle(Theme.red)
            Text(L("Ask a grown-up")).font(.system(size: tvScaled(24), weight: .bold))
            Text(L("Solve this sum to leave the kids profile."))
                .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            NetflixButton(title: "OK", icon: "lock.open", kind: .accent) { asking = true }
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(isPresented: $asking) {
            KidsGateView { passed in
                asking = false
                if passed {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        onPassed()
                    }
                }
            }
        }
    }
}
