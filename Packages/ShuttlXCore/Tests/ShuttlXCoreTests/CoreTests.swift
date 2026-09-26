import XCTest
@testable import ShuttlXCore

final class CoreTests: XCTestCase {
    func testReplayRejectsReversedSamplesAndOutOfRangeLabels() {
        let samples = [
            MotionSample(timestamp: 0, acceleration: .init(), rotation: .init()),
            MotionSample(timestamp: 1, acceleration: .init(), rotation: .init())
        ]
        XCTAssertThrowsError(try MotionRecording(name: "Unordered", samples: Array(samples.reversed())).validate())
        let label = MotionLabel(startTime: 0, endTime: 2, shotType: .smash)
        XCTAssertThrowsError(try MotionRecording(name: "Outside recording", samples: samples, labels: [label]).validate())
    }

    func testWatchRecordingRejectsMisspelledPositiveLabel() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString, "label": "smsh", "source": "Watch",
            "samples": [["timestamp": 0, "acceleration": ["x": 0, "y": 0, "z": 0], "rotation": ["x": 0, "y": 0, "z": 0]]]
        ]
        XCTAssertThrowsError(try MotionRecording.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testNegativeWatchRecordingPreservesNegativeLabel() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString, "label": "Walking", "negativeActivity": "Walking", "source": "Watch",
            "samples": [["timestamp": 0, "acceleration": ["x": 0, "y": 0, "z": 0], "rotation": ["x": 0, "y": 0, "z": 0]]]
        ]
        let recording = try MotionRecording.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(recording.labels.count, 1)
        XCTAssertNil(recording.labels[0].shotType)
        XCTAssertEqual(recording.labels[0].note, "Walking")
    }

    private func trace(rate: Double = 50, peaks: [Double] = [0.6], accelerationOnly: Bool = false) -> [MotionSample] {
        (0...Int(2 * rate)).map { index in
            let time = Double(index) / rate
            let pulse = peaks.map { max(0, 1 - abs(time - $0) / 0.12) }.max() ?? 0
            return MotionSample(timestamp: time, acceleration: Vector3(x: pulse * 9),
                                rotation: Vector3(z: accelerationOnly ? 0 : pulse * 30))
        }
    }
    private func session(_ shots: [ShotEvent], start: Double = 1_700_000_000) -> Session {
        Session(startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: start + 60),
                activeDuration: 60, shots: shots)
    }

    func testCompletePulseProducesOneUnknownEventWithoutSpeed() {
        let events = MotionReplay.process(samples: trace())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .unknown)
        XCTAssertEqual(events.first?.tactical, .unknown)
        XCTAssertNil(events.first?.estimatedSwingSpeed)
        XCTAssertEqual(events.first?.peakRotation ?? 0, 30, accuracy: 0.001)
        XCTAssertFalse(events.first?.samples.isEmpty ?? true)
    }
    func testAccelerationAloneAndSingleSpikeDoNotCount() {
        XCTAssertTrue(MotionReplay.process(samples: trace(accelerationOnly: true)).isEmpty)
        let spike = (0..<100).map { index in
            MotionSample(timestamp: Double(index) / 50, acceleration: Vector3(x: index == 30 ? 9 : 0),
                         rotation: Vector3(z: index == 30 ? 30 : 0))
        }
        XCTAssertTrue(MotionReplay.process(samples: spike).isEmpty)
    }
    func testSustainedMotionDoesNotCountAsRepeatedShots() {
        let samples = (0..<300).map { index in
            MotionSample(timestamp: Double(index) / 50, acceleration: Vector3(x: 9), rotation: Vector3(z: 30))
        }
        XCTAssertTrue(MotionReplay.process(samples: samples).isEmpty)
    }
    func testSeparatedPulsesCountAndRefractorySuppressesNearbyPulse() {
        XCTAssertEqual(MotionReplay.process(samples: trace(peaks: [0.6, 1.5])).count, 2)
        XCTAssertEqual(MotionReplay.process(samples: trace(peaks: [0.6, 1.05])).count, 1)
    }
    func testIncompleteWindowIsDiscarded() {
        let samples = trace().filter { $0.timestamp <= 0.66 }
        XCTAssertTrue(MotionReplay.process(samples: samples).isEmpty)
    }
    func testInvalidAndNonMonotonicSamplesAreDiscardedAndBufferIsBounded() {
        var pipeline = MotionPipeline()
        XCTAssertNil(pipeline.ingest(MotionSample(timestamp: -1, acceleration: .init(), rotation: .init())))
        XCTAssertNil(pipeline.ingest(MotionSample(timestamp: 1, acceleration: .init(), rotation: .init())))
        XCTAssertNil(pipeline.ingest(MotionSample(timestamp: 0.5, acceleration: .init(), rotation: .init())))
        XCTAssertEqual(pipeline.discardedSamples, 2)
        for index in 1...20_000 {
            _ = pipeline.ingest(MotionSample(timestamp: 1 + Double(index) / 10_000, acceleration: .init(), rotation: .init()))
        }
        XCTAssertLessThanOrEqual(pipeline.bufferedSampleCount, 1536)
    }
    func testMeasuredRateAndTimestampIntegration() throws {
        var pipeline = MotionPipeline()
        for sample in trace(rate: 50) { _ = pipeline.ingest(sample) }
        XCTAssertEqual(pipeline.measuredSampleRateHz ?? 0, 50, accuracy: 0.001)
        let samples = [0.0, 0.02, 0.05, 0.1].map {
            MotionSample(timestamp: $0, acceleration: Vector3(x: 2), rotation: Vector3(z: 10))
        }
        let features = try XCTUnwrap(SwingFeatures.extract(from: samples))
        XCTAssertEqual(features.accelerationImpulse, 0.2, accuracy: 0.0001)
        XCTAssertEqual(features.rotationImpulse, 1, accuracy: 0.0001)
    }
    func testExperimentalClassificationAndCalibrationRemainExplicit() throws {
        var settings = TrackingSettings()
        settings.enableExperimentalClassification = true
        settings.confidenceThreshold = 0.7
        settings.calibratedLeverArmMeters = 0.5
        settings.handCalibrationSign = 1
        let event = try XCTUnwrap(MotionReplay.process(samples: trace(), settings: settings).first)
        XCTAssertEqual(event.type, .smash)
        XCTAssertEqual(event.hand, .forehand)
        XCTAssertEqual(event.estimatedSwingSpeed ?? 0, 54, accuracy: 0.001)
        XCTAssertEqual(event.tactical, .unknown)
        settings.confidenceThreshold = 0.99
        let conservative = try XCTUnwrap(MotionReplay.process(samples: trace(), settings: settings).first)
        XCTAssertEqual(conservative.type, .unknown)
        XCTAssertEqual(conservative.hand, .unknown)
    }
    func testNoRawRetentionPreservesSummary() throws {
        var settings = TrackingSettings(); settings.retainRawSamples = false
        let event = try XCTUnwrap(MotionReplay.process(samples: trace(), settings: settings).first)
        XCTAssertTrue(event.samples.isEmpty)
        XCTAssertGreaterThan(event.peakAcceleration, 0)
    }
    func testSessionBoundaryDoesNotCreateRestOrMergeRallies() {
        let first = session([ShotEvent(timestamp: 1), ShotEvent(timestamp: 3)])
        let second = session([ShotEvent(timestamp: 1)], start: 1_700_000_100)
        let stats = StatisticsEngine.summarize([first, second, first])
        XCTAssertEqual(stats.sessionCount, 2)
        XCTAssertEqual(stats.totalShots, 3)
        XCTAssertEqual(stats.rallyCount, 2)
        XCTAssertNil(stats.averageRest)
        XCTAssertEqual(RallyEngine.rallies(in: first).first?.id, first.shots.first?.id)
    }
    func testRallyGapSettingAppliesToAnalysisAndRecords() {
        let row = session([ShotEvent(timestamp: 1), ShotEvent(timestamp: 6)])
        XCTAssertEqual(AnalysisEngine.analyze([row], rallyGap: 2).statistics.rallyCount, 2)
        XCTAssertEqual(AnalysisEngine.analyze([row], rallyGap: 6).statistics.rallyCount, 1)
        XCTAssertEqual(RecordService.records(from: [row], rallyGap: 2).first { $0.kind == .longestRally }?.value, 1)
    }
    func testUnknownCoverageAndUnavailableRadarAreNotZero() {
        let row = session([ShotEvent(timestamp: 1, peakAcceleration: 2), ShotEvent(timestamp: 3, type: .smash, peakAcceleration: 8)])
        let analysis = AnalysisEngine.analyze([row])
        XCTAssertEqual(analysis.statistics.totalShots, 2)
        XCTAssertEqual(analysis.statistics.unknownShots, 1)
        XCTAssertEqual(analysis.statistics.highIntensity, 1)
        for name in ["Attack", "Defence", "Control", "Rotation", "Shot Variety"] {
            XCTAssertNil(analysis.radar.first { $0.name == name }?.normalizedScore)
        }
    }
    func testRecordsKeepHistoricalImprovementsAndExcludeDemo() throws {
        let rows = [40.0, 60, 50, 70].enumerated().map { index, speed in
            session([ShotEvent(timestamp: 1, type: .smash, estimatedSwingSpeed: speed)], start: 1_700_000_000 + Double(index) * 3600)
        }
        var demo = session([ShotEvent(timestamp: 1, estimatedSwingSpeed: 999)])
        demo.isDemo = true
        let record = try XCTUnwrap(RecordService.records(from: rows + [demo]).first { $0.kind == .fastestSwing })
        XCTAssertEqual(record.progression.map(\.value), [40, 60, 70])
        XCTAssertEqual(record.previousValue, 60)
        XCTAssertEqual(record.sessionID, rows.last?.id)
    }
    func testSevenDayRecordUsesRollingWindow() {
        let start = 1_700_000_000.0
        let rows = [0.0, 6, 8].map { session([ShotEvent(timestamp: 1)], start: start + $0 * 86_400) }
        XCTAssertEqual(RecordService.records(from: rows).first { $0.kind == .mostSessionsSevenDays }?.value, 2)
    }
    func testPeriodsExcludeDemoAndFutureSessions() {
        let now = Date(timeIntervalSince1970: 1_700_010_000)
        let past = session([])
        var demo = past; demo.id = UUID(); demo.isDemo = true
        let future = session([], start: now.timeIntervalSince1970 + 3600)
        XCTAssertEqual(AnalyticsPeriod.allTime.sessions(from: [past, demo, future], now: now).map(\.id), [past.id])
    }
    func testValidationRejectsDuplicateIDsAndUnorderedWindows() {
        var shot = ShotEvent(timestamp: 1)
        var row = session([shot, shot])
        XCTAssertThrowsError(try SessionValidator.validate(row))
        shot.samples = [MotionSample(timestamp: 1, acceleration: .init(), rotation: .init()),
                        MotionSample(timestamp: 0.5, acceleration: .init(), rotation: .init())]
        row.shots = [shot]
        XCTAssertThrowsError(try SessionValidator.validate(row))
    }
    func testReplayEvaluationMatchesOneDetectionPerLabel() {
        let events = [ShotEvent(timestamp: 1, type: .smash), ShotEvent(timestamp: 1.1, type: .unknown)]
        let result = ReplayEvaluation.evaluate(events: events, labels: [MotionLabel(startTime: 0.9, endTime: 1.2, shotType: .smash)])
        XCTAssertEqual(result.matchedShots, 1)
        XCTAssertEqual(result.unmatchedDetections, 1)
    }
}
