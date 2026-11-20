import SwiftUI
import ImageIO
import CoreGraphics

// Build 179: live scores en standen van ESPN in Sport, en kaarten in de kleuren van de teams. Pure regels: Sport179
// (Build179Sport.swift). Scores 60 s en standen 1 uur bewaard (standen ook op schijf, voor de wedstrijdmelding);
// met Data besparen (176) op mobiel wordt niets nieuws opgehaald.

@MainActor
final class SportScores: ObservableObject {
    static let shared = SportScores()

    /// Wedstrijden per ESPN-competitie ("soccer/ned.1")
    @Published private(set) var events: [String: [EspnEvent179]] = [:]
    /// Standen per ESPN-competitie
    @Published private(set) var tables: [String: [EspnTable179]] = [:]
    /// Achtergrondkleur per team (Sport173.teamKey)
    @Published private(set) var colors: [String: UInt32] = [:]

    private var eventsAt: [String: Date] = [:]
    private var tablesAt: [String: Date] = [:]
    private var loading: Set<String> = []
    private var colorLoading: Set<String> = []

    nonisolated static var network: Bool { !DataSaver176.active }

    // MARK: ophalen

    /// ESPN-competities van deze wedstrijden (en van de favoriete competities).
    static func leagues(_ groups: [SportGroup173], favorites: Set<String>) -> [String] {
        var out: [String] = []
        for g in groups {
            if let l = Sport179.espnLeague(competitionID: g.match.competitionID, sport: g.match.sport), !out.contains(l) { out.append(l) }
        }
        for c in favorites.sorted() {
            if let comp = Sport173.competition(id: c), let l = Sport179.espnLeague(competitionID: c, sport: comp.sport),
               !out.contains(l) { out.append(l) }
        }
        return out
    }

    /// Scores verversen (hooguit elke 60 s per competitie).
    func refresh(_ leagues: [String]) {
        let now = Date()
        // Data besparen (176): hooguit elke 5 minuten
        let maxAge = Self.network ? Sport179.scoresMaxAge : Sport179.scoresMaxAgeSaver
        for l in leagues where !loading.contains("s:" + l) {
            if let at = eventsAt[l], now.timeIntervalSince(at) < maxAge { continue }
            loading.insert("s:" + l)
            Task {
                let day = Sport179.day(now, timeZone: .current)
                let data = await Self.fetch(Sport179.scoreboardURL(l, day: day))
                self.loading.remove("s:" + l)
                self.eventsAt[l] = Date()
                if let data {
                    let list = Sport179.parseScoreboard(data, league: l)
                    if self.events[l] != list { self.events[l] = list }
                    self.learnColors(list)
                }
            }
        }
    }

    /// Standen van één competitie (1 uur bewaard; zonder netwerk uit de cache op schijf, ook verlopen).
    func loadTables(_ league: String) {
        guard Sport179.hasStandings(league), !loading.contains("t:" + league) else { return }
        if let at = tablesAt[league], Date().timeIntervalSince(at) < Sport179.standingsMaxAge { return }
        let file = SportLogos178.cacheName("standings179", league, ext: "json")
        if tables[league] == nil, let d = try? Data(contentsOf: SportLogoDisk.url(file)),
           let t = try? JSONDecoder().decode([EspnTable179].self, from: d) {
            tables[league] = t
            if let attrs = try? FileManager.default.attributesOfItem(atPath: SportLogoDisk.url(file).path),
               let m = attrs[.modificationDate] as? Date { tablesAt[league] = m }
            if let at = tablesAt[league], Date().timeIntervalSince(at) < Sport179.standingsMaxAge { return }
        }
        guard Self.network else { return }
        loading.insert("t:" + league)
        Task {
            let data = await Self.fetch(Sport179.standingsURL(league))
            self.loading.remove("t:" + league)
            self.tablesAt[league] = Date()
            guard let data else { return }
            let t = Sport179.parseStandings(data)
            guard !t.isEmpty else { return }
            self.tables[league] = t
            if let d = try? JSONEncoder().encode(t) { SportLogoDisk.write(d, file) }
        }
    }

