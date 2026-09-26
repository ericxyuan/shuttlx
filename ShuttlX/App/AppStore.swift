import Foundation
import CryptoKit
import Observation
import SwiftData
import WidgetKit
import ShuttlXCore

@Model final class SessionDocument {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var payload: Data
    var sourceDigest: String = ""
    var updatedAt: Date
    init(id: UUID, payload: Data, sourceDigest: String) { self.id = id; self.payload = payload; self.sourceDigest = sourceDigest; updatedAt = .now }
}

@MainActor @Observable final class AppStore {
    private(set) var sessions: [Session] = []
    var settings: TrackingSettings
    var watchLayout: WatchLayout
    /// nil = forever, 0 = no raw windows, positive = expiry in days.
    var rawRetentionDays: Int?
    var errorMessage: String?
    var isProcessing = false
    let transfer: SessionTransferService
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var connectivityStarted = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    private var analysisCache: [AnalyticsPeriod: AnalysisSummary] = [:]
    private var recordsCache: [PersonalRecord] = []

    init() {
        let defaults = UserDefaults.standard
        settings = Self.decode(TrackingSettings.self, from: defaults.data(forKey: "trackingSettings"))?.validated() ?? .init()
        watchLayout = Self.decode(WatchLayout.self, from: defaults.data(forKey: "watchLayout")) ?? .init()
        let retention = (defaults.object(forKey: "rawRetentionDays") as? Int) ?? 7
        rawRetentionDays = retention < 0 ? nil : retention
        transfer = SessionTransferService(settings: settings, layout: watchLayout)
        do {
            let configuration = ModelConfiguration("ShuttlXSessions", schema: Schema([SessionDocument.self]))
            let container = try ModelContainer(for: SessionDocument.self, configurations: configuration)
            self.container = container
            context = ModelContext(container)
            context?.autosaveEnabled = false
            try loadSessions()
            try enforceRetention()
        } catch { errorMessage = "Saved sessions could not be opened: \(error.localizedDescription)" }
    }

    func startConnectivity(equipmentAt: @escaping (Date) -> [UUID] = { _ in [] }) {
        guard !connectivityStarted else { return }
        connectivityStarted = true
        transfer.onLayoutReceived = { [weak self] layout in
            self?.watchLayout = layout
            self?.saveWatchLayout()
        }
        transfer.onReceiveSession = { [weak self] incoming in
            guard let self else { throw StoreError.unavailable }
            var linked = incoming
            if linked.equipmentIDs.isEmpty { linked.equipmentIDs = equipmentAt(linked.startedAt) }
            try self.saveSession(linked, sourceDigest: Self.fingerprint(incoming))
        }
        transfer.activate()
        saveSettings()
    }

    func refresh() {
        transfer.refreshStatus()
        transfer.retryPendingTransfers()
        do { try enforceRetention() } catch { errorMessage = error.localizedDescription }
        rebuildAnalysis()
    }

    private func loadSessions() throws {
        guard let context else { throw StoreError.unavailable }
        let rows = try context.fetch(FetchDescriptor<SessionDocument>())
        var decoded: [Session] = []
        var unreadable = 0
        for row in rows {
            guard let value = Self.decode(Session.self, from: row.payload),
                  value.id == row.id, (try? validate(value)) != nil else {
                unreadable += 1
                continue
            }
            decoded.append(value)
        }
        sessions = decoded.sorted { $0.startedAt > $1.startedAt }
        rebuildAnalysis()
        if unreadable > 0 {
            errorMessage = "\(unreadable) saved session(s) could not be read. Their stored data is preserved; other sessions remain available."
        }
    }

    func saveSession(_ source: Session, sourceDigest: String? = nil) throws {
        guard let context else { throw StoreError.unavailable }
        try validate(source)
        // Completed immutable sessions are identified by UUID. A resend cannot duplicate analytics.
        let digest = try sourceDigest ?? Self.fingerprint(source)
        if let existing = try context.fetch(FetchDescriptor<SessionDocument>()).first(where: { $0.id == source.id }) {
            guard existing.sourceDigest.isEmpty || existing.sourceDigest == digest else {
                throw StoreError.invalid("A different payload used an existing session identity. The saved session is preserved.")
            }
            return
        }
        let value = retainingRawData(in: source)
        let data = try Self.encoder.encode(value)
        do {
            context.insert(SessionDocument(id: value.id, payload: data, sourceDigest: digest))
            try context.save()
        } catch { context.rollback(); throw error }
        sessions.append(value)
        sessions.sort { $0.startedAt > $1.startedAt }
        rebuildAnalysis()
    }

    func deleteAllSessions() throws {
        guard let context else { throw StoreError.unavailable }
        do {
            try context.delete(model: SessionDocument.self)
            try context.save()
        } catch { context.rollback(); throw error }
        sessions.removeAll()
        rebuildAnalysis()
    }

    func saveSettings() {
        settings = settings.validated()
        settings.retainRawSamples = rawRetentionDays != 0
        do {
            defaults.set(try Self.encoder.encode(settings), forKey: "trackingSettings")
            defaults.set(try Self.encoder.encode(watchLayout), forKey: "watchLayout")
            defaults.set(rawRetentionDays ?? -1, forKey: "rawRetentionDays")
            try enforceRetention()
            try transfer.configure(settings: settings, layout: watchLayout)
            rebuildAnalysis()
        } catch { errorMessage = "Settings could not be fully saved: \(error.localizedDescription)" }
    }

