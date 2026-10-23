import Foundation
import Combine

// MARK: - Start-rooktest (CI, build 141)
//
// Alleen in een Debug-build en alleen met het launch-argument `-BingrSmoke YES` (workflow Build, stap "Start-rooktest").
// De app start dan als een terugkerende gebruiker zonder Bingr-account (geen netwerk naar de server): bij de eerste
// start zet hij een M3U-server met inloggegevens in het adres (zoals de meeste gebruikers; dat raakt de overzetting naar
// de sleutelhanger van build 141), een hoofdprofiel en een kinderprofiel, Mijn lijst en voortgang. Daarna opent hij
// vanzelf het laatst actieve profiel en loopt hij alle tabbladen langs, zodat Home, Live TV, Films, Series,
// Categorieën, Zoeken en Mijn Bingr echt getekend worden. Een tweede start (zelfde installatie) test de opgeslagen stand.
// Het M3U-adres (`-BingrSmokeM3U http://127.0.0.1:…`) is een lokale testserver van de workflow met verzonnen titels.
// In de App Store-build (Release, zonder BINGR_SMOKE) is dit altijd uit.

enum SmokeTest {
    static let isActive: Bool = {
        // DEBUG, of BINGR_SMOKE: de Release-build die de workflow alleen voor deze test maakt (zoals de App Store-build,
        // met optimalisaties); de Release-build voor de App Store heeft BINGR_SMOKE nooit
        #if DEBUG || BINGR_SMOKE
        return flag("-BingrSmoke")
        #else
        return false
        #endif
    }()

    /// `-BingrSmokeKids YES`: het kinderprofiel is het laatst actieve profiel (ouderpoort, kinderfilter)
    static var startInKids: Bool { flag("-BingrSmokeKids") }
    /// Met een Bingr-account (tijdelijk testaccount van de workflow): `-BingrSmokeEmail` en `-BingrSmokePassword`.
    /// Dan inloggen zoals in het inlogscherm, met de echte account-sync (profielen, servers, lijsten, categorieën).
    static var accountEmail: String? { isActive ? arg("-BingrSmokeEmail") : nil }
    private static var accountPassword: String? { isActive ? arg("-BingrSmokePassword") : nil }
    /// Zonder account: Bingr-accounts uit (geen server)
    static var offline: Bool { isActive && accountEmail == nil }
    /// `-BingrSmokeNoSeed YES`: geen eigen testgegevens (tweede apparaat: alles komt van het account)
    private static var noSeed: Bool { flag("-BingrSmokeNoSeed") }

