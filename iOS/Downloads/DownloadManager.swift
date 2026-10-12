import Foundation
import AVFoundation
import ActivityKit
import UserNotifications
import UIKit

/// Een gedownloade (of downloadende) film of aflevering. Metadata staat op schijf, zodat alles ook
/// zonder netwerk en na het opnieuw starten van de app te zien en af te spelen is.
struct DownloadItem: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case queued, downloading, paused, completed, failed }

    /// "<profiel>|<itemID>"
    var id: String
    var itemID: String
    var title: String
    var subtitle: String?
    var type: MediaType
    var seriesID: String?
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
    var imdbID: String?
    var posterURL: URL?
    /// Poster op schijf (naam in de downloadmap)
    var posterFile: String?
    var sourceID: UUID?
    var profileID: UUID?
    var remoteURL: URL
    /// HLS (.m3u8) gaat via AVAssetDownloadURLSession en wordt een .movpkg
    var isHLS: Bool
    /// Bestand: naam in de downloadmap; HLS: pad ten opzichte van de thuismap (zo wil AVFoundation het)
    var fileName: String?
    var status: Status
    var bytesWritten: Int64 = 0
    var bytesExpected: Int64 = 0
    var progress: Double = 0
    var error: String?
    var retries: Int = 0
    var createdAt = Date()

    var isActive: Bool { status == .queued || status == .downloading }
}

