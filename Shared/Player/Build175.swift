import Foundation

// Build 175 (versie 1.0.7): downloaden overal vanuit Meer op de detailpagina (iPhone en iPad), ook bij series.
// Pure logica zonder UI, getest in tools/selftest/main.swift. Dezelfde regels staan in Build175Logic.kt (Android).
// De webspeler heeft geen downloads.

enum Download175 {

    // MARK: - Stand van een download (los van DownloadManager, zodat de logica testbaar is)

    enum State: Equatable { case none, queued, downloading, paused, failed, completed }

    /// Telt als "al binnen of onderweg": niet nog eens toevoegen. Een mislukte of gepauzeerde download wel (dan hervat hij).
    static func isPresent(_ s: State) -> Bool { s == .completed || s == .queued || s == .downloading }

    // MARK: - Film (of één aflevering)

    enum MovieMenu: Equatable {
        /// Knop uitgegrijsd met de reden ("Deze stream kan niet gedownload worden")
        case unavailable
        case download
        /// Bezig: pauzeren, met het percentage
        case active
        /// Gepauzeerd of mislukt: hervatten
        case resume
        /// "Gedownload" met een vinkje, en Verwijderen
        case downloaded
    }

    /// Wat Meer toont voor een film. Een bestaande download gaat voor: die blijft zichtbaar (en te verwijderen), ook als
    /// de stream nu niet (meer) te downloaden is.
    static func movieMenu(canDownload: Bool, state: State) -> MovieMenu {
        switch state {
        case .completed: return .downloaded
        case .queued, .downloading: return .active
        case .paused, .failed: return .resume
        case .none: return canDownload ? .download : .unavailable
        }
    }

    // MARK: - Serie

    enum Scope: String, Equatable, CaseIterable {
        /// "Dit seizoen downloaden": het seizoen dat op de pagina gekozen is
        case season
        /// "Volgende 3 afleveringen": vanaf de aflevering die je als volgende kijkt
        case nextThree
        /// "Hele serie" (met een bevestiging met het aantal afleveringen)
        case all
    }

    struct Episode: Equatable {
        var id: String
        var season: Int
        var number: Int
        /// Heeft een downloadbare stream (DownloadManager.canDownload)
        var downloadable: Bool = true
        var state: State = .none

        init(id: String, season: Int, number: Int, downloadable: Bool = true, state: State = .none) {
            self.id = id; self.season = season; self.number = number; self.downloadable = downloadable; self.state = state
        }
    }

    static let nextCount = 3

    /// Op volgorde (seizoen, aflevering); bij gelijke nummers blijft de volgorde van de lijst
    static func ordered(_ eps: [Episode]) -> [Episode] {
        eps.enumerated().sorted { a, b in
            (a.element.season, a.element.number, a.offset) < (b.element.season, b.element.number, b.offset)
        }.map(\.element)
    }

    /// De afleveringen die een keuze toevoegt (id's, op volgorde). Alleen downloadbare afleveringen die nog niet binnen of
    /// onderweg zijn. `nextUp` = de aflevering die je als volgende kijkt (nil: vanaf het begin).
    /// Volgende 3: de eerste drie vanaf `nextUp` die nog niet binnen zijn, zodat nog eens kiezen de drie daarna pakt.
    static func episodes(for scope: Scope, in eps: [Episode], season: Int, nextUp: String?) -> [String] {
        let list = ordered(eps)
        let wanted: (Episode) -> Bool = { $0.downloadable && !isPresent($0.state) }
        switch scope {
        case .season:
            return list.filter { $0.season == season && wanted($0) }.map(\.id)
        case .all:
            return list.filter(wanted).map(\.id)
        case .nextThree:
            let start = nextUp.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
            return Array(list[start...].filter(wanted).prefix(nextCount)).map(\.id)
        }
    }

    /// Alleen bij Hele serie eerst vragen (met het aantal); seizoen en volgende 3 starten meteen.
    static func needsConfirmation(_ scope: Scope, count: Int) -> Bool { scope == .all && count > 0 }

    struct SeriesMenu: Equatable {
        /// Er is minstens één aflevering met een downloadbare stream (anders: uitgegrijsd met de reden)
        var available: Bool
        var season: Int
        var nextThree: Int
        var all: Int
        /// Afleveringen met een download (elke stand), voor Verwijderen
        var downloaded: Int
        /// Alle downloadbare afleveringen staan op het toestel: "Gedownload" met een vinkje
        var complete: Bool
    }

    static func seriesMenu(_ eps: [Episode], season: Int, nextUp: String?) -> SeriesMenu {
        let downloadable = eps.filter(\.downloadable)
        let withDownload = eps.filter { $0.state != .none }.count
        return SeriesMenu(
            available: !downloadable.isEmpty || withDownload > 0,
            season: episodes(for: .season, in: eps, season: season, nextUp: nextUp).count,
            nextThree: episodes(for: .nextThree, in: eps, season: season, nextUp: nextUp).count,
            all: episodes(for: .all, in: eps, season: season, nextUp: nextUp).count,
            downloaded: withDownload,
            complete: !downloadable.isEmpty && downloadable.allSatisfy { $0.state == .completed }
        )
    }
}
