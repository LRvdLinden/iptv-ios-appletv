import SwiftUI

// Build 172: tabblad Sport (iPhone, iPad, Mac en Apple TV). Wedstrijden uit de tv-gids van de servers van het account
// (Sport173 in Build173.swift), een kaart "Nu live" met het live voorbeeld (zelfde route als de tv-gids van build 164)
// en per dag de wedstrijden met een belletje (herinnering, docs/ACCOUNT.md → "Build 172: Sport").

// MARK: - Gegevens

/// Zoekt de wedstrijden op de achtergrond (met een cache per bibliotheek) en zet de automatische belletjes.
@MainActor
final class SportCenter: ObservableObject {
    static let shared = SportCenter()

    @Published private(set) var groups: [SportGroup173] = []
    @Published private(set) var loading = false
    /// Zender per programma (`SportListing173.id`), met `sourceID` als hij van een andere server komt
    private(set) var channels: [String: Channel] = [:]
    private var lastKey: String?
    private var lastRun = Date.distantPast
    private var running = false
    private var again = false

    /// Instellingen > Meldingen: standaardmoment van de melding (0, 5 of 15 min vóór de start; standaard 5)
    nonisolated static let leadKey = "sport.lead"
    nonisolated static var defaultLead: Int { Sport173.lead(UserDefaults.standard.object(forKey: leadKey) as? Int) }

    /// Opnieuw zoeken als de bibliotheek, de servers, de favorieten of het profiel veranderen, en elk kwartier.
    func refresh(_ playlists: PlaylistService, force: Bool = false) {
        guard let src = playlists.source else { return }
        let store = CloudStore.shared
        let key = [src.id.uuidString, String(playlists.libraryVersion), String(store.playlists.count),
                   String(store.favorites.count), store.activeProfileID?.uuidString ?? "-"].joined(separator: "|")
        if !force, key == lastKey, Date().timeIntervalSince(lastRun) < 900 { return }
        if running { again = true; return }
        running = true
        lastKey = key
        lastRun = Date()
        if groups.isEmpty { loading = true }
        let lib = playlists.library
        let favs = store.favorites
        let activeID = src.id
        let others = store.playlists.filter { $0.id != src.id && !$0.kind.isMediaServer }
        let ctx = Dictionary(uniqueKeysWithValues: others.map { ($0.id, playlists.context(for: $0)) })
        Task {
            let r = await Task.detached(priority: .utility) {
                Self.compute(active: lib, activeID: activeID, others: others, contexts: ctx, favorites: favs, now: Date())
            }.value
            self.channels = r.channels
            if self.groups != r.groups { self.groups = r.groups }
            self.loading = false
            self.running = false
            self.applyAuto(activeID: activeID)
            if self.again { self.again = false; self.refresh(playlists, force: true) }
        }
    }

    /// Op de achtergrond: sportzenders van alle servers, hun programma's van nu tot 7 dagen vooruit, herkennen en
    /// ontdubbelen. De bibliotheken zijn al gefilterd voor het profiel (verborgen zenders en categorieën, kinderprofiel).
    nonisolated static func compute(active: Library, activeID: UUID, others: [PlaylistSource],
                                    contexts: [UUID: PlaylistService.FilterContext], favorites: Set<String>,
                                    now: Date) -> (groups: [SportGroup173], channels: [String: Channel]) {
        var listings: [SportListing173] = []
        var chans: [String: Channel] = [:]
        let until = now.addingTimeInterval(Double(Sport173.days) * 86400)
        func scan(_ lib: Library, server: UUID, mark: Bool) {
            for c in lib.channels where c.radio != true {
                let pid = c.sourceID ?? server
                let fav = ListKeys.contains(favorites, playlist: pid.uuidString, item: c.id)
                guard Sport173.isSportChannel(c.name, category: c.group, favorite: fav) else { continue }
                for p in lib.programs(c, from: now, to: until) {
                    guard let m = Sport173.classify(title: p.title, description: p.description, channel: c.name,
                                                    category: c.group, start: p.start, end: p.end) else { continue }
                    let id = "\(pid.uuidString)|\(c.id)|\(Int(p.start.timeIntervalSince1970))"
                    if chans[id] != nil { continue }
                    var ch = c
                    if mark { ch.sourceID = server }
                    chans[id] = ch
                    listings.append(SportListing173(id: id, channel: c.name, favorite: fav, start: p.start, end: p.end, match: m))
                }
            }
        }
        scan(active, server: activeID, mark: false)
        for p in others {
            guard let raw = PlaylistService.readCache(p) else { continue }
            let lib = contexts[p.id].map { PlaylistService.apply(raw, $0) } ?? raw
            scan(lib, server: p.id, mark: true)
        }
        return (Sport173.dedupe(listings), chans)
    }

