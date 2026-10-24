import Foundation
import Darwin
import SwiftUI
#if canImport(UIKit)
import UIKit
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
    private let lock = NSLock()
    private var record: StartDiag.Record
    private let t0 = Date()
    /// Laatste moment dat de hoofdthread reageerde (bewaking)
    private var mainAlive = Date()
    private var started = false

    /// Het rapport van de vorige start (nil = die ging goed of is gewist)
    private(set) var lastProblem: StartDiag.Problem?

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

    // MARK: starten

    /// Zo vroeg mogelijk (eerste opgeslagen eigenschap van BingrApp): de vorige start beoordelen, de vangnetten zetten en
    /// de bewaking starten.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let crashLog = Self.readCrashFile()
        let prev = defaults.data(forKey: currentKey).flatMap { try? JSONDecoder().decode(StartDiag.Record.self, from: $0) }
        if let p = StartDiag.analyze(prev, crashLog: crashLog) {
            lastProblem = p
            if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: problemKey) }
        } else {
            lastProblem = defaults.data(forKey: problemKey).flatMap { try? JSONDecoder().decode(StartDiag.Problem.self, from: $0) }
        }
        Self.installHandlers()
        mark("gestart")
        startWatch()
    }

    /// Mijlpaal (alleen de eerste keer per naam), meteen weggeschreven.
    func mark(_ name: String) {
        lock.lock()
        if record.marks.contains(where: { $0.name == name }) || record.finished { lock.unlock(); return }
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

    func has(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return record.marks.contains { $0.name == name } }

    /// Build 146: mijlpalen van deze start (voor de tab Diagnose en de bijlage `milestones`)
    var currentMarks: [StartDiag.Mark] { lock.lock(); defer { lock.unlock() }; return record.marks }

    /// Seconden sinds de start van de app
    var uptime: TimeInterval { Date().timeIntervalSince(t0) }

    func clearProblem() {
        lastProblem = nil
        defaults.removeObject(forKey: problemKey)
    }

    // MARK: hoofdthread-bewaking (watchdog-vermoeden)

    private func startWatch() {
        let t = Thread { [weak self] in
            while let self {
                DispatchQueue.main.async { self.lock.lock(); self.mainAlive = Date(); self.lock.unlock() }
                Thread.sleep(forTimeInterval: 1)
                self.lock.lock()
                let stuck = Date().timeIntervalSince(self.mainAlive)
                var r: StartDiag.Record?
                // geheugen: hoogste waarde bewaren (een kill door de geheugenlimiet laat verder geen spoor na)
                if let mb = StartDiagnostics.footprintMB(), mb >= (self.record.peakMB ?? 0) + 25 {
                    self.record.peakMB = mb
                    r = self.record
                }
                if stuck >= StartDiag.hangLimit, stuck > (self.record.hang ?? 0) + 2 {
                    self.record.hang = (stuck * 10).rounded() / 10
                    self.record.hangAt = self.record.marks.last?.name
                    r = self.record
                }
                let done = self.record.finished && Date().timeIntervalSince(self.t0) > 600
                self.lock.unlock()
                if let r { self.save(r) }
                if done { return }   // na de start niet meer nodig
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
            if let p = problem {
                Text(verbatim: StartDiag.text(p))
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
                    Text(verbatim: marks.map { m in "\(m.name) \(String(format: "%.1f", m.t))s" + (m.mb.map { " \($0)MB" } ?? "") }
                        .joined(separator: " · "))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    subject: "Startdiagnose \(AppDevice.osName) build \(p.build)",
                    message: String(StartDiag.text(p).prefix(4900)), category: "apps",
                    diagnostics: DiagnosticsBuilder.start(problem: p).json)
                result = L("Sent as ticket #%@", String(n))
            } catch {
                result = error.localizedDescription
            }
        }
    }
}
