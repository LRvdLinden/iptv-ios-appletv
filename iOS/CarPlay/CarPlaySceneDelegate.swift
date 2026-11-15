import CarPlay
import UIKit

/// Build 171: radio in CarPlay (audio-app). Een lijst met zenders (favorieten bovenaan) en Now Playing.
///
/// Werkt pas als de entitlement `com.apple.developer.carplay-audio` er is (Léon vraagt die bij Apple aan) en de
/// CarPlay-scene in Info.plist staat; zie docs/CARPLAY.md. Tot die tijd wordt deze klasse nooit gebruikt, maar hij
/// compileert gewoon mee.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        MainActor.assumeIsolated {
            interfaceController.setRootTemplate(self.stationsTemplate(), animated: false, completion: nil)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    @MainActor
    private func stationsTemplate() -> CPListTemplate {
        let radio = RadioPlayer.shared
        let list = radio.stations()
        let items: [CPListItem] = list.prefix(CPListTemplate.maximumItemCount).map { c in
            let item = CPListItem(text: CategoryName.channel(c.name), detailText: nil)
            if let logo = c.logo, let cg = ImagePipeline.shared.cachedAny(logo) {
                item.setImage(UIImage(cgImage: cg))
            }
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    RadioPlayer.shared.play(c)
                    self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
                completion()
            }
            return item
        }
        let section = CPListSection(items: items)
        let t = CPListTemplate(title: L("Radio"), sections: [section])
        if items.isEmpty {
            t.emptyViewTitleVariants = [L("No radio stations found.")]
        }
        return t
    }
}
