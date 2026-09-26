import SwiftUI
import ShuttlXCore

struct WatchRootView: View {
    @Environment(WatchSessionController.self) private var controller
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var confirmEnd = false
    @State private var page = 0
    private var isSessionVisible: Bool { [.running, .paused, .saving].contains(controller.phase) }
    var body: some View {
        NavigationStack {
            Group {
                if isSessionVisible {
                    TabView(selection: $page) {
                        liveMetrics.tag(0)
                        sessionControls.tag(1)
                    }.tabViewStyle(.verticalPage)
                } else {
                    readyScreen
                }
            }
            .navigationTitle("ShuttlX")
            .toolbar {
                if isSessionVisible && !dimmed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { page = page == 0 ? 1 : 0 } label: { Image(systemName: page == 0 ? "slider.horizontal.3" : "waveform.path") }
                            .accessibilityLabel(page == 0 ? "Session controls" : "Live metrics")
                    }
                }
            }
            .confirmationDialog("Save and end this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End and save") { controller.end() }
                Button("Keep session", role: .cancel) {}
            }
            .onChange(of: controller.phase) { _, phase in if phase == .running { page = 0 } }
        }.tint(Color("AccentColor"))
    }
    private var liveMetrics: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: controller.phase == .paused ? "pause.circle.fill" : "waveform")
                    Text(controller.phase == .paused ? "PAUSED" : (controller.phase == .saving ? "SAVING" : "LIVE SESSION"))
                }.font(.caption2.bold()).foregroundStyle(controller.phase == .paused ? Color.orange : Color("AccentColor"))
                metric(controller.layout.primary, prominent: true)
                Divider().overlay(Color.white.opacity(0.12))
                HStack(alignment: .top, spacing: 10) {
                    metric(controller.layout.secondary)
                    if let third = controller.layout.tertiary { metric(third) }
                }
                if let error = controller.lastError { Text(error).font(.caption2).foregroundStyle(.orange) }
                if !dimmed {
                    Button(controller.phase == .paused ? "Resume" : "Pause",
                           systemImage: controller.phase == .paused ? "play.fill" : "pause.fill") {
                        if controller.phase == .paused { controller.resume() } else { controller.pause() }
                    }.disabled(controller.isBusy).buttonStyle(.bordered)
                }
            }.padding(.horizontal, 5)
        }
    }
    private var sessionControls: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Session controls").font(.headline)
                Text(WatchSessionController.timeString(controller.elapsed))
                    .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("\(controller.shotCount) detected shots").font(.caption).foregroundStyle(.secondary)
                Button(controller.phase == .paused ? "Resume session" : "Pause session",
                       systemImage: controller.phase == .paused ? "play.fill" : "pause.fill") {
                    if controller.phase == .paused { controller.resume() } else { controller.pause() }
                }.buttonStyle(.borderedProminent).disabled(controller.isBusy)
                Button("End and save", systemImage: "stop.fill", role: .destructive) { confirmEnd = true }
                    .buttonStyle(.bordered).disabled(controller.isBusy)
                Text(controller.web.isPaired ? "Saved on Watch before it syncs to the website." : "Saved on Watch before it syncs to iPhone.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var readyScreen: some View {
        ScrollView {
            VStack(spacing: 14) {
                if controller.phase == .loading || controller.phase == .starting {
                    ProgressView(controller.phase == .loading ? "Opening saved session" : "Starting capture")
                        .padding(.vertical, 24)
                } else {
                    Image(systemName: controller.phase == .finished ? "checkmark.circle" : "figure.badminton")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(Color("AccentColor"))
                        .padding(.top, 4).accessibilityHidden(true)
                    Text(controller.phase == .finished ? "Session saved" : "Ready to play?")
                        .font(.title3.bold())
                    if controller.phase == .finished {
                        Text("\(controller.shotCount) shots · \(WatchSessionController.timeString(controller.elapsed))")
                            .font(.caption).monospacedDigit()
                    } else {
                        Text("Watch on your racket wrist.\nFocus on your game.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Start session", systemImage: "play.fill") { controller.start() }
                        .buttonStyle(.borderedProminent).disabled(controller.isBusy)
                }
                if let error = controller.lastError { Text(error).font(.caption2).foregroundStyle(.orange) }
                NavigationLink("Display layout", systemImage: "rectangle.3.group") { WatchLayoutView() }
                NavigationLink("Website sync", systemImage: "network") { WatchWebsiteView() }
                NavigationLink("Dataset capture", systemImage: "waveform") { DatasetCaptureView() }.disabled(!controller.canCollectDataset)
                Text(controller.web.isPaired ? controller.web.status : controller.transfer.syncState).font(.caption2).foregroundStyle(.secondary)
                if controller.web.isPaired || controller.transfer.pendingTransferCount > 0 || controller.transfer.lastError != nil {
                    Button("Retry sync") { controller.retrySync() }.font(.caption)
                }
            }
        }
    }
    private func metric(_ metric: WatchMetric, prominent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(controller.metricValue(metric))
                .font(prominent ? .system(.largeTitle, design: .rounded, weight: .bold) : .system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit().minimumScaleFactor(0.7).lineLimit(2)
                .foregroundStyle(prominent ? Color("AccentColor") : .primary)
            Text(metric.displayName).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}

private struct WatchLayoutView: View {
    @Environment(WatchSessionController.self) private var controller
    var body: some View {
        List(WatchPreset.allCases.filter { $0 != .custom }) { preset in
            Button { controller.applyPreset(preset) } label: {
                HStack {
                    Text(preset.displayName)
                    if controller.layout.preset == preset { Image(systemName: "checkmark") }
                }
            }
        }.navigationTitle("Layout")
    }
}

private struct DatasetCaptureView: View {
    @Environment(WatchSessionController.self) private var controller
    @State private var label = ShotType.smash.rawValue
    private let negatives = ["Walking", "Picking up shuttle", "Resting", "Adjusting racket"]
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let countdown = controller.datasetCountdown {
                    Text("\(countdown)").font(.largeTitle.monospacedDigit())
                    Button("Cancel") { controller.cancelDatasetCountdown() }
                } else if controller.datasetRecording {
                    ProgressView("Recording for 5 seconds")
                    Text("Perform the labelled activity.").font(.caption)
                } else {
                    Picker("Activity", selection: $label) {
                        ForEach(ShotType.allCases.filter { $0 != .unknown }) { Text($0.displayName).tag($0.rawValue) }
                        ForEach(negatives, id: \.self) { Text($0).tag($0) }
                    }
                    Text("One stroke per recording. After the countdown, perform your chosen stroke once and hold still. For negative activities, keep moving naturally.")
                        .font(.caption2)
                    Button("Record after countdown") {
                        controller.collectDataset(label: label, negativeActivity: negatives.contains(label) ? label : nil)
                    }.disabled(!controller.canCollectDataset)
                }
                if let message = controller.datasetMessage { Text(message).font(.caption2) }
            }
        }.navigationTitle("Dataset capture")
    }
}
