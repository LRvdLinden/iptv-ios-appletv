import Foundation
import Combine

/// Laadt, cachet en presenteert de inhoud van de gekozen afspeellijst.
/// `library` is de inhoud na jouw aanpassingen (hernoemd, verborgen, volgorde,
/// samengevoegd) en zonder groepen die op kinderslot staan.
@MainActor
final class PlaylistService: ObservableObject {
    @Published private(set) var source: PlaylistSource? { didSet { CloudStore.shared.activePlaylistID = source?.id } }
    @Published private(set) var library = Library() { didSet { if !epgOnlyUpdate { libraryVersion &+= 1 } } }
    /// Alleen gidsgegevens van één zender aangevuld (Stalker): de rijen op Home en de collecties blijven gelijk,
    /// dus `libraryVersion` niet ophogen (anders bouwt elk scherm alles opnieuw op)
    private var epgOnlyUpdate = false
    /// Telt op bij elke nieuwe (gefilterde) lijst — schermen bouwen hun rijen dan één keer opnieuw op
    @Published private(set) var libraryVersion = 0
    @Published private(set) var rawLibrary = Library() { didSet { rawVersion &+= 1 } }
    /// Telt op bij elke nieuwe ongefilterde lijst; zo weet het filter of een nieuwe uitkomst echt anders kan zijn
    private var rawVersion = 0
    /// Van welke `rawVersion` de huidige `library` gemaakt is
    private var libraryRawVersion = -1
    /// Met welke regels de huidige `library` gefilterd is
    private var libraryContext: FilterContext?
    @Published private(set) var isLoading = false
    @Published private(set) var loadingText = ""
    /// De open bron wordt op de achtergrond ververst (de bewaarde lijst staat al in beeld)
    @Published private(set) var isRefreshing = false
    @Published var error: String?
    @Published private(set) var episodeCache: [String: [Episode]] = [:]

    private var stalker: StalkerClient?
    private var stremioAddons: [StremioClient.Addon] = []
    private var bag = Set<AnyCancellable>()

