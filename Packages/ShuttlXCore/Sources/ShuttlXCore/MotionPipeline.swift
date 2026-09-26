import Foundation

/// Feature units are seconds, g, rad/s, g·s and radians. Integrals use sensor timestamps.
public struct SwingFeatures: Codable, Sendable, Hashable {
    public var duration: Double
    public var peakAcceleration: Double
    public var peakRotation: Double
    public var accelerationImpulse: Double
    public var rotationImpulse: Double
    /// Signed rotation vector at the rotational peak, in rad/s.
    public var dominantAxis: Vector3
    public var sampleCount: Int
    public init(duration: Double, peakAcceleration: Double, peakRotation: Double,
                accelerationImpulse: Double, rotationImpulse: Double,
                dominantAxis: Vector3, sampleCount: Int) {
        self.duration = duration; self.peakAcceleration = peakAcceleration; self.peakRotation = peakRotation
        self.accelerationImpulse = accelerationImpulse; self.rotationImpulse = rotationImpulse
        self.dominantAxis = dominantAxis; self.sampleCount = sampleCount
    }
    public static func extract(from samples: [MotionSample]) -> SwingFeatures? {
        guard samples.count >= 3, samples.allSatisfy(\.isValid),
              let first = samples.first, let last = samples.last,
              let peak = samples.max(by: { $0.rotation.magnitude < $1.rotation.magnitude }) else { return nil }
        var accelerationIntegral = 0.0, rotationIntegral = 0.0
        for (left, right) in zip(samples, samples.dropFirst()) {
            let dt = right.timestamp - left.timestamp
            guard dt > 0 && dt <= 0.2 else { return nil }
            accelerationIntegral += (left.acceleration.magnitude + right.acceleration.magnitude) * dt / 2
            rotationIntegral += (left.rotation.magnitude + right.rotation.magnitude) * dt / 2
        }
        let peakAcceleration = samples.map { $0.acceleration.magnitude }.max() ?? 0
        // Active duration excludes the retained pre/post context.
        let active = samples.filter { $0.rotation.magnitude >= peak.rotation.magnitude * 0.2 }
        let activeDuration = (active.last?.timestamp ?? last.timestamp) - (active.first?.timestamp ?? first.timestamp)
        return SwingFeatures(duration: activeDuration, peakAcceleration: peakAcceleration,
                             peakRotation: peak.rotation.magnitude, accelerationImpulse: accelerationIntegral,
                             rotationImpulse: rotationIntegral, dominantAxis: peak.rotation, sampleCount: samples.count)
    }
}

public struct ShotClassification: Codable, Sendable, Hashable {
    public var type: ShotType
    public var confidence: Double
    public var hand: ShotHand
    public var handConfidence: Double
    public var position: ShotPosition
    public var positionConfidence: Double
    /// Populate only when a classifier has explicit contextual evidence. Wrist heuristics never assign tactics.
    public var tactical: TacticalRole
    public var estimatedSwingSpeed: Double?
    public init(type: ShotType = .unknown, confidence: Double = 0,
                hand: ShotHand = .unknown, handConfidence: Double = 0,
                position: ShotPosition = .unknown, positionConfidence: Double = 0,
                tactical: TacticalRole = .unknown, estimatedSwingSpeed: Double? = nil) {
        self.type = type; self.confidence = confidence; self.hand = hand; self.handConfidence = handConfidence
        self.position = position; self.positionConfidence = positionConfidence; self.tactical = tactical
        self.estimatedSwingSpeed = estimatedSwingSpeed
    }
    public func thresholded(at threshold: Double) -> ShotClassification {
        var result = self
        result.confidence = bounded(confidence, 0...1, fallback: 0)
        result.handConfidence = bounded(handConfidence, 0...1, fallback: 0)
        result.positionConfidence = bounded(positionConfidence, 0...1, fallback: 0)
        if result.confidence < threshold { result.type = .unknown; result.tactical = .unknown }
        if result.handConfidence < threshold { result.hand = .unknown }
        if result.positionConfidence < threshold { result.position = .unknown }
        if let speed = estimatedSwingSpeed, (!speed.isFinite || speed <= 0) { result.estimatedSwingSpeed = nil }
        return result
    }
}

public protocol ShotClassifier: Sendable {
    func classify(features: SwingFeatures, settings: TrackingSettings) -> ShotClassification
}

