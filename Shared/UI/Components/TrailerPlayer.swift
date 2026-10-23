import SwiftUI
#if !os(tvOS)
import WebKit
#endif

/// Trailers komen van Trakt (YouTube). iOS speelt ze in-app af; tvOS opent de YouTube-app.
enum Trailer {
    static func appURL(_ id: String) -> URL? { safeID(id).flatMap { URL(string: "youtube://www.youtube.com/watch?v=\($0)") } }
    static func webURL(_ id: String) -> URL? { safeID(id).flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") } }

    /// build 141: alleen een echte YouTube-id (11 tekens A-Z, a-z, 0-9, - en _). De id komt o.a. van de IPTV-server
    /// (`youtube_trailer`) en gaat in HTML; alles anders wordt geweigerd. Een volledige YouTube-link mag ook.
    static func safeID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if isValidID(raw) { return raw }
        // volledige link: youtube.com/watch?v=<id>, youtube.com/embed/<id> of youtu.be/<id>
        guard raw.contains("/"), let c = URLComponents(string: raw) else { return nil }
        if let v = c.queryItems?.first(where: { $0.name == "v" })?.value, isValidID(v) { return v }
        if let last = c.path.split(separator: "/").last.map(String.init), isValidID(last),
           let host = c.host?.lowercased(), host.contains("youtu") { return last }
        return nil
    }

    static func isValidID(_ s: String) -> Bool {
        s.utf8.count == 11 && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    /// build 141: HTML-escapen (extra laag naast `safeID`).
    static func htmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// build 141: HTML van het trailer-blad; nil bij een ongeldige id.
    static func embedHTML(_ id: String, playsInline: Bool) -> String? {
        guard let safe = safeID(id) else { return nil }
        let e = htmlEscaped(safe)
        let viewport = playsInline ? "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" : ""
        return """
        <html><head>\(viewport)<style>body{margin:0;background:#000}</style></head>
        <body><iframe width="100%" height="100%" style="position:absolute;inset:0;border:0"
        src="https://www.youtube-nocookie.com/embed/\(e)?autoplay=1\(playsInline ? "&amp;playsinline=1" : "")&amp;rel=0&amp;modestbranding=1"
        allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
    }

    /// Build 82: trailer automatisch (zonder geluid) in de kop van de detailpagina. Standaard aan.
    /// Apple TV heeft geen WebKit en geen eigen YouTube-stream, daar blijft de kopafbeelding staan.
    /// build 97: gelezen via `@AppStorage(Trailer.autoplayKey)` (de ongebruikte `autoplayEnabled` is weg)
    static let autoplayKey = "ui.autoplayTrailers"
}

#if !os(tvOS)
struct TrailerSheet: View {
    let youtubeID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title).font(.headline).padding(.top, 50)
                YouTubeEmbed(id: youtubeID).aspectRatio(16 / 9, contentMode: .fit)
                Spacer()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).symbolRenderingMode(.hierarchical)
            }.padding()
        }
    }
}

// MARK: - Trailer in de kop (build 82)

/// Stand van de trailer in de kop van de detailpagina. De webweergave bestaat alleen zolang `videoID` gezet is;
/// stoppen haalt hem weg (geen geluid of data meer), opnieuw afspelen maakt een nieuwe.
@MainActor
final class HeroTrailerModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, playing, finished }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var videoID: String?
    @Published private(set) var muted = true
    /// Nieuwe waarde = nieuwe webweergave (opnieuw afspelen)
    @Published private(set) var token = UUID()
    /// Laatst gestarte trailer, voor "Opnieuw afspelen"
    private(set) var lastID: String?
    weak var webView: WKWebView?
    private var timeout: Task<Void, Never>?

    var isVisible: Bool { phase == .playing }

    func start(_ id: String) {
        guard let id = Trailer.safeID(id) else { return }   // build 141
        lastID = id
        muted = true
        videoID = id
        token = UUID()
        phase = .loading
        // speelt hij na 10 s nog niet (geblokkeerd, geen internet): stil terug naar de afbeelding
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .loading else { return }
            self.stop()
        }
    }

    func replay() { if let lastID { start(lastID) } }

    /// Stoppen (afspelen, aflevering, ander scherm, achtergrond). Daarna kan "Opnieuw afspelen".
    func stop() {
        timeout?.cancel()
        guard videoID != nil else { return }
        webView?.evaluateJavaScript("try{player&&player.stopVideo()}catch(e){}", completionHandler: nil)
        videoID = nil
        webView = nil
        phase = lastID == nil ? .idle : .finished
    }

    func toggleMute() {
        muted.toggle()
        webView?.evaluateJavaScript("setMuted(\(muted))", completionHandler: nil)
    }

    fileprivate func event(_ name: String) {
        switch name {
        case "playing": if videoID != nil { timeout?.cancel(); phase = .playing }
        case "ended", "error": stop()
        default: break
        }
    }

    /// Pagina met de YouTube IFrame-API: zonder knoppen, titel of eindscherm, beeldvullend (16:9 bijgesneden)
    /// en iets ingezoomd zodat randen met YouTube-logo of titel buiten beeld vallen. Seintjes naar de app:
    /// `playing`, `ended` (1 s voor het einde, vóór het eindscherm) en `error`.
    static func html(_ id: String) -> String {
        // build 141: zelfde strikte controle als het trailer-blad (Trailer.safeID)
        let safe = Trailer.safeID(id) ?? ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;height:100%;overflow:hidden;background:#000}
        #w{position:absolute;top:50%;left:50%;width:max(100vw,177.78vh);height:max(100vh,56.25vw);
        transform:translate(-50%,-50%) scale(1.15);pointer-events:none}#p{width:100%;height:100%;border:0}</style>
        </head><body><div id="w"><div id="p"></div></div>
        <script>
        var player=null,timer=null;
        function post(m){try{window.webkit.messageHandlers.bingr.postMessage(m)}catch(e){}}
        function setMuted(m){if(!player)return;try{if(m){player.mute()}else{player.unMute();player.setVolume(100)}}catch(e){}}
        function watch(){clearInterval(timer);timer=setInterval(function(){try{var d=player.getDuration(),c=player.getCurrentTime();
        if(d>0&&d-c<1.2){clearInterval(timer);player.pauseVideo();post('ended')}}catch(e){}},400)}
        function onYouTubeIframeAPIReady(){player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',videoId:'\(safe)',
        playerVars:{autoplay:1,mute:1,playsinline:1,controls:0,disablekb:1,fs:0,rel:0,modestbranding:1,iv_load_policy:3,
        cc_load_policy:0,showinfo:0,enablejsapi:1,origin:'https://www.youtube-nocookie.com'},
        events:{onReady:function(e){e.target.mute();e.target.playVideo()},
        onStateChange:function(e){if(e.data===1){post('playing');watch()}else if(e.data===0){post('ended')}},
        onError:function(){post('error')}}})}
        </script><script src="https://www.youtube.com/iframe_api" onerror="post('error')"></script>
        </body></html>
        """
    }
}

/// Doorgeefluik voor seintjes uit de pagina (zwak, anders houdt WebKit het model vast).
@MainActor
private final class TrailerMessageProxy: NSObject, WKScriptMessageHandler {
    weak var model: HeroTrailerModel?
    init(_ model: HeroTrailerModel) { self.model = model }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let name = message.body as? String else { return }
        model?.event(name)
    }
}

