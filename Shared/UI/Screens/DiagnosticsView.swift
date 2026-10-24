import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// Build 146: tab Diagnose in Instellingen (startdiagnose, app-diagnose en de apparaatgegevens) en de diagnose-bijlage
// voor support (docs/ACCOUNT.md "Diagnose-bijlage", schema 1). Geen persoonsgegevens: geen URL's, servernamen,
// gebruikersnamen, e-mail of de eigen naam van het apparaat.

// MARK: - Apparaat

@MainActor
enum AppDevice {
    /// Hardware-identifier: `hw.machine` (iPhone15,2, AppleTV14,1), op de Mac `hw.model` (Mac14,2); in de simulator het
    /// gesimuleerde model.
    nonisolated static let identifier: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
        #if os(macOS)
        return sysctl("hw.model") ?? "Mac"
        #else
        return sysctl("hw.machine") ?? ""
        #endif
    }()

    nonisolated private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = buf.withUnsafeBufferPointer { p in p.baseAddress.map { String(cString: $0) } ?? "" }
        return s.isEmpty ? nil : s
    }

    /// Leesbaar model ("Apple TV 4K (3rd generation)", "iPhone 16 Pro"), anders de identifier
    static var model: String { DeviceModelName.name(identifier) }

    /// `phone`, `tablet`, `tv` of `desktop`
    static var type: String {
        #if os(tvOS)
        return "tv"
        #elseif os(macOS)
        return "desktop"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #endif
    }

    static var typeTitle: String {
        switch type {
        case "tv": return L("TV")
        case "desktop": return L("Computer")
        case "tablet": return L("Tablet")
        default: return L("Phone")
        }
    }

    static var osName: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: Int? { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } }

    /// BCP 47, bv. `nl-NL`: de taal van de app met de regio van het systeem
    @MainActor static var language: String {
        let lang = Localizer.shared.language
        guard let region = Locale.current.region?.identifier, !lang.contains("-") else { return lang }
        return "\(lang)-\(region)"
    }

    @MainActor static var screen: String? {
        #if os(macOS)
        guard let s = NSScreen.main else { return nil }
        let f = s.frame.size, k = s.backingScaleFactor
        return "\(Int(f.width * k))x\(Int(f.height * k))"
        #else
        let b = UIScreen.main.nativeBounds.size
        let w = Int(max(b.width, b.height)), h = Int(min(b.width, b.height))
        return "\(w)x\(h)"
        #endif
    }
}

// MARK: - Bijlage

