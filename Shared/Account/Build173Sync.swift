import Foundation

// Build 173 (versie 1.0.7): Trakt synchroniseert weer betrouwbaar, OpenSubtitles blijft ingelogd.
// Pure logica (zonder netwerk of UI), getest in tools/selftest/main.swift.
//
// Oorzaken in 172:
// - Trakt-tokens zijn eenmalig bij verversen (elke verversing geeft een nieuw refresh-token, en het access-token is bij
//   Trakt nog maar 24 uur geldig). Kwam er via de account-sync een `connections` binnen met een **ouder** Trakt-token
//   (bijv. omdat een ander apparaat alleen OpenSubtitles opnieuw koppelde en zijn oude Trakt-kopie meestuurde), dan
//   werd het nieuwere token hier overschreven door een al gebruikt refresh-token: elke verversing daarna faalde.
// - Elke mislukte aanroep (netwerk, 429, 5xx, een scrobble) zette een foutmelding die bleef staan tot een geslaagde
//   volledige sync, ook als er niets blijvend mis was.
// - OpenSubtitles: het token verloopt na ongeveer 24 uur; een 401 wiste de sessie (en via de account ook op je andere
//   apparaten). Nu: stil opnieuw inloggen met de bewaarde gegevens.

enum TraktHealth173 {
    enum Failure: Equatable {
        /// Netwerk, 408, 420, 429, 5xx: later vanzelf opnieuw, geen melding
        case transient
        /// Het token (of de koppeling) is niet meer geldig: opnieuw inloggen bij Trakt
        case reauth
        /// 423: het Trakt-account is vergrendeld
        case locked
    }

    /// Soort fout bij een gewone aanroep (nil = netwerkfout, geen antwoord). Een 401 komt hier pas als verversen
    /// en opnieuw proberen ook al niet hielp.
    static func classify(status: Int?) -> Failure {
        guard let s = status else { return .transient }
        switch s {
        case 401, 403: return .reauth
        case 423: return .locked
        default: return .transient
        }
    }

    /// Uitkomst van een mislukte tokenverversing over alle pogingen (nil = netwerkfout). Alleen als Trakt het
    /// refresh-token echt weigert (400/401 `invalid_grant`, 403) is opnieuw inloggen nodig; anders later opnieuw.
    static func refreshFailure(statuses: [Int?]) -> Failure {
        guard !statuses.isEmpty else { return .transient }
        for s in statuses {
            guard let s, [400, 401, 403].contains(s) else { return .transient }
        }
        return .reauth
    }

    /// De rode waarschuwing tonen? Alleen bij een blijvende fout: opnieuw inloggen, een vergrendeld account, of een
    /// tijdelijke fout die al minstens 24 uur aanhoudt (zonder enige geslaagde sync daartussen).
    static func showWarning(_ kind: Failure?, failingSince: Date?, now: Date = Date()) -> Bool {
        switch kind {
        case nil: return false
        case .reauth?, .locked?: return true
        case .transient?:
            guard let f = failingSince else { return false }
            return now.timeIntervalSince(f) >= 24 * 3600
        }
    }

    /// Een Trakt-token uit het account (`connections`) overnemen? Alleen als hier geen token is, of als dat van het
    /// account minstens zo lang geldig is. Een ouder token zou een al gebruikt refresh-token terugzetten.
    static func adoptRemote(local: (access: String, expiresAt: Date)?, remote: (access: String, expiresAt: Date)) -> Bool {
        guard let l = local else { return true }
        if l.access == remote.access { return true }
        return remote.expiresAt >= l.expiresAt
    }
}

enum OSSession173 {
    /// Het token van de OpenSubtitles-API is ongeveer 24 uur geldig; na 23 uur vooraf stil vernieuwen.
    static let maxTokenAge: Double = 23 * 3600

    /// Vóór een aanroep met het token (downloaden, account-info) eerst stil opnieuw inloggen?
    static func shouldRenew(loggedInAt: Double?, now: Double, hasPassword: Bool) -> Bool {
        guard hasPassword else { return false }
        guard let t = loggedInAt else { return true }
        return now - t >= maxTokenAge || now < t - 300
    }

    enum OnResponse: Equatable {
        /// Niets met de sessie doen (ook bij netwerkfouten, 429 en 5xx)
        case keep
        /// Token verlopen: stil opnieuw inloggen met de bewaarde gegevens
        case relogin
        /// Token verlopen en geen bewaard wachtwoord: vragen om opnieuw in te loggen, maar niet uitloggen
        case expired
    }

    /// Wat te doen met een antwoord (nil = netwerkfout). Alleen een 401 bij een aanroep die echt het token gebruikt.
    static func onResponse(status: Int?, authenticated: Bool, hasPassword: Bool) -> OnResponse {
        guard authenticated, status == 401 else { return .keep }
        return hasPassword ? .relogin : .expired
    }

    enum LoginResult: Equatable { case ok, badCredentials, transient }

    /// Uitkomst van (stil) inloggen. Alleen 400/401 = foute gegevens (dan uitloggen met een melding); 403 (app-sleutel),
    /// 429, 5xx en netwerkfouten zijn tijdelijk.
    static func loginResult(status: Int?) -> LoginResult {
        guard let s = status else { return .transient }
        if (200..<300).contains(s) { return .ok }
        if s == 400 || s == 401 { return .badCredentials }
        return .transient
    }
}