    // MARK: belletjes

    /// Wedstrijden van favoriete teams en competities in de komende 7 dagen krijgen automatisch een belletje
    /// (eén per wedstrijd: vaste sleutel). Wat de gebruiker uitzette (`sportMuted`) komt niet terug.
    private func applyAuto(activeID: UUID) {
        let store = CloudStore.shared
        let teams = Array(store.favoriteTeams), comps = Array(store.favoriteCompetitions)
        guard !teams.isEmpty || !comps.isEmpty else { return }
        let existing = Set(store.reminders.filter { store.belongsToActive($0.owner) }.compactMap(\.matchKey))
        let keys = Sport173.autoReminders(groups, now: Date(), teams: teams, competitions: comps,
                                          muted: store.sportMuted, existing: existing)
        for k in keys {
            guard let g = groups.first(where: { $0.key == k }), let c = channel(g) else { continue }
            let pid = c.sourceID ?? activeID
            Task { await ReminderCenter.shared.addSport(key: k, match: g.match, start: g.start, channel: c, playlist: pid,
                                                        lead: Self.defaultLead, auto: true) }
        }
    }

    /// De beste zender van een wedstrijd (favoriet, kwaliteit, gids).
    func channel(_ g: SportGroup173) -> Channel? { g.listings.first.flatMap { channels[$0.id] } }
    func channel(_ l: SportListing173) -> Channel? { channels[l.id] }

    func reminder(_ g: SportGroup173) -> ProgramReminder? { ReminderCenter.shared.sportReminder(key: g.key) }

    /// Belletje aan (met `lead`) of uit. Uitzetten dempt de wedstrijd, zodat een automatisch belletje niet terugkomt.
    func setBell(_ g: SportGroup173, on: Bool, lead: Int? = nil, playlists: PlaylistService) {
        let store = CloudStore.shared
        if let r = reminder(g) {
            ReminderCenter.shared.remove(r.id)
        }
        if on, let c = channel(g), let pid = c.sourceID ?? playlists.source?.id {
            store.updateProfileSet(.sportMuted, remove: [g.key])
            Task { await ReminderCenter.shared.addSport(key: g.key, match: g.match, start: g.start, channel: c, playlist: pid,
                                                        lead: lead ?? Self.defaultLead) }
        } else if !on {
            let pruned = Set(Sport173.pruneMuted(Array(store.sportMuted), now: Date()))
            store.updateProfileSet(.sportMuted, insert: [g.key], remove: store.sportMuted.subtracting(pruned))
        }
        objectWillChange.send()
    }

    // MARK: favorieten

    func isFavoriteTeam(_ name: String) -> Bool {
        let k = Sport173.teamKey(name)
        return CloudStore.shared.favoriteTeams.contains { Sport173.teamKey($0) == k }
    }

    func setFavoriteTeam(_ name: String, _ on: Bool, playlists: PlaylistService) {
        let store = CloudStore.shared
        let k = Sport173.teamKey(name)
        let same = store.favoriteTeams.filter { Sport173.teamKey($0) == k }
        if on { store.updateProfileSet(.favoriteTeams, insert: [Sport173.cleanTeam(name)], remove: same) }
        else { store.updateProfileSet(.favoriteTeams, remove: same) }
        objectWillChange.send()
        if on, let pid = playlists.source?.id { applyAuto(activeID: pid) }
    }

