import Foundation
import SwiftUI
import UserNotifications

/// Kinderslot: pincode in de iCloud-sleutelhanger, groepen op slot, sessie-ontgrendeling.
@MainActor
final class ParentalControl: ObservableObject {
    static let shared = ParentalControl()
    @Published private(set) var unlockedUntil: Date?

    private let pinKey = "parental.pin"
    private static let adultWords = ["adult", "xxx", "18+", "+18", "porn", "erotic", "erotiek", "for adults"]

    var hasPIN: Bool { Keychain.get(pinKey) != nil }
    var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    func setPIN(_ pin: String?) { Keychain.set(pin, for: pinKey) }

    func verify(_ pin: String) -> Bool {
        guard let stored = Keychain.get(pinKey), stored == pin else { return false }
        unlock()
        return true
    }

    /// Alleen controleren (één titel toestaan), zónder de hele bibliotheek te ontgrendelen.
    func check(_ pin: String) -> Bool { Keychain.get(pinKey) == pin }

    /// 30 min ontgrendelen; daarna gaat het slot vanzelf weer dicht (en wordt de bibliotheek opnieuw gefilterd).
    private func unlock() {
        let until = Date().addingTimeInterval(30 * 60)
        unlockedUntil = until
        relockTask?.cancel()
        relockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled, let self, self.unlockedUntil == until else { return }
            self.unlockedUntil = nil
        }
    }
    private var relockTask: Task<Void, Never>?

    func lock() { relockTask?.cancel(); unlockedUntil = nil }

    // MARK: pincode per profiel
    // Het hoofdaccount gebruikt de kinderslot-pincode ("parental.pin"); elk ander profiel heeft een eigen pincode.

    static func pinKey(for profileID: UUID) -> String {
        CloudStore.shared.mainProfileID == profileID ? "parental.pin" : "profile.\(profileID.uuidString).pin"
    }
    func hasPIN(profile: UUID) -> Bool { Keychain.get(Self.pinKey(for: profile)) != nil }
    func setPIN(_ pin: String?, profile: UUID) { Keychain.set(pin, for: Self.pinKey(for: profile)); objectWillChange.send() }
    /// Juiste pincode voor dit profiel? (Bij het hoofdaccount ook meteen 30 min ontgrendelen.)
    func verify(_ pin: String, profile: UUID) -> Bool {
        guard let stored = Keychain.get(Self.pinKey(for: profile)), stored == pin else { return false }
        if CloudStore.shared.mainProfileID == profile { unlock() }
        return true
    }

    /// Is deze groep op slot (en dus verborgen tot ontgrendeling)?
    func isLocked(playlist: UUID, group: String) -> Bool {
        let s = CloudStore.shared.parental
        guard s.enabled, !isUnlocked else { return false }
        if s.lockedGroups.contains("\(playlist.uuidString)|\(group)") { return true }
        if s.autoLockAdult {
            let g = group.lowercased()
            return Self.adultWords.contains { g.contains($0) }
        }
        return false
    }

    // MARK: leeftijdsfilter per profiel

    static let ageChoices = [6, 9, 12, 16]

    /// Is deze groepsnaam duidelijk voor volwassenen?
    static func isAdultGroup(_ g: String) -> Bool {
        let l = g.lowercased()
        return adultWords.contains { l.contains($0) }
    }

    /// Minimumleeftijd uit een classificatie (IMDb/OMDb "Rated": PG-13, TV-MA, 16, …). nil = onbekend.
    nonisolated static func minimumAge(_ rated: String?) -> Int? {
        guard let r = rated?.uppercased().trimmingCharacters(in: .whitespaces), !r.isEmpty, r != "N/A",
              r != "NOT RATED", r != "UNRATED" else { return nil }
        let table: [String: Int] = [
            "G": 0, "TV-Y": 0, "TV-G": 0, "AL": 0, "U": 0, "ALL": 0, "APPROVED": 0, "PASSED": 0,
            "TV-Y7": 7, "TV-Y7-FV": 7, "PG": 9, "TV-PG": 10, "UC": 0,
            "PG-13": 13, "TV-14": 14, "12A": 12, "M": 15, "MA15+": 15,
            "R": 17, "TV-MA": 17, "NC-17": 18, "X": 18, "R18+": 18, "18": 18
        ]
        if let v = table[r] { return v }
        let digits = r.filter(\.isNumber)
        if let n = Int(digits), n <= 21 { return n }
        return nil
    }

    /// Mag dit profiel dit zien? (Onbekende classificatie = toegestaan, behalve in volwassenengroepen.)
    func allowed(rated: String?, group: String, limit: Int?, genre: String? = nil, strict: Bool = false) -> Bool {
        guard let limit, !isUnlocked else { return true }
        if Self.isAdultGroup(group) { return false }
        let age = Self.minimumAge(rated)
        if let age, age > limit { return false }
        guard strict else { return true }
        // Kinderprofiel / t/m 12 jaar: alleen wat zeker geschikt is — bekende leeftijd binnen de grens,
        // een kindergroep (Kids, Kinderen, Cartoon, Disney…) of genre animatie/familie.
        if age != nil { return true }
        if Self.isKidsGroup(group) { return true }
        if let g = genre?.lowercased(), g.contains("animation") || g.contains("family") { return true }
        return false
    }

    private static let kidsWords = ["kid", "kinder", "kinderen", "child", "junior", "jeugd", "cartoon", "anim", "disney",
                                    "nick", "pixar", "dreamworks", "family", "familie", "enfant", "jeunesse", "niños", "infantil",
                                    "bambini", "ragazzi", "çocuk", "cocuk", "dzieci", "bajki", "kika", "zapp", "baby", "boomerang",
                                    "cbeebies", "pbs kids", "toon", "أطفال", "儿童", "动画"]
    /// Groep met kinderinhoud?
    static func isKidsGroup(_ g: String) -> Bool {
        let l = g.lowercased()
        return !isAdultGroup(g) && kidsWords.contains { l.contains($0) }
    }

    func toggleLock(playlist: UUID, group: String) {
        let k = "\(playlist.uuidString)|\(group)"
        CloudStore.shared.updateParental { s in
            if s.lockedGroups.contains(k) { s.lockedGroups.remove(k) } else { s.lockedGroups.insert(k) }
        }
    }
}

