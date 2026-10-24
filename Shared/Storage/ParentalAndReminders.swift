import Foundation
import SwiftUI
import UserNotifications
import CryptoKit

/// Kinderslot: pincode in de iCloud-sleutelhanger, groepen op slot, sessie-ontgrendeling.
@MainActor
final class ParentalControl: ObservableObject {
    static let shared = ParentalControl()
    @Published private(set) var unlockedUntil: Date?

    private let pinKey = "parental.pin"
    nonisolated private static let adultWords = ["adult", "xxx", "18+", "+18", "porn", "erotic", "erotiek", "for adults"]

    var hasPIN: Bool { Keychain.get(pinKey) != nil }
    var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    /// Build 146: alleen de hash (`PinHash`, PBKDF2) wordt bewaard, nooit de pincode zelf.
    func setPIN(_ pin: String?) { Keychain.set(Self.stored(pin), for: pinKey) }

    init() { loadAttempts() }

    /// Build 143: de pincodes van alle profielen alvast (op de achtergrond) uit de sleutelhanger in het geheugen, zodat
    /// "Wie kijkt er?" (slotje) en het kiezen van een beveiligd profiel meteen het pincodescherm tonen zonder op de
    /// sleutelhanger te wachten.
    func prefetchPINs() {
        let keys = ["parental.pin"] + CloudStore.shared.profiles.map { "profile.\($0.id.uuidString).pin" }
        Keychain.prefetch(keys, localOnly: [Self.attemptsKey])
        migrateLocalPINs()
    }

    func verify(_ pin: String) -> Bool {
        guard attempt({ matches(Keychain.get(pinKey), pin) }) else { return false }
        unlock()
        return true
    }

    /// Alleen controleren (één titel toestaan), zónder de hele bibliotheek te ontgrendelen.
    func check(_ pin: String) -> Bool { attempt { matches(Keychain.get(pinKey), pin) } }

    // MARK: pincode als hash (build 146, docs/ACCOUNT.md "Pincode als hash")

    /// Wat er bewaard wordt: de hash als tekst (nil = geen pincode).
    static func stored(_ pin: String?) -> String? {
        guard let pin, !pin.isEmpty else { return nil }
        return PinHash.make(pin: pin)?.string
    }

    /// Afgeleide sleutels die het pincodescherm buiten de hoofdthread alvast berekende (`prepare`), per salt en iteraties.
    private var derived: [String: Data] = [:]
    private var derivedFor = ""

