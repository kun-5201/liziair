import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for Lizi: shows the synced lyric of the song playing
/// in the Lizi web player.
///
/// - compactLeading: current lyric line (single line, truncated).
/// - compactTrailing: ♪ (no cover art in v1).
/// - expanded: title/artist + 3 lyric lines (prev dimmed, current bold,
///   next dimmed) + progress bar.
/// - minimal: ♪.
/// - lock screen: same as expanded (3 lines, current bold) + progress.
struct LiziLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiziLyricsAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("♪")
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.currentLyric)
                        .font(.headline)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if let prev = context.state.prevLyric {
                            Text(prev)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let next = context.state.nextLyric {
                            Text(next)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ProgressView(value: context.state.progress)
                            .tint(.white)
                    }
                }
            } compactLeading: {
                Text(context.state.currentLyric)
                    .lineLimit(1)
            } compactTrailing: {
                Text("♪")
            } minimal: {
                Text("♪")
            }
            .keylineTint(.white)
        }
    }

    private func lockScreenView(context: ActivityViewContext<LiziLyricsAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(context.attributes.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let prev = context.state.prevLyric {
                Text(prev)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(context.state.currentLyric)
                .font(.headline)
                .fontWeight(.bold)
                .lineLimit(2)
            if let next = context.state.nextLyric {
                Text(next)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: context.state.progress)
                .tint(.white)
        }
        .padding()
    }
}
