import Foundation
import SwiftUI
import UserNotifications

/// Kinderslot: pincode in de iCloud-sleutelhanger, groepen op slot, sessie-ontgrendeling.
@MainActor
final class ParentalControl: ObservableObject {
    static let shared = ParentalControl()
    @Published private(set) var unlockedUntil: Date?

    private let pinKey = "parental.pin"
    nonisolated private static let adultWords = ["adult", "xxx", "18+", "+18", "porn", "erotic", "erotiek", "for adults"]

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
    nonisolated static func isAdultGroup(_ g: String) -> Bool {
        let l = g.lowercased()
        return adultWords.contains { l.contains($0) }
    }

    /// Minimumleeftijd uit een classificatie (IMDb/OMDb "Rated", TMDB: PG-13, TV-MA, 16, AL, …). nil = onbekend.
    nonisolated static func minimumAge(_ rated: String?) -> Int? {
        guard let r = rated?.uppercased().trimmingCharacters(in: .whitespaces), !r.isEmpty, r != "N/A",
              r != "NOT RATED", r != "UNRATED", r != "NR" else { return nil }
        // "Approved"/"Passed" (oude VS-films) zeggen niets over de leeftijd: als onbekend behandelen
        let table: [String: Int] = [
            "G": 0, "TV-Y": 0, "TV-G": 0, "AL": 0, "U": 0, "ALL": 0, "UC": 0,
            "TV-Y7": 7, "TV-Y7-FV": 7, "PG": 9, "TV-PG": 10,
            "PG-13": 13, "TV-14": 14, "12A": 12, "M": 15, "MA15+": 15, "MA 15+": 15,
            "R": 17, "TV-MA": 17, "NC-17": 18, "X": 18, "R18+": 18, "R18": 18, "18": 18
        ]
        if let v = table[r] { return v }
        // getallen ("12", "16+", "FSK 12", "K-12"): geen string-vergelijking, maar het getal zelf
        let digits = r.filter(\.isNumber)
        if let n = Int(digits), n <= 21 { return n }
        return nil
    }

    /// Mag dit profiel dit zien?
    func allowed(rated: String?, group: String, limit: Int?, genre: String? = nil, strict: Bool = false, info: AgeInfo? = nil) -> Bool {
        guard !isUnlocked else { return true }
        return Self.allowedFor(rated: rated, group: group, limit: limit, genre: genre, strict: strict, info: info)
    }

    /// Mag het actieve profiel deze film/serie zien? (Zelfde regel als de afspeellijst.)
    func allowed(movie m: Movie) -> Bool {
        guard let p = CloudStore.shared.activeProfile, let limit = p.effectiveAgeLimit else { return true }
        let meta = MetadataService.shared.cached(m)
        return allowed(rated: meta?.rated, group: m.group, limit: limit, genre: meta?.genre, strict: p.strictAgeFilter,
                       info: AgeRatingService.shared.cached(m))
    }
    func allowed(series s: Series) -> Bool {
        guard let p = CloudStore.shared.activeProfile, let limit = p.effectiveAgeLimit else { return true }
        let meta = MetadataService.shared.cached(s)
        return allowed(rated: meta?.rated, group: s.group, limit: limit, genre: meta?.genre, strict: p.strictAgeFilter,
                       info: AgeRatingService.shared.cached(s))
    }

    /// Dezelfde regel zonder toegang tot de app-status (kan op de achtergrond draaien).
    ///
    /// Bekende leeftijd (TMDB: Kijkwijzer eerst, anders VS/overig; daarna IMDb/OMDb) → alleen t/m de grens.
    /// Onbekende leeftijd bij een kinderprofiel / grens t/m 12 → streng: alleen een kindergroep of
    /// genre animatie/familie/kids, en nooit horror, thriller, misdaad of oorlog.
    nonisolated static func allowedFor(rated: String?, group: String, limit: Int?, genre: String? = nil,
                                       strict: Bool = false, info: AgeInfo? = nil) -> Bool {
        guard let limit else { return true }
        if Self.isAdultGroup(group) { return false }
        if let age = info?.age ?? Self.minimumAge(rated) { return age <= limit }
        guard strict else { return true }
        let tokens = Self.genreTokens(genre)
        if info?.adultGenre == true || !tokens.isDisjoint(with: adultGenres) { return false }
        if Self.isKidsGroup(group) { return true }
        if info?.kidsGenre == true || !tokens.isDisjoint(with: kidsGenres) { return true }
        return false
    }

