import Foundation

public struct Vector3: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public var magnitude: Double { sqrt(x * x + y * y + z * z) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct MotionSample: Codable, Sendable, Hashable {
    public var timestamp: Double
    public var acceleration: Vector3
    public var rotation: Vector3
    public init(timestamp: Double, acceleration: Vector3, rotation: Vector3) {
        self.timestamp = timestamp; self.acceleration = acceleration; self.rotation = rotation
    }
    public var isValid: Bool { timestamp.isFinite && timestamp >= 0 && acceleration.isFinite && rotation.isFinite }
}

public enum ShotType: String, Codable, Sendable, CaseIterable, Identifiable {
    case smash, clear, drop, drive, lift, net, serve, unknown
    public var id: String { rawValue }
    public var displayName: String { self == .unknown ? "Unknown Shot" : (self == .net ? "Net Shot" : rawValue.capitalized) }
}
public enum ShotHand: String, Codable, Sendable, CaseIterable, Identifiable {
    case forehand, backhand, unknown
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
public enum ShotPosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case overhead, sidearm, underarm, unknown
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
public enum TacticalRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case attack, defence, neutral, unknown
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct ShotEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var timestamp: Double
    public var type: ShotType
    public var hand: ShotHand
    public var position: ShotPosition
    public var tactical: TacticalRole
    public var confidence: Double
    public var handConfidence: Double
    public var positionConfidence: Double
    /// Experimental calibrated tangential estimate in km/h, never shuttle speed.
    public var estimatedSwingSpeed: Double?
    /// radians per second
    public var peakRotation: Double
    /// gravity units from CMDeviceMotion.userAcceleration
    public var peakAcceleration: Double
    public var duration: Double
    public var samples: [MotionSample]
    public init(id: UUID = UUID(), timestamp: Double, type: ShotType = .unknown,
                hand: ShotHand = .unknown, position: ShotPosition = .unknown,
                tactical: TacticalRole = .unknown, confidence: Double = 0,
                handConfidence: Double = 0, positionConfidence: Double = 0,
                estimatedSwingSpeed: Double? = nil, peakRotation: Double = 0,
                peakAcceleration: Double = 0, duration: Double = 0, samples: [MotionSample] = []) {
        self.id = id; self.timestamp = timestamp; self.type = type; self.hand = hand
        self.position = position; self.tactical = tactical; self.confidence = confidence
        self.handConfidence = handConfidence; self.positionConfidence = positionConfidence
        self.estimatedSwingSpeed = estimatedSwingSpeed; self.peakRotation = peakRotation
        self.peakAcceleration = peakAcceleration; self.duration = duration; self.samples = samples
    }
    public var peakRotationDegrees: Double { peakRotation * 180 / .pi }
}

public struct Session: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var activeDuration: Double
    public var name: String
    public var shots: [ShotEvent]
    public var sampleRateHz: Double?
    public var equipmentIDs: [UUID]
    public var isDemo: Bool
    public init(id: UUID = UUID(), startedAt: Date = .now, endedAt: Date? = nil,
                activeDuration: Double = 0, name: String = "Badminton", shots: [ShotEvent] = [],
                sampleRateHz: Double? = nil, equipmentIDs: [UUID] = [], isDemo: Bool = false) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.activeDuration = activeDuration; self.name = name; self.shots = shots
        self.sampleRateHz = sampleRateHz; self.equipmentIDs = equipmentIDs; self.isDemo = isDemo
    }
    public var shotCount: Int { shots.count }
    public var duration: Double { max(0, activeDuration) }
    public func date(of shot: ShotEvent) -> Date { startedAt.addingTimeInterval(shot.timestamp) }
}

