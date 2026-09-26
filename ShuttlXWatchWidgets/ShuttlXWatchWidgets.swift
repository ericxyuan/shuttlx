import WidgetKit
import SwiftUI

struct WatchSnapshotEntry: TimelineEntry { let date: Date; let snapshot: WatchWidgetSnapshot }
struct WatchSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchSnapshotEntry { .init(date: .now, snapshot: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (WatchSnapshotEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchSnapshotEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(900))))
    }
    private func load() -> WatchSnapshotEntry { .init(date: .now, snapshot: WatchWidgetSnapshotStore.load()) }
}
struct WatchAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchSnapshotEntry
    var body: some View {
        Group {
            if !entry.snapshot.hasSession {
                if family == .accessoryCircular {
                    Image(systemName: "figure.badminton").font(.title2).widgetAccentable()
                } else {
                    Label("Start ShuttlX", systemImage: "figure.badminton")
                }
            } else if family == .accessoryInline {
                Text("ShuttlX · \(entry.snapshot.shotCount) shots")
            } else if family == .accessoryCircular {
                VStack(spacing: 2) {
                    Image(systemName: "figure.badminton").font(.caption2)
                    Text("\(entry.snapshot.shotCount)").font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit().widgetAccentable()
                    Text("shots").font(.caption2)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("SHUTTLX").font(.caption2.bold())
                        Spacer()
                        Image(systemName: "figure.badminton").widgetAccentable()
                    }
                    Text("\(entry.snapshot.shotCount) shots").font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                    Text(entry.snapshot.lastShot ?? "No strokes detected").font(.caption)
                    Text("Updated \(entry.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))").font(.caption2)
                }
            }
        }
        .containerBackground(for: .widget) { Color.black }
        .accessibilityLabel(entry.snapshot.hasSession ? "ShuttlX snapshot, \(entry.snapshot.shotCount) shots. Open app for current session." : "ShuttlX, start a session")
    }
}
struct WatchAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAccessory", provider: WatchSnapshotProvider()) { WatchAccessoryView(entry: $0) }
            .configurationDisplayName("ShuttlX session")
            .description("Latest saved session snapshot. Refresh is controlled by watchOS.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
@main struct ShuttlXWatchWidgets: WidgetBundle { var body: some Widget { WatchAccessoryWidget() } }
