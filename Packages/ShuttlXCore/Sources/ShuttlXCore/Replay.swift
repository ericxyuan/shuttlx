import Foundation

public struct MotionLabel: Codable, Sendable, Hashable {
    public var startTime: Double
    public var endTime: Double
    /// Nil marks a negative activity, e.g. walking or picking up a shuttle.
    public var shotType: ShotType?
    public var note: String
    public init(startTime: Double, endTime: Double, shotType: ShotType?, note: String = "") {
        self.startTime = startTime; self.endTime = endTime; self.shotType = shotType; self.note = note
    }
}
public struct MotionRecording: Codable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var isSynthetic: Bool
    public var samples: [MotionSample]
    public var labels: [MotionLabel]
    public init(name: String, isSynthetic: Bool = false, samples: [MotionSample], labels: [MotionLabel] = []) {
        schemaVersion = 1; self.name = name; self.isSynthetic = isSynthetic; self.samples = samples; self.labels = labels
    }
    public static func decode(_ data: Data) throws -> MotionRecording {
        let decoder = JSONDecoder()
        if let recording = try? decoder.decode(MotionRecording.self, from: data) {
            guard recording.schemaVersion == 1 else { throw RecordingError.unsupportedSchema }
            try recording.validate()
            return recording
        }
        if let dataset = try? decoder.decode(WatchDataset.self, from: data) {
            let kind = dataset.negativeActivity == nil ? ShotType(rawValue: dataset.label) : nil
            guard dataset.negativeActivity != nil || (kind != nil && kind != .unknown) else {
                throw RecordingError.invalid("A positive Watch recording needs a known stroke label.")
            }
            let label = MotionLabel(startTime: dataset.samples.first?.timestamp ?? 0,
                                    endTime: dataset.samples.last?.timestamp ?? 0,
                                    shotType: kind, note: dataset.negativeActivity ?? "One user-labelled stroke")
            let recording = MotionRecording(name: "Watch · \(dataset.label)", samples: dataset.samples, labels: [label])
            try recording.validate()
            return recording
        }
        let recording = MotionRecording(name: "Imported motion", samples: try decoder.decode([MotionSample].self, from: data))
        try recording.validate()
        return recording
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw RecordingError.unsupportedSchema }
        guard !samples.isEmpty, samples.count <= 1_000_000 else {
            throw RecordingError.invalid("A recording needs between 1 and 1,000,000 samples.")
        }
        var previous: Double?
        for sample in samples {
            guard sample.isValid, sample.acceleration.magnitude.isFinite, sample.rotation.magnitude.isFinite,
                  previous.map({ sample.timestamp > $0 }) ?? true else {
                throw RecordingError.invalid("Samples must be finite and strictly ordered by timestamp.")
            }
            previous = sample.timestamp
        }
        for label in labels {
            guard label.startTime.isFinite, label.endTime.isFinite,
                  label.startTime >= samples[0].timestamp, label.endTime <= samples[samples.count - 1].timestamp,
                  label.startTime <= label.endTime, label.shotType != .unknown else {
                throw RecordingError.invalid("Labels must have valid intervals inside the recording and known positive stroke types.")
            }
        }
    }
    private struct WatchDataset: Decodable {
        let id: UUID
        let label: String
        let negativeActivity: String?
        let samples: [MotionSample]
        let source: String
    }
    public enum RecordingError: LocalizedError {
        case unsupportedSchema, invalid(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema: "This recording schema is not supported."
            case .invalid(let reason): reason
            }
        }
    }
}
public struct ReplayEvaluation: Codable, Sendable {
    public var expectedShots: Int
    public var detectedShots: Int
    public var matchedShots: Int
    public var missedShots: Int
    public var unmatchedDetections: Int
    public var correctTypes: Int
    public var unknownTypes: Int
    /// Unknown types are not counted as correct known labels. No accuracy claim without independent ground truth.
    public static func evaluate(events: [ShotEvent], labels: [MotionLabel]) -> ReplayEvaluation {
        let positive = labels.filter { $0.shotType != nil && $0.endTime >= $0.startTime }
        var unused = Set(events.indices), matched = 0, correct = 0, unknown = 0
        for label in positive.sorted(by: { $0.startTime < $1.startTime }) {
            let candidates = unused.filter { events[$0].timestamp >= label.startTime && events[$0].timestamp <= label.endTime }
            let midpoint = (label.startTime + label.endTime) / 2
            guard let index = candidates.min(by: { abs(events[$0].timestamp - midpoint) < abs(events[$1].timestamp - midpoint) }) else { continue }
            unused.remove(index); matched += 1
            if events[index].type == .unknown { unknown += 1 }
            else if events[index].type == label.shotType { correct += 1 }
        }
        return ReplayEvaluation(expectedShots: positive.count, detectedShots: events.count, matchedShots: matched,
            missedShots: positive.count - matched, unmatchedDetections: unused.count, correctTypes: correct, unknownTypes: unknown)
    }
}

public struct SessionValidationError: Error, Sendable, CustomStringConvertible {
    public let problems: [String]
    public var description: String { problems.joined(separator: "; ") }
}
public enum SessionValidator {
    /// Validate at trust boundaries before persistence. Analytics also deduplicates defensively.
    public static func validate(_ session: Session) throws {
        let problems = issues(in: session)
        if !problems.isEmpty { throw SessionValidationError(problems: problems) }
    }
    public static func issues(in session: Session) -> [String] {
        var issues: [String] = []
        if !session.startedAt.timeIntervalSince1970.isFinite { issues.append("Invalid start date") }
        if let end = session.endedAt, !end.timeIntervalSince1970.isFinite || end < session.startedAt { issues.append("Invalid end date") }
        if !session.activeDuration.isFinite || session.activeDuration < 0 { issues.append("Invalid active duration") }
        if let rate = session.sampleRateHz, !rate.isFinite || rate <= 0 { issues.append("Invalid measured rate") }
        if Set(session.shots.map(\.id)).count != session.shots.count { issues.append("Duplicate shot IDs") }
        for shot in session.shots {
            if !shot.timestamp.isFinite || shot.timestamp < 0 || !shot.duration.isFinite || shot.duration < 0
                || !shot.peakAcceleration.isFinite || shot.peakAcceleration < 0 || !shot.peakRotation.isFinite || shot.peakRotation < 0 {
                issues.append("Invalid shot measurement: \(shot.id)")
            }
            if [shot.confidence, shot.handConfidence, shot.positionConfidence].contains(where: { !$0.isFinite || !(0...1).contains($0) }) {
                issues.append("Invalid confidence: \(shot.id)")
            }
            if let speed = shot.estimatedSwingSpeed, !speed.isFinite || speed <= 0 { issues.append("Invalid estimated speed: \(shot.id)") }
            var last: Double?
            for sample in shot.samples {
                if !sample.isValid || (last.map { sample.timestamp <= $0 } ?? false) { issues.append("Invalid or unordered trace: \(shot.id)"); break }
                last = sample.timestamp
            }
        }
        return issues
    }
}
