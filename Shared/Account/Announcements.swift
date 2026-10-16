import SwiftUI

/// Mededelingen van de beheerder (build 62), via device-auth `announcements`, zie docs/ACCOUNT.md.
///
/// Bij het starten (na inloggen en het kiezen van een profiel) en bij terugkeer naar de voorgrond
/// (hooguit eens per uur) ophalen. Elke nog niet geziene mededeling wordt één keer getoond; de
/// geziene id's staan lokaal (UserDefaults, max. 200). Een fout of een oudere server → stil negeren.
@MainActor
final class AnnouncementCenter: ObservableObject {
    static let shared = AnnouncementCenter()

    /// De mededeling die nu getoond moet worden (de rest wacht in de rij).
    @Published private(set) var current: AccountService.Announcement?

    private var queue: [AccountService.Announcement] = []
    private var lastFetch: Date?
    private var task: Task<Void, Never>?
    private let seenKey = "announcements.seen"
    private let maxSeen = 200

    private init() {}

    private var seen: [String] {
        get { UserDefaults.standard.stringArray(forKey: seenKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(maxSeen)), forKey: seenKey) }
    }

    /// Ophalen; `force: false` alleen als de vorige keer langer dan een uur geleden is.
    func check(force: Bool = false) {
        guard Secrets.accountsConfigured, AccountService.shared.isSignedIn, task == nil else { return }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 3600 { return }
        lastFetch = Date()
        task = Task { @MainActor in
            defer { self.task = nil }
            guard let items = await AccountService.shared.fetchAnnouncements() else { return }
            let seen = Set(self.seen)
            let waiting = Set(self.queue.map(\.id) + [self.current?.id].compactMap { $0 })
            // oudste eerst tonen
            let fresh = items.filter { !seen.contains($0.id) && !waiting.contains($0.id) }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            self.queue.append(contentsOf: fresh)
            self.showNext()
        }
    }

    /// "OK" (of het venster weggeveegd): als gezien onthouden en de volgende tonen.
    func dismiss() {
        guard let a = current else { return }
        var s = seen
        s.removeAll { $0 == a.id }
        s.append(a.id)
        seen = s
        current = nil
        // even wachten zodat het vorige venster eerst sluit
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.showNext()
        }
    }

    /// Uitgelogd: de rij leegmaken (de geziene id's blijven).
    func reset() {
        queue = []
        current = nil
        lastFetch = nil
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
    }
}

/// Eenvoudig venster in Bingr-stijl: titel, tekst en "OK".
struct AnnouncementSheet: View {
    let announcement: AccountService.Announcement
    let onOK: () -> Void
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        VStack(spacing: tvScaled(18)) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: tvScaled(30)))
                .foregroundStyle(Theme.red)
            if !announcement.title.isEmpty {
                Text(announcement.title)
                    .font(.system(size: tvScaled(22), weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            if !announcement.body.isEmpty {
                ScrollView {
                    Text(announcement.body)
                        .font(.system(size: tvScaled(15)))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: tvScaled(320))
                .fixedSize(horizontal: false, vertical: true)
            }
            okButton
        }
        .padding(tvScaled(28))
        .frame(maxWidth: tvScaled(520))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #elseif os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    @ViewBuilder private var okButton: some View {
        let button = Button(action: onOK) {
            Text(L("OK"))
                .font(.system(size: tvScaled(16), weight: .semibold))
                .frame(minWidth: tvScaled(140))
                .padding(.vertical, tvScaled(4))
                .onAccentLabel()   // goud: donkere tekst op de knop
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.red)
        #if os(tvOS)
        // tvOS: de knop krijgt meteen de focus
        button
            .focused($focused)
            .onAppear { focused = true }
        #else
        button.keyboardShortcut(.defaultAction)
        #endif
    }
}
