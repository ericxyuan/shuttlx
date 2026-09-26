import WidgetKit
import SwiftUI
import Foundation

struct WidgetSnapshotEntry: TimelineEntry { let date: Date; let snapshot: PhoneWidgetSnapshot; let unit: String }
struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetSnapshotEntry { .init(date: .now, snapshot: .init(), unit: "km/h") }
    func getSnapshot(in context: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(900))))
    }
    private func load() -> WidgetSnapshotEntry { .init(date: .now, snapshot: PhoneWidgetSnapshotStore.load(), unit: PhoneWidgetSnapshotStore.speedUnit) }
}
struct AnalysisWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetSnapshotEntry
    private let accent = Color(red: 0, green: 0.4, blue: 0.69)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SHUTTLX").font(.caption2.bold()).tracking(1.4)
                Spacer(minLength: 0)
                Image(systemName: "figure.badminton").foregroundStyle(accent).widgetAccentable()
            }
            if entry.snapshot.sessionID == nil {
                Text("Your next session\nstarts on Watch.").font(.headline)
                Spacer(minLength: 0)
                Text("Play. Sync. Understand.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.snapshot.shotCount.map { $0.formatted() } ?? "—")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit().widgetAccentable()
                        Text("detected shots").font(.caption).foregroundStyle(.secondary)
                    }
                    if family != .systemSmall, let duration = entry.snapshot.activeDuration {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(time(duration)).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                            Text("active time").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if family != .systemSmall {
                    Divider()
                    if entry.snapshot.attackPercent != nil || entry.snapshot.defencePercent != nil {
                        HStack { metric("Attack", entry.snapshot.attackPercent); Spacer(); metric("Defence", entry.snapshot.defencePercent) }
                    } else { Text("Open Analysis to explore your recorded motion.").font(.caption).foregroundStyle(.secondary) }
                }
                if family == .systemLarge {
                    Divider()
                    HStack { metric("Forehand", entry.snapshot.forehandPercent); Spacer(); metric("Backhand", entry.snapshot.backhandPercent) }
                    Text("Unknown classifications stay in your shot total.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(entry.snapshot.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .secondarySystemGroupedBackground) }
        .widgetURL(URL(string: "shuttlx://analysis" + (entry.snapshot.sessionID.map { "?session=\($0.uuidString)" } ?? "")))
    }
    private func metric(_ title: String, _ value: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "—").font(.subheadline.bold().monospacedDigit())
        }.accessibilityElement(children: .combine)
    }
    private func time(_ duration: Double) -> String {
        guard duration.isFinite else { return "—" }
        let minutes = Int(max(0, duration) / 60)
        return "\(minutes)m"
    }
}
struct RecordWidgetView: View {
    let entry: WidgetSnapshotEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("PERSONAL BEST", systemImage: "trophy").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Fastest Smash").font(.headline)
            if let speed = entry.snapshot.fastestSmash {
                Text((entry.unit == "mph" ? speed / 1.609344 : speed).formatted(.number.precision(.fractionLength(0))))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("\(entry.unit) · estimated swing").font(.caption).foregroundStyle(.secondary)
                if let date = entry.snapshot.fastestSmashDate { Text(date, style: .date).font(.caption2) }
            } else {
                Text("No eligible record yet").font(.subheadline)
                Text("Needs a classified smash and a speed estimate.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .secondarySystemGroupedBackground) }
        .widgetURL(URL(string: "shuttlx://records"))
    }
}
@main struct ShuttlXWidgets: WidgetBundle { var body: some Widget { AnalysisWidget(); RecordWidget() } }
struct AnalysisWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AnalysisWidget", provider: WidgetProvider()) { AnalysisWidgetView(entry: $0) }
            .configurationDisplayName("Analysis snapshot").description("Your latest recorded badminton analysis.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecordWidget", provider: WidgetProvider()) { RecordWidgetView(entry: $0) }
            .configurationDisplayName("Personal best").description("Your estimated fastest smash.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
