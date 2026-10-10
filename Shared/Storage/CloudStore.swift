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

    private let kv = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var observer: NSObjectProtocol?

    private enum K {
        static let playlists = "playlists.v1", favorites = "favorites.v1", myList = "mylist.v1",
                   progress = "progress.v1", watched = "watched.v1", recent = "recent.v1",
                   custom = "custom.v1", parental = "parental.v1", reminders = "reminders.v1",
                   photos = "photos.v1"
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
        favorites = decode(Set<String>.self, K.favorites) ?? []
        myList = decode(Set<String>.self, K.myList) ?? []
        localWatched = decode(Set<String>.self, K.watched) ?? []
        recentChannels = decode([String].self, K.recent) ?? []
        customizations = decode([UUID: Customization].self, K.custom) ?? [:]
        parental = decode(ParentalSettings.self, K.parental) ?? ParentalSettings()
        photos = decode([UUID: Data].self, K.photos) ?? [:]
        reminders = (decode([ProgramReminder].self, K.reminders) ?? []).filter { $0.start > Date().addingTimeInterval(-3600) }
        let remote = decode([String: ProgressEntry].self, K.progress) ?? [:]
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
    }

    func setPhoto(_ data: Data?, for playlist: UUID) {
        photos[playlist] = data
        write(photos, K.photos)
    }

    func delete(_ p: PlaylistSource) {
        playlists.removeAll { $0.id == p.id }
        if photos[p.id] != nil { setPhoto(nil, for: p.id) }
        Keychain.set(nil, for: p.passwordKey)
        write(playlists, K.playlists)
    }

    // MARK: favorieten / mijn lijst

    func key(_ playlist: UUID, _ item: String) -> String { "\(playlist.uuidString)|\(item)" }

    func toggleFavorite(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        write(favorites, K.favorites)
    }
    func isFavorite(_ playlist: UUID, _ item: String) -> Bool { favorites.contains(key(playlist, item)) }

    func toggleMyList(_ playlist: UUID, _ item: String) {
        let k = key(playlist, item)
        if myList.contains(k) { myList.remove(k) } else { myList.insert(k) }
        write(myList, K.myList)
    }
    func inMyList(_ playlist: UUID, _ item: String) -> Bool { myList.contains(key(playlist, item)) }

    // MARK: voortgang

    func setProgress(_ itemKey: String, _ entry: ProgressEntry) {
        progress[itemKey] = entry
        if progress.count > 300 {   // oudste weggooien
            let keep = progress.sorted { $0.value.updated > $1.value.updated }.prefix(250)
            progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        write(progress, K.progress)
    }
    func clearProgress(_ itemKey: String) { progress[itemKey] = nil; write(progress, K.progress) }

    // MARK: lokaal bekeken (als Trakt niet gekoppeld is)

    func setLocalWatched(_ itemKey: String, _ watched: Bool) {
        if watched { localWatched.insert(itemKey) } else { localWatched.remove(itemKey) }
        write(localWatched, K.watched)
    }

    func pushRecentChannel(_ playlist: UUID, _ channelID: String) {
        let k = key(playlist, channelID)
        recentChannels.removeAll { $0 == k }
        recentChannels.insert(k, at: 0)
        recentChannels = Array(recentChannels.prefix(20))
        write(recentChannels, K.recent)
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