    init() {
        // aanpassingen of kinderslot gewijzigd (ook via iCloud) → opnieuw toepassen
        CloudStore.shared.$customizations.combineLatest(CloudStore.shared.$parental)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyCustomizations() }
            .store(in: &bag)
        ParentalControl.shared.$unlockedUntil
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyCustomizations() }
            .store(in: &bag)
        // profiel aangepast (bijv. leeftijdsfilter) → bijwerken
        CloudStore.shared.$playlists
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self, let s = self.source, let u = list.first(where: { $0.id == s.id }), u != s else { return }
                self.source = u
            }
            .store(in: &bag)
        // ander profiel gekozen of leeftijdsgrens van het profiel gewijzigd → opnieuw filteren
        CloudStore.shared.$profiles.combineLatest(CloudStore.shared.$activeProfileID)
            .map { list, id in list.first { $0.id == id }.map { "\($0.effectiveAgeLimit ?? 0)-\($0.strictAgeFilter)-\($0.kids)" } }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyCustomizations() }
            .store(in: &bag)
        // build 140: categorieën aan/uit voor het account gewijzigd (ook via de sync) → opnieuw filteren. Build 140:
        // even wachten, zodat een reeks tikken in Instellingen → Categorieën één keer filtert (niet per tik)
        CloudStore.shared.$hiddenCategories
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyCustomizations() }
            .store(in: &bag)
        // nieuwe IMDb-classificaties binnen → leeftijdsfilter opnieuw toepassen
        MetadataService.shared.$cache
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                if CloudStore.shared.activeProfile?.effectiveAgeLimit != nil { self?.refilterWhenIdle() }
            }
            .store(in: &bag)
        // nieuwe TMDB-classificaties (Kijkwijzer) binnen → idem (build 53)
        AgeRatingService.shared.$cache
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                if CloudStore.shared.activeProfile?.effectiveAgeLimit != nil { self?.refilterWhenIdle() }
            }
            .store(in: &bag)
    }

    private var idleRefilter: Task<Void, Never>?
    /// Nieuwe classificaties binnen (build 56): opnieuw filteren zodra er niet meer gescrold wordt. Het filter loopt
    /// door de hele bibliotheek; midden in het scrollen gaf dat haperingen.
    private func refilterWhenIdle() {
        idleRefilter?.cancel()
        idleRefilter = Task { [weak self] in
            await ScrollActivity.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            self?.applyCustomizations()
        }
    }

    // MARK: laden

    func select(_ s: PlaylistSource, forceRefresh: Bool = false) async {
        source = s
        // App Store-screenshots: de demo-bibliotheek uit het geheugen, geen netwerk en geen cache
        if Screenshots.isActive {
            stalker = nil; episodeCache = [:]; error = nil
            setRaw(ScreenshotDemo.library)
            return
        }
        stalker = s.kind == .stalker ? StalkerClient(source: s) : nil
        episodeCache = [:]
        error = nil

        // grote lijsten (tienduizenden titels) inlezen op de achtergrond, niet op het scherm wachten
        var cached: Library? = nil
        if !forceRefresh {
            isLoading = true
            cached = await Task.detached(priority: .userInitiated) { Self.readCache(s) }.value
            isLoading = false
        }
        guard source?.id == s.id else { return }   // intussen een andere bron gekozen
        if let cached {
            setRaw(cached)
            // build 140: volgens de instelling alle servers van het account die aan de beurt zijn. Build 141: de open
            // server meteen, de andere pas later en één voor één (zie `refreshIfDue`)
            scheduleAutoRefresh()
            return
        }
        setRaw(Library())
        await refresh(s, showSpinner: true)
    }

    /// Eén server verversen (met gids). true = gelukt. Build 130: voor een niet-actieve server blijven de
    /// laadindicator en de laadtekst van de actieve server onaangeroerd (die horen alleen bij de actieve server).
    @discardableResult
    func refresh(_ s: PlaylistSource, showSpinner: Bool) async -> Bool {
        guard !Screenshots.isActive else { return false }
        let isActive = source?.id == s.id
        let ownsIndicator = showSpinner || isActive
        if showSpinner { isLoading = true }
        let background = !showSpinner && isActive
        if background { isRefreshing = true }
        defer {
            if ownsIndicator { isLoading = false; loadingText = "" }
            if background { isRefreshing = false }
        }
        // laadtekst alleen voor de actieve server
        func say(_ t: String) { if ownsIndicator { loadingText = t } }
        // build 143: startdiagnose: ophalen, binnen, ingelezen, bewaard (met het geheugen op elk moment)
        StartDiagnostics.shared.mark(isActive ? "ophalen open server" : "ophalen andere server")
        do {
            var lib: Library
            let password = Keychain.get(s.passwordKey) ?? ""
            switch s.kind {
            case .m3u:
                say(L("Downloading playlist…"))
                guard let u = s.m3uURL.urlValue else { throw HTTPError.badURL }
                var data: Data? = try await HTTP.get(u)
                StartDiagnostics.shared.mark("binnen")
                say(L("Sorting channels and movies…"))
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                data = nil   // build 143: de ruwe bytes meteen vrijgeven (niet twee kopieën tijdens het inlezen)
                let pid = s.id
                lib = await Task.detached(priority: isActive ? .userInitiated : .utility) { M3UParser.library(from: text, playlistID: pid) }.value
                StartDiagnostics.shared.mark("ingelezen")
                let epg = s.epgURL.urlValue ?? M3UParser.epgURL(fromHeader: text)
                if let epg { say(L("Loading TV guide…")); lib.epg = await loadEPG(epg) }
            case .xtream:
                say(L("Signing in to server…"))
                let x = XtreamClient(source: s, password: password)
                try await x.authenticate()
                say(L("Fetching live TV, movies and series…"))
                lib = try await x.library(playlistID: s.id)
                let epg = s.epgURL.urlValue ?? x.xmltvURL
                if let epg { say(L("Loading TV guide…")); lib.epg = await loadEPG(epg) }
            case .stalker:
                say(L("Connecting to portal…"))
                let st = (source?.id == s.id ? stalker : nil) ?? StalkerClient(source: s)
                try await st.connect()
                say(L("Fetching channels and videos…"))
                lib = try await st.library()
                if let epg = s.epgURL.urlValue { lib.epg = await loadEPG(epg) }
            case .jellyfin, .emby:
                say(L("Fetching your library…"))
                let jf = JellyfinClient(source: s, session: Self.session(s))
                lib = try await jf.library()
            case .plex:
                say(L("Fetching your library…"))
                guard var session = Self.session(s) else { throw MediaError.notLoggedIn }
                // server-adres kan veranderen: bij fout opnieuw zoeken
                do { lib = try await PlexClient(session: session).library() }
                catch {
                    guard let userToken = Keychain.get(s.passwordKey) else { throw error }
                    session = try await PlexClient.discoverServer(userToken: userToken)
                    Keychain.setCodable(session, for: Self.sessionKey(s))
                    lib = try await PlexClient(session: session).library()
                }
            case .stremio:
                say(L("Loading Stremio add-ons…"))
                let addons = await Self.stremioAddons(s)
                if source?.id == s.id { stremioAddons = addons }
                say(L("Fetching catalogs…"))
                lib = await StremioClient(addons: addons).library()
            }
            if source?.id == s.id {
                setRaw(lib)
                writeCache(s, lib)
                SplashPosters.save(from: lib)
            } else {
                writeCache(s, lib)     // andere afspeellijst op de achtergrond ververst
            }
            StartDiagnostics.shared.mark("bewaard")
            return true
        } catch {
            guard source?.id == s.id else { return false }
            if rawLibrary.channels.isEmpty && rawLibrary.movies.isEmpty && rawLibrary.series.isEmpty {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    /// Bij terugkeren in de app: verversen als het volgens de instelling tijd is.
    /// Build 140: niet alleen de open server, maar alle servers van het account (zoals "Nu vernieuwen" sinds build 130).
    ///
    /// Build 141 (crash op Apple TV, build 140): bij het openen van de app ververste build 140 meteen álle servers
    /// waarvan de lijst te oud was, ook vóór er een server open was (de app wordt bij het starten "actief"). Op een Apple
    /// TV, die meestal één keer per dag opent, zijn dat elke keer alle servers: ophalen, inlezen en de gids van alle
    /// grote servers tegelijk met het opstarten van de app. Het geheugen liep daardoor zo op dat tvOS de app direct na
    /// het openen stopte. Nu: alleen de open server meteen (zoals tot build 139); de andere servers pas als de app al een
    /// tijd draait, één voor één en niet tijdens het afspelen (`scheduleOthers`).
    func refreshIfDue() async {
        guard !Screenshots.isActive, let s = source else { return }
        let due = AutoRefresh.due(policy: RefreshPolicy.current.rawValue, servers: [(id: s.id.uuidString, age: cacheAge(s))],
                                  lastAttempt: autoRefreshAttempt, now: Date(), periodic: false)
        if !due.isEmpty, !isLoading, !autoRefreshing, !refreshingAll {
            autoRefreshing = true
            autoRefreshAttempt[s.id.uuidString] = Date()
            let ok = await refresh(s, showSpinner: false)
            autoRefreshing = false
            if ok { autoRefreshAttempt[s.id.uuidString] = nil; CrossServer.shared.serversRefreshed([s.id]) }
        }
        scheduleOthers()
    }

    /// Build 143: automatisch verversen na het openen met een bewaarde lijst. Bij het openen wordt NIETS opgehaald: de
    /// bewaarde lijst staat meteen in beeld. Pas als de app al `autoSettle` seconden draait, er niets speelt en het
    /// hoofdscherm open is: eerst de open server (alleen als die ouder is dan de ingestelde termijn), daarna de andere
    /// één voor één (`scheduleOthers`). Een nieuwe server of profiel annuleert het.
    static var autoSettle: TimeInterval { SmokeTest.isActive ? 35 : 45 }
    private var autoTask: Task<Void, Never>?
    func scheduleAutoRefresh() {
        autoTask?.cancel()
        othersTask?.cancel(); othersTask = nil
        autoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let up = StartDiagnostics.shared.uptime
                if up >= Self.autoSettle, !(self.isPlaying?() ?? false), self.mayAutoRefresh?() ?? true { break }
                try? await Task.sleep(nanoseconds: UInt64(max(2, Self.autoSettle - up) * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.refreshIfDue()
        }
    }
    /// Wordt er iets afgespeeld / mag het nu (hoofdscherm open)? Gezet door AppState.
    var isPlaying: (() -> Bool)?
    var mayAutoRefresh: (() -> Bool)?

    /// Build 141: de andere servers pas na `othersDelay` seconden (als de app dan nog openstaat), via
    /// `refreshAllIfDue` (één voor één, niet tijdens het afspelen, met een time-out).
    /// (in de start-rooktest korter, zodat het verversen van de grote servers binnen de test valt)
    static var othersDelay: TimeInterval { SmokeTest.isActive ? 40 : 120 }
    private var othersTask: Task<Void, Never>?
    private func scheduleOthers() {
        guard othersTask == nil, CloudStore.shared.playlists.count > 1 else { return }
        othersTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.othersDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.isPlaying?() ?? false { self.othersTask = nil; self.scheduleOthers(); return }
            await self.refreshAllIfDue()
            self.othersTask = nil
        }
    }

    /// Build 140: laatste mislukte poging per server (niet vaker dan eens per 15 minuten opnieuw)
    private var autoRefreshAttempt: [String: Date] = [:]
    private var autoRefreshing = false

    /// Build 140: "Server automatisch vernieuwen" (dagelijks, wekelijks …): elke server van het account waarvan de
    /// bewaarde lijst te oud is, verversen. De open server eerst; de andere rustig op de achtergrond (niet tijdens het
    /// afspelen, met een time-out). Loopt bij het openen van een server, bij terugkeer naar de voorgrond en
    /// (`periodic`) elke 5 minuten zolang de app openstaat — ook na een herstart, want de leeftijd komt van de cache.
    func refreshAllIfDue(periodic: Bool = false) async {
        guard !Screenshots.isActive, !autoRefreshing, !refreshingAll, !isLoading else { return }
        let all = CloudStore.shared.playlists
        let activeID = source?.id
        let ordered = all.filter { $0.id == activeID } + all.filter { $0.id != activeID }
        let due = AutoRefresh.due(policy: RefreshPolicy.current.rawValue,
                                  servers: ordered.map { (id: $0.id.uuidString, age: cacheAge($0)) },
                                  lastAttempt: autoRefreshAttempt, now: Date(), periodic: periodic)
        guard !due.isEmpty else { return }
        autoRefreshing = true
        defer { autoRefreshing = false }
        var done: [UUID] = []
        for id in due {
            guard let p = CloudStore.shared.playlists.first(where: { $0.id.uuidString == id }) else { continue }
            autoRefreshAttempt[id] = Date()
            let isActive = p.id == source?.id
            if !isActive { await CrossServer.shared.waitUntilNotPlaying() }
            let ok = await CrossServer.withTimeout(isActive ? 300 : 120, { await self.refresh(p, showSpinner: false) }) ?? false
            if ok {
                done.append(p.id)
                autoRefreshAttempt[id] = nil
            }
        }
        if !done.isEmpty { CrossServer.shared.serversRefreshed(done) }
    }

    /// Build 130: alle servers van het account verversen ("Nu vernieuwen", "Alle servers nu verversen").
    /// Eerst de actieve (zodat die snel klaar is), daarna de andere één voor één op de achtergrond, met een time-out
    /// per server en niet tijdens het afspelen. Een fout bij één server houdt de rest niet tegen; welke niet lukten
    /// staat daarna in `refreshFailed` (alleen de servernamen, er wordt niets gelogd). Daarna catalogmeta, remap en
    /// slimme collecties bijwerken (`CrossServer`).
    @Published private(set) var refreshingAll = false
    /// Voortgang: server `done + 1` van `total` (nil = niet bezig)
    @Published private(set) var refreshProgress: (current: Int, total: Int)?
    /// Namen van de servers die bij de laatste keer alles verversen niet lukten
    @Published private(set) var refreshFailed: [String] = []

    /// `forceActive`: de actieve server opnieuw laden met het laadscherm (zoals "Nu vernieuwen" altijd deed);
    /// anders op de achtergrond met het "Bijwerken"-pilletje.
    func refreshAll(forceActive: Bool = false) async {
        guard !refreshingAll, !Screenshots.isActive else { return }
        refreshingAll = true
        refreshFailed = []
        defer { refreshingAll = false; refreshProgress = nil }
        let all = CloudStore.shared.playlists
        let activeID = source?.id
        let ordered = all.filter { $0.id == activeID } + all.filter { $0.id != activeID }
        var failed: [String] = []
        for (i, p) in ordered.enumerated() {
            refreshProgress = (i + 1, ordered.count)
            // de server kan intussen verwijderd zijn
            guard CloudStore.shared.playlists.contains(where: { $0.id == p.id }) else { continue }
            let ok: Bool
            if p.id == activeID {
                if forceActive {
                    await select(p, forceRefresh: true)
                    ok = !rawLibrary.isEmptyLibrary && source?.id == p.id
                } else {
                    ok = await CrossServer.withTimeout(300, { await self.refresh(p, showSpinner: false) }) ?? false
                }
            } else {
                // de andere servers: rustig, niet tijdens het afspelen
                await CrossServer.shared.waitUntilNotPlaying()
                ok = await CrossServer.withTimeout(120, { await self.refresh(p, showSpinner: false) }) ?? false
            }
            if !ok { failed.append(p.name) }
        }
        refreshFailed = failed
        CrossServer.shared.serversRefreshed(ordered.map(\.id))
    }

    private func loadEPG(_ url: URL) async -> [String: [EPGProgram]] {
        guard let d = try? await HTTP.get(url) else { return [:] }
        return await Task.detached(priority: .utility) { XMLTVParser.parse(d) }.value
    }

    // MARK: sessies (Plex / Jellyfin / Emby / Stremio)

    static func sessionKey(_ s: PlaylistSource) -> String { "playlist.\(s.id.uuidString).session" }
    static func session(_ s: PlaylistSource) -> MediaSession? { Keychain.getCodable(MediaSession.self, sessionKey(s)) }

    static func stremioAddons(_ s: PlaylistSource) async -> [StremioClient.Addon] {
        var urls = s.m3uURL.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        if let key = Keychain.get(s.passwordKey), !key.isEmpty, let acct = try? await StremioClient.accountAddons(authKey: key) {
            urls = acct + urls
        }
        if !urls.contains(where: { $0.contains("cinemeta") }) { urls.insert(StremioClient.cinemeta, at: 0) }
        var out: [StremioClient.Addon] = []
        for u in orderedUnique(urls) { if let a = await StremioClient.loadAddon(u) { out.append(a) } }
        return out
    }

    // MARK: aanpassingen toepassen

    private func setRaw(_ lib: Library) {
        if !lib.isEmptyLibrary { StartDiagnostics.shared.mark("catalogus") }   // build 143
        rawLibrary = lib
        applyCustomizations()
    }

    /// Alles wat het filteren nodig heeft, als losse waarden — zodat het op de achtergrond kan (grote lijsten).
    struct FilterContext {
        var custom: Customization
        var playlist: UUID
        var ageLimit: Int?
        var strict: Bool
        var parentalEnabled: Bool
        var lockedGroups: Set<String>
        var autoLockAdult: Bool
        var unlocked: Bool
        var meta: [String: TitleMetadata]
        /// TMDB-classificaties (build 53); leeg zonder leeftijdsgrens
        var ratings: [String: AgeInfo] = [:]
        /// Build 128: categorieën die het actieve profiel op deze server uit heeft gezet (categorienaam zoals de server
        /// hem levert). De oude `group:`-items in `custom.hidden` gelden sinds build 128 niet meer voor categorieën.
        var hiddenGroups: Set<String> = []
        /// Build 140: kinderprofiel: alleen inhoud uit kindercategorieën (KidsCategory), de account-brede verborgen
        /// categorieën gelden dan niet
        var kids = false

        /// Dezelfde regels (alles behalve de classificaties zelf)? Dan mag de vorige uitkomst blijven staan
        /// tot de nieuwe klaar is, en hoeft een gelijke uitkomst niet opnieuw gepubliceerd te worden.
        func sameRules(as o: FilterContext) -> Bool {
            playlist == o.playlist && ageLimit == o.ageLimit && strict == o.strict && parentalEnabled == o.parentalEnabled
                && autoLockAdult == o.autoLockAdult && unlocked == o.unlocked && lockedGroups == o.lockedGroups
                && custom == o.custom && hiddenGroups == o.hiddenGroups && kids == o.kids
        }
    }

    /// Filter van een bron met de regels van het actieve profiel (ook voor andere servers, build 128).
    func context(for s: PlaylistSource) -> FilterContext {
        let st = CloudStore.shared
        let pc = st.parental
        var custom = st.customization(s.id)
        // build 140: categorieën aan/uit staan voor het hele account (CloudStore.hiddenCategories; build 128–139 per
        // profiel); de oude `group:`-items blijven op de server staan voor oudere apps, maar tellen hier niet mee
        // (App Store-screenshots: de demo verbergt groepen nog op de oude manier)
        if !Screenshots.isActive { custom.hidden = custom.hidden.filter { !$0.hasPrefix("group:") } }
        let kids = st.activeProfile?.kids ?? false
        return FilterContext(custom: custom, playlist: s.id,
                             ageLimit: st.activeProfile?.effectiveAgeLimit, strict: st.activeProfile?.strictAgeFilter ?? false,
                             parentalEnabled: pc.enabled, lockedGroups: pc.lockedGroups, autoLockAdult: pc.autoLockAdult,
                             unlocked: ParentalControl.shared.isUnlocked,
                             meta: (st.activeProfile?.effectiveAgeLimit != nil) ? MetadataService.shared.cache : [:],
                             ratings: (st.activeProfile?.effectiveAgeLimit != nil) ? AgeRatingService.shared.cache : [:],
                             hiddenGroups: kids ? [] : st.hiddenGroups(for: s.id), kids: kids)
    }

    /// Filter voor een andere afspeellijst met de leeftijdsgrens van het actieve profiel (nil = geen grens).
    func ageContext(for p: PlaylistSource) -> FilterContext? {
        guard CloudStore.shared.activeProfile?.effectiveAgeLimit != nil else { return nil }
        return context(for: p)
    }

    private var filterGeneration = 0
    /// Bezig met filteren op de achtergrond (Home toont dan nog geen "lege lijst"-melding)
    @Published private(set) var isFiltering = false

    /// Filtert de lijst (verbergen, kinderslot, leeftijd) op de achtergrond; de app blijft direct reageren.
    func applyCustomizations() {
        guard let s = source else { library = rawLibrary; libraryRawVersion = -1; return }
        let ctx = context(for: s)
        let raw = rawLibrary
        // profiel met leeftijdsgrens: classificaties op de achtergrond aanvullen (TMDB, gecachet)
        if ctx.ageLimit != nil { AgeRatingService.shared.prefetch(raw) }
        filterGeneration += 1
        let gen = filterGeneration
        let rv = rawVersion
        // dezelfde bron opnieuw gefilterd (bijv. nieuwe leeftijdsclassificaties, iCloud-sync): alleen publiceren als
        // de uitkomst anders is. Anders bouwt elk scherm (Home, collecties, Live TV) alles opnieuw op terwijl je scrolt.
        let previous: Library? = libraryRawVersion == rv && libraryContext?.sameRules(as: ctx) == true ? library : nil
        // kleine lijsten: meteen; grote lijsten: op de achtergrond
        if raw.channels.count + raw.movies.count + raw.series.count < 3000 {
            let lib = Self.apply(raw, ctx)
            if let previous, Self.sameContent(previous, lib) { return }
            library = lib
            libraryRawVersion = rv
            libraryContext = ctx
            return
        }
        // kinderprofiel/leeftijdsgrens: niets ongefilterds laten zien terwijl er gefilterd wordt
        // (alleen bij een nieuwe lijst; bij opnieuw filteren blijft de vorige uitkomst staan tot de nieuwe klaar is)
        if ctx.ageLimit != nil && previous == nil { library = Library(); libraryRawVersion = -1 }
        // stil opnieuw filteren (vorige uitkomst blijft staan): geen extra schermverversingen voor de spinner
        if previous == nil { isFiltering = true }
        Task {
            let result: Library? = await Task.detached(priority: .userInitiated) { () -> Library? in
                let lib = Self.apply(raw, ctx)
                if let previous, Self.sameContent(previous, lib) { return nil }
                return lib
            }.value
            guard gen == self.filterGeneration else { return }   // intussen opnieuw gefilterd
            if let result {
                self.library = result
                self.libraryRawVersion = rv
                self.libraryContext = ctx
            }
            if self.isFiltering { self.isFiltering = false }
        }
    }

    /// Zelfde zenders, films en series (met dezelfde namen/groepen) uit dezelfde ongefilterde lijst?
    /// De gids volgt de zenders, dus die hoeft niet apart vergeleken te worden.
    nonisolated static func sameContent(_ a: Library, _ b: Library) -> Bool {
        a.channels.count == b.channels.count && a.movies.count == b.movies.count && a.series.count == b.series.count
            && a.epg.count == b.epg.count
            && a.channels == b.channels && a.movies == b.movies && a.series == b.series
    }

    /// Voor "Bron controleren": wat er van een lijst overblijft na alleen jouw categorie-instellingen
    /// (verbergen, samenvoegen), en wat er zichtbaar is na ook kinderslot en leeftijdsgrens van dit profiel.
    func visibility(of raw: Library) async -> (afterSettings: Library, visible: Library) {
        guard let s = source else { return (raw, raw) }
        let ctx = context(for: s)
        var settingsOnly = ctx
        settingsOnly.ageLimit = nil
        settingsOnly.parentalEnabled = false
        settingsOnly.meta = [:]
        settingsOnly.ratings = [:]
        return await Task.detached(priority: .userInitiated) {
            (Self.apply(raw, settingsOnly), Self.apply(raw, ctx))
        }.value
    }

    /// Oude aanroepen (bijv. zoeken in andere afspeellijsten).
    static func apply(_ raw: Library, _ c: Customization, playlist: UUID, ageLimit: Int? = nil, strict: Bool = false) -> Library {
        let st = CloudStore.shared
        let pc = st.parental
        var c = c
        if !Screenshots.isActive { c.hidden = c.hidden.filter { !$0.hasPrefix("group:") } }
        let kids = st.activeProfile?.kids ?? false
        return apply(raw, FilterContext(custom: c, playlist: playlist, ageLimit: ageLimit, strict: strict,
                                        parentalEnabled: pc.enabled, lockedGroups: pc.lockedGroups, autoLockAdult: pc.autoLockAdult,
                                        unlocked: ParentalControl.shared.isUnlocked,
                                        meta: ageLimit != nil ? MetadataService.shared.cache : [:],
                                        ratings: ageLimit != nil ? AgeRatingService.shared.cache : [:],
                                        hiddenGroups: kids ? [] : st.hiddenGroups(for: playlist), kids: kids))
    }

    nonisolated static func apply(_ raw: Library, _ ctx: FilterContext) -> Library {
        let c = ctx.custom, playlist = ctx.playlist, ageLimit = ctx.ageLimit, strict = ctx.strict
        func isLocked(_ g: String) -> Bool {
            guard ctx.parentalEnabled, !ctx.unlocked else { return false }
            if ctx.lockedGroups.contains("\(playlist.uuidString)|\(g)") { return true }
            return ctx.autoLockAdult && ParentalControl.isAdultGroup(g)
        }
        func movieOK(_ m: Movie) -> Bool {
            let k = MetadataService.key(title: m.title, year: m.year, isShow: false), md = ctx.meta[k]
            return ParentalControl.allowedFor(rated: md?.rated, group: m.group, limit: ageLimit, genre: md?.genre,
                                              strict: strict, info: ctx.ratings[k], kids: ctx.kids)
        }
        func seriesOK(_ s: Series) -> Bool {
            let k = MetadataService.key(title: s.title, year: s.year, isShow: true), md = ctx.meta[k]
            return ParentalControl.allowedFor(rated: md?.rated, group: s.group, limit: ageLimit, genre: md?.genre,
                                              strict: strict, info: ctx.ratings[k], kids: ctx.kids)
        }
        func group(_ g: String) -> String {
            let merged = c.merged[g] ?? g
            return c.renamed[Customization.groupKey(merged)] ?? merged
        }
        // per groep één keer uitrekenen (tienduizenden titels delen maar een paar honderd groepen)
        var groupOK: [String: Bool] = [:]
        func visible(_ id: String, _ g: String) -> Bool {
            if c.hidden.contains(id) { return false }
            if let ok = groupOK[g] { return ok }
            // build 140: kinderprofiel: alleen kindercategorieën (naam zoals de server hem levert)
            let ok = (!ctx.kids || KidsCategory.isKids(g))
                && !c.hidden.contains(Customization.groupKey(g))
                && !c.hidden.contains(Customization.groupKey(c.merged[g] ?? g))
                && !ctx.hiddenGroups.contains(g)
                && !isLocked(g)
                && !isLocked(c.merged[g] ?? g)
            groupOK[g] = ok
            return ok
        }
        var lib = raw
        // programma's per zender op begintijd (nodig voor het snelle opzoeken van nu/straks per rij)
        lib.epg = Library.sortedEPG(raw.epg)
        lib.channels = raw.channels.filter { visible($0.id, $0.group) }.map { ch in
            var x = ch; x.group = group(ch.group); x.name = c.renamed[ch.id] ?? ch.name; return x
        }
        // build 140: een kinderprofiel filtert altijd (ook als het kinderslot van het hoofdaccount even open staat)
        let ageFilter = (ageLimit != nil && !ctx.unlocked) || ctx.kids
        if ageFilter {
            if ctx.kids {
                // build 140: zenders volgen alleen de (kinder)categorie; nooit een zender met een volwassenennaam
                lib.channels = lib.channels.filter { !ParentalControl.isAdultGroup($0.name) }
            } else {
                // leeftijdsgrens: alleen kinderzenders (groep of zendernaam) bij een strenge grens
                lib.channels = lib.channels.filter { ParentalControl.channelAllowed(name: $0.name, group: $0.group, limit: ageLimit, strict: strict) }
            }
            let ids = Set(lib.channels.map { $0.epgID ?? $0.id })
            lib.epg = lib.epg.filter { ids.contains($0.key) }
        }
        lib.movies = raw.movies.filter { visible($0.id, $0.group) && (!ageFilter || movieOK($0)) }.map { m in
            var x = m; x.group = group(m.group); x.title = c.renamed[m.id] ?? m.title; return x
        }
        lib.series = raw.series.filter { visible($0.id, $0.group) && (!ageFilter || seriesOK($0)) }.map { se in
            var x = se; x.group = group(se.group); x.title = c.renamed[se.id] ?? se.title; return x
        }
        // eigen volgorde: groepen, dan kanalen binnen een groep
        if !c.groupOrder.isEmpty || !c.channelOrder.isEmpty {
            let gIndex = Dictionary(c.groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let natural = Dictionary(orderedUnique(lib.channels.map(\.group)).enumerated().map { ($1, $0 + 10_000) },
                                     uniquingKeysWith: { a, _ in a })
            var cIndex: [String: Int] = [:]
            for (_, ids) in c.channelOrder { for (i, id) in ids.enumerated() { cIndex[id] = i } }
            let original = Dictionary(lib.channels.enumerated().map { ($1.id, $0 + 100_000) }, uniquingKeysWith: { a, _ in a })
            lib.channels.sort { a, b in
                let ga = gIndex[a.group] ?? natural[a.group] ?? 0, gb = gIndex[b.group] ?? natural[b.group] ?? 0
                if ga != gb { return ga < gb }
                return (cIndex[a.id] ?? original[a.id] ?? 0) < (cIndex[b.id] ?? original[b.id] ?? 0)
            }
        }
        return lib
    }

    // MARK: details

    /// Bron van een item: zijn eigen server (build 128, `sourceID`), anders de open bron.
    func source(for id: UUID?) -> PlaylistSource? {
        guard let id, id != source?.id else { return source }
        return CloudStore.shared.playlists.first { $0.id == id }
    }

    func episodes(for series: Series) async -> [Episode] {
        if !series.episodes.isEmpty { return series.episodes }
        // build 128: een serie van een andere server: afleveringen via die server (zonder te wisselen)
        if let sid = series.sourceID, sid != source?.id {
            let key = sid.uuidString + "|" + series.id
            if let c = episodeCache[key] { return c }
            guard let other = self.source(for: sid) else { return [] }
            let eps = await Self.fetchEpisodes(series, in: other).map { e -> Episode in var x = e; x.sourceID = sid; return x }
            if !eps.isEmpty { episodeCache[key] = eps }
            return eps
        }
        if let c = episodeCache[series.id] { return c }
        guard let s = source else { return [] }
        var eps: [Episode] = []
        switch s.kind {
        case .xtream:
            eps = (try? await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").episodes(for: series)) ?? []
        case .jellyfin, .emby:
            eps = (try? await JellyfinClient(source: s, session: Self.session(s)).episodes(series)) ?? []
        case .plex:
            if let session = Self.session(s) { eps = (try? await PlexClient(session: session).episodes(series)) ?? [] }
        case .stremio:
            if stremioAddons.isEmpty { stremioAddons = await Self.stremioAddons(s) }
            eps = (try? await StremioClient(addons: stremioAddons).episodes(series)) ?? []
        default: break
        }
        // alleen bewaren als er iets binnenkwam: bij een time-out of serverfout opnieuw proberen
        if !eps.isEmpty { episodeCache[series.id] = eps }
        return eps
    }

    func xtreamSeriesInfo(_ series: Series) async -> XtreamClient.SeriesInfo? {
        guard let s = source(for: series.sourceID), s.kind == .xtream, let id = series.xtreamSeriesID else { return nil }
        return await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").seriesInfo(id)
    }

    func xtreamVodInfo(_ m: Movie) async -> XtreamClient.VodInfo.Info? {
        guard let s = source(for: m.sourceID), s.kind == .xtream, let id = m.xtreamVodID else { return nil }
        return await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").vodInfo(id)
    }

    /// Stremio: alle beschikbare streams voor een titel.
    func stremioStreams(_ item: PlayableItem) async -> [StremioClient.Stream] {
        guard let ref = item.stremio, let s = source(for: item.sourceID) else { return [] }
        let parts = ref.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        // build 128: een titel van een andere server: de add-ons van die server
        if s.id != source?.id {
            if foreignAddons[s.id] == nil { foreignAddons[s.id] = await Self.stremioAddons(s) }
            return await StremioClient(addons: foreignAddons[s.id] ?? []).streams(type: parts[0], id: parts[1])
        }
        if stremioAddons.isEmpty { stremioAddons = await Self.stremioAddons(s) }
        return await StremioClient(addons: stremioAddons).streams(type: parts[0], id: parts[1])
    }
    /// Build 128: Stremio-add-ons en MAC-portalsessies van andere servers (afspelen zonder te wisselen)
    private var foreignAddons: [UUID: [StremioClient.Addon]] = [:]
    private var foreignStalker: [UUID: StalkerClient] = [:]

    /// Geeft de echte afspeel-URL (Stalker maakt per keer een link aan, Stremio zoekt een stream).
    func resolve(_ item: PlayableItem) async -> URL? {
        if let u = item.url { if item.stalkerCmd == nil { return u } }
        // build 128: MAC-portal van een andere server: een eigen sessie met die server
        if let cmd = item.stalkerCmd, let sid = item.sourceID, sid != source?.id, let other = source(for: sid), other.kind == .stalker {
            let st: StalkerClient
            if let c = foreignStalker[sid] { st = c } else {
                st = StalkerClient(source: other)
                guard (try? await st.connect()) != nil else { return item.url }
                foreignStalker[sid] = st
            }
            return (try? await st.createLink(cmd: cmd, type: item.type == .live ? .live : .movie)) ?? item.url
        }
        if let cmd = item.stalkerCmd, let st = stalker {
            return (try? await st.createLink(cmd: cmd, type: item.type == .live ? .live : .movie)) ?? item.url
        }
        if item.stremio != nil { return await stremioStreams(item).first?.url }
        return item.url
    }

    func catchupURL(_ c: Channel, _ p: EPGProgram) -> URL? {
        catchupURL(channelID: c.id, start: p.start, end: p.end, sourceID: c.sourceID, channel: c)
    }

    /// Terugkijken / timeshift vanaf een willekeurig moment (Xtream). Build 128: ook voor een zender van een andere
    /// server (`sourceID`): met de inloggegevens, de zender en de terugkijk-correctie van die server.
    func catchupURL(channelID: String, start: Date, end: Date, sourceID: UUID? = nil, channel: Channel? = nil) -> URL? {
        if let sid = sourceID, sid != source?.id {
            guard let other = self.source(for: sid), other.kind == .xtream else { return nil }
            let ch = (channel?.catchupDays ?? 0) > 0 ? channel : CrossServer.shared.channel(forKey: sid.uuidString + "|" + channelID)
            guard let ch, ch.catchupDays > 0 else { return nil }
            let shift = TimeInterval((other.catchupOffsets?[channelID] ?? 0) * 60)
            let p = EPGProgram(channelID: channelID, title: "", start: start.addingTimeInterval(shift), end: end.addingTimeInterval(shift))
            return XtreamClient(source: other, password: Keychain.get(other.passwordKey) ?? "").catchupURL(channel: ch, program: p)
        }
        guard let s = source, s.kind == .xtream,
              let ch = rawLibrary.channels.first(where: { $0.id == channelID }), ch.catchupDays > 0 else { return nil }
        // terugkijk-correctie van deze zender (build 51): het begintijdstip verschuiven
        let shift = TimeInterval((s.catchupOffsets?[channelID] ?? 0) * 60)
        let p = EPGProgram(channelID: channelID, title: "", start: start.addingTimeInterval(shift), end: end.addingTimeInterval(shift))
        return XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").catchupURL(channel: ch, program: p)
    }

    /// Build 128: tv-gids van een zender van een andere server: uit de cache van die server, anders de gids van die
    /// server ophalen (XMLTV, één keer per sessie bewaard), bij een MAC-portal via die portal.
    func foreignEPG(_ c: Channel) async -> [EPGProgram] {
        guard let sid = c.sourceID, let other = source(for: sid) else { return [] }
        let key = c.epgID ?? c.id
        if let cached = foreignEPGCache[sid] { return cached[key] ?? cached[c.id] ?? [] }
        if other.kind == .stalker {
            let st: StalkerClient
            if let x = foreignStalker[sid] { st = x } else {
                st = StalkerClient(source: other)
                guard (try? await st.connect()) != nil else { return [] }
                foreignStalker[sid] = st
            }
            return await st.shortEPG(channelID: c.id).sorted { $0.start < $1.start }
        }
        var epg = await Task.detached(priority: .userInitiated) { () -> [String: [EPGProgram]] in
            PlaylistService.readAnyCatalog(other)?.0.epg ?? [:]
        }.value
        if epg.isEmpty {
            var url = other.epgURL.urlValue
            if url == nil, other.kind == .xtream { url = XtreamClient(source: other, password: Keychain.get(other.passwordKey) ?? "").xmltvURL }
            if let url { epg = await loadEPG(url) }
        }
        epg = Library.sortedEPG(epg)
        foreignEPGCache = [sid: epg]   // één server tegelijk in het geheugen
        return epg[key] ?? epg[c.id] ?? []
    }
    private var foreignEPGCache: [UUID: [String: [EPGProgram]]] = [:]

    func shortEPG(_ c: Channel) async -> [EPGProgram] {
        if c.sourceID != nil, c.sourceID != source?.id { return await foreignEPG(c) }
        if let s = stalker, library.epg[c.epgID ?? c.id] == nil {
            let p = await s.shortEPG(channelID: c.id).sorted { $0.start < $1.start }
            if !p.isEmpty {
                rawLibrary.epg[c.id] = p
                epgOnlyUpdate = true
                library.epg[c.id] = p
                epgOnlyUpdate = false
                libraryRawVersion = rawVersion
            }
            return p
        }
        return library.upcoming(c, count: 10)
    }

    // MARK: zoeken

    struct SearchResults {
        var channels: [Channel] = []; var movies: [Movie] = []; var series: [Series] = []
        var other: [OtherHit] = []
        var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty && other.isEmpty }
    }

    /// Treffer in een andere afspeellijst.
    struct OtherHit: Identifiable, Hashable {
        var id: String { "\(playlist.id)-\(itemID)" }
        var playlist: PlaylistSource
        var itemID: String
        var title: String
        var subtitle: String
        var artwork: URL?
        /// zender (Live TV): in de zoekresultaten altijd na films en series
        var isLive = false
    }

    nonisolated static func normTitle(_ t: String) -> String { fold(t).filter { $0.isLetter || $0.isNumber } }
    nonisolated static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    func search(_ q: String, allPlaylists: Bool = true) async -> SearchResults {
        let t = Self.fold(q.trimmingCharacters(in: .whitespaces))
        guard t.count >= 2 else { return SearchResults() }
        func m(_ s: String) -> Bool { Self.fold(s).contains(t) }
        // films én series én zenders, uit álle categorieën (ongeacht het tabblad waarin je zoekt)
        var r = SearchResults(channels: Array(library.channels.filter { m($0.name) }.prefix(60)),
                              movies: Array(library.movies.filter { m($0.title) }.prefix(200)),
                              series: Array(library.series.filter { m($0.title) }.prefix(200)))
        guard allPlaylists else { return r }
        // zoeken in de cache van alle andere afspeellijsten
        let others = CloudStore.shared.playlists.filter { $0.id != source?.id }
        let liveLabel = L("Live TV")
        // build 130: elk profiel ziet alle servers, met zijn eigen filter per server (leeftijd, kinderslot, categorieën)
        let ageCtx = Dictionary(uniqueKeysWithValues: others.map { p in (p.id, context(for: p)) })
        r.other = await Task.detached(priority: .userInitiated) {
            var hits: [OtherHit] = []
            for p in others {
                guard let raw = Self.readCache(p) else { continue }
                let lib = ageCtx[p.id].map { Self.apply(raw, $0) } ?? raw
                for c in lib.channels where Self.fold(c.name).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: c.id, title: c.name, subtitle: liveLabel, artwork: c.logo, isLive: true))
                    if hits.count > 80 { break }
                }
                for mv in lib.movies where Self.fold(mv.title).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: mv.id, title: mv.title, subtitle: mv.year.map(String.init) ?? "", artwork: mv.poster))
                }
                for se in lib.series where Self.fold(se.title).contains(t) {
                    hits.append(OtherHit(playlist: p, itemID: se.id, title: se.title, subtitle: se.year.map(String.init) ?? "", artwork: se.poster))
                }
            }
            // Live TV altijd als laatste; verder de volgorde houden (stabiel)
            let kept = hits.prefix(120)
            return kept.filter { !$0.isLive } + kept.filter { $0.isLive }
        }.value
        return r
    }

    /// Dezelfde titel in andere groepen of andere afspeellijsten ("Andere bronnen").
    func otherSources(title: String, year: Int?, isShow: Bool, excluding id: String) async -> [OtherHit] {
        let norm = Self.normTitle(title)
        guard !norm.isEmpty else { return [] }
        let current = source
        let currentLib = library   // gefilterd: geen verborgen/vergrendelde of te oude titels
        // build 130: alle servers van het account, voor elk profiel (met het filter van het profiel per server)
        let all = CloudStore.shared.playlists
        let ageCtx = Dictionary(uniqueKeysWithValues: all.filter { $0.id != current?.id }.map { p in (p.id, context(for: p)) })
        return await Task.detached(priority: .userInitiated) {
            var hits: [OtherHit] = []
            for p in all {
                let lib: Library
                if p.id == current?.id { lib = currentLib } else {
                    let other = Self.readCache(p) ?? Library()
                    lib = ageCtx[p.id].map { Self.apply(other, $0) } ?? other
                }
                if isShow {
                    for s in lib.series where s.id != id && Self.normTitle(s.title) == norm && (year == nil || s.year == nil || s.year == year) {
                        hits.append(OtherHit(playlist: p, itemID: s.id, title: s.title, subtitle: s.group, artwork: s.poster))
                    }
                } else {
                    for m in lib.movies where m.id != id && Self.normTitle(m.title) == norm && (year == nil || m.year == nil || m.year == year) {
                        hits.append(OtherHit(playlist: p, itemID: m.id, title: m.title, subtitle: m.group, artwork: m.poster))
                    }
                }
            }
            return hits
        }.value
    }

    /// Build 129: een treffer op een andere server (zoeken, "Andere bronnen") openen zonder van server te wisselen:
    /// het item uit de catalogus van die server, met `sourceID`, zodat openen en afspelen via die server gaan (zoals
    /// de items van andere servers sinds build 128). nil = niet (meer) in de catalogus van die server.
    func foreignItem(_ h: OtherHit) async -> CrossServer.Found? {
        let p = h.playlist, id = h.itemID, live = h.isLive
        let active = source?.id
        return await Task.detached(priority: .userInitiated) { () -> CrossServer.Found? in
            guard let (lib, _) = Self.readAnyCatalog(p) else { return nil }
            let tag: UUID? = p.id == active ? nil : p.id
            if live {
                guard var c = lib.channels.first(where: { $0.id == id }) else { return nil }
                c.sourceID = tag
                return CrossServer.Found(channel: c)
            }
            if var m = lib.movies.first(where: { $0.id == id }) { m.sourceID = tag; return CrossServer.Found(movie: m) }
            if var x = lib.series.first(where: { $0.id == id }) { x.sourceID = tag; return CrossServer.Found(series: x) }
            return nil
        }.value
    }

    // MARK: cache

    nonisolated static func cacheURL(_ s: PlaylistSource) -> URL {
        AppDirs.caches
            .appendingPathComponent("library-\(s.id.uuidString).json")
    }
    nonisolated static func readCache(_ s: PlaylistSource) -> Library? {
        guard let d = try? Data(contentsOf: cacheURL(s)) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: d)
    }
    private func cacheAge(_ s: PlaylistSource) -> TimeInterval? {
        let a = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL(s).path)
        return (a?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
    }
    private func writeCache(_ s: PlaylistSource, _ lib: Library) {
        let url = Self.cacheURL(s)
        Task.detached(priority: .background) {
            if let d = try? JSONEncoder().encode(lib) { try? d.write(to: url, options: .atomic) }
        }
    }
    func clearCache(_ s: PlaylistSource) { try? FileManager.default.removeItem(at: Self.cacheURL(s)) }
}

