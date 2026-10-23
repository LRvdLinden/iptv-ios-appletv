#if !os(tvOS)
import Foundation
import Network

/// Klein HTTP-servertje op het toestel (build 57) voor ondertitels naar Chromecast en AirPlay.
///
/// Een Chromecast of Apple TV kan geen bestanden van de telefoon lezen; ze halen ondertitels (WebVTT) en een
/// eigen HLS-afspeellijst via http op bij het IP-adres van de telefoon in het wifi-netwerk. De server draait
/// alleen zolang er iets gedeeld wordt (tijdens het casten of AirPlay met eigen ondertitels) en geeft alleen
/// bestanden onder een willekeurig token in het pad (`/<token>/<naam>`); al het andere is 404.
final class LocalMediaServer: @unchecked Sendable {
    static let shared = LocalMediaServer()

    private struct File { var data: Data; var type: String; var owner: String }

    private let queue = DispatchQueue(label: "bingr.localmedia")
    private let lock = NSLock()
    private var listener: NWListener?
    private var files: [String: File] = [:]
    private var portValue: UInt16 = 0
    /// Willekeurig token in elk pad; nieuw bij elke start van de server
    private var token = ""

    private init() {}

    /// Build 141: op de Mac geen inkomende verbindingen (sandbox zonder `com.apple.security.network.server`, eis van
    /// Apple). Casten en AirPlay werken daar gewoon, alleen eigen ondertitels (OpenSubtitles/bestand) niet; ondertitels
    /// uit de stream wel. De app biedt het daar dan ook niet aan (zie `CastManager`, `AirPlaySubtitles`).
    static var isAvailable: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    /// Bestand delen (vervangt een bestaand bestand met dezelfde naam). Geeft het pad (`/<token>/<naam>`)
    /// terug, of nil als de server niet kan starten.
    @discardableResult
    func publish(_ data: Data, name: String, contentType: String, owner: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard startLocked() else { return nil }
        files[name] = File(data: data, type: contentType, owner: owner)
        return "/\(token)/\(name)"
    }

    /// Alles van deze eigenaar weghalen; niets meer gedeeld → server stoppen.
    func remove(owner: String) {
        lock.lock(); defer { lock.unlock() }
        files = files.filter { $0.value.owner != owner }
        if files.isEmpty { stopLocked() }
    }

    /// Volledige URL voor een gedeeld bestand op dit adres (IP van het toestel in het netwerk van de ontvanger).
    func url(name: String, host: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard listener != nil, portValue > 0, files[name] != nil else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(portValue)/\(token)/\(name)")
    }

    // MARK: server

    private func startLocked() -> Bool {
        if listener != nil { return true }
        guard Self.isAvailable else { return false }
        // vaste (willekeurige) poort, zodat de URL meteen bekend is; bezet → een andere proberen
        for _ in 0..<5 {
            let p = UInt16.random(in: 49_200...64_000)
            guard let port = NWEndpoint.Port(rawValue: p) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: port) else { continue }
            token = Self.randomToken()
            portValue = p
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                if case .failed = st, let self, let l {
                    // bijv. poort toch bezet: opnieuw met een andere poort zodra er weer iets gedeeld wordt
                    self.lock.lock()
                    if self.listener === l { self.listener = nil; self.portValue = 0 }
                    self.lock.unlock()
                    l.cancel()
                }
            }
            l.start(queue: queue)
            listener = l
            return true
        }
        return false
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        portValue = 0
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receiveRequest(c, buffer: Data())
    }

    private func receiveRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if err != nil || done || buf.count > 64_000 {
                c.cancel()
            } else {
                self.receiveRequest(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let first = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : ""
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        // CORS: de standaard media-ontvanger van Chromecast haalt ondertitels op vanuit een webpagina
        var headers = [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Cache-Control: no-cache",
            "Connection: close"
        ]
        var status = "404 Not Found"
        var body = Data()
        if method == "OPTIONS" {
            status = "204 No Content"
        } else if method == "GET" || method == "HEAD" {
            lock.lock()
            let comps = path.split(separator: "/").map(String.init)
            let file = comps.count == 2 && comps[0] == token ? files[comps[1]] : nil
            lock.unlock()
            if let file {
                status = "200 OK"
                headers.append("Content-Type: \(file.type)")
                body = file.data
            }
        } else {
            status = "405 Method Not Allowed"
        }
        headers.append("Content-Length: \(body.count)")
        var out = Data("HTTP/1.1 \(status)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
        if method != "HEAD" { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: IP-adres

    /// IPv4-adres van het toestel in het lokale netwerk (wifi, op de Mac ook ethernet).
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var found: [(name: String, ip: String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // wifi/ethernet, geen mobiel netwerk of VPN
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }        // link-local: niet bereikbaar voor een ontvanger
            found.append((name, ip))
        }
        return (found.first { $0.name == "en0" } ?? found.first)?.ip
    }

    /// Bruikbaar adres uit een verbinding (het lokale adres waarmee de telefoon de Chromecast bereikt).
    static func address(of endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a):
            let s = "\(a)"
            return s.split(separator: "%").first.map(String.init)
        default:
            return nil
        }
    }
}

