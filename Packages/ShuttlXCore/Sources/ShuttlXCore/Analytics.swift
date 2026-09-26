import Foundation

public enum AnalyticsPeriod: String, Codable, Sendable, CaseIterable, Identifiable {
    case latestSession, today, sevenDays, thirtyDays, threeMonths, allTime
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .latestSession: "Latest Session"
        case .today: "Today"
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        case .threeMonths: "3 Months"
        case .allTime: "All Time"
        }
    }
    public func sessions(from source: [Session], now: Date = .now, calendar: Calendar = .current) -> [Session] {
        let candidates = productionSessions(source).filter { $0.startedAt <= now }.sorted { $0.startedAt < $1.startedAt }
        if self == .latestSession { return candidates.last.map { [$0] } ?? [] }
        let lower: Date?
        switch self {
        case .today: lower = calendar.startOfDay(for: now)
        case .sevenDays: lower = calendar.date(byAdding: .day, value: -7, to: now)
        case .thirtyDays: lower = calendar.date(byAdding: .day, value: -30, to: now)
        case .threeMonths: lower = calendar.date(byAdding: .month, value: -3, to: now)
        case .latestSession, .allTime: lower = nil
        }
        guard let lower else { return candidates }
        return candidates.filter { $0.startedAt >= lower }
    }
}

public struct Rally: Codable, Sendable, Identifiable, Hashable {
    /// First shot UUID remains stable when the same session is re-analysed.
    public var id: UUID { shots[0].id }
    public var sessionID: UUID
    public var shots: [ShotEvent]
    public var startedAt: Double { shots.first?.timestamp ?? 0 }
    public var endedAt: Double { shots.last?.timestamp ?? 0 }
    public var duration: Double { max(0, endedAt - startedAt) }
    public var shotCount: Int { shots.count }
}
public enum RallyEngine {
    public static func rallies(in session: Session, gap: Double = 6) -> [Rally] {
        let shots = validShots(session.shots).sorted { $0.timestamp < $1.timestamp }
        let threshold = bounded(gap, 2...20, fallback: 6)
        var groups: [[ShotEvent]] = []
        for shot in shots {
            if let last = groups.last?.last, shot.timestamp - last.timestamp <= threshold {
                groups[groups.count - 1].append(shot)
            } else { groups.append([shot]) }
        }
        return groups.map { Rally(sessionID: session.id, shots: $0) }
    }
}

public struct SessionStatistics: Codable, Sendable, Hashable {
    public var sessionCount = 0
    public var duration = 0.0
    public var totalShots = 0
    public var knownShots = 0
    public var unknownShots = 0
    public var shotCounts: [ShotType: Int] = [:]
    public var handCounts: [ShotHand: Int] = [:]
    public var positionCounts: [ShotPosition: Int] = [:]
    public var tacticalCounts: [TacticalRole: Int] = [:]
    public var highIntensity = 0
    public var mediumIntensity = 0
    public var lowIntensity = 0
    public var maxSwingSpeed: Double?
    public var averageSwingSpeed: Double?
    public var medianSwingSpeed: Double?
    /// Display unit degrees per second. These aggregate per-shot peaks, not all continuous samples.
    public var maxAngularVelocity: Double?
    public var averageAngularVelocity: Double?
    public var maxAcceleration: Double?
    public var rallyCount = 0
    public var averageRallyLength: Double?
    public var longestRally = 0
    public var averageRest: Double?
    public init() {}
    public static var empty: SessionStatistics { .init() }
}
public enum StatisticsEngine {
    public static func summarize(_ source: [Session], rallyGap: Double = 6) -> SessionStatistics {
        let sessions = productionSessions(source)
        let shots = sessions.flatMap { validShots($0.shots) }
        let rallies = sessions.flatMap { RallyEngine.rallies(in: $0, gap: rallyGap) }
        var result = SessionStatistics()
        result.sessionCount = sessions.count
        result.duration = sessions.reduce(0) { $0 + ($1.activeDuration.isFinite ? max(0, $1.activeDuration) : 0) }
        result.totalShots = shots.count
        for type in ShotType.allCases { result.shotCounts[type] = shots.filter { $0.type == type }.count }
        for hand in ShotHand.allCases { result.handCounts[hand] = shots.filter { $0.hand == hand }.count }
        for position in ShotPosition.allCases { result.positionCounts[position] = shots.filter { $0.position == position }.count }
        for role in TacticalRole.allCases { result.tacticalCounts[role] = shots.filter { $0.tactical == role }.count }
        result.unknownShots = result.shotCounts[.unknown] ?? 0
        result.knownShots = shots.count - result.unknownShots
        result.highIntensity = shots.filter { $0.peakAcceleration >= 7 }.count
        result.mediumIntensity = shots.filter { $0.peakAcceleration >= 3 && $0.peakAcceleration < 7 }.count
        result.lowIntensity = shots.count - result.highIntensity - result.mediumIntensity
        let speeds = shots.compactMap(\.estimatedSwingSpeed).filter { $0.isFinite && $0 > 0 }
        result.maxSwingSpeed = speeds.max(); result.averageSwingSpeed = mean(speeds); result.medianSwingSpeed = median(speeds)
        let rotations = shots.map(\.peakRotationDegrees)
        result.maxAngularVelocity = rotations.max(); result.averageAngularVelocity = mean(rotations)
        result.maxAcceleration = shots.map(\.peakAcceleration).max()
        result.rallyCount = rallies.count
        result.averageRallyLength = mean(rallies.map { Double($0.shotCount) })
        result.longestRally = rallies.map(\.shotCount).max() ?? 0
        // Gaps never cross session boundaries; these are intervals between the player's detected strokes.
        let rests = sessions.flatMap { session -> [Double] in
            let rows = RallyEngine.rallies(in: session, gap: rallyGap)
            return zip(rows, rows.dropFirst()).map { pair in pair.1.startedAt - pair.0.endedAt }
        }
        result.averageRest = mean(rests)
        return result
    }
}

