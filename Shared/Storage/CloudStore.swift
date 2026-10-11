import Foundation
import Combine

struct ProgressEntry: Codable, Hashable {
    var fraction: Double
    var position: Double
    var updated: Date
    var title: String
    var artwork: URL?
    var playlistID: UUID?
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
    /// Het profiel dat nu open is (gezet door PlaylistService)
    var activePlaylistID: UUID?

    // MARK: profielen ("Wie kijkt er?")
    //
    // Eén hoofdaccount met de server(s), Trakt en OpenSubtitles; daaronder kijkprofielen.
    // Per profiel apart: Mijn lijst, favorieten, kijkvoortgang/Verder kijken, bekeken, recente zenders,
    // kijkgeschiedenis, avatar/foto en leeftijdsgrens. Gedeeld: server(s), aanpassingen, Trakt, OpenSubtitles.

    @Published private(set) var profiles: [ViewerProfile] = []
    /// De server die alle profielen gebruiken
    @Published private(set) var mainSourceID: UUID?
    /// Gekozen profiel op dít apparaat (per Apple TV-gebruiker apart)
    @Published private(set) var activeProfileID: UUID? = UserDefaults.standard.string(forKey: "activeProfileID").flatMap(UUID.init)

    var activeProfile: ViewerProfile? { profiles.first { $0.id == activeProfileID } }

