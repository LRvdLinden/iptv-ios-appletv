import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// Build 171: "Kijk je nog?" (zoals Netflix). Na 3 afleveringen achter elkaar die automatisch of met Volgende
/// aflevering zijn gestart, of na 2/3/4 uur live of film zonder enige bediening: beeld gedimd met de vraag, en zonder
/// antwoord binnen 30 s pauzeren en `stream_stop` (plek in de streamlimiet en de verbinding bij de aanbieder vrij).
/// De regels staan in `StillWatching171` (Shared/Account/Build171.swift, met zelftest).
enum StillWatchingSettings {
    static let enabledKey = "player.stillWatching"
    static let hoursKey = "player.stillWatchingHours"
    /// Per apparaat (niet gesynct), standaard aan
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var hours: Int {
        StillWatching171.hours(UserDefaults.standard.object(forKey: hoursKey) as? Int ?? StillWatching171.defaultHours)
    }
}

@MainActor
final class StillWatchingModel: ObservableObject {
    enum Phase: Equatable { case watching, asking(Double), paused }

    @Published private(set) var phase: Phase = .watching
    @Published private(set) var secondsLeft = Int(StillWatching171.answerSeconds)
    private var state = StillWatching171(now: Date().timeIntervalSince1970)
    private var loop: Task<Void, Never>?
    #if os(iOS)
    private var volumeObservation: NSKeyValueObservation?
    #endif

    /// Geen antwoord binnen 30 s: de host pauzeert en meldt de stream af
    var onTimeout: (() -> Void)?
    /// Afspelen na "Gepauzeerd": de host start opnieuw op dezelfde plek (live: weer live)
    var onResume: (() -> Void)?
    /// Mag er nu gevraagd worden (er speelt iets, geen foutmelding of limietscherm)
    var canAsk: (() -> Bool)?

    private static var now: Double { Date().timeIntervalSince1970 }

    var isActive: Bool { phase != .watching }

    func start() {
        guard loop == nil else { return }
        state = StillWatching171(now: Self.now)
        #if os(iOS)
        // volume (knoppen op het toestel) telt als bediening
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.interaction() }
        }
        #endif
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        #if os(iOS)
        volumeObservation?.invalidate(); volumeObservation = nil
        #endif
        if phase != .watching { phase = .watching }
    }

    /// Toets, tik, focuswissel, volume of zenderwissel
    func interaction() {
        guard phase == .watching else { return }
        state.interaction(now: Self.now)
    }

    /// Aflevering automatisch of met de knop Volgende aflevering gestart
    func autoEpisodeStarted() { state.autoEpisodeStarted(now: Self.now) }

    /// De app start zelf iets (geen bediening, geen aflevering)
    func programmatic() { state.programmatic(now: Self.now) }

    private func tick() {
        let now = Self.now
        switch phase {
        case .watching:
            guard canAsk?() ?? true,
                  state.shouldAsk(now: now, hours: StillWatchingSettings.hours, enabled: StillWatchingSettings.enabled) else { return }
            secondsLeft = Int(StillWatching171.answerSeconds)
            phase = .asking(now)
        case .asking(let at):
            let left = StillWatching171.secondsLeft(askedAt: at, now: now)
            if left != secondsLeft { secondsLeft = left }
            if StillWatching171.timedOut(askedAt: at, now: now) {
                phase = .paused
                onTimeout?()
            }
        case .paused:
            break
        }
    }

    /// "Verder kijken"
    func keepWatching() {
        state.answered(now: Self.now)
        phase = .watching
    }

    /// "Gepauzeerd: druk op Afspelen om verder te gaan"
    func resume() {
        guard phase == .paused else { keepWatching(); return }
        state.answered(now: Self.now)
        phase = .watching
        onResume?()
    }
}

/// Gedimd beeld met "Kijk je nog?" (Verder kijken / Stoppen), of na 30 s "Gepauzeerd".
struct StillWatchingOverlay: View {
    @ObservedObject var model: StillWatchingModel
    let onStop: () -> Void
    @FocusState private var focus: Field?
    private enum Field: Hashable { case keep, stop, play }

