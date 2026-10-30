import SwiftUI
import Charts

/// Mijn Bingr → Statistieken (build 68): kijkstatistieken per week, maand of jaar, zoals bij Trakt.
/// Gegevens komen van device-auth `watch_stats` (zie docs/ACCOUNT.md). Het hoofdprofiel kan per profiel
/// filteren (of alle profielen samen); andere profielen (ook kinderprofielen) zien alleen hun eigen cijfers.

// MARK: - Periode en opmaak

enum StatsText {
    static let seriesColor = Color(hex: 0x3B82F6)
    static let liveColor = Color(hex: 0xF59E0B)

    /// Kalender met weken vanaf maandag (ISO-weeknummers), in de tijdzone van het apparaat.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = .current
        c.locale = Localizer.shared.locale
        return c
    }

    /// Begin en einde (exclusief) van de periode met `offset` (0 = nu, -1 = vorige …).
    static func interval(_ period: AccountService.StatsPeriod, offset: Int, now: Date = Date()) -> DateInterval {
        let cal = calendar
        let unit: Calendar.Component = period == .week ? .weekOfYear : (period == .month ? .month : .year)
        let base = cal.dateInterval(of: unit, for: now) ?? DateInterval(start: now, duration: 86400)
        let start = cal.date(byAdding: unit, value: offset, to: base.start) ?? base.start
        let end = cal.date(byAdding: unit, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    /// "Week 42", "oktober 2026" of "2026".
    static func label(_ period: AccountService.StatsPeriod, offset: Int) -> String {
        let r = interval(period, offset: offset)
        let loc = Localizer.shared.locale
        switch period {
        case .week:
            let week = calendar.component(.weekOfYear, from: r.start)
            let year = calendar.component(.yearForWeekOfYear, from: r.start)
            let base = L("Week %d", week)
            return year == calendar.component(.yearForWeekOfYear, from: Date()) ? base : "\(base) · \(year)"
        case .month:
            return r.start.formatted(.dateTime.month(.wide).year().locale(loc))
        case .year:
            return String(calendar.component(.year, from: r.start))
        }
    }

    /// Bij een week: "13 – 19 okt." als extra regel onder het weeknummer.
    static func subtitle(_ period: AccountService.StatsPeriod, offset: Int) -> String? {
        guard period == .week else { return nil }
        let r = interval(period, offset: offset)
        let last = r.end.addingTimeInterval(-1)
        let loc = Localizer.shared.locale
        return r.start.formatted(.dateTime.day().month(.abbreviated).locale(loc)) + " – "
            + last.formatted(.dateTime.day().month(.abbreviated).locale(loc))
    }

    private static func formatter(_ format: String) -> DateFormatter { SharedFormatters.posix(format) }   // build 149

    /// Alle staven van de periode, ook zonder kijktijd: dagen ("yyyy-MM-dd") of maanden ("yyyy-MM").
    static func bucketDates(_ period: AccountService.StatsPeriod, offset: Int) -> [(key: String, date: Date)] {
        let r = interval(period, offset: offset)
        let cal = calendar
        let unit: Calendar.Component = period == .year ? .month : .day
        let f = formatter(period == .year ? "yyyy-MM" : "yyyy-MM-dd")
        var out: [(key: String, date: Date)] = []
        var d = r.start
        while d < r.end, out.count < 40 {
            out.append((key: f.string(from: d), date: d))
            d = cal.date(byAdding: unit, value: 1, to: d) ?? r.end
        }
        return out
    }

    /// Korte naam van een staaf: "ma", "13" of "okt".
    static func barLabel(_ period: AccountService.StatsPeriod, date: Date) -> String {
        let loc = Localizer.shared.locale
        switch period {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).locale(loc))
        case .month: return String(calendar.component(.day, from: date))
        case .year: return date.formatted(.dateTime.month(.abbreviated).locale(loc))
        }
    }

    /// "45 min", "3 h" of "12 h 30 min".
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return L("%d min", minutes) }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? L("%d h", h) : L("%d h %d min", h, m)
    }

    /// Beginletters (max. twee) voor een titel zonder poster.
    static func initials(_ title: String) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let s = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return s.isEmpty ? "?" : s
    }
}