// MARK: - Ondertitels als WebVTT

enum WebVTT {
    /// Ondertitels (SRT of VTT) → WebVTT, met de ingestelde verschuiving (+ = later tonen).
    static func make(from file: URL, delay: Double = 0) -> Data? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        let cues = SRT.parse(d)
        guard !cues.isEmpty else { return nil }
        return make(cues, delay: delay)
    }

    static func make(_ cues: [SubtitleCue], delay: Double = 0) -> Data {
        var out = "WEBVTT\n\n"
        for c in cues {
            let s = c.start + delay, e = c.end + delay
            guard e > 0 else { continue }
            // "-->" mag niet in de tekst staan; lege regels zouden de cue afbreken
            let text = c.text.replacingOccurrences(of: "-->", with: "→")
                .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            out += "\(stamp(max(0, s))) --> \(stamp(max(0.001, e)))\n\(text)\n\n"
        }
        return Data(out.utf8)
    }

    /// Laatste eindtijd (voor de lengte van een HLS-ondertitelafspeellijst).
    static func lastEnd(of file: URL) -> Double {
        guard let d = try? Data(contentsOf: file) else { return 0 }
        return SRT.parse(d).map(\.end).max() ?? 0
    }

    private static func stamp(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
#endif

#if !os(tvOS)
// MARK: - AirPlay: eigen ondertitels als HLS-ondertitelspoor

/// Ondertitels van OpenSubtitles tekent de app zelf over het beeld; die gaan niet mee via AirPlay. Daarom
/// speelt de Apple-speler tijdens AirPlay een eigen HLS-hoofdafspeellijst af (op de lokale server) die de
/// originele stream gebruikt en er een WebVTT-ondertitelspoor bij zet. De Apple TV haalt de video gewoon
/// rechtstreeks bij de bron; alleen de afspeellijst en de ondertitels komen van de telefoon.
/// Lukt alleen bij HLS (.m3u8); bij MP4/TS/MKV geeft `wrap` nil.
enum AirPlaySubtitles {
    /// Naam van het spoor in de afspeellijst (zo vindt de speler het terug)
    static let trackName = "OpenSubtitles"
    static let owner = "airplay"

    static func isHLS(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Lokale URL van de hoofdafspeellijst, of nil als het niet kan (geen HLS, geen netwerk, geen ondertitels).
    static func wrap(source: URL, subtitle file: URL, language: String?, duration: Double, delay: Double) async -> URL? {
        guard LocalMediaServer.isAvailable, ["http", "https"].contains(source.scheme?.lowercased() ?? ""), isHLS(source),
              let vtt = WebVTT.make(from: file, delay: delay),
              let host = LocalMediaServer.lanAddress() else { return nil }
        var req = URLRequest(url: source, timeoutInterval: 10)
        req.setValue(Secrets.userAgent, forHTTPHeaderField: "User-Agent")
        guard let fetched = try? await URLSession.shared.data(for: req) else { return nil }
        let (data, resp) = fetched
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") || text.hasPrefix("\u{FEFF}#EXTM3U")
        else { return nil }
        let base = resp.url ?? source

        let length = max(duration, WebVTT.lastEnd(of: file) + max(0, delay)) + 5
        let secs = Int(length.rounded(.up))
        let subsList = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(secs)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(secs).000,
        subs.vtt
        #EXT-X-ENDLIST

        """
        let master = makeMaster(text, base: base, language: language)
        let server = LocalMediaServer.shared
        server.remove(owner: owner)
        guard server.publish(vtt, name: "subs.vtt", contentType: "text/vtt; charset=utf-8", owner: owner) != nil,
              server.publish(Data(subsList.utf8), name: "subs.m3u8", contentType: "application/vnd.apple.mpegurl", owner: owner) != nil,
              server.publish(Data(master.utf8), name: "master.m3u8", contentType: "application/vnd.apple.mpegurl", owner: owner) != nil
        else { return nil }
        return server.url(name: "master.m3u8", host: host)
    }

    static func stop() { LocalMediaServer.shared.remove(owner: owner) }

    /// Originele afspeellijst → hoofdafspeellijst met ons ondertitelspoor (alle adressen absoluut gemaakt).
    static func makeMaster(_ text: String, base: URL, language: String?) -> String {
        let lang = (language?.isEmpty == false ? language! : "und").replacingOccurrences(of: "\"", with: "")
        func media(_ group: String) -> String {
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(group)\",NAME=\"\(trackName)\",LANGUAGE=\"\(lang)\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subs.m3u8\""
        }
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // alleen een media-afspeellijst (segmenten): één variant eromheen
        guard lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else {
            return "#EXTM3U\n#EXT-X-VERSION:3\n\(media("bingr"))\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,SUBTITLES=\"bingr\"\n\(base.absoluteString)\n"
        }

        let groupRegex = try? NSRegularExpression(pattern: #"SUBTITLES="([^"]+)""#)
        let uriRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var groups: [String] = []
        var out: [String] = []
        for line in lines {
            if line.hasPrefix("#EXTM3U") { continue }
            if !line.hasPrefix("#") {
                out.append(URL(string: line, relativeTo: base)?.absoluteString ?? line)
                continue
            }
            var l = line
            // URI="…" in tags (audio, ondertitels, I-frames, sleutels) absoluut maken
            if let r = uriRegex, let m = r.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
               let rr = Range(m.range(at: 1), in: l) {
                let abs = URL(string: String(l[rr]), relativeTo: base)?.absoluteString ?? String(l[rr])
                l.replaceSubrange(rr, with: abs)
            }
            // één standaardspoor per groep: dat wordt het onze
            if l.hasPrefix("#EXT-X-MEDIA:"), l.contains("TYPE=SUBTITLES") {
                l = l.replacingOccurrences(of: "DEFAULT=YES", with: "DEFAULT=NO")
            }
            if l.hasPrefix("#EXT-X-STREAM-INF") {
                if let r = groupRegex, let m = r.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                   let rr = Range(m.range(at: 1), in: l) {
                    let g = String(l[rr])
                    if !groups.contains(g) { groups.append(g) }
                } else {
                    l += ",SUBTITLES=\"bingr\""
                    if !groups.contains("bingr") { groups.append("bingr") }
                }
            }
            out.append(l)
        }
        // eigen spoor in elke ondertitelgroep die de varianten gebruiken
        return (["#EXTM3U"] + groups.map(media) + out).joined(separator: "\n") + "\n"
    }
}
#endif