@MainActor private func makeHeroWebView(_ model: HeroTrailerModel, id: String) -> WKWebView {
    let c = WKWebViewConfiguration()
    #if os(iOS)
    c.allowsInlineMediaPlayback = true
    c.allowsPictureInPictureMediaPlayback = false
    #endif
    c.mediaTypesRequiringUserActionForPlayback = []
    c.userContentController.add(TrailerMessageProxy(model), name: "bingr")
    #if os(macOS)
    let w: WKWebView = PassThroughWebView(frame: .zero, configuration: c)
    #else
    let w = WKWebView(frame: .zero, configuration: c)
    #endif
    #if os(iOS)
    w.isOpaque = false
    w.backgroundColor = .black
    w.scrollView.isScrollEnabled = false
    w.isUserInteractionEnabled = false
    #else
    w.setValue(false, forKey: "drawsBackground")
    #endif
    model.webView = w
    w.loadHTMLString(HeroTrailerModel.html(id), baseURL: URL(string: "https://www.youtube-nocookie.com"))
    return w
}

@MainActor private func tearDown(_ w: WKWebView) {
    w.configuration.userContentController.removeScriptMessageHandler(forName: "bingr")
    w.stopLoading()
    w.loadHTMLString("", baseURL: nil)
}

#if os(macOS)
/// Geen klikken of scrollen opvangen: die horen bij de pagina en de knoppen.
private final class PassThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Trailer in de kop; vangt geen klikken (die gaan naar de knoppen erboven).
struct HeroTrailerView: NSViewRepresentable {
    let id: String
    let model: HeroTrailerModel
    func makeNSView(context: Context) -> WKWebView { makeHeroWebView(model, id: id) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) { tearDown(nsView) }
}
#else
struct HeroTrailerView: UIViewRepresentable {
    let id: String
    let model: HeroTrailerModel
    func makeUIView(context: Context) -> WKWebView { makeHeroWebView(model, id: id) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { tearDown(uiView) }
}
#endif

#if os(macOS)
struct YouTubeEmbed: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = context.coordinator
        if let html = Trailer.embedHTML(id, playsInline: false) {
            w.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        }
        return w
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> YouTubeNavigationGuard { YouTubeNavigationGuard() }
}
#else
struct YouTubeEmbed: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.isScrollEnabled = false
        w.navigationDelegate = context.coordinator
        if let html = Trailer.embedHTML(id, playsInline: true) {
            w.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> YouTubeNavigationGuard { YouTubeNavigationGuard() }
}
#endif

/// build 141: het trailer-blad blijft op YouTube: de hoofdpagina navigeert nergens anders heen.
@MainActor
final class YouTubeNavigationGuard: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame ?? true else { decisionHandler(.allow); return }
        let url = action.request.url
        if url?.scheme == "about" { decisionHandler(.allow); return }
        let host = url?.host?.lowercased() ?? ""
        let ok = url?.scheme == "https" && ["youtube-nocookie.com", "youtube.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        // loadHTMLString met baseURL youtube-nocookie.com komt hier als die URL binnen
        decisionHandler(ok ? .allow : .cancel)
    }
}
#endif
