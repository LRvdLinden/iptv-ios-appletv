import SwiftUI
import WidgetKit
import AppIntents
import ActivityKit
import UIKit

// Build 179: Live Activity van live tv: zender, logo, het programma van nu met voortgang en wat er daarna komt, met
// pauze/afspelen (ToggleLiveTVIntent, uitgevoerd in de app). Vergrendelscherm, Dynamic Island en vanaf iOS 18 een
// kleine weergave voor CarPlay en Apple Watch (zoals de radio van build 174/175). Alleen lokaal bijgewerkt.

private let tvRed = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)

private func tvLogo(_ file: String?) -> UIImage? {
    guard let file, let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Radio174.appGroup)?
        .appendingPathComponent("radio", isDirectory: true) else { return nil }
    return UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
}

private struct TVLogo: View {
    let file: String?
    let name: String
    let size: CGFloat
    var body: some View {
        Group {
            if let img = tvLogo(file) {
                Image(uiImage: img).resizable().scaledToFit().padding(size * 0.08)
            } else {
                Text(String(name.prefix(3)).uppercased()).font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.2))
    }
}

/// Voortgang van het programma van nu (het systeem tekent de balk zelf mee met de tijd)
private struct TVProgress: View {
    let s: LiveTVActivityAttributes.ContentState
    var body: some View {
        if let a = s.nowStart, let b = s.nowEnd, b > a {
            ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(tvRed)
        }
    }
}

private struct TVToggle: View {
    let attrs: LiveTVActivityAttributes
    let s: LiveTVActivityAttributes.ContentState
    let size: CGFloat
    var body: some View {
        Button(intent: ToggleLiveTVIntent()) {
            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size).background(tvRed, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.isPlaying ? attrs.pauseLabel : attrs.playLabel)
    }
}

struct LiveTVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        Self.withSmallFamily(
            ActivityConfiguration(for: LiveTVActivityAttributes.self) { context in
                LiveTVActivityContent(attrs: context.attributes, state: context.state)
                    .activityBackgroundTint(Color.black.opacity(0.85))
                    .activitySystemActionForegroundColor(.white)
            } dynamicIsland: { context in
                let a = context.attributes, s = context.state
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) { TVLogo(file: s.logo, name: s.channel, size: 44) }
                    DynamicIslandExpandedRegion(.trailing) { TVToggle(attrs: a, s: s, size: 40) }
                    DynamicIslandExpandedRegion(.center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.channel).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let now = s.now { Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            TVProgress(s: s)
                            if let next = s.next {
                                Text("\(a.nextLabel): \(timeText(s.nextStart))\(next)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } compactLeading: {
                    TVLogo(file: s.logo, name: s.channel, size: 22)
                } compactTrailing: {
                    Image(systemName: s.isPlaying ? "dot.radiowaves.left.and.right" : "pause.fill").foregroundStyle(tvRed)
                } minimal: {
                    Image(systemName: "tv").foregroundStyle(tvRed)
                }
            }
        )
    }

    private static func withSmallFamily<C: WidgetConfiguration>(_ c: C) -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return c.supplementalActivityFamilies([.small])
        } else {
            return c
        }
    }
}

private func timeText(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: d) + " "
}

private struct LiveTVActivityContent: View {
    let attrs: LiveTVActivityAttributes
    let state: LiveTVActivityAttributes.ContentState
    var body: some View {
        if #available(iOS 18.0, *) {
            LiveTVFamilyView(attrs: attrs, state: state)
        } else {
            LiveTVLockScreen(attrs: attrs, state: state)
        }
    }
}

@available(iOS 18.0, *)
private struct LiveTVFamilyView: View {
    let attrs: LiveTVActivityAttributes
    let state: LiveTVActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family
    var body: some View {
        switch family {
        case .small: LiveTVSmall(attrs: attrs, state: state)
        default: LiveTVLockScreen(attrs: attrs, state: state)
        }
    }
}

/// Klein (CarPlay, Apple Watch): logo, zender, programma van nu en pauze/afspelen
private struct LiveTVSmall: View {
    let attrs: LiveTVActivityAttributes
    let state: LiveTVActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            TVLogo(file: state.logo, name: state.channel, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.channel).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(state.now ?? attrs.heading).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            TVToggle(attrs: attrs, s: state, size: 30)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private struct LiveTVLockScreen: View {
    let attrs: LiveTVActivityAttributes
    let state: LiveTVActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            TVLogo(file: state.logo, name: state.channel, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(attrs.heading).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(state.channel).font(.headline).foregroundStyle(.white).lineLimit(1)
                if let now = state.now { Text(now).font(.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(1) }
                TVProgress(s: state)
                if let next = state.next {
                    Text("\(attrs.nextLabel): \(timeText(state.nextStart))\(next)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TVToggle(attrs: attrs, s: state, size: 46)
        }
        .padding(16)
    }
}