public struct ConsistencyResult: Codable, Sendable, Identifiable, Hashable {
    public var id: ShotType { type }
    public var type: ShotType
    public var score: Double
    public var sampleCount: Int
    public var explanation: String
}
public enum ConsistencyEngine {
    public static func summarize(shots: [ShotEvent], minimumCount: Int = 5) -> [ConsistencyResult] {
        let valid = validShots(shots)
        return ShotType.allCases.filter { $0 != .unknown }.compactMap { type in
            let rows = valid.filter { $0.type == type && $0.duration > 0 && $0.peakRotation > 0 && $0.peakAcceleration > 0 }
            guard rows.count >= max(3, minimumCount) else { return nil }
            let coefficients = [rows.map(\.duration), rows.map(\.peakRotation), rows.map(\.peakAcceleration)].compactMap(coefficientOfVariation)
            guard coefficients.count == 3, let average = mean(coefficients) else { return nil }
            return ConsistencyResult(type: type, score: max(0, 1 - average) * 100, sampleCount: rows.count,
                explanation: "100 × (1 − mean coefficient of variation) of active swing duration, peak wrist rotation and peak user acceleration, clipped to 0–100. Calculated across \(rows.count) \(type.displayName.lowercased()) strokes. Repeatability is not shot placement, accuracy or skill.")
        }
    }
}

public struct RadarMetric: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var normalizedScore: Double?
    public var sourceMetrics: [String: Double]
    public var explanation: String
    /// Data coverage, not a statistical probability that a skill assessment is correct.
    public var confidence: Double
    public var minimumDataRequirement: Int
}
public struct AnalysisSummary: Codable, Sendable {
    public var statistics: SessionStatistics
    public var radar: [RadarMetric]
    public var consistency: [ConsistencyResult]
    public var rallies: [Rally]
    public var insights: [String]
}
public enum AnalysisEngine {
    public static func analyze(_ source: [Session], rallyGap: Double = 6) -> AnalysisSummary {
        let sessions = productionSessions(source)
        let shots = sessions.flatMap { validShots($0.shots) }
        let known = shots.filter { $0.type != .unknown }
        let stats = StatisticsEngine.summarize(sessions, rallyGap: rallyGap)
        let tactical = shots.filter { $0.tactical != .unknown }
        let consistency = ConsistencyEngine.summarize(shots: shots)
        let coverage = shots.isEmpty ? 0 : Double(known.count) / Double(shots.count)
        var radar: [RadarMetric] = []
        for (name, role) in [("Attack", TacticalRole.attack), ("Defence", .defence)] {
            let count = tactical.filter { $0.tactical == role }.count
            radar.append(RadarMetric(name: name, normalizedScore: tactical.count >= 10 ? Double(count) / Double(tactical.count) * 100 : nil,
                sourceMetrics: ["classified tactical strokes": Double(tactical.count), "\(name.lowercased()) strokes": Double(count)],
                explanation: "Share of \(name.lowercased()) strokes among explicitly context-classified strokes (including neutral). Unknown tactics are excluded and reported separately. This describes shot mix, not tactical effectiveness. Wrist motion alone cannot establish tactical intent.",
                confidence: shots.isEmpty ? 0 : Double(tactical.count) / Double(shots.count), minimumDataRequirement: 10))
        }
        radar.append(RadarMetric(name: "Rotation", normalizedScore: nil,
            sourceMetrics: stats.averageAngularVelocity.map { ["mean peak wrist rotation (degrees/s)": $0] } ?? [:],
            explanation: "Measured wrist rotation is available in raw statistics. No validated reference range or personal baseline is installed, so a 0–100 rotation rating is intentionally unavailable.", confidence: 0, minimumDataRequirement: 10))
        radar.append(RadarMetric(name: "Consistency", normalizedScore: mean(consistency.map(\.score)),
            sourceMetrics: ["eligible shot types": Double(consistency.count), "eligible strokes": Double(consistency.reduce(0) { $0 + $1.sampleCount })],
            explanation: "Equal-weight mean of repeatability scores for known shot types with at least five positive, finite observations. Repeatability does not measure accuracy.", confidence: shots.isEmpty ? 0 : Double(consistency.reduce(0) { $0 + $1.sampleCount }) / Double(shots.count), minimumDataRequirement: 5))
        radar.append(RadarMetric(name: "Control", normalizedScore: nil, sourceMetrics: [:],
            explanation: "Control needs landing position, placement or outcome evidence that wrist sensors do not provide.", confidence: 0, minimumDataRequirement: 1))
        // Normalized Shannon entropy describes mix, without inventing a normative skill reference.
        let probabilities = ShotType.allCases.filter { $0 != .unknown }.map { type in
            known.isEmpty ? 0 : Double(known.filter { $0.type == type }.count) / Double(known.count)
        }
        let entropy = -probabilities.filter { $0 > 0 }.reduce(0) { $0 + $1 * log($1) } / log(7.0) * 100
        radar.append(RadarMetric(name: "Shot Variety", normalizedScore: known.count >= 20 && coverage >= 0.5 ? entropy : nil,
            sourceMetrics: ["known strokes": Double(known.count), "known coverage percent": coverage * 100, "observed types": Double(Set(known.map(\.type)).count)],
            explanation: "Normalized Shannon entropy of seven known shot-type shares: −Σ(p ln p) ÷ ln(7) × 100. A balanced mix scores higher than a concentrated mix; neither implies better badminton. Needs 20 known strokes and at least 50% classification coverage.", confidence: coverage, minimumDataRequirement: 20))
        var insights = [String]()
        if stats.unknownShots > 0 { insights.append("\(stats.unknownShots) of \(stats.totalShots) detected strokes have unknown type. They remain in your total and sensor statistics.") }
        if tactical.isEmpty && !shots.isEmpty { insights.append("Attack and defence remain unavailable because no tactical context was recorded.") }
        return AnalysisSummary(statistics: stats, radar: radar, consistency: consistency,
            rallies: sessions.flatMap { RallyEngine.rallies(in: $0, gap: rallyGap) }, insights: insights)
    }
}

