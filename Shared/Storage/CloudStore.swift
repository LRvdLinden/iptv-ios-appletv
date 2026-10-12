import Foundation
import Combine

struct ProgressEntry: Codable, Hashable {
    var fraction: Double
    var position: Double
    var updated: Date
    var title: String
    var artwork: URL?
    var playlistID: UUID?
    /// Van welk kijkprofiel (nil = van vóór de profielen → hoort bij het hoofdaccount)
    var profileID: UUID? = nil
}

/// Alles wat tussen iPhone/iPad en Apple TV gedeeld wordt, via iCloud Key-Value Store.
/// (Max 1 MB — ruim genoeg voor configuratie, favorieten en kijkvoortgang.)
@MainActor
final class CloudStore: ObservableObject {
    static let shared = CloudStore()

    @Published private(set) var playlists: [PlaylistSource] = []
    @Published private(set) var favorites: Set<String> = []          // "<playlistID>|<itemID>"
    @Published private(set) var myList: Set<String> = []
    @Published private(set) var progress: [String: ProgressEntry] = [:] // key: itemKey
    @Published private(set) var localWatched: Set<String> = []       // fallback zonder Trakt
    @Published private(set) var recentChannels: [String] = []
    @Published var lastSync: Date?
    /// Per afspeellijst: hernoemd, verborgen, volgorde, samengevoegd
    @Published private(set) var customizations: [UUID: Customization] = [:]
    @Published private(set) var parental = ParentalSettings()
    @Published private(set) var reminders: [ProgramReminder] = []
    /// Eigen profielfoto's per afspeellijst (klein JPEG, ±15 KB, via iCloud gedeeld)
    @Published private(set) var photos: [UUID: Data] = [:]
    /// Kijkgeschiedenis, per profiel (afspeellijst)
    @Published private(set) var history: [HistoryEntry] = []
    /// Eigen collecties van alle profielen op dit apparaat (build 54: per profiel, zie `owner`), inclusief
    /// tombstones (`deleted`). Zonder `owner`: nog niet gemigreerd (build 51–53, voor het hele account).
    @Published private(set) var collections: [BingrCollection] = [] { didSet { refreshActiveCollections() } }
    /// Startscherm per profiel (profiel-ID → indeling)
    @Published private(set) var homeLayouts: [String: HomeLayout] = [:]
    /// Het profiel dat nu open is (gezet door PlaylistService)
    var activePlaylistID: UUID?

    // MARK: profielen ("Wie kijkt er?")
    //
    // Eén hoofdaccount met de server(s), Trakt en OpenSubtitles; daaronder kijkprofielen.
    // Per profiel apart: Mijn lijst, favorieten, kijkvoortgang/Verder kijken, bekeken, recente zenders,
    // kijkgeschiedenis, avatar/foto en leeftijdsgrens. Gedeeld: server(s), aanpassingen, Trakt, OpenSubtitles.

    @Published private(set) var profiles: [ViewerProfile] = [] { didSet { refreshActiveCollections() } }
    /// De server die alle profielen gebruiken
    @Published private(set) var mainSourceID: UUID?
    /// Gekozen profiel op dít apparaat (per Apple TV-gebruiker apart)
    @Published private(set) var activeProfileID: UUID? = UserDefaults.standard.string(forKey: "activeProfileID").flatMap(UUID.init) {
        didSet { refreshActiveCollections() }
    }

    var activeProfile: ViewerProfile? { profiles.first { $0.id == activeProfileID } }

    /// Het hoofdaccount: alleen dat profiel stelt de server, Trakt, OpenSubtitles, kinderslot,
    /// categorieën en profielen in. Standaard het eerste profiel.
    @Published private(set) var mainProfileIDStored: UUID? { didSet { refreshActiveCollections() } }
    var mainProfileID: UUID? {
        if let m = mainProfileIDStored, profiles.contains(where: { $0.id == m }) { return m }
        return profiles.first?.id
    }
    var isMainActive: Bool { activeProfileID != nil && activeProfileID == mainProfileID }
    func isMain(_ p: ViewerProfile) -> Bool { p.id == mainProfileID }
    var mainSource: PlaylistSource? { playlists.first { $0.id == mainSourceID } ?? playlists.first }

    /// Sleutel per profiel ("favorites.v1.<profiel>")
    private func pk(_ base: String) -> String { activeProfileID.map { "\(base).\($0.uuidString)" } ?? base }
    /// Lezen per profiel; bestaat die nog niet, dan de gegevens van vóór de profielen (eenmalige overname)
    private func scoped<T: Decodable>(_ t: T.Type, _ base: String) -> T? {
        if let v = decode(t, pk(base)) { return v }
        // alleen het hoofdaccount neemt de gegevens van vóór de profielen over; nieuwe profielen beginnen leeg
        return (activeProfileID == nil || activeProfileID == mainProfileID) ? decode(t, base) : nil
    }

    private func loadProfileData() {
        assign(\.favorites, scoped(Set<String>.self, K.favorites) ?? [])
        assign(\.myList, scoped(Set<String>.self, K.myList) ?? [])
        assign(\.localWatched, scoped(Set<String>.self, K.watched) ?? [])
        assign(\.recentChannels, scoped([String].self, K.recent) ?? [])
        assign(\.history, scoped([HistoryEntry].self, K.history) ?? [])
    }