    /// Pincode tegen de bewaarde waarde (hash, of nog een oude pincode van vóór build 146). Gebruikt een al
    /// berekende afleiding van `prepare` als die er is (anders hier afleiden).
    private func matches(_ stored: String?, _ pin: String) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        if let h = PinHash(string: stored) {
            if derivedFor == pin, let d = derived[Self.derivationKey(h)] { return PinHash.constantTimeEqual(d, h.hash) }
            return h.verify(pin)
        }
        return PinHash.matches(stored: stored, pin: pin)
    }

    nonisolated private static func derivationKey(_ h: PinHash) -> String { "\(h.iter)|\(h.salt.base64EncodedString())" }

    /// Pincodescherm: de PBKDF2-afleiding voor alle bewaarde hashes buiten de hoofdthread berekenen (100.000 iteraties),
    /// zodat de controle daarna meteen klaar is. Daarna wordt de pincode met `verify`/`check` gecontroleerd (met de
    /// wachttijd na foute pogingen zoals altijd).
    func prepare(_ pin: String) async {
        let keys = ["parental.pin"] + Keychain.keys(withPrefix: "profile.").filter { $0.hasSuffix(".pin") }
        let hashes = keys.compactMap { Keychain.get($0).flatMap(PinHash.init(string:)) }
        guard !hashes.isEmpty, PinHash.isValidPIN(pin) else { return }
        let out = await Task.detached(priority: .userInitiated) { () -> [String: Data] in
            var r: [String: Data] = [:]
            for h in hashes where r[Self.derivationKey(h)] == nil {
                if let d = PinHash.derive(pin: pin, salt: h.salt, iterations: h.iter) { r[Self.derivationKey(h)] = d }
            }
            return r
        }.value
        derived = out
        derivedFor = pin
    }

    /// Na de controle de afgeleide sleutels weer vergeten.
    func forgetPrepared() {
        derived = [:]
        derivedFor = ""
    }

    /// Oude lokale pincodes (t/m build 145 stond de pincode zelf hier) meteen hashen, buiten de hoofdthread. De tijd van
    /// de pincode (`pinUpdatedAt`) verandert daardoor niet (zie `consumeMigration`).
    func migrateLocalPINs() {
        guard !migrating else { return }
        migrating = true
        Task { @MainActor in
            defer { self.migrating = false }
            // niet tijdens het opstarten: pas na het eerste beeld (zoals de overzetting van build 144)
            var waited = 0
            while !StartDiagnostics.shared.has("eerste frame") && waited < 60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await Keychain.waitForMigration()
            let keys = ["parental.pin"] + Keychain.keys(withPrefix: "profile.").filter { $0.hasSuffix(".pin") }
            let legacy: [(String, String)] = keys.compactMap { k in
                guard let v = Keychain.get(k), PinHash.isLegacyPlain(v), PinHash.isValidPIN(v) else { return nil }
                return (k, v)
            }
            guard !legacy.isEmpty else { return }
            let hashed = await Task.detached(priority: .utility) { () -> [(String, String, String)] in
                legacy.compactMap { pair in PinHash.make(pin: pair.1).map { (pair.0, pair.1, $0.string) } }
            }.value
            var marks = UserDefaults.standard.dictionary(forKey: Self.migratedKey) as? [String: String] ?? [:]
            for (k, old, hashedValue) in hashed where Keychain.get(k) == old {
                marks[k] = Self.fingerprint(hashedValue)
                UserDefaults.standard.set(marks, forKey: Self.migratedKey)
                Keychain.set(hashedValue, for: k)
            }
            self.objectWillChange.send()
        }
    }
    private var migrating = false
    nonisolated private static let migratedKey = "pin.migrated.v146"

    nonisolated static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// StateSync: is deze nieuwe lokale waarde alleen de omzetting van de oude pincode naar een hash? Dan telt het niet
    /// als een nieuwe pincode (`pinUpdatedAt` blijft). Eenmalig per omzetting.
    nonisolated static func consumeMigration(key: String, value: String?) -> Bool {
        guard let value else { return false }
        var marks = UserDefaults.standard.dictionary(forKey: migratedKey) as? [String: String] ?? [:]
        guard let fp = marks[key] else { return false }
        marks[key] = nil
        UserDefaults.standard.set(marks, forKey: migratedKey)
        return fp == fingerprint(value)
    }

    // MARK: wachttijd na foute pincodes (build 141)
    // Na 5 foute pogingen een oplopende wachttijd (30 s, 1 min, 5 min, 15 min, daarna 1 uur per poging), voor alle
    // pincodes samen. Alleen op dit apparaat bijgehouden (sleutelhanger, niet gesynchroniseerd), zodat opnieuw
    // starten hem niet wist. Een goede pincode zet de teller terug op nul.

    /// Tot wanneer er geen nieuwe poging mag (nil = nu al).
    @Published private(set) var blockedUntil: Date?
    private var failures = 0
    private static let attemptsKey = "pin.attempts"
    static let freeAttempts = 5
    private static let delays: [TimeInterval] = [30, 60, 5 * 60, 15 * 60, 60 * 60]

    /// Seconden tot een nieuwe poging mag (0 = nu). Nooit langer dan de langste wachttijd (klok teruggezet).
    var waitRemaining: TimeInterval {
        guard let u = blockedUntil else { return 0 }
        return max(0, min(u.timeIntervalSinceNow, Self.delays[Self.delays.count - 1]))
    }

    /// Eén poging: tijdens de wachttijd altijd fout (zonder te vergelijken), daarna tellen.
    private func attempt(_ match: () -> Bool) -> Bool {
        guard waitRemaining <= 0 else { return false }
        let ok = match()
        if ok {
            if failures != 0 || blockedUntil != nil { failures = 0; blockedUntil = nil; saveAttempts() }
        } else {
            failures += 1
            if failures >= Self.freeAttempts {
                let step = min(failures - Self.freeAttempts, Self.delays.count - 1)
                blockedUntil = Date().addingTimeInterval(Self.delays[step])
            }
            saveAttempts()
        }
        return ok
    }

    private func loadAttempts() {
        guard let s = Keychain.getLocalOnly(Self.attemptsKey) else { return }
        let parts = s.split(separator: "|")
        failures = parts.first.flatMap { Int($0) } ?? 0
        if parts.count > 1, let t = Double(parts[1]), t > 0 { blockedUntil = Date(timeIntervalSince1970: t) }
    }

    private func saveAttempts() {
        let value = failures == 0 ? nil : "\(failures)|\(blockedUntil?.timeIntervalSince1970 ?? 0)"
        Keychain.setLocalOnly(value, for: Self.attemptsKey)
    }

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
    /// Build 146: alleen de hash wordt bewaard (en via StateSync als `pinHash` gedeeld).
    func setPIN(_ pin: String?, profile: UUID) { Keychain.set(Self.stored(pin), for: Self.pinKey(for: profile)); objectWillChange.send() }
    /// Juiste pincode voor dit profiel? (Bij het hoofdaccount ook meteen 30 min ontgrendelen.)
    func verify(_ pin: String, profile: UUID) -> Bool {
        guard attempt({ matches(Keychain.get(Self.pinKey(for: profile)), pin) }) else { return false }
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
        return Self.allowedFor(rated: rated, group: group, limit: limit, genre: genre, strict: strict, info: info,
                               kids: CloudStore.shared.activeProfile?.kids ?? false)
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
                                       strict: Bool = false, info: AgeInfo? = nil, kids: Bool = false) -> Bool {
        // build 140: kinderprofiel: alleen uit een kindercategorie (docs/ACCOUNT.md → "Build 140"); een bekende
        // classificatie boven de grens niet, een onbekende wel (hij komt uit een kindercategorie)
        if kids {
            guard KidsCategory.isKids(group) else { return false }
            if let age = info?.age ?? Self.minimumAge(rated) { return age <= (limit ?? 12) }
            return true
        }
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

    /// build 141: groep op slot zetten mag altijd; ontgrendelen alleen na de pincode (zie ManageView).
    func setLocked(_ locked: Bool, playlist: UUID, group: String) {
        let k = "\(playlist.uuidString)|\(group)"
        CloudStore.shared.updateParental { s in
            if locked { s.lockedGroups.insert(k) } else { s.lockedGroups.remove(k) }
        }
    }
}

