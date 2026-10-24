import Foundation
import Darwin
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Build 143: eigen startdiagnose, zodat zichtbaar wordt waar een start misgaat, ook zonder Xcode of crashlog.
///
/// - Mijlpalen bij het starten (gestart, account, profiel, servers, catalogus, Home, eerste frame, klaar; ook profiel
///   gekozen en pincodescherm) gaan meteen naar UserDefaults, met tijd, build en OS.
/// - Kwam de vorige start niet bij "klaar", stond de hoofdthread langer dan 10 s vast (watchdog-vermoeden) of crashte de
///   app, dan bewaart de volgende start dat als rapport (`lastProblem`). Mijn Bingr → Instellingen → Over toont het, met
///   een knop om het als supportticket te sturen.
/// - Vangnet: NSException-handler (type, reden, `Thread.callStackSymbols`) en een signal-handler (SIGABRT, SIGSEGV, SIGBUS,
///   SIGTRAP, SIGILL, SIGFPE) die alleen async-signal-safe naar een vooraf geopend bestand schrijft (signaal en backtrace).
/// - Geen persoonsgegevens: alleen mijlpalen, tijden, build, OS en stack-symbolen (zie `StartDiag.scrub`).
final class StartDiagnostics: @unchecked Sendable {
    static let shared = StartDiagnostics()

    private let defaults = UserDefaults.standard
    private let currentKey = "diag.start.current.v143"
    private let problemKey = "diag.start.problem.v143"
    private let previousKey = "diag.start.previous.v147"
    private let lock = NSLock()
    private var record: StartDiag.Record
    private let t0 = Date()
    /// Laatste moment dat de hoofdthread reageerde (bewaking), in monotone seconden (`DispatchTime`)
    private var mainAlive: Double = 0
    private var started = false
    /// Build 147: staat de app op de voorgrond? (achtergrond telt niet als hang)
    private var foreground = true
    /// Build 147: lopende hang (begin) en of er al een stack van gemaakt is
    private var hangSampled = 0.0

    /// Het rapport van de vorige start (nil = die ging goed of is gewist)
    private(set) var lastProblem: StartDiag.Problem?
    /// Build 147: samenvatting van de vorige start (ook zonder probleem), voor `start.previous` in elke diagnose
    private(set) var previous: [String: Any]?

