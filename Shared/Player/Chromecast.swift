#if !os(tvOS)
import Foundation
import Network
import SwiftUI
import AVKit

/// Chromecast zonder externe SDK: zoekt apparaten via Bonjour (_googlecast._tcp)
/// en praat het Cast v2-protocol (protobuf over TLS, poort 8009) met de
/// standaard media-ontvanger (app-ID CC1AD845).
@MainActor
final class CastManager: ObservableObject {
    static let shared = CastManager()

    struct Device: Identifiable, Hashable { var id: String; var name: String; var endpoint: NWEndpoint }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var connected: Device?
    @Published private(set) var status: String = ""
    @Published private(set) var isPlaying = false
    /// Melding over ondertitels op de Chromecast (bijv. spoor uit de stream niet beschikbaar) (build 57)
    @Published private(set) var subtitleNote: String?

    private var browser: NWBrowser?
    private var session: CastSession?

    func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Device] = results.compactMap { r in
                var name = "Chromecast"
                if case let .bonjour(txt) = r.metadata, let fn = txt["fn"] { name = fn }
                if case let .service(svcName, _, _, _) = r.endpoint { return Device(id: svcName, name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor in self?.devices = found.sorted { $0.name < $1.name } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopDiscovery() { browser?.cancel(); browser = nil }

    /// `subtitles`: de ondertitel die nu in de speler gekozen is (build 57), met de ingestelde verschuiving.
    func cast(_ item: PlayableItem, url: URL, to device: Device, at seconds: Double,
              subtitles: SubtitleChoice? = nil, delay: Double = 0) {
        session?.close()
        LocalMediaServer.shared.remove(owner: CastSession.serverOwner)
        status = L("Connecting to %@…", device.name)
        subtitleNote = nil
        let s = CastSession(endpoint: device.endpoint)
        s.onStatus = { [weak self] text, playing in
            Task { @MainActor in self?.status = text; self?.isPlaying = playing }
        }
        s.onSubtitleNote = { [weak self] note in
            Task { @MainActor in self?.subtitleNote = note }
        }
        session = s
        connected = device
        let s2 = url.absoluteString.lowercased()
        let contentType = url.pathExtension.lowercased() == "m3u8" || s2.contains(".m3u8") ? "application/x-mpegurl"
            : url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/mp2t"
        s.start(media: url, contentType: contentType, title: item.title, subtitle: item.subtitle ?? "",
                image: item.artwork, live: item.type == .live, startAt: seconds,
                subtitles: Self.spec(subtitles, delay: delay), style: Self.textStyle())
    }

    /// Andere ondertitel gekozen tijdens het casten (of andere verschuiving).
    func updateSubtitle(_ choice: SubtitleChoice?, delay: Double) {
        guard let session else { return }
        subtitleNote = nil
        session.setSubtitles(Self.spec(choice, delay: delay), style: Self.textStyle())
    }

    func togglePause() { session?.togglePause() }
    func disconnect() {
        session?.close(); session = nil; connected = nil; status = ""; isPlaying = false; subtitleNote = nil
        // lokale server alleen tijdens het casten
        LocalMediaServer.shared.remove(owner: CastSession.serverOwner)
    }

    /// Keuze in de speler → wat de Chromecast nodig heeft (bestand als WebVTT, of welk spoor uit de stream).
    private static func spec(_ c: SubtitleChoice?, delay: Double) -> CastSubtitleSpec? {
        guard let c else { return nil }
        let lang = c.language.map(TrackPreferences.baseCode)
        switch c.kind {
        case .file(let f):
            guard let vtt = WebVTT.make(from: f, delay: delay) else { return nil }
            return CastSubtitleSpec(vtt: vtt, key: "\(f.path)|\(delay)", name: c.name, language: lang, embeddedIndex: nil)
        case .embedded(let i):
            return CastSubtitleSpec(vtt: nil, key: "embedded-\(i)", name: c.name, language: lang, embeddedIndex: i)
        }
    }

    /// Goed leesbare ondertitels op de tv: wit met schaduw op een half doorzichtige balk.
    private static func textStyle() -> [String: Any] {
        let scale: Double
        switch SubtitleSize.current { case .small: scale = 0.9; case .medium: scale = 1.1; case .large: scale = 1.3 }
        return ["foregroundColor": "#FFFFFFFF", "backgroundColor": "#00000099", "edgeType": "DROP_SHADOW",
                "edgeColor": "#000000FF", "fontScale": scale, "fontGenericFamily": "SANS_SERIF",
                "fontStyle": "NORMAL", "windowType": "NONE"]
    }
}

/// Ondertitel voor de Chromecast: een WebVTT-bestand (via de lokale server) of een spoor uit de stream.
struct CastSubtitleSpec {
    var vtt: Data?
    /// Zelfde bestand en verschuiving = zelfde sleutel (dan hoeft de media niet opnieuw geladen te worden)
    var key: String
    var name: String
    var language: String?
    var embeddedIndex: Int?
}

/// Eén verbinding met een Cast-apparaat.
final class CastSession {
    static let serverOwner = "cast"
    /// Ons eigen ondertitelspoor (hoog nummer, botst niet met sporen die de ontvanger zelf uit HLS haalt)
    private static let ownTrackID = 1000
    private let conn: NWConnection
    /// Alles van deze sessie op één wachtrij (berichten van de Chromecast én wijzigingen vanuit de app)
    private let queue = DispatchQueue(label: "bingr.cast")
    private let sender = "sender-bingr"
    private var transportID: String?
    private var mediaSessionID: Int?
    private var requestID = 1
    private var buffer = Data()
    private var heartbeat: Timer?
    private var paused = false
    var onStatus: ((String, Bool) -> Void)?
    var onSubtitleNote: ((String?) -> Void)?

    private var pending: (url: URL, type: String, title: String, subtitle: String, image: URL?, live: Bool, start: Double)?

    // ondertitels (build 57)
    private var subs: CastSubtitleSpec?
    private var style: [String: Any] = [:]
    /// Sleutel van het bestand dat in de geladen media als ons spoor zit
    private var loadedKey: String?
    private var fileCounter = 0
    /// Tekstsporen die de ontvanger meldt (ook die uit de HLS-stream zelf); nil = nog niet bekend
    private var remoteTextTracks: [[String: Any]]?
    /// Spoor uit de stream gekozen, wacht op de sporenlijst van de ontvanger
    private var embeddedPending = false
    private var lastTime: Double = 0

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Cast-apparaten gebruiken een eigen (zelf-ondertekend) certificaat
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .main)
        let params = NWParameters(tls: tls)
        if case let .service(name, type, domain, _) = endpoint {
            conn = NWConnection(to: .service(name: name, type: type, domain: domain, interface: nil), using: params)
        } else {
            conn = NWConnection(to: endpoint, using: params)
        }
    }

    func start(media: URL, contentType: String, title: String, subtitle: String, image: URL?, live: Bool, startAt: Double,
               subtitles: CastSubtitleSpec? = nil, style: [String: Any] = [:]) {
        pending = (media, contentType, title, subtitle, image, live, startAt)
        subs = subtitles
        self.style = style
        lastTime = startAt
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.send(ns: "urn:x-cast:com.google.cast.tp.connection", to: "receiver-0", ["type": "CONNECT"])
                self.send(ns: "urn:x-cast:com.google.cast.receiver", to: "receiver-0",
                          ["type": "LAUNCH", "appId": "CC1AD845", "requestId": self.nextID()])
                DispatchQueue.main.async {
                    guard !self.closed else { return }
                    self.heartbeat?.invalidate()
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
                        guard let self, !self.closed else { t.invalidate(); return }
                        self.queue.async { self.send(ns: "urn:x-cast:com.google.cast.tp.heartbeat", to: "receiver-0", ["type": "PING"]) }
                    }
                }
                self.receive()
            case .failed(let e):
                self.onStatus?(L("Chromecast error: %@", e.localizedDescription), false)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func togglePause() {
        queue.async { [self] in
            guard let t = transportID, let m = mediaSessionID else { return }
            paused.toggle()
            send(ns: "urn:x-cast:com.google.cast.media", to: t,
                 ["type": paused ? "PAUSE" : "PLAY", "mediaSessionId": m, "requestId": nextID()])
        }
    }

    /// Andere ondertitel tijdens het casten: aan/uit en sporen uit de stream via EDIT_TRACKS_INFO;
    /// een nieuw bestand (of andere verschuiving) kan alleen met de media opnieuw laden op dezelfde plek.
    func setSubtitles(_ spec: CastSubtitleSpec?, style: [String: Any]) {
        queue.async { [self] in
            subs = spec
            self.style = style
            guard let t = transportID, mediaSessionID != nil else { return }   // nog aan het laden: LOAD neemt het mee
            if let spec, spec.vtt != nil, spec.key != loadedKey {
                load(transport: t, startAt: lastTime)
            } else {
                applyActiveTracks()
            }
        }
    }

    func close() {
        closed = true
        heartbeat?.invalidate(); heartbeat = nil
        LocalMediaServer.shared.remove(owner: Self.serverOwner)
        // build 60: sessiegegevens alleen op de eigen wachtrij lezen (de berichten van de Chromecast komen daar ook binnen)
        queue.async { [self] in
            if let t = transportID {
                send(ns: "urn:x-cast:com.google.cast.receiver", to: "receiver-0", ["type": "STOP", "requestId": nextID(), "sessionId": t])
            }
            conn.cancel()
        }
    }
    /// Gesloten: geen heartbeat meer starten (de verbinding kan nog net "ready" melden)
    private var closed = false

    private func nextID() -> Int { requestID += 1; return requestID }

    // MARK: berichten

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if err == nil && !done { self.receive() }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer[buffer.startIndex]) << 24 | Int(buffer[buffer.startIndex + 1]) << 16
                | Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            guard buffer.count >= 4 + len else { return }
            let msg = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + len))
            if let payload = CastProto.payload(msg),
               let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                handle(json)
            }
        }
    }

    private func handle(_ j: [String: Any]) {
        switch j["type"] as? String {
        case "PING":
            send(ns: "urn:x-cast:com.google.cast.tp.heartbeat", to: "receiver-0", ["type": "PONG"])
        case "RECEIVER_STATUS":
            guard transportID == nil,
                  let apps = (j["status"] as? [String: Any])?["applications"] as? [[String: Any]],
                  let app = apps.first(where: { ($0["appId"] as? String) == "CC1AD845" }),
                  let t = app["transportId"] as? String, let p = pending else { return }
            transportID = t
            send(ns: "urn:x-cast:com.google.cast.tp.connection", to: t, ["type": "CONNECT"])
            load(transport: t, startAt: p.start)
            onStatus?(L("Playing on Chromecast"), true)
        case "MEDIA_STATUS":
            if let s = (j["status"] as? [[String: Any]])?.first {
                mediaSessionID = s["mediaSessionId"] as? Int ?? mediaSessionID
                if let ct = (s["currentTime"] as? NSNumber)?.doubleValue, ct > 0 { lastTime = ct }
                let state = s["playerState"] as? String ?? ""
                onStatus?(state == "PAUSED" ? L("Paused on Chromecast") : L("Playing on Chromecast"), state == "PLAYING" || state == "BUFFERING")
                // sporenlijst van de ontvanger (o.a. ondertitels uit de HLS-stream)
                if let media = s["media"] as? [String: Any] {
                    let tracks = media["tracks"] as? [[String: Any]] ?? []
                    remoteTextTracks = tracks.filter { ($0["type"] as? String) == "TEXT" }
                    // pas beslissen als er sporen zijn of de stream echt speelt (dan is de afspeellijst gelezen)
                    if embeddedPending, !(remoteTextTracks ?? []).isEmpty || state == "PLAYING" { applyActiveTracks() }
                }
            }
        case "LOAD_FAILED", "LOAD_CANCELLED":
            onStatus?(L("This stream can't be played on Chromecast."), false)
        default: break
        }
    }

    // MARK: media laden met ondertitels (build 57)

    /// LOAD-bericht: de stream plus (bij een eigen bestand) een WebVTT-tekstspoor van de lokale server.
    private func load(transport t: String, startAt: Double) {
        guard let p = pending else { return }
        var meta: [String: Any] = ["metadataType": 0, "title": p.title, "subtitle": p.subtitle]
        if let i = p.image { meta["images"] = [["url": i.absoluteString]] }
        var media: [String: Any] = ["contentId": p.url.absoluteString, "contentType": p.type,
                                    "streamType": p.live ? "LIVE" : "BUFFERED", "metadata": meta]
        var msg: [String: Any] = ["type": "LOAD", "requestId": nextID(), "autoplay": true, "currentTime": startAt]
        loadedKey = nil
        remoteTextTracks = nil
        embeddedPending = subs?.embeddedIndex != nil
        if let s = subs, let vtt = s.vtt, let track = publish(vtt, spec: s) {
            media["tracks"] = [track]
            msg["activeTrackIds"] = [Self.ownTrackID]
            loadedKey = s.key
        } else if let s = subs, s.vtt != nil {
            onSubtitleNote?(L("Subtitles can't be sent to the Chromecast (no Wi-Fi connection)."))
        }
        if !style.isEmpty { media["textTrackStyle"] = style }
        msg["media"] = media
        mediaSessionID = nil
        send(ns: "urn:x-cast:com.google.cast.media", to: t, msg)
    }

    /// Zet de WebVTT op de lokale server (adres waarmee de telefoon de Chromecast bereikt) en geeft het tekstspoor.
    private func publish(_ vtt: Data, spec: CastSubtitleSpec) -> [String: Any]? {
        // elke keer een nieuwe naam: de ontvanger onthoudt een eerder opgehaald bestand
        fileCounter += 1
        let name = "cast-\(fileCounter).vtt"
        let server = LocalMediaServer.shared
        server.remove(owner: Self.serverOwner)
        guard let host = LocalMediaServer.address(of: conn.currentPath?.localEndpoint) ?? LocalMediaServer.lanAddress(),
              server.publish(vtt, name: name, contentType: "text/vtt; charset=utf-8", owner: Self.serverOwner) != nil,
              let url = server.url(name: name, host: host) else { return nil }
        var track: [String: Any] = ["trackId": Self.ownTrackID, "type": "TEXT", "subtype": "SUBTITLES",
                                    "trackContentId": url.absoluteString, "trackContentType": "text/vtt",
                                    "name": spec.name]
        if let l = spec.language, !l.isEmpty { track["language"] = l }
        return track
    }

    /// Welk tekstspoor aan staat (EDIT_TRACKS_INFO): ons bestand, een spoor uit de stream, of geen.
    private func applyActiveTracks() {
        guard let t = transportID, let m = mediaSessionID else { return }
        var ids: [Int] = []
        if let s = subs {
            if s.vtt != nil, loadedKey == s.key {
                ids = [Self.ownTrackID]
            } else if let index = s.embeddedIndex {
                guard let tracks = remoteTextTracks else { embeddedPending = true; return }   // nog niet bekend
                embeddedPending = false
                if let id = matchEmbedded(s, index: index, in: tracks) {
                    ids = [id]
                } else {
                    onSubtitleNote?(L("Subtitles from this stream can't be shown on the Chromecast."))
                }
            }
        }
        var msg: [String: Any] = ["type": "EDIT_TRACKS_INFO", "requestId": nextID(), "mediaSessionId": m, "activeTrackIds": ids]
        if !style.isEmpty { msg["textTrackStyle"] = style }
        send(ns: "urn:x-cast:com.google.cast.media", to: t, msg)
    }

    /// Spoor uit de stream terugvinden in de sporen van de ontvanger: op taal, dan op naam, dan op volgorde.
    private func matchEmbedded(_ s: CastSubtitleSpec, index: Int, in tracks: [[String: Any]]) -> Int? {
        let own = tracks.filter { ($0["trackId"] as? Int) != Self.ownTrackID }
        guard !own.isEmpty else { return nil }
        func id(_ t: [String: Any]) -> Int? { (t["trackId"] as? NSNumber)?.intValue }
        if let lang = s.language, !lang.isEmpty {
            let hits = own.filter { t in
                TrackPreferences.matches(MediaTrack(id: "", name: t["name"] as? String ?? "", lang: t["language"] as? String), code: lang)
            }
            if hits.count == 1 { return id(hits[0]) }
            if let n = hits.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(s.name) == .orderedSame }) { return id(n) }
            if let first = hits.first { return id(first) }
        }
        if let n = own.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(s.name) == .orderedSame }) { return id(n) }
        return index < own.count ? id(own[index]) : nil
    }

    private func send(ns: String, to dest: String, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        let msg = CastProto.message(source: sender, destination: dest, namespace: ns, payload: s)
        var framed = Data()
        let n = UInt32(msg.count).bigEndian
        withUnsafeBytes(of: n) { framed.append(contentsOf: $0) }
        framed.append(msg)
        conn.send(content: framed, completion: .contentProcessed { _ in })
    }
}

