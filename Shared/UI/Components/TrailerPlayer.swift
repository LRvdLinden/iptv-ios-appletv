import SwiftUI
#if os(iOS)
import WebKit
#endif

/// Trailers komen van Trakt (YouTube). iOS speelt ze in-app af; tvOS opent de YouTube-app.
enum Trailer {
    static func appURL(_ id: String) -> URL? { URL(string: "youtube://www.youtube.com/watch?v=\(id)") }
    static func webURL(_ id: String) -> URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }
}

#if os(iOS)
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

struct YouTubeEmbed: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.isScrollEnabled = false
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;background:#000}</style></head>
        <body><iframe width="100%" height="100%" style="position:absolute;inset:0;border:0"
        src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&modestbranding=1"
        allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