// MARK: - Scherm

struct StatsView: View {
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var playlists: PlaylistService
    /// Build 88: statistieken horen bij Lifetime
    @ObservedObject private var ent = EntitlementsService.shared

    @State private var period: AccountService.StatsPeriod = .month
    @State private var offset = 0
    /// Filter van het hoofdprofiel: nil = alle profielen
    @State private var filterProfile: UUID?
    @State private var stats: AccountService.WatchStats?
    @State private var error: String?
    @State private var expanded: Set<String> = []
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var detail: DetailTarget?
    /// Poster/logo en detailpagina per `item_key`, één keer per antwoord opgezocht
    @State private var resolved: [String: Resolved] = [:]

    struct Resolved {
        var image: URL?
        var target: DetailTarget?
        var isLogo = false
    }

    private var isMain: Bool { store.isMainActive || store.profiles.isEmpty || store.activeProfileID == nil }

    /// Profiel waarvoor de cijfers gelden (nil = alle profielen; alleen voor het hoofdprofiel).
    private var requestProfileID: String? {
        if isMain { return filterProfile?.uuidString }
        return store.activeProfile?.id.uuidString
    }

    private var loadKey: String { "\(period.rawValue)|\(offset)|\(requestProfileID ?? "all")" }

    var body: some View {
        if ent.allows(.stats) { unlocked } else { locked }
    }

