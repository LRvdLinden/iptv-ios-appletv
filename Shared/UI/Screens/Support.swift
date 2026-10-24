import SwiftUI
#if os(iOS)
import SafariServices
#endif

/// Support (build 75): de helpcentrum-site support.bingr.online, vanuit Mijn Bingr en het profielmenu.
/// iPhone/iPad: in de app (Safari-weergave); Mac: in de browser; Apple TV kan geen webpagina's openen,
/// daar een QR-code om de pagina op je telefoon te openen.
enum Support {
    static let url = URL(string: "https://support.bingr.online")!
    static var displayURL: String { url.absoluteString.replacingOccurrences(of: "https://", with: "") }
}

extension View {
    /// Toont support.bingr.online zodra `isPresented` waar wordt (zie `Support`).
    func supportPage(isPresented: Binding<Bool>) -> some View {
        modifier(SupportPageModifier(isPresented: isPresented, url: Support.url, title: L("Support")))
    }

    /// Build 146: een webpagina van Bingr (privacy, voorwaarden): iPhone/iPad in de app, Mac in de browser, Apple TV
    /// als QR-code.
    func webPage(isPresented: Binding<Bool>, url: URL, title: String) -> some View {
        modifier(SupportPageModifier(isPresented: isPresented, url: url, title: title))
    }
}

/// Build 146: regel die een webpagina opent (zie `webPage`).
struct WebLinkRow: View {
    let title: String
    let icon: String
    let url: URL
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack {
                Label { Text(title).foregroundStyle(Color.primary) } icon: { Image(systemName: icon) }
                Spacer(minLength: 8)
                #if !os(tvOS)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                #endif
            }
            .contentShape(Rectangle())
        }
        .webPage(isPresented: $open, url: url, title: title)
    }
}

private struct SupportPageModifier: ViewModifier {
    @Binding var isPresented: Bool
    let url: URL
    let title: String
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(isPresented: $isPresented) {
            SafariView(url: url).ignoresSafeArea()
        }
        #elseif os(tvOS)
        content.sheet(isPresented: $isPresented) { SupportQRView(url: url, title: title) }
        #else
        content.onChange(of: isPresented) { _, open in
            guard open else { return }
            openURL(url)
            isPresented = false
        }
        #endif
    }
}

#if os(iOS)
/// Webpagina in de app (SFSafariViewController), met de accentkleur van Bingr.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.red)
        vc.dismissButtonStyle = .close
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#endif

#if os(tvOS)
/// Apple TV: QR-code naar support.bingr.online en het adres als tekst.
struct SupportQRView: View {
    var url: URL = Support.url
    var title: String = L("Support")
    @Environment(\.dismiss) private var dismiss

    private var isSupport: Bool { url == Support.url }

    var body: some View {
        VStack(spacing: 36) {
            Image(systemName: isSupport ? "questionmark.circle" : "doc.text").font(.system(size: 64, weight: .medium)).foregroundStyle(Theme.red)
            Text(title).font(.system(size: 48, weight: .bold))
            Text(isSupport ? L("Scan the QR code with your phone to open the Bingr help center.") : L("Scan the QR code with your phone to open this page."))
                .font(.system(size: 28)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            if let qr = QRCode.image(url.absoluteString) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 320, height: 320)
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(verbatim: url.absoluteString.replacingOccurrences(of: "https://", with: "")).font(.system(size: 34, weight: .semibold))
            Button(L("Done")) { dismiss() }
        }
        .padding(60)
    }
}
#endif