public enum PlayingHand: String, Codable, Sendable, CaseIterable, Identifiable {
    case right, left
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
public enum WatchWrist: String, Codable, Sendable, CaseIterable, Identifiable {
    case right, left
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct TrackingSettings: Codable, Sendable, Equatable {
    public var playingHand: PlayingHand = .right
    public var watchWrist: WatchWrist = .right
    /// Requested rate. Core Motion and device capabilities determine actual delivered rate.
    public var sampleRateHz: Double = 50
    public var accelerationThreshold: Double = 2.2
    public var rotationThreshold: Double = 10
    public var refractoryPeriod: Double = 0.65
    public var preWindow: Double = 0.2
    public var postWindow: Double = 0.4
    public var confidenceThreshold: Double = 0.8
    public var rallyGap: Double = 6
    public var retainRawSamples: Bool = true
    public var hapticFeedback: Bool = false
    public var autoPause: Bool = false
    /// Enables only the explicitly experimental, rule-based classifier. It is off for production defaults.
    public var enableExperimentalClassification: Bool = false
    public var calibratedLeverArmMeters: Double? = nil
    /// Signed z-axis direction observed in labelled forehand calibration. Nil until calibrated.
    public var handCalibrationSign: Double? = nil
    public init() {}
    public func validated() -> TrackingSettings {
        var result = self
        result.sampleRateHz = bounded(sampleRateHz, 25...200, fallback: 50)
        result.accelerationThreshold = bounded(accelerationThreshold, 0.8...8, fallback: 2.2)
        result.rotationThreshold = bounded(rotationThreshold, 3...35, fallback: 10)
        result.refractoryPeriod = bounded(refractoryPeriod, 0.3...2, fallback: 0.65)
        result.preWindow = bounded(preWindow, 0.1...0.5, fallback: 0.2)
        result.postWindow = bounded(postWindow, 0.2...0.8, fallback: 0.4)
        result.confidenceThreshold = bounded(confidenceThreshold, 0.5...0.99, fallback: 0.8)
        result.rallyGap = bounded(rallyGap, 2...20, fallback: 6)
        if let radius = calibratedLeverArmMeters, (!radius.isFinite || radius < 0.05 || radius > 1.2) {
            result.calibratedLeverArmMeters = nil
        }
        if let sign = handCalibrationSign {
            result.handCalibrationSign = sign.isFinite && sign != 0 ? (sign > 0 ? 1 : -1) : nil
        }
        return result
    }
}

public enum WatchMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    case shotCount, sessionTime, currentRally, lastSwingSpeed, maxSwingSpeed, lastShot, smashes, averageSwingSpeed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .shotCount: "Shots"
        case .sessionTime: "Session Time"
        case .currentRally: "Current Rally"
        case .lastSwingSpeed: "Last Swing"
        case .maxSwingSpeed: "Max Swing"
        case .lastShot: "Last Shot"
        case .smashes: "Smashes"
        case .averageSwingSpeed: "Average Swing"
        }
    }
}
public enum WatchPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal, performance, rally, speed, custom
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
public struct WatchLayout: Codable, Sendable, Equatable {
    public var preset: WatchPreset
    public var primary: WatchMetric
    public var secondary: WatchMetric
    public var tertiary: WatchMetric?
    public init(preset: WatchPreset = .performance) {
        self.preset = preset; primary = .shotCount; secondary = .lastSwingSpeed; tertiary = .lastShot
        apply(preset)
    }
    public mutating func apply(_ preset: WatchPreset) {
        self.preset = preset
        switch preset {
        case .minimal: primary = .sessionTime; secondary = .shotCount; tertiary = nil
        case .performance: primary = .shotCount; secondary = .lastSwingSpeed; tertiary = .lastShot
        case .rally: primary = .currentRally; secondary = .shotCount; tertiary = .sessionTime
        case .speed: primary = .lastSwingSpeed; secondary = .maxSwingSpeed; tertiary = .shotCount
        case .custom: break
        }
    }
}

func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
func mean(_ values: [Double]) -> Double? {
    let valid = values.filter(\.isFinite)
    return valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
}
func median(_ values: [Double]) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    let midpoint = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[midpoint - 1] + sorted[midpoint]) / 2 : sorted[midpoint]
}