// MARK: - Build 128: catalogi en afleveringen van andere servers (zonder te wisselen)

extension PlaylistService {
    /// Afleveringen van een serie op een (andere) server.
    static func fetchEpisodes(_ series: Series, in s: PlaylistSource) async -> [Episode] {
        if !series.episodes.isEmpty { return series.episodes }
        switch s.kind {
        case .xtream:
            return (try? await XtreamClient(source: s, password: Keychain.get(s.passwordKey) ?? "").episodes(for: series)) ?? []
        case .jellyfin, .emby:
            return (try? await JellyfinClient(source: s, session: session(s)).episodes(series)) ?? []
        case .plex:
            guard let session = session(s) else { return [] }
            return (try? await PlexClient(session: session).episodes(series)) ?? []
        case .stremio:
            return (try? await StremioClient(addons: await stremioAddons(s)).episodes(series)) ?? []
        default:
            // build 141: M3U/Stalker: de afleveringen staan in de catalogus van die server (op dit apparaat bewaard);
            // de rijen over alle servers (Voor jou, Nieuw op Bingr) bewaren ze niet in het geheugen
            let id = series.id
            return await Task.detached(priority: .userInitiated) {
                PlaylistService.readAnyCatalog(s)?.0.series.first { $0.id == id }?.episodes ?? []
            }.value
        }
    }