/// Pincode-invoer (werkt met toetsenbord, afstandsbediening en Siri Remote).
struct PINPad: View {
    let title: String
    /// build 141: false bij het kiezen van een nieuwe pincode (daar geldt geen wachttijd)
    var limited = true
    let onDone: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var parental = ParentalControl.shared
    @State private var pin = ""
    @State private var shake = false
    /// build 146: de pincode wordt gecontroleerd (hash afleiden)
    @State private var checking = false

    /// build 141: melding tijdens de wachttijd na te veel foute pogingen (telt elke seconde af)
    @ViewBuilder private var waitNotice: some View {
        if limited, parental.blockedUntil != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let r = parental.waitRemaining
                if r > 0 {
                    Text(L("Too many wrong attempts. Try again in %@.", Self.format(r)))
                        .font(.footnote).foregroundStyle(Theme.imdb).multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder private var checkingNotice: some View {
        if checking {
            Text(L("Checking…")).font(.footnote).foregroundStyle(Theme.secondary)
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        pad.onAppear {
            StartDiagnostics.shared.mark("pincodescherm")   // build 143
            // start-rooktest (build 143): tijd tot het pincodescherm meten en de testcode invoeren
            guard let code = SmokeTest.pinShown() else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if onDone(code) { dismiss() }
            }
        }
    }

    @ViewBuilder private var pad: some View {
        #if os(tvOS)
        // Apple TV: compact, één rij cijfers (zoals op tv gebruikelijk) — past op elk scherm, ook met overscan
        VStack(spacing: 34) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Theme.red)
            Text(title).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7).frame(maxWidth: 1100)
            dots(size: 22, spacing: 22)
            waitNotice
            checkingNotice
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
                waitNotice
                checkingNotice
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
        guard !checking else { return }
        if k == "⌫" { if !pin.isEmpty { pin.removeLast() }; return }
        guard pin.count < 4 else { return }
        // build 141: tijdens de wachttijd geen invoer
        if limited, parental.waitRemaining > 0 { shake.toggle(); pin = ""; return }
        pin += k
        if pin.count == 4 {
            // build 146: de hash (PBKDF2) eerst buiten de hoofdthread afleiden, dan pas controleren
            let entered = pin
            checking = true
            Task { @MainActor in
                // build 147: altijd vooraf afleiden (ook zonder wachttijd), nooit PBKDF2 op de hoofdthread
                await parental.prepare(entered)
                let ok = onDone(entered)
                parental.forgetPrepared()
                checking = false
                if ok { StartDiagnostics.shared.mark("pincode goed"); dismiss() } else { shake.toggle(); pin = "" }
            }
        }
    }
}

