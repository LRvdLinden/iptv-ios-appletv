import Foundation

// Build 157: pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).
// Contract: docs/ACCOUNT.md, "Build 157: Gratis en Lifetime aangepast".
//
// - `PlanDefaults157`: standaardlimieten (Gratis 1 scherm, 2 apparaten, 1 server; Lifetime tot 3, 15, onbeperkt).
// - `FeatureFlags157`: `features` uit `entitlements` lezen. Een vlag die ontbreekt volgt het abonnement: een oudere
//   server zonder `continue_watching` / `kids_profiles` / `opensubtitles` betekent bij Gratis dus "op slot".
// - `ContinueWatching157`, `KidsProfiles157`, `OpenSubtitles157`: wat de apps bij Gratis wel en niet doen.

// MARK: - Standaardlimieten

enum PlanDefaults157 {
    struct Limits: Equatable, Sendable {
        var streams: Int?
        var devices: Int?
        /// nil = onbeperkt
        var servers: Int?
    }

    static let free = Limits(streams: 1, devices: 2, servers: 1)
    static let lifetime = Limits(streams: 3, devices: 15, servers: nil)

    static func standard(lifetime isLifetime: Bool) -> Limits { isLifetime ? lifetime : free }

    /// `plans` uit `entitlements` (build 128), aangevuld met de standaard; ontbreekt het hele object (oudere
    /// server), dan de standaard (Gratis 1/2/1).
    static func plans(_ raw: Any?) -> [String: Limits] {
        var out = ["free": free, "lifetime": lifetime]
        guard let pj = raw as? [String: Any] else { return out }
        for (k, v) in pj {
            guard let d = v as? [String: Any] else { continue }
            var lim = k == "free" ? free : lifetime
            if let x = int(d["streams"]) { lim.streams = x }
            if let x = int(d["devices"]) { lim.devices = x }
            if d.keys.contains("servers") { lim.servers = int(d["servers"]) }   // null = onbeperkt
            out[k] = lim
        }
        return out
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

// MARK: - Feature-vlaggen

struct FeatureFlags157: Equatable, Sendable {
    var stats: Bool
    var nowWatching: Bool
    var trakt: Bool
    var multiServer: Bool
    var themes: Bool
    /// build 157
    var continueWatching: Bool
    var kidsProfiles: Bool
    var openSubtitles: Bool

    /// Alle sleutels van `features` (contract).
    static let keys = ["stats", "now_watching", "trakt", "multi_server", "themes",
                       "continue_watching", "kids_profiles", "opensubtitles"]

    /// Alles aan (Lifetime) of alles uit (Gratis).
    init(all value: Bool) {
        stats = value; nowWatching = value; trakt = value; multiServer = value; themes = value
        continueWatching = value; kidsProfiles = value; openSubtitles = value
    }

    /// `features` uit het antwoord; een ontbrekende of onleesbare vlag volgt het abonnement (`lifetime`).
    init(json: Any?, lifetime: Bool) {
        let f = json as? [String: Any] ?? [:]
        func flag(_ k: String) -> Bool {
            if let b = f[k] as? Bool { return b }
            if let n = f[k] as? NSNumber { return n.boolValue }
            return lifetime
        }
        stats = flag("stats"); nowWatching = flag("now_watching"); trakt = flag("trakt")
        multiServer = flag("multi_server"); themes = flag("themes")
        continueWatching = flag("continue_watching"); kidsProfiles = flag("kids_profiles")
        openSubtitles = flag("opensubtitles")
    }

    /// Het abonnement uit een antwoord (`entitlements`, `config` of `heartbeat`, eventueel genest onder
    /// `entitlements`): `true` = Lifetime, `false` = Gratis, nil = geen abonnement in het antwoord.
    static func isLifetime(_ raw: [String: Any]) -> Bool? {
        let j = (raw["entitlements"] as? [String: Any]) ?? raw
        guard let p = (j["plan"] as? String)?.lowercased() else { return nil }
        return p != "free"
    }

    /// Vlaggen uit een volledig antwoord; nil = geen abonnement in het antwoord.
    static func parse(_ raw: [String: Any]) -> FeatureFlags157? {
        guard let lifetime = isLifetime(raw) else { return nil }
        let j = (raw["entitlements"] as? [String: Any]) ?? raw
        return FeatureFlags157(json: j["features"], lifetime: lifetime)
    }

    /// Eén 403 `feature_locked` van de server: welke vlag gaat (tijdelijk) uit.
    mutating func lock(_ feature: String?) {
        switch feature {
        case "stats": stats = false
        case "now_watching", "watch_log", "list_streams": nowWatching = false
        case "trakt": trakt = false
        case "multi_server", "servers": multiServer = false
        case "themes": themes = false
        case "continue_watching": continueWatching = false
        case "kids_profiles": kidsProfiles = false
        case "opensubtitles": openSubtitles = false
        default: break
        }
    }
}

// MARK: - Verder kijken

enum ContinueWatching157 {
    enum Row: Equatable {
        /// niets om te tonen
        case hidden
        /// rij met een slotje en de vergelijking (Gratis)
        case locked
        /// de gewone rij
        case items
    }

    /// De rij Verder kijken (Home en Mijn Bingr).
    static func row(allowed: Bool, hasItems: Bool) -> Row {
        guard hasItems else { return .hidden }
        return allowed ? .items : .locked
    }

    /// De voortgang wordt altijd bewaard en gesynct (ook bij Gratis), zodat hij er na het upgraden meteen is.
    static func saveProgress(allowed: Bool) -> Bool { true }

    /// "Hervatten vanaf …" in de speler en op de detailpagina blijft altijd werken.
    static func resume(allowed: Bool) -> Bool { true }
}

// MARK: - Kinderprofielen

enum KidsProfiles157 {
    enum Edit: Equatable {
        /// Lifetime: alles aan te passen
        case editable
        /// Gratis, geen kinderprofiel: de schakelaar "Kinderprofiel" toont het slotje
        case lockedToCreate
        /// Gratis, bestaand kinderprofiel: blijft een kinderprofiel, instellingen alleen te lezen
        case readOnly
    }

    static func edit(allowed: Bool, isKids: Bool) -> Edit {
        if allowed { return .editable }
        return isKids ? .readOnly : .lockedToCreate
    }

    /// Wat er bewaard wordt: bij Gratis blijft een bestaand kinderprofiel een kinderprofiel en wordt er geen nieuw
    /// kinderprofiel gemaakt, wat de schakelaar ook zegt.
    static func savedKids(requested: Bool, allowed: Bool, wasKids: Bool) -> Bool {
        allowed ? requested : wasKids
    }

    /// Leeftijdsgrens bij het bewaren: bij Gratis blijft die van een bestaand kinderprofiel ongewijzigd.
    static func savedAgeLimit(requested: Int?, allowed: Bool, wasKids: Bool, previous: Int?) -> Int? {
        (!allowed && wasKids) ? previous : requested
    }

    /// Filteren hangt nooit van het abonnement af (veiligheid): een kinderprofiel blijft altijd gefilterd.
    static func filtered(isKids: Bool, allowed: Bool) -> Bool { isKids }

    /// Een kinderprofiel verwijderen mag altijd (achter de ouderpoort).
    static func canDelete(allowed: Bool) -> Bool { true }
}

// MARK: - OpenSubtitles

enum OpenSubtitles157 {
    /// Zoeken en downloaden via OpenSubtitles (ook de automatische ondertitels): alleen met Lifetime en een koppeling.
    static func usable(allowed: Bool, signedIn: Bool) -> Bool { allowed && signedIn }

    /// Een bestaande koppeling blijft bewaard (`connections.opensubtitles`), ook bij Gratis.
    static func keepConnection(allowed: Bool) -> Bool { true }

    /// Ondertitels uit de stream zelf blijven gratis.
    static func streamSubtitles(allowed: Bool) -> Bool { true }
}