    var body: some View {
        switch model.phase {
        case .watching:
            EmptyView()
        case .asking:
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()
                VStack(spacing: tvScaled(20)) {
                    Text(L("Are you still watching?"))
                        .font(.system(size: tvScaled(28), weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(L("Playback pauses in %d seconds.", model.secondsLeft))
                        .font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                    HStack(spacing: tvScaled(16)) {
                        NetflixButton(title: L("Continue watching"), icon: "play.fill", kind: .play) { model.keepWatching() }
                            .focused($focus, equals: .keep)
                        NetflixButton(title: L("Stop"), icon: "xmark", kind: .secondary) { onStop() }
                            .focused($focus, equals: .stop)
                    }
                }
                .padding(Theme.edge)
            }
            .onAppear { focus = .keep }
            .transition(.opacity)
        case .paused:
            ZStack {
                Color.black.opacity(0.85).ignoresSafeArea()
                VStack(spacing: tvScaled(18)) {
                    Image(systemName: "pause.circle").font(.system(size: tvScaled(48))).foregroundStyle(.white)
                    Text(L("Paused: press Play to continue"))
                        .font(.system(size: tvScaled(22), weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    HStack(spacing: tvScaled(16)) {
                        NetflixButton(title: L("Play"), icon: "play.fill", kind: .play) { model.resume() }
                            .focused($focus, equals: .play)
                        NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary) { onStop() }
                    }
                }
                .padding(Theme.edge)
            }
            .onAppear { focus = .play }
            .transition(.opacity)
        }
    }
}

/// Instellingen → Afspelen: "Vragen of je nog kijkt" en na hoeveel uur (per apparaat)
struct StillWatchingSettingsSection: View {
    @AppStorage(StillWatchingSettings.enabledKey) private var enabled = true
    @AppStorage(StillWatchingSettings.hoursKey) private var hours = StillWatching171.defaultHours

    var body: some View {
        Section {
            Toggle(isOn: $enabled) { Label(L("Ask if you're still watching"), systemImage: "questionmark.bubble") }
            if enabled {
                Picker(L("Live and movies without any input"), selection: $hours) {
                    ForEach(StillWatching171.hourChoices, id: \.self) { h in Text(L("%d hours", h)).tag(h) }
                }
            }
        } footer: {
            Text(L("After 3 episodes in a row without any input, or after this time with live TV or a movie, Bingr asks if you're still watching. Without an answer playback pauses after 30 seconds, so your stream and the connection with your provider are released."))
        }
    }
}

// MARK: - Build 171: bediening vergrendelen (iPhone en iPad)

#if os(iOS)
/// Laag over het hele spelerscherm zolang de bediening vergrendeld is: alle tikken en vegen (ook dubbeltikken en de
/// zijkant) worden opgevangen. Een tik toont een klein slot; 1 s ingedrukt houden ontgrendelt (ringetje loopt vol).
/// De systeemknoppen (volume, zijknop) en de vergrendeling van het toestel werken gewoon.
struct ControlLockOverlay: View {
    let onUnlock: () -> Void
    @State private var showIcon = true
    @State private var progress: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 1) { reveal() }
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in reveal() })
                .accessibilityHidden(true)
            if showIcon {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 4)
                        Circle().trim(from: 0, to: progress)
                            .stroke(Theme.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "lock.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 64, height: 64)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .contentShape(Circle())
                    .onLongPressGesture(minimumDuration: 1, maximumDistance: 40, perform: {
                        progress = 0
                        onUnlock()
                    }, onPressingChanged: { pressing in
                        hideTask?.cancel()
                        if pressing {
                            withAnimation(.linear(duration: 1)) { progress = 1 }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                            scheduleHide()
                        }
                    })
                    .accessibilityLabel(L("Hold to unlock"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onUnlock() }
                    Text(L("Hold to unlock"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 40)
                .transition(.opacity)
            }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    private func reveal() {
        withAnimation(.easeInOut(duration: 0.2)) { showIcon = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showIcon = false }
        }
    }
}
#endif