    /// Bestaande afspeellijsten (vroeger = profielen) omzetten naar kijkprofielen.
    private func migrateToProfiles() {
        guard profiles.isEmpty, !playlists.isEmpty, data(K.profiles) == nil else { return }
        var photosCopy = photos
        profiles = playlists.map { p in
            let prof = ViewerProfile(name: p.name, avatar: p.avatar, ageLimit: p.ageLimit)
            if let ph = photos[p.id] { photosCopy[prof.id] = ph }
            return prof
        }
        photos = photosCopy
        write(photos, K.photos)
        write(profiles, K.profiles)
        mainProfileIDStored = profiles.first?.id
        write(mainProfileIDStored, K.mainProfile)
        let last = UserDefaults.standard.string(forKey: "lastPlaylistID").flatMap(UUID.init)
        mainSourceID = playlists.first { $0.id == last }?.id ?? playlists.first?.id
        write(mainSourceID, K.mainSource)
    }

    func selectProfile(_ p: ViewerProfile) {
        activeProfileID = p.id
        UserDefaults.standard.set(p.id.uuidString, forKey: "activeProfileID")
        applyPreferences(of: p)
        applyActiveAccent()
        loadProfileData()
        progress = scoped([String: ProgressEntry].self, K.progress) ?? [:]
    }

    /// Kijkvoorkeuren van dit profiel actief maken (automatische ondertitels, talen).
    private func applyPreferences(of p: ViewerProfile) {
        let d = UserDefaults.standard
        let fresh = !isMain(p)   // nieuw/ander profiel zonder eigen keuze → standaardwaarden, niet die van een ander
        if let v = p.autoSubtitles { d.set(v, forKey: "autoSubtitles") } else if fresh { d.set(false, forKey: "autoSubtitles") }
        // build 59: ondertitels automatisch (uit / wanneer nodig / altijd)
        if let v = p.effectiveSubtitleMode { d.set(v, forKey: TrackPreferences.subtitleModeKey) }
        // oud "off" als ondertiteltaal zonder gekozen modus = automatisch uit
        else if p.streamSubtitleLanguage == "off" { d.set(TrackPreferences.SubtitleMode.off.rawValue, forKey: TrackPreferences.subtitleModeKey) }
        else if fresh { d.set(TrackPreferences.SubtitleMode.whenNeeded.rawValue, forKey: TrackPreferences.subtitleModeKey) }
        if let v = p.audioLanguage { d.set(v, forKey: TrackPreferences.audioKey) } else if fresh { d.set("", forKey: TrackPreferences.audioKey) }
        if let v = p.streamSubtitleLanguage { d.set(v, forKey: TrackPreferences.subtitleKey) } else if fresh { d.set("", forKey: TrackPreferences.subtitleKey) }
        if let v = p.subtitleLanguage { OpenSubtitles.shared.defaultLanguage = v }
        else if fresh { OpenSubtitles.shared.defaultLanguage = String(Localizer.shared.language.prefix(2)) }
    }

    /// Kijkvoorkeur van het actieve profiel opslaan.
    func updateActivePreferences(_ change: (inout ViewerProfile) -> Void) {
        guard var p = activeProfile else { return }
        change(&p)
        upsertProfile(p)
    }

    func upsertProfile(_ p: ViewerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        write(profiles, K.profiles)
        if p.id == activeProfileID { applyActiveAccent() }
        edited(.prefs)
    }

    // MARK: accentkleur per profiel (build 54)

    /// De accentkleur van het actieve profiel actief maken (de app tekent dan meteen opnieuw, zie BingrApp).
    /// Zonder actief profiel ("Wie kijkt er?") blijft de laatste kleur staan.
    func applyActiveAccent() {
        guard let p = activeProfile else { return }
        let v = AccentChoice.of(p).rawValue
        if local.string(forKey: AccentChoice.key) != v { local.set(v, forKey: AccentChoice.key) }
    }

    /// Eenmalige migratie: de oude kleur van het account (`settings.shared.accentColor`, build 52/53) naar elk
    /// profiel zonder eigen `accentColor`, zodat niemands kleur verandert. Daarna wordt de oude kleur niet meer gelezen.
    /// Zonder bekende oude kleur gebeurt er nog niets (die kan later via de account binnenkomen).
    func migrateLegacyAccent() {
        guard !local.bool(forKey: AccentChoice.migratedKey) else { return }
        guard let legacy = AccentChoice.legacy, !profiles.isEmpty else { return }
        var changed = false
        for i in profiles.indices where profiles[i].accentColor == nil {
            profiles[i].accentColor = legacy.rawValue
            changed = true
        }
        if changed { write(profiles, K.profiles) }
        local.set(true, forKey: AccentChoice.migratedKey)
        applyActiveAccent()
    }

    /// Profiel op dít apparaat verwijderd: ProfileSync zet er een tombstone voor in de Bingr-account
    /// (zie "Profielen volledig synchroniseren (build 41)" in docs/ACCOUNT.md).
    let profileDeleted = PassthroughSubject<UUID, Never>()

    func deleteProfile(_ p: ViewerProfile) {
        guard !isMain(p) else { return }   // het hoofdaccount blijft altijd bestaan
        profiles.removeAll { $0.id == p.id }
        write(profiles, K.profiles)
        setPhoto(nil, for: p.id)
        purgeProfileData(p.id)
        if activeProfileID == p.id { activeProfileID = nil; UserDefaults.standard.removeObject(forKey: "activeProfileID") }
        profileDeleted.send(p.id)
    }

