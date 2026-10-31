import Foundation

// Build 158: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
//
// Oorzaak van de crash bij het openen op Apple TV (build 157, log uit de tvOS 27-simulator): op tvOS mag UserDefaults
// samen hooguit 1 MB zijn, en dat wordt afgedwongen ("Attempting to store >= 1048576 bytes of data in CFPreferences/
// NSUserDefaults on this platform is invalid"). `account.stateMeta.v1` was 668 KB (inhoudssleutels van build 154),
// `photos.v1` 235 KB, en samen met de rest ging de app over de grens.
//
// - `DefaultsPolicy158`: welke sleutels in een bestand horen, en de grenzen voor wat nog wel in UserDefaults mag
//   (900 KB samen, 100 KB per sleutel).
// - `FileKV158`: één bestand per sleutel (binaire plist), met een cache in het geheugen.
// - `BigDefaults`: zelfde aanroepen als UserDefaults; grote gegevens in bestanden, kleine in UserDefaults. Op tvOS in
//   Caches (andere blijvende opslag is er niet: wist het systeem die, dan komt alles opnieuw uit het account of wordt
//   het opnieuw opgebouwd), op iOS en macOS in Application Support. `migrate()` zet bij de start bestaande grote
//   sleutels uit UserDefaults over naar bestanden en haalt ze uit UserDefaults.

enum DefaultsPolicy158 {
    /// Hooguit zoveel samen in UserDefaults (de grens van tvOS is 1 MB)
    static let maxTotal = 900 * 1024
    /// Hooguit zoveel per sleutel in UserDefaults; groter gaat naar een bestand
    static let maxPerKey = 100 * 1024

    /// Sleutels (en hun varianten per profiel/server/land: `<basis>.<…>`) die altijd in een bestand staan.
    static let fileBases = ["account.stateMeta.v1", "photos.v1", "categories.v1", "categories.account.v140", "watched.v1",
                            "history.v1", "progress.v1", "discover", "account.sourceExtras.v1", "custom.v1"]

    static func isFileKey(_ key: String) -> Bool {
        fileBases.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    /// Mag deze waarde (grootte `size`) in UserDefaults, als de andere sleutels samen `others` bytes zijn?
    static func fitsInDefaults(size: Int, others: Int) -> Bool {
        size <= maxPerKey && others + size <= maxTotal
    }

    /// Geschatte grootte van een waarde in UserDefaults (binaire plist; onbekend type telt als te groot).
    static func size(of value: Any) -> Int {
        switch value {
        case let d as Data: return d.count
        case let s as String: return s.utf8.count
        case is NSNumber, is Date: return 16
        default:
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let d = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return Int.max }
            return d.count
        }
    }

    /// Bestandsnaam voor een sleutel: alleen letters, cijfers, punt, streepje en liggend streepje; de rest als %XX.
    static func fileName(_ key: String) -> String {
        var out = ""
        for b in key.utf8 {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || c == "." || c == "-" || c == "_" {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        // altijd met "k" ervoor: ook "", "." en ".." worden zo een gewone bestandsnaam
        return "k" + out + ".plist"
    }

    static func key(fromFileName name: String) -> String? {
        guard name.hasPrefix("k"), name.hasSuffix(".plist") else { return nil }
        return String(name.dropFirst().dropLast(6)).removingPercentEncoding
    }
}

/// Eén bestand per sleutel (binaire plist van de waarde), met een cache in het geheugen. Draadveilig.
final class FileKV158: @unchecked Sendable {
    let dir: URL
    private let lock = NSLock()
    private var cache: [String: Any] = [:]
    private var missing = Set<String>()
    private var listed: Set<String>?

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL { dir.appendingPathComponent(DefaultsPolicy158.fileName(key)) }

    func object(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        if let v = cache[key] { return v }
        if missing.contains(key) { return nil }
        guard let d = try? Data(contentsOf: url(key)), !d.isEmpty,
              let v = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) else {
            missing.insert(key)
            return nil
        }
        cache[key] = v
        return v
    }

    /// `false` als de waarde niet als plist te bewaren is of het schrijven mislukte.
    @discardableResult
    func set(_ value: Any?, _ key: String) -> Bool {
        guard let value else { remove(key); return true }
        guard let d = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            #if os(macOS)
            try d.write(to: url(key), options: .atomic)
            #else
            try d.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
        } catch {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? d.write(to: url(key), options: .atomic)) != nil else { return false }
        }
        cache[key] = value
        missing.remove(key)
        listed?.insert(key)
        return true
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(key))
        cache[key] = nil
        missing.insert(key)
        listed?.remove(key)
    }

    func keys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let l = listed { return l }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let l = Set(names.compactMap(DefaultsPolicy158.key(fromFileName:)))
        listed = l
        return l
    }

    func removeAll() {
        for k in keys() { remove(k) }
    }
}

