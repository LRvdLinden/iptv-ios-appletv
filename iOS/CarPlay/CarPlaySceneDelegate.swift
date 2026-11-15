import CarPlay
import Combine
import UIKit

/// Build 171: radio in CarPlay (audio-app). Aan vanaf build 172: entitlement `com.apple.developer.carplay-audio` en de
/// CarPlay-scene staan in project.yml (docs/CARPLAY.md).
///
/// Build 174: tabbladen Favorieten / Alle zenders / Categorieën, Now Playing met logo, titel en vorige/volgende zender
/// (MPRemoteCommandCenter, zie RadioPlayer), lijsten bijwerken als favorieten of de bibliotheek veranderen, en werken als
/// de app nog niet open was (dan eerst de server van het laatste profiel laden).
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private var bag = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        MainActor.assumeIsolated {
            let tabs = CPTabBarTemplate(templates: self.tabTemplates())
            self.tabBar = tabs
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            self.observe()
            // app was nog niet open: bibliotheek laden, daarna verschijnen de zenders vanzelf
            if RadioPlayer.shared.stations().isEmpty, let load = RadioPlayer.shared.ensureLoaded {
                Task { @MainActor in await load() }
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        tabBar = nil
        bag.removeAll()
        rebuildTask?.cancel()
    }

    @MainActor
    private func observe() {
        bag.removeAll()
        CloudStore.shared.$favorites.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &bag)
        RadioPlayer.shared.$channel.map { $0?.id }.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &bag)
        Task { @MainActor [weak self] in
            for _ in 0..<100 where RadioPlayer.shared.service == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard let self, let service = RadioPlayer.shared.service else { return }
            service.$libraryVersion.removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRebuild() }
                .store(in: &self.bag)
        }
    }

    @MainActor
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let tabBar = self.tabBar else { return }
            tabBar.updateTemplates(self.tabTemplates())
        }
    }

    // MARK: tabbladen

    @MainActor
    private func tabTemplates() -> [CPTemplate] {
        let all = RadioPlayer.shared.stations()
        let pid = RadioPlayer.shared.service?.source?.id
        let store = CloudStore.shared
        let favs = all.filter { c in (c.sourceID ?? pid).map { store.isFavorite($0, c.id) } ?? false }

        var tabs: [CPTemplate] = []
        if !favs.isEmpty {
            let t = listTemplate(title: L("Favorites"), stations: favs)
            t.tabImage = UIImage(systemName: "star.fill")
            tabs.append(t)
        }
        let allT = listTemplate(title: L("All stations"), stations: all)
        allT.tabImage = UIImage(systemName: "radio")
        if all.isEmpty {
            allT.emptyViewTitleVariants = [RadioPlayer.shared.service?.isLoading == true || RadioPlayer.shared.service?.source == nil
                                           ? L("Loading stations…") : L("No radio stations found.")]
        }
        tabs.append(allT)

        let snapshot = all.map { Radio174.Station(id: $0.id, name: $0.name, group: CategoryName.clean($0.group)) }
        let groups = Radio174.carPlayGroups(snapshot, maxGroups: CPListTemplate.maximumItemCount)
        if !groups.isEmpty {
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items: [CPListItem] = groups.map { g in
                let item = CPListItem(text: g.name, detailText: L("%d stations", g.ids.count))
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    MainActor.assumeIsolated {
                        let list = g.ids.compactMap { byID[$0] }
                        if let t = self?.listTemplate(title: g.name, stations: list) {
                            self?.interfaceController?.pushTemplate(t, animated: true, completion: nil)
                        }
                    }
                    completion()
                }
                return item
            }
            let t = CPListTemplate(title: L("Categories"), sections: [CPListSection(items: items)])
            t.tabImage = UIImage(systemName: "square.grid.2x2")
            tabs.append(t)
        }
        return Array(tabs.prefix(CPTabBarTemplate.maximumTabCount))
    }

    @MainActor
    private func listTemplate(title: String, stations: [Channel]) -> CPListTemplate {
        let playing = RadioPlayer.shared.channel?.id
        let items: [CPListItem] = stations.prefix(CPListTemplate.maximumItemCount).map { c in
            let item = CPListItem(text: CategoryName.channel(c.name), detailText: nil)
            if let logo = c.logo, let cg = ImagePipeline.shared.cachedAny(logo) {
                item.setImage(UIImage(cgImage: cg))
            } else if let img = RadioBridge174.logo(for: c) {
                item.setImage(img)
            } else {
                item.setImage(UIImage(systemName: "radio"))
                if let logo = c.logo {
                    Task { @MainActor [weak item] in
                        if let cg = await ImagePipeline.shared.load(logo, maxPixel: 120) { item?.setImage(UIImage(cgImage: cg)) }
                    }
                }
            }
            item.isPlaying = c.id == playing
            item.playingIndicatorLocation = .trailing
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    RadioPlayer.shared.play(c)
                    self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
                completion()
            }
            return item
        }
        let t = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        if items.isEmpty { t.emptyViewTitleVariants = [L("No radio stations found.")] }
        return t
    }
}