    private init() {
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let os = "tvOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #elseif os(macOS)
        let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        let os = "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
        record = StartDiag.Record(build: build, os: os, started: Date().timeIntervalSince1970)
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    // MARK: starten

    /// Zo vroeg mogelijk (eerste opgeslagen eigenschap van BingrApp): de vorige start beoordelen, de vangnetten zetten en
    /// de bewaking starten.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        MainThreadSampler.captureMainThread()
        NetworkType.shared.start()   // build 147: verbinding vroeg volgen
        let crashLog = Self.readCrashFile()
        let prev = defaults.data(forKey: currentKey).flatMap { try? JSONDecoder().decode(StartDiag.Record.self, from: $0) }
        if let p = StartDiag.analyze(prev, crashLog: crashLog) {
            lastProblem = p
            if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: problemKey) }
        } else {
            lastProblem = defaults.data(forKey: problemKey).flatMap { try? JSONDecoder().decode(StartDiag.Problem.self, from: $0) }
        }
        if let prev {
            let pv = Self.previousSummary(prev, crashLog: crashLog)
            previous = pv
            if JSONSerialization.isValidJSONObject(pv), let d = try? JSONSerialization.data(withJSONObject: pv) {
                defaults.set(d, forKey: previousKey)
            }
        } else if let d = defaults.data(forKey: previousKey) {
            previous = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        Self.installHandlers()
        observeForeground()
        mark("gestart")
        startWatch()
    }

    /// Build 147: `start.previous` (schema 2): probleem, mijlpaal, seconden, voorgrond, taak en stack van de vorige start.
    private static func previousSummary(_ r: StartDiag.Record, crashLog: String?) -> [String: Any] {
        let crashed = r.crash != nil || !(crashLog ?? "").isEmpty
        let problem = StartPrevious.problem(crashed: crashed, hang: r.hang, finished: r.finished,
                                            waitingOnUser: StartPrevious.waitingOnUser(r.marks))
        var out: [String: Any] = ["problem": problem.rawValue, "at": SupportDiagnostics.iso(Date(timeIntervalSince1970: r.started))]
        if let b = SupportDiagnostics.buildNumber(r.build) { out["build"] = b }
        let lastMark = (problem == .hang ? r.hangAt : nil) ?? r.marks.last?.name
        // build 148 (schema 3): mijlpaal en taak als code
        if let m = lastMark.flatMap({ DiagCode.code($0) ?? SupportDiagnostics.milestoneName($0) }) { out["milestone"] = m }
        switch problem {
        case .hang:
            out["seconds"] = r.hang ?? 0
            out["foreground"] = r.hangFg ?? true
            if let t = r.hangTask { out["task"] = DiagCode.task(t) ?? String(StartDiag.scrub(t).prefix(60)) }
            let st = StartDiag.scrub(lines: r.hangStack ?? [])
            if !st.isEmpty { out["stack"] = Array(st.prefix(30)) }
        case .crash:
            out["seconds"] = r.marks.last?.t ?? 0
            let lines = (crashLog.map { $0.split(separator: "\n").map(String.init) } ?? []) + r.stack
            let st = StartDiag.scrub(lines: lines)
            if !st.isEmpty { out["stack"] = Array(st.prefix(30)) }
        case .notFinished, .none:
            out["seconds"] = r.marks.last?.t ?? 0
            if let t = r.hangTask { out["task"] = DiagCode.task(t) ?? String(StartDiag.scrub(t).prefix(60)) }
        }
        return out
    }

    /// Mijlpaal (alleen de eerste keer per naam), meteen weggeschreven. Build 147: ook na "klaar" (max. 40), zodat te zien
    /// is wat er daarna gebeurde.
    func mark(_ raw: String) {
        // build 148: mijlpalen als code (oude Nederlandse namen worden omgezet)
        let name = DiagCode.code(raw) ?? raw
        lock.lock()
        if record.marks.contains(where: { $0.name == name }) || record.marks.count >= 40 { lock.unlock(); return }
        let mb = Self.footprintMB()
        record.marks.append(.init(name: name, t: (Date().timeIntervalSince(t0) * 10).rounded() / 10, mb: mb))
        if let mb { record.peakMB = max(record.peakMB ?? 0, mb) }
        if name == StartDiag.finalMark { record.finished = true }
        let r = record
        lock.unlock()
        save(r)
        if SmokeTest.isActive { SmokeTest.say("mijlpaal \(name) (\(Self.footprintMB() ?? -1) MB)") }
    }

    /// Geheugengebruik van de app zoals het systeem het telt (phys_footprint, de maat voor de geheugenlimiet), in MB.
    static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    private func save(_ r: StartDiag.Record) {
        if let d = try? JSONEncoder().encode(r) { defaults.set(d, forKey: currentKey) }
    }

    func has(_ raw: String) -> Bool {
        let name = DiagCode.code(raw) ?? raw
        lock.lock(); defer { lock.unlock() }; return record.marks.contains { $0.name == name }
    }

    /// Build 148: langste hang van deze start (`start.longestHang`): duur, taak, mijlpaal, voorgrond en stack
    var currentHang: (seconds: Double, task: String?, milestone: String?, foreground: Bool, stack: [String]) {
        lock.lock(); let r = record; lock.unlock()
        return (r.hang ?? 0, r.hangTask, r.hangAt, r.hangFg ?? true, StartDiag.scrub(lines: r.hangStack ?? []))
    }

    /// Build 148: hoogste geheugengebruik van deze sessie (MB)
    var peakMB: Int? { lock.lock(); defer { lock.unlock() }; return record.peakMB }

    /// Build 146: mijlpalen van deze start (voor de tab Diagnose en de bijlage `milestones`)
    var currentMarks: [StartDiag.Mark] { lock.lock(); defer { lock.unlock() }; return record.marks }

    /// Build 147: deze start: app-tijd, wachten op de gebruiker, langste hang en de samenvatting (goed/traag/vastgelopen)
    var currentStart: (split: StartTiming.Split, maxHang: Double, summary: StartTiming.Summary, finished: Bool) {
        lock.lock(); let r = record; lock.unlock()
        let end = r.marks.first { StartTiming.named($0, StartDiag.finalMark) }?.t
        let split = StartTiming.split(r.marks, end: end)
        let hang = r.hang ?? 0
        return (split, hang, StartTiming.summary(appMs: split.appMs, hang: hang, crashed: false), r.finished)
    }

    /// Seconden sinds de start van de app
    var uptime: TimeInterval { Date().timeIntervalSince(t0) }

    func clearProblem() {
        lastProblem = nil
        defaults.removeObject(forKey: problemKey)
    }

    // MARK: voorgrond / achtergrond (build 147)

    private func observeForeground() {
        let nc = NotificationCenter.default
        #if canImport(UIKit)
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(false) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(true) }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(true) }
        #elseif os(macOS)
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(false) }
        nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(true) }
        #endif
    }

    private func setForeground(_ fg: Bool) {
        lock.lock()
        foreground = fg
        mainAlive = Self.now()   // de tijd op de achtergrond telt nooit als hang
        lock.unlock()
    }

    // MARK: hoofdthread-bewaking

    /// Build 147: elke halve seconde. Een hang telt alleen op de voorgrond; was het proces zelf stilgezet (achtergrond,
    /// slaapstand: de bewaking liep zelf ook niet), dan begint de meting opnieuw. Vanaf 2 s: de taak/fase en een
    /// momentopname van de stack van de hoofdthread (bij 2 s en nog eens bij 8 s, de laatste blijft). Loopt de hele sessie.
    private func startWatch() {
        lock.lock(); mainAlive = Self.now(); lock.unlock()
        let t = Thread { [weak self] in
            var lastTick = StartDiagnostics.now()
            var lastMem = 0.0
            while let self {
                DispatchQueue.main.async { let n = StartDiagnostics.now(); self.lock.lock(); self.mainAlive = n; self.lock.unlock() }
                Thread.sleep(forTimeInterval: 0.5)
                let now = StartDiagnostics.now()
                let gap = now - lastTick
                lastTick = now
                self.lock.lock()
                if gap > 3 || !self.foreground {
                    // het proces stond stil (of de app is op de achtergrond): geen hang
                    self.mainAlive = now
                    self.hangSampled = 0
                    self.lock.unlock()
                    continue
                }
                let stuck = now - self.mainAlive
                var r: StartDiag.Record?
                // geheugen: hoogste waarde bewaren (een kill door de geheugenlimiet laat verder geen spoor na)
                if now - lastMem >= 1 {
                    lastMem = now
                    if let mb = StartDiagnostics.footprintMB(), mb >= (self.record.peakMB ?? 0) + 25 {
                        self.record.peakMB = mb
                        r = self.record
                    }
                }
                var wantSample = false
                if stuck >= StartTiming.slowHang {
                    if self.hangSampled == 0 {
                        self.record.hangs = (self.record.hangs ?? 0) + 1
                        wantSample = true
                    } else if stuck >= 8 && self.hangSampled < 8 {
                        wantSample = true
                    }
                    if stuck > (self.record.hang ?? 0) + 0.4 {
                        self.record.hang = (stuck * 10).rounded() / 10
                        self.record.hangAt = self.record.marks.last?.name
                        self.record.hangTask = MainTasks.shared.current
                        self.record.hangFg = true
                        r = self.record
                    }
                } else if stuck < 1 {
                    self.hangSampled = 0
                }
                let isLongest = (self.record.hang ?? 0) <= stuck + 0.5
                self.lock.unlock()
                if wantSample {
                    let stack = MainThreadSampler.sample()
                    self.lock.lock()
                    self.hangSampled = stuck
                    if isLongest, !stack.isEmpty { self.record.hangStack = stack; r = self.record }
                    self.lock.unlock()
                }
                if let r { self.save(r) }
            }
        }
        t.name = "bingr.diag.watch"
        t.qualityOfService = .utility
        t.start()
    }

    // MARK: vangnetten

    private static var crashURL: URL {
        AppDirs.caches.appendingPathComponent("diag-crash.v143.txt")
    }

    private static func readCrashFile() -> String? {
        guard let s = try? String(contentsOf: crashURL, encoding: .utf8), !s.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: crashURL)
        return s
    }

    private static func installHandlers() {
        #if os(tvOS)
        // build 144: op Apple TV (nog) geen signal-handlers en geen crashbestand bij de start (tot bewezen veilig op het
        // toestel); de mijlpalen en de NSException-handler blijven
        NSSetUncaughtExceptionHandler { e in StartDiagnostics.shared.noteException(e) }
        return
        #else
        // bestand vooraf openen: de signal-handler mag alleen write/backtrace gebruiken
        let path = crashURL.path
        FileManager.default.createFile(atPath: path, contents: nil)
        crashFD = open(path, O_WRONLY | O_TRUNC)
        NSSetUncaughtExceptionHandler { e in StartDiagnostics.shared.noteException(e) }
        guard crashFD >= 0 else { return }
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE] {
            signal(s, bingrSignalHandler)
        }
        #endif
    }

    fileprivate func noteException(_ e: NSException) {
        lock.lock()
        record.crash = "\(e.name.rawValue): \(e.reason ?? "")"
        record.stack = Array(e.callStackSymbols.prefix(60))
        let r = record
        lock.unlock()
        save(r)
    }

    /// Test (start-rooktest, `-BingrSmokeCrash YES`): bewust crashen, de volgende start moet het rapport tonen.
    static func forceCrash() -> Never {
        let a: [Int] = []
        _ = a[a.count + 1]   // index buiten de lijst → SIGTRAP (Swift-runtimefout)
        fatalError("start-rooktest")
    }
}

