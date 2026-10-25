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
            .sink { [weak self] _, _ in _ = self?.applyCustomizations() }
            .store(in: &bag)
        ParentalControl.shared.$unlockedUntil
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in _ = self?.applyCustomizations() }
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
            .sink { [weak self] _ in _ = self?.applyCustomizations() }
            .store(in: &bag)
        // build 140: categorieën aan/uit voor het account gewijzigd (ook via de sync) → opnieuw filteren. Build 140:
        // even wachten, zodat een reeks tikken in Instellingen → Categorieën één keer filtert (niet per tik)
        CloudStore.shared.$hiddenCategories
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in _ = self?.applyCustomizations() }
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
            _ = self?.applyCustomizations()
        }
    }

    // MARK: laden

    func select(_ s: PlaylistSource, forceRefresh: Bool = false) async {
        // build 145: een andere server gekozen → het bijwerken bij het openen stopt
        if source?.id != s.id { cancelServerUpdate() }
        lastSelectHadCache = false
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
        if SmokeTest.isActive { SmokeTest.say("bewaarde lijst: \(cached != nil ? "ja" : "nee (ophalen)")") }
        if let cached {
            setRaw(cached)
            // build 145: niets ophalen; wat er daarna gebeurt (vragen, altijd, nooit) beslist AppState (`StartLoad`)
            lastSelectHadCache = true
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
        // build 143: startdiagnose: ophalen, ingelezen, bewaard (met het geheugen op elk moment). Build 148: als code.
        StartDiagnostics.shared.mark("fetch")
        // build 148: fasen van dit bijwerken (ophalen, inlezen, indexeren, toepassen, bewaren) met duur en geheugen
        let rec = UpdateRecorder(server: s.id)
        // build 147: uitkomst per soort voor de diagnose (Xtream per lijst, de rest de hele lijst)
        var fetchStatus: [FetchStatus.Entry]?
        do {
            var lib: Library
            let password = Keychain.get(s.passwordKey) ?? ""
            switch s.kind {
            case .m3u:
                say(L("Downloading playlist…"))
                guard let u = s.m3uURL.urlValue else { throw HTTPError.badURL }
                var data: Data? = try await HTTP.get(u)
                rec.end("fetch")
                say(L("Sorting channels and movies…"))
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                data = nil   // build 143: de ruwe bytes meteen vrijgeven (niet twee kopieën tijdens het inlezen)
                let pid = s.id
                lib = await Task.detached(priority: isActive ? .userInitiated : .utility) { M3UParser.library(from: text, playlistID: pid) }.value
                rec.end("parse")
                let epg = s.epgURL.urlValue ?? M3UParser.epgURL(fromHeader: text)
                if let epg { say(L("Loading TV guide…")); lib.epg = await loadEPG(epg, rec) }
            case .xtream:
                say(L("Signing in to server…"))
                let x = XtreamClient(source: s, password: password)
                try await x.authenticate()
                say(L("Fetching live TV, movies and series…"))
                // build 151: verborgen categorieën niet inlezen (alleen tellen + compacte zoekindex)
                let (xl, st) = try await x.libraryWithStatus(playlistID: s.id, onFetched: { rec.end("fetch") }, skip: skipFilter(for: s))
                rec.end("parse")
                lib = xl
                fetchStatus = st
                let epg = s.epgURL.urlValue ?? x.xmltvURL
                if let epg { say(L("Loading TV guide…")); lib.epg = await loadEPG(epg, rec) }
            case .stalker:
                say(L("Connecting to portal…"))
                let st = (source?.id == s.id ? stalker : nil) ?? StalkerClient(source: s)
                try await st.connect()
                say(L("Fetching channels and videos…"))
                lib = try await st.library()
                rec.end("fetch")
                if let epg = s.epgURL.urlValue { lib.epg = await loadEPG(epg, rec) }
            case .jellyfin, .emby:
                say(L("Fetching your library…"))
                let jf = JellyfinClient(source: s, session: Self.session(s))
                lib = try await jf.library()
                rec.end("fetch")
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
                rec.end("fetch")
            case .stremio:
                say(L("Loading Stremio add-ons…"))
                let addons = await Self.stremioAddons(s)
                if source?.id == s.id { stremioAddons = addons }
                say(L("Fetching catalogs…"))
                lib = await StremioClient(addons: addons).library()
                rec.end("fetch")
            }
            StartDiagnostics.shared.mark("parse")
            // build 145: gestopt (wissel van profiel of server, time-out): niets half bijgewerkts wegschrijven
            try Task.checkCancellation()
            if let fetchStatus { FetchLog.shared.note(s.id, fetchStatus) } else { FetchLog.shared.noteLibrary(s.id, lib) }
            if source?.id == s.id {
                // build 148: filteren (indexeren) op de achtergrond, op de hoofdthread alleen het eindresultaat
                let t0 = Date()
                let task = setRaw(lib)
                var applyMs = Date().timeIntervalSince(t0) * 1000
                if let task { let r = await task.value; rec.add("index", ms: r.indexMs); applyMs += r.applyMs }
                // build 149: "toepassen" telt ook het tekenen van de nieuwe lijst (SwiftUI rekent pas na het publiceren;
                // daardoor stond hij op 0 ms): wachten tot de hoofdthread weer vrij is
                let t2 = Date()
                await Self.mainSettled()
                applyMs += Date().timeIntervalSince(t2) * 1000
                rec.add("apply", ms: applyMs)
                SplashPosters.save(from: lib)
            } else {
                // andere afspeellijst op de achtergrond ververst: zichtbaar en verborgen tellen (diagnose)
                let ctx = context(for: s), raw = lib
                let t0 = Date()
                let vis = await Task.detached(priority: .utility) { Self.visibilityStats(raw, Self.apply(raw, ctx), ctx) }.value
                rec.add("index", ms: Date().timeIntervalSince(t0) * 1000)
                FetchLog.shared.noteVisibility(s.id, vis)
            }
            await writeCache(s, lib)
            rec.end("save")
            StartDiagnostics.shared.mark("save")
            UpdateLog.shared.save(rec.finish(.ok))
            return true
        } catch {
            // build 145: gestopt is geen fout
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            UpdateLog.shared.save(rec.finish(cancelled ? .cancelled : .failed))
            if !cancelled { FetchLog.shared.noteLibrary(s.id, nil, error: error) }
            guard source?.id == s.id else { return false }
            if cancelled { return false }
            // build 149: te groot voor het geheugen: altijd melden (de bewaarde lijst blijft staan)
            if (rawLibrary.channels.isEmpty && rawLibrary.movies.isEmpty && rawLibrary.series.isEmpty) || error is ServerTooLargeError {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    /// Build 149: wacht tot de hoofdthread het lopende werk (o.a. het tekenen na een publicatie) af heeft: eerst
    /// achter de huidige wachtrij, dan een timer in een volgende ronde van de runloop (na de schermupdate).
    static func mainSettled() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { c.resume() }
            }
        }
    }

    /// Build 145: had de laatst gekozen server een bewaarde lijst? (Anders is hij net met de laadmelding geladen.)
    private(set) var lastSelectHadCache = false

    /// Wordt er iets afgespeeld / mag er nu geladen worden (hoofdscherm open, niet in de profielkeuze of op het
    /// pincodescherm)? Gezet door AppState.
    var isPlaying: (() -> Bool)?
    var mayLoad: (() -> Bool)?

    /// Build 145: "Servers bijwerken?" → Nu bijwerken, of de instelling Altijd: alle servers van het account, één voor
    /// één. Eerst de open server, op de achtergrond (het "Bijwerken"-pilletje; Home blijft bruikbaar), daarna de andere.
    /// Nooit tijdens het afspelen of buiten het hoofdscherm (dan wachten), met een time-out per server. Een wissel van
    /// profiel of server stopt het (`cancelServerUpdate`). Er wordt niets automatisch op tijd ververst.
    @Published private(set) var updatingServers = false
    private var updateTask: Task<Void, Never>?
    /// Welke ronde de huidige is (een gestopte ronde ruimt na afloop niet de nieuwe op)
    private var updateRound = 0

    /// `justLoaded`: de open server is net (zonder bewaarde lijst) geladen; die niet meteen nog een keer.
    func startServerUpdate(justLoaded: Bool = false) {
        guard updateTask == nil, !refreshingAll, !Screenshots.isActive else { return }
        updatingServers = true
        updateRound &+= 1
        let round = updateRound
        updateTask = Task { @MainActor [weak self] in
            await self?.runServerUpdate(justLoaded: justLoaded)
            guard let self, self.updateRound == round else { return }
            self.updateTask = nil
            self.updatingServers = false
        }
    }

    /// Stoppen (wissel van profiel of server, naar "Wie kijkt er?", of handmatig alles verversen).
    func cancelServerUpdate() {
        updateTask?.cancel()
        updateTask = nil
        updatingServers = false
    }

    private func runServerUpdate(justLoaded: Bool) async {
        let all = CloudStore.shared.playlists
        let activeID = source?.id
        let ordered = all.filter { $0.id == activeID } + all.filter { $0.id != activeID }
        var done: [UUID] = []
        for p in ordered {
            // niet tijdens het afspelen, niet in de profielkeuze of op het pincodescherm
            while !Task.isCancelled, (isPlaying?() ?? false) || !(mayLoad?() ?? true) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled else { break }
            // de server kan intussen verwijderd zijn
            guard CloudStore.shared.playlists.contains(where: { $0.id == p.id }) else { continue }
            let isActive = p.id == source?.id
            if isActive, StartLoad.skipJustLoaded(age: cacheAge(p), justLoaded: justLoaded) { continue }
            // één server tegelijk: dit wacht tot hij klaar is (of de time-out)
            let ok = await CrossServer.withTimeout(isActive ? 300 : 120, { await self.refresh(p, showSpinner: false) }) ?? false
            if ok { done.append(p.id) }
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
        cancelServerUpdate()   // build 145: handmatig gaat voor (één server tegelijk)
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

    /// Build 148: gids ophalen (fase `fetch`) en inlezen (fase `parse`), de ruwe bytes meteen weer weg
    private func loadEPG(_ url: URL, _ rec: UpdateRecorder) async -> [String: [EPGProgram]] {
        var data = try? await HTTP.get(url)
        rec.end("fetch")
        guard let d = data else { return [:] }
        data = nil
        let out = await Task.detached(priority: .utility) { XMLTVParser.parse(d) }.value
        rec.end("parse")
        return out
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

    /// Build 148: nieuwe ongefilterde lijst. De oude wordt buiten de hoofdthread vrijgegeven (tienduizenden titels en
    /// de gids opruimen kostte seconden op de hoofdthread); het filteren loopt op de achtergrond (`Task`).
    @discardableResult
    private func setRaw(_ lib: Library) -> Task<ApplyTiming, Never>? {
        if !lib.isEmptyLibrary { StartDiagnostics.shared.mark("catalog") }   // build 143
        return MainTasks.shared.run("apply") {
            let old = rawLibrary
            rawLibrary = lib
            OffMain.release(old)
            return applyCustomizations()
        }
    }

    /// Build 148: de gefilterde lijst publiceren; de vorige buiten de hoofdthread vrijgeven
    private func publish(_ lib: Library) {
        let old = library
        library = lib
        OffMain.release(old)
    }

    /// Build 148: duur van het filteren op de achtergrond (`index`) en van het publiceren op de hoofdthread (`apply`)
    struct ApplyTiming: Sendable { var indexMs: Double = 0; var applyMs: Double = 0 }

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
        /// Build 151: gewenste taallabels ("NL", "BE", "EN" …): bij dubbele titels in samengevoegde categorieën gaat
        /// de bron in de audio- of app-taal voor, dan een meertalige bron, dan de rest
        var want: [String] = []

        /// Dezelfde regels (alles behalve de classificaties zelf)? Dan mag de vorige uitkomst blijven staan
        /// tot de nieuwe klaar is, en hoeft een gelijke uitkomst niet opnieuw gepubliceerd te worden.
        func sameRules(as o: FilterContext) -> Bool {
            playlist == o.playlist && ageLimit == o.ageLimit && strict == o.strict && parentalEnabled == o.parentalEnabled
                && autoLockAdult == o.autoLockAdult && unlocked == o.unlocked && lockedGroups == o.lockedGroups
                && custom == o.custom && hiddenGroups == o.hiddenGroups && kids == o.kids && want == o.want
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
                             hiddenGroups: kids ? [] : st.hiddenGroups(for: s.id), kids: kids,
                             want: SourcePreference.want(audio: [TrackPreferences.preferredAudio], app: TrackPreferences.appLanguage))
    }

    /// Build 151: wat bij het ophalen van deze server niet ingelezen hoeft te worden (categorie uit). Nil = alles
    /// inlezen (kinderprofiel: daar gelden de verborgen categorieën niet; App Store-screenshots).
    func skipFilter(for s: PlaylistSource) -> SkipFilter? {
        guard !Screenshots.isActive else { return nil }
        let ctx = context(for: s)
        guard !ctx.kids, !ctx.hiddenGroups.isEmpty || ctx.custom.hidden.contains(where: { $0.hasPrefix("group:") }) else { return nil }
        return SkipFilter { Self.categoryHidden($0, ctx) }
    }

    /// Build 151: categorie uit (zelfde regel als in `apply` en de diagnose; kinderslot telt hier niet, dat kan open)
    nonisolated static func categoryHidden(_ g: String, _ ctx: FilterContext) -> Bool {
        let c = ctx.custom
        return !ctx.kids && (ctx.hiddenGroups.contains(g) || c.hidden.contains(Customization.groupKey(g))
                             || c.hidden.contains(Customization.groupKey(c.merged[g] ?? g)))
    }

    /// Build 151: niet ingelezen categorie die nu wél zichtbaar is (aangezet, ander profiel)? Dan deze server op de
    /// achtergrond opnieuw ophalen (één keer per lijst). Andere servers krijgen hem bij hun volgende keer bijwerken.
    private var refetchedRaw = -1
    private func refetchIfUnhidden(_ s: PlaylistSource, _ ctx: FilterContext) {
        guard let sk = rawLibrary.skipped, refetchedRaw != rawVersion, !Screenshots.isActive,
              !refreshingAll, updateTask == nil, !isLoading else { return }
        let still: (String) -> Bool = { g in ctx.kids ? !KidsCategory.isKids(g) : Self.categoryHidden(g, ctx) }
        guard sk.needsRefetch(stillHidden: still) else { return }
        refetchedRaw = rawVersion
        Task { @MainActor [weak self] in
            guard let self, self.source?.id == s.id else { return }
            _ = await self.refresh(s, showSpinner: false)
        }
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
    /// Build 148: geeft de taak terug (met de duur van filteren en publiceren), zodat het bijwerken erop kan wachten.
    @discardableResult
    func applyCustomizations() -> Task<ApplyTiming, Never>? {
        guard let s = source else { publish(rawLibrary); libraryRawVersion = -1; return nil }
        let ctx = context(for: s)
        let raw = rawLibrary
        refetchIfUnhidden(s, ctx)   // build 151
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
            FetchLog.shared.noteVisibility(s.id, Self.visibilityStats(raw, lib, ctx))
            if let previous, Self.sameContent(previous, lib) { return nil }
            publish(lib)
            libraryRawVersion = rv
            libraryContext = ctx
            return nil
        }
        // kinderprofiel/leeftijdsgrens: niets ongefilterds laten zien terwijl er gefilterd wordt
        // (alleen bij een nieuwe lijst; bij opnieuw filteren blijft de vorige uitkomst staan tot de nieuwe klaar is)
        if ctx.ageLimit != nil && previous == nil { publish(Library()); libraryRawVersion = -1 }
        // stil opnieuw filteren (vorige uitkomst blijft staan): geen extra schermverversingen voor de spinner
        if previous == nil { isFiltering = true }
        let sid = s.id
        return Task {
            var timing = ApplyTiming()
            let t0 = Date()
            let (result, vis) = await Task.detached(priority: .userInitiated) { () -> (Library?, [FetchStatus.Kind: FetchVisibility]) in
                let lib = Self.apply(raw, ctx)
                let vis = Self.visibilityStats(raw, lib, ctx)
                if let previous, Self.sameContent(previous, lib) { return (nil, vis) }
                return (lib, vis)
            }.value
            timing.indexMs = Date().timeIntervalSince(t0) * 1000
            guard gen == self.filterGeneration else { return timing }   // intussen opnieuw gefilterd
            let t1 = Date()
            FetchLog.shared.noteVisibility(sid, vis)
            if let result {
                MainTasks.shared.run("apply") {
                    self.publish(result)
                    self.libraryRawVersion = rv
                    self.libraryContext = ctx
                }
            }
            if self.isFiltering { self.isFiltering = false }
            timing.applyMs = Date().timeIntervalSince(t1) * 1000
            return timing
        }
    }

    /// Build 148 (diagnose): per soort zichtbaar, en hoeveel er verborgen is door categorieën of het kinderfilter
    /// (de rest: leeftijd, kinderslot, eigen verborgen titels = overig). Dubbele titels laat de app gewoon staan.
    nonisolated static func visibilityStats(_ raw: Library, _ lib: Library, _ ctx: FilterContext) -> [FetchStatus.Kind: FetchVisibility] {
        let c = ctx.custom
        var cat: [String: Bool] = [:], kid: [String: Bool] = [:]
        func catHidden(_ g: String) -> Bool {
            if let v = cat[g] { return v }
            let v = !ctx.kids && (ctx.hiddenGroups.contains(g) || c.hidden.contains(Customization.groupKey(g))
                                  || c.hidden.contains(Customization.groupKey(c.merged[g] ?? g)))
            cat[g] = v
            return v
        }
        func kidsHidden(_ g: String) -> Bool {
            guard ctx.kids else { return false }
            if let v = kid[g] { return v }
            let v = !KidsCategory.isKids(g)
            kid[g] = v
            return v
        }
        // build 151: niet ingelezen items (verborgen categorieën) tellen als geleverd en verborgen door categorieën
        func stats(_ groups: [String], visible: Int, skipped: Int) -> FetchVisibility {
            var cats = skipped, kids = 0
            for g in groups { if catHidden(g) { cats += 1 } else if kidsHidden(g) { kids += 1 } }
            return FetchVisibility(visible: visible, hidden: HiddenCounts.make(delivered: groups.count + skipped, visible: visible,
                                                                               categories: cats, kids: kids, duplicates: 0))
        }
        let sk = raw.skipped
        return [.live: stats(raw.channels.map(\.group), visible: lib.channels.count, skipped: sk?.count(.live) ?? 0),
                .movie: stats(raw.movies.map(\.group), visible: lib.movies.count, skipped: sk?.count(.movie) ?? 0),
                .series: stats(raw.series.map(\.group), visible: lib.series.count, skipped: sk?.count(.series) ?? 0)]
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
        // build 150: de naam opgeschoond (taal-, land- en kwaliteitslabels weg, nette hoofdletters) en gelijke namen
        // (hoofdletterongevoelig) als één categorie; een eigen naam (hernoemen) gaat voor. Per groep één keer.
        var groupName: [String: String] = [:]
        var firstName: [String: String] = [:]
        func group(_ g: String) -> String {
            if let v = groupName[g] { return v }
            let merged = c.merged[g] ?? g
            let v: String
            if let r = c.renamed[Customization.groupKey(merged)] {
                v = r
            } else {
                let name = CategoryName.clean(merged)
                let k = CategoryName.mergeKey(name)
                if let first = firstName[k] { v = first } else { firstName[k] = name; v = name }
            }
            groupName[g] = v
            CategoryMerge.note(display: v, raw: g)
            return v
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
        lib.skipped = nil   // build 151: de compacte index hoort alleen bij de ongefilterde lijst
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
        let keptMovies = raw.movies.filter { visible($0.id, $0.group) && (!ageFilter || movieOK($0)) }
        lib.movies = keptMovies.map { m in
            var x = m; x.group = group(m.group); x.title = c.renamed[m.id] ?? m.title; return x
        }
        let keptSeries = raw.series.filter { visible($0.id, $0.group) && (!ageFilter || seriesOK($0)) }
        lib.series = keptSeries.map { se in
            var x = se; x.group = group(se.group); x.title = c.renamed[se.id] ?? se.title; return x
        }
        // build 151: samengevoegde categorieën: de bron in de audio-/app-taal eerst (dan meertalig, dan de rest), zodat
        // bij dubbele titels die bron blijft (`CategoryMerge.unique` houdt de eerste)
        preferSources(&lib.movies, raw: keptMovies.map(\.group), group: \.group, want: ctx.want)
        preferSources(&lib.series, raw: keptSeries.map(\.group), group: \.group, want: ctx.want)
        // eigen volgorde: groepen, dan kanalen binnen een groep
        if !c.groupOrder.isEmpty || !c.channelOrder.isEmpty {
            // build 150: de eigen volgorde staat op de namen van de server; de rijen hebben de opgeschoonde naam
            var gIndex: [String: Int] = [:]
            for (i, g) in c.groupOrder.enumerated() {
                if gIndex[g] == nil { gIndex[g] = i }
                let shown = group(g)
                if gIndex[shown] == nil { gIndex[shown] = i }
            }
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

    /// Build 151: binnen elke samengevoegde categorie (meer dan één bron) de items op bronvoorkeur zetten (stabiel);
    /// de plekken van de categorie in de lijst blijven gelijk, andere categorieën worden niet aangeraakt.
    nonisolated static func preferSources<T>(_ items: inout [T], raw: [String], group: KeyPath<T, String>, want: [String]) {
        guard !want.isEmpty, raw.count == items.count, items.count > 1 else { return }
        var sources: [String: String] = [:]          // weergavenaam → eerste bron
        var merged = Set<String>()
        for (i, x) in items.enumerated() {
            let d = x[keyPath: group]
            if let first = sources[d] { if first != raw[i] { merged.insert(d) } } else { sources[d] = raw[i] }
        }
        guard !merged.isEmpty else { return }
        var rank: [String: Int] = [:]
        func r(_ g: String) -> Int {
            if let v = rank[g] { return v }
            let v = SourcePreference.rank(group: g, want: want)
            rank[g] = v
            return v
        }
        var slots: [String: [Int]] = [:]
        for (i, x) in items.enumerated() where merged.contains(x[keyPath: group]) { slots[x[keyPath: group], default: []].append(i) }
        for (_, idx) in slots {
            let ordered = idx.enumerated().sorted { a, b in
                let ra = r(raw[a.element]), rb = r(raw[b.element])
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map { items[$0.element] }
            for (k, i) in idx.enumerated() { items[i] = ordered[k] }
        }
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
        /// Build 149: treffers in verborgen categorieën (onderaan, met label)
        var hiddenMovies: [Movie] = []; var hiddenSeries: [Series] = []
        var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty && other.isEmpty && hiddenMovies.isEmpty && hiddenSeries.isEmpty }
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
    nonisolated static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).nativeUTF8 }

    /// Build 149: zoeksleutels (SearchMatch.normalize) één keer per lijst berekend, op de achtergrond, en bewaard
    /// tot de lijst verandert; niet bij elke zoekopdracht opnieuw.
    final class SearchKeys: @unchecked Sendable {
        static let shared = SearchKeys()
        struct Keys: Sendable {
            var channels: [String] = []
            var movies: [(text: String, year: Int?)] = []
            var series: [(text: String, year: Int?)] = []
            /// Build 151: de compacte zoekindex (verborgen categorieën)
            var rows: [(text: String, year: Int?)] = []
        }
        private let lock = NSLock()
        private var cache: [String: Keys] = [:]

        func keys(_ id: String, _ lib: Library) -> Keys {
            lock.lock()
            if let k = cache[id] { lock.unlock(); return k }
            lock.unlock()
            var k = Keys()
            k.channels = lib.channels.map { SearchMatch.normalize($0.name).text }
            k.movies = lib.movies.map { m -> (text: String, year: Int?) in let n = SearchMatch.normalize(m.title); return (text: n.text, year: n.year ?? m.year) }
            k.series = lib.series.map { x -> (text: String, year: Int?) in let n = SearchMatch.normalize(x.title); return (text: n.text, year: n.year ?? x.year) }
            k.rows = (lib.skipped?.rows ?? []).map { r -> (text: String, year: Int?) in let n = SearchMatch.normalize(r.t); return (text: n.text, year: n.year ?? r.y) }
            lock.lock()
            if cache.count > 6 { cache.removeAll() }   // oude lijsten vergeten
            cache[id] = k
            lock.unlock()
            return k
        }
    }

    /// Treffers gerangschikt (score + kleine bonus voor recent en populair), stabiel bij gelijke score
    nonisolated static func ranked<T>(_ items: [T], _ keys: [(text: String, year: Int?)], _ q: SearchMatch.Query,
                                      boost: (T) -> Int, limit: Int) -> [T] {
        var hits: [(i: Int, s: Int)] = []
        for (i, k) in keys.enumerated() where i < items.count {
            if let sc = SearchMatch.score(q, text: k.text, year: k.year) { hits.append((i, sc + boost(items[i]))) }
        }
        hits.sort { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }
        return hits.prefix(limit).map { items[$0.i] }
    }

    /// Build 149: op woorden (elk woord, willekeurige volgorde, woordbegin of deel, één typefout bij 5+ letters),
    /// gerangschikt; alles op de achtergrond. Bij Stremio ook via de zoek-catalogi van de add-ons. Treffers in
    /// verborgen categorieën onderaan (niet bij een kinderprofiel; kinderslot en leeftijd blijven gelden).
    func search(_ q: String, allPlaylists: Bool = true) async -> SearchResults {
        let query = SearchMatch.query(q)
        guard q.trimmingCharacters(in: .whitespaces).count >= 2, !query.words.isEmpty else { return SearchResults() }
        let lib = library, raw = rawLibrary
        let libID = "lib-\(source?.id.uuidString ?? "")-\(libraryVersion)", rawID = "raw-\(source?.id.uuidString ?? "")-\(rawVersion)"
        let ctx = source.map { context(for: $0) }
        // build 151: treffers uit de compacte zoekindex (niet ingelezen verborgen categorieën) als film/serie
        let xc: XtreamClient? = source.flatMap { $0.kind == .xtream ? XtreamClient(source: $0, password: Keychain.get($0.passwordKey) ?? "") : nil }
        let addons = source?.kind == .stremio ? stremioAddons : []
        async let remote: Library = addons.isEmpty ? Library() : Self.withTimeout149(6) { await StremioClient(addons: addons).search(q) }
        var r = await Task.detached(priority: .userInitiated) { () -> SearchResults in
            var r = SearchResults()
            let k = SearchKeys.shared.keys(libID, lib)
            r.channels = Self.ranked(lib.channels, k.channels.map { (text: $0, year: nil as Int?) }, query, boost: { _ in 0 }, limit: 60)
            r.movies = Self.ranked(lib.movies, k.movies, query, boost: { SearchMatch.boost(rating: $0.rating, added: $0.addedAt) }, limit: 200)
            r.series = Self.ranked(lib.series, k.series, query, boost: { SearchMatch.boost(rating: $0.rating, added: $0.addedAt) }, limit: 200)
            // verborgen categorieën: treffers uit de ongefilterde lijst die alleen door het verbergen wegvallen
            let skippedRows = raw.skipped?.rows.count ?? 0
            if let ctx, !ctx.kids, raw.movies.count + raw.series.count > lib.movies.count + lib.series.count || skippedRows > 0 {
                let rk = SearchKeys.shared.keys(rawID, raw)
                let shownM = Set(lib.movies.map(\.id)), shownS = Set(lib.series.map(\.id))
                var cand = Library()
                if raw.movies.count + raw.series.count > lib.movies.count + lib.series.count {
                    cand.movies = Self.ranked(raw.movies, rk.movies, query, boost: { _ in 0 }, limit: 400).filter { !shownM.contains($0.id) }
                    cand.series = Self.ranked(raw.series, rk.series, query, boost: { _ in 0 }, limit: 400).filter { !shownS.contains($0.id) }
                }
                if let sk = raw.skipped, let xc, skippedRows > 0 {
                    for row in Self.ranked(sk.rows, rk.rows, query, boost: { _ in 0 }, limit: 400) {
                        let g = sk.group(of: row)
                        if row.k == .movie, let m = xc.movie(row, group: g) { cand.movies.append(m) }
                        else if row.k == .series, let x = xc.series(row, group: g) { cand.series.append(x) }
                    }
                }
                if !cand.movies.isEmpty || !cand.series.isEmpty {
                    var open = ctx
                    open.hiddenGroups = []
                    open.custom.hidden = ctx.custom.hidden.filter { !$0.hasPrefix("group:") }
                    let ok = Self.apply(cand, open)   // kinderslot, leeftijd en eigen verborgen titels blijven gelden
                    r.hiddenMovies = Array(ok.movies.prefix(60))
                    r.hiddenSeries = Array(ok.series.prefix(60))
                }
            }
            return r
        }.value
        // Stremio: treffers van de add-ons erbij, zonder dubbele (IMDb-id of titel + jaar)
        let extra = await remote
        if !extra.movies.isEmpty || !extra.series.isEmpty {
            var seen = Set(r.movies.map { $0.imdbID ?? "\(Self.normTitle($0.title))|\($0.year ?? 0)" })
            for m in extra.movies where seen.insert(m.imdbID ?? "\(Self.normTitle(m.title))|\(m.year ?? 0)").inserted { r.movies.append(m) }
            seen = Set(r.series.map { $0.imdbID ?? "\(Self.normTitle($0.title))|\($0.year ?? 0)" })
            for x in extra.series where seen.insert(x.imdbID ?? "\(Self.normTitle(x.title))|\(x.year ?? 0)").inserted { r.series.append(x) }
        }
        guard allPlaylists else { return r }
        // zoeken in de cache van alle andere afspeellijsten
        let others = CloudStore.shared.playlists.filter { $0.id != source?.id }
        let liveLabel = L("Live TV")
        // build 130: elk profiel ziet alle servers, met zijn eigen filter per server (leeftijd, kinderslot, categorieën)
        let ageCtx = Dictionary(uniqueKeysWithValues: others.map { p in (p.id, context(for: p)) })
        r.other = await Task.detached(priority: .userInitiated) {
            var hits: [(hit: OtherHit, score: Int)] = []
            for p in others {
                guard let raw = Self.readCache(p) else { continue }
                let lib = ageCtx[p.id].map { Self.apply(raw, $0) } ?? raw
                var live = 0
                for c in lib.channels {
                    guard live < 80, let sc = SearchMatch.score(query, text: SearchMatch.normalize(c.name).text) else { continue }
                    live += 1
                    hits.append((OtherHit(playlist: p, itemID: c.id, title: c.name, subtitle: liveLabel, artwork: c.logo, isLive: true), sc))
                }
                for mv in lib.movies {
                    let n = SearchMatch.normalize(mv.title)
                    guard let sc = SearchMatch.score(query, text: n.text, year: n.year ?? mv.year) else { continue }
                    hits.append((OtherHit(playlist: p, itemID: mv.id, title: mv.title, subtitle: mv.year.map(String.init) ?? "", artwork: mv.poster), sc))
                }
                for se in lib.series {
                    let n = SearchMatch.normalize(se.title)
                    guard let sc = SearchMatch.score(query, text: n.text, year: n.year ?? se.year) else { continue }
                    hits.append((OtherHit(playlist: p, itemID: se.id, title: se.title, subtitle: se.year.map(String.init) ?? "", artwork: se.poster), sc))
                }
            }
            // beste eerst; Live TV altijd als laatste
            let sorted = hits.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .map(\.element.hit)
            let kept = sorted.prefix(120)
            return kept.filter { !$0.isLive } + kept.filter { $0.isLive }
        }.value
        return r
    }

    /// Build 149: werk met een tijdslimiet (zoeken bij add-ons mag de lokale treffers niet ophouden)
    nonisolated static func withTimeout149(_ seconds: Double, _ work: @escaping @Sendable () async -> Library) async -> Library {
        await withTaskGroup(of: Library?.self) { g in
            g.addTask { await work() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            for await r in g {
                if let r { g.cancelAll(); return r }
                g.cancelAll(); return Library()
            }
            return Library()
        }
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
    /// Build 148: wachten tot het bewaard is (fase `save` van het bijwerken)
    private func writeCache(_ s: PlaylistSource, _ lib: Library) async {
        let url = Self.cacheURL(s)
        // build 144: .utility i.p.v. .background: met .background stelde het systeem het wegschrijven soms zo lang uit
        // dat de app eerder stopte; dan was er bij de volgende start geen bewaarde lijst en werd alles opnieuw opgehaald
        await Task.detached(priority: .utility) {
            // build 149: in stukken naar het bestand (geen volledige kopie van de hele lijst als JSON in het geheugen)
            try? Self.writeLibrary(lib, to: url)
        }.value
    }

    /// Build 149: zelfde JSON als `JSONEncoder().encode(lib)`, maar in stukken weggeschreven (ChunkedJSONWriter)
    nonisolated static func writeLibrary(_ lib: Library, to url: URL) throws {
        let w = try ChunkedJSONWriter(url: url, chunk: 2000)
        do {
            try w.array("channels", lib.channels)
            try w.array("movies", lib.movies)
            try w.array("series", lib.series)
            try w.dictionary("epg", lib.epg)
            if let sk = lib.skipped { try w.value("skipped", sk) }   // build 151
            try w.finish()
        } catch {
            w.cancel()
            throw error
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
        try? writeLibrary(l, to: catalogURL(s))   // build 149: in stukken
    }
}

/// Build 145: "Servers laden bij openen" (per apparaat, niet gesynct), zie `StartLoad` (Build145.swift).
extension StartLoad {
    static var current: Mode { mode(UserDefaults.standard.string(forKey: key)) }

    /// Eenmalig: de oude vernieuwtermijn (`playlist.refresh`) wordt Vragen; de oude sleutel gaat weg.
    static func migrateIfNeeded(_ d: UserDefaults = .standard) {
        guard !d.bool(forKey: migratedKey) else { return }
        d.set(migrated(legacy: d.string(forKey: legacyKey), current: d.string(forKey: key)).rawValue, forKey: key)
        d.removeObject(forKey: legacyKey)
        d.set(true, forKey: migratedKey)
    }
}

extension StartLoad.Mode {
    var title: String {
        switch self {
        case .ask: return L("Ask")
        case .always: return L("Always")
        case .never: return L("Never, manually only")
        }
    }
}