    /// Catalogus (zenders, films, series; zonder gids) van een server die op dit apparaat nog geen cache heeft.
    static func fetchCatalog(_ s: PlaylistSource) async throws -> Library {
        let password = Keychain.get(s.passwordKey) ?? ""
        switch s.kind {
        case .m3u:
            guard let u = s.m3uURL.urlValue else { throw HTTPError.badURL }
            let data = try await HTTP.get(u)
            let pid = s.id
            let text = String(decoding: data, as: UTF8.self)
            return await Task.detached(priority: .utility) { M3UParser.library(from: text, playlistID: pid) }.value
        case .xtream:
            let x = XtreamClient(source: s, password: password)
            try await x.authenticate()
            return try await x.library(playlistID: s.id)
        case .stalker:
            let st = StalkerClient(source: s)
            try await st.connect()
            return try await st.library()
        case .jellyfin, .emby:
            return try await JellyfinClient(source: s, session: session(s)).library()
        case .plex:
            guard let session = session(s) else { throw MediaError.notLoggedIn }
            return try await PlexClient(session: session).library()
        case .stremio:
            return await StremioClient(addons: await stremioAddons(s)).library()
        }
    }

    /// Catalogus zonder gids van een server die hier (nog) niet geopend is (build 128)
    nonisolated static func catalogURL(_ s: PlaylistSource) -> URL {
        AppDirs.caches
            .appendingPathComponent("catalog-\(s.id.uuidString).json")
    }

