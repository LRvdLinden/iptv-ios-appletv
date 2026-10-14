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
        modifier(SupportPageModifier(isPresented: isPresented))
    }
}

private struct SupportPageModifier: ViewModifier {
    @Binding var isPresented: Bool
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(isPresented: $isPresented) {
            SafariView(url: Support.url).ignoresSafeArea()
        }
        #elseif os(tvOS)
        content.sheet(isPresented: $isPresented) { SupportQRView() }
        #else
        content.onChange(of: isPresented) { _, open in
            guard open else { return }
            openURL(Support.url)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 36) {
            Image(systemName: "questionmark.circle").font(.system(size: 64, weight: .medium)).foregroundStyle(Theme.red)
            Text(L("Support")).font(.system(size: 48, weight: .bold))
            Text(L("Scan the QR code with your phone to open the Bingr help center."))
                .font(.system(size: 28)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            if let qr = QRCode.image(Support.url.absoluteString) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 320, height: 320)
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(verbatim: Support.displayURL).font(.system(size: 34, weight: .semibold))
            Button(L("Done")) { dismiss() }
        }
        .padding(60)
    }
}
#endif