    private nonisolated static func fetch(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: koppelen

    /// De ESPN-wedstrijd bij een wedstrijd uit de gids (alleen duels).
    func event(_ g: SportGroup173) -> EspnEvent179? {
        guard g.match.isDuel else { return nil }
        let pool: [EspnEvent179]
        if let l = Sport179.espnLeague(competitionID: g.match.competitionID, sport: g.match.sport), let e = events[l] {
            pool = e
        } else {
            pool = events.values.flatMap { $0 }
        }
        return Sport179.match(home: g.match.home, away: g.match.away, start: g.start, in: pool)
    }

    /// ESPN-wedstrijden van vandaag van gevolgde competities en teams die niet in de gids staan.
    func notInGuide(_ groups: [SportGroup173], now: Date, teams: [String], competitions: Set<String>) -> [EspnEvent179] {
        let followed = Set(competitions.compactMap { Sport179.espnLeague(competitionID: $0) })
        let all = events.keys.sorted().flatMap { events[$0] ?? [] }.filter { e in
            followed.contains(e.league) || teams.contains { Sport179.sameTeam($0, e.home.names) || Sport179.sameTeam($0, e.away.names) }
        }
        var matched = Set<String>()
        for g in groups { if let e = event(g) { matched.insert(Sport179.key(e)) } }
        let cal = Calendar.current
        return Sport179.notInGuide(all, matched: matched).filter { $0.isLive || cal.isDate($0.start, inSameDayAs: now) }
    }

    /// Plaats in de stand (alleen wat al bekend of op schijf is).
    func rank(_ team: String, competitionID: String, sport: String) -> Int? {
        guard let l = Sport179.espnLeague(competitionID: competitionID, sport: sport) else { return nil }
        if tables[l] == nil { loadTables(l) }
        return tables[l].flatMap { Sport179.rank(team, in: $0) }
    }

    /// Voor de wedstrijdmelding en de banner: de stand ("2–1 · 67'") als ESPN die heeft.
    func score(title: String, start: Date, competition: String?) -> String? {
        guard let duel = Sport173.parseDuel(title) else { return nil }
        let comp = Sport173.competitions.first { $0.name == competition }
        let league = comp.flatMap { Sport179.espnLeague(competitionID: $0.id, sport: $0.sport) }
        let pool = league.flatMap { events[$0] } ?? events.values.flatMap { $0 }
        return Sport179.match(home: duel.home, away: duel.away, start: start, in: pool).flatMap(Sport179.status)
    }

    /// Voor de wedstrijdmelding: "Ajax (2) - PSV (1)" als beide plaatsen bekend zijn.
    func rankedTitle(_ title: String, competition: String?) -> String? {
        guard let duel = Sport173.parseDuel(title),
              let comp = Sport173.competitions.first(where: { $0.name == competition }),
              let a = rank(duel.home, competitionID: comp.id, sport: comp.sport),
              let b = rank(duel.away, competitionID: comp.id, sport: comp.sport) else { return nil }
        return "\(duel.home) (\(a)) - \(duel.away) (\(b))"
    }

    // MARK: teamkleuren

    private func learnColors(_ list: [EspnEvent179]) {
        var next = colors
        for e in list {
            for t in [e.home, e.away] where t.color != nil || t.alternateColor != nil {
                let c = Sport179.teamColor(name: t.displayName, color: t.color, alternate: t.alternateColor, logo: nil)
                for n in t.names { next[Sport173.teamKey(n)] = c }
            }
        }
        if next != colors { colors = next }
    }

    /// Bekende kleur van een team, of nil (dan de vaste kleur van build 172).
    func color(_ name: String) -> UInt32? {
        let k = Sport173.teamKey(name)
        if let c = colors[k] { return c }
        for e in events.values.joined() {
            for t in [e.home, e.away] where (t.color != nil || t.alternateColor != nil) && Sport179.sameTeam(name, t.names) {
                return Sport179.teamColor(name: name, color: t.color, alternate: t.alternateColor, logo: nil)
            }
        }
        return nil
    }

    /// Kleur zeker weten: ESPN, anders de gemiddelde kleur van het logo (uit de cache van build 178), anders vast.
    func resolveColor(_ name: String, match: SportMatch173?) async {
        let k = Sport173.teamKey(name)
        guard !k.isEmpty, colors[k] == nil, !colorLoading.contains(k) else { return }
        if let c = color(name) { colors[k] = c; return }
        colorLoading.insert(k)
        let art = SportArt.team(name: name, sport: match?.sport ?? "football", competitionID: match?.competitionID ?? "")
        let data = await SportLogoStore.shared.data(for: art)
        let avg = await Task.detached(priority: .utility) { data.flatMap(Self.average) }.value
        colorLoading.remove(k)
        if colors[k] == nil, let avg { colors[k] = Sport179.teamColor(name: name, color: nil, alternate: nil, logo: avg) }
    }

    /// Gemiddelde kleur van een logo (verkleind naar 16×16).
    nonisolated static func average(_ data: Data) -> UInt32? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = 16, h = 16
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Sport179.averageColor(rgba: buf) : nil
    }
}

/// Achtergrond in de kleuren van de teams (punt 8): verloop van thuis naar uit, donker naar de kaart toe.
struct SportTeamTint: View {
    @ObservedObject private var scores = SportScores.shared
    let match: SportMatch173
    var opacity: Double = 0.55

    private func c(_ name: String) -> Color {
        Color(hex: scores.colors[Sport173.teamKey(name)] ?? Sport173.color(name))
    }

    var body: some View {
        Group {
            if match.isDuel {
                LinearGradient(colors: [c(match.home).opacity(opacity), c(match.away).opacity(opacity)],
                               startPoint: .leading, endPoint: .trailing)
            } else {
                Color.clear
            }
        }
        .task(id: match.home + "|" + match.away) {
            guard match.isDuel else { return }
            await scores.resolveColor(match.home, match: match)
            await scores.resolveColor(match.away, match: match)
        }
    }
}