    func setFavoriteCompetition(_ id: String, _ on: Bool, playlists: PlaylistService) {
        let store = CloudStore.shared
        if on { store.updateProfileSet(.favoriteCompetitions, insert: [id]) }
        else { store.updateProfileSet(.favoriteCompetitions, remove: [id]) }
        objectWillChange.send()
        if on, let pid = playlists.source?.id { applyAuto(activeID: pid) }
    }

    // MARK: teksten

    nonisolated static func sportName(_ id: String) -> String {
        switch id {
        case "football": return L("Football")
        case "motorsport": return L("F1/Motorsport")
        case "tennis": return L("Tennis")
        case "darts": return L("Darts")
        case "cycling": return L("Cycling")
        case "basketball": return L("Basketball")
        case "icehockey": return L("Ice hockey")
        case "americanfootball": return L("American football")
        case "combat": return L("Combat sports")
        case "golf": return L("Golf")
        default: return L("Other")
        }
    }

    nonisolated static func leadName(_ m: Int) -> String {
        switch m {
        case 0: return L("At the start")
        case 15: return L("15 min before")
        default: return L("5 min before")
        }
    }

    /// Competitie, anders de sport
    nonisolated static func label(_ m: SportMatch173) -> String { m.competition.isEmpty ? sportName(m.sport) : m.competition }

    nonisolated static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    nonisolated static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("Today") }
        if cal.isDateInTomorrow(day) { return L("Tomorrow") }
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: day).capitalized(with: Localizer.shared.locale)
    }
}

// MARK: - Filter en indeling

private enum SportFilter: Hashable {
    case all, mine, sport(String)
}

private struct SportDay: Identifiable {
    let id: Date
    let groups: [SportGroup173]
}

private extension SportGroup173 {
    func isLive(_ now: Date) -> Bool { start <= now && now < end }
    func progress(_ now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(max(now.timeIntervalSince(start) / total, 0), 1) : 0
    }
}

// MARK: - Tabblad