/// UserDefaults met grote gegevens in bestanden (zie boven). Zelfde aanroepen als UserDefaults voor wat de app gebruikt.
final class BigDefaults: @unchecked Sendable {
    static let shared = BigDefaults(defaults: .standard, dir: BigDefaults.defaultDir)

    /// tvOS: Caches (de enige blijvende opslag); iOS en macOS: Application Support
    static var defaultDir: URL {
        let fm = FileManager.default
        #if os(tvOS)
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #else
        var base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        if (try? fm.createDirectory(at: base, withIntermediateDirectories: true)) == nil {
            base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        }
        #endif
        return base.appendingPathComponent("BingrDefaults", isDirectory: true)
    }

    let defaults: UserDefaults
    let files: FileKV158
    /// Naam van het eigen domein in UserDefaults (nil = de bundle-id)
    let domain: String?
    private let lock = NSLock()
    private var migrated = false

    init(defaults: UserDefaults, dir: URL, domain: String? = nil) {
        self.defaults = defaults
        self.files = FileKV158(dir: dir)
        self.domain = domain
    }

    // MARK: lezen

    func object(forKey key: String) -> Any? {
        if let v = files.object(key) { return v }
        guard let v = defaults.object(forKey: key) else { return nil }
        // nog in UserDefaults (bijv. vóór de migratie geschreven): meteen naar een bestand als het daar hoort
        if DefaultsPolicy158.isFileKey(key), files.set(v, key) { defaults.removeObject(forKey: key) }
        return v
    }

    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    func dictionaryRepresentation() -> [String: Any] {
        var all = defaults.dictionaryRepresentation()
        for k in files.keys() { if let v = files.object(k) { all[k] = v } }
        return all
    }

    // MARK: schrijven (met de grens)

    func set(_ value: Any?, forKey key: String) {
        guard let value else { removeObject(forKey: key); return }
        if DefaultsPolicy158.isFileKey(key) {
            if files.set(value, key) { defaults.removeObject(forKey: key); return }
            // schrijven mislukt: alleen in UserDefaults als het binnen de grens past, anders niet bewaren (geen crash)
        } else {
            files.remove(key)
        }
        let size = DefaultsPolicy158.size(of: value)
        let others = defaultsBytes(excluding: key)
        if DefaultsPolicy158.fitsInDefaults(size: size, others: others) {
            defaults.set(value, forKey: key)
        } else if files.set(value, key) {
            defaults.removeObject(forKey: key)
        }
    }

    func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }

    func removeObject(forKey key: String) {
        files.remove(key)
        defaults.removeObject(forKey: key)
    }

    /// Grootte van wat deze app nu in UserDefaults heeft (alleen het eigen domein)
    func defaultsBytes(excluding key: String? = nil) -> Int {
        var total = 0
        for (k, v) in ownDomain() where k != key {
            let s = DefaultsPolicy158.size(of: v)
            total += s == Int.max ? DefaultsPolicy158.maxPerKey : s
        }
        return total
    }

    private func ownDomain() -> [String: Any] {
        if let id = domain ?? Bundle.main.bundleIdentifier, let d = defaults.persistentDomain(forName: id) { return d }
        return [:]
    }

    // MARK: migratie bij de start

    /// Bestaande grote sleutels uit UserDefaults naar bestanden (eenmalig per start, zo vroeg mogelijk): eerst alle
    /// sleutels die in een bestand horen, daarna elke sleutel boven 100 KB, en tot slot de grootste tot UserDefaults
    /// onder 900 KB zit. Een sleutel gaat pas uit UserDefaults als het bestand geschreven is. Geeft de verplaatste sleutels.
    @discardableResult
    func migrate() -> [String] {
        lock.lock()
        guard !migrated else { lock.unlock(); return [] }
        migrated = true
        lock.unlock()
        var moved: [String] = []
        var sizes: [(key: String, value: Any, size: Int)] = []
        for (k, v) in ownDomain() {
            let s = DefaultsPolicy158.size(of: v)
            if DefaultsPolicy158.isFileKey(k) || s > DefaultsPolicy158.maxPerKey {
                if files.set(v, k) { defaults.removeObject(forKey: k); moved.append(k) }
            } else {
                sizes.append((k, v, s))
            }
        }
        var total = sizes.reduce(0) { $0 + $1.size }
        for x in sizes.sorted(by: { $0.size > $1.size }) where total > DefaultsPolicy158.maxTotal {
            // alleen gegevens (Data) verplaatsen: kleine instellingen leest de app soms rechtstreeks uit UserDefaults
            guard x.value is Data, files.set(x.value, x.key) else { continue }
            defaults.removeObject(forKey: x.key)
            moved.append(x.key)
            total -= x.size
        }
        return moved.sorted()
    }
}
