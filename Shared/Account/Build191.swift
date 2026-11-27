import Foundation

// Build 191 (versie 1.1.2): pure logica (alleen Foundation), ook los gebouwd in de zelftest van CI (tools/selftest/main.swift).

/// "Pincode vergeten?": met het wachtwoord van het Bingr-account de pincode van een profiel weghalen.
enum PINReset191 {
    /// Welk profiel de reset raakt: het profiel van het pincodescherm, anders het hoofdprofiel.
    static func target<ID: Equatable>(profile: ID?, main: ID?) -> ID? { profile ?? main }

    /// De reset is er alleen met een ingelogd Bingr-account (en een e-mailadres om mee in te loggen).
    static func available(signedIn: Bool, email: String?) -> Bool {
        guard signedIn, let e = email?.trimmingCharacters(in: .whitespaces) else { return false }
        return !e.isEmpty
    }

    /// Het wachtwoord mag niet leeg zijn (niet getrimd: spaties kunnen bij een wachtwoord horen).
    static func canSubmit(password: String, busy: Bool) -> Bool { !password.isEmpty && !busy }

    /// Gevolgen gelijk aan "Pincode uitzetten": het hoofdprofiel zet ook het kinderslot uit.
    static func turnsOffParentalLock(isMain: Bool) -> Bool { isMain }
}

/// Detailpagina: welke tabbladen er zijn (alleen die met inhoud).
enum DetailTabs191 {
    enum Tab: String, Equatable { case episodes, similar, trailers }

    static func tabs(isSeries: Bool, hasEpisodes: Bool, hasSimilar: Bool, hasTrailers: Bool) -> [Tab] {
        var t: [Tab] = []
        if isSeries && hasEpisodes { t.append(.episodes) }
        if hasSimilar { t.append(.similar) }
        if hasTrailers { t.append(.trailers) }
        return t
    }

    /// De gekozen tab blijft als die er nog is, anders de eerste.
    static func selected(_ current: Tab?, in tabs: [Tab]) -> Tab? {
        if let c = current, tabs.contains(c) { return c }
        return tabs.first
    }
}
