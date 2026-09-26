import SwiftUI
import Charts
import ShuttlXCore

struct AnalysisView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @State private var period: AnalyticsPeriod = .latestSession
    @State private var selectedSession: UUID?
    @State private var showingHistory = false
    private var sessions: [Session] {
        if let selectedSession { return store.sessions.filter { $0.id == selectedSession } }
        return period.sessions(from: store.sessions)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    ShuttlPeriodPicker(selection: $period)
                    Spacer()
                    Button { showingHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.headline).frame(width: 46, height: 46).shuttlGlass()
                    }.accessibilityLabel("Session history")
                }
                if let selected = sessions.first, selectedSession != nil {
                    Label(selected.name, systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                } else { Text("A closer look at your game").font(.subheadline).foregroundStyle(.secondary) }
                if sessions.isEmpty && !store.sessions.isEmpty {
                    ContentUnavailableView("No sessions in this period", systemImage: "calendar",
                                           description: Text("Choose another time period or open session history."))
                } else {
                    AnalysisContent(sessions: sessions,
                                    summary: selectedSession.map { store.analysis(forSession: $0) } ?? store.analysis(for: period))
                }
            }.padding(20)
        }
        .background(Color.shuttlBackground)
        .navigationTitle("Analysis")
        .sheet(isPresented: $showingHistory) { SessionHistorySheet(selection: $selectedSession) }
        .onChange(of: period) { _, _ in selectedSession = nil }
        .onChange(of: navigation.routeRevision, initial: true) { _, _ in
            guard navigation.selection == .analysis else { return }
            selectedSession = navigation.requestedSessionID
            showingHistory = false
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            if let selectedSession, !ids.contains(selectedSession) { self.selectedSession = nil }
        }
    }
}