    private static func flag(_ name: String) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return false }
        return ["yes", "true", "1"].contains(args[i + 1].lowercased())
    }

    private static func arg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Naar stderr (niet gebufferd), zodat de workflow het ook ziet als de app daarna crasht
    static func say(_ s: String) {
        let t = String(format: "%.0f", Date().timeIntervalSince(started))
        FileHandle.standardError.write(Data(("BINGR_SMOKE: [\(t)s] " + s + "\n").utf8))
    }
    private static let started = Date()

    // MARK: build 143: trage sleutelhanger, hangende hoofdthread en de tijd tot het pincodescherm

    /// `-BingrSmokeKeychainMs <ms>`: elke sleutelhanger-aanroep zoveel trager (zoals op een echt toestel)
    private static let keychainDelay: UInt32 = { isActive ? UInt32(arg("-BingrSmokeKeychainMs").flatMap { Int($0) } ?? 0) : 0 }()
    private static let statsLock = NSLock()
    private static var mainKeychainCalls = 0

    static func keychainCall() {
        guard isActive else { return }
        if Thread.isMainThread { statsLock.withLock { mainKeychainCalls += 1 } }
        if keychainDelay > 0 { usleep(keychainDelay * 1000) }
    }

    /// Hoofdthread-bewaking: elke 250 ms een tik; staat de hoofdthread langer dan 1 s stil, dan in het log.
    static func startHangMonitor() {
        guard isActive else { return }
        let t = Thread {
            let lock = NSLock()
            while true {
                var answered = false
                DispatchQueue.main.async { lock.lock(); answered = true; lock.unlock() }
                Thread.sleep(forTimeInterval: 0.25)
                var waited = 0.25
                while true {
                    lock.lock(); let ok = answered; lock.unlock()
                    if ok { break }
                    Thread.sleep(forTimeInterval: 0.05); waited += 0.05
                }
                if waited > 1.0 { say(String(format: "hoofdthread hing %.1f s", waited)) }
            }
        }
        t.name = "bingr.smoke.hang"
        t.start()
    }

    static let pickProfile = PassthroughSubject<UUID, Never>()
    private static var pickAt: Date?
    private static var pickPIN: String?

    /// Het pincodescherm verschijnt: tijd sinds het kiezen in het log (> 1 s = fout); geeft de testcode terug.
    static func pinShown() -> String? {
        guard isActive, let t = pickAt, let pin = pickPIN else { return nil }
        let s = Date().timeIntervalSince(t)
        pickAt = nil
        say(String(format: "pincodescherm na %.2f s", s) + (s > 1 ? " BINGR_SMOKE_FAIL (moet binnen 1 s)" : ""))
        return pin
    }

    private static let seededKey = "smoke.seeded.v141"

    /// Vóór alles (eerste opgeslagen eigenschap van BingrApp, vóór CloudStore): de stand van een terugkerende gebruiker
    /// zetten, eenmalig per installatie. Drie servers: een kleine (open) en twee grote (`-BingrSmokeM3U` + `2`/`3`), zodat
    /// ook het geheugen bij veel titels over alle servers (Voor jou, Nieuw op Bingr) getest wordt.
    static func seedIfNeeded() {
        guard isActive else { return }
        let d = UserDefaults.standard
        say("start (seeded=\(d.bool(forKey: seededKey)))")
        startHangMonitor()
        guard !d.bool(forKey: seededKey) else { return }
        if noSeed { d.set(true, forKey: seededKey); return }
        let base = arg("-BingrSmokeM3U") ?? "http://127.0.0.1:9/get"
        func server(_ name: String, _ file: String, _ color: Int) -> PlaylistSource {
            var s = PlaylistSource(name: name, kind: .m3u, avatar: PlaylistAvatar(symbol: "tv", colorIndex: color))
            s.m3uURL = base + file + ".php?username=smoke&password=test&type=m3u_plus&output=ts"
            return s
        }
        let src = server("Smoke", "", 1)
        let big1 = server("Smoke groot 1", "2", 4), big2 = server("Smoke groot 2", "3", 5)
        let main = ViewerProfile(name: "Smoke", avatar: PlaylistAvatar(symbol: "star", colorIndex: 2))
        var kids = ViewerProfile(name: "Kids", avatar: PlaylistAvatar(symbol: "kid01", colorIndex: 3))
        kids.isKids = true
        func put<T: Encodable>(_ v: T, _ key: String) {
            if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
        }
        put([src, big1, big2], "playlists.v1")
        put([main, kids], "profiles.v1")
        put(src.id, "mainsource.v1")
        put(main.id, "mainprofile.v1")
        let sid = src.id.uuidString
        put(Set(["\(sid)|m-smoke-1", "\(sid)|s-smoke-1", "\(big1.id.uuidString)|m-big-7"]), "mylist.v1.\(main.id.uuidString)")
        put(Set(["\(sid)|m-smoke-2"]), "mylist.v1.\(kids.id.uuidString)")
        put(Set(["\(sid)|c-smoke-1"]), "favorites.v1.\(main.id.uuidString)")
        put(Set(["\(sid)|Smoke Films"]), "categories.v1.\(main.id.uuidString)")
        d.set((startInKids ? kids : main).id.uuidString, forKey: "activeProfileID")
        d.set(src.id.uuidString, forKey: "lastPlaylistID")
        d.set(true, forKey: "account.skipped")
        // build 145: bij het openen meteen alle servers bijwerken, zonder vraag ("Servers laden bij openen: Altijd")
        d.set(StartLoad.Mode.always.rawValue, forKey: StartLoad.key)
        d.set(true, forKey: StartLoad.migratedKey)
        d.set(true, forKey: seededKey)
        // build 143: het hoofdprofiel is met een pincode beveiligd (pincodescherm-test)
        Keychain.set(smokePIN, for: "parental.pin")
    }
    static let smokePIN = "2468"

    /// Na de intro: vanzelf het laatst actieve profiel openen, de tabbladen langslopen en daarna wijzigingen zoals een
    /// sync-ronde ze geeft (categorie uit en weer aan, wisselen naar het kinderprofiel en terug), met Home lang in beeld
    /// zodat het billboard een paar keer wisselt.
    @MainActor static func drive(_ app: AppState) {
        guard isActive else { return }
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            await wait(1.5)
            // build 143: startdiagnose van de vorige start
            if let pr = StartDiagnostics.shared.lastProblem {
                say("diagnose vorige start: \(pr.kind.rawValue) bij \(pr.lastMark), \(pr.stack.count) stackregels, fout: \(pr.crash ?? "-")")
            } else {
                say("diagnose vorige start: geen probleem")
            }
            // Apple TV: zonder signal-handler (build 144) is een crash "niet klaar" (laatste mijlpaal en duur)
            #if os(tvOS)
            let reported = [StartDiag.Problem.Kind.crash, .notFinished].contains(StartDiagnostics.shared.lastProblem?.kind ?? .hang)
            #else
            let reported = StartDiagnostics.shared.lastProblem?.kind == .crash
            #endif
            if flag("-BingrSmokeExpectCrashReport"), !reported {
                say("geen crashrapport van de vorige start BINGR_SMOKE_FAIL")
            }
            if app.stage == .auth, let mail = accountEmail, let pw = accountPassword {
                // zoals het inlogscherm: daarna registreert AuthView het apparaat, synct en gaat naar "Wie kijkt er?"
                do { try await AccountService.shared.signIn(email: mail, password: pw); say("ingelogd") }
                catch { say("inloggen mislukt: \(type(of: error))") }
                for _ in 0..<40 where app.stage != .picker && app.stage != .main { await wait(0.5) }
                say("na inloggen: \(app.stage == .picker ? "kies profiel" : "\(app.stage)")")
            }
            let store = CloudStore.shared
            say("account: \(AccountService.shared.isSignedIn ? "ingelogd" : "geen") · servers \(store.playlists.count) · profielen \(store.profiles.count)")
            // build 143: beveiligd profiel kiezen in "Wie kijkt er?": het pincodescherm moet er binnen 1 s zijn
            if app.stage == .picker, !(store.activeProfile?.kids ?? false), let main = store.profiles.first(where: { store.isMain($0) }),
               ParentalControl.shared.hasPIN(profile: main.id) {
                await wait(2)
                pickPIN = Keychain.get(ParentalControl.pinKey(for: main.id))
                pickAt = Date()
                say("beveiligd profiel kiezen")
                pickProfile.send(main.id)
                for _ in 0..<40 where app.stage != .main { await wait(0.25) }
                if pickAt != nil { say("pincodescherm niet verschenen BINGR_SMOKE_FAIL") }
                say("na pincode: \(app.stage == .main ? "profiel open" : "niet open")")
            }
            guard let p = store.activeProfile ?? store.profiles.first else { say("geen profiel"); return }
            say("profiel openen (kids=\(p.kids))")
            let opened = Date()
            // niet nog eens openen als de pincodetest het profiel al opende (anders twee keer laden)
            if app.stage != .main { app.open(profile: p) }
            // build 143: Home binnen 2 s na het kiezen van een profiel (bewaarde lijst, niets ophalen)
            if !StartDiagnostics.shared.has("home") {
                for _ in 0..<40 where !StartDiagnostics.shared.has("home") { await wait(0.1) }
                let s = Date().timeIntervalSince(opened)
                say(String(format: "Home na %.1f s", s) + (s > 2 ? " BINGR_SMOKE_FAIL (moet binnen 2 s)" : ""))
            }
            if flag("-BingrSmokeCrash") {
                await wait(4)
                say("bewust crashen (test van de startdiagnose)")
                StartDiagnostics.forceCrash()
            }
            for tab in [0, 1, 2, 3, 7, 4, 5, 0] {
                await wait(2.5)
                app.selectedTab = tab
                say("tabblad \(tab)")
            }
            #if !os(tvOS)
            app.showMyBingr()
            await wait(2.5)
            app.showingMyBingr = false
            #endif
            await wait(10)
            if let src = store.playlists.first {
                store.setCategories([(src.id, "Smoke Films")], hidden: true)
                say("categorie uit")
                await wait(4)
                store.setCategories([(src.id, "Smoke Films")], hidden: false)
                say("categorie aan")
            }
            await wait(4)
            for q in store.profiles.filter(\.kids) + [p] {
                app.open(profile: q)
                say("profiel \(q.kids ? "kinderen" : "hoofd")")
                await wait(6)
            }
            app.selectedTab = 0
            let calls = statsLock.withLock { mainKeychainCalls }
            say("sleutelhanger op de hoofdthread: \(calls) keer")
            say("klaar")
        }
    }
}