/// Herinneringen voor programma's: melding op iPhone/iPad, banner in de app op Apple TV.
/// Per profiel: elk profiel zet, ziet en verwijdert alleen zijn eigen herinneringen (`CloudStore.reminderID`), maar
/// meldingen en de banner komen voor de herinneringen van álle profielen, met de profielnaam erbij.
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

    /// Herinnering voor het actieve profiel (elk profiel heeft zijn eigen herinneringen, ook een kinderprofiel).
    func add(channel: Channel, program: EPGProgram, playlist: UUID) async {
        let store = CloudStore.shared
        let owner = store.activeProfileID ?? store.mainProfileID
        let r = ProgramReminder(id: store.reminderID(channelID: channel.id, start: program.start), playlistID: playlist,
                                channelID: channel.id, channelName: channel.name, title: program.title, start: program.start,
                                profileID: owner == store.mainProfileID ? nil : owner)
        store.addReminder(r)
        await scheduleNotification(r)
    }

    /// Titel van de melding/banner: met de profielnaam als het account meer profielen heeft ("Voor Emma: Journaal").
    func displayTitle(_ r: ProgramReminder) -> String {
        guard let name = CloudStore.shared.reminderProfileName(r) else { return r.title }
        return L("For %@: %@", name, r.title)
    }

    /// Mag de "Kijk"-knop van de banner deze zender openen? Eigen herinnering altijd (de bibliotheek is al gefilterd);
    /// die van een ander profiel niet als het actieve profiel een leeftijdsgrens heeft.
    func canWatch(_ r: ProgramReminder) -> Bool { canWatch(owner: r.owner) }

    /// Zelfde controle voor een herinnering van het profiel `owner` (nil = hoofdprofiel), ook vanuit een pushmelding.
    func canWatch(owner: UUID?) -> Bool {
        let store = CloudStore.shared
        if store.belongsToActive(owner) { return true }
        return store.activeProfile?.effectiveAgeLimit == nil
    }

    /// Melding 2 minuten voor de start (iPhone, iPad, Mac). Ook voor herinneringen uit de Bingr-account.
    /// Met pushmeldingen voor dit account (docs/PUSH.md) stuurt de server de herinnering: dan hier niets plannen.
    func scheduleNotification(_ r: ProgramReminder, ask: Bool = true) async {
        #if !os(tvOS)
        guard !PushService.shared.handlesReminders else { return }
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
        // ook voor herinneringen van een ander profiel dan het actieve: dan met de naam van dat profiel
        content.title = displayTitle(r)
        content.body = L("Starts in 2 minutes on %@", r.channelName)
        content.sound = .default
        var info: [String: String] = ["channelID": r.channelID, "playlistID": r.playlistID.uuidString]
        if let p = r.owner { info["profileID"] = p.uuidString }
        content.userInfo = info
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

    /// Overstap tussen herinneringen via push en lokaal (PushService). Naar push: de geplande lokale herinneringen
    /// opruimen (anders dubbel). Terug naar lokaal (push uit, uitgelogd, geen toestemming): opnieuw plannen.
    func pushModeChanged(_ viaPush: Bool) {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        if viaPush {
            Task {
                let pending = await center.pendingNotificationRequests()
                // alleen herinneringen (die hebben een channelID), geen downloadmeldingen
                let ids = pending.filter { $0.content.userInfo["channelID"] != nil }.map(\.identifier)
                if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
            }
        } else {
            let upcoming = CloudStore.shared.reminders.filter { $0.start.addingTimeInterval(-120) > Date() }
            Task { @MainActor in
                for r in upcoming { await self.scheduleNotification(r, ask: false) }
            }
        }
        #endif
    }

    func remove(_ id: String) {
        CloudStore.shared.removeReminder(id)
        #if !os(tvOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }
}