    /// Gratis-account (of 403 `feature_locked`): uitleg in plaats van de cijfers.
    private var locked: some View {
        ScrollView {
            LifetimeLockedView(feature: .stats)
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, tvScaled(16))
                .frame(maxWidth: tvScaled(700), alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(L("Statistics"))
        .task { await ent.refresh() }
    }

    private var unlocked: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tvScaled(22)) {
                StatsPeriodBar(period: $period, offset: $offset)
                if isMain && store.profiles.count > 1 {
                    StatsProfileFilter(profiles: store.profiles, selection: $filterProfile)
                }
                content
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, tvScaled(16))
            .frame(maxWidth: tvScaled(1000), alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(L("Statistics"))
        .task(id: loadKey) { await load() }
        #if !os(tvOS)
        .refreshable { await load() }
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
        .confirmationDialog(clearQuestion, isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Clear statistics"), role: .destructive) { Task { await clear() } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        if let stats, !stats.isEmpty {
            StatsTiles(stats: stats, periodLabel: StatsText.label(period, offset: offset))
            StatsChartCard(period: period, offset: offset, stats: stats)
            if isMain && requestProfileID == nil && !stats.profiles.isEmpty {
                StatsProfileBreakdown(profiles: stats.profiles)
            }
            topSection("series", L("Top series"), stats.topSeries, showEpisodes: true)
            topSection("movies", L("Top movies"), stats.topMovies, showEpisodes: false)
            topSection("channels", L("Top channels"), stats.topChannels, showEpisodes: false)
            clearButton
            if let since = stats.since {
                Text(L("Tracked since %@", since.formatted(.dateTime.day().month(.wide).year().locale(Localizer.shared.locale))))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
            }
        } else if let error {
            VStack(alignment: .leading, spacing: tvScaled(12)) {
                Text(error).font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                NetflixButton(title: L("Try again"), icon: "arrow.clockwise", kind: .secondary) { Task { await load() } }
            }
        } else if stats != nil {
            VStack(alignment: .leading, spacing: tvScaled(16)) {
                HStack(alignment: .top, spacing: tvScaled(12)) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: tvScaled(26))).foregroundStyle(Theme.secondary)
                    Text(L("No viewing statistics yet. Bingr keeps track of them from 13 October 2026."))
                        .font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #if os(tvOS)
                // focus op de lege pagina (anders kan de afstandsbediening nergens heen onder de periodeknoppen)
                .focusable()
                #endif
            }
            .padding(.vertical, tvScaled(20))
        } else {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, tvScaled(40))
        }
    }

    // MARK: toplijsten

    @ViewBuilder
    private func topSection(_ id: String, _ title: String, _ items: [AccountService.WatchStats.TopItem], showEpisodes: Bool) -> some View {
        if !items.isEmpty {
            let open = expanded.contains(id)
            let shown = Array(items.prefix(open ? 10 : 5))
            VStack(alignment: .leading, spacing: tvScaled(10)) {
                Text(title).font(.system(size: tvScaled(19), weight: .bold)).foregroundStyle(.white)
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    let r = resolved[resolveKey(id, item)]
                    if let target = r?.target {
                        Button { detail = target } label: {
                            StatsTopRow(rank: i + 1, item: item, image: r?.image, isLogo: r?.isLogo ?? false,
                                        showEpisodes: showEpisodes, chevron: true)
                        }
                        .plainTVButton()
                    } else {
                        StatsTopRow(rank: i + 1, item: item, image: r?.image, isLogo: r?.isLogo ?? (id == "channels"),
                                    showEpisodes: showEpisodes, chevron: false)
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }
                }
                if items.count > 5 {
                    Button {
                        withAnimation { if open { expanded.remove(id) } else { expanded.insert(id) } }
                    } label: {
                        Label(open ? L("Show less") : L("More"), systemImage: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: tvScaled(14), weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, tvScaled(14)).padding(.vertical, tvScaled(7))
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .plainTVButton()
                }
            }
        }
    }

    private var clearButton: some View {
        Button { confirmClear = true } label: {
            HStack(spacing: tvScaled(8)) {
                if clearing { ProgressView() } else { Image(systemName: "trash") }
                Text(L("Clear statistics"))
            }
            .font(.system(size: tvScaled(15), weight: .semibold))
            .foregroundStyle(Theme.alert)
            .padding(.horizontal, tvScaled(16)).padding(.vertical, tvScaled(9))
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .plainTVButton()
        .disabled(clearing)
        .padding(.top, tvScaled(8))
    }

    /// Vraag bij wissen: het hoofdprofiel wist alle profielen of het gekozen profiel, een ander profiel alleen zichzelf.
    private var clearQuestion: String {
        if let id = requestProfileID {
            let name = store.profiles.first { $0.id.uuidString == id }?.name ?? store.activeProfile?.name ?? ""
            return L("Clear the viewing statistics of %@? This can't be undone.", name)
        }
        return L("Clear the viewing statistics of all profiles? This can't be undone.")
    }

    // MARK: laden

    @MainActor private func load() async {
        do {
            let s = try await account.watchStats(period: period, offset: offset, profileID: requestProfileID)
            resolved = resolve(s)
            stats = s
            error = nil
        } catch is CancellationError {
        } catch is FeatureLockedError {
            // de server zette de functie op slot: het scherm wisselt naar de uitleg
            stats = nil
        } catch {
            stats = nil
            self.error = error.localizedDescription
        }
    }

    @MainActor private func clear() async {
        clearing = true
        defer { clearing = false }
        do {
            try await account.deleteWatchStats(profileID: requestProfileID)
            await load()
        } catch {
            self.error = error.localizedDescription
            stats = nil
        }
    }

    private func resolveKey(_ section: String, _ item: AccountService.WatchStats.TopItem) -> String { section + "|" + item.id }

    /// `item_key` zijn de id's uit de bibliotheek (film, serie, zender); anders op titel.
    private func resolve(_ s: AccountService.WatchStats) -> [String: Resolved] {
        let lib = playlists.library
        var out: [String: Resolved] = [:]
        func candidates(_ key: String) -> [String] {
            var c = [key]
            if let i = key.firstIndex(of: ":") { c.append(String(key[key.index(after: i)...])) }
            return c
        }
        func norm(_ t: String) -> String { t.trimmingCharacters(in: .whitespaces).lowercased() }
        if !s.topMovies.isEmpty {
            let byID = Dictionary(lib.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for m in s.topMovies {
                let hit = candidates(m.itemKey).lazy.compactMap { byID[$0] }.first
                    ?? lib.movies.first { norm($0.title) == norm(m.title) }
                out[resolveKey("movies", m)] = Resolved(image: hit?.poster, target: hit.map { .movie($0) })
            }
        }
        if !s.topSeries.isEmpty {
            let byID = Dictionary(lib.series.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for sr in s.topSeries {
                let hit = candidates(sr.itemKey).lazy.compactMap { byID[$0] }.first
                    ?? lib.series.first { norm($0.title) == norm(sr.title) }
                out[resolveKey("series", sr)] = Resolved(image: hit?.poster, target: hit.map { .series($0) })
            }
        }
        if !s.topChannels.isEmpty {
            let byID = Dictionary(lib.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for c in s.topChannels {
                let hit = candidates(c.itemKey).lazy.compactMap { byID[$0] }.first
                    ?? lib.channels.first { norm($0.name) == norm(c.title) }
                out[resolveKey("channels", c)] = Resolved(image: hit?.logo, target: nil, isLogo: true)
            }
        }
        return out
    }
}

// MARK: - Periodekeuze

private struct StatsPeriodBar: View {
    @Binding var period: AccountService.StatsPeriod
    @Binding var offset: Int

    private func title(_ p: AccountService.StatsPeriod) -> String {
        switch p {
        case .week: return L("Week")
        case .month: return L("Month")
        case .year: return L("Year")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(14)) {
            #if os(tvOS)
            HStack(spacing: tvScaled(10)) {
                ForEach(AccountService.StatsPeriod.allCases) { p in
                    Button { select(p) } label: {
                        Text(title(p))
                            .font(.system(size: tvScaled(15), weight: .semibold))
                            .foregroundStyle(period == p ? Color.black : Color.white)
                            .padding(.horizontal, tvScaled(18)).padding(.vertical, tvScaled(8))
                            .background(period == p ? Color.white : Color.white.opacity(0.14), in: Capsule())
                    }
                    .plainTVButton()
                }
            }
            #else
            Picker(L("Statistics"), selection: Binding(get: { period }, set: { select($0) })) {
                ForEach(AccountService.StatsPeriod.allCases) { p in Text(title(p)).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            #endif
            HStack(spacing: tvScaled(14)) {
                arrow("chevron.left", L("Previous period")) { offset -= 1 }
                VStack(spacing: tvScaled(2)) {
                    Text(StatsText.label(period, offset: offset))
                        .font(.system(size: tvScaled(20), weight: .bold)).foregroundStyle(.white)
                    if let sub = StatsText.subtitle(period, offset: offset) {
                        Text(sub).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(minWidth: tvScaled(160))
                arrow("chevron.right", L("Next period")) { offset += 1 }
                    .disabled(offset >= 0)
                    .opacity(offset >= 0 ? 0.35 : 1)
            }
        }
    }

    private func select(_ p: AccountService.StatsPeriod) {
        guard p != period else { return }
        period = p
        offset = 0
    }

    private func arrow(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: tvScaled(16), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: tvScaled(38), height: tvScaled(38))
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .plainTVButton()
        .accessibilityLabel(label)
    }
}

// MARK: - Profielfilter (alleen hoofdprofiel)

private struct StatsProfileFilter: View {
    let profiles: [ViewerProfile]
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tvScaled(10)) {
                chip(nil, name: L("All profiles"))
                ForEach(profiles) { p in chip(p.id, name: p.name) }
            }
            .padding(.vertical, tvScaled(8))
            .padding(.horizontal, tvScaled(4))
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    private func chip(_ id: UUID?, name: String) -> some View {
        let on = selection == id
        return Button { selection = id } label: {
            HStack(spacing: tvScaled(8)) {
                if let id {
                    AccountProfileAvatar(profileID: id.uuidString, profileName: name, size: tvScaled(26))
                } else {
                    Image(systemName: "person.2.fill").font(.system(size: tvScaled(13)))
                        .frame(width: tvScaled(26), height: tvScaled(26))
                }
                Text(name).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.leading, tvScaled(5)).padding(.trailing, tvScaled(14)).padding(.vertical, tvScaled(5))
            .background(on ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .plainTVButton()
    }
}

// MARK: - Tegels

private struct StatsTiles: View {
    let stats: AccountService.WatchStats
    let periodLabel: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tvScaled(150)), spacing: tvScaled(12))], spacing: tvScaled(12)) {
            tile(L("Hours watched"), icon: "clock.fill", color: .white,
                 value: StatsText.duration(stats.totalMinutes), detail: periodLabel)
            tile(L("Movies"), icon: "film.fill", color: Theme.red,
                 value: StatsText.duration(stats.movieMinutes), detail: L("%d movies", stats.movieCount))
            tile(L("Series"), icon: "tv.fill", color: StatsText.seriesColor,
                 value: StatsText.duration(stats.seriesMinutes),
                 detail: L("%d series · %d episodes", stats.seriesShows, stats.seriesEpisodes))
            tile(L("Live TV"), icon: "dot.radiowaves.left.and.right", color: StatsText.liveColor,
                 value: StatsText.duration(stats.liveMinutes), detail: L("%d channels", stats.liveChannels))
        }
        #if os(tvOS)
        .focusable()
        #endif
    }

    private func tile(_ title: String, icon: String, color: Color, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: tvScaled(6)) {
            Label(title, systemImage: icon)
                .font(.system(size: tvScaled(13), weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(.system(size: tvScaled(22), weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail)
                .font(.system(size: tvScaled(12)))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: tvScaled(92), alignment: .topLeading)
        .padding(tvScaled(14))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.06)))
    }
}

// MARK: - Grafiek

private struct StatsChartCard: View {
    let period: AccountService.StatsPeriod
    let offset: Int
    let stats: AccountService.WatchStats

    struct Point: Identifiable {
        let key: String
        let kind: Int        // 0 films, 1 series, 2 live (volgorde van stapelen)
        let hours: Double
        var id: String { "\(key)-\(kind)" }
    }

    private var bars: [(key: String, date: Date)] { StatsText.bucketDates(period, offset: offset) }

    private var points: [Point] {
        let byKey = Dictionary(stats.buckets.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Point] = []
        for b in bars {
            let v = byKey[b.key]
            out.append(Point(key: b.key, kind: 0, hours: Double(v?.movieMinutes ?? 0) / 60))
            out.append(Point(key: b.key, kind: 1, hours: Double(v?.episodeMinutes ?? 0) / 60))
            out.append(Point(key: b.key, kind: 2, hours: Double(v?.liveMinutes ?? 0) / 60))
        }
        return out
    }

    private var names: [String] { [L("Movies"), L("Series"), L("Live TV")] }
    private var colors: [Color] { [Theme.red, StatsText.seriesColor, StatsText.liveColor] }

    /// Bij een maand niet alle 31 dagen onder de as: 1, 5, 10, 15 …
    private var axisKeys: [String] {
        let all = bars
        guard period == .month else { return all.map(\.key) }
        return all.enumerated().filter { i, _ in i == 0 || (i + 1) % 5 == 0 }.map(\.element.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tvScaled(12)) {
            chart
                .frame(height: tvScaled(200))
            HStack(spacing: tvScaled(16)) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: tvScaled(6)) {
                        Circle().fill(colors[i]).frame(width: tvScaled(9), height: tvScaled(9))
                        Text(names[i]).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(tvScaled(14))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.06)))
        #if os(tvOS)
        .focusable()
        #endif
    }

    private var chart: some View {
        let labels = Dictionary(bars.map { ($0.key, StatsText.barLabel(period, date: $0.date)) }, uniquingKeysWith: { a, _ in a })
        let n = names
        return Chart(points) { p in
            BarMark(x: .value("Period", p.key), y: .value("Hours", p.hours))
                .foregroundStyle(by: .value("Kind", n[p.kind]))
                .cornerRadius(period == .month ? 1 : 3)
        }
        .chartForegroundStyleScale(domain: n, range: colors)
        .chartLegend(.hidden)
        .chartXScale(domain: bars.map(\.key))
        .chartXAxis {
            AxisMarks(values: axisKeys) { v in
                AxisValueLabel {
                    Text(labels[v.as(String.self) ?? ""] ?? "")
                        .font(.system(size: tvScaled(10)))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    Text(L("%d h", Int((v.as(Double.self) ?? 0).rounded())))
                        .font(.system(size: tvScaled(10)))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .accessibilityLabel(L("Hours watched"))
    }
}

// MARK: - Per profiel (hoofdprofiel, alle profielen)

private struct StatsProfileBreakdown: View {
    let profiles: [AccountService.WatchStats.ProfileShare]

    var body: some View {
        let sorted = profiles.sorted { $0.minutes > $1.minutes }
        let maxMinutes = max(1, sorted.first?.minutes ?? 1)
        VStack(alignment: .leading, spacing: tvScaled(10)) {
            Text(L("Per profile")).font(.system(size: tvScaled(19), weight: .bold)).foregroundStyle(.white)
            ForEach(sorted) { p in
                HStack(spacing: tvScaled(12)) {
                    AccountProfileAvatar(profileID: p.profileID, profileName: p.profileName, size: tvScaled(34))
                    VStack(alignment: .leading, spacing: tvScaled(5)) {
                        HStack {
                            Text(p.profileName.isEmpty ? "—" : p.profileName)
                                .font(.system(size: tvScaled(15), weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: tvScaled(8))
                            Text(StatsText.duration(p.minutes))
                                .font(.system(size: tvScaled(13)).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(Theme.red)
                                    .frame(width: max(tvScaled(4), g.size.width * CGFloat(p.minutes) / CGFloat(maxMinutes)))
                            }
                        }
                        .frame(height: tvScaled(6))
                    }
                }
                .padding(.vertical, tvScaled(2))
                #if os(tvOS)
                .focusable()
                #endif
            }
        }
    }
}

// MARK: - Regel in een toplijst

private struct StatsTopRow: View {
    let rank: Int
    let item: AccountService.WatchStats.TopItem
    let image: URL?
    let isLogo: Bool
    let showEpisodes: Bool
    let chevron: Bool

    var body: some View {
        HStack(spacing: tvScaled(12)) {
            Text("\(rank)")
                .font(.system(size: tvScaled(16), weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: tvScaled(22))
            artwork
            VStack(alignment: .leading, spacing: tvScaled(3)) {
                Text(item.title.isEmpty ? "—" : ContentLanguage.shown(item.title))
                    .font(.system(size: tvScaled(15), weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                Text(detail).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: tvScaled(6))
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: tvScaled(12), weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, tvScaled(4))
        .contentShape(Rectangle())
    }

    private var detail: String {
        let d = StatsText.duration(item.minutes)
        return showEpisodes && item.episodes > 0 ? L("%d episodes", item.episodes) + " · " + d : d
    }

    @ViewBuilder private var artwork: some View {
        let w = tvScaled(isLogo ? 52 : 40), h = tvScaled(isLogo ? 40 : 60)
        Group {
            if let image {
                if isLogo {
                    RemoteImage(url: image, contentMode: .fit, maxPixel: 200).padding(tvScaled(4))
                } else {
                    RemoteImage(url: image, maxPixel: 240)
                }
            } else {
                ZStack {
                    AccountProfileAvatar.fallbackGradient(item.title)
                    Text(StatsText.initials(item.title))
                        .font(.system(size: tvScaled(14), weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: w, height: h)
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: tvScaled(5)))
    }
}
