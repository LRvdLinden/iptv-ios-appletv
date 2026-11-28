import SwiftUI

/// Build 164: de tv-gids in NL-Ziet-stijl (ontwerp "Bingr tv-gids"): een lijst per zender met live beeld bovenaan
/// (iPhone), zenderkolommen met een live NU-kaart (Apple TV) of een groot live voorbeeld met zenderkolommen
/// (iPad en Mac). De pure logica (dagbalk, NU, instelling, stilstaande beelden) staat in Shared/Account/Build164.swift.
///
/// De gids leest per zender alleen het stuk van de gekozen dag (binair zoeken op begintijd), de lijsten zijn lazy.
/// Hooguit één live voorbeeld tegelijk (`ChannelPreview`, telt mee voor de streamlimiet).
struct GuideGridView: View {
    /// Alle zenders van de gekozen groep (kinderprofiel: al gefilterd; verborgen categorieën en zenders van andere
    /// servers zoals in de lijst)
    let channels: [Channel]
    var onPlay: (Channel) -> Void
    var onProgram: (Channel, EPGProgram) -> Void
    /// Niet meer gebruikt (het voorbeeld zit nu in de gids zelf); blijft voor de aanroep in Live TV
    var onSelect: ((Channel) -> Void)? = nil
    /// Build 166 (Apple TV): knoppen van Live TV links (Categorie, Zoeken) en rechts (Lijst) in de regel met de dagpillen
    var tvLeading: AnyView? = nil
    var tvTrailing: AnyView? = nil

    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    #if os(iOS)
    /// Build 179 (iPhone Duo): telefoon- of brede gids per size class (niet per apparaat)
    @Environment(\.horizontalSizeClass) private var guideHSize
    #endif
    @State private var now = Date()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var selectedID: String?
    /// Build 129: programma's van zenders van een andere server ("<server-id>|<zender-id>" → programma's)
    @State private var foreignPrograms: [String: [EPGProgram]] = [:]
    /// Build 166: de dagen waarvoor er gids-info is (nil = nog niet bepaald: alleen vandaag)
    @State private var availableDays: [Date]?
    /// Build 177: programma's per zender en dag, één keer berekend (op volgorde, zonder dubbelen)
    @State private var cache = GuideDayCache177()
    /// Build 177: telt op bij elke nieuwe gids van andere servers (voor de cache)
    @State private var foreignVersion = 0
    /// Build 178: de gids met archief per zender (Xtream `get_simple_data_table`, "<server>|<zender>" → programma's)
    @State private var archive: [String: [EPGProgram]] = [:]
    @State private var archiveVersion = 0

    private var preview: ChannelPreview { ChannelPreview.shared }
    private var selected: Channel? {
        channels.first(where: { $0.id == selectedID && $0.sourceID == selectedSource }) ?? channels.first
    }
    @State private var selectedSource: UUID?

    private func isForeign(_ c: Channel) -> Bool { c.sourceID != nil && c.sourceID != playlists.source?.id }
    private func foreignKey(_ c: Channel) -> String { (c.sourceID?.uuidString ?? "") + "|" + c.id }
    /// Zenders van andere servers (per server bij elkaar: elke gids wordt zo maar één keer gelezen); hooguit 60
    private var foreignShown: [Channel] {
        Array(channels.filter(isForeign).prefix(60)).sorted { ($0.sourceID?.uuidString ?? "") < ($1.sourceID?.uuidString ?? "") }
    }

    /// Build 178: het grootste aantal terugkijkdagen van de zenders in de lijst (hooguit 14 in de dagbalk)
    private var maxCatchup: Int { channels.lazy.map(\.catchupDays).max() ?? 0 }
    /// Build 166: daarvan alleen de dagen met gids-info (`GuideAvailableDays166`); vandaag staat er altijd
    private var days: [Date] {
        availableDays ?? [Calendar.current.startOfDay(for: now)]
    }
    /// Wanneer de beschikbare dagen opnieuw bepaald worden: andere lijst, andere zenders, nieuwe dag of gids
    private var daysKey: String {
        "\(playlists.libraryVersion)|\(playlists.library.epg.count)|\(foreignPrograms.count)|\(channels.count)|\(Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970))|"
            + channels.prefix(GuideAvailableDays166.sampleSize).map(foreignKey).joined(separator: ",")
    }
    private var isToday: Bool { GuideDays164.label(day, today: now) == .today }

    /// Programma's van een zender op de gekozen dag (binair zoeken; andere servers uit hun eigen gids). Build 177: op
    /// volgorde en zonder dubbelen (`Build177.clean`), per zender en dag één keer berekend; opnieuw na een nieuwe gids.
    func programs(_ c: Channel) -> [EPGProgram] {
        let key = foreignKey(c) + "#" + String(Int(day.timeIntervalSince1970))
        let version = "\(playlists.epgVersion)|\(foreignVersion)|\(archiveVersion)|\(c.epgID ?? "")"
        return cache.programs(key, version: version) {
            let w = GuideDays164.window(day)
            var raw: [EPGProgram]
            if isForeign(c) {
                raw = (foreignPrograms[foreignKey(c)] ?? []).filter { $0.end > w.from && $0.start < w.to }
            } else {
                raw = playlists.library.programs(c, from: w.from, to: w.to)
            }
            // build 178: programma's van vroeger uit het archief van de server erbij (met has_archive)
            if let a = archive[foreignKey(c)], !a.isEmpty {
                raw = GuideArchive178.merged(raw, a.filter { $0.end > w.from && $0.start < w.to })
            }
            return GuideDayCache177.clean(raw)
        }
    }

