import SwiftUI
import HealthKit
import WatchKit
import WidgetKit
import Observation
import ShuttlXCore

@MainActor @Observable final class WatchSessionController: NSObject {
    enum Phase: String { case loading, idle, starting, running, paused, saving, finished, unavailable }
    private(set) var phase: Phase = .loading
    private(set) var shots: [ShotEvent] = []
    private(set) var elapsed = 0.0
    private(set) var lastError: String?
    private(set) var measuredSampleRateHz: Double?
    private(set) var datasetCountdown: Int?
    private(set) var datasetRecording = false
    private(set) var datasetMessage: String?
    private(set) var settings: TrackingSettings
    var layout: WatchLayout
    let transfer: SessionTransferService
    let web = WatchWebSync()
    @ObservationIgnored private let worker = WatchCaptureWorker()
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var workout: HKWorkoutSession?
    @ObservationIgnored private var workoutBuilder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var activeSettings: TrackingSettings
    @ObservationIgnored private var lastWidgetWrite = Date.distantPast
    @ObservationIgnored private var initialization: Task<Void, Never>?
    @ObservationIgnored private var datasetTask: Task<Void, Never>?

    init(settings: TrackingSettings = .init(), layout: WatchLayout = .init()) {
        let connection = SessionTransferService(settings: settings, layout: layout)
        transfer = connection
        self.settings = connection.settings; activeSettings = connection.settings; self.layout = connection.layout
        super.init()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        worker.setEventHandler { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        transfer.onConfigurationReceived = { [weak self] settings, layout in
            guard self?.web.isPaired != true else { return }
            self?.settings = settings; self?.layout = layout
        }
        transfer.onAcknowledged = { [weak self] id in
            guard let self else { return }
            try await self.worker.removeAcknowledgedArchive(id: id)
        }
        transfer.onWebCredentialReceived = { [weak self] baseURL, deviceID, token in
            do { try self?.web.acceptCredential(baseURL: baseURL, deviceID: deviceID, token: token); self?.retrySync() }
            catch { self?.lastError = error.localizedDescription }
        }
        transfer.activate()
        initialization = Task { [weak self] in await self?.restore() }
    }

    var shotCount: Int { shots.count }
    var currentRally: Int {
        guard let last = shots.last, let sessionStart,
              Date.now.timeIntervalSince(sessionStart) - last.timestamp <= activeSettings.rallyGap else { return 0 }
        var count = 1; var previous = last.timestamp
        for shot in shots.dropLast().reversed() {
            if previous - shot.timestamp > activeSettings.rallyGap { break }
            count += 1; previous = shot.timestamp
        }
        return count
    }
    var lastShotName: String { shots.last?.type.displayName ?? "Waiting for a swing" }
    var lastSpeed: String { speed(shots.last?.estimatedSwingSpeed) }
    var isBusy: Bool { [.loading, .starting, .saving].contains(phase) || datasetRecording || datasetCountdown != nil }
    var canCollectDataset: Bool { [.idle, .finished, .unavailable].contains(phase) && !isBusy }

    func metricValue(_ metric: WatchMetric) -> String {
        switch metric {
        case .shotCount: return "\(shotCount)"
        case .sessionTime: return Self.timeString(elapsed)
        case .currentRally: return "\(currentRally)"
        case .lastSwingSpeed: return speed(shots.last?.estimatedSwingSpeed)
        case .maxSwingSpeed: return speed(shots.compactMap(\.estimatedSwingSpeed).max())
        case .lastShot: return lastShotName
        case .smashes: return "\(shots.filter { $0.type == .smash }.count)"
        case .averageSwingSpeed:
            let values = shots.compactMap(\.estimatedSwingSpeed)
            return speed(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
        }
    }

    func start() {
        guard [.idle, .finished, .unavailable].contains(phase), !isBusy else { return }
        phase = .starting; lastError = nil
        activeSettings = settings
        Task {
            do {
                guard worker.isMotionAvailable else { throw WatchCaptureError.unavailable }
                try await beginWorkout()
                apply(try await worker.begin(settings: activeSettings, resume: false))
                publishStatus("Tracking")
            } catch {
                await endWorkout()
                phase = worker.isMotionAvailable ? .idle : .unavailable
                lastError = error.localizedDescription
            }
        }
    }

    func pause() {
        guard phase == .running else { return }
        phase = .saving
        Task {
            do { apply(try await worker.pause()); workout?.pause(); publishStatus("Paused") }
            catch { phase = .paused; workout?.pause(); lastError = error.localizedDescription }
        }
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .starting; lastError = nil
        Task {
            do {
                if workout == nil { try await beginWorkout() } else { workout?.resume() }
                apply(try await worker.begin(settings: activeSettings, resume: true))
                publishStatus("Tracking")
            } catch { phase = .paused; workout?.pause(); lastError = error.localizedDescription }
        }
    }

    func end() {
        guard phase == .running || phase == .paused else { return }
        phase = .saving
        Task {
            do {
                let saved = try await worker.finish()
                shots = saved.shots; elapsed = saved.activeDuration; measuredSampleRateHz = saved.sampleRateHz
                phase = .finished
                writeWidget(active: false, force: true)
                await endWorkout()
                do {
                    if web.isPaired { retrySync() }
                    else { try await transfer.enqueue(saved) }
                    lastError = nil
                }
                catch { lastError = "Saved on Watch. Sync will retry: \(error.localizedDescription)" }
                publishStatus("Ready")
            } catch {
                phase = .paused; workout?.pause()
                lastError = "Could not finish saving. Your previous checkpoint is retained: \(error.localizedDescription)"
            }
        }
    }

    func applyPreset(_ preset: WatchPreset) {
        layout.apply(preset)
        do {
            try transfer.configure(settings: settings, layout: layout)
            try transfer.sendWatchLayout(layout)
        }
        catch { lastError = error.localizedDescription }
    }

    func collectDataset(label: String, negativeActivity: String?) {
        guard canCollectDataset else { return }
        datasetTask = Task {
            datasetMessage = nil
            do {
                for count in (1...3).reversed() {
                    datasetCountdown = count
                    WKInterfaceDevice.current().play(.click)
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                try await beginWorkout()
                datasetCountdown = nil; datasetRecording = true
                WKInterfaceDevice.current().play(.start)
                let trace = try await worker.recordDataset(label: label, negativeActivity: negativeActivity, requestedRate: settings.sampleRateHz)
                datasetRecording = false
                await endWorkout()
                try await transfer.enqueueDataset(JSONEncoder().encode(trace), id: trace.id)
                datasetMessage = "Saved \(trace.samples.count) samples. Export from iPhone Developer Tools after sync."
                WKInterfaceDevice.current().play(.success)
            } catch is CancellationError { datasetMessage = "Countdown cancelled." }
            catch {
                datasetMessage = "Dataset: \(error.localizedDescription)"
                await endWorkout()
            }
            datasetCountdown = nil; datasetRecording = false; datasetTask = nil
        }
    }

    func cancelDatasetCountdown() { if !datasetRecording { datasetTask?.cancel() } }
    func retrySync() {
        Task {
            do {
                let sessions = try await worker.savedSessions()
                if web.isPaired {
                    await web.synchronize(sessions, onConfiguration: { config in
                        self.settings = config.settings.validated(); self.layout = config.layout
                        try self.transfer.configure(settings: self.settings, layout: self.layout)
                    }, onAcknowledged: { id in
                        try await self.worker.removeAcknowledgedArchive(id: id)
                    })
                    return
                }
                let datasets = try await worker.savedDatasets()
                for session in sessions { try await transfer.enqueue(session) }
                for trace in datasets { try await transfer.enqueueDataset(JSONEncoder().encode(trace), id: trace.id) }
                transfer.retryPendingTransfers()
            } catch { lastError = "Retry could not be staged: \(error.localizedDescription)" }
        }
    }

    private func restore() async {
        do {
            let recovered = try await worker.recover()
            if let recovered { apply(recovered) }
            else { phase = .idle }
            retrySync()
            publishStatus(phase == .paused ? "Recovered · paused" : "Ready")
        } catch {
            phase = .unavailable
            lastError = "Saved session recovery failed: \(error.localizedDescription)"
        }
    }

    private func apply(_ snapshot: CaptureSnapshot) {
        // Queued UI updates arriving after an explicit pause/end cannot reopen the session.
        if snapshot.isRunning && [.paused, .saving, .finished].contains(phase) { return }
        let previousCount = shots.count
        shots = snapshot.session.shots; elapsed = snapshot.session.activeDuration
        activeSettings = snapshot.settings
        sessionStart = snapshot.session.startedAt; measuredSampleRateHz = snapshot.session.sampleRateHz
        phase = snapshot.isRunning ? .running : .paused
        if let error = snapshot.error { lastError = error; workout?.pause(); publishStatus("Paused") }
        if shots.count > previousCount, settings.hapticFeedback { WKInterfaceDevice.current().play(.click) }
        writeWidget(active: snapshot.isRunning, force: false)
    }

    private func beginWorkout() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WatchCaptureError.unavailable }
        try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            throw NSError(domain: "ShuttlX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow ShuttlX to save workouts in Health to keep tracking active with your wrist down."])
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .badminton
        configuration.locationType = .indoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        session.delegate = self
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        workout = session; workoutBuilder = builder
        let start = Date.now
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)
    }
    private func endWorkout() async {
        let builder = workoutBuilder
        workout?.end(); workout = nil; workoutBuilder = nil
        if let builder {
            do { try await builder.endCollection(at: .now); _ = try await builder.finishWorkout() }
            catch { lastError = "ShuttlX data is retained. Health workout save failed: \(error.localizedDescription)" }
        }
    }
    private func publishStatus(_ value: String) {
        let device = WKInterfaceDevice.current()
        do {
            try transfer.publishStatus(WatchDeviceStatus(modelName: device.name, systemVersion: device.systemVersion,
                batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                motionAvailable: worker.isMotionAvailable, requestedSampleRateHz: settings.sampleRateHz,
                measuredSampleRateHz: measuredSampleRateHz, trackingStatus: value))
        } catch { lastError = "Status update pending: \(error.localizedDescription)" }
    }
    private func writeWidget(active: Bool, force: Bool) {
        guard force || Date.now.timeIntervalSince(lastWidgetWrite) >= 15 else { return }
        lastWidgetWrite = .now
        WatchWidgetSnapshotStore.save(WatchWidgetSnapshot(sessionTime: elapsed, shotCount: shots.count,
            lastShot: shots.last?.type.displayName, lastSwingSpeed: shots.last?.estimatedSwingSpeed,
            hasSession: sessionStart != nil, isActive: active))
        WidgetCenter.shared.reloadTimelines(ofKind: "WatchAccessory")
    }
    private func speed(_ value: Double?) -> String {
        let unit = web.isPaired ? web.speedUnit : "km/h"
        return value.map { "\((unit == "mph" ? $0 / 1.609344 : $0).formatted(.number.precision(.fractionLength(0)))) \(unit)" } ?? "—"
    }
    static func timeString(_ value: Double) -> String {
        let seconds = Int(max(0, value)); return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

extension WatchSessionController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                   from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            if toState == .paused, self.phase == .running { self.pause() }
            if toState == .ended, self.phase == .running {
                self.pause(); self.lastError = "The Health workout ended. Your ShuttlX session is paused."
                self.workout = nil; self.workoutBuilder = nil
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            if self.phase == .running { self.pause() }
            self.lastError = "Workout interrupted: \(message)"
            self.workout = nil; self.workoutBuilder = nil
        }
    }
}