/// Minimale protobuf-codering van het CastMessage-bericht.
enum CastProto {
    private static func varint(_ v: Int) -> Data {
        var v = UInt64(v), d = Data()
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0
        return d
    }
    private static func string(_ field: Int, _ s: String) -> Data {
        let b = Data(s.utf8)
        return Data([UInt8(field << 3 | 2)]) + varint(b.count) + b
    }

    static func message(source: String, destination: String, namespace: String, payload: String) -> Data {
        var d = Data([0x08, 0x00])                 // protocol_version = CASTV2_1_0
        d += string(2, source)
        d += string(3, destination)
        d += string(4, namespace)
        d += Data([0x28, 0x00])                    // payload_type = STRING
        d += string(6, payload)
        return d
    }

    /// Haalt payload_utf8 (veld 6) uit een binnenkomend bericht.
    static func payload(_ d: Data) -> String? {
        let b = [UInt8](d)
        var i = 0
        func readVarint() -> Int? {
            var result = 0, shift = 0
            while i < b.count {
                let x = b[i]; i += 1
                result |= Int(x & 0x7F) << shift
                if x & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 0: _ = readVarint()
            case 2:
                guard let len = readVarint(), i + len <= b.count else { return nil }
                if field == 6 { return String(decoding: b[i..<(i + len)], as: UTF8.self) }
                i += len
            default: return nil
            }
        }
        return nil
    }
}