    var body: some View {
        // de gids van andere servers hoort bij deze weergave (de schermen hieronder lezen hem via `programs`)
        let _ = foreignPrograms.count
        layout
            .background(Color.black)
            .task(id: foreignShown.map(foreignKey)) { await loadForeign() }
            .task(id: daysKey) { await loadDays() }
            .task(id: archiveKey) { await loadArchive() }
            .task {
                // build 177: op elke hele minuut (programma's beginnen op hele minuten), niet om de 30 seconden
                while !Task.isCancelled {
                    let wait = Build177.secondsToNextMinute(Date().timeIntervalSince1970)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
            .onAppear {
                if !days.contains(day) { day = Calendar.current.startOfDay(for: Date()) }
            }
            // gids verlaten (bijv. terug naar de lijst): het voorbeeld stoppen
            .onDisappear { preview.stop() }
    }

    @ViewBuilder private var layout: some View {
        #if os(tvOS)
        TVGuide(guide: self, channels: channels, day: $day, days: days, now: now)
        #elseif os(iOS)
        if guideHSize == .compact {
            PhoneGuide(guide: self, channels: channels, day: $day, days: days, now: now,
                       selected: selected, select: { pick($0) })
        } else {
            WideGuide(guide: self, channels: channels, day: $day, days: days, now: now,
                      selected: selected, select: { pick($0) })
        }
        #else
        WideGuide(guide: self, channels: channels, day: $day, days: days, now: now,
                  selected: selected, select: { pick($0) })
        #endif
    }

    private func pick(_ c: Channel) {
        selectedID = c.id
        selectedSource = c.sourceID
    }

    // MARK: acties (gedeeld door de drie schermen)

    /// Live voorbeeld van deze zender starten (hooguit één tegelijk). `tap`: op mobiel netwerk pas na een tik.
    func startPreview(_ c: Channel, delay: Double, tap: Bool = false) {
        preview.select(c, playlists: playlists, delay: delay, floating: false, handoff: true, userInitiated: tap)
    }

    /// Volledig scherm met dezelfde stream als het kan, anders gewoon afspelen.
    func fullscreen(_ c: Channel) {
        if let ctrl = preview.takeForFullscreen(c) {
            CloudStore.shared.pushRecentChannel(c.sourceID ?? playlists.source?.id ?? UUID(), c.id)
            app.playHandoff(ctrl, zap: channels)
        } else {
            onPlay(c)
        }
    }

    /// Build 178: een voorbij programma dat terug te kijken is speelt meteen af vanaf het begin (zoals NLZIET); de rest
    /// opent het programmablad
    func openProgram(_ c: Channel, _ p: EPGProgram) {
        if case .past(replay: true) = GuideArchive178.state(p, c, Date()), let u = playlists.catchupURL(c, p) {
            preview.stop()
            app.play(PlayableItem.replay(channel: c, program: p, url: u))
            return
        }
        onProgram(c, p)
    }

    /// Vanaf het begin (terugkijken van het lopende programma), zoals in het programmablad
    func fromStart(_ c: Channel, _ p: EPGProgram) -> (() -> Void)? {
        guard c.catchupDays > 0, let u = playlists.catchupURL(c, p) else { return nil }
        return {
            app.play(PlayableItem.replay(channel: c, program: p, url: u))
        }
    }

    static func dayTitle(_ d: Date, today: Date) -> String {
        switch GuideDays164.label(d, today: today) {
        case .yesterday: return L("Yesterday")
        case .today: return L("Today")
        case .tomorrow: return L("Tomorrow")
        case .other: return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// Build 178: voor welke zenders het archief geladen wordt: de gekozen zender en de eerste 12 met terugkijken,
    /// niet voor dagen in de toekomst
    private var archiveChannels: [Channel] {
        guard day <= Calendar.current.startOfDay(for: now) else { return [] }
        var out: [Channel] = []
        if let s = selected, s.catchupDays > 0 { out.append(s) }
        for c in channels where c.catchupDays > 0 && out.count < 12 {
            if !out.contains(where: { $0.id == c.id && $0.sourceID == c.sourceID }) { out.append(c) }
        }
        return out
    }
    private var archiveKey: String {
        "\(Int(day.timeIntervalSince1970))|" + archiveChannels.map(foreignKey).joined(separator: ",")
    }

    /// Build 178: het archief van de server ophalen (Xtream; hooguit 20 minuten oud, zie `PlaylistService.archiveEPG`)
    private func loadArchive() async {
        for c in archiveChannels {
            let k = foreignKey(c)
            let list = await playlists.archiveEPG(c)
            guard !Task.isCancelled else { return }
            if !list.isEmpty, archive[k] != list {
                archive[k] = list
                archiveVersion &+= 1
            }
        }
    }

    /// Build 166: welke dagen gids-info hebben, buiten de hoofdthread. Steekproef: de eerste 50 zenders van de lijst
    /// mét gids (gezocht in de eerste 400, zodat een info- of radiozender zonder gids bovenaan niet alles leeg maakt;
    /// zenders van andere servers uit hun eigen gids). Build 178: terug tot de terugkijktermijn van de zenders (ook
    /// zonder gids van die dag: die komt uit het archief), vooruit de dagen met gids (hooguit 7).
    private func loadDays() async {
        let today = now
        let back = maxCatchup
        let sample = Array(channels.prefix(GuideAvailableDays166.scanLimit))
        let epg = playlists.library.epg
        let foreign = foreignPrograms
        let own = playlists.source?.id
        let result = await Task.detached(priority: .utility) { () -> [Date] in
            var samples: [GuideSample166] = []
            for c in sample where samples.count < GuideAvailableDays166.sampleSize {
                let other = c.sourceID != nil && c.sourceID != own
                var list = other ? (foreign[(c.sourceID?.uuidString ?? "") + "|" + c.id] ?? []) : (epg[c.epgID ?? c.id] ?? [])
                guard !list.isEmpty else { continue }
                if other { list.sort { $0.start < $1.start } }
                samples.append(GuideSample166(starts: list.map(\.start), ends: list.map(\.end), catchupDays: c.catchupDays))
            }
            let cal = Calendar.current
            let start = cal.startOfDay(for: today)
            let future = (1...Build178.maxAhead).filter { off in
                guard let d = cal.date(byAdding: .day, value: off, to: start) else { return false }
                let w = GuideDays164.window(d)
                return samples.contains { $0.hasProgram(from: w.from, to: w.to) }
            }
            return Build178.dayOffsets(maxCatchupDays: back, futureWithGuide: future)
                .compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }.value
        guard !Task.isCancelled else { return }
        if result != availableDays { availableDays = result }
        let keep = GuideAvailableDays166.keep(day, in: result, today: today)
        if keep != day { day = keep }
    }

    /// Build 129: de gids van zenders van een andere server (zoals in het gidsblad, `PlaylistService.foreignEPG`);
    /// alleen het stuk van de dagbalk bewaren, zodat het geheugen klein blijft.
    private func loadForeign() async {
        let list = foreignShown
        guard !list.isEmpty else { if !foreignPrograms.isEmpty { foreignPrograms = [:]; foreignVersion &+= 1 }; return }
        let back = Double(min(max(1, list.map(\.catchupDays).max() ?? 0), Build178.maxBack) + 1)
        let from = Date().addingTimeInterval(-back * 86400), to = Date().addingTimeInterval(Double(GuideDays164.ahead + 1) * 86400)
        var out: [String: [EPGProgram]] = [:]
        for (i, c) in list.enumerated() {
            let k = foreignKey(c)
            if let have = foreignPrograms[k] { out[k] = have; continue }
            let progs = await playlists.foreignEPG(c)
            guard !Task.isCancelled else { return }
            // build 177: op begintijd gesorteerd bewaren
            out[k] = progs.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
            if i + 1 < list.count, list[i + 1].sourceID != c.sourceID {
                foreignPrograms.merge(out) { _, n in n }
                foreignVersion &+= 1
            }
        }
        if out != foreignPrograms { foreignPrograms = out; foreignVersion &+= 1 }
    }
}

// MARK: - build 177: programma's per zender en dag

/// De programma's per zender en dag, één keer berekend: de gids rekende ze bij elke weergave opnieuw uit, voor elke
/// kolom (ook bij elke tik van de klok of een wijziging van het voorbeeld). Een nieuwe gids (andere `version`) of een
/// volle cache begint opnieuw. Geen ObservableObject: de cache zelf geeft nooit een nieuwe weergave. Alleen vanuit de
/// weergave (hoofdthread) gebruiken.
final class GuideDayCache177 {
    private var store: [String: (version: String, programs: [EPGProgram])] = [:]
    static let limit = 800

    func programs(_ key: String, version: String, make: () -> [EPGProgram]) -> [EPGProgram] {
        if let hit = store[key], hit.version == version { return hit.programs }
        if store.count >= Self.limit { store.removeAll(keepingCapacity: true) }
        let p = make()
        store[key] = (version, p)
        return p
    }

    /// Op volgorde en zonder dubbelen (`Build177.clean`): samengevoegde programma's krijgen het langste einde, een
    /// programma dat kort overlapt met het vorige begint pas als dat afloopt.
    static func clean(_ list: [EPGProgram]) -> [EPGProgram] {
        guard list.count > 1 else { return list }
        let c = Build177.clean(titles: list.map(\.title), starts: list.map { $0.start.timeIntervalSince1970 },
                               ends: list.map { $0.end.timeIntervalSince1970 })
        return c.map { x in
            var p = list[x.index]
            p.start = Date(timeIntervalSince1970: x.start)
            p.end = Date(timeIntervalSince1970: x.end)
            return p
        }
    }
}

// MARK: - gedeelde onderdelen

/// NU / voorbij / later van een programma, met de terugkijkdagen van de zender (build 178: en has_archive)
private func guideState(_ p: EPGProgram, _ c: Channel, _ now: Date) -> GuideState164 {
    GuideArchive178.state(p, c, now)
}

/// Build 178: terugkijken in de gids (pure regels in Shared/Account/Build178.swift)
enum GuideArchive178 {
    static func state(_ p: EPGProgram, _ c: Channel, _ now: Date) -> GuideState164 {
        if p.start <= now && now < p.end { return .now }
        if p.end <= now {
            return .past(replay: Build178.replayable(start: p.start.timeIntervalSince1970, end: p.end.timeIntervalSince1970,
                                                     now: now.timeIntervalSince1970, catchupDays: c.catchupDays, archive: p.archive))
        }
        return .future
    }

    /// Gids en archief samen (zelfde begin = zelfde programma, met has_archive uit het archief)
    static func merged(_ guide: [EPGProgram], _ archive: [EPGProgram]) -> [EPGProgram] {
        guard !archive.isEmpty else { return guide }
        let slots = Build178.merge(guide: guide.map { (title: $0.title, start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) },
                                   archive: archive.map { (title: $0.title, start: $0.start.timeIntervalSince1970,
                                                           end: $0.end.timeIntervalSince1970, archive: $0.archive) })
        return slots.map { x in
            var p = x.source >= 0 ? guide[x.source] : archive[-1 - x.source]
            if x.source >= 0, let a = x.archive { p.archive = a }
            return p
        }
    }
}

private func isPast(_ s: GuideState164) -> Bool { if case .past = s { return true }; return false }

/// Index van NU in een lijst programma's (binair zoeken)
private func nowIndex(_ progs: [EPGProgram], _ now: Date) -> Int? {
    GuideNow164.index(starts: progs.map(\.start), ends: progs.map(\.end), now: now)
}

/// Het live vak: het voorbeeld van deze zender als dat speelt, anders het stilstaande beeld of het logo.
private struct GuideLiveImage: View {
    let channel: Channel
    /// Build 166 (Apple TV): zonder beeld het logo los op het donkere vlak (geen kader in een kader)
    var plainLogo = false
    @ObservedObject private var preview = ChannelPreview.shared

    private var live: PlayerController? {
        guard preview.channel?.id == channel.id, preview.channel?.sourceID == channel.sourceID, !preview.blocked else { return nil }
        return preview.controller
    }

    var body: some View {
        ZStack {
            GuideStillView(channel: channel, plainLogo: plainLogo)
            if let ctrl = live {
                EngineView(controller: ctrl)
                PreviewStatus(controller: ctrl)
            }
        }
        .clipped()
    }
}

/// Is dit het live voorbeeld dat nu speelt?
private struct LiveFlag: View {
    let channel: Channel
    @ObservedObject private var preview = ChannelPreview.shared
    @ObservedObject private var stills = GuideStills.shared
    var body: some View {
        let playing = preview.channel?.id == channel.id && preview.controller != nil && !preview.blocked
        if playing {
            tag(L("Playing without sound"), color: .white)
        } else if let d = stills.savedDate(GuideStills.key(channel)), GuideStillPolicy164.isFresh(savedAt: d, now: Date()) {
            tag(L("Image from %@", TimeText.short(d)), color: Theme.secondary)
        }
    }
    private func tag(_ s: String, color: Color) -> some View {
        Text(s).font(.system(size: tvScaled(11), weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text(L("LIVE")).font(.system(size: tvScaled(11), weight: .heavy)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.red, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ProgressLine: View {
    let value: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x333333))
                Capsule().fill(Theme.red).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Een pil in de dagbalk
private struct DayPill: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: tvScaled(14), weight: on ? .heavy : .regular))
                .foregroundStyle(on ? Color.black : Theme.secondary)
                .padding(.horizontal, tvScaled(16)).frame(height: tvScaled(40))
                .background(on ? Color.white : Color(hex: 0x1C1C1C), in: Capsule())
        }
        .plainTVButton()
    }
}

private struct DayBar: View {
    @Binding var day: Date
    let days: [Date]
    let now: Date
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tvScaled(8)) {
                    ForEach(days, id: \.self) { d in
                        DayPill(title: GuideGridView.dayTitle(d, today: now), on: d == day) { day = d }.id(d)
                    }
                }
                .padding(.vertical, tvScaled(6))
                #if os(tvOS)
                .padding(.horizontal, 10)   // ruimte voor de tv-lift van de eerste en laatste pil
                #endif
            }
            .onAppear { proxy.scrollTo(day, anchor: .center) }
            // build 166: de dagen komen pas na het bepalen van de gids-info
            .onChange(of: days) { _, _ in proxy.scrollTo(day, anchor: .center) }
        }
    }
}

