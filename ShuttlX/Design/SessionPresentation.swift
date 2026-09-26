import SwiftUI
import ShuttlXCore

struct SessionOverviewCard: View {
    let statistics: SessionStatistics
    let subtitle: String
    var body: some View {
        ShuttlCard(title: "Your session", subtitle: subtitle) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statistics.totalShots.formatted())
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fontWidth(.expanded).monospacedDigit()
                    Text("detected shots").font(.subheadline).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                Spacer()
                Image(systemName: "figure.badminton")
                    .font(.system(size: 32, weight: .regular)).foregroundStyle(Color.shuttlAccent)
                    .padding(14).background(Color.shuttlAccent.opacity(0.08), in: .rect(cornerRadius: 20))
                    .accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 20) {
                compactMetric("Active time", ShuttlFormat.duration(statistics.duration), "clock")
                compactMetric("Inferred rallies", statistics.rallyCount.formatted(), "arrow.left.arrow.right")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Classification coverage").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(ShuttlFormat.percent(statistics.knownShots, of: statistics.totalShots)).font(.caption.bold()).monospacedDigit()
                }
                ProgressView(value: Double(statistics.knownShots), total: Double(max(1, statistics.totalShots)))
                    .tint(Color.shuttlAccent).accessibilityLabel("Classification coverage")
                Text("\(statistics.unknownShots) unknown · all detections remain in totals")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func compactMetric(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

struct FirstSessionCard: View {
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        ShuttlCard(title: "") {
            Image(systemName: "figure.badminton")
                .font(.system(size: 48, weight: .light)).foregroundStyle(Color.shuttlAccent)
                .padding(20).background(Color.shuttlAccent.opacity(0.08), in: .circle)
                .accessibilityHidden(true)
            Text("Your game.\nA clearer picture.").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text("Record a session on your Watch. Your shots, swing patterns and personal bests will come together here.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Label("Wear your Watch on your racket wrist", systemImage: "applewatch")
                Label("Start a session on the Watch", systemImage: "play.circle")
                Label("Return here when your session syncs", systemImage: "arrow.triangle.2.circlepath")
            }.font(.subheadline)
            Button { navigation.selection = .watch } label: {
                Text("Set up your Watch").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

struct SessionHistorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UUID?
    @State private var query = ""
    private var matchingSessions: [Session] {
        store.sessions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
            $0.startedAt.formatted(date: .abbreviated, time: .omitted).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selection = nil; dismiss()
                    } label: { Label("Use selected time period", systemImage: "calendar") }
                }
                Section("Saved sessions") {
                    ForEach(matchingSessions) { session in
                        Button {
                            selection = session.id; dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "figure.badminton").foregroundStyle(Color.shuttlAccent)
                                    .frame(width: 40, height: 44).background(Color.shuttlAccent.opacity(0.08), in: .rect(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.name).font(.headline).foregroundStyle(.primary)
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Text("\(session.shotCount) shots · \(ShuttlFormat.duration(session.activeDuration))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if selection == session.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.shuttlAccent) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .overlay {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "clock", description: Text("Completed Watch sessions will appear here."))
                } else if matchingSessions.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Session name or date")
            .navigationTitle("Session history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