public struct EquipmentComparison: Codable, Sendable {
    public var matchedSessions: [UUID]
    public var otherSessions: [UUID]
    public var matchedMeanRotation: Double?
    public var otherMeanRotation: Double?
    public var explanation: String
}
public enum EquipmentCorrelationEngine {
    public static func compare(sessions source: [Session], equipmentID: UUID, minimumSessions: Int = 3) -> EquipmentComparison? {
        let sessions = productionSessions(source).filter { !$0.equipmentIDs.isEmpty && !validShots($0.shots).isEmpty }
        let matched = sessions.filter { $0.equipmentIDs.contains(equipmentID) }
        let other = sessions.filter { !$0.equipmentIDs.contains(equipmentID) }
        guard matched.count >= max(2, minimumSessions), other.count >= max(2, minimumSessions) else { return nil }
        func rotation(_ rows: [Session]) -> Double? {
            // Equal session weighting prevents a very long session dominating the comparison.
            mean(rows.compactMap { mean(validShots($0.shots).map(\.peakRotationDegrees)) })
        }
        return EquipmentComparison(matchedSessions: matched.map(\.id), otherSessions: other.map(\.id),
            matchedMeanRotation: rotation(matched), otherMeanRotation: rotation(other),
            explanation: "Equal-weight session means of per-stroke peak wrist rotation (degrees/s). Sessions without recorded equipment are excluded. Shot mix, fatigue and player changes are uncontrolled; this association does not establish that equipment caused a difference.")
    }
}

func coefficientOfVariation(_ values: [Double]) -> Double? {
    guard let average = mean(values), average > 0 else { return nil }
    let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count)
    return sqrt(variance) / average
}
/// Repeated transfers do not multiply sessions. Most complete revision wins deterministically.
func productionSessions(_ source: [Session]) -> [Session] {
    var unique: [UUID: Session] = [:]
    for session in source where !session.isDemo && session.startedAt.timeIntervalSince1970.isFinite {
        if let existing = unique[session.id] {
            let isMoreComplete = (session.endedAt != nil && existing.endedAt == nil)
                || (session.endedAt == existing.endedAt && session.shots.count > existing.shots.count)
                || ((session.endedAt ?? .distantPast) > (existing.endedAt ?? .distantPast))
            if isMoreComplete { unique[session.id] = session }
        } else { unique[session.id] = session }
    }
    return unique.values.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
}
func validShots(_ source: [ShotEvent]) -> [ShotEvent] {
    var seen = Set<UUID>()
    return source.filter { shot in
        shot.timestamp.isFinite && shot.timestamp >= 0 && shot.peakRotation.isFinite && shot.peakRotation >= 0
        && shot.peakAcceleration.isFinite && shot.peakAcceleration >= 0 && shot.duration.isFinite && shot.duration >= 0
        && seen.insert(shot.id).inserted
    }
}