/// Opt-in unvalidated rules for dataset exploration. Rule scores are NOT calibrated probabilities.
/// No inference of position, tactics or shuttle speed is supported by these features.
public struct HeuristicShotClassifier: ShotClassifier {
    public init() {}
    public func classify(features: SwingFeatures, settings: TrackingSettings) -> ShotClassification {
        guard settings.enableExperimentalClassification else { return ShotClassification() }
        var result = ShotClassification()
        // Deliberately separated envelopes leave ambiguous strokes unknown. Physical validation is required.
        let transverse = hypot(features.dominantAxis.x, features.dominantAxis.y)
        if features.peakRotation >= 24 && features.peakAcceleration >= 7 && (0.08...0.26).contains(features.duration) {
            result.type = .smash; result.confidence = 0.82
        } else if (14..<24).contains(features.peakRotation) && (0.10...0.22).contains(features.duration)
                    && abs(features.dominantAxis.z) > transverse * 1.8 {
            result.type = .drive; result.confidence = 0.76
        } else if (12...22).contains(features.peakRotation) && (0.28...0.50).contains(features.duration)
                    && transverse > abs(features.dominantAxis.z) * 1.8 {
            result.type = .clear; result.confidence = 0.72
        }
        if let sign = settings.validated().handCalibrationSign,
           abs(features.dominantAxis.z) > transverse * 2, features.peakRotation >= 12 {
            result.hand = features.dominantAxis.z * sign > 0 ? .forehand : .backhand
            result.handConfidence = 0.75
        }
        return result.thresholded(at: settings.validated().confidenceThreshold)
    }
}

/// Prefer an injected learned classifier, fall back only to explicitly opted-in rules.
public struct HybridShotClassifier: ShotClassifier {
    private let learned: (any ShotClassifier)?
    private let fallback: any ShotClassifier
    public init(learned: (any ShotClassifier)? = nil, fallback: any ShotClassifier = HeuristicShotClassifier()) {
        self.learned = learned; self.fallback = fallback
    }
    public func classify(features: SwingFeatures, settings: TrackingSettings) -> ShotClassification {
        let threshold = settings.validated().confidenceThreshold
        if let result = learned?.classify(features: features, settings: settings).thresholded(at: threshold), result.type != .unknown {
            return result
        }
        return fallback.classify(features: features, settings: settings).thresholded(at: threshold)
    }
}

/// Own on one serial executor. Memory is bounded even for abnormal input rates or continuous motion.
public struct MotionPipeline: Sendable {
    public private(set) var settings: TrackingSettings
    private let classifier: any ShotClassifier
    private var ring: [MotionSample] = []
    private var pending: [MotionSample] = []
    private var triggerTime: Double?
    private var lastTimestamp: Double?
    private var refractoryUntil: Double = -.greatestFiniteMagnitude
    private var intervals: [Double] = []
    public private(set) var measuredSampleRateHz: Double?
    public private(set) var rejectedCandidates = 0
    public private(set) var discardedSamples = 0
    public var bufferedSampleCount: Int { ring.count + pending.count }