struct SportView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var center = SportCenter.shared
    @ObservedObject private var store = CloudStore.shared
    @State private var filter: SportFilter = .all
    @State private var now = Date()
    @State private var sheet: SportGroup173?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var filters: [SportFilter] {
        let present = Set(center.groups.map(\.match.sport))
        return [.all, .mine] + Sport173.sports.filter { present.contains($0) }.map { SportFilter.sport($0) }
    }

    private func title(_ f: SportFilter) -> String {
        switch f {
        case .all: return L("All")
        case .mine: return L("My teams")
        case .sport(let s): return SportCenter.sportName(s)
        }
    }

    private var visible: [SportGroup173] {
        let teams = Array(store.favoriteTeams), comps = Array(store.favoriteCompetitions)
        return center.groups.filter { g in
            guard g.end > now else { return false }
            switch filter {
            case .all: return true
            case .mine: return Sport173.isFavorite(g.match, teams: teams, competitions: comps) || center.reminder(g) != nil
            case .sport(let s): return g.match.sport == s
            }
        }
    }

    private var live: [SportGroup173] { visible.filter { $0.isLive(now) } }

    private var days: [SportDay] {
        let cal = Calendar.current
        var order: [Date] = []
        var by: [Date: [SportGroup173]] = [:]
        for g in visible where !g.isLive(now) {
            let d = cal.startOfDay(for: g.start)
            if by[d] == nil { order.append(d) }
            by[d, default: []].append(g)
        }
        return order.map { SportDay(id: $0, groups: by[$0] ?? []) }
    }

    var body: some View {
        content
            .background(Color.black.ignoresSafeArea())
            .task(id: playlists.libraryVersion) { center.refresh(playlists) }
            .onReceive(tick) { d in
                now = d
                center.refresh(playlists)
            }
            .onChange(of: store.favoriteTeams) { _, _ in center.refresh(playlists, force: true) }
            .onChange(of: store.favoriteCompetitions) { _, _ in center.refresh(playlists, force: true) }
            .onDisappear { ChannelPreview.shared.stop(release: true) }
            #if os(tvOS)
            .fullScreenCover(item: $sheet) { g in SportMatchSheet(group: g).environmentObject(playlists).environmentObject(app) }
            #else
            .sheet(item: $sheet) { g in
                SportMatchSheet(group: g)
                    .environmentObject(playlists).environmentObject(app)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            #endif
    }

    @ViewBuilder private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: tvScaled(14)) {
                header
                if center.loading && center.groups.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(L("Looking for matches…")).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, Theme.edge).padding(.top, 30)
                } else if center.groups.isEmpty {
                    empty(L("No matches found"), L("Matches come from the TV guide of your servers: sports channels and event categories."))
                } else if visible.isEmpty {
                    empty(L("No matches for this filter."), nil)
                } else {
                    if !live.isEmpty { liveSection }
                    ForEach(days) { day in daySection(day) }
                }
            }
            .padding(.bottom, tvScaled(90))
        }
    }

    private func empty(_ title: String, _ text: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sportscourt").font(.system(size: tvScaled(40))).foregroundStyle(Theme.secondary)
            Text(title).font(.system(size: tvScaled(18), weight: .bold))
            if let text {
                Text(text).font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.edge).padding(.top, tvScaled(60))
    }

    // MARK: kop en filterchips

    private var header: some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            #if !os(tvOS)
            Text(L("Sport")).font(Theme.titleFont)
                .padding(.horizontal, Theme.edge)
            #endif
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tvScaled(8)) {
                    ForEach(filters, id: \.self) { f in chip(f) }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, tvScaled(6))
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(.top, tvScaled(8))
    }

    private func chip(_ f: SportFilter) -> some View {
        let on = f == filter
        return Button { filter = f } label: {
            Text(title(f))
                .font(.system(size: tvScaled(13), weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, tvScaled(14)).padding(.vertical, tvScaled(8))
                .frame(minHeight: tvScaled(36))
                .background(on ? Theme.red.opacity(0.18) : Color(hex: 0x141414), in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.red : Color(hex: 0x2C2C2C), lineWidth: 1))
        }
        .plainTVButton()
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Nu live

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            HStack(spacing: 8) {
                Circle().fill(Theme.alert).frame(width: tvScaled(8), height: tvScaled(8))
                Text(L("LIVE NOW")).font(.system(size: tvScaled(13), weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Color(hex: 0xFF5A62))
            }
            .padding(.horizontal, Theme.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: tvScaled(14)) {
                    ForEach(Array(live.enumerated()), id: \.element.key) { i, g in
                        SportLiveCard(group: g, now: now, preview: i == 0, onWatch: { watch(g) })
                    }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, tvScaled(8))
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    // MARK: dagen

    private func daySection(_ day: SportDay) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(8)) {
            Text(SportCenter.dayTitle(day.id)).font(.system(size: tvScaled(18), weight: .heavy))
                .padding(.horizontal, Theme.edge).padding(.top, tvScaled(8))
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(day.groups, id: \.key) { g in
                        SportTVCard(group: g, now: now, onWatch: { watch(g) }, onMore: { sheet = g })
                    }
                }
                .padding(.horizontal, Theme.edge).padding(.vertical, 12)
            }
            .focusSection()
            #else
            VStack(spacing: 8) {
                ForEach(day.groups, id: \.key) { g in
                    SportRow(group: g, onOpen: { sheet = g })
                }
            }
            .padding(.horizontal, Theme.edge)
            #endif
        }
    }

    private func watch(_ g: SportGroup173) {
        guard let c = center.channel(g) else { return }
        SportPlayback.play(c, app: app, playlists: playlists)
    }
}

/// Kijken: de zender live (ook van een andere server, via `sourceID`).
@MainActor
enum SportPlayback {
    static func play(_ c: Channel, app: AppState, playlists: PlaylistService) {
        ChannelPreview.shared.stop()
        let lib = playlists.library
        let zap = c.sourceID == nil ? lib.channels.filter { $0.group == c.group } : []
        app.play(Playables.channel(c, now: c.sourceID == nil ? lib.nowPlaying(c) : nil), zap: zap)
    }
}

