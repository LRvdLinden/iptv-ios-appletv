import SwiftUI
import WidgetKit
import AppIntents
#if os(iOS)
import ActivityKit
import UIKit
private typealias RadioImage = UIImage
#else
import AppKit
private typealias RadioImage = NSImage
#endif

// Build 174: Bingr Radio in de widget-extensie: de widget "Bingr Radio" (klein en middel; vanaf iOS 26 ook op het
// CarPlay-dashboard) en de Live Activity tijdens het afspelen (vanaf iOS 26 ook op CarPlay, in de compacte weergave).
// De gegevens zet de app in de App Group (RadioBridge174); de knoppen zijn App Intents die in de app worden uitgevoerd
// (iOS/Radio/RadioIntents.swift).
// Build 175: de widget ook op de Mac (extensie BingrMacWidgets, zonder Live Activity), en een aparte kleine weergave van
// de Live Activity voor CarPlay en Apple Watch (iOS 18: supplementalActivityFamilies([.small]) en activityFamily, via
// `if #available` in de configuratie zelf; de extensie houdt iOS 17 als minimum, iOS 17 houdt de gewone weergave).

private let radioRed = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)

private enum RadioFiles {
    static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Radio174.appGroup)?
            .appendingPathComponent("radio", isDirectory: true)
    }
    static func snapshot() -> Radio174.Snapshot? {
        guard let dir else { return nil }
        return Radio174.Snapshot.decode(try? Data(contentsOf: dir.appendingPathComponent("stations.json")))
    }
    static func logo(_ file: String?) -> RadioImage? {
        guard let file, let dir else { return nil }
        return RadioImage(contentsOfFile: dir.appendingPathComponent(file).path)
    }
}

/// Teksten in de galerie (vóór de app iets heeft klaargezet); daarna komen ze uit de app (snapshot.texts)
private enum RadioWidgetText {
    static var lang: String { String((Locale.preferredLanguages.first ?? "en").prefix(2)) }
    static var description: String {
        switch lang {
        case "nl": return "Je favoriete radiozenders en wat er nu speelt."
        case "de": return "Deine Lieblingsradiosender und was gerade läuft."
        case "fr": return "Vos stations de radio favorites et ce qui passe maintenant."
        case "es": return "Tus emisoras de radio favoritas y lo que suena ahora."
        case "it": return "Le tue stazioni radio preferite e cosa va in onda ora."
        case "pt": return "As tuas rádios favoritas e o que está a tocar agora."
        case "tr": return "Favori radyo istasyonların ve şu an çalan."
        case "pl": return "Twoje ulubione stacje radiowe i to, co teraz gra."
        case "ar": return "محطات الراديو المفضلة لديك وما يُذاع الآن."
        case "zh": return "你喜爱的电台和正在播放的内容。"
        default: return "Your favorite radio stations and what's playing now."
        }
    }
    static var empty: String {
        switch lang {
        case "nl": return "Open Bingr om je radiozenders te kiezen."
        case "de": return "Öffne Bingr, um deine Radiosender zu wählen."
        case "fr": return "Ouvrez Bingr pour choisir vos stations de radio."
        case "es": return "Abre Bingr para elegir tus emisoras de radio."
        case "it": return "Apri Bingr per scegliere le tue stazioni radio."
        case "pt": return "Abre o Bingr para escolher as tuas rádios."
        case "tr": return "Radyo istasyonlarını seçmek için Bingr'ı aç."
        case "pl": return "Otwórz Bingr, aby wybrać stacje radiowe."
        case "ar": return "افتح Bingr لاختيار محطات الراديو."
        case "zh": return "打开 Bingr 选择你的电台。"
        default: return "Open Bingr to choose your radio stations."
        }
    }
}

// MARK: - Widget "Bingr Radio"

struct RadioEntry: TimelineEntry {
    let date: Date
    let snapshot: Radio174.Snapshot?
}