    /// Het hoofdaccount: alleen dat profiel stelt de server, Trakt, OpenSubtitles, kinderslot,
    /// categorieën en profielen in. Standaard het eerste profiel.
    @Published private(set) var mainProfileIDStored: UUID?
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
        favorites = scoped(Set<String>.self, K.favorites) ?? []
        myList = scoped(Set<String>.self, K.myList) ?? []
        localWatched = scoped(Set<String>.self, K.watched) ?? []
        recentChannels = scoped([String].self, K.recent) ?? []
        history = scoped([HistoryEntry].self, K.history) ?? []
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
        loadProfileData()
        progress = scoped([String: ProgressEntry].self, K.progress) ?? [:]
    }

    /// Kijkvoorkeuren van dit profiel actief maken (automatische ondertitels, talen).
    private func applyPreferences(of p: ViewerProfile) {
        let d = UserDefaults.standard
        let fresh = !isMain(p)   // nieuw/ander profiel zonder eigen keuze → standaardwaarden, niet die van een ander
        if let v = p.autoSubtitles { d.set(v, forKey: "autoSubtitles") } else if fresh { d.set(false, forKey: "autoSubtitles") }
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
    }

    func deleteProfile(_ p: ViewerProfile) {
        guard !isMain(p) else { return }   // het hoofdaccount blijft altijd bestaan
        profiles.removeAll { $0.id == p.id }
        write(profiles, K.profiles)
        setPhoto(nil, for: p.id)
        if activeProfileID == p.id { activeProfileID = nil; UserDefaults.standard.removeObject(forKey: "activeProfileID") }
    }

    func setMainSource(_ id: UUID) {
        mainSourceID = id
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
                   profiles = "profiles.v1", mainSource = "mainsource.v1", mainProfile = "mainprofile.v1"
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
        lastSync = Date()
    }

    private func decode<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = data(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func load(mergeProgress: Bool) {
        playlists = decode([PlaylistSource].self, K.playlists) ?? []
        profiles = decode([ViewerProfile].self, K.profiles) ?? []
        mainSourceID = decode(UUID.self, K.mainSource)
        mainProfileIDStored = decode(UUID.self, K.mainProfile)
        migrateToProfiles()
        loadProfileData()
        customizations = decode([UUID: Customization].self, K.custom) ?? [:]
        parental = decode(ParentalSettings.self, K.parental) ?? ParentalSettings()
        photos = decode([UUID: Data].self, K.photos) ?? [:]
        // wachtwoorden/tokens ook via iCloud KV delen (Apple TV krijgt ze anders niet) — op de achtergrond,
        // sleutelhanger-acties zijn traag en blokkeerden het wisselen van profiel
        let secretKeys = playlists.flatMap { [$0.passwordKey, "playlist.\($0.id.uuidString).session"] }
            + ["trakt.tokens", "opensubtitles.session", "parental.pin"]
            + profiles.map { "profile.\($0.id.uuidString).pin" }
            + Secrets.Key.allCases.map { "apikey.\($0.rawValue)" }
        DispatchQueue.global(qos: .utility).async {
            Keychain.syncFromCloud()
            Keychain.pushToCloud(keys: secretKeys)
            DispatchQueue.main.async { Secrets.reload() }
        }
        reminders = (decode([ProgramReminder].self, K.reminders) ?? []).filter { $0.start > Date().addingTimeInterval(-3600) }
        let remote = scoped([String: ProgressEntry].self, K.progress) ?? [:]
        if mergeProgress {
            var merged = progress
            for (k, v) in remote where (merged[k]?.updated ?? .distantPast) < v.updated { merged[k] = v }
            progress = merged
        } else {
            progress = remote
        }
        lastSync = Date()
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

    func setPhoto(_ data: Data?, for playlist: UUID) {
        photos[playlist] = data
        write(photos, K.photos)
    }

    func delete(_ p: PlaylistSource) {
        playlists.removeAll { $0.id == p.id }
        if mainSourceID == p.id { mainSourceID = playlists.first?.id; write(mainSourceID, K.mainSource) }
        customizations[p.id] = nil; write(customizations, K.custom)
        if photos[p.id] != nil { setPhoto(nil, for: p.id) }
        Keychain.set(nil, for: p.passwordKey)
        write(playlists, K.playlists)
    }

    // MARK: favorieten / mijn lijst

    func key(_ playlist: UUID, _ item: String) -> String { "\(playlist.uuidString)|\(item)" }

    func toggleFavorite(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        write(favorites, pk(K.favorites))
    }
    func isFavorite(_ playlist: UUID, _ item: String) -> Bool { favorites.contains(key(playlist, item)) }

    func toggleMyList(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if myList.contains(k) { myList.remove(k) } else { myList.insert(k) }
        write(myList, pk(K.myList))
    }
    func inMyList(_ playlist: UUID, _ item: String) -> Bool { myList.contains(key(playlist, item)) }

    // MARK: voortgang

    func setProgress(_ itemKey: String, _ entry: ProgressEntry) {
        progress[itemKey] = entry
        if progress.count > 300 {   // oudste weggooien
            let keep = progress.sorted { $0.value.updated > $1.value.updated }.prefix(250)
            progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        write(progress, pk(K.progress))
    }
    func clearProgress(_ itemKey: String) { progress[itemKey] = nil; write(progress, pk(K.progress)) }

    // MARK: lokaal bekeken (als Trakt niet gekoppeld is)

    func setLocalWatched(_ itemKey: String, _ watched: Bool) {
        if watched { localWatched.insert(itemKey) } else { localWatched.remove(itemKey) }
        write(localWatched, pk(K.watched))
    }

    func pushRecentChannel(_ playlist: UUID, _ channelID: String) {
        let k = key(playlist, channelID)
        recentChannels.removeAll { $0 == k }
        recentChannels.insert(k, at: 0)
        recentChannels = Array(recentChannels.prefix(20))
        write(recentChannels, pk(K.recent))
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
    }

    // MARK: kijkgeschiedenis

    func addHistory(_ e: HistoryEntry) {
        history.removeAll { $0.itemID == e.itemID && $0.playlistID == e.playlistID }
        history.insert(e, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        write(history, pk(K.history))
    }
    func removeHistory(_ e: HistoryEntry) {
        history.removeAll { $0.id == e.id }
        write(history, pk(K.history))
    }
    func clearHistory(playlist: UUID?) {
        history.removeAll { $0.playlistID == playlist }
        write(history, pk(K.history))
    }
    func history(for playlist: UUID?) -> [HistoryEntry] { history.filter { $0.playlistID == playlist } }

    // MARK: herinneringen

    func addReminder(_ r: ProgramReminder) {
        reminders.removeAll { $0.id == r.id }
        reminders.append(r)
        write(reminders, K.reminders)
    }
    func removeReminder(_ id: String) {
        reminders.removeAll { $0.id == id }
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