    /// De nieuwste van de gewone cache en de catalogus van build 128; met het tijdstip van het bestand.
    /// Build 130: de nieuwste wint (de catalogus wordt op de achtergrond ververst als de cache oud is).
    nonisolated static func readAnyCatalog(_ s: PlaylistSource) -> (Library, Date)? {
        for url in catalogFiles(s) {
            guard let d = try? Data(contentsOf: url.0), let lib = try? JSONDecoder().decode(Library.self, from: d) else { continue }
            return (lib, url.1)
        }
        return nil
    }

    /// Cache en catalogus die er zijn, nieuwste eerst
    nonisolated private static func catalogFiles(_ s: PlaylistSource) -> [(URL, Date)] {
        let fm = FileManager.default
        return [cacheURL(s), catalogURL(s)].compactMap { url -> (URL, Date)? in
            guard let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
            return (url, d)
        }.sorted { $0.1 > $1.1 }
    }

    /// Tijdstip van de nieuwste cache/catalogus van een server (nil = nog niets).
    nonisolated static func catalogStamp(_ s: PlaylistSource) -> Date? {
        catalogFiles(s).first?.1
    }

    nonisolated static func writeCatalog(_ s: PlaylistSource, _ lib: Library) {
        var l = lib
        l.epg = [:]
        if let d = try? JSONEncoder().encode(l) { try? d.write(to: catalogURL(s), options: .atomic) }
    }
}

/// Hoe vaak afspeellijsten (incl. gids) automatisch ververst worden.
enum RefreshPolicy: String, CaseIterable, Identifiable {
    case manual, launch, sixHours, daily, weekly
    var id: String { rawValue }

    static var current: RefreshPolicy {
        RefreshPolicy(rawValue: UserDefaults.standard.string(forKey: "playlist.refresh") ?? "") ?? .daily
    }

    var title: String {
        switch self {
        case .manual: return L("Manually")
        case .launch: return L("Every time the app opens")
        case .sixHours: return L("Every 6 hours")
        case .daily: return L("Daily")
        case .weekly: return L("Weekly")
        }
    }

    /// Build 140: dezelfde regels als `AutoRefresh.isDue` (Build140.swift, getest in de zelftest)
    func isDue(age: TimeInterval?) -> Bool {
        guard let age else { return self != .manual }
        return AutoRefresh.isDue(policy: rawValue, age: age)
    }
}