/// Pincode-invoer (werkt met toetsenbord, afstandsbediening en Siri Remote).
struct PINPad: View {
    let title: String
    let onDone: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var shake = false

    var body: some View {
        VStack(spacing: tvScaled(22)) {
            Image(systemName: "lock.fill").font(.system(size: tvScaled(36))).foregroundStyle(Theme.red)
            Text(title).font(.system(size: tvScaled(20), weight: .bold))
            HStack(spacing: tvScaled(14)) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < pin.count ? Color.white : Color.white.opacity(0.2))
                        .frame(width: tvScaled(16), height: tvScaled(16))
                }
            }
            .offset(x: shake ? -10 : 0)
            .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: shake)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(tvScaled(70)), spacing: tvScaled(14)), count: 3), spacing: tvScaled(14)) {
                ForEach(["1","2","3","4","5","6","7","8","9","","0","⌫"], id: \.self) { k in
                    if k.isEmpty { Color.clear.frame(height: tvScaled(70)) } else {
                        Button { tap(k) } label: {
                            Text(k).font(.system(size: tvScaled(26), weight: .semibold))
                                .frame(width: tvScaled(70), height: tvScaled(70))
                                .background(Theme.elevated, in: Circle())
                        }
                        .plainTVButton()
                    }
                }
            }
            Button(L("Cancel")) { dismiss() }.foregroundStyle(Theme.secondary)
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x141414).ignoresSafeArea())
    }

    private func tap(_ k: String) {
        if k == "⌫" { if !pin.isEmpty { pin.removeLast() }; return }
        guard pin.count < 4 else { return }
        pin += k
        if pin.count == 4 {
            if onDone(pin) { dismiss() } else { shake.toggle(); pin = "" }
        }
    }
}

/// Herinneringen voor programma's: melding op iPhone/iPad, banner in de app op Apple TV.
@MainActor
final class ReminderCenter: ObservableObject {
    static let shared = ReminderCenter()
    @Published var due: ProgramReminder?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        check()
    }

    private func check() {
        let now = Date()
        if let r = CloudStore.shared.reminders.first(where: { $0.start <= now.addingTimeInterval(60) && $0.start > now.addingTimeInterval(-300) }) {
            due = r
            CloudStore.shared.removeReminder(r.id)
        }
    }

    func add(channel: Channel, program: EPGProgram, playlist: UUID) async {
        let r = ProgramReminder(id: "\(channel.id)-\(Int(program.start.timeIntervalSince1970))", playlistID: playlist,
                                channelID: channel.id, channelName: channel.name, title: program.title, start: program.start)
        CloudStore.shared.addReminder(r)
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = L("Starts in 2 minutes on %@", r.channelName)
        content.sound = .default
        content.userInfo = ["channelID": r.channelID, "playlistID": r.playlistID.uuidString]
        let fire = max(program.start.addingTimeInterval(-120).timeIntervalSinceNow, 1)
        let req = UNNotificationRequest(identifier: r.id, content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false))
        try? await center.add(req)
        #endif
    }

    func remove(_ id: String) {
        CloudStore.shared.removeReminder(id)
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }
}
