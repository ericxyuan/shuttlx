# ShuttlXCore API contract

All models below are public Codable, Sendable value types; enum cases have displayName. UUID identifiers. All timestamps in MotionSample/ShotEvent are session-relative seconds. Rotation is rad/s; user acceleration is g; estimatedSwingSpeed is optional km/h (never shuttle speed). UI should label speed as estimated, and measured sensor rotation separately.

- `Vector3(x:y:z:)`, `.magnitude`.
- `MotionSample(timestamp:acceleration:rotation:)`; acceleration, rotation are Vector3.
- `ShotType`: smash, clear, drop, drive, lift, net, serve, unknown.
- `ShotHand`: forehand, backhand, unknown. `ShotPosition`: overhead, sidearm, underarm, unknown. `TacticalRole`: attack, defence, neutral, unknown.
- `ShotEvent(id:timestamp:type:hand:position:tactical:confidence:handConfidence:positionConfidence:estimatedSwingSpeed:peakRotation:peakAcceleration:duration:samples:)`: all except timestamp have defaults. `.peakRotationDegrees`.
- `Session(id:startedAt:endedAt:activeDuration:name:shots:sampleRateHz:equipmentIDs:isDemo:)`: every field defaults. `.shotCount`, `.duration`, `.date(of:)`.
- `PlayingHand`: right, left. `WatchWrist`: right, left. `TrackingSettings()` mutable defaults: playingHand, watchWrist, sampleRateHz, accelerationThreshold, rotationThreshold, refractoryPeriod, preWindow, postWindow, confidenceThreshold, rallyGap, retainRawSamples, hapticFeedback, autoPause, calibratedLeverArmMeters: Double?, handCalibrationSign: Double?. `.validated()` normalizes bounds.
- `WatchMetric`: shotCount, sessionTime, currentRally, lastSwingSpeed, maxSwingSpeed, lastShot, smashes, averageSwingSpeed. `WatchPreset`: minimal, performance, rally, speed, custom. `WatchLayout(preset:)` defaults performance; mutable `.preset`, `.primary`, `.secondary`, `.tertiary: WatchMetric?`; `.apply(_ preset:)`.

## Detection and replay

`MotionPipeline(settings: TrackingSettings = .init())` is a mutating struct. `ingest(_ sample: MotionSample) -> ShotEvent?`, `finish() -> ShotEvent?`, `reset()`. `measuredSampleRateHz: Double?`. Use serial queue or actor on Watch; values are Sendable, pipeline must have one owner. Invalid/nonmonotonic samples are discarded. `MotionReplay.process(samples:settings:) -> [ShotEvent]` uses identical production pipeline.

Classifier seam: `ShotClassifier: Sendable` with `classify(features: SwingFeatures, settings: TrackingSettings) -> ShotClassification`. Implementations `HeuristicShotClassifier`, `HybridShotClassifier`. `MotionPipeline` accepts optional `classifier: any ShotClassifier`. Core ML model injected explicitly through conditional CoreML adapter; none is silently bundled or fabricated. Heuristic shot type/tactics remain unknown without validated model. Calibration needed for hand and estimated swing speed.

## Analytics

`AnalyticsPeriod`: latestSession, today, sevenDays, thirtyDays, threeMonths, allTime. `.displayName`; `.sessions(from: [Session], now: Date = .now, calendar: Calendar = .current) -> [Session]` excludes demo and future sessions.

`StatisticsEngine.summarize(_ sessions: [Session], rallyGap: Double = 6) -> SessionStatistics`: sessionCount, duration, totalShots, knownShots, unknownShots, shotCounts [ShotType:Int], handCounts [ShotHand:Int], positionCounts [ShotPosition:Int], tacticalCounts [TacticalRole:Int], highIntensity, mediumIntensity, lowIntensity; maxSwingSpeed, averageSwingSpeed, medianSwingSpeed, maxAngularVelocity, averageAngularVelocity, maxAcceleration optional Double. Angular stats are DEGREES/SECOND for display. rallyCount, averageRallyLength, longestRally, averageRest optional Double. `SessionStatistics.empty`.

`RallyEngine.rallies(in: Session, gap: Double = 6) -> [Rally]`: Rally id, sessionID, shots, startedAt/endedAt relative seconds, duration, shotCount. A rally is inferred from this player's gaps, not the entire court rally.

`ConsistencyEngine.summarize(shots: [ShotEvent], minimumCount: Int = 5) -> [ConsistencyResult]`: type, score (0...100), sampleCount, explanation; excludes unknown shots. Within type coefficient-of-variation over duration/peakRotation/peakAcceleration; no accuracy claim.

`AnalysisEngine.analyze(_ sessions: [Session], rallyGap: Double = 6) -> AnalysisSummary`: statistics, radar [RadarMetric], consistency [ConsistencyResult], rallies [Rally], insights [String]. RadarMetric id/name, normalizedScore: Double? (0...100), sourceMetrics [String:Double], explanation, confidence (0...1), minimumDataRequirement. Missing values must stay missing. Six dimensions: Attack, Defence, Rotation, Consistency, Control, Shot Variety. Attack/Defence unavailable without known tactical roles; Control unavailable without landing/outcome data. No skill rating.

`RecordService.records(from: [Session], rallyGap: Double = 6) -> [PersonalRecord]`: PersonalRecord id, kind: RecordKind, value, unit, achievedAt, sessionID: UUID?, shotID: UUID?, previousValue: Double?, progression [RecordPoint]. RecordPoint value/date/sessionID/shotID. RecordKind has displayName. Categories cover fastest swing/smash/clear/drive, most shots/smashes, best smash/clear consistency, longest rally, most rallies, highest average rally, longest session, most sessions/shots in rolling seven days. Records rebuilt from sessions, demo excluded.

`EquipmentCorrelationEngine.compare(sessions: [Session], equipmentID: UUID, minimumSessions: Int = 3) -> EquipmentComparison?`: matchedSessions, otherSessions, matchedMeanRotation, otherMeanRotation (degrees/s), explanation. Observational association only.

No production sample sessions or synthetic metrics. Test fixtures are explicitly synthetic sensor traces.