// MARK: - Teamcirkel

struct SportTeamBadge: View {
    let name: String
    var size: CGFloat = tvScaled(30)
    var body: some View {
        Text(Sport173.short(name))
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Color(hex: Sport173.color(name)), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Kaart Nu live

private struct SportLiveCard: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var preview = ChannelPreview.shared
    let group: SportGroup173
    let now: Date
    let preview0: Bool
    let onWatch: () -> Void

    init(group: SportGroup173, now: Date, preview: Bool, onWatch: @escaping () -> Void) {
        self.group = group
        self.now = now
        self.preview0 = preview
        self.onWatch = onWatch
    }

    private var channel: Channel? { SportCenter.shared.channel(group) }
    private var width: CGFloat {
        #if os(tvOS)
        return 430
        #else
        return PlayerSettings.isPhone ? 330 : 400
        #endif
    }

    var body: some View {
        Button(action: onWatch) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let c = channel, preview.channel?.id == c.id {
                        ChannelPreviewView(placeholder: c, cornerRadius: 0)
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(hex: 0x134A2A), Color(hex: 0x0B2A17)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            if let c = channel { RemoteImage(url: c.logo, contentMode: .fit, placeholder: c.name).padding(tvScaled(28)) }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                    }
                    Text(L("LIVE")).font(.system(size: tvScaled(11), weight: .heavy))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.alert, in: RoundedRectangle(cornerRadius: 4))
                        .padding(10)
                    if let c = channel {
                        Text(CategoryName.channel(c.name)).font(.system(size: tvScaled(11), weight: .bold)).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(SportCenter.label(group.match)).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    HStack(spacing: 10) {
                        if group.match.isDuel { SportTeamBadge(name: group.match.home) }
                        Text(group.match.title).font(.system(size: tvScaled(17), weight: .bold)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if group.match.isDuel { SportTeamBadge(name: group.match.away) }
                    }
                    ProgressView(value: group.progress(now)).tint(Theme.alert)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .frame(width: width)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x262626), lineWidth: 1))
            #if os(tvOS)
            .background(FocusProbe { f in
                guard let c = channel else { return }
                if f { preview.select(c, playlists: playlists, delay: 1.0, floating: false) } else { preview.release(c) }
            })
            #endif
        }
        .plainTVButton()
        .accessibilityLabel("\(L("LIVE")), \(SportCenter.label(group.match)), \(group.match.title)")
        .onAppear {
            #if !os(tvOS)
            // telefoon, tablet en Mac: het eerste live voorbeeld start vanzelf (zonder geluid; instelling Live voorbeeld)
            if preview0, let c = channel { preview.select(c, playlists: playlists, delay: 1.0, floating: false) }
            #endif
        }
    }
}

// MARK: - Rij (telefoon, tablet, Mac)

