import SwiftUI
import UniformTypeIdentifiers
import ShuttlXCore

struct DeveloperToolsView: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var processing = false
    @State private var report: String?
    @State private var error: String?
    @State private var datasets: [URL] = []
    @State private var exportURL: URL?

    var body: some View {
        Form {
            Section {
                Text("Replay runs the same detector as Watch capture. Results stay in this tool and never populate personal statistics or records.")
                Button("Import motion recording", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(processing)
                if processing { ProgressView("Processing recording") }
                if let report { Text(report).font(.body.monospaced()).textSelection(.enabled) }
            } header: { Text("Sensor replay") } footer: {
                Text("Accepts a MotionRecording JSON object or an array of MotionSample objects, with increasing timestamps. Labels are optional. Synthetic traces test code behaviour, not real-world accuracy.")
            }
            Section("Labelled Watch datasets") {
                Text("On Watch, open Dataset Capture, choose the activity and follow the countdown. Keep individual strokes and negative activities clearly labelled.")
                Button("Refresh received recordings") { Task { await refreshDatasets() } }
                ForEach(datasets, id: \.lastPathComponent) { url in
                    ShareLink(url.deletingPathExtension().lastPathComponent, item: url)
                }
                if datasets.isEmpty { Text("No dataset has arrived yet.").foregroundStyle(.secondary) }
            }
            Section("Retained sensor windows") {
                Button("Prepare raw-window export") {
                    do { exportURL = try store.exportRawData() } catch { self.error = error.localizedDescription }
                }
                if let exportURL { ShareLink("Share raw windows", item: exportURL) }
                Text("Windows are grouped by session and shot. Gaps between windows were not recorded; this export is not a continuous replay trace.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section("Could not complete") { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Developer tools")
        .task { await refreshDatasets() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url): replay(url)
            }
        }
    }

    private func refreshDatasets() async {
        do { datasets = try await store.transfer.receivedDatasetFiles() }
        catch { self.error = error.localizedDescription }
    }

    private func replay(_ url: URL) {
        processing = true; error = nil
        let settings = store.settings
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw ReplayError.tooLarge }
                    let recording = try MotionRecording.decode(Data(contentsOf: url))
                    guard !recording.samples.isEmpty, recording.samples.count <= 1_000_000,
                          recording.samples.allSatisfy(\.isValid),
                          zip(recording.samples, recording.samples.dropFirst()).allSatisfy({ pair in pair.0.timestamp < pair.1.timestamp })
                    else { throw ReplayError.invalidTrace }
                    let events = MotionReplay.process(samples: recording.samples, settings: settings)
                    let evaluation = ReplayEvaluation.evaluate(events: events, labels: recording.labels)
                    return """
                    \(recording.name)
                    \(recording.isSynthetic ? "Synthetic recording" : "Imported recording")
                    Samples: \(recording.samples.count)
                    Detections: \(events.count)
                    Labelled strokes: \(evaluation.expectedShots)
                    Matched: \(evaluation.matchedShots)
                    Missed: \(evaluation.missedShots)
                    Unmatched detections: \(evaluation.unmatchedDetections)
                    Correct known types: \(evaluation.correctTypes)
                    Unknown types: \(evaluation.unknownTypes)
                    """
                }.value
                report = output
            } catch { self.error = error.localizedDescription }
            processing = false
        }
    }
    private enum ReplayError: LocalizedError {
        case tooLarge, invalidTrace
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose a recording smaller than 32 MB."
            case .invalidTrace: "The trace must contain finite samples with strictly increasing timestamps."
            }
        }
    }
}