@MainActor
enum DiagnosticsBuilder {
    /// Gemeenschappelijk deel: app en apparaat (bij elke diagnose)
    static func base(_ kind: SupportDiagnostics.Kind) -> SupportDiagnostics {
        var d = SupportDiagnostics(kind: kind, platform: AccountService.entitlementsPlatform, version: AppDevice.version,
                                   build: AppDevice.build, engine: UserDefaults.standard.string(forKey: "player.engine") ?? "auto",
                                   deviceType: AppDevice.type, model: AppDevice.model, os: AppDevice.osName,
                                   osVersion: AppDevice.osVersion, language: AppDevice.language)
        d.screen = AppDevice.screen
        var mem: [String: Any] = ["totalMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)]
        if let app = StartDiagnostics.footprintMB() { mem["appMB"] = app }
        d.memory = mem
        return d
    }

    /// Startdiagnose: de mijlpalen (en de crash) van de vorige start als er een rapport is, anders die van deze start.
    /// Build 147: altijd met `start` (deze start én de vorige), `fetch`, `network` en `storage` (schema 2).
    static func start(problem: StartDiag.Problem?, playlists: PlaylistService? = nil) -> SupportDiagnostics {
        var d = base(.start)
        let marks = problem?.marks ?? StartDiagnostics.shared.currentMarks
        d.milestones = marks.map { (name: $0.name, seconds: $0.t, ok: nil) }
        if let p = problem {
            d.crash = SupportDiagnostics.crash(from: p)
            if let peak = p.peakMB { d.memory?["appMB"] = peak }
        }
        enrich(&d, problem: problem, playlists: playlists)
        return d
    }

    /// Build 147 (schema 2): startsamenvatting, vorige start, ophalen per server, verbinding en opslag. Bij elke diagnose.
    static func enrich(_ d: inout SupportDiagnostics, problem: StartDiag.Problem?, playlists: PlaylistService?) {
        d.start = startBlock(problem: problem)
        if let pl = playlists ?? CrossServer.shared.playlists { d.fetch = FetchLog.shared.rows(playlists: pl) }
        var net: [String: Any] = ["type": NetworkType.shared.current]
        if let on = NetworkType.shared.isOnline { net["online"] = on }
        if let old = d.state?["network"] as? [String: Any] {
            for k in ["backend", "backendMs", "provider", "providerMs"] { if let v = old[k] { net[k] = v } }
            if var s = d.state { var n = old; n["type"] = net["type"]; s["network"] = n; d.state = s }
        }
        d.network = net
        d.storage = StorageSnapshot.shared.json
        // build 148 (schema 3): app-taal, de laatste 5 keer bijwerken, haperingen tijdens het afspelen
        d.lang = Localizer.shared.language
        d.updates = UpdateLog.shared.rows
        d.playback = PlaybackLog.shared.json
    }

    /// `start`: deze start (app-tijd, wachten op de gebruiker, langste hang) of de start van het rapport, en altijd de
    /// vorige start (`previous`) met zijn probleem.
    static func startBlock(problem: StartDiag.Problem?) -> [String: Any] {
        var out: [String: Any]
        if let p = problem {
            let split = StartTiming.split(p.marks, end: p.marks.first { StartTiming.named($0, StartDiag.finalMark) }?.t)
            var sum = StartTiming.summary(appMs: split.appMs, hang: p.kind == .hang ? p.seconds : nil, crashed: p.kind == .crash)
            if p.kind == .notFinished && sum == .good { sum = .slow }
            out = ["summary": sum.rawValue, "appMs": split.appMs, "userWaitMs": split.userWaitMs]
            if p.kind == .hang { out["maxHangMs"] = Int(p.seconds * 1000) }
        } else {
            let c = StartDiagnostics.shared.currentStart
            out = ["summary": c.summary.rawValue, "appMs": c.split.appMs, "userWaitMs": c.split.userWaitMs,
                   "maxHangMs": Int(c.maxHang * 1000)]
            // build 148 (schema 3): langste hang van deze start, met taak, mijlpaal, voorgrond en stack
            let h = StartDiagnostics.shared.currentHang
            if h.seconds > 0 {
                out["longestHang"] = LongestHang.json(seconds: h.seconds, task: h.task, milestone: h.milestone,
                                                      foreground: h.foreground, stack: h.stack)
            }
        }
        if let prev = StartDiagnostics.shared.previous { out["previous"] = prev }
        return out
    }

    /// Samenvatting voor bovenaan (tekst): "Start: goed / traag / vastgelopen" met app-tijd en wachttijd.
    static func summaryLine(problem: StartDiag.Problem?) -> String {
        let b = startBlock(problem: problem)
        let sum = StartTiming.Summary(rawValue: b["summary"] as? String ?? "") ?? .good
        let title: String
        switch sum {
        case .good: title = L("Start: good")
        case .slow: title = L("Start: slow")
        case .hung: title = L("Start: stuck")
        }
        let app = Double(b["appMs"] as? Int ?? 0) / 1000, wait = Double(b["userWaitMs"] as? Int ?? 0) / 1000
        return title + " · " + L("app %@ s, waiting for you %@ s", String(format: "%.1f", app), String(format: "%.1f", wait))
    }
}

// MARK: - App-diagnose

@MainActor
final class DiagnosticsModel: ObservableObject {
    struct Row: Identifiable { let id = UUID(); let title: String; let value: String }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var running = false
    @Published private(set) var result: String?
    @Published private(set) var sending = false
    private(set) var report: SupportDiagnostics?
    private var text = ""