    /// De lokale gegevens van een (verwijderd) profiel wissen: lijsten, voortgang, geschiedenis en pincode.
    func purgeProfileData(_ id: UUID) {
        guard id != mainProfileID else { return }
        for base in [K.favorites, K.myList, K.watched, K.recent, K.history, K.progress] {
            let key = "\(base).\(id.uuidString)"
            kv.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        kv.synchronize()
        if Keychain.get("profile.\(id.uuidString).pin") != nil { Keychain.set(nil, for: "profile.\(id.uuidString).pin") }
        // collecties van dit profiel (build 54)
        if collections.contains(where: { $0.owner == id }) {
            collections.removeAll { $0.owner == id }
            write(collections, K.collections)
        }
    }

    /// Profielen uit de Bingr-account overnemen (importeren/samenvoegen, zie ProfileSync).
    /// `mainID` nil = het huidige hoofdprofiel houden.
    func replaceProfiles(_ list: [ViewerProfile], mainID: UUID?) {
        let removed = profiles.filter { old in !list.contains { $0.id == old.id } }
        // gelijke waarden niet opnieuw publiceren (elke sync-ronde liet anders alle schermen opnieuw tekenen)
        assign(\.profiles, list)
        write(profiles, K.profiles)
        if let mainID {
            assign(\.mainProfileIDStored, mainID)
            write(mainProfileIDStored, K.mainProfile)
        }
        for p in removed where photos[p.id] != nil { setSyncedPhoto(nil, for: p.id) }
        if let a = activeProfileID, !list.contains(where: { $0.id == a }) {
            activeProfileID = nil
            UserDefaults.standard.removeObject(forKey: "activeProfileID")
        }
        applyActiveAccent()   // kleur van het actieve profiel kan op een ander apparaat gewijzigd zijn
    }

    func setMainSource(_ id: UUID) {
        assign(\.mainSourceID, id)
        write(mainSourceID, K.mainSource)
    }

    private let kv = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var observer: NSObjectProtocol?

    private enum K {
        static let playlists = "playlists.v1", favorites = "favorites.v1", myList = "mylist.v1",
                   progress = "progress.v1", watched = "watched.v1", recent = "recent.v1",
                   custom = "custom.v1", parental = "parental.v1", reminders = "reminders.v1",
                   photos = "photos.v1", history = "history.v1",
                   profiles = "profiles.v1", mainSource = "mainsource.v1", mainProfile = "mainprofile.v1",
                   collections = "collections.v1", homeLayout = "homelayout.v1"
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.load(mergeProgress: true) }
            }
        kv.synchronize()
        load(mergeProgress: false)
    }

    // MARK: laden / opslaan

    private func data(_ key: String) -> Data? { kv.data(forKey: key) ?? local.data(forKey: key) }

    private func write<T: Encodable>(_ value: T, _ key: String) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        kv.set(d, forKey: key)
        local.set(d, forKey: key)
        kv.synchronize()
        touchLastSync()
    }

    /// "Laatst gesynchroniseerd" toont alleen uren en minuten: niet bij elke opslag (bijv. voortgang tijdens het
    /// kijken) publiceren, want dat laat elk scherm dat de store volgt opnieuw tekenen.
    private func touchLastSync() {
        let now = Date()
        if let l = lastSync, Calendar.current.isDate(l, equalTo: now, toGranularity: .minute) { return }
        lastSync = now
    }

    /// Alleen toewijzen als de waarde echt anders is: elke toewijzing aan een @Published-eigenschap (ook een gelijke)
    /// laat alle schermen die de store volgen opnieuw rekenen.
    private func assign<T: Equatable>(_ path: ReferenceWritableKeyPath<CloudStore, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func decode<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = data(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func load(mergeProgress: Bool) {
        // bij elke iCloud-wijziging van een ander apparaat: alleen wat echt veranderd is opnieuw publiceren
        assign(\.playlists, decode([PlaylistSource].self, K.playlists) ?? [])
        assign(\.profiles, decode([ViewerProfile].self, K.profiles) ?? [])
        assign(\.mainSourceID, decode(UUID.self, K.mainSource))
        assign(\.mainProfileIDStored, decode(UUID.self, K.mainProfile))
        migrateToProfiles()
        loadProfileData()
        // zonder Bingr-account in deze build: migraties alleen lokaal (anders na de sync, zie ProfileSync/StateSync)
        if !Secrets.accountsConfigured { migrateLegacyAccent() }
        applyActiveAccent()
        assign(\.customizations, decode([UUID: Customization].self, K.custom) ?? [:])
        assign(\.parental, decode(ParentalSettings.self, K.parental) ?? ParentalSettings())
        assign(\.photos, decode([UUID: Data].self, K.photos) ?? [:])
        assign(\.collections, decode([BingrCollection].self, K.collections) ?? collections)
        assign(\.homeLayouts, decode([String: HomeLayout].self, K.homeLayout) ?? homeLayouts)
        if !Secrets.accountsConfigured { migrateLegacyCollections() }
        // wachtwoorden/tokens ook via iCloud KV delen (Apple TV krijgt ze anders niet) — op de achtergrond,
        // sleutelhanger-acties zijn traag en blokkeerden het wisselen van profiel
        let secretKeys = playlists.flatMap { [$0.passwordKey, "playlist.\($0.id.uuidString).session"] }
            + ["trakt.tokens", "opensubtitles.session", "parental.pin"]
            + profiles.map { "profile.\($0.id.uuidString).pin" }
            + Secrets.Key.allCases.filter { !$0.builtInOnly }.map { "apikey.\($0.rawValue)" }
        DispatchQueue.global(qos: .utility).async {
            Keychain.syncFromCloud()
            Keychain.pushToCloud(keys: secretKeys)
            DispatchQueue.main.async { Secrets.reload() }
        }
        assign(\.reminders, (decode([ProgramReminder].self, K.reminders) ?? []).filter { $0.start > Date().addingTimeInterval(-3600) })
        let remote = scoped([String: ProgressEntry].self, K.progress) ?? [:]
        if mergeProgress {
            var merged = progress
            for (k, v) in remote where (merged[k]?.updated ?? .distantPast) < v.updated { merged[k] = v }
            assign(\.progress, merged)
        } else {
            assign(\.progress, remote)
        }
        touchLastSync()
    }

    // MARK: playlists

    func upsert(_ p: PlaylistSource) {
        var p = p; p.updatedAt = Date()
        if let i = playlists.firstIndex(where: { $0.id == p.id }) { playlists[i] = p } else { playlists.append(p) }
        write(playlists, K.playlists)
        // eerste server: meteen hoofdserver, en een eerste profiel als er nog geen is
        if mainSourceID == nil || !playlists.contains(where: { $0.id == mainSourceID }) { setMainSource(p.id) }
        if profiles.isEmpty {
            let main = ViewerProfile(name: p.name, avatar: p.avatar)
            upsertProfile(main)
            mainProfileIDStored = main.id
            write(mainProfileIDStored, K.mainProfile)
            if activeProfileID == nil { selectProfile(main) }
        }
    }

    /// Eigen foto gekozen, gewijzigd of verwijderd op dít apparaat (niet via iCloud of de account-sync).
    /// ProfileSync uploadt of verwijdert hem dan in de Bingr-account.
    let photoEdited = PassthroughSubject<UUID, Never>()

    func setPhoto(_ data: Data?, for playlist: UUID) {
        photos[playlist] = data
        write(photos, K.photos)
        photoEdited.send(playlist)
    }

    /// Foto uit de Bingr-account toepassen (gaat ook via iCloud, maar telt niet als eigen wijziging).
    func setSyncedPhoto(_ data: Data?, for profile: UUID) {
        guard photos[profile] != data else { return }
        photos[profile] = data
        write(photos, K.photos)
    }

    /// Server op dít apparaat verwijderd: SourceSync zet er een tombstone voor in de Bingr-account
    /// (zie "Servers en afspeellijsten via het account (build 43)" in docs/ACCOUNT.md).
    let sourceDeleted = PassthroughSubject<UUID, Never>()

    func delete(_ p: PlaylistSource) {
        removeSource(p.id)
        sourceDeleted.send(p.id)
    }

    /// Server lokaal verwijderen, met zijn aanpassingen, wachtwoorden/tokens en cache (zonder tombstone).
    func removeSource(_ id: UUID) {
        let old = playlists.first { $0.id == id }
        playlists.removeAll { $0.id == id }
        if mainSourceID == id { mainSourceID = playlists.first?.id; write(mainSourceID, K.mainSource) }
        if customizations[id] != nil { customizations[id] = nil; write(customizations, K.custom) }
        if photos[id] != nil { setPhoto(nil, for: id) }
        let prefix = Self.secretPrefix(id)
        let pl = parental.lockedGroups.filter { $0.hasPrefix(id.uuidString + "|") }
        if !pl.isEmpty { updateParental { $0.lockedGroups.subtract(pl) } }
        DispatchQueue.global(qos: .utility).async {
            for k in Keychain.keys(withPrefix: prefix) { Keychain.set(nil, for: k) }
        }
        if let old { try? FileManager.default.removeItem(at: PlaylistService.cacheURL(old)) }
        write(playlists, K.playlists)
    }

    /// Servers en profielen van het vorige account op dit apparaat (zie `wipeAccountData`)
    nonisolated static let foreignSourcesKey = "account.foreignSources.v1"
    nonisolated static let foreignProfilesKey = "account.foreignProfiles.v1"

    /// Voorvoegsel van alle geheime velden van een bron in de sleutelhanger: `playlist.<id>.`
    nonisolated static func secretPrefix(_ id: UUID) -> String { "playlist.\(id.uuidString)." }

    /// Servers uit de Bingr-account overnemen (importeren/samenvoegen, zie SourceSync). `updatedAt` blijft
    /// zoals gegeven. `mainID` nil = de huidige hoofdserver houden (zolang die bestaat).
    func replaceSources(_ list: [PlaylistSource], mainID: UUID?) {
        assign(\.playlists, list)
        write(playlists, K.playlists)
        if let mainID, list.contains(where: { $0.id == mainID }) {
            setMainSource(mainID)
        } else if mainSourceID == nil || !list.contains(where: { $0.id == mainSourceID }) {
            mainSourceID = list.first?.id
            write(mainSourceID, K.mainSource)
        }
        // eerste server en nog geen profiel: een hoofdprofiel (ProfileSync vervangt het als de account er heeft)
        if profiles.isEmpty, let p = list.first {
            let main = ViewerProfile(name: p.name, avatar: p.avatar)
            upsertProfile(main)
            mainProfileIDStored = main.id
            write(mainProfileIDStored, K.mainProfile)
        }
    }

    /// Aanpassingen van één bron in één keer zetten (uit de account-sync).
    func setCustomization(_ playlist: UUID, _ c: Customization?) {
        guard customizations[playlist] != c else { return }
        customizations[playlist] = c
        write(customizations, K.custom)
    }

    /// Kinderslot-groepen van één bron (`<id>|<groep>`) in één keer zetten (uit de account-sync).
    func setLockedGroups(_ playlist: UUID, _ groups: [String]) {
        let prefix = playlist.uuidString + "|"
        var set = parental.lockedGroups.filter { !$0.hasPrefix(prefix) }
        for g in groups { set.insert(prefix + g) }
        guard set != parental.lockedGroups else { return }
        updateParental { $0.lockedGroups = set }
    }

    /// Een **ander** account logt in op dit apparaat: eerst de servers, profielen en gegevens van het
    /// vorige account lokaal wissen (zie "Uitloggen" in "Servers en afspeellijsten via het account").
    func wipeAccountData() {
        let ids = playlists.map(\.id)
        let profileIDs = profiles.map(\.id)
        for p in playlists { try? FileManager.default.removeItem(at: PlaylistService.cacheURL(p)) }
        let bases = [K.favorites, K.myList, K.watched, K.recent, K.history, K.progress]
        let keys = Set(kv.dictionaryRepresentation.keys).union(local.dictionaryRepresentation().keys)
            .filter { k in bases.contains { k == $0 || k.hasPrefix($0 + ".") } }
        for k in keys { kv.removeObject(forKey: k); local.removeObject(forKey: k) }
        playlists = []; write(playlists, K.playlists)
        profiles = []; write(profiles, K.profiles)
        mainSourceID = nil; write(mainSourceID, K.mainSource)
        mainProfileIDStored = nil; write(mainProfileIDStored, K.mainProfile)
        customizations = [:]; write(customizations, K.custom)
        parental = ParentalSettings(); write(parental, K.parental)
        reminders = []; write(reminders, K.reminders)
        photos = [:]; write(photos, K.photos)
        collections = []; write(collections, K.collections)
        homeLayouts = [:]; write(homeLayouts, K.homeLayout)
        // oude accentkleur van het vorige account niet naar de profielen van dit account kopiëren
        local.removeObject(forKey: AccentChoice.legacyKey)
        local.removeObject(forKey: AccentChoice.migratedKey)
        favorites = []; myList = []; localWatched = []; recentChannels = []; history = []; progress = [:]
        activeProfileID = nil
        activePlaylistID = nil
        local.removeObject(forKey: "activeProfileID")
        local.removeObject(forKey: "lastPlaylistID")
        // iCloud kan de oude servers en profielen later terugbrengen: die horen niet bij het nieuwe account
        // en worden dan door SourceSync en ProfileSync lokaal weer gewist (niet geüpload)
        local.set(ids.map(\.uuidString), forKey: Self.foreignSourcesKey)
        local.set(profileIDs.map(\.uuidString), forKey: Self.foreignProfilesKey)
        kv.synchronize()
        DispatchQueue.global(qos: .utility).async {
            for id in ids { for k in Keychain.keys(withPrefix: Self.secretPrefix(id)) { Keychain.set(nil, for: k) } }
            for id in profileIDs { Keychain.set(nil, for: "profile.\(id.uuidString).pin") }
            Keychain.set(nil, for: "parental.pin")
        }
    }

    // MARK: overige gegevens via de Bingr-account (build 44, zie StateSync)

    /// Soort lokale wijziging, zodat StateSync weet wat er (vertraagd) naar de account moet.
    enum StateEdit { case profile, progress, prefs, reminders, settings, collections }
    /// Eigen wijziging op dit apparaat: (profiel-ID of nil, soort). Niet bij overnemen uit iCloud of de account.
    let stateEdited = PassthroughSubject<(UUID?, StateEdit), Never>()

    private func edited(_ kind: StateEdit) {
        stateEdited.send((activeProfileID ?? mainProfileID, kind))
    }

    /// Lijsten, voortgang en geschiedenis van één profiel (ook als het niet actief is).
    struct ProfileData: Equatable {
        var favorites: Set<String> = []
        var myList: Set<String> = []
        var watched: Set<String> = []
        var recentChannels: [String] = []
        var history: [HistoryEntry] = []
        var progress: [String: ProgressEntry] = [:]
    }

    /// Gegevens van een profiel lezen. Het hoofdprofiel neemt (net als `scoped`) de gegevens van vóór de profielen over.
    func profileData(_ id: UUID) -> ProfileData {
        // het actieve profiel: wat nu in het geheugen staat (dat is altijd het nieuwste)
        if id == activeProfileID {
            return ProfileData(favorites: favorites, myList: myList, watched: localWatched,
                               recentChannels: recentChannels, history: history, progress: progress)
        }
        func read<T: Decodable>(_ t: T.Type, _ base: String) -> T? {
            if let v = decode(t, "\(base).\(id.uuidString)") { return v }
            return id == mainProfileID ? decode(t, base) : nil
        }
        return ProfileData(favorites: read(Set<String>.self, K.favorites) ?? [],
                           myList: read(Set<String>.self, K.myList) ?? [],
                           watched: read(Set<String>.self, K.watched) ?? [],
                           recentChannels: read([String].self, K.recent) ?? [],
                           history: read([HistoryEntry].self, K.history) ?? [],
                           progress: read([String: ProgressEntry].self, K.progress) ?? [:])
    }

    /// Gegevens van een profiel uit de Bingr-account zetten (StateSync). Alleen wat veranderd is wordt geschreven;
    /// is het profiel actief, dan ziet de app het meteen.
    func setProfileData(_ id: UUID, _ d: ProfileData) {
        let old = profileData(id)
        guard old != d else { return }
        let suffix = ".\(id.uuidString)"
        if old.favorites != d.favorites { write(d.favorites, K.favorites + suffix) }
        if old.myList != d.myList { write(d.myList, K.myList + suffix) }
        if old.watched != d.watched { write(d.watched, K.watched + suffix) }
        if old.recentChannels != d.recentChannels { write(d.recentChannels, K.recent + suffix) }
        if old.history != d.history { write(d.history, K.history + suffix) }
        if old.progress != d.progress { write(d.progress, K.progress + suffix) }
        if id == activeProfileID {
            // alleen wat veranderd is: anders tekent elk scherm opnieuw bij elke sync-ronde
            assign(\.favorites, d.favorites); assign(\.myList, d.myList); assign(\.localWatched, d.watched)
            assign(\.recentChannels, d.recentChannels); assign(\.history, d.history); assign(\.progress, d.progress)
        }
    }

    /// Kijkvoorkeuren van een profiel uit de account zetten; is het profiel actief, dan ook meteen toepassen.
    func setSyncedPreferences(_ id: UUID, _ change: (inout ViewerProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        var p = profiles[i]
        change(&p)
        guard p != profiles[i] else { return }
        profiles[i] = p
        write(profiles, K.profiles)
        if id == activeProfileID { applyPreferences(of: p); applyActiveAccent() }
    }

    /// Kinderslot aan/uit en volwassenengroepen (zonder de groepen per server) uit de account zetten.
    func setSyncedParental(enabled: Bool, autoLockAdult: Bool) {
        guard parental.enabled != enabled || parental.autoLockAdult != autoLockAdult else { return }
        parental.enabled = enabled
        parental.autoLockAdult = autoLockAdult
        write(parental, K.parental)
    }

    // MARK: collecties (build 51, per profiel sinds build 54)

    /// Het profiel waarvan de collecties nu gelden: het actieve, anders het hoofdprofiel.
    var collectionOwner: UUID? { activeProfileID ?? mainProfileID }

    /// Collecties van het actieve profiel zoals de app ze toont: zonder tombstones, op volgorde. Collecties zonder
    /// eigenaar (nog niet gemigreerd, build 51–53) zijn tot de migratie voor iedereen zichtbaar, zodat niets verdwijnt.
    /// Eén keer uitgerekend bij een wijziging (niet bij elke schermverversing; Home en Live TV vragen dit per rij op).
    private(set) var activeCollections: [BingrCollection] = []
    private var activeCollectionsByID: [String: BingrCollection] = [:]

    private func refreshActiveCollections() {
        let list = computeActiveCollections()
        guard list != activeCollections else { return }
        activeCollections = list
        activeCollectionsByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func computeActiveCollections() -> [BingrCollection] {
        let me = collectionOwner
        let mine = collections.filter { $0.owner != nil && $0.owner == me }
        let mineIDs = Set(mine.map(\.id))   // ook tombstones: een eigen verwijdering verbergt de oude versie
        let legacy = collections.filter { $0.owner == nil && !mineIDs.contains($0.id) }
        return (mine + legacy).filter { !$0.deleted }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name }
    }

    func collection(_ id: String) -> BingrCollection? { activeCollectionsByID[id] }

    /// Index van de collectie van het actieve profiel. Bestaat alleen nog een oude (zonder eigenaar), dan wordt
    /// die eerst een eigen kopie van dit profiel.
    private func ownedCollectionIndex(_ id: String) -> Int? {
        let me = collectionOwner
        if let i = collections.firstIndex(where: { $0.id == id && $0.owner != nil && $0.owner == me }) { return i }
        guard let me, let old = collections.first(where: { $0.id == id && $0.owner == nil }) else { return nil }
        var c = old
        c.owner = me
        collections.append(c)
        return collections.count - 1
    }

    /// Nieuw of gewijzigd, voor het actieve profiel (eigen wijziging: `updatedAt` = nu). Elk profiel mag dit,
    /// ook een kinderprofiel: de inhoud komt uit de bibliotheek van dat profiel, die al op leeftijd gefilterd is.
    func upsertCollection(_ c: BingrCollection) {
        var c = c
        c.updatedAt = Date()
        c.owner = collectionOwner
        if let i = ownedCollectionIndex(c.id) {
            collections[i] = c
        } else {
            c.order = (activeCollections.map(\.order).max() ?? -1) + 1
            collections.append(c)
        }
        write(collections, K.collections)
        stateEdited.send((nil, .collections))
    }

    /// Verwijderen = tombstone (zelfde regels als bij profielen), alleen bij het actieve profiel.
    func deleteCollection(_ id: String) {
        guard let i = ownedCollectionIndex(id) else { return }
        let now = Date()
        collections[i].deleted = true
        collections[i].deletedAt = now
        collections[i].updatedAt = now
        collections[i].items = []
        write(collections, K.collections)
        stateEdited.send((nil, .collections))
    }

    /// Nieuwe volgorde (ids van boven naar beneden).
    func reorderCollections(_ ids: [String]) {
        let now = Date()
        for (n, id) in ids.enumerated() {
            guard let i = ownedCollectionIndex(id), collections[i].order != n else { continue }
            collections[i].order = n
            collections[i].updatedAt = now
        }
        write(collections, K.collections)
        stateEdited.send((nil, .collections))
    }

    func toggleInCollection(_ id: String, _ item: CollectionItem) {
        guard var c = collection(id), c.kind == .manual else { return }
        if let i = c.items.firstIndex(of: item) { c.items.remove(at: i) } else { c.items.append(item) }
        upsertCollection(c)
    }

    /// Collecties uit de Bingr-account (StateSync); telt niet als eigen wijziging.
    func replaceCollections(_ list: [BingrCollection]) {
        guard list != collections else { return }
        collections = list
        write(collections, K.collections)
    }

    /// Zonder account (build 54): oude collecties zonder eigenaar naar elk bestaand profiel kopiëren
    /// (zelfde `id` en `updatedAt`), zodat niets verdwijnt. Met een account doet StateSync dit.
    func migrateLegacyCollections() {
        let legacy = collections.filter { $0.owner == nil }
        guard !legacy.isEmpty, !profiles.isEmpty else { return }
        var list = collections.filter { $0.owner != nil }
        for p in profiles {
            for c in legacy where !list.contains(where: { $0.owner == p.id && $0.id == c.id }) {
                var copy = c
                copy.owner = p.id
                list.append(copy)
            }
        }
        collections = list
        write(collections, K.collections)
    }

    // MARK: startscherm per profiel (build 51)

    /// Indeling van het startscherm van het actieve profiel.
    var homeLayout: HomeLayout { (activeProfileID ?? mainProfileID).flatMap { homeLayouts[$0.uuidString] } ?? HomeLayout() }

    func homeLayout(for profile: UUID) -> HomeLayout? { homeLayouts[profile.uuidString] }

    /// Eigen wijziging van het startscherm van het actieve profiel.
    func setHomeLayout(_ l: HomeLayout) {
        guard let id = activeProfileID ?? mainProfileID else { return }
        var l = l
        l.updatedAt = Date()
        homeLayouts[id.uuidString] = l
        write(homeLayouts, K.homeLayout)
        edited(.profile)
    }

    /// Startscherm uit de Bingr-account (StateSync); telt niet als eigen wijziging.
    func setSyncedHomeLayout(_ profile: UUID, _ l: HomeLayout?) {
        guard homeLayouts[profile.uuidString] != l else { return }
        homeLayouts[profile.uuidString] = l
        write(homeLayouts, K.homeLayout)
    }

    // MARK: terugkijk-correctie per zender (build 51)

    /// Minuten (−120…120) die het begintijdstip van terugkijken verschuiven; 0 = geen correctie.
    func catchupOffset(_ playlist: UUID, _ channelID: String) -> Int {
        playlists.first { $0.id == playlist }?.catchupOffsets?[channelID] ?? 0
    }

    func setCatchupOffset(_ playlist: UUID, _ channelID: String, _ minutes: Int) {
        guard var p = playlists.first(where: { $0.id == playlist }) else { return }
        let m = min(max(minutes, -120), 120)
        var offsets = p.catchupOffsets ?? [:]
        guard (offsets[channelID] ?? 0) != m else { return }
        offsets[channelID] = m == 0 ? nil : m
        p.catchupOffsets = offsets
        upsert(p)
    }

    // MARK: favorieten / mijn lijst

    func key(_ playlist: UUID, _ item: String) -> String { "\(playlist.uuidString)|\(item)" }

    func toggleFavorite(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        write(favorites, pk(K.favorites))
        edited(.profile)
    }
    func isFavorite(_ playlist: UUID, _ item: String) -> Bool { favorites.contains(key(playlist, item)) }

    func toggleMyList(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if myList.contains(k) { myList.remove(k) } else { myList.insert(k) }
        write(myList, pk(K.myList))
        edited(.profile)
    }
    func inMyList(_ playlist: UUID, _ item: String) -> Bool { myList.contains(key(playlist, item)) }
    func setMyList(_ playlist: UUID, _ item: String, _ on: Bool) {
        guard inMyList(playlist, item) != on else { return }
        toggleMyList(playlist, item)
    }

    // MARK: voortgang

    func setProgress(_ itemKey: String, _ entry: ProgressEntry) {
        progress[itemKey] = entry
        if progress.count > 300 {   // oudste weggooien
            let keep = progress.sorted { $0.value.updated > $1.value.updated }.prefix(250)
            progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        write(progress, pk(K.progress))
        edited(.progress)
    }
    func clearProgress(_ itemKey: String) { progress[itemKey] = nil; write(progress, pk(K.progress)); edited(.profile) }

    // MARK: lokaal bekeken (als Trakt niet gekoppeld is)

    /// Aflevering als gezien per serie bewaren (seizoen-aflevering), zodat het vinkje en "X GEZIEN" ook kloppen
    /// als de afleveringen pas later geladen worden. Geldt per profiel, ook zonder Trakt.
    static func episodeKey(series: String, season: Int, episode: Int) -> String { "ep:\(series)|\(season)-\(episode)" }
    func setEpisodeWatched(_ e: Episode, _ watched: Bool) {
        let k = Self.episodeKey(series: e.seriesID, season: e.season, episode: e.number)
        if watched { localWatched.insert(e.id); localWatched.insert(k) } else { localWatched.remove(e.id); localWatched.remove(k) }
        write(localWatched, pk(K.watched))
        edited(.profile)
    }
    func localWatchedCount(series id: String) -> Int {
        let prefix = "ep:\(id)|"
        return localWatched.reduce(0) { $0 + ($1.hasPrefix(prefix) ? 1 : 0) }
    }

    func setLocalWatched(_ itemKey: String, _ watched: Bool) {
        if watched { localWatched.insert(itemKey) } else { localWatched.remove(itemKey) }
        write(localWatched, pk(K.watched))
        edited(.profile)
    }

    func pushRecentChannel(_ playlist: UUID, _ channelID: String) {
        let k = key(playlist, channelID)
        recentChannels.removeAll { $0 == k }
        recentChannels.insert(k, at: 0)
        recentChannels = Array(recentChannels.prefix(20))
        write(recentChannels, pk(K.recent))
        edited(.profile)
    }

    // MARK: beheren (hernoemen / verbergen / volgorde / samenvoegen)

    func customization(_ playlist: UUID) -> Customization { customizations[playlist] ?? Customization() }

    func updateCustomization(_ playlist: UUID, _ change: (inout Customization) -> Void) {
        var c = customization(playlist)
        change(&c)
        customizations[playlist] = c
        write(customizations, K.custom)
    }

    // MARK: kinderslot

    func updateParental(_ change: (inout ParentalSettings) -> Void) {
        change(&parental)
        write(parental, K.parental)
        edited(.settings)
    }

    // MARK: kijkgeschiedenis

    func addHistory(_ e: HistoryEntry) {
        history.removeAll { $0.itemID == e.itemID && $0.playlistID == e.playlistID }
        history.insert(e, at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }   // zelfde maximum als in de account
        write(history, pk(K.history))
        edited(.profile)
    }
    func removeHistory(_ e: HistoryEntry) {
        history.removeAll { $0.id == e.id }
        write(history, pk(K.history))
        edited(.profile)
    }
    func clearHistory(playlist: UUID?) {
        history.removeAll { $0.playlistID == playlist }
        write(history, pk(K.history))
        edited(.profile)
    }
    /// Kijkgeschiedenis van het actieve profiel (en de server).
    func history(for playlist: UUID?) -> [HistoryEntry] {
        history.filter { $0.playlistID == playlist && belongsToActive($0.profileID) }
    }
    /// Hoort een opgeslagen item bij het actieve profiel? Oude items zonder profiel horen bij het hoofdaccount.
    func belongsToActive(_ profile: UUID?) -> Bool {
        guard let active = activeProfileID else { return true }
        if let profile { return profile == active }
        return active == mainProfileID
    }

    // MARK: herinneringen

    func addReminder(_ r: ProgramReminder) {
        reminders.removeAll { $0.id == r.id }
        reminders.append(r)
        write(reminders, K.reminders)
        edited(.reminders)
    }
    func removeReminder(_ id: String) {
        reminders.removeAll { $0.id == id }
        write(reminders, K.reminders)
        edited(.reminders)
    }

    /// Herinneringen uit de Bingr-account in één keer zetten (StateSync); telt niet als eigen wijziging.
    func replaceReminders(_ list: [ProgramReminder]) {
        guard list != reminders else { return }
        reminders = list
        write(reminders, K.reminders)
    }
    func hasReminder(_ id: String) -> Bool { reminders.contains { $0.id == id } }
}

/// Eén keer kijken: film, aflevering of zender.
struct HistoryEntry: Codable, Hashable, Identifiable {
    var id: String { "\(playlistID?.uuidString ?? "-")|\(itemID)" }
    var itemID: String
    var playlistID: UUID?
    var title: String
    var subtitle: String?
    var artwork: URL?
    var type: MediaType
    var channelID: String?
    var date: Date
    /// Van welk kijkprofiel (nil = van vóór de profielen → hoort bij het hoofdaccount)
    var profileID: UUID? = nil
}

/// Aanpassingen van de gebruiker op een afspeellijst (gesynchroniseerd via iCloud).
struct Customization: Codable, Hashable {
    var renamed: [String: String] = [:]        // item-id of "group:<naam>" → nieuwe naam
    var hidden: Set<String> = []               // item-id of "group:<naam>"
    var groupOrder: [String] = []              // groepen in eigen volgorde (live)
    var channelOrder: [String: [String]] = [:] // groep → kanaal-id's
    var merged: [String: String] = [:]         // groep → doelgroep

    static func groupKey(_ g: String) -> String { "group:\(g)" }
}

struct ParentalSettings: Codable, Hashable {
    var enabled = false
    var lockedGroups: Set<String> = []          // "<playlistID>|<groep>"
    var autoLockAdult = true                    // groepen met "adult", "xxx", "18+" automatisch op slot
}

struct ProgramReminder: Codable, Hashable, Identifiable {
    var id: String               // channelID + start
    var playlistID: UUID
    var channelID: String
    var channelName: String
    var title: String
    var start: Date
}
