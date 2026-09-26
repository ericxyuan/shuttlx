import Foundation

public enum RecordKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case fastestSwing, fastestSmash, fastestClear, fastestDrive, mostShots, mostSmashes
    case bestSmashConsistency, bestClearConsistency, longestRally, mostRallies, highestAverageRally
    case longestSession, mostSessionsSevenDays, mostShotsSevenDays
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fastestSwing: "Fastest Swing"
        case .fastestSmash: "Fastest Smash"
        case .fastestClear: "Fastest Clear"
        case .fastestDrive: "Fastest Drive"
        case .mostShots: "Most Shots"
        case .mostSmashes: "Most Smashes"
        case .bestSmashConsistency: "Highest Smash Consistency"
        case .bestClearConsistency: "Highest Clear Consistency"
        case .longestRally: "Longest Rally"
        case .mostRallies: "Most Rallies"
        case .highestAverageRally: "Highest Average Rally"
        case .longestSession: "Longest Session"
        case .mostSessionsSevenDays: "Most Sessions in 7 Days"
        case .mostShotsSevenDays: "Most Shots in 7 Days"
        }
    }
    public var unit: String {
        switch self {
        case .fastestSwing, .fastestSmash, .fastestClear, .fastestDrive: "km/h"
        case .bestSmashConsistency, .bestClearConsistency: "%"
        case .longestSession: "seconds"
        case .mostRallies: "rallies"
        case .mostSessionsSevenDays: "sessions"
        default: "shots"
        }
    }
}
public struct RecordPoint: Codable, Sendable, Hashable {
    public var value: Double
    public var date: Date
    public var sessionID: UUID?
    public var shotID: UUID?
    public init(value: Double, date: Date, sessionID: UUID? = nil, shotID: UUID? = nil) {
        self.value = value; self.date = date; self.sessionID = sessionID; self.shotID = shotID
    }
}
public struct PersonalRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: RecordKind { kind }
    public var kind: RecordKind
    public var value: Double
    public var unit: String
    public var achievedAt: Date
    public var sessionID: UUID?
    public var shotID: UUID?
    public var previousValue: Double?
    public var progression: [RecordPoint]
}
public enum RecordDirection: String, Codable, Sendable { case higher, lower }
public enum RecordService {
    /// Historical strict improvements only. Ties keep the earliest achievement; supports minima for future categories.
    public static func progression(points: [RecordPoint], direction: RecordDirection = .higher) -> [RecordPoint] {
        let sorted = points.filter { $0.value.isFinite && $0.date.timeIntervalSince1970.isFinite }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sessionID != $1.sessionID { return ($0.sessionID?.uuidString ?? "") < ($1.sessionID?.uuidString ?? "") }
            return ($0.shotID?.uuidString ?? "") < ($1.shotID?.uuidString ?? "")
        }
        var result = [RecordPoint]()
        for point in sorted {
            if let previous = result.last {
                let improves = direction == .higher ? point.value > previous.value : point.value < previous.value
                if improves { result.append(point) }
            } else { result.append(point) }
        }
        return result
    }
    public static func records(from source: [Session], rallyGap: Double = 6) -> [PersonalRecord] {
        let sessions = productionSessions(source)
        var candidates: [RecordKind: [RecordPoint]] = [:]
        func append(_ kind: RecordKind, value: Double, date: Date, session: Session, shot: ShotEvent? = nil) {
            guard value.isFinite, value > 0 else { return }
            candidates[kind, default: []].append(RecordPoint(value: value, date: date, sessionID: session.id, shotID: shot?.id))
        }
        for session in sessions {
            let shots = validShots(session.shots)
            let completedAt = session.endedAt ?? session.startedAt.addingTimeInterval(max(0, session.activeDuration.isFinite ? session.activeDuration : 0))
            for shot in shots {
                if let speed = shot.estimatedSwingSpeed {
                    append(.fastestSwing, value: speed, date: session.date(of: shot), session: session, shot: shot)
                    let kind: RecordKind? = switch shot.type {
                    case .smash: .fastestSmash
                    case .clear: .fastestClear
                    case .drive: .fastestDrive
                    default: nil
                    }
                    if let kind { append(kind, value: speed, date: session.date(of: shot), session: session, shot: shot) }
                }
            }
            append(.mostShots, value: Double(shots.count), date: completedAt, session: session)
            append(.mostSmashes, value: Double(shots.filter { $0.type == .smash }.count), date: completedAt, session: session)
            append(.longestSession, value: session.duration, date: completedAt, session: session)
            let rallies = RallyEngine.rallies(in: session, gap: rallyGap)
            append(.mostRallies, value: Double(rallies.count), date: completedAt, session: session)
            if let average = mean(rallies.map { Double($0.shotCount) }) {
                append(.highestAverageRally, value: average, date: completedAt, session: session)
            }
            for rally in rallies {
                append(.longestRally, value: Double(rally.shotCount), date: session.startedAt.addingTimeInterval(rally.endedAt), session: session, shot: rally.shots.first)
            }
            for result in ConsistencyEngine.summarize(shots: shots) {
                if result.type == .smash || result.type == .clear {
                    append(result.type == .smash ? .bestSmashConsistency : .bestClearConsistency,
                           value: result.score, date: completedAt, session: session)
                }
            }
        }
        // Exact rolling 168-hour interval (start exclusive, end inclusive), evaluated at every session start.
        var left = 0, rollingShots = 0
        for (right, session) in sessions.enumerated() {
            rollingShots += validShots(session.shots).count
            let lower = session.startedAt.addingTimeInterval(-7 * 24 * 60 * 60)
            while left <= right && sessions[left].startedAt <= lower {
                rollingShots -= validShots(sessions[left].shots).count; left += 1
            }
            append(.mostSessionsSevenDays, value: Double(right - left + 1), date: session.startedAt, session: session)
            append(.mostShotsSevenDays, value: Double(rollingShots), date: session.startedAt, session: session)
        }
        return RecordKind.allCases.compactMap { kind in
            let points = progression(points: candidates[kind] ?? [])
            guard let winner = points.last else { return nil }
            return PersonalRecord(kind: kind, value: winner.value, unit: kind.unit, achievedAt: winner.date,
                sessionID: winner.sessionID, shotID: winner.shotID,
                previousValue: points.count >= 2 ? points[points.count - 2].value : nil, progression: points)
        }
    }
}