/// Lijst met Chromecasts in het netwerk.
struct CastPicker: View {
    let item: PlayableItem
    let url: URL
    let position: Double
    /// Gekozen ondertitel in de speler (build 57)
    var subtitles: SubtitleChoice? = nil
    var subtitleDelay: Double = 0
    var onCast: () -> Void
    @StateObject private var cast = CastManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cast.devices.isEmpty {
                    HStack { ProgressView(); Text(L("Searching for Chromecasts…")).foregroundStyle(Theme.secondary) }
                }
                ForEach(cast.devices) { d in
                    Button {
                        cast.cast(item, url: url, to: d, at: position, subtitles: subtitles, delay: subtitleDelay)
                        onCast(); dismiss()
                    } label: { Label(d.name, systemImage: "tv.and.mediabox") }
                }
                if cast.connected != nil {
                    Button(L("Stop casting"), role: .destructive) { cast.disconnect(); dismiss() }
                }
            }
            .navigationTitle("Chromecast")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Close")) { dismiss() } } }
        }
        .onAppear { cast.startDiscovery() }
    }
}

/// AirPlay-knop.
#if os(macOS)
struct AirPlayButton: NSViewRepresentable {
    var onWillPresent: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(onWillPresent) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.delegate = context.coordinator
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { f() }
    }
}
#else
struct AirPlayButton: UIViewRepresentable {
    var onWillPresent: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(onWillPresent) }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)
        v.prioritizesVideoDevices = true
        v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { f() }
    }
}
#endif
#endif
