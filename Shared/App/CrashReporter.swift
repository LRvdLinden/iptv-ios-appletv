import Foundation
import SwiftUI
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Build 171: eigen crashrapporten, zonder derde partij (docs/ACCOUNT.md → Build 171, device-auth `crash_report`).
/// - MetricKit (`MXCrashDiagnostic`, `MXHangDiagnostic`) levert ze bij de volgende start (niet op Apple TV: daar is
///   geen MetricKit);
/// - een eigen handler voor `NSException` schrijft het rapport meteen naar schijf;
/// - versturen bij de volgende start. Vóór het versturen gaan URL's, query-strings, IP-adressen, e-mailadressen en
///   lange tokens eruit (`Crash171.scrub`). Geeft de server 404 (nog geen `crash_report`), dan blijft het rapport
///   bewaard en volgt een nieuwe poging, hooguit 7 dagen.
/// - Instelling "Crashrapporten delen" (standaard aan) onder Privacy; uit = niets bewaren of versturen.
@MainActor
final class CrashReporter: NSObject {
    static let shared = CrashReporter()

    static let enabledKey = "privacy.crashReports"
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var started = false
    private var flushing = false
    private static let sentKey = "crash.sentTimes"

    nonisolated private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CrashReports171", isDirectory: true)
    }
    nonisolated private static var queueURL: URL { dir.appendingPathComponent("queue.json") }
    nonisolated private static var pendingExceptionURL: URL { dir.appendingPathComponent("exception.json") }

    // MARK: starten

    func start() {
        guard !started, !Screenshots.isActive else { return }
        started = true
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { e in CrashReporter.writeException(e) }
        #if canImport(MetricKit) && !os(tvOS)
        MXMetricManager.shared.add(self)
        #endif
        importPendingException()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self.flush()
        }
    }

    // MARK: NSException (synchroon, de app stopt meteen daarna)

    nonisolated private static func writeException(_ e: NSException) {
        guard enabled else { return }
        let frames = e.callStackSymbols
        let name = e.name.rawValue
        let dict: [String: Any] = [
            "kind": "crash", "name": name, "message": "\(name): \(e.reason ?? "")",
            "frames": Array(frames.prefix(80)), "at": Date().timeIntervalSince1970,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: pendingExceptionURL, options: .atomic)
    }

    private func importPendingException() {
        guard let d = try? Data(contentsOf: Self.pendingExceptionURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: Self.pendingExceptionURL)
        let frames = o["frames"] as? [String] ?? []
        add(kind: o["kind"] as? String ?? "crash", name: o["name"] as? String ?? "NSException",
            message: o["message"] as? String ?? "", frames: frames,
            at: o["at"] as? Double ?? Date().timeIntervalSince1970, appVersion: nil, build: nil)
    }

    // MARK: wachtrij

    private func add(kind: String, name: String, message: String, frames: [String], at: Double,
                     appVersion: String?, build: String?) {
        guard Self.enabled else { return }
        let info = Bundle.main.infoDictionary
        let r = Crash171.Report(kind: kind,
                                signature: Crash171.signature(kind: kind, name: name, frames: frames),
                                message: Crash171.message(message),
                                stack: Crash171.stack(frames.joined(separator: "\n")),
                                at: at, count: 1,
                                appVersion: appVersion ?? (info?["CFBundleShortVersionString"] as? String ?? "?"),
                                build: build ?? (info?["CFBundleVersion"] as? String ?? "?"),
                                osVersion: AccountService.osVersion, deviceModel: Self.deviceModel)
        save(Crash171.enqueue(load(), r, now: Date().timeIntervalSince1970))
    }

    private func load() -> [Crash171.Report] {
        guard let d = try? Data(contentsOf: Self.queueURL) else { return [] }
        return (try? JSONDecoder().decode([Crash171.Report].self, from: d)) ?? []
    }

    private func save(_ q: [Crash171.Report]) {
        if q.isEmpty { try? FileManager.default.removeItem(at: Self.queueURL); return }
        if let d = try? JSONEncoder().encode(q) { try? d.write(to: Self.queueURL, options: .atomic) }
    }

    /// Versturen (bij de start en na een nieuwe MetricKit-levering). Stil bij fouten.
    func flush() async {
        guard !flushing else { return }
        guard Self.enabled else { save([]); return }
        flushing = true
        defer { flushing = false }
        let now = Date().timeIntervalSince1970
        let queue = Crash171.prune(load(), now: now)
        var sent = (UserDefaults.standard.array(forKey: Self.sentKey) as? [Double] ?? []).filter { now - $0 < 3600 }
        var remaining: [Crash171.Report] = []
        var stop = false
        for r in queue {
            if stop || !Crash171.maysend(sent: sent, now: now) { remaining.append(r); continue }
            switch await AccountService.shared.crashReport(body(r)) {
            case .sent: sent.append(now)
            case .retryLater: remaining.append(r); stop = true
            case .drop: break
            }
        }
        UserDefaults.standard.set(sent, forKey: Self.sentKey)
        save(remaining)
    }

    private func body(_ r: Crash171.Report) -> [String: Any] {
        ["platform": Self.platformID, "app_version": r.appVersion, "build": r.build, "os_version": r.osVersion,
         "device_model": r.deviceModel, "kind": r.kind, "signature": r.signature, "message": r.message,
         "stack": r.stack, "at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: r.at)), "count": r.count]
    }

    /// Platform zoals in de changelog: ios, ipados, tvos of macos
    static var platformID: String {
        #if os(tvOS)
        return "tvos"
        #elseif os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// Modelcode (bv. "iPhone16,2"), geen naam van het apparaat
    nonisolated static var deviceModel: String {
        var u = utsname()
        uname(&u)
        let raw = withUnsafeBytes(of: &u.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return raw.isEmpty ? "unknown" : raw
    }

    #if canImport(MetricKit) && !os(tvOS)
    /// Stack van MetricKit (JSON van `MXCallStackTree`): de regels van de thread die crashte, als "i binaire +offset"
    nonisolated static func frames(fromCallStackJSON data: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = o["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var out: [String] = []
        var level = stack?["callStackRootFrames"] as? [[String: Any]] ?? []
        while let f = level.first, out.count < 60 {
            let bin = f["binaryName"] as? String ?? "?"
            let off = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            out.append("\(out.count) \(bin) 0x\(String(off, radix: 16))")
            level = f["subFrames"] as? [[String: Any]] ?? []
        }
        return out
    }
    #endif
}

#if canImport(MetricKit) && !os(tvOS)
extension CrashReporter: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var items: [(kind: String, name: String, message: String, frames: [String], at: Double, version: String?, build: String)] = []
        for p in payloads {
            let at = p.timeStampEnd.timeIntervalSince1970
            for c in p.crashDiagnostics ?? [] {
                let name = [c.exceptionType.map { "exc \($0)" }, c.signal.map { "sig \($0)" }].compactMap { $0 }.joined(separator: " ")
                let msg = [c.terminationReason, c.virtualMemoryRegionInfo].compactMap { $0 }.joined(separator: " · ")
                items.append(("crash", name.isEmpty ? "crash" : name, msg.isEmpty ? name : msg,
                              Self.frames(fromCallStackJSON: c.callStackTree.jsonRepresentation()), at,
                              nil, c.metaData.applicationBuildVersion))
            }
            for h in p.hangDiagnostics ?? [] {
                let secs = Int(h.hangDuration.converted(to: .seconds).value)
                items.append(("anr", "hang", "Hang \(secs) s",
                              Self.frames(fromCallStackJSON: h.callStackTree.jsonRepresentation()), at,
                              nil, h.metaData.applicationBuildVersion))
            }
        }
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for i in items {
                CrashReporter.shared.add(kind: i.kind, name: i.name, message: i.message, frames: i.frames, at: i.at,
                                         appVersion: i.version, build: i.build)
            }
            await CrashReporter.shared.flush()
        }
    }
}
#endif

/// Instellingen → Algemeen → Privacy: "Crashrapporten delen"
struct CrashReportsSettingsSection: View {
    @AppStorage(CrashReporter.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) { Label(L("Share crash reports"), systemImage: "ladybug") }
        } header: {
            Text(L("Privacy"))
        } footer: {
            Text(L("If Bingr crashes or hangs, a report goes to Bingr at the next start. Without addresses of your servers, passwords, IP addresses or e-mail addresses, and not to third parties."))
        }
    }
}