    public init(settings: TrackingSettings = .init(), classifier: (any ShotClassifier)? = nil) {
        self.settings = settings.validated(); self.classifier = classifier ?? HeuristicShotClassifier()
    }
    @discardableResult public mutating func ingest(_ sample: MotionSample) -> ShotEvent? {
        guard sample.isValid, sample.acceleration.magnitude.isFinite, sample.rotation.magnitude.isFinite else {
            discardedSamples += 1; return nil
        }
        if let lastTimestamp {
            guard sample.timestamp > lastTimestamp else { discardedSamples += 1; return nil }
            let interval = sample.timestamp - lastTimestamp
            if interval > max(0.12, 4 / settings.sampleRateHz) {
                if !pending.isEmpty { rejectedCandidates += 1 }
                pending.removeAll(keepingCapacity: true); ring.removeAll(keepingCapacity: true); triggerTime = nil
            } else {
                intervals.append(interval)
                if intervals.count > 128 { intervals.removeFirst(intervals.count - 128) }
                if intervals.count >= 8, let middle = median(intervals) { measuredSampleRateHz = 1 / middle }
            }
        }
        lastTimestamp = sample.timestamp
        ring.append(sample)
        while ring.count > 512 || (ring.count > 1 && ring[1].timestamp < sample.timestamp - settings.preWindow) { ring.removeFirst() }
        if let triggerTime {
            pending.append(sample)
            if pending.count > 1024 {
                rejectedCandidates += 1; pending.removeAll(keepingCapacity: true); self.triggerTime = nil
                refractoryUntil = sample.timestamp + settings.refractoryPeriod
                return nil
            }
            if sample.timestamp >= triggerTime + settings.postWindow {
                let event = makeEvent(from: pending)
                if event == nil { rejectedCandidates += 1 }
                pending.removeAll(keepingCapacity: true); self.triggerTime = nil
                // Refractory is measured from trigger, not the end of the retained post window.
                refractoryUntil = triggerTime + settings.refractoryPeriod
                return event
            }
            return nil
        }
        let crossesBoth = sample.acceleration.magnitude >= settings.accelerationThreshold
            && sample.rotation.magnitude >= settings.rotationThreshold
        guard crossesBoth, sample.timestamp >= refractoryUntil,
              let first = ring.first, sample.timestamp - first.timestamp >= settings.preWindow * 0.8 else { return nil }
        pending = ring; triggerTime = sample.timestamp
        return nil
    }
    /// Incomplete windows are deliberately discarded at end/pause, preventing a last-sample spike becoming a shot.
    public mutating func finish() -> ShotEvent? {
        if !pending.isEmpty { rejectedCandidates += 1 }
        pending.removeAll(keepingCapacity: true); triggerTime = nil
        return nil
    }
    public mutating func reset() {
        ring.removeAll(keepingCapacity: true); pending.removeAll(keepingCapacity: true)
        triggerTime = nil; lastTimestamp = nil; refractoryUntil = -.greatestFiniteMagnitude
        intervals.removeAll(keepingCapacity: true); measuredSampleRateHz = nil
        rejectedCandidates = 0; discardedSamples = 0
    }
    private func makeEvent(from samples: [MotionSample]) -> ShotEvent? {
        guard let features = SwingFeatures.extract(from: samples), features.sampleCount >= 8,
              (0.04...0.65).contains(features.duration),
              features.accelerationImpulse >= settings.accelerationThreshold * 0.03,
              features.rotationImpulse >= settings.rotationThreshold * 0.03,
              let peak = samples.max(by: { $0.rotation.magnitude < $1.rotation.magnitude }) else { return nil }
        let coincident = samples.filter { $0.acceleration.magnitude >= settings.accelerationThreshold && $0.rotation.magnitude >= settings.rotationThreshold }
        guard coincident.count >= 3, let first = coincident.first, let last = coincident.last,
              last.timestamp - first.timestamp >= 0.025 else { return nil }
        // A complete pulse must rise from and settle toward a quieter baseline. Reject sustained shaking/rotation.
        let edgeCount = max(2, samples.count / 10)
        let before = mean(samples.prefix(edgeCount).map { $0.rotation.magnitude }) ?? .infinity
        let after = mean(samples.suffix(edgeCount).map { $0.rotation.magnitude }) ?? .infinity
        guard before < features.peakRotation * 0.5, after < features.peakRotation * 0.5 else { return nil }
        let result = classifier.classify(features: features, settings: settings).thresholded(at: settings.confidenceThreshold)
        let calibratedSpeed = settings.calibratedLeverArmMeters.map { features.peakRotation * $0 * 3.6 }
        return ShotEvent(timestamp: peak.timestamp, type: result.type, hand: result.hand, position: result.position,
                         tactical: result.tactical, confidence: result.confidence, handConfidence: result.handConfidence,
                         positionConfidence: result.positionConfidence, estimatedSwingSpeed: calibratedSpeed,
                         peakRotation: features.peakRotation, peakAcceleration: features.peakAcceleration,
                         duration: features.duration, samples: settings.retainRawSamples ? samples : [])
    }
}

public enum MotionReplay {
    public static func process<S: Sequence>(_ samples: S, settings: TrackingSettings = .init(), classifier: (any ShotClassifier)? = nil) -> [ShotEvent] where S.Element == MotionSample {
        var pipeline = MotionPipeline(settings: settings, classifier: classifier)
        var events: [ShotEvent] = []
        for sample in samples { if let event = pipeline.ingest(sample) { events.append(event) } }
        if let event = pipeline.finish() { events.append(event) }
        return events
    }
    public static func process(samples: [MotionSample], settings: TrackingSettings = .init(), classifier: (any ShotClassifier)? = nil) -> [ShotEvent] {
        process(samples, settings: settings, classifier: classifier)
    }
}