    func saveWatchLayout() { saveSettings() }

    func exportSessions() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShuttlX-sessions.json")
        try Self.encoder.encode(sessions).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportRawData() throws -> URL {
        // Keep session-relative clocks and overlapping windows separate.
        struct Window: Encodable { let shotID: UUID; let samples: [MotionSample] }
        struct Windows: Encodable { let sessionID: UUID; let startedAt: Date; let windows: [Window] }
        let samples = sessions.map { session in
            Windows(sessionID: session.id, startedAt: session.startedAt,
                    windows: session.shots.filter { !$0.samples.isEmpty }.map { Window(shotID: $0.id, samples: $0.samples) })
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShuttlX-motion-windows.json")
        try Self.encoder.encode(samples).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func statistics(for period: AnalyticsPeriod) -> SessionStatistics {
        analysis(for: period).statistics
    }

    func analysis(for period: AnalyticsPeriod) -> AnalysisSummary {
        analysisCache[period] ?? AnalysisEngine.analyze(period.sessions(from: sessions), rallyGap: settings.rallyGap)
    }

    func records() -> [PersonalRecord] { recordsCache }

    func analysis(forSession id: UUID) -> AnalysisSummary {
        AnalysisEngine.analyze(sessions.filter { $0.id == id }, rallyGap: settings.rallyGap)
    }

    private func rebuildAnalysis() {
        analysisCache = Dictionary(uniqueKeysWithValues: AnalyticsPeriod.allCases.map { period in
            (period, AnalysisEngine.analyze(period.sessions(from: sessions), rallyGap: settings.rallyGap))
        })
        recordsCache = RecordService.records(from: sessions, rallyGap: settings.rallyGap)
        updateWidgetSnapshot()
    }

    private func retainingRawData(in source: Session) -> Session {
        guard let days = rawRetentionDays else { return source }
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86_400)
        guard days == 0 || (source.endedAt ?? source.startedAt) < cutoff else { return source }
        var value = source
        for index in value.shots.indices { value.shots[index].samples.removeAll() }
        return value
    }

    private func enforceRetention() throws {
        guard let context else { return }
        let updated = sessions.map(retainingRawData)
        guard updated != sessions else { return }
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        do {
            for row in try context.fetch(FetchDescriptor<SessionDocument>()) {
                if let value = byID[row.id] { row.payload = try Self.encoder.encode(value) }
            }
            try context.save()
        } catch { context.rollback(); throw error }
        sessions = updated
        rebuildAnalysis()
    }

    private func validate(_ value: Session) throws {
        try SessionValidator.validate(value)
        guard !value.isDemo, value.endedAt != nil,
              value.startedAt.timeIntervalSince1970.isFinite,
              value.activeDuration.isFinite, value.activeDuration >= 0,
              (value.endedAt ?? .distantPast) >= value.startedAt,
              value.shots.count <= 100_000,
              Set(value.shots.map(\.id)).count == value.shots.count else {
            throw StoreError.invalid("The session has invalid or duplicate data.")
        }
        for shot in value.shots {
            guard shot.timestamp.isFinite, shot.timestamp >= 0,
                  shot.peakRotation.isFinite, shot.peakRotation >= 0,
                  shot.peakAcceleration.isFinite, shot.peakAcceleration >= 0,
                  shot.duration.isFinite, shot.duration >= 0,
                  shot.samples.count <= 4096,
                  shot.samples.allSatisfy(\.isValid),
                  shot.estimatedSwingSpeed.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw StoreError.invalid("The session contains an invalid motion event.")
            }
        }
    }

    private func updateWidgetSnapshot() {
        let latest = AnalyticsPeriod.latestSession.sessions(from: sessions).first
        let stats = analysisCache[.latestSession]?.statistics ?? .empty
        let attack = stats.tacticalCounts[.attack, default: 0]
        let defence = stats.tacticalCounts[.defence, default: 0]
        let forehand = stats.handCounts[.forehand, default: 0]
        let backhand = stats.handCounts[.backhand, default: 0]
        let knownTactics = stats.totalShots - stats.tacticalCounts[.unknown, default: 0]
        let smash = recordsCache.first { $0.kind == .fastestSmash }
        func ratio(_ numerator: Int, _ denominator: Int) -> Int? {
            denominator > 0 ? Int((Double(numerator) / Double(denominator) * 100).rounded()) : nil
        }
        PhoneWidgetSnapshotStore.save(PhoneWidgetSnapshot(
            updatedAt: latest?.endedAt ?? latest?.startedAt ?? .now,
            attackPercent: ratio(attack, knownTactics),
            defencePercent: ratio(defence, knownTactics),
            forehandPercent: ratio(forehand, forehand + backhand),
            backhandPercent: ratio(backhand, forehand + backhand),
            fastestSmash: smash?.value, fastestSmashDate: smash?.achievedAt, sessionID: latest?.id,
            shotCount: stats.sessionCount > 0 ? stats.totalShots : nil,
            activeDuration: stats.sessionCount > 0 ? stats.duration : nil))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private static func fingerprint(_ session: Session) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(session)).map { String(format: "%02x", $0) }.joined()
    }
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
    enum StoreError: LocalizedError {
        case unavailable, invalid(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Session storage is unavailable. Existing data is preserved."
            case .invalid(let reason): reason
            }
        }
    }
}