    /// "Diagnose maken": de staat van de app, een korte netwerkcheck, opslag en geheugen.
    func run(playlists: PlaylistService) async {
        guard !running else { return }
        running = true
        result = nil
        defer { running = false }
        let store = CloudStore.shared
        let account = AccountService.shared
        var d = DiagnosticsBuilder.base(.app)
        d.milestones = StartDiagnostics.shared.currentMarks.map { (name: $0.name, seconds: $0.t, ok: nil) }

        // netwerk: Bingr-server (device-auth ping) en de eigen IPTV-server (HEAD, niets gelogd of meegestuurd)
        let backend = await account.backendPing()
        let provider = await Self.providerCheck(playlists.source)
        func level(_ ok: Bool, _ ms: Int) -> String { !ok ? "fail" : (ms > 1500 ? "slow" : "ok") }
        var network: [String: Any] = ["online": backend.ok || provider?.ok == true, "type": NetworkType.shared.current,
                                      "backend": level(backend.ok, backend.ms), "backendMs": backend.ms]
        if let provider {
            network["provider"] = level(provider.ok, provider.ms)
            network["providerMs"] = provider.ms
        } else {
            network["provider"] = "skipped"
        }

        // opslag (build 147: één totaal met cache, catalogus en downloads die samen het totaal zijn; buiten de hoofdthread)
        let st = await StorageSnapshot.shared.refresh()
        let cacheMB = st.cacheMB, dbMB = st.catalogMB, downloadsMB = st.downloadsMB
        var storage: [String: Any] = ["cacheMB": cacheMB, "dbMB": dbMB, "usedMB": st.totalMB]
        if let free = st.freeMB { storage["freeMB"] = free }

        // servers: aantal, soort en hoe lang geleden bijgewerkt (zonder naam of adres)
        let lib = playlists.library
        let updated = store.playlists.map { Self.updatedAt($0) }
        var state: [String: Any] = [
            "signedIn": Secrets.accountsConfigured && account.isSignedIn,
            "profiles": store.profiles.count,
            "servers": store.playlists.count,
            "serverKinds": Array(Set(store.playlists.map { $0.kind.rawValue })).sorted(),
            "pushEnabled": PushService.isSupported && PushService.shared.isOn,
            "channels": lib.channels.count, "movies": lib.movies.count, "series": lib.series.count,
            "uptimeS": Int(StartDiagnostics.shared.uptime),
            "network": network, "storage": storage,
        ]
        if let sync = store.lastSync { state["lastSync"] = SupportDiagnostics.iso(sync) }
        if let plan = EntitlementsService.shared.plan { state["plan"] = plan.rawValue }
        d.state = state
        // build 147: altijd ook de startdiagnose (deze en de vorige start), ophalen per server, verbinding en opslag
        DiagnosticsBuilder.enrich(&d, problem: nil, playlists: playlists)
        report = d

        // wat er in beeld (en in het bericht) komt
        let mode = StartLoad.mode(UserDefaults.standard.string(forKey: StartLoad.key))
        var r: [Row] = []
        r.append(Row(title: L("Servers"), value: "\(store.playlists.count)"))
        for (i, u) in updated.enumerated() {
            r.append(Row(title: L("Server %d", i + 1), value: u.map { L("Updated %@", Self.relative($0)) } ?? L("Not loaded yet")))
        }
        r.append(Row(title: L("Load servers on open"), value: mode.title))
        r.append(Row(title: L("Last account sync"), value: store.lastSync.map { Self.relative($0) } ?? "–"))
        r.append(Row(title: L("Bingr server"), value: backend.ok ? L("Reachable (%d ms)", backend.ms) : L("Not reachable")))
        if let provider {
            r.append(Row(title: L("Your server"), value: provider.ok ? L("Reachable (%d ms)", provider.ms) : L("Not reachable")))
        }
        r.insert(Row(title: L("Start"), value: DiagnosticsBuilder.summaryLine(problem: nil)), at: 0)
        if let h = DiagText.longestHang() { r.insert(Row(title: " ", value: h), at: 1) }
        r.append(Row(title: L("Connection"), value: Self.networkTitle(NetworkType.shared.current)))
        r.append(Row(title: L("Storage"), value: "\(st.totalMB) MB"))
        r.append(Row(title: "  " + L("Cache"), value: "\(cacheMB) MB"))
        r.append(Row(title: "  " + L("Catalog"), value: "\(dbMB) MB"))
        #if os(iOS)
        r.append(Row(title: "  " + L("Downloads"), value: "\(downloadsMB) MB"))
        #endif
        if let free = st.freeMB { r.append(Row(title: L("Free on this device"), value: "\(free) MB")) }
        for f in d.fetch {
            guard let srv = f["server"] as? String, let kind = f["kind"] as? String, let status = f["status"] as? String else { continue }
            // build 148: "36.593 geleverd · 10.286 zichtbaar (26.307 verborgen door categorieën)"
            let value = (status == "failed" ? nil : DiagText.delivered(f))
                ?? Self.fetchTitle(status, count: f["count"] as? Int, error: f["error"] as? String)
            r.append(Row(title: "\(srv.uppercased()) · \(Self.kindTitle(kind))", value: value))
        }
        // build 148: de laatste keren bijwerken per server (fasen met duur en geheugen)
        for u in d.updates {
            r.append(Row(title: L("Update %@", (u["server"] as? String ?? "?").uppercased()), value: DiagText.update(u)))
        }
        // build 148: haperingen tijdens het afspelen
        r.append(Row(title: L("Playback"), value: DiagText.stalls(PlaybackLog.shared.entries)))
        if let app = StartDiagnostics.footprintMB() {
            r.append(Row(title: L("Memory"), value: "\(app) MB / \(Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)) MB"))
        }
        r.append(Row(title: L("Profiles"), value: "\(store.profiles.count)"))
        r.append(Row(title: L("Watch progress"), value: L("%d titles", store.progress.count)))
        rows = r

        // tekst voor het ticket (build 148: in de taal van de app, dezelfde regels als in beeld; zonder namen of adressen)
        var t: [String] = [L("App diagnostics") + " \(AppDevice.osName) \(AppDevice.osVersion), build \(AppDevice.version) (\(AppDevice.build.map(String.init) ?? "?"))"]
        t.append("\(L("Device type")): \(AppDevice.typeTitle) · \(AppDevice.model) · \(L("Language")) \(AppDevice.language)")
        t += r.map { $0.title.trimmingCharacters(in: .whitespaces).isEmpty ? $0.value : "\($0.title.trimmingCharacters(in: .whitespaces)): \($0.value)" }
        if let p = StartDiagnostics.shared.lastProblem { t.append(DiagText.problem(p)) }
        text = t.joined(separator: "\n")
    }

