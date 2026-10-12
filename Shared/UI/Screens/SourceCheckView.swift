import SwiftUI

/// "Bron controleren": haalt de actieve bron opnieuw op en vergelijkt wat de server aanbiedt
/// met wat Bingr inleest en wat er in dit profiel zichtbaar is.
@MainActor
final class SourceCheck: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var label: String
        var server: Int?
        var parsed: Int?
        var visible: Int?
        var notes: [String] = []
        /// Bingr las minder dan de server stuurde
        var parsedDiffers: Bool { if let s = server, let p = parsed { return s != p } else { return false } }
        /// Er is minder zichtbaar dan Bingr inlas
        var visibleDiffers: Bool { if let p = parsed, let v = visible { return p != v } else { return false } }
    }
    struct Fact: Identifiable {
        let id = UUID()
        var label: String
        var value: String
        var warn = false
    }

    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var step = ""
    @Published private(set) var account: [Fact] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var sampleSummary: Fact?
    @Published private(set) var sample: [Fact] = []
    @Published private(set) var problems: [String] = []
    @Published private(set) var finishedAt: Date?
    private var kindTitle = ""
    /// Teksten die nooit in het rapport of op het scherm mogen (gebruikersnaam, wachtwoord, serveradres)
    private var secrets: [String] = []

    nonisolated static func fmt(_ n: Int) -> String { n.formatted(.number.locale(Localizer.shared.locale)) }

    func run(_ s: PlaylistSource, service: PlaylistService) async {
        guard !running else { return }
        running = true; progress = 0; step = ""
        account = []; rows = []; sample = []; sampleSummary = nil; problems = []; finishedAt = nil
        kindTitle = s.kind.title
        let password = Keychain.get(s.passwordKey) ?? ""
        secrets = Self.secrets(of: s, password: password)
        switch s.kind {
        case .xtream: await checkXtream(s, password: password, service: service)
        case .m3u: await checkM3U(s, service: service)
        default: await checkOther(service: service)
        }
        progress = 1; step = ""
        finishedAt = Date()
        running = false
    }

    // MARK: Xtream

    private func checkXtream(_ s: PlaylistSource, password: String, service: PlaylistService) async {
        let x = XtreamClient(source: s, password: password)
        let total = 8.0 + 5.0

        step = L("Signing in to server…")
        do {
            let data = try await x.rawData()
            readAccount(data)
        } catch {
            problems.append(scrub(L("Couldn't sign in to the server: %@", error.localizedDescription)))
        }
        progress = 1 / total

        step = L("Fetching live TV, movies and series…")
        async let lcR = x.rawList("get_live_categories", as: XtreamClient.Cat.self)
        async let lsR = x.rawList("get_live_streams", as: XtreamClient.Live.self)
        async let vcR = x.rawList("get_vod_categories", as: XtreamClient.Cat.self)
        async let vsR = x.rawList("get_vod_streams", as: XtreamClient.Vod.self)
        async let scR = x.rawList("get_series_categories", as: XtreamClient.Cat.self)
        async let ssR = x.rawList("get_series", as: XtreamClient.SeriesDTO.self)
        let lc = await lcR; progress = 2 / total
        let ls = await lsR; progress = 3 / total
        let vc = await vcR; progress = 4 / total
        let vs = await vsR; progress = 5 / total
        let sc = await scR; progress = 6 / total
        let ss = await ssR; progress = 7 / total

        step = L("Applying your settings…")
        let lib = x.makeLibrary(liveCats: lc.items, live: ls.items, vodCats: vc.items, vod: vs.items,
                                serCats: sc.items, series: ss.items)
        let (afterSettings, visible) = await service.visibility(of: lib)
        let inApp = service.source?.id == s.id ? service.rawLibrary : nil
        progress = 8 / total

        func catRow(_ label: String, _ r: XtreamClient.RawList<XtreamClient.Cat>) -> Row {
            var row = Row(label: label, server: r.serverCount, parsed: r.items.count)
            addReadNotes(&row, error: r.error)
            return row
        }
        func itemRow<T: Decodable>(_ label: String, _ r: XtreamClient.RawList<T>, parsed: Int, after: Int, vis: Int, app: Int?) -> Row {
            var row = Row(label: label, server: r.serverCount, parsed: parsed, visible: vis)
            addReadNotes(&row, error: r.error)
            addHiddenNotes(&row, parsed: parsed, afterSettings: after, visible: vis, inApp: app)
            return row
        }
        rows = [
            catRow(L("Live categories"), lc),
            itemRow(L("Live channels"), ls, parsed: lib.channels.count, after: afterSettings.channels.count,
                    vis: visible.channels.count, app: inApp?.channels.count),
            catRow(L("Movie categories"), vc),
            itemRow(L("Movies"), vs, parsed: lib.movies.count, after: afterSettings.movies.count,
                    vis: visible.movies.count, app: inApp?.movies.count),
            catRow(L("Series categories"), sc),
            itemRow(L("Series"), ss, parsed: lib.series.count, after: afterSettings.series.count,
                    vis: visible.series.count, app: inApp?.series.count),
        ]

        // steekproef: krijgen series ook afleveringen?
        let picks = Array(lib.series.filter { $0.xtreamSeriesID != nil }.shuffled().prefix(5))
        var ok = 0
        for (i, se) in picks.enumerated() {
            step = L("Checking series episodes (%d of %d)…", i + 1, picks.count)
            do {
                let eps = try await x.episodes(for: se)
                let seasons = Set(eps.map(\.season)).count
                if eps.isEmpty {
                    sample.append(Fact(label: se.title, value: L("No episodes"), warn: true))
                } else {
                    ok += 1
                    sample.append(Fact(label: se.title, value: L("%d seasons · %d episodes", seasons, eps.count)))
                }
            } catch {
                sample.append(Fact(label: se.title, value: scrub(L("Couldn't be read: %@", error.localizedDescription)), warn: true))
            }
            progress = (9 + Double(i)) / total
        }
        if !picks.isEmpty {
            sampleSummary = Fact(label: L("Sample"), value: L("%d/%d series have episodes", ok, picks.count), warn: ok < picks.count)
        }
    }

    /// Abonnementsgegevens uit het antwoord op de inlog (user_info).
    private func readAccount(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let u = obj["user_info"] as? [String: Any] else {
            problems.append(L("The server did not send account information"))
            return
        }
        func str(_ k: String) -> String? {
            let v: Any = u[k] ?? NSNull()
            switch v {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        if str("auth") == "0" {
            account.append(Fact(label: L("Sign-in"), value: L("Rejected"), warn: true))
        }
        let status = str("status") ?? "—"
        account.append(Fact(label: L("Status"), value: status, warn: status.lowercased() != "active"))
        if let e = str("exp_date"), let t = Double(e), t > 0 {
            let d = Date(timeIntervalSince1970: t)
            let text = d.formatted(.dateTime.day().month(.wide).year().locale(Localizer.shared.locale))
            account.append(Fact(label: L("Expires"), value: text, warn: d.timeIntervalSinceNow < 7 * 86_400))
        } else {
            account.append(Fact(label: L("Expires"), value: L("Unlimited")))
        }
        if let m = str("max_connections") {
            account.append(Fact(label: L("Max connections"), value: m))
        }
        if let a = str("active_cons") {
            let atMax = Int(a).flatMap { act in str("max_connections").flatMap { Int($0) }.map { act >= $0 && $0 > 0 } } ?? false
            account.append(Fact(label: L("Active connections"), value: a, warn: atMax))
        }
        if str("is_trial") == "1" {
            account.append(Fact(label: L("Trial"), value: L("Yes"), warn: true))
        }
    }

    // MARK: M3U

    private func checkM3U(_ s: PlaylistSource, service: PlaylistService) async {
        step = L("Downloading playlist…")
        guard let u = s.m3uURL.urlValue else { problems.append(L("Invalid URL")); return }
        let data: Data
        do { data = try await HTTP.get(u) } catch {
            problems.append(scrub(L("Couldn't download the playlist: %@", error.localizedDescription)))
            return
        }
        progress = 0.4
        step = L("Sorting channels and movies…")
        let pid = s.id
        let (entries, lib) = await Task.detached(priority: .userInitiated) { () -> (Int, Library) in
            let text = String(decoding: data, as: UTF8.self)
            var n = 0
            text.enumerateLines { line, _ in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTINF") { n += 1 }
            }
            return (n, M3UParser.library(from: text, playlistID: pid))
        }.value
        progress = 0.7
        step = L("Applying your settings…")
        let (afterSettings, visible) = await service.visibility(of: lib)
        let inApp = service.source?.id == s.id ? service.rawLibrary : nil

        func eps(_ l: Library) -> Int { l.series.reduce(0) { $0 + $1.episodes.count } }
        let parsedTotal = lib.channels.count + lib.movies.count + eps(lib)
        let visibleTotal = visible.channels.count + visible.movies.count + eps(visible)
        var entriesRow = Row(label: L("Entries (#EXTINF)"), server: entries, parsed: parsedTotal, visible: visibleTotal)
        addReadNotes(&entriesRow, error: nil)
        rows = [entriesRow]
        rows += itemRows(lib, afterSettings, visible, inApp, episodes: true)
    }

    // MARK: overige bronnen (Stalker, Plex, Jellyfin, Emby, Stremio)

    private func checkOther(service: PlaylistService) async {
        step = L("Applying your settings…")
        let lib = service.rawLibrary
        let (afterSettings, visible) = await service.visibility(of: lib)
        rows = itemRows(lib, afterSettings, visible, nil, episodes: false)
        if lib.isEmptyLibrary { problems.append(L("No content loaded. Use Refresh now and check again.")) }
    }

    private func itemRows(_ lib: Library, _ after: Library, _ vis: Library, _ app: Library?, episodes: Bool) -> [Row] {
        func make(_ label: String, _ p: Int, _ a: Int, _ v: Int, _ inApp: Int?) -> Row {
            var r = Row(label: label, server: nil, parsed: p, visible: v)
            addHiddenNotes(&r, parsed: p, afterSettings: a, visible: v, inApp: inApp)
            return r
        }
        var out = [
            make(L("Live channels"), lib.channels.count, after.channels.count, vis.channels.count, app?.channels.count),
            make(L("Movies"), lib.movies.count, after.movies.count, vis.movies.count, app?.movies.count),
            make(L("Series"), lib.series.count, after.series.count, vis.series.count, app?.series.count),
        ]
        if episodes {
            func eps(_ l: Library) -> Int { l.series.reduce(0) { $0 + $1.episodes.count } }
            out.append(make(L("Episodes"), eps(lib), eps(after), eps(vis), app.map(eps)))
        }
        return out
    }

    // MARK: toelichting

    private func addReadNotes(_ row: inout Row, error: String?) {
        if let error { row.notes.append(scrub(L("Couldn't fetch this list: %@", error))) }
        if let s = row.server, let p = row.parsed {
            if s > p { row.notes.append(L("%@ items could not be read", Self.fmt(s - p))) }
            else if p > s { row.notes.append(L("%@ more read than the server listed", Self.fmt(p - s))) }
        }
    }

    private func addHiddenNotes(_ row: inout Row, parsed: Int, afterSettings: Int, visible: Int, inApp: Int?) {
        if parsed > afterSettings {
            row.notes.append(L("%@ hidden by your category settings", Self.fmt(parsed - afterSettings)))
        }
        if afterSettings > visible {
            row.notes.append(L("%@ hidden by parental controls or the age limit", Self.fmt(afterSettings - visible)))
        }
        if let inApp, inApp != parsed {
            row.notes.append(L("The app still has %@ from an earlier load; use Refresh now", Self.fmt(inApp)))
        }
    }

    // MARK: privacy

    private static func secrets(of s: PlaylistSource, password: String) -> [String] {
        var out = [password, s.username, s.macAddress]
        for raw in [s.serverURL, s.m3uURL, s.epgURL] {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            out.append(t)
            if let c = URLComponents(string: t) {
                if let h = c.host { out.append(h) }
                out += (c.queryItems ?? []).compactMap(\.value)
                if let u = c.user { out.append(u) }
                if let p = c.password { out.append(p) }
            }
        }
        // langste eerst, zodat een volledige URL vóór zijn onderdelen wordt vervangen
        return Array(Set(out.filter { $0.count >= 4 })).sorted { $0.count > $1.count }
    }

    private func scrub(_ text: String) -> String {
        var t = text
        for s in secrets { t = t.replacingOccurrences(of: s, with: "•••") }
        return t
    }

    // MARK: rapport

    /// Platte tekst om te delen: zonder wachtwoord, gebruikersnaam, serveradres of URL's.
    func report() -> String {
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        #if os(macOS)
        let platform = "macOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        lines.append("Bingr – " + L("Check source"))
        lines.append("\(L("Date")): " + (finishedAt ?? Date()).formatted(date: .abbreviated, time: .shortened))
        lines.append("App: \(version) (\(build)) · \(platform)")
        lines.append("\(L("Source type")): \(kindTitle)")
        if !account.isEmpty {
            lines.append("")
            lines.append(L("Subscription"))
            for f in account { lines.append("  \(f.label): \(f.value)\(f.warn ? " (!)" : "")") }
        }
        if !rows.isEmpty {
            lines.append("")
            lines.append(L("Content") + " — " + [L("Server"), "Bingr", L("Visible")].joined(separator: " / "))
            for r in rows {
                let cells = [r.server, r.parsed, r.visible].map { $0.map(Self.fmt) ?? "—" }.joined(separator: " / ")
                lines.append("  \(r.label): \(cells)")
                for n in r.notes { lines.append("    ! \(n)") }
            }
        }
        if let s = sampleSummary {
            lines.append("")
            lines.append(L("Series episodes (sample)") + ": " + s.value)
            for f in sample { lines.append("  \(f.label): \(f.value)") }
        }
        if !problems.isEmpty {
            lines.append("")
            lines.append(L("Problems"))
            for p in problems { lines.append("  ! \(p)") }
        }
        return scrub(lines.joined(separator: "\n"))
    }
}

struct SourceCheckView: View {
    @EnvironmentObject var playlists: PlaylistService
    @StateObject private var check = SourceCheck()
    @State private var copied = false

    var body: some View {
        List {
            if let s = playlists.source {
                Section {
                    FocusRow {
                        LabeledContent(L("Source"), value: "\(s.name) · \(s.kind.title)")
                    }
                    if check.running {
                        FocusRow {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: check.progress).tint(Theme.red)
                                Text(check.step).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    Button { Task { await check.run(s, service: playlists) } } label: {
                        Label(check.running ? L("Checking…") : L("Check again"), systemImage: "arrow.clockwise")
                    }
                    .disabled(check.running)
                    #if !os(tvOS)
                    if check.finishedAt != nil && !check.running {
                        Button {
                            UIPasteboard.general.string = check.report()
                            copied = true
                        } label: {
                            Label(copied ? L("Copied") : L("Copy report"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    #endif
                } footer: {
                    Text(L("Bingr fetches everything from your server again and compares it with what the app reads and shows."))
                }

                if !check.account.isEmpty {
                    Section(L("Subscription")) {
                        ForEach(check.account) { f in FactRowView(fact: f) }
                    }
                }

                if !check.rows.isEmpty {
                    Section {
                        CountHeader()
                        ForEach(check.rows) { r in FocusRow { CountRowView(row: r) } }
                    } header: { Text(L("Content")) } footer: {
                        Text(L("Server: what your server offers. Bingr: what Bingr could read. Visible: what this profile sees after your category settings and parental controls."))
                    }
                }

                if let sum = check.sampleSummary {
                    Section(L("Series episodes (sample)")) {
                        FactRowView(fact: sum)
                        ForEach(check.sample) { f in FactRowView(fact: f) }
                    }
                }

                if !check.problems.isEmpty {
                    Section(L("Problems")) {
                        ForEach(check.problems, id: \.self) { p in
                            FocusRow { Text(p).foregroundStyle(.orange) }
                        }
                    }
                }
            } else {
                Text(L("No source selected"))
            }
        }
        .navigationTitle(L("Check source"))
        .task {
            if check.finishedAt == nil, !check.running, let s = playlists.source { await check.run(s, service: playlists) }
        }
        .onChange(of: check.running) { _, r in if r { copied = false } }
    }
}

/// Op tvOS moet elke rij focusbaar zijn, anders kun je er niet langs scrollen.
private struct FocusRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        Button {} label: { content }
        #else
        content
        #endif
    }
}

private struct FactRowView: View {
    let fact: SourceCheck.Fact
    var body: some View {
        FocusRow {
            LabeledContent {
                Text(fact.value).foregroundStyle(fact.warn ? Color.orange : Theme.secondary)
            } label: {
                Text(fact.label)
            }
        }
    }
}

private let countColumn = tvScaled(70)

private struct CountHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(L("Server")).frame(width: countColumn, alignment: .trailing)
            Text("Bingr").frame(width: countColumn, alignment: .trailing)
            Text(L("Visible")).frame(width: countColumn, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.secondary)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
}

private struct CountRowView: View {
    let row: SourceCheck.Row
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.label).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                cell(row.server, warn: false)
                cell(row.parsed, warn: row.parsedDiffers)
                cell(row.visible, warn: row.visibleDiffers)
            }
            ForEach(row.notes, id: \.self) { n in
                Label(n, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func cell(_ v: Int?, warn: Bool) -> some View {
        Text(v.map(SourceCheck.fmt) ?? "—")
            .font(.callout.monospacedDigit())
            .foregroundStyle(warn ? Color.orange : (v == nil ? Theme.secondary : Color.primary))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: countColumn, alignment: .trailing)
    }
}
