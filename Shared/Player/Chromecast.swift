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

    func cast(_ item: PlayableItem, url: URL, to device: Device, at seconds: Double) {
        session?.close()
        status = L("Connecting to %@…", device.name)
        let s = CastSession(endpoint: device.endpoint)
        s.onStatus = { [weak self] text, playing in
            Task { @MainActor in self?.status = text; self?.isPlaying = playing }
        }
        session = s
        connected = device
        let contentType = url.pathExtension.lowercased() == "m3u8" ? "application/x-mpegurl"
            : url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/mp2t"
        s.start(media: url, contentType: contentType, title: item.title, subtitle: item.subtitle ?? "",
                image: item.artwork, live: item.type == .live, startAt: seconds)
    }

    func togglePause() { session?.togglePause() }
    func disconnect() { session?.close(); session = nil; connected = nil; status = ""; isPlaying = false }
}

/// Eén verbinding met een Cast-apparaat.
final class CastSession {
    private let conn: NWConnection
    private let sender = "sender-bingr"
    private var transportID: String?
    private var mediaSessionID: Int?
    private var requestID = 1
    private var buffer = Data()
    private var heartbeat: Timer?
    private var paused = false
    var onStatus: ((String, Bool) -> Void)?

    private var pending: (url: URL, type: String, title: String, subtitle: String, image: URL?, live: Bool, start: Double)?

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

    func start(media: URL, contentType: String, title: String, subtitle: String, image: URL?, live: Bool, startAt: Double) {
        pending = (media, contentType, title, subtitle, image, live, startAt)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.send(ns: "urn:x-cast:com.google.cast.tp.connection", to: "receiver-0", ["type": "CONNECT"])
                self.send(ns: "urn:x-cast:com.google.cast.receiver", to: "receiver-0",
                          ["type": "LAUNCH", "appId": "CC1AD845", "requestId": self.nextID()])
                DispatchQueue.main.async {
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        self?.send(ns: "urn:x-cast:com.google.cast.tp.heartbeat", to: "receiver-0", ["type": "PING"])
                    }
                }
                self.receive()
            case .failed(let e):
                self.onStatus?(L("Chromecast error: %@", e.localizedDescription), false)
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func togglePause() {
        guard let t = transportID, let m = mediaSessionID else { return }
        paused.toggle()
        send(ns: "urn:x-cast:com.google.cast.media", to: t,
             ["type": paused ? "PAUSE" : "PLAY", "mediaSessionId": m, "requestId": nextID()])
    }

    func close() {
        heartbeat?.invalidate()
        if let t = transportID {
            send(ns: "urn:x-cast:com.google.cast.receiver", to: "receiver-0", ["type": "STOP", "requestId": nextID(), "sessionId": t])
        }
        conn.cancel()
    }

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
            var meta: [String: Any] = ["metadataType": 0, "title": p.title, "subtitle": p.subtitle]
            if let i = p.image { meta["images"] = [["url": i.absoluteString]] }
            send(ns: "urn:x-cast:com.google.cast.media", to: t, [
                "type": "LOAD", "requestId": nextID(), "autoplay": true, "currentTime": p.start,
                "media": ["contentId": p.url.absoluteString, "contentType": p.type,
                          "streamType": p.live ? "LIVE" : "BUFFERED", "metadata": meta]
            ])
            onStatus?(L("Playing on Chromecast"), true)
        case "MEDIA_STATUS":
            if let s = (j["status"] as? [[String: Any]])?.first {
                mediaSessionID = s["mediaSessionId"] as? Int ?? mediaSessionID
                let state = s["playerState"] as? String ?? ""
                onStatus?(state == "PAUSED" ? L("Paused on Chromecast") : L("Playing on Chromecast"), state == "PLAYING" || state == "BUFFERING")
            }
        case "LOAD_FAILED", "LOAD_CANCELLED":
            onStatus?(L("This stream can't be played on Chromecast."), false)
        default: break
        }
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
                        cast.cast(item, url: url, to: d, at: position)
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
