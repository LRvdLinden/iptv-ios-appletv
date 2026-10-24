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
enum DeviceInfo {
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
        var d = SupportDiagnostics(kind: kind, platform: AccountService.entitlementsPlatform, version: DeviceInfo.version,
                                   build: DeviceInfo.build, engine: UserDefaults.standard.string(forKey: "player.engine") ?? "auto",
                                   deviceType: DeviceInfo.type, model: DeviceInfo.model, os: DeviceInfo.osName,
                                   osVersion: DeviceInfo.osVersion, language: DeviceInfo.language)
        d.screen = DeviceInfo.screen
        var mem: [String: Any] = ["totalMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)]
        if let app = StartDiagnostics.footprintMB() { mem["appMB"] = app }
        d.memory = mem
        return d
    }

    /// Startdiagnose: de mijlpalen (en de crash) van de vorige start als er een rapport is, anders die van deze start.
    static func start(problem: StartDiag.Problem?) -> SupportDiagnostics {
        var d = base(.start)
        let marks = problem?.marks ?? StartDiagnostics.shared.currentMarks
        d.milestones = marks.map { (name: $0.name, seconds: $0.t, ok: nil) }
        if let p = problem {
            d.crash = SupportDiagnostics.crash(from: p)
            if let peak = p.peakMB { d.memory?["appMB"] = peak }
        }
        return d
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
        var network: [String: Any] = ["online": backend.ok || provider?.ok == true, "type": "unknown",
                                      "backend": level(backend.ok, backend.ms), "backendMs": backend.ms]
        if let provider {
            network["provider"] = level(provider.ok, provider.ms)
            network["providerMs"] = provider.ms
        } else {
            network["provider"] = "skipped"
        }

        // opslag (mappen doorlopen buiten de hoofdthread)
        let catalogs = store.playlists.map { PlaylistService.cacheURL($0) }
        let sizes = await Task.detached(priority: .utility) { () -> (cache: Int, db: Int, support: Int, downloads: Int, free: Int?) in
            #if os(iOS)
            let downloads = DiagnosticsModel.sizeMB(AppDirs.support.appendingPathComponent("Downloads", isDirectory: true))
            #else
            let downloads = 0
            #endif
            return (DiagnosticsModel.sizeMB(AppDirs.caches), catalogs.reduce(0) { $0 + DiagnosticsModel.fileMB($1) },
                    DiagnosticsModel.sizeMB(AppDirs.support), downloads, DiagnosticsModel.freeMB())
        }.value
        let cacheMB = sizes.cache, dbMB = sizes.db, downloadsMB = sizes.downloads
        var storage: [String: Any] = ["cacheMB": cacheMB, "dbMB": dbMB, "usedMB": sizes.cache + sizes.support]
        if let free = sizes.free { storage["freeMB"] = free }

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
        r.append(Row(title: L("Cache"), value: "\(cacheMB) MB"))
        #if os(iOS)
        r.append(Row(title: L("Downloads"), value: "\(downloadsMB) MB"))
        #endif
        if let app = StartDiagnostics.footprintMB() {
            r.append(Row(title: L("Memory"), value: "\(app) MB / \(Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)) MB"))
        }
        r.append(Row(title: L("Profiles"), value: "\(store.profiles.count)"))
        r.append(Row(title: L("Watch progress"), value: L("%d titles", store.progress.count)))
        rows = r

        // tekst voor het ticket (vast Nederlands, zoals de startdiagnose; zonder namen of adressen)
        var t: [String] = ["App-diagnose \(DeviceInfo.osName) \(DeviceInfo.osVersion), build \(DeviceInfo.version) (\(DeviceInfo.build.map(String.init) ?? "?"))"]
        t.append("Apparaat: \(DeviceInfo.type) · \(DeviceInfo.model) · taal \(DeviceInfo.language)")
        t.append("Servers: \(store.playlists.count) (\(updated.map { $0.map { Self.relativeNL($0) } ?? "nog niet geladen" }.joined(separator: ", ")))")
        t.append("Servers laden bij openen: \(mode.rawValue)")
        t.append("Profielen: \(store.profiles.count) · zenders \(lib.channels.count), films \(lib.movies.count), series \(lib.series.count)")
        t.append("Laatste account-sync: \(store.lastSync.map { Self.relativeNL($0) } ?? "–")")
        t.append("Bingr-server: \(backend.ok ? "bereikbaar" : "niet bereikbaar") (\(backend.ms) ms)"
                 + (provider.map { " · eigen server: \($0.ok ? "bereikbaar" : "niet bereikbaar") (\($0.ms) ms)" } ?? ""))
        t.append("Opslag: cache \(cacheMB) MB, catalogus \(dbMB) MB, downloads \(downloadsMB) MB")
        text = t.joined(separator: "\n")
    }

    /// "Naar support sturen": ticket met de app-diagnose als bijlage (`app_create`).
    func send() async {
        guard let report, !sending else { return }
        sending = true
        result = nil
        defer { sending = false }
        do {
            let n = try await SupportCenter.shared.create(subject: "App-diagnose \(DeviceInfo.osName) build \(DeviceInfo.build.map(String.init) ?? "?")",
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
            LabeledContent(L("Device type"), value: DeviceInfo.typeTitle)
            LabeledContent(L("Model"), value: DeviceInfo.model)
            LabeledContent(L("System"), value: "\(DeviceInfo.osName) \(DeviceInfo.osVersion)")
            LabeledContent(L("App version"), value: "\(DeviceInfo.version) (\(DeviceInfo.build.map(String.init) ?? "?"))")
            LabeledContent(L("Language"), value: DeviceInfo.language)
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