#if os(iOS)
// MARK: - iPhone

private struct PhoneGuide: View {
    let guide: GuideGridView
    let channels: [Channel]
    @Binding var day: Date
    let days: [Date]
    let now: Date
    let selected: Channel?
    let select: (Channel) -> Void
    @ObservedObject private var preview = ChannelPreview.shared
    @EnvironmentObject var playlists: PlaylistService
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        VStack(spacing: 0) {
            if let c = selected {
                liveBox(c)
                nowInfo(c)
                HStack(spacing: 0) {
                    rail(c)
                    programList(c)
                }
            } else {
                Text(L("No channels.")).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if let c = selected { guide.startPreview(c, delay: 0.4) } }
        .onChange(of: selected?.id) { _, _ in if let c = selected { guide.startPreview(c, delay: 0.5) } }
        // kantelen = volledig scherm met dezelfde stream
        .onChange(of: vSize) { _, v in if v == .compact, let c = selected { guide.fullscreen(c) } }
    }

    private func liveBox(_ c: Channel) -> some View {
        let isLive = preview.channel?.id == c.id && preview.controller != nil && !preview.blocked
        return ZStack {
            GuideLiveImage(channel: c)
            if !isLive && !preview.blocked && !preview.allowed && preview.allowed(userInitiated: true) {
                // mobiel netwerk met "Alleen wifi": pas na een tik
                Button { guide.startPreview(c, delay: 0, tap: true) } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Play live preview"))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color(hex: 0x141414))
        .contentShape(Rectangle())
        .onTapGesture { guide.fullscreen(c) }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                GuideLogo(channel: c).frame(width: 44, height: 30)
                LiveBadge()
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                roundButton(preview.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: preview.soundOn ? L("Sound off") : L("Sound on")) {
                    preview.setSound(!preview.soundOn, playlists: playlists)
                    if preview.controller == nil || preview.channel?.id != c.id { guide.startPreview(c, delay: 0, tap: true) }
                }
                roundButton("arrow.up.left.and.arrow.down.right", label: L("Full screen")) { guide.fullscreen(c) }
            }
            .padding(10)
        }
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func nowInfo(_ c: Channel) -> some View {
        let p = playlists.library.nowPlaying(c, at: now)
        VStack(alignment: .leading, spacing: 6) {
            Text(p.map { CategoryName.display($0.title) } ?? CategoryName.channel(c.name))
                .font(.system(size: 16, weight: .bold)).lineLimit(1)
            HStack(spacing: 10) {
                if let p {
                    Text("\(TimeText.short(p.start)) – \(TimeText.short(p.end))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    ProgressLine(value: GuideNow164.progress(start: p.start, end: p.end, now: now))
                } else {
                    Text(L("No guide information")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Color(hex: 0x1F1F1F)).frame(height: 1), alignment: .bottom)
    }

    private func rail(_ sel: Channel) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(channels) { ch in
                    let on = ch.id == sel.id && ch.sourceID == sel.sourceID
                    Button { select(ch) } label: {
                        GuideLogo(channel: ch).frame(width: 52, height: 36)
                            .frame(width: 76, height: 64)
                            .background(on ? Theme.elevated : Color.clear)
                            .overlay(alignment: .leading) { if on { Rectangle().fill(Theme.red).frame(width: 3) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CategoryName.channel(ch.name))
                }
            }
        }
        .frame(width: 76)
        .background(Color(hex: 0x0D0D0D))
        .overlay(Rectangle().fill(Color(hex: 0x1F1F1F)).frame(width: 1), alignment: .trailing)
    }

    /// Build 177: waar de lijst bovenaan staat: vandaag twee programma's vóór NU (eerder op de dag blijft erboven),
    /// andere dagen bovenaan
    private func anchor(_ progs: [EPGProgram]) -> Int? {
        let col = Build177.column(count: progs.count, nowIndex: nowIndex(progs, now),
                                  firstFuture: progs.firstIndex(where: { $0.start > now }),
                                  today: GuideDays164.label(day, today: now) == .today, nowCard: false)
        return col.anchor
    }

    private func programList(_ c: Channel) -> some View {
        let progs = guide.programs(c)
        let target = anchor(progs)
        return VStack(spacing: 0) {
            Menu {
                ForEach(days, id: \.self) { d in
                    Button(GuideGridView.dayTitle(d, today: now)) { day = d }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(GuideGridView.dayTitle(day, today: now) + " · " + day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    Image(systemName: "calendar").font(.system(size: 13))
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .accessibilityLabel(L("Choose a day"))
            .background(Color(hex: 0x0D0D0D))
            .overlay(Rectangle().fill(Color(hex: 0x1F1F1F)).frame(height: 1), alignment: .bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if progs.isEmpty {
                            Text(L("No guide information")).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 30)
                        }
                        ForEach(Array(progs.enumerated()), id: \.element.id) { i, p in
                            PhoneProgramRow(channel: c, program: p, now: now) { guide.openProgram(c, p) }.id(i)
                        }
                    }
                }
                .onAppear { if let t = target { proxy.scrollTo(t, anchor: .top) } }
                .onChange(of: "\(c.id)|\(day.timeIntervalSince1970)") { _, _ in
                    if let t = anchor(guide.programs(c)) { proxy.scrollTo(t, anchor: .top) }
                }
                // de gids kwam later binnen: dan alsnog naar NU
                .onChange(of: progs.isEmpty) { _, empty in
                    if !empty, let t = anchor(guide.programs(c)) { proxy.scrollTo(t, anchor: .top) }
                }
            }
        }
    }
}

private struct PhoneProgramRow: View {
    let channel: Channel
    let program: EPGProgram
    let now: Date
    let action: () -> Void

    var body: some View {
        let st = guideState(program, channel, now)
        Button(action: action) {
            HStack(spacing: 0) {
                Text(st == .now ? L("NOW") : TimeText.short(program.start))
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(st == .now ? Theme.onAccent : isPast(st) ? Color(hex: 0x8A8A8A) : .white)
                    .frame(width: 62).frame(maxHeight: .infinity)
                    .background(st == .now ? Theme.red : Color.clear)
                HStack(spacing: 8) {
                    Text(CategoryName.display(program.title))
                        .font(.system(size: 15, weight: st == .now ? .bold : .regular)).lineLimit(1)
                        .foregroundStyle(st == .now ? Theme.red : isPast(st) ? Color(hex: 0x8A8A8A) : .white)
                    Spacer(minLength: 0)
                    if st == .past(replay: true) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .accessibilityLabel(L("Catch-up"))
                    }
                    if st == .future && CloudStore.shared.hasReminder(channelID: channel.id, start: program.start) {
                        Image(systemName: "bell").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .accessibilityLabel(L("Reminder set"))
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 54)
            .background(st == .now ? Theme.red.opacity(0.12) : Color.clear)
            .overlay(Rectangle().fill(Color(hex: 0x1A1A1A)).frame(height: 1), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif

#if !os(tvOS)
// MARK: - iPad en Mac

private struct WideGuide: View {
    let guide: GuideGridView
    let channels: [Channel]
    @Binding var day: Date
    let days: [Date]
    let now: Date
    let selected: Channel?
    let select: (Channel) -> Void
    @EnvironmentObject var playlists: PlaylistService

    /// Build 177: kopregel, live voorbeeld en tussenruimte boven de kolommen (voor de hoogte van de kolommen):
    /// marge 2 × 24, kop 44, voorbeeld 248, tussenruimte 2 × 18 en 8 voor de schuifbalk
    private static let chrome: CGFloat = 384
    private static let heroBlock: CGFloat = 266

    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Text(L("TV guide")).font(.system(size: 26, weight: .heavy))
                        Spacer(minLength: 8)
                        DayBar(day: $day, days: days, now: now).frame(maxWidth: 760)
                    }
                    if let c = selected { hero(c) }
                    columns(height: columnsHeight(g.size.height))
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
            }
        }
        .onAppear { if let c = selected { guide.startPreview(c, delay: 0.4) } }
        .onChange(of: selected?.id) { _, _ in if let c = selected { guide.startPreview(c, delay: 0.5) } }
    }

    /// Build 177: elke kolom scrolt zelf (de hele dag), zo hoog als er plaats is (minstens 320)
    private func columnsHeight(_ total: CGFloat) -> CGFloat {
        let chrome: CGFloat = selected == nil ? Self.chrome - Self.heroBlock : Self.chrome
        return max(320, total - chrome)
    }

    private func columns(height: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(channels) { ch in column(ch) }
            }
            .padding(.bottom, 8)
        }
        .frame(height: height)
    }

    private func hero(_ c: Channel) -> some View {
        let p = playlists.library.nowPlaying(c, at: now)
        let next = playlists.library.upcoming(c, count: 3, now: now).first(where: { $0.start >= (p?.end ?? now) })
        return HStack(alignment: .center, spacing: 24) {
            Button { guide.fullscreen(c) } label: {
                GuideLiveImage(channel: c)
                    .frame(width: 440, height: 248)
                    .overlay(alignment: .topLeading) { LiveBadge().padding(12) }
                    .overlay(alignment: .topTrailing) { LiveFlag(channel: c).padding(12) }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("%@ · now", CategoryName.channel(c.name))).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.secondary)
                Text(p.map { CategoryName.display($0.title) } ?? L("No guide information"))
                    .font(.system(size: 30, weight: .heavy)).lineLimit(2)
                if let p {
                    let left = GuideNow164.minutesLeft(end: p.end, now: now)
                    let parts = ["\(TimeText.short(p.start)) – \(TimeText.short(p.end))", L("%d min left", left)]
                        + (next.map { [L("Next: %@", CategoryName.display($0.title))] } ?? [])
                    Text(parts.joined(separator: " · ")).font(.system(size: 15)).foregroundStyle(Theme.secondary).lineLimit(1)
                    ProgressLine(value: GuideNow164.progress(start: p.start, end: p.end, now: now), height: 4).frame(maxWidth: 360)
                }
                HStack(spacing: 10) {
                    Button { guide.fullscreen(c) } label: {
                        Text(L("Watch live")).font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
                            .padding(.horizontal, 20).frame(height: 44).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    if let p, let start = guide.fromStart(c, p) {
                        Button(action: start) {
                            Text(L("From the start")).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 20).frame(height: 44).background(Color(hex: 0x2A2A2A), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.vertical, 24).padding(.trailing, 24)
            Spacer(minLength: 0)
        }
        .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Build 177: altijd de hele dag; vandaag staat de kolom bij openen op twee programma's vóór NU (eerder op de dag
    /// blijft erboven), andere dagen bovenaan
    private func anchor(_ progs: [EPGProgram]) -> Int? {
        Build177.column(count: progs.count, nowIndex: nowIndex(progs, now),
                        firstFuture: progs.firstIndex(where: { $0.start > now }),
                        today: GuideDays164.label(day, today: now) == .today, nowCard: false).anchor
    }

    private func column(_ ch: Channel) -> some View {
        let on = selected.map { $0.id == ch.id && $0.sourceID == ch.sourceID } ?? false
        let progs = guide.programs(ch)
        let target = anchor(progs)
        return VStack(alignment: .leading, spacing: 4) {
            Button { select(ch) } label: {
                GuideLogo(channel: ch).frame(width: 90, height: 34)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(on ? Color(hex: 0x2A2A2A) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) { if on { Rectangle().fill(Theme.red).frame(height: 3) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CategoryName.channel(ch.name))
            if progs.isEmpty {
                Text(L("No guide information")).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(10)
            }
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(progs.enumerated()), id: \.element.id) { i, p in
                    let st = guideState(p, ch, now)
                    Button { guide.openProgram(ch, p) } label: {
                        HStack(spacing: 8) {
                            Text(st == .now ? L("NOW") : TimeText.short(p.start)).font(.system(size: 14, weight: .bold).monospacedDigit())
                                .frame(width: 48, alignment: .leading)
                            Text(CategoryName.display(p.title)).font(.system(size: 14, weight: st == .now ? .bold : .regular)).lineLimit(1)
                            Spacer(minLength: 0)
                            if st == .past(replay: true) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)) }
                            if st == .future && CloudStore.shared.hasReminder(channelID: ch.id, start: p.start) {
                                Image(systemName: "bell").font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(st == .now ? Theme.onAccent : isPast(st) ? Color(hex: 0x8A8A8A) : Color(hex: 0xE6E6E6))
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(st == .now ? Theme.red : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(i)
                }
            }
            }
            .onAppear { if let t = target { proxy.scrollTo(t, anchor: .top) } }
            .onChange(of: day) { _, _ in if let t = anchor(guide.programs(ch)) { proxy.scrollTo(t, anchor: .top) } }
            .onChange(of: progs.isEmpty) { _, empty in
                if !empty, let t = anchor(guide.programs(ch)) { proxy.scrollTo(t, anchor: .top) }
            }
            }
        }
        .frame(width: 220)
    }
}
#endif

#if os(tvOS)
// MARK: - Apple TV

/// Build 166: de gids over de hele breedte (binnen de veilige marge), zonder zijkolom. Bovenaan één regel met
/// Categorie en Zoeken (van Live TV), de dagpillen en rechts Lijst. Kolommen van 270 pt: ±6 zenders op 1920 breed.
///
/// Build 177: elke kolom toont de hele dag en scrolt zelf. Vandaag staat elke kolom bij openen (en bij een andere
/// dag) op twee programma's vóór NU, zodat de NU-kaarten naast elkaar staan; de focus gaat bij het binnenkomen van
/// een kolom naar de NU-kaart (andere dagen het eerste programma), en omhoog gaat naar eerder op de dag.
private struct TVGuide: View {
    let guide: GuideGridView
    let channels: [Channel]
    @Binding var day: Date
    let days: [Date]
    let now: Date
    @FocusState private var focus: String?

    static let columnWidth: CGFloat = 270
    static let columnSpacing: CGFloat = 22
    /// Ruimte rond de regels binnen een kolom voor de tv-lift (een kolom knipt zelf af)
    static let lift: CGFloat = 10

    var body: some View {
        let today = GuideDays164.label(day, today: now) == .today
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                if let l = guide.tvLeading { l }
                DayBar(day: $day, days: days, now: now).frame(maxWidth: .infinity, alignment: .leading)
                if let t = guide.tvTrailing { t }
            }
            .focusSection()
            ScrollView(.horizontal, showsIndicators: false) {
                // lazy: op de Apple TV niet honderden kolommen tegelijk opbouwen
                LazyHStack(alignment: .top, spacing: Self.columnSpacing - 2 * Self.lift) {
                    ForEach(channels) { ch in
                        TVColumn(guide: guide, channel: ch, day: day, today: today,
                                 programs: guide.programs(ch), now: now, focus: $focus)
                    }
                }
            }
            // de tv-lift en schaduw van de kaarten aan de zijkant niet afknippen
            .scrollClipDisabled()
            .focusSection()
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct TVColumn: View {
    let guide: GuideGridView
    let channel: Channel
    let day: Date
    let today: Bool
    let programs: [EPGProgram]
    let now: Date
    var focus: FocusState<String?>.Binding

    private var width: CGFloat { TVGuide.columnWidth }
    private var lift: CGFloat { TVGuide.lift }
    private var columnKey: String { (channel.sourceID?.uuidString ?? "") + "|" + channel.id }
    /// Focussleutel van een regel: vast per programma (en "now" voor de kaart), zodat de focus blijft staan als NU
    /// verspringt
    private func key(_ row: Build177.Row) -> String {
        switch row {
        case .now: return columnKey + "#now"
        case .program(let i): return columnKey + "#" + (i < programs.count ? programs[i].id : String(i))
        }
    }

    private var layout: Build177.Column {
        Build177.column(count: programs.count, nowIndex: today ? nowIndex(programs, now) : nil,
                        firstFuture: programs.firstIndex(where: { $0.start > now }), today: today, nowCard: true)
    }

    var body: some View {
        let col = layout
        VStack(alignment: .leading, spacing: 8) {
            header.padding(.horizontal, lift)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // geen lazy stack: de focus moet het programma erboven kunnen vinden (hooguit een dag per kolom)
                    VStack(alignment: .leading, spacing: 4) {
                        if col.rows.isEmpty {
                            Text(L("No guide information")).font(.system(size: 19)).foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 8)
                        }
                        ForEach(Array(col.rows.enumerated()), id: \.offset) { r, row in
                            switch row {
                            case .now(let i):
                                nowCard(i.map { programs[$0] }, key: key(row)).id(r)
                            case .program(let i):
                                line(programs[i], dim: isPast(guideState(programs[i], channel, now)), key: key(row)).id(r)
                            }
                        }
                    }
                    .padding(lift)
                }
                // de focus komt bij het binnenkomen van de kolom op NU (andere dagen op het eerste programma)
                .defaultFocus(focus, col.focus.map { key(col.rows[$0]) } ?? "", priority: .userInitiated)
                .focusSection()
                .onAppear { scroll(proxy, col.anchor) }
                .onChange(of: day) { _, _ in scroll(proxy, layout.anchor) }
                .onChange(of: programs.isEmpty) { _, _ in scroll(proxy, layout.anchor) }
            }
        }
        .frame(width: width + 2 * lift, alignment: .top)
    }

    /// Naar het anker scrollen, maar niet als de focus al in deze kolom staat (anders vechten scrollen en focus)
    private func scroll(_ proxy: ScrollViewProxy, _ anchor: Int?) {
        guard let a = anchor else { return }
        if let f = focus.wrappedValue, f.hasPrefix(columnKey + "#") { return }
        proxy.scrollTo(a, anchor: .top)
    }

    /// Kolomkop: compact (56 pt), het logo op een donker vlak met een dunne rand, of de opgeschoonde naam
    private var header: some View {
        GuideLogo(channel: channel)
            .frame(width: width, height: 56)
            .accessibilityLabel(CategoryName.channel(channel.name))
    }

    private func line(_ p: EPGProgram, dim: Bool, key: String) -> some View {
        let st = guideState(p, channel, now)
        return Button { guide.openProgram(channel, p) } label: {
            HStack(spacing: 12) {
                Text(TimeText.short(p.start)).font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundStyle(dim ? Color(hex: 0x8A8A8A) : Theme.secondary).frame(width: 64, alignment: .leading)
                Text(CategoryName.display(p.title)).font(.system(size: 19)).lineLimit(1)
                    .foregroundStyle(dim ? Color(hex: 0x8A8A8A) : Color(hex: 0xE6E6E6))
                Spacer(minLength: 0)
                if st == .past(replay: true) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 15)).foregroundStyle(Theme.secondary) }
                if st == .future && CloudStore.shared.hasReminder(channelID: channel.id, start: p.start) {
                    Image(systemName: "bell").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVLiftStyle(scale: 1.04, dimWhenIdle: false))
        .focused(focus, equals: key)
    }

    /// De NU-kaart: het beeld (live, stilstaand of logo) van rand tot rand bovenaan (16:9), LIVE linksboven, daaronder
    /// de tijd in de accentkleur, de titel en de voortgang. Focus = tv-lift en schaduw; na ±1 s live zonder geluid;
    /// OK = volledig scherm.
    private func nowCard(_ p: EPGProgram?, key: String) -> some View {
        Button { guide.fullscreen(channel) } label: {
            VStack(alignment: .leading, spacing: 0) {
                GuideLiveImage(channel: channel, plainLogo: true)
                    .frame(width: width, height: (width * 9 / 16).rounded())
                    .overlay(alignment: .topLeading) { LiveBadge().padding(10) }
                    .overlay(alignment: .bottomTrailing) { LiveFlag(channel: channel).padding(8) }
                VStack(alignment: .leading, spacing: 6) {
                    if let p {
                        Text("\(TimeText.short(p.start)) – \(TimeText.short(p.end))")
                            .font(.system(size: 18, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.red)
                    }
                    Text(p.map { CategoryName.display($0.title) } ?? CategoryName.channel(channel.name))
                        .font(.system(size: 21, weight: .bold)).lineLimit(1).foregroundStyle(.white)
                    if let p { ProgressLine(value: GuideNow164.progress(start: p.start, end: p.end, now: now), height: 4).padding(.top, 2) }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width)
            .background(Color(hex: 0x1A1A1A))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .background(FocusProbe { f in
                if f { guide.startPreview(channel, delay: 1.0) } else { ChannelPreview.shared.release(channel) }
            })
        }
        .buttonStyle(TVLiftStyle(scale: 1.06, dimWhenIdle: false))
        .focused(focus, equals: key)
        .padding(.vertical, 4)
    }
}
#endif


/// Details van een programma: kijken, terugkijken of herinnering zetten.
struct ProgramSheet: View {
    let channel: Channel
    let program: EPGProgram
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playlists: PlaylistService
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var editOffset = false

    /// Herinnering van het actieve profiel (elk profiel heeft zijn eigen herinneringen)
    private var reminderID: String { store.reminderID(channelID: channel.id, start: program.start) }
    private var canCatchup: Bool {
        if case .past(replay: true) = GuideArchive178.state(program, channel, Date()) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(14)) {
            Text(channel.name).font(.system(size: tvScaled(13), weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(CategoryName.display(program.title)).font(.system(size: tvScaled(24), weight: .bold))
            HStack(spacing: tvScaled(10)) {
                Text("\(program.start.formatted(date: .abbreviated, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(Theme.secondary)
                if channel.catchupDays > 0, let pid = channel.sourceID ?? playlists.source?.id {
                    let off = store.catchupOffset(pid, channel.id)
                    Button { editOffset = true } label: {
                        Label(off == 0 ? L("Catch-up offset") : L("Offset %@ min", (off > 0 ? "+" : "−") + "\(abs(off))"),
                              systemImage: "clock.badge.questionmark")
                            .font(.system(size: tvScaled(12), weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .plainTVButton()
                }
            }
            if let d = program.description { Text(d).font(.system(size: tvScaled(14))).foregroundStyle(.white.opacity(0.85)) }
            HStack(spacing: tvScaled(14)) {
                if program.isNow {
                    NetflixButton(title: L("Watch live"), icon: "play.fill", kind: .play) {
                        dismiss(); app.play(Playables.channel(channel, now: program), zap: playlists.library.channels)
                    }
                } else if canCatchup, let u = playlists.catchupURL(channel, program) {
                    NetflixButton(title: L("Watch from the start"), icon: "clock.arrow.circlepath", kind: .play) {
                        dismiss()
                        app.play(PlayableItem.replay(channel: channel, program: program, url: u))
                    }
                } else if program.start > Date() {
                    let on = store.hasReminder(reminderID)
                    NetflixButton(title: on ? L("Reminder set") : L("Remind me"), icon: on ? "bell.slash" : "bell", kind: on ? .secondary : .primary) {
                        if on { ReminderCenter.shared.remove(reminderID) }
                        else if let pid = channel.sourceID ?? playlists.source?.id {
                            Task { await ReminderCenter.shared.add(channel: channel, program: program, playlist: pid) }
                        }
                    }
                }
                if program.isNow, channel.catchupDays > 0, let u = playlists.catchupURL(channel, program) {
                    NetflixButton(title: L("From the start"), icon: "backward.end.fill", kind: .secondary) {
                        dismiss()
                        app.play(PlayableItem.replay(channel: channel, program: program, url: u))
                    }
                }
            }
            Spacer()
        }
        .padding(Theme.edge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x141414).ignoresSafeArea())
        #if !os(tvOS)
        .presentationDetents([.medium])
        #endif
        .sheet(isPresented: $editOffset) { CatchupOffsetSheet(channel: channel) }
    }
}