    /// Zender voor dit profiel? Met een leeftijdsgrens nooit volwassenengroepen; bij een kinderprofiel /
    /// t/m 12 alleen zenders in een kindergroep of met een duidelijke kindernaam (Nickelodeon, Disney Junior …).
    nonisolated static func channelAllowed(name: String, group: String, limit: Int?, strict: Bool) -> Bool {
        guard limit != nil else { return true }
        if isAdultGroup(group) || isAdultGroup(name) { return false }
        guard strict else { return true }
        return isKidsGroup(group) || isKidsGroup(name)
    }

    nonisolated private static let adultGenres: Set<String> = ["horror", "thriller", "crime", "war", "misdaad", "oorlog",
                                                              "war & politics", "erotic", "erotiek", "adult"]
    nonisolated private static let kidsGenres: Set<String> = ["animation", "family", "kids", "children", "animatie",
                                                             "familie", "kinderen", "jeugd"]
    nonisolated private static func genreTokens(_ g: String?) -> Set<String> {
        guard let g, !g.isEmpty else { return [] }
        return Set(g.lowercased().components(separatedBy: CharacterSet(charactersIn: ",/|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    // "anim" stond hier eerst ook in, maar dat raakte "Anime" (vaak niet voor kinderen): nu alleen "animat" (animatie/animation)
    nonisolated private static let kidsWords = ["kid", "kinder", "kinderen", "child", "junior", "jeugd", "cartoon", "animat", "disney",
                                    "nickelodeon", "nick jr", "nicktoons", "pixar", "dreamworks", "family", "familie", "enfant", "jeunesse", "niños", "infantil",
                                    "bambini", "ragazzi", "çocuk", "cocuk", "dzieci", "bajki", "kika", "zapp", "babytv", "baby tv", "boomerang",
                                    "cbeebies", "pbs kids", "toon", "jim jam", "duck tv", "pebble", "أطفال", "儿童", "动画"]
    /// Groep (of zendernaam) met kinderinhoud?
    nonisolated static func isKidsGroup(_ g: String) -> Bool {
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
        #if os(tvOS)
        // Apple TV: compact, één rij cijfers (zoals op tv gebruikelijk) — past op elk scherm, ook met overscan
        VStack(spacing: 34) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Theme.red)
            Text(title).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7).frame(maxWidth: 1100)
            dots(size: 22, spacing: 22)
            HStack(spacing: 14) {
                ForEach(["1","2","3","4","5","6","7","8","9","0","⌫"], id: \.self) { k in
                    Button { tap(k) } label: {
                        Group {
                            if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) }
                        }
                        .font(.system(size: 34, weight: .semibold))
                        .frame(width: 84, height: 84)
                        .background(Theme.elevated, in: Circle())
                    }
                    .plainTVButton()
                }
            }
            .focusSection()
            Button(L("Cancel")) { dismiss() }
        }
        .padding(.vertical, 50).padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #else
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(Theme.red)
                Text(title).font(.system(size: 20, weight: .bold)).multilineTextAlignment(.center)
                dots(size: 16, spacing: 14)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 14), count: 3), spacing: 14) {
                    ForEach(["1","2","3","4","5","6","7","8","9","","0","⌫"], id: \.self) { k in
                        if k.isEmpty { Color.clear.frame(height: 70) } else {
                            Button { tap(k) } label: {
                                Text(k).font(.system(size: 26, weight: .semibold))
                                    .frame(width: 70, height: 70)
                                    .background(Theme.elevated, in: Circle())
                            }
                            .plainTVButton()
                        }
                    }
                }
                Button(L("Cancel")) { dismiss() }.foregroundStyle(Theme.secondary)
            }
            .padding(Theme.edge)
            .padding(.top, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #endif
    }

    private func dots(size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(i < pin.count ? Color.white : Color.white.opacity(0.2))
                    .frame(width: size, height: size)
            }
        }
        .offset(x: shake ? -10 : 0)
        .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: shake)
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
        await scheduleNotification(r)
    }

    /// Melding 2 minuten voor de start (iPhone, iPad, Mac). Ook voor herinneringen uit de Bingr-account.
    func scheduleNotification(_ r: ProgramReminder, ask: Bool = true) async {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        if ask {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        } else {
            let s = await center.notificationSettings()
            granted = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
        guard granted, r.start > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = L("Starts in 2 minutes on %@", r.channelName)
        content.sound = .default
        content.userInfo = ["channelID": r.channelID, "playlistID": r.playlistID.uuidString]
        let fire = max(r.start.addingTimeInterval(-120).timeIntervalSinceNow, 1)
        let req = UNNotificationRequest(identifier: r.id, content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false))
        try? await center.add(req)
        #endif
    }

    /// Melding van een (elders) verwijderde herinnering intrekken.
    func cancelNotification(_ id: String) {
        #if !os(tvOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }

    func remove(_ id: String) {
        CloudStore.shared.removeReminder(id)
        #if !os(tvOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }
}
