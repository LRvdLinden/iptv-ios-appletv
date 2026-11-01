import SwiftUI
#if !os(tvOS)
import StoreKit
#endif

// Build 160: beoordelingsprompt (StoreKit `requestReview`) op iPhone, iPad en Mac. Apple TV heeft geen
// beoordelingsvenster: daar doet dit niets. De beslisregel staat in Shared/Account/Build160.swift (zelftest in CI).
//
// Waar het afvuurt: op Home (HomeView met filter .all), 5 seconden na het verschijnen van Home, na terugkeer naar het
// tabblad Home of na terugkeer naar de voorgrond. Tijdens die 5 seconden moet het elke seconde rustig blijven; daarna
// beslist `ReviewPolicy160.shouldAsk` (4 uur na het eerste gebruik op dit apparaat, daarna hooguit eens per 7 dagen).

@MainActor
final class ReviewPrompt {
    static let shared = ReviewPrompt()

    /// HomeView: een eigen blad of volledig scherm open (detail, categorie, zoeken, collectie, hervatten, …)
    var homeBusy = false
    /// MainTabView: detail of zoekscherm uit een link open, of een link wordt opgezocht
    var mainBusy = false
    /// Scene op de voorgrond (bijgehouden door de host op Home)
    var appActive = false

    private var store: ReviewStore160 { ReviewStore160() }

    /// Nooit in de rooktest of bij App Store-screenshots
    nonisolated static var specialMode: Bool { SmokeTest.isActive || Screenshots.isActive }

    /// Bij de start: eerste gebruik op dit apparaat vastleggen (lokaal, gaat niet mee met het account)
    nonisolated static func recordFirstUse() {
        #if !os(tvOS)
        guard !specialMode else { return }
        let s = ReviewStore160()
        s.normalize()
        s.recordFirstUseIfNeeded()
        #endif
    }

    /// De toestand van de app nu
    func conditions(app: AppState, playlists: PlaylistService) -> ReviewConditions160 {
        let cloud = CloudStore.shared
        var c = ReviewConditions160()
        c.specialMode = Self.specialMode
        c.appActive = appActive
        c.inMain = app.stage == .main && AccountService.shared.deviceLimit == nil
        c.onHome = (app.selectedTab ?? 0) == 0
        // "Wie kijkt er?" met pincode of ouderpoort: dan is er (nog) geen profiel open
        c.locked = app.stage != .main || cloud.activeProfileID == nil
        c.playing = app.playing != nil || app.showMultiview
        c.pip = PiPCenter.shared.active != nil
        c.kidsProfile = cloud.activeProfile?.kids ?? false
        c.serverCount = cloud.playlists.count
        c.presenting = homeBusy || mainBusy || app.showingMyBingr || app.startPrompt || app.pendingTitleLink != nil
            || playlists.error != nil || playlists.isLoading
            || PushService.shared.showPrompt || ReminderCenter.shared.due != nil || KidsGate.shared.request != nil
        return c
    }

    #if !os(tvOS)
    /// Wacht `settleSeconds` (elke seconde rustig) en vraag dan, als de regel het toestaat. Geeft true als er gevraagd is.
    func runIfDue(app: AppState, playlists: PlaylistService, request: () -> Void) async -> Bool {
        guard !Self.specialMode else { return false }
        let s = store
        // snel klaar als het toch niet mag (te vroeg of te kort geleden)
        var probe = ReviewConditions160()
        probe.serverCount = 1
        guard s.shouldAsk(conditions: probe) else { return false }
        let steps = Int(ReviewPolicy160.settleSeconds)
        for _ in 0..<steps {
            guard conditions(app: app, playlists: playlists).blockers.isEmpty else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return false }
        }
        guard s.shouldAsk(conditions: conditions(app: app, playlists: playlists)) else { return false }
        s.markAsked()
        request()
        return true
    }
    #endif
}

#if !os(tvOS)
/// Op Home: na verschijnen, terugkeer naar het tabblad of naar de voorgrond na 5 rustige seconden de vraag stellen.
private struct ReviewPromptHost: ViewModifier {
    let enabled: Bool
    let busy: Bool
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var phase
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .onAppear {
                ReviewPrompt.shared.homeBusy = busy
                ReviewPrompt.shared.appActive = phase == .active
                if enabled { trigger += 1 }
            }
            .onChange(of: busy) { _, b in ReviewPrompt.shared.homeBusy = b }
            .onChange(of: phase) { _, p in
                ReviewPrompt.shared.appActive = p == .active
                if enabled && p == .active { trigger += 1 }
            }
            .onChange(of: app.selectedTab) { _, t in if enabled && (t ?? 0) == 0 { trigger += 1 } }
            .task(id: trigger) {
                guard enabled, trigger > 0 else { return }
                _ = await ReviewPrompt.shared.runIfDue(app: app, playlists: playlists) {
                    requestReview()
                }
            }
    }
}
#endif

extension View {
    /// Build 160: beoordelingsprompt op Home (iPhone, iPad, Mac); op Apple TV niets
    @ViewBuilder func reviewPromptHost(enabled: Bool, busy: Bool) -> some View {
        #if os(tvOS)
        self
        #else
        modifier(ReviewPromptHost(enabled: enabled, busy: busy))
        #endif
    }
}
