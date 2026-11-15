import SwiftUI
#if !os(tvOS)
import UserNotifications
#endif

// Build 178: club- en competitielogo's op de Sport-pagina, zoals Weekdot (SportsArtwork.swift). Niets in de app: logo's
// worden live opgehaald (maak-agenda.nl, ESPN, TheSportsDB, favicons via Google) en in de Caches-map bewaard
// (map BingrSportLogos: indexen `crests2-….json`, zoekresultaten `crest-search-….json`, afbeeldingen `img-…`, niet
// gevonden `miss-…`). Pure regels: SportLogos178 (SportLogos178.swift). Zolang een logo laadt of ontbreekt: de cirkel
// met initialen. Data besparen (176) op mobiel: geen nieuwe logo's, alleen wat al in de cache staat.

/// Wat er getoond wordt.
enum SportArt: Hashable, Sendable {
    /// Competitie (Sport173-id); `small` = lijstje (favicon eerst)
    case competition(String, small: Bool)
    /// Team in een wedstrijd: vlag (landenteam), clublogo of niets (zie SportLogos178.teamArt)
    case team(name: String, sport: String, competitionID: String)
}

/// Bestanden in Caches/BingrSportLogos. Elke leesactie is optioneel: ontbreekt of verlopen = opnieuw ophalen.
enum SportLogoDisk {
    static let directory: URL = {
        let dir = AppDirs.caches.appendingPathComponent("BingrSportLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Inhoud als hij volgens de regels bruikbaar is (`kind`: index, miss of image).
    static func read(_ name: String, kind: String, saver: Bool) -> Data? {
        let u = url(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let modified = attrs[.modificationDate] as? Date,
              SportLogos178.usable(kind: kind, age: Date().timeIntervalSince(modified), saver: saver) else { return nil }
        return try? Data(contentsOf: u)
    }

    static func write(_ data: Data, _ name: String) { try? data.write(to: url(name), options: .atomic) }
}

/// Haalt logo's op en bewaart ze (geheugen + schijf). Nooit op de hoofdthread.
actor SportLogoStore {
    static let shared = SportLogoStore()

    private struct Index: Codable { var teams: [String: String] }

    private var images: [String: Data] = [:]
    private var misses: Set<String> = []
    private var indexes: [String: [String: String]] = [:]
    private var loadingIndex: [String: Task<[String: String], Never>] = [:]
    private var loadingImage: [String: Task<Data?, Never>] = [:]
    private var crests: [String: String] = [:]

    /// Mag er iets nieuws opgehaald worden? Niet met Data besparen op mobiel.
    nonisolated static var network: Bool { !DataSaver176.active }

    /// Adressen in volgorde van voorkeur voor dit logo.
    func urls(for art: SportArt, network: Bool) async -> [String] {
        switch art {
        case .competition(let id, let small):
            return SportLogos178.competitionURLs(id, small: small)
        case .team(let name, let sport, let comp):
            let kind = SportLogos178.teamArt(name, sport: sport, competitionID: comp)
            if kind.hasPrefix("flag:") { return [SportLogos178.flagURL(String(kind.dropFirst(5)))] }
            guard kind == "club", let crest = await crest(name: name, sport: sport, competitionID: comp, network: network)
            else { return [] }
            return [crest]
        }
    }

    /// De eerste afbeelding die er is (of opgehaald kan worden).
    func data(for art: SportArt, network: Bool = SportLogoStore.network) async -> Data? {
        for u in await urls(for: art, network: network) {
            if let d = await image(u, network: network) { return d }
        }
        return nil
    }

    // MARK: afbeeldingen

    private func image(_ address: String, network: Bool) async -> Data? {
        if let d = images[address] { return d }
        if misses.contains(address) { return nil }
        let file = SportLogos178.cacheName("img", address, ext: "")
        let miss = SportLogos178.cacheName("miss", address, ext: "")
        if let d = SportLogoDisk.read(file, kind: "image", saver: !network) { images[address] = d; return d }
        if SportLogoDisk.read(miss, kind: "miss", saver: !network) != nil { misses.insert(address); return nil }
        guard network, let url = URL(string: address) else { return nil }
        if let running = loadingImage[address] { return await running.value }
        let task = Task<Data?, Never> {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count > 64,
                  (http.mimeType ?? "image").lowercased().hasPrefix("image"), UIImage(data: data) != nil else { return nil }
            return data
        }
        loadingImage[address] = task
        let result = await task.value
        loadingImage[address] = nil
        if let result {
            images[address] = result
            SportLogoDisk.write(result, file)
        } else {
            misses.insert(address)
            SportLogoDisk.write(Data("1".utf8), miss)
        }
        return result
    }

    /// Alleen uit de cache (geen netwerk), bijv. voor de bijlage van een melding.
    func cachedData(for art: SportArt) async -> Data? { await data(for: art, network: false) }

    // MARK: clublogo's

    private func crest(name: String, sport: String, competitionID: String, network: Bool) async -> String? {
        let leagues = SportLogos178.espnLeagues(sport: sport, competitionID: competitionID)
        let cacheKey = name + "|" + sport + "|" + leagues.joined(separator: ",")
        if let hit = crests[cacheKey] { return hit }
        let wanted = SportLogos178.keys(name)
        guard !wanted.isEmpty else { return nil }
        for league in leagues {
            let idx = await index(league, network: network)
            if let found = SportLogos178.match(wanted, in: idx) { crests[cacheKey] = found; return found }
        }
        let found = await search(name, sport: sport, wanted: wanted, network: network)
        if let found { crests[cacheKey] = found }
        return found
    }

    /// ESPN-teamlijst van één competitie (7 dagen bewaard).
    private func index(_ league: String, network: Bool) async -> [String: String] {
        if let cached = indexes[league] { return cached }
        let file = SportLogos178.cacheName("crests2", league, ext: "json")
        let miss = SportLogos178.cacheName("miss-crests2", league, ext: "")
        if let d = SportLogoDisk.read(file, kind: "index", saver: !network), let i = try? JSONDecoder().decode(Index.self, from: d) {
            indexes[league] = i.teams
            return i.teams
        }
        if SportLogoDisk.read(miss, kind: "miss", saver: !network) != nil { indexes[league] = [:]; return [:] }
        guard network else { return [:] }
        if let running = loadingIndex[league] { return await running.value }
        let task = Task<[String: String], Never> {
            guard let url = URL(string: SportLogos178.espnTeamsURL(league)),
                  let json = await Self.fetchJSON(url),
                  let sports = json["sports"] as? [[String: Any]],
                  let leagues = sports.first?["leagues"] as? [[String: Any]],
                  let teams = leagues.first?["teams"] as? [[String: Any]] else { return [:] }
            let list: [(names: [String], logo: String)] = teams.compactMap { w in
                guard let t = w["team"] as? [String: Any] else { return nil }
                let logo = ((t["logos"] as? [[String: Any]])?.first?["href"] as? String) ?? ""
                let names = ["displayName", "shortDisplayName", "name", "location", "nickname"].compactMap { t[$0] as? String }
                return (names: names, logo: logo)
            }
            return SportLogos178.buildIndex(list)
        }
        loadingIndex[league] = task
        let result = await task.value
        loadingIndex[league] = nil
        indexes[league] = result
        if result.isEmpty {
            SportLogoDisk.write(Data("1".utf8), miss)
        } else if let d = try? JSONEncoder().encode(Index(teams: result)) {
            SportLogoDisk.write(d, file)
        }
        return result
    }

    /// TheSportsDB: zoeken op de clubnaam (alleen records van deze sport), als ESPN hem niet kent.
    private func search(_ name: String, sport: String, wanted: [String], network: Bool) async -> String? {
        let key = wanted[0]
        let file = SportLogos178.cacheName("crest-search", key, ext: "json")
        let miss = SportLogos178.cacheName("miss-search", key, ext: "")
        if let d = SportLogoDisk.read(file, kind: "index", saver: !network), let i = try? JSONDecoder().decode(Index.self, from: d) {
            return SportLogos178.match(wanted, in: i.teams)
        }
        if SportLogoDisk.read(miss, kind: "miss", saver: !network) != nil { return nil }
        guard network, let url = URL(string: SportLogos178.sportsDBSearchURL(name)) else { return nil }
        let want = SportLogos178.sportsDBSport(sport)
        let records = ((await Self.fetchJSON(url))?["teams"] as? [[String: Any]] ?? [])
            .filter { (($0["strSport"] as? String) ?? "Soccer") == want }
        let list: [(names: [String], logo: String)] = records.map { r in
            var names = ["strTeam", "strTeamShort"].compactMap { r[$0] as? String }
            if let alt = r["strTeamAlternate"] as? String { names += alt.split(separator: ",").map(String.init) }
            return (names: names, logo: SportLogos178.sportsDBThumb((r["strBadge"] as? String) ?? "") ?? "")
        }
        let idx = SportLogos178.buildIndex(list)
        guard let found = SportLogos178.match(wanted, in: idx) else {
            SportLogoDisk.write(Data("1".utf8), miss)
            return nil
        }
        if let d = try? JSONEncoder().encode(Index(teams: idx)) { SportLogoDisk.write(d, file) }
        return found
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Gedecodeerde logo's voor deze sessie, gedeeld door alle weergaven.
@MainActor
enum SportLogoMemory {
    static var images: [SportArt: UIImage] = [:]
}

// MARK: - Weergaven

/// Logo, vlag of clublogo; zolang het laadt of ontbreekt de cirkel met initialen. Blokkeert nooit.
struct SportLogoView: View {
    let art: SportArt
    let title: String
    var size: CGFloat
    /// Zonder logo: de cirkel met initialen (anders niets, bijv. naast een competitienaam)
    var placeholder = true

    @State private var image: UIImage?

    @MainActor init(art: SportArt, title: String, size: CGFloat, placeholder: Bool = true) {
        self.art = art
        self.title = title
        self.size = size
        self.placeholder = placeholder
        _image = State(initialValue: SportLogoMemory.images[art])
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else if placeholder {
                SportInitials(name: title, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: art) { await load() }
    }

    @MainActor private func load() async {
        if let cached = SportLogoMemory.images[art] { image = cached; return }
        image = nil
        let art = self.art
        guard let data = await SportLogoStore.shared.data(for: art), let decoded = UIImage(data: data) else { return }
        SportLogoMemory.images[art] = decoded
        withAnimation(.easeOut(duration: 0.2)) { image = decoded }
    }
}

/// De cirkel met initialen en een vaste kleur (build 172).
struct SportInitials: View {
    let name: String
    var size: CGFloat
    var body: some View {
        Text(Sport173.short(name))
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Color(hex: Sport173.color(name)), in: Circle())
    }
}

/// Logo van een team in een wedstrijd.
struct SportTeamLogo: View {
    let name: String
    let match: SportMatch173?
    var size: CGFloat = tvScaled(30)
    var body: some View {
        SportLogoView(art: .team(name: name, sport: match?.sport ?? "football", competitionID: match?.competitionID ?? ""),
                      title: name, size: size)
    }
}

/// Logo van de competitie van een wedstrijd (niets als er geen competitie of geen logo is).
struct SportCompetitionLogo: View {
    let match: SportMatch173
    var size: CGFloat = tvScaled(16)
    var body: some View {
        if !match.competitionID.isEmpty {
            SportLogoView(art: .competition(match.competitionID, small: size < 24), title: match.competition, size: size,
                          placeholder: false)
        }
    }
}

/// Vermelding onderaan het sportoverzicht (tekst van Weekdot).
struct SportLogoNotice: View {
    var body: some View {
        Text(L("Logos and crests are trademarks of their respective owners and are shown for identification only."))
            .font(.system(size: tvScaled(11)))
            .foregroundStyle(Color(hex: 0x7A7A7A))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.edge)
            .padding(.top, tvScaled(18))
    }
}

// MARK: - Melding

#if !os(tvOS)
/// Bijlage van een wedstrijdmelding: het logo van de thuisploeg (anders de uitploeg of de competitie), alleen als het
/// al in de cache staat (geen netwerk bij het plannen).
@MainActor
enum SportLogoAttachment {
    static func make(_ r: ProgramReminder) async -> UNNotificationAttachment? {
        guard r.isSport else { return nil }
        let comp = Sport173.competitions.first { $0.name == r.competition }
        let sport = comp?.sport ?? "football"
        var arts: [SportArt] = []
        if let duel = Sport173.parseDuel(r.title) {
            arts.append(.team(name: duel.home, sport: sport, competitionID: comp?.id ?? ""))
            arts.append(.team(name: duel.away, sport: sport, competitionID: comp?.id ?? ""))
        }
        if let comp { arts.append(.competition(comp.id, small: false)) }
        for art in arts {
            guard let data = await SportLogoStore.shared.cachedData(for: art) else { continue }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sportlogo-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("logo.png")
            guard (try? data.write(to: file)) != nil else { continue }
            if let a = try? UNNotificationAttachment(identifier: "logo", url: file,
                                                     options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
                return a
            }
        }
        return nil
    }
}
#endif
