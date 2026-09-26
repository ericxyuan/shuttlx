import Foundation
import CoreMotion
import ShuttlXCore

struct CaptureSnapshot: Sendable {
    let session: Session
    let settings: TrackingSettings
    let isRunning: Bool
    let lastSampleOffset: Double?
    let error: String?
}

struct DatasetTrace: Codable, Sendable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let label: String
    let negativeActivity: String?
    let requestedSampleRateHz: Double
    let measuredSampleRateHz: Double?
    let samples: [MotionSample]
    let source: String
}

private struct SessionCheckpoint: Codable {
    var session: Session
    var settings: TrackingSettings
}

enum WatchCaptureError: LocalizedError {
    case unavailable, missingSession, alreadyRecording, interrupted
    var errorDescription: String? {
        switch self {
        case .unavailable: "Motion sensors are unavailable. Try on a physical Apple Watch."
        case .missingSession: "There is no recoverable session."
        case .alreadyRecording: "Finish the active session before recording a dataset."
        case .interrupted: "Motion capture was interrupted. The saved session can be resumed."
        }
    }
}

/// The unchecked conformance is limited to this queue-confined adapter for CMMotionManager.
/// Every mutable property (including the detector) is accessed only on workQueue.
final class WatchCaptureWorker: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "com.shuttlx.motion", qos: .userInitiated)
    private let callbackQueue: OperationQueue
    private let motion = CMMotionManager()
    private let root: URL
    private var current: Session?
    private var settings = TrackingSettings()
    private var pipeline = MotionPipeline()
    private var segmentStart: Double?
    private var wallOffset = 0.0
    private var intervalTotal = 0.0
    private var intervalCount = 0
    private var previousTimestamp: Double?
    private var lastSampleOffset: Double?
    private var lastPublication = 0.0
    private var lastCheckpoint = 0.0
    private var quietSince: Double?
    private var generation = UUID()
    private var lastCallbackUptime = 0.0
    private var datasetSamples: [MotionSample]?
    private var datasetStart: Double?
    private var datasetCompletion: (@Sendable (Result<DatasetTrace, Error>) -> Void)?
    private var datasetLabel = ""
    private var datasetNegative: String?
    private var eventHandler: (@Sendable (CaptureSnapshot) -> Void)?
    var isMotionAvailable: Bool { motion.isDeviceMotionAvailable }

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuttlX/Capture", isDirectory: true)
        callbackQueue = OperationQueue()
        callbackQueue.name = "ShuttlX motion callbacks"
        callbackQueue.maxConcurrentOperationCount = 1
        callbackQueue.qualityOfService = .userInitiated
        callbackQueue.underlyingQueue = workQueue
    }

    func setEventHandler(_ handler: @escaping @Sendable (CaptureSnapshot) -> Void) {
        workQueue.async { self.eventHandler = handler }
    }

    func recover() async throws -> CaptureSnapshot? {
        try await perform {
            try self.prepare()
            let url = self.root.appendingPathComponent("active.checkpoint")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let checkpoint = try JSONDecoder().decode(SessionCheckpoint.self, from: Data(contentsOf: url))
            self.current = checkpoint.session; self.settings = checkpoint.settings
            self.pipeline = MotionPipeline(settings: self.settings)
            return self.snapshot(error: "Interrupted session recovered. Resume or End to save it.")
        }
    }

    func begin(settings: TrackingSettings, resume: Bool) async throws -> CaptureSnapshot {
        try await perform {
            guard self.motion.isDeviceMotionAvailable else { throw WatchCaptureError.unavailable }
            guard self.segmentStart == nil, self.datasetCompletion == nil else { throw WatchCaptureError.alreadyRecording }
            if resume {
                guard self.current != nil else { throw WatchCaptureError.missingSession }
            } else {
                self.current = Session(startedAt: .now)
                self.settings = settings.validated()
                self.intervalTotal = 0; self.intervalCount = 0
            }
            self.pipeline = MotionPipeline(settings: self.settings)
            self.previousTimestamp = nil; self.quietSince = nil
            let uptime = ProcessInfo.processInfo.systemUptime
            self.wallOffset = Date.now.timeIntervalSince(self.current!.startedAt) - uptime
            self.segmentStart = uptime
            self.lastCheckpoint = uptime
            try self.checkpoint()
            self.startMotion()
            return self.snapshot()
        }
    }

    func pause() async throws -> CaptureSnapshot {
        try await perform {
            self.stopSegment()
            guard self.current != nil else { throw WatchCaptureError.missingSession }
            // A partial swing crossing pause must never become a shot on resume.
            self.pipeline.reset()
            try self.checkpoint()
            return self.snapshot()
        }
    }

    func finish() async throws -> Session {
        try await perform {
            self.stopSegment()
            self.pipeline.reset()
            guard var value = self.current else { throw WatchCaptureError.missingSession }
            value.endedAt = .now
            // Archive first. If this fails the checkpoint remains recoverable.
            try self.prepare()
            try self.write(value, to: self.root.appendingPathComponent("Sessions/\(value.id.uuidString).json"))
            let checkpoint = self.root.appendingPathComponent("active.checkpoint")
            if FileManager.default.fileExists(atPath: checkpoint.path) { try FileManager.default.removeItem(at: checkpoint) }
            self.current = nil
            return value
        }
    }

    func savedSessions() async throws -> [Session] {
        try await perform {
            try self.prepare()
            return try FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent("Sessions"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(Session.self, from: Data(contentsOf: $0)) }
        }
    }

    /// The paired phone has durably saved this transfer. Release the extra recovery copy.
    func removeAcknowledgedArchive(id: UUID) async throws {
        try await perform {
            for directory in ["Sessions", "Datasets"] {
                let url = self.root.appendingPathComponent(directory).appendingPathComponent(id.uuidString).appendingPathExtension("json")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    func recordDataset(label: String, negativeActivity: String?, requestedRate: Double) async throws -> DatasetTrace {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                guard self.current == nil, self.datasetCompletion == nil else { continuation.resume(throwing: WatchCaptureError.alreadyRecording); return }
                guard self.motion.isDeviceMotionAvailable else { continuation.resume(throwing: WatchCaptureError.unavailable); return }
                self.datasetLabel = label; self.datasetNegative = negativeActivity
                self.datasetSamples = []; self.datasetStart = nil
                self.settings.sampleRateHz = requestedRate
                self.datasetCompletion = { result in continuation.resume(with: result) }
                self.startMotion()
                let token = self.generation
                self.workQueue.asyncAfter(deadline: .now() + 7) {
                    guard self.generation == token, self.datasetCompletion != nil else { return }
                    self.completeDataset()
                }
            }
        }
    }

    func savedDatasets() async throws -> [DatasetTrace] {
        try await perform {
            try self.prepare()
            return try FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent("Datasets"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(DatasetTrace.self, from: Data(contentsOf: $0)) }
        }
    }

    private func startMotion() {
        generation = UUID()
        let token = generation
        lastCallbackUptime = ProcessInfo.processInfo.systemUptime
        motion.deviceMotionUpdateInterval = 1 / settings.validated().sampleRateHz
        motion.startDeviceMotionUpdates(to: callbackQueue) { [weak self] data, error in
            guard let self, token == self.generation else { return }
            if let error { self.fail(error); return }
            guard let data else { return }
            self.lastCallbackUptime = ProcessInfo.processInfo.systemUptime
            // CMDeviceMotion.timestamp is the sensor clock; handler delivery time is not the sample time.
            self.consume(timestamp: data.timestamp,
                         acceleration: Vector3(x: data.userAcceleration.x, y: data.userAcceleration.y, z: data.userAcceleration.z),
                         rotation: Vector3(x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z))
        }
        checkSensorLiveness(token: token)
    }

    private func checkSensorLiveness(token: UUID) {
        workQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == token else { return }
            guard self.segmentStart != nil || self.datasetCompletion != nil else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastCallbackUptime >= 5 {
                self.fail(WatchCaptureError.interrupted)
            } else {
                self.checkSensorLiveness(token: token)
            }
        }
    }

    private func consume(timestamp: Double, acceleration: Vector3, rotation: Vector3) {
        if datasetCompletion != nil {
            if datasetStart == nil { datasetStart = timestamp }
            let offset = timestamp - (datasetStart ?? timestamp)
            let sample = MotionSample(timestamp: offset, acceleration: acceleration, rotation: rotation)
            if sample.isValid, datasetSamples?.count ?? 0 < 2_000 { datasetSamples?.append(sample) }
            if offset >= 5 { completeDataset() }
            return
        }
        guard let segmentStart, current != nil else { return }
        let sample = MotionSample(timestamp: max(0, timestamp + wallOffset), acceleration: acceleration, rotation: rotation)
        guard sample.isValid else { return }
        if let previousTimestamp {
            let delta = timestamp - previousTimestamp
            if delta <= 0 { return }
            if delta < 0.5 { intervalTotal += delta; intervalCount += 1 }
            else { pipeline.reset() } // Gaps cannot be stitched into a swing.
        }
        previousTimestamp = timestamp
        lastSampleOffset = sample.timestamp
        current?.sampleRateHz = intervalTotal > 0 ? Double(intervalCount) / intervalTotal : nil
        let event = pipeline.ingest(sample)
        if let event { current?.shots.append(event) }
        let now = ProcessInfo.processInfo.systemUptime
        if settings.autoPause {
            if acceleration.magnitude < 0.08 && rotation.magnitude < 0.35 {
                if quietSince == nil { quietSince = timestamp }
                if timestamp - (quietSince ?? timestamp) >= 30 {
                    stopSegment(); pipeline.reset()
                    do { try checkpoint(); eventHandler?(snapshot(error: "Auto-paused after 30 seconds of stillness. Tap Resume when ready.")) }
                    catch { fail(error) }
                    return
                }
            } else { quietSince = nil }
        }
        if event != nil || now - lastCheckpoint >= 5 {
            do { try checkpoint(); lastCheckpoint = now } catch { fail(error); return }
        }
        if event != nil || now - lastPublication >= 0.5 {
            lastPublication = now
            var value = current!
            value.activeDuration += max(0, now - segmentStart)
            eventHandler?(CaptureSnapshot(session: value, settings: settings, isRunning: true, lastSampleOffset: lastSampleOffset, error: nil))
        }
    }

    private func stopSegment() {
        motion.stopDeviceMotionUpdates(); generation = UUID()
        if let segmentStart { current?.activeDuration += max(0, ProcessInfo.processInfo.systemUptime - segmentStart) }
        segmentStart = nil; previousTimestamp = nil
    }
    private func snapshot(error: String? = nil) -> CaptureSnapshot {
        var value = current ?? Session()
        if let segmentStart { value.activeDuration += max(0, ProcessInfo.processInfo.systemUptime - segmentStart) }
        return CaptureSnapshot(session: value, settings: settings, isRunning: segmentStart != nil, lastSampleOffset: lastSampleOffset, error: error)
    }
    private func fail(_ error: Error) {
        if let completion = datasetCompletion {
            motion.stopDeviceMotionUpdates(); generation = UUID(); datasetCompletion = nil; datasetSamples = nil
            completion(.failure(error)); return
        }
        stopSegment(); pipeline.reset()
        try? checkpoint() // Earlier checkpoint survives a disk failure.
        eventHandler?(snapshot(error: "Tracking paused: \(error.localizedDescription)"))
    }
    private func completeDataset() {
        guard let completion = datasetCompletion else { return }
        motion.stopDeviceMotionUpdates(); generation = UUID(); datasetCompletion = nil
        let samples = datasetSamples ?? []; datasetSamples = nil
        guard samples.count > 1, let first = samples.first, let last = samples.last, last.timestamp > first.timestamp else { completion(.failure(WatchCaptureError.interrupted)); return }
        let value = DatasetTrace(id: UUID(), recordedAt: .now, label: datasetLabel, negativeActivity: datasetNegative,
                                 requestedSampleRateHz: settings.sampleRateHz,
                                 measuredSampleRateHz: Double(samples.count - 1) / (last.timestamp - first.timestamp),
                                 samples: samples, source: "Apple Watch CMDeviceMotion · user-labelled")
        do { try prepare(); try write(value, to: root.appendingPathComponent("Datasets/\(value.id.uuidString).json")); completion(.success(value)) }
        catch { completion(.failure(error)) }
    }
    private func prepare() throws {
        for path in ["", "Sessions", "Datasets"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func checkpoint() throws {
        guard current != nil else { return }
        try prepare()
        try write(SessionCheckpoint(session: snapshot().session, settings: settings), to: root.appendingPathComponent("active.checkpoint"))
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
}
