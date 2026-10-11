import SwiftUI

#if os(macOS)
import AppKit

/// Bingr voor de Mac: dezelfde code als iPhone/iPad, met deze kleine vertalingen van UIKit naar AppKit.
typealias PlatformView = NSView
typealias UIImage = NSImage
typealias UIColor = NSColor

@MainActor func makeBlackView() -> NSView {
    let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor; return v
}

extension NSImage {
    convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)) }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// Klembord zoals op iOS (`UIPasteboard.general.string = …`).
struct UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        nonmutating set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

// iOS-only modifiers: op de Mac doen ze niets (of iets vergelijkbaars).
enum MacKeyboardType { case `default`, URL, numberPad, emailAddress, asciiCapable }
enum MacAutocapitalization { case never, words, sentences, characters }
enum MacTitleDisplayMode { case inline, large, automatic }

extension View {
    func keyboardType(_ type: MacKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ a: MacAutocapitalization?) -> some View { self }
    func navigationBarTitleDisplayMode(_ m: MacTitleDisplayMode) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    /// Schermvullend op iPhone/Apple TV = een groot venster-blad op de Mac.
    func fullScreenCover<Item: Identifiable, C: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                      @ViewBuilder content: @escaping (Item) -> C) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).macCoverFrame() }
    }
    func fullScreenCover<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                  @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().macCoverFrame() }
    }
    fileprivate func macCoverFrame() -> some View {
        frame(minWidth: 960, idealWidth: 1280, maxWidth: .infinity, minHeight: 620, idealHeight: 800, maxHeight: .infinity)
            .background(Color.black)
    }
}

#else
import UIKit
typealias PlatformView = UIView
@MainActor func makeBlackView() -> UIView { let v = UIView(); v.backgroundColor = .black; return v }
#endif