/// Vooraf geopend bestand voor de signal-handler (-1 = niet open)
private var crashFD: Int32 = -1

/// Async-signal-safe: alleen write(2), backtrace(3) en backtrace_symbols_fd(3); daarna het standaardgedrag (crashrapport
/// van het systeem blijft zo bestaan).
private func bingrSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        var head: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
            (0x73, 0x69, 0x67, 0x6e, 0x61, 0x6c, 0x20, 0x00, 0x00, 0x00, 0x0a, 0x00)   // "signal " + nummer + "\n"
        let n = Int(sig)
        head.7 = CChar(0x30 + (n / 10) % 10)
        head.8 = CChar(0x30 + n % 10)
        head.9 = 0x0a
        withUnsafeBytes(of: &head) { p in _ = write(crashFD, p.baseAddress, 10) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, count, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Build 143/146: Instellingen → Diagnose: het rapport van de vorige start (crash, hang of niet klaar), met een knop om
/// het als supportticket te sturen (build 146: `app_create` met de startdiagnose als bijlage). Zonder rapport: de
/// mijlpalen van deze start.
struct StartDiagnosticsSection: View {
    @ObservedObject private var account = AccountService.shared
    @State private var problem = StartDiagnostics.shared.lastProblem
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        Section {
            // build 147: samenvatting bovenaan (goed / traag / vastgelopen, app-tijd en wachten op de gebruiker)
            Text(verbatim: DiagnosticsBuilder.summaryLine(problem: problem))
                .font(.footnote.weight(.semibold))
            if let p = problem {
                Text(verbatim: DiagText.problem(p))
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(14)
                    .fixedSize(horizontal: false, vertical: true)
                if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                if Secrets.accountsConfigured && account.isSignedIn {
                    Button {
                        send(p)
                    } label: {
                        HStack {
                            Label(L("Send to support"), systemImage: "paperplane")
                            if sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sending)
                } else {
                    Text(L("Sign in to send this to support.")).font(.footnote).foregroundStyle(.secondary)
                }
                Button(L("Dismiss"), role: .destructive) {
                    StartDiagnostics.shared.clearProblem()
                    problem = nil
                }
            } else {
                Label(L("The previous start went fine."), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.green)
                let marks = StartDiagnostics.shared.currentMarks
                if !marks.isEmpty {
                    Text(verbatim: DiagText.marks(marks))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // build 148: langste hang van deze start (duur, taak, mijlpaal)
            if let h = DiagText.longestHang() {
                Text(verbatim: h).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text(L("Start diagnostics")) }
    }

    private func send(_ p: StartDiag.Problem) {
        sending = true
        result = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                let n = try await SupportCenter.shared.create(
                    subject: L("Start diagnostics %@ build %@", AppDevice.osName, p.build),
                    message: String((DiagnosticsBuilder.summaryLine(problem: p) + "\n" + DiagText.problem(p)).prefix(4900)), category: "apps",
                    diagnostics: DiagnosticsBuilder.start(problem: p).json)
                result = L("Sent as ticket #%@", String(n))
            } catch {
                result = error.localizedDescription
            }
        }
    }
}