    /// "Naar support sturen": ticket met de app-diagnose als bijlage (`app_create`).
    func send() async {
        guard let report, !sending else { return }
        sending = true
        result = nil
        defer { sending = false }
        do {
            let n = try await SupportCenter.shared.create(subject: L("App diagnostics %@ build %@", AppDevice.osName, AppDevice.build.map(String.init) ?? "?"),
                                                          message: text, category: "apps", diagnostics: report.json)
            result = L("Sent as ticket #%@", String(n))
        } catch {
            result = error.localizedDescription
        }
    }

    var preview: String { report?.prettyText ?? "" }

    // MARK: hulpjes

    /// HEAD op de eigen server (alleen bereikbaarheid: elk HTTP-antwoord telt). nil = geen server of geen adres.
    private static func providerCheck(_ s: PlaylistSource?) async -> (ok: Bool, ms: Int)? {
        guard let s else { return nil }
        let raw = s.kind == .m3u ? s.m3uURL : s.serverURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: c)
        defer { session.invalidateAndCancel() }
        let t0 = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp is HTTPURLResponse, Int(Date().timeIntervalSince(t0) * 1000))
        } catch {
            return (false, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }

    static func networkTitle(_ t: String) -> String {
        switch t {
        case "wifi": return L("Wi-Fi")
        case "cellular": return L("Mobile")
        case "ethernet": return L("Ethernet")
        case "none": return L("Offline")
        default: return L("Unknown")
        }
    }

    static func kindTitle(_ k: String) -> String {
        switch k {
        case "live": return L("Live TV")
        case "movie": return L("Movies")
        default: return L("Series")
        }
    }

    static func fetchTitle(_ status: String, count: Int?, error: String?) -> String {
        switch status {
        case "ok": return L("Delivered (%d)", count ?? 0)
        case "empty": return L("Provider delivered nothing")
        case "hidden": return L("All hidden (%d)", count ?? 0)
        default: return L("Fetch failed (%@)", error ?? "?")
        }
    }

    static func updatedAt(_ s: PlaylistSource) -> Date? {
        let a = try? FileManager.default.attributesOfItem(atPath: PlaylistService.cacheURL(s).path)
        return a?[.modificationDate] as? Date
    }

    nonisolated static func fileMB(_ url: URL) -> Int {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Int(((a?[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576)
    }

    nonisolated static func sizeMB(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return Int(total / 1_048_576)
    }

    nonisolated static func freeMB() -> Int? {
        let v = try? AppDirs.caches.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacity.map { $0 / 1_048_576 }
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Localizer.shared.locale
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    private static func relativeNL(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Weergave

/// Instellingen → Diagnose
struct DiagnosticsView: View {
    @EnvironmentObject var playlists: PlaylistService
    @ObservedObject private var account = AccountService.shared
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        List {
            DeviceInfoSection()
            StartDiagnosticsSection()
            Section {
                Button {
                    Task { await model.run(playlists: playlists) }
                } label: {
                    HStack {
                        Label(model.rows.isEmpty ? L("Run diagnostics") : L("Run again"), systemImage: "stethoscope")
                        if model.running { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.running)
                ForEach(model.rows) { r in LabeledContent(r.title, value: r.value) }
                if !model.rows.isEmpty {
                    NavigationLink { DiagnosticsPreview(text: model.preview) } label: {
                        Label(L("View what is sent"), systemImage: "doc.text.magnifyingglass")
                    }
                    if Secrets.accountsConfigured && account.isSignedIn {
                        Button {
                            Task { await model.send() }
                        } label: {
                            HStack {
                                Label(L("Send to support"), systemImage: "paperplane")
                                if model.sending { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.sending)
                    } else {
                        Text(L("Sign in to send this to support.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let r = model.result { Text(r).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(L("App diagnostics")) } footer: {
                Text(L("No personal data: no addresses, server names, user names or email addresses."))
            }
        }
        .navigationTitle(L("Diagnostics"))
    }
}

/// Apparaattype, model, systeem, app-versie en taal (bij elke diagnose zichtbaar en meegestuurd)
struct DeviceInfoSection: View {
    var body: some View {
        Section(L("This device")) {
            LabeledContent(L("Device type"), value: AppDevice.typeTitle)
            LabeledContent(L("Model"), value: AppDevice.model)
            LabeledContent(L("System"), value: "\(AppDevice.osName) \(AppDevice.osVersion)")
            LabeledContent(L("App version"), value: "\(AppDevice.version) (\(AppDevice.build.map(String.init) ?? "?"))")
            LabeledContent(L("Language"), value: AppDevice.language)
        }
    }
}

/// "Bekijken": precies wat er meegaat
struct DiagnosticsPreview: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(L("Diagnostics"))
    }
}