/// Downloads voor offline kijken (alleen iPhone en iPad, build 52).
///
/// - Directe bestanden (Xtream/M3U-VOD, Plex/Jellyfin/Emby) via een achtergrond-`URLSession`: gaat door als de
///   app op de achtergrond staat, en hervat na een onderbreking met *resume data* (tot 5 nieuwe pogingen).
/// - HLS (.m3u8) via `AVAssetDownloadURLSession`.
/// - Voortgang als Live Activity (toegangsscherm/Dynamic Island) en een melding als een download klaar is.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var usedBytes: Int64 = 0

    static let fileSessionID = "nl.lrvdlinden.bingr.downloads"
    static let hlsSessionID = "nl.lrvdlinden.bingr.downloads.hls"
    static let cellularKey = "downloads.cellular"
    private static let maxRetries = 5

    private let delegate = DownloadSessionDelegate()
    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var started = false
    /// Systeem: klaar met de achtergrondgebeurtenissen van een sessie
    var backgroundCompletion: [String: () -> Void] = [:]
    private var fileTasks: [String: URLSessionDownloadTask] = [:]
    private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    private var lastSave = Date.distantPast
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastActivityUpdate = Date.distantPast

    private init() {
        items = Self.loadItems()
        // een download die bij het afsluiten liep, wordt hieronder opnieuw gekoppeld of hervat
        recalcUsage()
    }

    /// Sessies aanmaken (ook bij een start op de achtergrond) en lopende taken opnieuw koppelen.
    func start() {
        guard !started else { return }
        started = true
        // build 60: Live Activity van een vorige keer (app afgesloten of gecrasht) overnemen in plaats van er een
        // tweede naast te zetten; overbodige meteen beëindigen. Zonder lopende downloads gaat hij hieronder weg.
        let existing = Activity<DownloadActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        let fc = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fc.sessionSendsLaunchEvents = true
        fc.isDiscretionary = false
        fc.allowsCellularAccess = true          // per verzoek bepaald (instelling "Mobiele data")
        fc.httpMaximumConnectionsPerHost = 2
        fileSession = URLSession(configuration: fc, delegate: delegate, delegateQueue: nil)
        let hc = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hc.sessionSendsLaunchEvents = true
        hc.isDiscretionary = false
        hlsSession = AVAssetDownloadURLSession(configuration: hc, assetDownloadDelegate: delegate, delegateQueue: .main)

        fileSession.getTasksWithCompletionHandler { _, _, downloads in
            Task { @MainActor in
                for t in downloads { if let id = t.taskDescription { self.fileTasks[id] = t } }
                self.hlsSession.getAllTasks { tasks in
                    Task { @MainActor in
                        for t in tasks { if let a = t as? AVAssetDownloadTask, let id = a.taskDescription { self.hlsTasks[id] = a } }
                        self.resumeOrphans()
                    }
                }
            }
        }
    }

    /// Downloads die liepen maar geen taak meer hebben (app afgesloten): opnieuw starten, met resume data.
    private func resumeOrphans() {
        for d in items where d.isActive {
            if fileTasks[d.id] == nil && hlsTasks[d.id] == nil { begin(d.id) }
        }
        updateActivity(force: true)
    }

    // MARK: lijst

    /// Downloads van het huidige profiel
    var visibleItems: [DownloadItem] {
        let pid = CloudStore.shared.activeProfileID
        return items.filter { $0.profileID == nil || pid == nil || $0.profileID == pid }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                let ka = (a.seriesTitle ?? a.title, a.season ?? 0, a.episode ?? 0)
                let kb = (b.seriesTitle ?? b.title, b.season ?? 0, b.episode ?? 0)
                return ka.0 != kb.0 ? ka.0.localizedStandardCompare(kb.0) == .orderedAscending : (ka.1, ka.2) < (kb.1, kb.2)
            }
    }

    private static func downloadID(_ itemID: String) -> String {
        "\(CloudStore.shared.activeProfileID?.uuidString ?? "-")|\(itemID)"
    }

    func download(for itemID: String) -> DownloadItem? {
        items.first { $0.id == Self.downloadID(itemID) }
    }

    /// Kan deze titel gedownload worden? (geen live TV en geen smb://, ftp:// enz.)
    static func canDownload(_ item: PlayableItem) -> Bool {
        guard item.type == .movie || item.type == .episode else { return false }
        if item.stalkerCmd != nil || item.stremio != nil { return true }
        guard let s = item.url?.scheme?.lowercased() else { return false }
        return s == "http" || s == "https"
    }

    // MARK: starten, pauzeren, verwijderen

    func enqueue(_ item: PlayableItem, seriesTitle: String?, poster: URL?, playlists: PlaylistService) async {
        let id = Self.downloadID(item.id)
        if let existing = items.first(where: { $0.id == id }) {
            if existing.status == .failed || existing.status == .paused { resume(existing.id) }
            return
        }
        guard let url = await playlists.resolve(item), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            notifyFailure(item.subtitle.map { "\(item.title) · \($0)" } ?? item.title, L("This title can't be downloaded."))
            return
        }
        let hls = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
        let d = DownloadItem(id: id, itemID: item.id, title: item.title, subtitle: item.subtitle, type: item.type,
                             seriesID: item.seriesID, seriesTitle: seriesTitle, season: item.season, episode: item.episode,
                             imdbID: item.imdbID, posterURL: poster ?? item.artwork, posterFile: nil,
                             sourceID: item.sourceID ?? playlists.source?.id, profileID: CloudStore.shared.activeProfileID,
                             remoteURL: url, isHLS: hls, fileName: nil, status: .queued)
        items.append(d)
        save(force: true)
        begin(id)
        Task { await fetchPoster(id) }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func begin(_ id: String) {
        start()
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let d = items[i]
        let cellular = UserDefaults.standard.bool(forKey: Self.cellularKey)
        if d.isHLS {
            let asset = AVURLAsset(url: d.remoteURL, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Secrets.userAgent],
                AVURLAssetAllowsCellularAccessKey: cellular
            ])
            guard let t = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: d.title, assetArtworkData: nil,
                                                           options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 2_000_000]) else {
                fail(id, L("This title can't be downloaded.")); return
            }
            t.taskDescription = id
            hlsTasks[id] = t
            t.resume()
        } else {
            let t: URLSessionDownloadTask
            if let data = try? Data(contentsOf: Self.resumeDataURL(id)) {
                t = fileSession.downloadTask(withResumeData: data)
                try? FileManager.default.removeItem(at: Self.resumeDataURL(id))
            } else {
                var r = URLRequest(url: d.remoteURL)
                r.setValue(Secrets.userAgent, forHTTPHeaderField: "User-Agent")
                r.allowsCellularAccess = cellular
                t = fileSession.downloadTask(with: r)
            }
            t.taskDescription = id
            fileTasks[id] = t
            t.resume()
        }
        items[i].status = .downloading
        items[i].error = nil
        save(force: true)
        updateActivity(force: true)
    }

    func pause(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isActive else { return }
        items[i].status = .paused
        if let t = hlsTasks[id] { t.suspend() }
        if let t = fileTasks.removeValue(forKey: id) {
            t.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: Self.resumeDataURL(id)) }
            })
        }
        save(force: true)
        updateActivity(force: true)
    }

    func resume(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status == .paused || items[i].status == .failed else { return }
        items[i].retries = 0
        if let t = hlsTasks[id], t.state == .suspended {
            items[i].status = .downloading
            t.resume()
            save(force: true); updateActivity(force: true)
            return
        }
        hlsTasks[id] = nil
        begin(id)
    }

    func delete(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let d = items.remove(at: i)
        fileTasks.removeValue(forKey: id)?.cancel()
        hlsTasks.removeValue(forKey: id)?.cancel()
        if let url = Self.localURL(d) { try? FileManager.default.removeItem(at: url) }
        if let p = d.posterFile { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(p)) }
        try? FileManager.default.removeItem(at: Self.resumeDataURL(id))
        save(force: true)
        recalcUsage()
        updateActivity(force: true)
    }

    // MARK: afspelen

    /// Afspeelbaar item met het bestand op dit toestel (werkt zonder netwerk; voortgang blijft per titel bewaard).
    func playable(_ d: DownloadItem) -> PlayableItem? {
        guard d.status == .completed, let url = Self.localURL(d), FileManager.default.fileExists(atPath: url.path) else { return nil }
        var p = PlayableItem(id: d.itemID, title: d.title, subtitle: d.subtitle, url: url, type: d.type, imdbID: d.imdbID,
                             season: d.season, episode: d.episode,
                             artwork: d.posterFile.map { Self.folder.appendingPathComponent($0) } ?? d.posterURL,
                             resumeAt: CloudStore.shared.progress[d.itemID]?.fraction ?? 0)
        p.seriesID = d.seriesID
        p.sourceID = d.sourceID
        // build 60: taal van de titel (automatische ondertitels "wanneer nodig") en hervatten op de seconde (VLC)
        let lang = ContentLanguage.resolve(title: d.title, group: nil, id: d.seriesID ?? d.itemID)
        p.audioLanguage = (lang?.multi ?? false) ? nil : lang?.audioBase
        p.burnedSubtitles = lang?.subtitlesBase
        if p.resumeAt > 0.01, let e = CloudStore.shared.progress[d.itemID], e.position > 0 { p.resumeSeconds = e.position }
        return p
    }

    /// Volgende gedownloade aflevering van dezelfde serie (offline verder kijken).
    func nextEpisode(after item: PlayableItem) -> PlayableItem? {
        guard item.type == .episode, let sid = item.seriesID, let s = item.season, let e = item.episode else { return nil }
        let eps = visibleItems.filter { $0.seriesID == sid && $0.status == .completed && $0.type == .episode }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let n = eps.first(where: { ($0.season ?? 0, $0.episode ?? 0) > (s, e) }) else { return nil }
        return playable(n)
    }

    // MARK: opslag

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var u = base
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
        return base
    }
    private static var indexURL: URL { folder.appendingPathComponent("downloads.json") }
    nonisolated static func resumeDataURL(_ id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        return base.appendingPathComponent(safeName(id) + ".resume")
    }
    nonisolated static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    static func localURL(_ d: DownloadItem) -> URL? {
        guard let f = d.fileName else { return nil }
        if d.isHLS { return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(f) }
        return folder.appendingPathComponent(f)
    }

    private static func loadItems() -> [DownloadItem] {
        guard let d = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return [] }
        return list
    }

    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) > 3 else { return }
        lastSave = Date()
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.indexURL, options: .atomic) }
    }

    func recalcUsage() {
        let list = items
        Task.detached(priority: .utility) {
            var total: Int64 = 0
            let fm = FileManager.default
            for d in list {
                guard let url = await Self.localURL(d) else { continue }
                total += Self.size(of: url, fm)
            }
            await MainActor.run { self.usedBytes = total }
        }
    }

    nonisolated private static func size(of url: URL, _ fm: FileManager) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    /// Vrije ruimte op het toestel
    var freeBytes: Int64 {
        let v = try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func fetchPoster(_ id: String) async {
        guard let d = items.first(where: { $0.id == id }), let url = d.posterURL, !url.isFileURL,
              let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else { return }
        let name = Self.safeName(id) + ".poster"
        try? data.write(to: Self.folder.appendingPathComponent(name))
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].posterFile = name; save(force: true) }
    }

    // MARK: gebeurtenissen van de sessies

    func progress(_ id: String, written: Int64, expected: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].status == .queued { items[i].status = .downloading }
        guard items[i].status == .downloading else { return }
        items[i].bytesWritten = written
        items[i].bytesExpected = max(expected, 0)
        if expected > 0 { items[i].progress = min(1, Double(written) / Double(expected)) }
        save()
        updateActivity()
    }

    func hlsProgress(_ id: String, fraction: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isActive else { return }
        items[i].status = .downloading
        items[i].progress = min(1, max(0, fraction))
        save()
        updateActivity()
    }

    /// Bestand staat al op zijn plek (verplaatst in de delegate), of `fileName` is nil bij een fout.
    func finished(_ id: String, fileName: String?, error: String? = nil) {
        fileTasks[id] = nil
        hlsTasks[id] = nil
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            // intussen verwijderd: bestand opruimen (HLS: pad ten opzichte van de thuismap, build 60)
            if let f = fileName {
                let url = f.hasSuffix(".movpkg") ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(f)
                                                 : Self.folder.appendingPathComponent(f)
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        guard let fileName else { failed(id, error: error ?? L("Download failed."), resumeData: nil); return }
        items[i].fileName = fileName
        items[i].status = .completed
        items[i].progress = 1
        items[i].error = nil
        if items[i].bytesExpected > 0 { items[i].bytesWritten = items[i].bytesExpected }
        save(force: true)
        recalcUsage()
        updateActivity(force: true, finishedTitle: Self.displayTitle(items[i]))
        notifyDone(items[i])
    }

    /// Fout tijdens het downloaden: met resume data automatisch opnieuw proberen (oplopende wachttijd).
    func failed(_ id: String, error: String, resumeData: Data?) {
        fileTasks[id] = nil
        hlsTasks[id] = nil
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status != .paused, items[i].status != .completed else { return }
        if let resumeData { try? resumeData.write(to: Self.resumeDataURL(id)) }
        items[i].retries += 1
        if items[i].retries <= Self.maxRetries {
            items[i].status = .queued
            items[i].error = error
            save(force: true)
            let wait = UInt64(min(pow(2.0, Double(items[i].retries)), 60) * 1_000_000_000)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: wait)
                guard let d = self.items.first(where: { $0.id == id }), d.status == .queued,
                      self.fileTasks[id] == nil, self.hlsTasks[id] == nil else { return }
                self.begin(id)
            }
        } else {
            fail(id, error)
        }
        updateActivity(force: true)
    }

    private func fail(_ id: String, _ error: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = .failed
        items[i].error = error
        save(force: true)
        updateActivity(force: true)
        notifyFailure(Self.displayTitle(items[i]), error)
    }

    func backgroundEventsDone(_ identifier: String) {
        save(force: true)
        backgroundCompletion.removeValue(forKey: identifier)?()
    }

    static func displayTitle(_ d: DownloadItem) -> String {
        d.subtitle.map { d.type == .episode ? "\(d.title) · \($0)" : d.title } ?? d.title
    }

    // MARK: Live Activity en meldingen

    private func updateActivity(force: Bool = false, finishedTitle: String? = nil) {
        guard force || Date().timeIntervalSince(lastActivityUpdate) > 1.5 else { return }
        lastActivityUpdate = Date()
        let active = items.filter { $0.isActive }
        let paused = items.filter { $0.status == .paused }
        let running = active + paused
        let state: DownloadActivityAttributes.ContentState
        if running.isEmpty {
            guard let act = activity else { return }
            activity = nil
            // build 60: alleen "klaar" tonen als er echt iets klaar is; een overgebleven activiteit van een vorige
            // keer (of alles verwijderd) meteen weghalen
            guard let finishedTitle else {
                Task { await act.end(nil, dismissalPolicy: .immediate) }
                return
            }
            let done = DownloadActivityAttributes.ContentState(
                title: finishedTitle, detail: L("Ready to watch offline"),
                progress: 1, remaining: 0, paused: false, finished: true)
            Task { await act.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
            return
        }
        let progress = running.map(\.progress).reduce(0, +) / Double(running.count)
        let current = active.first ?? running[0]
        let written = running.map(\.bytesWritten).reduce(0, +), expected = running.map(\.bytesExpected).reduce(0, +)
        var detail = running.count == 1 ? L("1 download") : L("%d downloads", running.count)
        if expected > 0 {
            detail += " · " + L("%@ of %@", Self.bytes(written), Self.bytes(expected))
        }
        state = DownloadActivityAttributes.ContentState(title: Self.displayTitle(current), detail: detail,
                                                        progress: progress, remaining: running.count,
                                                        paused: active.isEmpty, finished: false)
        if let act = activity {
            Task { await act.update(ActivityContent(state: state, staleDate: nil)) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(heading: L("Downloads")),
                                             content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        }
    }

    private func notifyDone(_ d: DownloadItem) {
        let c = UNMutableNotificationContent()
        c.title = L("Download complete")
        c.body = Self.displayTitle(d)
        c.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-\(d.id)", content: c, trigger: nil))
    }

    private func notifyFailure(_ title: String, _ error: String) {
        let c = UNMutableNotificationContent()
        c.title = L("Download failed")
        c.body = "\(title) · \(error)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-failed-\(UUID().uuidString)", content: c, trigger: nil))
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

/// Delegate van beide achtergrondsessies. Draait buiten de main actor; bestanden worden hier meteen verplaatst
/// (het tijdelijke bestand bestaat alleen tijdens deze aanroep).
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in DownloadManager.shared.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            Task { @MainActor in DownloadManager.shared.finished(id, fileName: nil, error: "HTTP \(http.statusCode) · \(msg)") }
            return
        }
        var ext = (downloadTask.response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        if ext.isEmpty || ext.count > 5 { ext = downloadTask.originalRequest?.url?.pathExtension ?? "" }
        // onbekende extensie (bijv. .php): als .mkv bewaren, dan speelt VLC het (die kijkt naar de inhoud)
        let known = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]
        if !known.contains(ext.lowercased()) { ext = "mkv" }
        let name = DownloadManager.safeName(id) + "." + ext.lowercased()
        let folder = DownloadManager.resumeDataURL(id).deletingLastPathComponent()
        let dest = folder.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            Task { @MainActor in DownloadManager.shared.finished(id, fileName: name) }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.finished(id, fileName: nil, error: msg) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled && ns.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            return   // gepauzeerd of verwijderd
        }
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let msg = error.localizedDescription
        Task { @MainActor in DownloadManager.shared.failed(id, error: msg, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in DownloadManager.shared.backgroundEventsDone(identifier) }
    }

    // MARK: HLS

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        // AVFoundation bepaalt de plek; bewaren als pad ten opzichte van de thuismap
        let home = NSHomeDirectory()
        let rel = location.path.hasPrefix(home) ? String(location.path.dropFirst(home.count + 1)) : location.relativePath
        Task { @MainActor in DownloadManager.shared.finished(id, fileName: rel) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let total = timeRangeExpectedToLoad.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.filter(\.isFinite).reduce(0, +)
        let fraction = loaded / total
        Task { @MainActor in DownloadManager.shared.hlsProgress(id, fraction: fraction) }
    }
}
