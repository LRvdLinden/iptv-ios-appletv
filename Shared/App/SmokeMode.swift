import Foundation

// MARK: - Start-rooktest (CI, build 141)
//
// Alleen in een Debug-build en alleen met het launch-argument `-BingrSmoke YES` (workflow Build, stap "Start-rooktest").
// De app start dan als een terugkerende gebruiker zonder Bingr-account (geen netwerk naar de server): bij de eerste
// start zet hij een M3U-server met inloggegevens in het adres (zoals de meeste gebruikers; dat raakt de overzetting naar
// de sleutelhanger van build 141), een hoofdprofiel en een kinderprofiel, Mijn lijst en voortgang. Daarna opent hij
// vanzelf het laatst actieve profiel en loopt hij alle tabbladen langs, zodat Home, Live TV, Films, Series,
// Categorieën, Zoeken en Mijn Bingr echt getekend worden. Een tweede start (zelfde installatie) test de opgeslagen stand.
// Het M3U-adres (`-BingrSmokeM3U http://127.0.0.1:…`) is een lokale testserver van de workflow met verzonnen titels.
// In de App Store-build (Release) is dit altijd uit.

enum SmokeTest {
    static let isActive: Bool = {
        #if DEBUG
        return flag("-BingrSmoke")
        #else
        return false
        #endif
    }()

    /// `-BingrSmokeKids YES`: het kinderprofiel is het laatst actieve profiel (ouderpoort, kinderfilter)
    static var startInKids: Bool { flag("-BingrSmokeKids") }

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
        FileHandle.standardError.write(Data(("BINGR_SMOKE: " + s + "\n").utf8))
    }

    private static let seededKey = "smoke.seeded.v141"

    /// Vóór alles (BingrApp.init): de stand van een terugkerende gebruiker zetten, eenmalig per installatie.
    static func seedIfNeeded() {
        guard isActive else { return }
        let d = UserDefaults.standard
        say("start (seeded=\(d.bool(forKey: seededKey)))")
        guard !d.bool(forKey: seededKey) else { return }
        let base = arg("-BingrSmokeM3U") ?? "http://127.0.0.1:9/get.php"
        var src = PlaylistSource(name: "Smoke", kind: .m3u, avatar: PlaylistAvatar(symbol: "tv", colorIndex: 1))
        src.m3uURL = base + "?username=smoke&password=test&type=m3u_plus&output=ts"
        let main = ViewerProfile(name: "Smoke", avatar: PlaylistAvatar(symbol: "star", colorIndex: 2))
        var kids = ViewerProfile(name: "Kids", avatar: PlaylistAvatar(symbol: "kid01", colorIndex: 3))
        kids.isKids = true
        func put<T: Encodable>(_ v: T, _ key: String) {
            if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
        }
        put([src], "playlists.v1")
        put([main, kids], "profiles.v1")
        put(src.id, "mainsource.v1")
        put(main.id, "mainprofile.v1")
        let sid = src.id.uuidString
        put(Set(["\(sid)|m-smoke-1", "\(sid)|s-smoke-1"]), "mylist.v1.\(main.id.uuidString)")
        put(Set(["\(sid)|m-smoke-2"]), "mylist.v1.\(kids.id.uuidString)")
        put(Set(["\(sid)|c-smoke-1"]), "favorites.v1.\(main.id.uuidString)")
        put(Set(["\(sid)|Smoke Films"]), "categories.v1.\(main.id.uuidString)")
        d.set((startInKids ? kids : main).id.uuidString, forKey: "activeProfileID")
        d.set(src.id.uuidString, forKey: "lastPlaylistID")
        d.set(true, forKey: "account.skipped")
        d.set(true, forKey: seededKey)
    }

    /// Na de intro: vanzelf het laatst actieve profiel openen en daarna de tabbladen langslopen.
    @MainActor static func drive(_ app: AppState) {
        guard isActive else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let store = CloudStore.shared
            guard let p = store.activeProfile ?? store.profiles.first else { say("geen profiel"); return }
            say("profiel openen (kids=\(p.kids))")
            app.open(profile: p)
            for tab in [0, 1, 2, 3, 7, 4, 5, 0] {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                app.selectedTab = tab
                say("tabblad \(tab)")
            }
            #if !os(tvOS)
            app.showMyBingr()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            app.showingMyBingr = false
            #endif
            say("klaar")
        }
    }
}