/// Stand of status van een wedstrijd: "67' · 2 - 1" (live, rood) of "FT · 2 - 1".
struct SportScoreBadge: View {
    let event: EspnEvent179
    var size: CGFloat = tvScaled(13)
    var body: some View {
        if let s = Sport179.status(event) {
            Text(event.isFinished ? L("Full time") + " " + s : s)
                .font(.system(size: size, weight: .heavy).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(event.isLive ? Theme.alert : Color(hex: 0x333333), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(event.isLive ? L("Live score %@", s) : L("Final score %@", s))
        }
    }
}

/// Donkere kaart met een zachte waas in de kleuren van de teams.
struct SportCardBackground: View {
    let match: SportMatch173
    var opacity: Double = 0.35
    var radius: CGFloat = 12
    var body: some View {
        ZStack {
            Color(hex: 0x121212)
            SportTeamTint(match: match, opacity: opacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Wedstrijd uit ESPN die niet in de gids staat (alleen ter informatie: geen zender).
struct SportEspnRow: View {
    @ObservedObject private var scores = SportScores.shared
    let event: EspnEvent179

    private var match: SportMatch173 {
        SportMatch173(kind: "duel", title: event.home.displayName + " - " + event.away.displayName,
                      home: event.home.displayName, away: event.away.displayName, sport: Self.sport(event.league),
                      competition: "", competitionID: "")
    }

    static func sport(_ league: String) -> String {
        if league.hasPrefix("soccer/") { return "football" }
        if league.hasPrefix("basketball/") { return "basketball" }
        if league.hasPrefix("hockey/") { return "icehockey" }
        if league.hasPrefix("football/") { return "americanfootball" }
        return "other"
    }

    var body: some View {
        let m = match
        HStack(spacing: tvScaled(12)) {
            Text(SportCenter.time(event.start)).font(.system(size: tvScaled(15), weight: .heavy))
                .frame(width: tvScaled(64))
            SportTeamBadge(name: m.home, match: m, size: tvScaled(26))
            SportTeamBadge(name: m.away, match: m, size: tvScaled(26))
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.system(size: tvScaled(15), weight: .bold)).lineLimit(1)
                if event.scoreLine != nil {
                    SportScoreBadge(event: event, size: tvScaled(12))
                } else {
                    Text(L("Not in your guide")).font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SportCardBackground(match: m, opacity: 0.3, radius: 12))
        #if os(tvOS)
        .focusable()
        #endif
        .accessibilityElement(children: .combine)
    }
}

/// Stand van één competitie (ESPN): plaats, team, gespeeld, punten (en verschil).
struct SportStandingsSection: View {
    @ObservedObject private var scores = SportScores.shared
    let league: String
    var highlight: [String] = []
    var inset = true
    var limit: Int? = nil

    private var title: String {
        let id = Sport173.competitions.first { Sport179.espnLeague(competitionID: $0.id, sport: $0.sport) == league }
        return id?.name ?? league
    }

    private func marked(_ r: EspnStanding179) -> Bool { highlight.contains { Sport179.sameTeam($0, r.names) } }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(L("Standings") + " · " + title).font(.system(size: tvScaled(inset ? 18 : 14), weight: .heavy))
                .padding(.top, tvScaled(8))
            if let tables = scores.tables[league] {
                ForEach(Array(tables.enumerated()), id: \.offset) { _, t in
                    if tables.count > 1 && !t.name.isEmpty {
                        Text(t.name).font(.system(size: tvScaled(12), weight: .bold)).foregroundStyle(Theme.secondary)
                    }
                    VStack(spacing: 0) {
                        header
                        ForEach(rows(t), id: \.self) { r in row(r) }
                    }
                    .background(Color(hex: 0x121212), in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text(SportScores.network ? L("Loading…") : L("Standings are not available right now."))
                    .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, inset ? Theme.edge : 0)
        .task(id: league) { scores.loadTables(league) }
    }

    private func rows(_ t: EspnTable179) -> [EspnStanding179] {
        guard let limit, t.rows.count > limit else { return t.rows }
        // de gemarkeerde teams altijd tonen
        return t.rows.enumerated().filter { $0.offset < limit || marked($0.element) }.map(\.element)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: tvScaled(26), alignment: .trailing)
            Text(L("Team")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("P")).frame(width: tvScaled(30))
            Text(L("+/-")).frame(width: tvScaled(38))
            Text(L("Pts")).frame(width: tvScaled(36))
        }
        .font(.system(size: tvScaled(11), weight: .bold)).foregroundStyle(Theme.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func row(_ r: EspnStanding179) -> some View {
        let on = marked(r)
        return HStack(spacing: 8) {
            Text("\(r.rank)").frame(width: tvScaled(26), alignment: .trailing).foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                SportTeamBadge(name: r.displayName, match: nil, size: tvScaled(18))
                Text(r.displayName).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(r.played)").frame(width: tvScaled(30))
            Text(r.difference > 0 ? "+\(r.difference)" : "\(r.difference)").frame(width: tvScaled(38))
            Text("\(r.points)").fontWeight(.bold).frame(width: tvScaled(36))
        }
        .font(.system(size: tvScaled(13)).monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(on ? Theme.red.opacity(0.18) : .clear)
        #if os(tvOS)
        .focusable()
        #endif
    }
}