private struct AnalysisContent: View {
    @Environment(AppStore.self) private var store
    @Environment(ProfileStore.self) private var profile
    let sessions: [Session]
    let summary: AnalysisSummary
    @State private var selectedRadar: RadarMetric?
    var body: some View {
        if sessions.isEmpty {
            FirstSessionCard()
        } else {
            SessionOverviewCard(statistics: summary.statistics,
                                subtitle: sessions.count == 1 ? sessions[0].startedAt.formatted(date: .abbreviated, time: .shortened) : "\(sessions.count) sessions")
            RadarCard(metrics: summary.radar) { selectedRadar = $0 }
                .sheet(item: $selectedRadar) { metric in
                    NavigationStack {
                        List {
                            Section {
                                ShuttlStatRow(label: metric.name, value: ShuttlFormat.number(metric.normalizedScore), unit: metric.normalizedScore == nil ? "" : "/100")
                                Text(metric.explanation)
                            }
                            Section("Inputs") {
                                ForEach(metric.sourceMetrics.keys.sorted(), id: \.self) { key in
                                    LabeledContent(key, value: ShuttlFormat.number(metric.sourceMetrics[key], digits: 1))
                                }
                                LabeledContent("Data coverage", value: metric.confidence.formatted(.percent))
                                LabeledContent("Minimum observations", value: "\(metric.minimumDataRequirement)")
                            }
                        }.navigationTitle(metric.name).navigationBarTitleDisplayMode(.inline)
                    }.presentationDragIndicator(.visible)
                }
            ShuttlCard(title: "Forehand / backhand", subtitle: "Shares of classified hand observations") {
                let known = summary.statistics.handCounts[.forehand, default: 0] + summary.statistics.handCounts[.backhand, default: 0]
                ForEach([ShotHand.forehand, .backhand]) { hand in
                    let values = sessions.flatMap(\.shots).filter { $0.hand == hand }.compactMap(\.estimatedSwingSpeed)
                    ShuttlStatRow(label: hand.displayName, value: ShuttlFormat.percent(summary.statistics.handCounts[hand, default: 0], of: known))
                    Text("Average \(speed(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))) · maximum \(speed(values.max()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(summary.statistics.handCounts[.unknown, default: 0]) unknown hand observations").font(.caption).foregroundStyle(.secondary)
            }
            ShuttlCard(title: "Attack / defence", subtitle: "Shares include neutral classified observations") {
                let stats = summary.statistics
                let known = stats.totalShots - stats.tacticalCounts[.unknown, default: 0]
                ForEach(TacticalRole.allCases) { role in
                    ShuttlStatRow(label: role.displayName, value: "\(stats.tacticalCounts[role, default: 0])",
                                  unit: role == .unknown ? "shots" : ShuttlFormat.percent(stats.tacticalCounts[role, default: 0], of: known))
                }
                if known == 0 { Text("Wrist motion alone cannot establish tactical intent.").font(.caption).foregroundStyle(.secondary) }
            }
            ShuttlCard(title: "Shot distribution", subtitle: "Percentages use all detected shots") {
                ForEach(ShotType.allCases.filter { profile.showUnknownShots || $0 != .unknown }) { type in
                    ShuttlStatRow(label: type.displayName, value: "\(summary.statistics.shotCounts[type, default: 0])",
                                  unit: ShuttlFormat.percent(summary.statistics.shotCounts[type, default: 0], of: summary.statistics.totalShots))
                }
                if !profile.showUnknownShots { Text("Unknown shots are hidden here but remain in totals.").font(.caption).foregroundStyle(.secondary) }
            }
            SwingChart(sessions: sessions)
            ShuttlCard(title: "Consistency", subtitle: "Motion repeatability, not shot accuracy") {
                if summary.consistency.isEmpty { Text("Needs at least five classified examples of one shot type.").foregroundStyle(.secondary) }
                ForEach(summary.consistency) { result in
                    DisclosureGroup {
                        Text(result.explanation).font(.subheadline)
                    } label: { ShuttlStatRow(label: result.type.displayName, value: ShuttlFormat.number(result.score), unit: "/100") }
                }
            }
            ShuttlCard(title: "Rallies", subtitle: "Inferred from your own stroke timing") {
                ShuttlStatRow(label: "Average length", value: ShuttlFormat.number(summary.statistics.averageRallyLength, digits: 1), unit: "shots")
                ShuttlStatRow(label: "Longest", value: "\(summary.statistics.longestRally)", unit: "shots")
                ShuttlStatRow(label: "Average interval", value: ShuttlFormat.number(summary.statistics.averageRest, digits: 1), unit: "s")
                NavigationLink("Browse \(summary.rallies.count) inferred rallies") {
                    List(summary.rallies) { rally in
                        if let session = sessions.first(where: { $0.id == rally.sessionID }) {
                            NavigationLink {
                                ShotList(sessions: [session], only: Set(rally.shots.map(\.id)))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("\(rally.shotCount) shots · \(ShuttlFormat.duration(rally.duration))")
                                    Text(session.startedAt.addingTimeInterval(rally.startedAt).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.navigationTitle("Rallies")
                }
                Text("Opponent contacts and rally outcomes are not measured.").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink { ShotList(sessions: sessions) } label: {
                ShuttlCard(title: "Shot timeline", subtitle: "Explore every event and its retained sensor window") {
                    Label("Browse \(summary.statistics.totalShots) shots", systemImage: "arrow.right")
                }
            }.buttonStyle(.plain)
            ForEach(summary.insights, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func speed(_ value: Double?) -> String { SpeedDisplay.text(value, unit: profile.speedUnit) }
}

private struct DatedShot: Identifiable {
    var id: UUID { shot.id }
    let session: Session
    let shot: ShotEvent
    var date: Date { session.date(of: shot) }
}
private func datedShots(_ sessions: [Session]) -> [DatedShot] {
    sessions.flatMap { session in session.shots.map { DatedShot(session: session, shot: $0) } }.sorted { $0.date < $1.date }
}
enum SpeedDisplay {
    static func value(_ value: Double, unit: String) -> Double { unit == "mph" ? value / 1.609344 : value }
    static func text(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(ShuttlFormat.number(Self.value(value, unit: unit))) \(unit)"
    }
}

private struct SwingChart: View {
    @Environment(ProfileStore.self) private var profile
    let sessions: [Session]
    @State private var filter: ShotType?
    @State private var selectedDate: Date?
    private var rows: [DatedShot] {
        datedShots(sessions).filter { $0.shot.estimatedSwingSpeed != nil && (filter == nil || $0.shot.type == filter) }
    }
    var body: some View {
        ShuttlCard(title: "Estimated swing speed", subtitle: "Wrist-motion estimate · \(profile.speedUnit)") {
            Picker("Shot type", selection: $filter) {
                Text("All shots").tag(Optional<ShotType>.none)
                ForEach(ShotType.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
            if rows.isEmpty {
                Text("No speed estimates in this selection.").foregroundStyle(.secondary)
            } else {
                Chart(rows) { row in
                    PointMark(x: .value("Time", row.date),
                              y: .value("Estimated swing speed", SpeedDisplay.value(row.shot.estimatedSwingSpeed ?? 0, unit: profile.speedUnit)))
                        .foregroundStyle(Color.shuttlAccent)
                        .accessibilityLabel(row.shot.type.displayName)
                        .accessibilityValue(SpeedDisplay.text(row.shot.estimatedSwingSpeed, unit: profile.speedUnit))
                }.frame(height: 210).chartXSelection(value: $selectedDate)
                if let selectedDate, let nearest = rows.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                    NavigationLink { ShotDetailView(session: nearest.session, shot: nearest.shot) } label: {
                        Label("\(nearest.shot.type.displayName) · \(SpeedDisplay.text(nearest.shot.estimatedSwingSpeed, unit: profile.speedUnit))", systemImage: "waveform.path")
                    }
                }
            }
            DisclosureGroup("How to interpret swing speed") { Text(ShuttlFormat.swingExplanation).font(.subheadline) }
        }
    }
}

struct ShotList: View {
    @Environment(ProfileStore.self) private var profile
    let sessions: [Session]
    var only: Set<UUID>?
    @State private var filter: ShotType?
    var body: some View {
        let rows = datedShots(sessions).filter {
            (only == nil || only!.contains($0.id)) && (filter == nil || filter == $0.shot.type)
            && (profile.showUnknownShots || $0.shot.type != .unknown)
        }
        List {
            Picker("Shot type", selection: $filter) {
                Text("All visible shots").tag(Optional<ShotType>.none)
                ForEach(ShotType.allCases.filter { profile.showUnknownShots || $0 != .unknown }) { Text($0.displayName).tag(Optional($0)) }
            }
            ForEach(rows) { row in
                NavigationLink { ShotDetailView(session: row.session, shot: row.shot) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(row.shot.type.displayName); Spacer(); Text(SpeedDisplay.text(row.shot.estimatedSwingSpeed, unit: profile.speedUnit)).monospacedDigit() }
                        Text(row.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if rows.isEmpty { Text("No visible shots match these filters.").foregroundStyle(.secondary) }
        }.navigationTitle("Shot timeline")
    }
}

struct ShotDetailView: View {
    @Environment(ProfileStore.self) private var profile
    let session: Session
    let shot: ShotEvent
    var body: some View {
        List {
            Section("Observation") {
                LabeledContent("Recorded", value: session.date(of: shot).formatted(date: .abbreviated, time: .standard))
                LabeledContent("Shot type", value: shot.type.displayName)
                LabeledContent("Type confidence", value: shot.confidence.formatted(.percent))
                LabeledContent("Hand", value: shot.hand.displayName)
                LabeledContent("Hand confidence", value: shot.handConfidence.formatted(.percent))
                LabeledContent("Position", value: shot.position.displayName)
                LabeledContent("Position confidence", value: shot.positionConfidence.formatted(.percent))
                LabeledContent("Tactical role", value: shot.tactical.displayName)
            }
            Section("Measurements") {
                LabeledContent("Estimated swing", value: SpeedDisplay.text(shot.estimatedSwingSpeed, unit: profile.speedUnit))
                LabeledContent("Peak wrist rotation", value: "\(ShuttlFormat.number(shot.peakRotationDegrees)) °/s")
                LabeledContent("Peak user acceleration", value: "\(ShuttlFormat.number(shot.peakAcceleration, digits: 2)) g")
                LabeledContent("Swing duration", value: "\(ShuttlFormat.number(shot.duration, digits: 2)) s")
            }
            if shot.samples.isEmpty {
                Section("Sensor window") { Text("Raw samples were not retained or have expired. Summary measurements are still available.") }
            } else {
                Section("User acceleration · g") {
                    sensorChart(rotation: false)
                }
                Section("Wrist rotation · rad/s") {
                    sensorChart(rotation: true)
                }
            }
            Section { Text(ShuttlFormat.swingExplanation).font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(shot.type.displayName).navigationBarTitleDisplayMode(.inline)
    }
    private func sensorChart(rotation: Bool) -> some View {
        Chart(shot.samples, id: \.timestamp) { sample in
            LineMark(x: .value("Seconds from shot", sample.timestamp - shot.timestamp),
                     y: .value(rotation ? "rad/s" : "g", rotation ? sample.rotation.magnitude : sample.acceleration.magnitude))
                .foregroundStyle(Color.shuttlAccent)
        }.frame(height: 190).chartXAxisLabel("Seconds from shot")
    }
}

private struct RadarCard: View {
    let metrics: [RadarMetric]
    let onSelect: (RadarMetric) -> Void
    var body: some View {
        ShuttlCard(title: "Performance overview", subtitle: "A description of your data, not a skill rating") {
            Canvas { context, size in
                let radius = min(size.width, size.height) * 0.45
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                func point(_ index: Int, _ fraction: Double) -> CGPoint {
                    let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(1, metrics.count))
                    return CGPoint(x: centre.x + cos(angle) * radius * fraction, y: centre.y + sin(angle) * radius * fraction)
                }
                for fraction in [0.25, 0.5, 0.75, 1.0] {
                    var path = Path()
                    for index in metrics.indices {
                        if index == 0 { path.move(to: point(index, fraction)) }
                        else { path.addLine(to: point(index, fraction)) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                }
                for index in metrics.indices {
                    var axis = Path(); axis.move(to: centre); axis.addLine(to: point(index, 1))
                    context.stroke(axis, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    if let score = metrics[index].normalizedScore {
                        let p = point(index, score / 100)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.shuttlAccent))
                    }
                }
                // Missing dimensions are never plotted as zero or connected into a false polygon.
            }.frame(height: 190).accessibilityHidden(true)
            ForEach(metrics) { metric in
                Button { onSelect(metric) } label: {
                    ShuttlStatRow(label: metric.name, value: metric.normalizedScore.map { ShuttlFormat.number($0) } ?? "Unavailable",
                                  unit: metric.normalizedScore == nil ? "" : "/100")
                }.buttonStyle(.plain)
            }
        }
    }
}

struct StatisticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ProfileStore.self) private var profile
    @State private var period: AnalyticsPeriod = .latestSession
    var body: some View {
        let stats = store.statistics(for: period)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShuttlPeriodPicker(selection: $period)
                if stats.sessionCount == 0 {
                    ShuttlEmptyState(title: "No measurements yet", message: "Start a session on Apple Watch to collect your first measurements.", systemImage: "chart.bar.xaxis")
                } else {
                    ShuttlCard(title: "Session") {
                        stat("Sessions", "\(stats.sessionCount)", "Completed sessions in this period.")
                        stat("Active time", ShuttlFormat.duration(stats.duration), "Tracking time, excluding explicit pauses.")
                        stat("Total shots", "\(stats.totalShots)", "All detected candidate swings, including unknown classifications.")
                        stat("Rallies", "\(stats.rallyCount)", "Groups inferred from this player's stroke timing.")
                        stat("Average rally", ShuttlFormat.number(stats.averageRallyLength, digits: 1), "Mean number of your strokes per inferred rally.")
                        stat("Longest rally", "\(stats.longestRally)", "Maximum number of your strokes in one inferred rally.")
                        stat("Average rest", ShuttlFormat.number(stats.averageRest, digits: 1) + " s", "Average gap between inferred rallies within the same session.")
                    }
                    ShuttlCard(title: "Motion") {
                        stat("Maximum swing", SpeedDisplay.text(stats.maxSwingSpeed, unit: profile.speedUnit), ShuttlFormat.swingExplanation)
                        stat("Average swing", SpeedDisplay.text(stats.averageSwingSpeed, unit: profile.speedUnit), ShuttlFormat.swingExplanation)
                        stat("Median swing", SpeedDisplay.text(stats.medianSwingSpeed, unit: profile.speedUnit), "Middle estimated speed among strokes with an available speed estimate.")
                        stat("Maximum rotation", ShuttlFormat.number(stats.maxAngularVelocity) + " °/s", "Maximum per-stroke peak wrist rotation.")
                        stat("Average rotation", ShuttlFormat.number(stats.averageAngularVelocity) + " °/s", "Mean of per-stroke peak wrist rotation; not a continuous session average.")
                        stat("Maximum acceleration", ShuttlFormat.number(stats.maxAcceleration, digits: 2) + " g", "Peak gravity-excluded acceleration measured at the wrist.")
                    }
                    ShuttlCard(title: "Shot counts") {
                        ForEach(ShotType.allCases) { type in
                            stat(type.displayName, "\(stats.shotCounts[type, default: 0])", "Count of events classified as \(type.displayName.lowercased()).")
                        }
                    }
                    ShuttlCard(title: "Hand and position") {
                        ForEach(ShotHand.allCases) { hand in stat(hand.displayName + " hand", "\(stats.handCounts[hand, default: 0])", "Requires calibrated or model-supported hand classification.") }
                        ForEach(ShotPosition.allCases) { position in stat(position.displayName + " position", "\(stats.positionCounts[position, default: 0])", "Unknown remains explicit when evidence is insufficient.") }
                    }
                    ShuttlCard(title: "Acceleration bands") {
                        stat("High", "\(stats.highIntensity)", "Peak user acceleration at or above 7 g. This is a sensor threshold, not a fitness score.")
                        stat("Medium", "\(stats.mediumIntensity)", "Peak user acceleration from 3 g to below 7 g.")
                        stat("Low", "\(stats.lowIntensity)", "Peak user acceleration below 3 g.")
                    }
                    NavigationLink("Explore source events") { ShotList(sessions: period.sessions(from: store.sessions)) }
                }
            }.padding(20)
        }.navigationTitle("Statistics")
    }
    private func stat(_ label: String, _ value: String, _ explanation: String) -> some View {
        DisclosureGroup { Text(explanation).font(.subheadline).foregroundStyle(.secondary) } label: {
            ShuttlStatRow(label: label, value: value)
        }
    }
}

struct RecordsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ProfileStore.self) private var profile
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if store.records().isEmpty {
                    ShuttlEmptyState(title: "Your first personal best awaits", message: "Records appear after a saved session provides the necessary measurements.", systemImage: "trophy")
                }
                ForEach(store.records()) { record in
                    NavigationLink { RecordDetail(record: record) } label: {
                        ShuttlCard(title: record.kind.displayName, subtitle: record.achievedAt.formatted(date: .abbreviated, time: .shortened)) {
                            Label(recordText(record.value, unit: record.unit, speedUnit: profile.speedUnit), systemImage: "trophy")
                                .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(20)
        }.navigationTitle("Records")
    }
}
private func recordText(_ value: Double, unit: String, speedUnit: String) -> String {
    if unit == "km/h" { return SpeedDisplay.text(value, unit: speedUnit) }
    if unit == "seconds" { return ShuttlFormat.duration(value) }
    return "\(ShuttlFormat.number(value, digits: value.rounded() == value ? 0 : 1)) \(unit)"
}
private struct RecordDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(ProfileStore.self) private var profile
    let record: PersonalRecord
    var body: some View {
        List {
            Section("Personal best") {
                Text(recordText(record.value, unit: record.unit, speedUnit: profile.speedUnit)).font(.largeTitle.monospacedDigit())
                Text(record.achievedAt.formatted(date: .long, time: .shortened))
                if let previous = record.previousValue {
                    LabeledContent("Previous best", value: recordText(previous, unit: record.unit, speedUnit: profile.speedUnit))
                    LabeledContent("Improvement", value: recordText(record.value - previous, unit: record.unit, speedUnit: profile.speedUnit))
                }
            }
            Section("Progression") {
                Chart(record.progression, id: \.self) { point in
                    LineMark(x: .value("Date", point.date), y: .value(record.unit, record.unit == "km/h" ? SpeedDisplay.value(point.value, unit: profile.speedUnit) : point.value))
                        .interpolationMethod(.stepEnd)
                    PointMark(x: .value("Date", point.date), y: .value(record.unit, record.unit == "km/h" ? SpeedDisplay.value(point.value, unit: profile.speedUnit) : point.value))
                }.frame(height: 180)
                ForEach(record.progression, id: \.self) { point in
                    LabeledContent(point.date.formatted(date: .abbreviated, time: .shortened),
                                   value: recordText(point.value, unit: record.unit, speedUnit: profile.speedUnit))
                }
            }
            if let session = store.sessions.first(where: { $0.id == record.sessionID }) {
                Section("Source") {
                    if let shot = session.shots.first(where: { $0.id == record.shotID }) {
                        NavigationLink("View record stroke") { ShotDetailView(session: session, shot: shot) }
                    }
                    NavigationLink("View source session") {
                        ScrollView { VStack(spacing: 20) { AnalysisContent(sessions: [session], summary: store.analysis(forSession: session.id)) }.padding(20) }.navigationTitle("Session")
                    }
                }
            }
            Section { Text("Records are calculated from saved sessions. Speed records are wrist-motion estimates. Inferred rallies count your strokes only.").font(.caption) }
        }.navigationTitle(record.kind.displayName).navigationBarTitleDisplayMode(.inline)
    }
}
