import SwiftUI
import WidgetKit
import ActivityKit

/// Widget-extensie van Bingr (build 52): de Live Activity met de voortgang van downloads.
@main
struct BingrWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

private let bingrRed = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // toegangsscherm en meldingen
            LockScreenView(heading: context.attributes.heading, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(context.state)).font(.title2).foregroundStyle(bingrRed)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state)).font(.headline).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress).tint(bingrRed)
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context.state)).foregroundStyle(bingrRed)
            } compactTrailing: {
                Text(percent(context.state)).font(.caption2).monospacedDigit()
            } minimal: {
                ProgressView(value: context.state.progress).progressViewStyle(.circular).tint(bingrRed)
            }
        }
    }
}

private func symbol(_ s: DownloadActivityAttributes.ContentState) -> String {
    if s.finished { return "checkmark.circle.fill" }
    return s.paused ? "pause.circle.fill" : "arrow.down.circle.fill"
}

private func percent(_ s: DownloadActivityAttributes.ContentState) -> String {
    "\(Int((s.progress * 100).rounded()))%"
}

private struct LockScreenView: View {
    let heading: String
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                Text("B").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Capsule().fill(bingrRed).frame(width: 20, height: 3).offset(y: 16)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(heading).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: symbol(state)).foregroundStyle(state.finished ? .green : bingrRed)
                    Text(percent(state)).font(.caption.weight(.semibold)).monospacedDigit()
                }
                Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                ProgressView(value: state.progress).tint(state.finished ? .green : bingrRed)
                Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
    }
}