struct RadioProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadioEntry {
        RadioEntry(date: Date(), snapshot: Radio174.Snapshot(stations: [
            .init(id: "1", name: "Radio 1", favorite: true), .init(id: "2", name: "Radio 2", favorite: true),
            .init(id: "3", name: "Radio 3"), .init(id: "4", name: "Radio 4")]))
    }
    func getSnapshot(in context: Context, completion: @escaping (RadioEntry) -> Void) {
        completion(RadioEntry(date: Date(), snapshot: RadioFiles.snapshot() ?? placeholder(in: context).snapshot))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RadioEntry>) -> Void) {
        // de app vraagt zelf om een nieuwe tijdlijn (WidgetCenter.reloadTimelines) als er iets verandert
        completion(Timeline(entries: [RadioEntry(date: Date(), snapshot: RadioFiles.snapshot())], policy: .never))
    }
}

struct RadioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Radio174.widgetKind, provider: RadioProvider()) { entry in
            RadioWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Bingr Radio")
        .description(RadioWidgetText.description)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct RadioWidgetView: View {
    let entry: RadioEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snap = entry.snapshot, let featured = Radio174.featured(snap) {
            switch family {
            case .systemMedium: medium(snap, featured)
            default: small(snap, featured)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header("Bingr Radio")
                Spacer(minLength: 0)
                Text(entry.snapshot?.text("empty", RadioWidgetText.empty) ?? RadioWidgetText.empty)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ t: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "radio").font(.caption2.weight(.bold)).foregroundStyle(radioRed)
            Text(t).font(.caption2.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func isCurrent(_ snap: Radio174.Snapshot, _ s: Radio174.Station) -> Bool { snap.currentID == s.id }

    private func small(_ snap: Radio174.Snapshot, _ s: Radio174.Station) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                RadioLogo(file: s.logo, size: 44)
                Spacer(minLength: 0)
                playButton(snap, s, size: 36)
            }
            Spacer(minLength: 0)
            Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
            if isCurrent(snap, s), let now = snap.nowPlaying {
                Text(now).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else {
                header(snap.text("radio", "Radio"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ snap: Radio174.Snapshot, _ s: Radio174.Station) -> some View {
        HStack(spacing: 12) {
            small(snap, s).frame(maxWidth: .infinity)
            let others = Radio174.widgetStations(snap.stations.filter { $0.id != s.id }, max: 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(others, id: \.id) { o in
                    Button(intent: PlayRadioStationIntent(stationID: o.id)) {
                        VStack(spacing: 4) {
                            RadioLogo(file: o.logo, size: 34)
                            Text(o.name).font(.caption2).foregroundStyle(.white).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func playButton(_ snap: Radio174.Snapshot, _ s: Radio174.Station, size: CGFloat) -> some View {
        let playing = isCurrent(snap, s) && snap.isPlaying
        let icon = Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(radioRed, in: Circle())
        if isCurrent(snap, s) {
            Button(intent: ToggleRadioIntent()) { icon }.buttonStyle(.plain)
                .accessibilityLabel(playing ? snap.text("pause", "Pause") : snap.text("play", "Play"))
        } else {
            Button(intent: PlayRadioStationIntent(stationID: s.id)) { icon }.buttonStyle(.plain)
                .accessibilityLabel(snap.text("play", "Play"))
        }
    }
}

private struct RadioLogo: View {
    let file: String?
    let size: CGFloat
    var body: some View {
        Group {
            if let img = RadioFiles.logo(file) {
                logoImage(img).resizable().scaledToFit().padding(size * 0.08)
            } else {
                Image(systemName: "radio").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private func logoImage(_ img: RadioImage) -> Image {
        #if os(iOS)
        return Image(uiImage: img)
        #else
        return Image(nsImage: img)
        #endif
    }
}

// MARK: - Live Activity (iPhone en iPad)

#if os(iOS)
struct RadioLiveActivity: Widget {
    var body: some WidgetConfiguration {
        Self.withSmallFamily(
            ActivityConfiguration(for: RadioActivityAttributes.self) { context in
                RadioActivityContent(attrs: context.attributes, state: context.state)
                    .activityBackgroundTint(Color.black.opacity(0.85))
                    .activitySystemActionForegroundColor(.white)
            } dynamicIsland: { context in
                radioIsland(context.attributes, context.state)
            }
        )
    }

    /// Build 175: vanaf iOS 18 ook een eigen kleine weergave (CarPlay, Apple Watch). Opaque type met `if #available`
    /// (SE-0360), zodat iOS 17 de gewone configuratie houdt zonder de extensie naar iOS 18 te tillen.
    private static func withSmallFamily<C: WidgetConfiguration>(_ c: C) -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return c.supplementalActivityFamilies([.small])
        } else {
            return c
        }
    }
}

/// Vergrendelscherm (medium) of, vanaf iOS 18, de kleine weergave
private struct RadioActivityContent: View {
    let attrs: RadioActivityAttributes
    let state: RadioActivityAttributes.ContentState
    var body: some View {
        if #available(iOS 18.0, *) {
            RadioActivityFamilyView(attrs: attrs, state: state)
        } else {
            RadioLockScreenView(attrs: attrs, state: state)
        }
    }
}

@available(iOS 18.0, *)
private struct RadioActivityFamilyView: View {
    let attrs: RadioActivityAttributes
    let state: RadioActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family
    var body: some View {
        switch family {
        case .small: RadioSmallActivityView(attrs: attrs, state: state)
        default: RadioLockScreenView(attrs: attrs, state: state)
        }
    }
}

/// Build 175: klein (CarPlay, Apple Watch): logo, zender, nu aan het spelen (één regel) en pauze/afspelen
private struct RadioSmallActivityView: View {
    let attrs: RadioActivityAttributes
    let state: RadioActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            RadioLogo(file: state.logo, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.station).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(state.nowPlaying ?? attrs.heading).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(intent: ToggleRadioIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(radioRed, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPlaying ? attrs.pauseLabel : attrs.playLabel)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private func radioIsland(_ a: RadioActivityAttributes, _ s: RadioActivityAttributes.ContentState) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            RadioLogo(file: s.logo, size: 44)
        }
        DynamicIslandExpandedRegion(.trailing) {
            Image(systemName: s.isPlaying ? "waveform" : "pause.fill").font(.title3).foregroundStyle(radioRed)
        }
        DynamicIslandExpandedRegion(.center) {
            VStack(spacing: 2) {
                Text(s.station).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let now = s.nowPlaying { Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        DynamicIslandExpandedRegion(.bottom) {
            RadioControls(attrs: a, state: s)
        }
    } compactLeading: {
        RadioLogo(file: s.logo, size: 22)
    } compactTrailing: {
        Image(systemName: s.isPlaying ? "waveform" : "pause.fill").foregroundStyle(radioRed)
    } minimal: {
        Image(systemName: "radio").foregroundStyle(radioRed)
    }
}

private struct RadioControls: View {
    let attrs: RadioActivityAttributes
    let state: RadioActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 28) {
            Button(intent: StepRadioIntent(step: -1)) {
                Image(systemName: "backward.fill").font(.title3)
            }
            .accessibilityLabel(attrs.previousLabel)
            Button(intent: ToggleRadioIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 46, height: 46).background(radioRed, in: Circle())
            }
            .accessibilityLabel(state.isPlaying ? attrs.pauseLabel : attrs.playLabel)
            Button(intent: StepRadioIntent(step: 1)) {
                Image(systemName: "forward.fill").font(.title3)
            }
            .accessibilityLabel(attrs.nextLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}

private struct RadioLockScreenView: View {
    let attrs: RadioActivityAttributes
    let state: RadioActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            RadioLogo(file: state.logo, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(attrs.heading).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(state.station).font(.headline).foregroundStyle(.white).lineLimit(1)
                if let now = state.nowPlaying {
                    Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RadioControls(attrs: attrs, state: state).fixedSize()
        }
        .padding(16)
    }
}
#endif