private struct SportRow: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var center = SportCenter.shared
    @ObservedObject private var store = CloudStore.shared
    let group: SportGroup173
    let onOpen: () -> Void

    var body: some View {
        let on = center.reminder(group) != nil
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text(SportCenter.time(group.start)).font(.system(size: 15, weight: .heavy))
                        Text(center.channel(group).map { CategoryName.channel($0.name) } ?? "")
                            .font(.system(size: 11)).foregroundStyle(Color(hex: 0x8A8A8A)).lineLimit(1)
                    }
                    .frame(width: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SportCenter.label(group.match)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Text(group.match.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                center.setBell(group, on: !on, playlists: playlists)
            } label: {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(on ? Theme.alert : Theme.secondary)
                    .frame(width: 44, height: 44)
                    .background(on ? Theme.alert.opacity(0.18) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? L("Turn off reminder") : L("Turn on reminder"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(hex: 0x121212), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Kaart (Apple TV)

#if os(tvOS)
private struct SportTVCard: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var center = SportCenter.shared
    @ObservedObject private var store = CloudStore.shared
    let group: SportGroup173
    let now: Date
    let onWatch: () -> Void
    let onMore: () -> Void

    var body: some View {
        let on = center.reminder(group) != nil
        // OK: kijken (live) of het belletje aan/uit (nog niet begonnen); ingedrukt houden: meer
        Button {
            if group.isLive(now) { onWatch() } else { center.setBell(group, on: !on, playlists: playlists) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(SportCenter.time(group.start)).font(.system(size: 26, weight: .heavy))
                    Spacer()
                    Image(systemName: on ? "bell.fill" : "bell").font(.system(size: 26))
                        .foregroundStyle(on ? Theme.alert : Theme.secondary)
                }
                Text([SportCenter.label(group.match), center.channel(group).map { CategoryName.channel($0.name) } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 20)).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(group.match.title).font(.system(size: 24, weight: .bold)).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(width: 360, alignment: .leading)
            .background(Color(hex: 0x121212), in: RoundedRectangle(cornerRadius: 14))
        }
        .plainTVButton()
        .contextMenu {
            Button(L("Notification")) { onMore() }
        }
    }
}
#endif

// MARK: - Blad van een wedstrijd

struct SportMatchSheet: View {
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = SportCenter.shared
    @ObservedObject private var store = CloudStore.shared
    let group: SportGroup173
    @State private var lead = SportCenter.defaultLead

    private var reminder: ProgramReminder? { center.reminder(group) }
    private var live: Bool { group.start <= Date() && Date() < group.end }

    private var subtitle: String {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return [SportCenter.label(group.match), f.string(from: group.start), SportCenter.time(group.start),
                center.channel(group).map { CategoryName.channel($0.name) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tvScaled(14)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtitle).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    HStack(spacing: 10) {
                        if group.match.isDuel { SportTeamBadge(name: group.match.home, size: tvScaled(36)) }
                        Text(group.match.title).font(.system(size: tvScaled(20), weight: .heavy))
                        if group.match.isDuel { SportTeamBadge(name: group.match.away, size: tvScaled(36)) }
                    }
                }
                if live {
                    Button {
                        if let c = center.channel(group) { dismiss(); SportPlayback.play(c, app: app, playlists: playlists) }
                    } label: {
                        Label(L("Watch live"), systemImage: "play.fill").frame(maxWidth: .infinity).onAccentLabel()
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                } else {
                    Text(L("Notification")).font(.system(size: tvScaled(14), weight: .bold))
                    HStack(spacing: 8) {
                        ForEach(Sport173.leads, id: \.self) { m in
                            Button {
                                lead = m
                                if reminder != nil { center.setBell(group, on: true, lead: m, playlists: playlists) }
                            } label: {
                                Text(SportCenter.leadName(m)).font(.system(size: tvScaled(13), weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: tvScaled(44))
                                    .background(lead == m ? Theme.red.opacity(0.18) : Color(hex: 0x1D1D1D), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(lead == m ? Theme.red : Color(hex: 0x2C2C2C)))
                            }
                            .plainTVButton()
                            .accessibilityAddTraits(lead == m ? .isSelected : [])
                        }
                    }
                }
                if group.match.isDuel {
                    teamToggle(group.match.home)
                    teamToggle(group.match.away)
                }
                if !group.match.competitionID.isEmpty {
                    Toggle(L("All matches of %@", group.match.competition), isOn: Binding(
                        get: { store.favoriteCompetitions.contains(group.match.competitionID) },
                        set: { center.setFavoriteCompetition(group.match.competitionID, $0, playlists: playlists) }))
                        .tint(Theme.red)
                }
                if !live {
                    Button {
                        center.setBell(group, on: reminder == nil, lead: lead, playlists: playlists)
                    } label: {
                        Text(reminder == nil ? L("Turn on reminder") : L("Turn off reminder"))
                            .font(.system(size: tvScaled(16), weight: .bold)).frame(maxWidth: .infinity, minHeight: tvScaled(32))
                            .onAccentLabel()
                    }
                    .buttonStyle(.borderedProminent).tint(reminder == nil ? Theme.red : Color(hex: 0x333333))
                    if reminder != nil {
                        Label(L("Reminder on"), systemImage: "bell.fill").font(.system(size: tvScaled(13)))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if group.listings.count > 1 {
                    Text(L("Also on")).font(.system(size: tvScaled(14), weight: .bold)).padding(.top, 6)
                    ForEach(Array(group.listings.dropFirst().prefix(6)), id: \.id) { l in
                        Button {
                            if let c = center.channel(l) { dismiss(); SportPlayback.play(c, app: app, playlists: playlists) }
                        } label: {
                            HStack {
                                Text(CategoryName.channel(l.channel)).lineLimit(1)
                                Spacer()
                                Text(SportCenter.time(l.start)).foregroundStyle(Theme.secondary)
                            }
                            .font(.system(size: tvScaled(14)))
                        }
                        .plainTVButton()
                        .disabled(!(l.start <= Date() && Date() < l.end))
                    }
                }
            }
            .padding(tvScaled(20))
        }
        .background(Color(hex: 0x141414).ignoresSafeArea())
        .onAppear { if let r = reminder { lead = Sport173.lead(r.leadMin) } }
    }

    private func teamToggle(_ name: String) -> some View {
        Toggle(L("All matches of %@", name), isOn: Binding(
            get: { center.isFavoriteTeam(name) },
            set: { center.setFavoriteTeam(name, $0, playlists: playlists) }))
            .tint(Theme.red)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(hex: 0x1D1D1D), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension SportGroup173: Identifiable {
    var id: String { key }
}

// MARK: - Instellingen

/// Instellingen > Meldingen: standaardmoment voor een belletje bij een wedstrijd.
struct SportNotifySettingsSection: View {
    @AppStorage(SportCenter.leadKey) private var lead = Sport173.defaultLead

    var body: some View {
        Section {
            Picker(L("Default notification for a match"), selection: Binding(get: { Sport173.lead(lead) }, set: { lead = $0 })) {
                ForEach(Sport173.leads, id: \.self) { Text(SportCenter.leadName($0)).tag($0) }
            }
        } header: { Text(L("Sport reminders")) }
    }
}

/// Instellingen > Sport > Mijn teams en competities.
struct SportSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink { SportFavoritesView() } label: {
                Label(L("My teams and competitions"), systemImage: "sportscourt")
            }
        } header: { Text(L("Sport")) } footer: {
            Text(L("Matches of your teams and competitions get a reminder automatically."))
        }
    }
}

struct SportFavoritesView: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var store = CloudStore.shared
    @ObservedObject private var center = SportCenter.shared
    @State private var newTeam = ""

    var body: some View {
        Form {
            Section {
                if store.favoriteTeams.isEmpty {
                    Text(L("No favorite teams yet. Turn on “All matches of …” at a match.")).foregroundStyle(Theme.secondary)
                }
                ForEach(store.favoriteTeams.sorted(), id: \.self) { t in
                    HStack(spacing: 12) {
                        SportTeamBadge(name: t)
                        Text(t)
                        Spacer()
                        Button(role: .destructive) { center.setFavoriteTeam(t, false, playlists: playlists) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.alert)
                        .accessibilityLabel(L("Remove"))
                    }
                }
                #if !os(tvOS)
                HStack {
                    TextField(L("Team name"), text: $newTeam)
                        .onSubmit(addTeam)
                    Button(L("Add"), action: addTeam).disabled(Sport173.cleanTeam(newTeam).count < 2)
                }
                #endif
            } header: { Text(L("Teams")) }
            Section {
                ForEach(Sport173.competitions, id: \.id) { c in
                    Toggle(c.name, isOn: Binding(get: { store.favoriteCompetitions.contains(c.id) },
                                                 set: { center.setFavoriteCompetition(c.id, $0, playlists: playlists) }))
                        .tint(Theme.red)
                }
            } header: { Text(L("Competitions")) } footer: {
                Text(L("Matches of your teams and competitions get a reminder automatically."))
            }
        }
        .navigationTitle(L("My teams and competitions"))
    }

    private func addTeam() {
        let t = Sport173.cleanTeam(newTeam)
        guard t.count >= 2 else { return }
        center.setFavoriteTeam(t, true, playlists: playlists)
        newTeam = ""
    }
}
