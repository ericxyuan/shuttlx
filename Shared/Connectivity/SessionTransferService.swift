import Foundation
import Observation
import ShuttlXCore
@preconcurrency import WatchConnectivity

public struct WatchDeviceStatus: Codable, Sendable, Equatable {
    public var modelName: String
    public var systemVersion: String
    public var batteryLevel: Double?
    public var motionAvailable: Bool
    public var requestedSampleRateHz: Double?
    public var measuredSampleRateHz: Double?
    public var trackingStatus: String
    public var reportedAt: Date
    public init(modelName: String, systemVersion: String, batteryLevel: Double? = nil, motionAvailable: Bool,
                requestedSampleRateHz: Double? = nil, measuredSampleRateHz: Double? = nil,
                trackingStatus: String, reportedAt: Date = .now) {
        self.modelName = modelName; self.systemVersion = systemVersion; self.batteryLevel = batteryLevel
        self.motionAvailable = motionAvailable; self.requestedSampleRateHz = requestedSampleRateHz
        self.measuredSampleRateHz = measuredSampleRateHz; self.trackingStatus = trackingStatus; self.reportedAt = reportedAt
    }
}

private struct WatchConfiguration: Codable, Sendable {
    var settings: TrackingSettings
    var layout: WatchLayout
}

/// Own one instance in each app. Install the persistence callback BEFORE activate().
@MainActor @Observable public final class SessionTransferService: NSObject, WCSessionDelegate {
    public private(set) var settings: TrackingSettings
    public private(set) var layout: WatchLayout
    public private(set) var isPaired = false
    public private(set) var isAppInstalled = false
    public private(set) var isReachable = false
    public private(set) var deviceStatus: WatchDeviceStatus?
    public private(set) var lastError: String?
    public private(set) var syncState = "Not connected"
    public private(set) var pendingTransferCount = 0
    @ObservationIgnored public var onReceiveSession: ((Session) async throws -> Void)? {
        didSet { if onReceiveSession != nil { retryPendingTransfers() } }
    }
    @ObservationIgnored public var onConfigurationReceived: ((TrackingSettings, WatchLayout) -> Void)?
    @ObservationIgnored public var onStatusReceived: ((WatchDeviceStatus) -> Void)?
    @ObservationIgnored public var onLayoutReceived: ((WatchLayout) -> Void)?
    @ObservationIgnored public var onAcknowledged: ((UUID) async throws -> Void)?
    @ObservationIgnored public var onWebCredentialReceived: ((URL, UUID, String) -> Void)?
    @ObservationIgnored private let connection: WCSession
    @ObservationIgnored private let disk: SessionTransferDisk
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private var activated = false
    // URL is immutable/sendable, so the delegate can move an ephemeral received file synchronously.
    nonisolated private let stagingURL: URL
    public var modelName: String? { deviceStatus?.modelName }
    public var batteryLevel: Double? { deviceStatus?.batteryLevel }
    public var trackingStatus: String { deviceStatus?.trackingStatus ?? "Awaiting Watch report" }

    public init(session: WCSession = .default, settings: TrackingSettings = .init(), layout: WatchLayout = .init()) {
        connection = session
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuttlX/Transfer", isDirectory: true)
        stagingURL = root.appendingPathComponent("Staging", isDirectory: true)
        disk = SessionTransferDisk(root: root)
        #if os(watchOS)
        let saved = UserDefaults.standard.data(forKey: "watch-configuration-v1")
            .flatMap { try? JSONDecoder().decode(WatchConfiguration.self, from: $0) }
        self.settings = saved?.settings.validated() ?? settings.validated()
        self.layout = saved?.layout ?? layout
        #else
        self.settings = settings.validated(); self.layout = layout
        #endif
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { syncState = "WatchConnectivity unavailable"; return }
        guard !activated else { retryPendingTransfers(); return }
        activated = true
        connection.delegate = self
        connection.activate()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                self.retryPendingTransfers()
            }
        }
    }

    public func refreshStatus() {
        #if os(iOS)
        isPaired = connection.isPaired
        isAppInstalled = connection.isWatchAppInstalled
        #else
        isPaired = connection.activationState == .activated
        isAppInstalled = connection.isCompanionAppInstalled
        #endif
        isReachable = connection.isReachable
        if !isPaired { syncState = "No paired device available" }
        else if !isAppInstalled { syncState = "Install ShuttlX on the paired device" }
        else if pendingTransferCount > 0 { syncState = "Sessions waiting for confirmation" }
        else { syncState = isReachable ? "Connected" : "Available for background sync" }
    }

    public func configure(settings: TrackingSettings, layout: WatchLayout) throws {
        let value = WatchConfiguration(settings: settings.validated(), layout: layout)
        let data = try JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: "watch-configuration-v1")
        self.settings = value.settings; self.layout = value.layout
        if connection.activationState == .activated {
            try connection.updateApplicationContext(["version": 1, "configuration": data])
        }
    }

    public func sendWatchLayout(_ layout: WatchLayout) throws {
        #if os(watchOS)
        let data = try JSONEncoder().encode(layout)
        connection.transferUserInfo(["kind": "shuttlx-layout-v1", "layout": data])
        #endif
    }

    #if os(iOS)
    public func sendWebCredential(baseURL: URL, deviceID: UUID, token: String) {
        guard connection.activationState == .activated else { lastError = "WatchConnectivity is still activating."; return }
        guard connection.isPaired, connection.isWatchAppInstalled else { lastError = "Install ShuttlX on the paired Watch first."; return }
        let message: [String: Any] = ["kind": "shuttlx-website-pair-v1", "baseURL": baseURL.absoluteString, "deviceID": deviceID.uuidString, "token": token]
        connection.sendMessage(message, replyHandler: nil) { [weak self] error in
            Task { @MainActor in self?.lastError = "The Watch could not receive its website pairing: \(error.localizedDescription)" }
        }
    }
    #endif

    public func enqueue(_ session: Session) async throws {
        try await disk.enqueue(session)
        let acknowledged = try await disk.isAcknowledged(session.id)
        if acknowledged { try await onAcknowledged?(session.id) }
        retryPendingTransfers()
    }

    public func enqueueDataset(_ data: Data, id: UUID) async throws {
        try await disk.enqueueDataset(data, id: id)
        let acknowledged = try await disk.isAcknowledged(id)
        if acknowledged { try await onAcknowledged?(id) }
        retryPendingTransfers()
    }

    public func receivedDatasetFiles() async throws -> [URL] {
        try await disk.receivedDatasetFiles()
    }

    public func publishStatus(_ status: WatchDeviceStatus) throws {
        deviceStatus = status
        let data = try JSONEncoder().encode(status)
        UserDefaults.standard.set(data, forKey: "watch-status-v1")
        if connection.activationState == .activated {
            // Context coalesces battery/status updates; no queue of stale telemetry.
            try connection.updateApplicationContext(["version": 1, "status": data])
        }
    }

    public func retryPendingTransfers() {
        guard activated, connection.activationState == .activated else { return }
        if pumping { pumpAgain = true; return }
        pumping = true
        Task {
            defer {
                pumping = false
                if pumpAgain { pumpAgain = false; retryPendingTransfers() }
            }
            do {
                var persistenceErrors: [String] = []
                let duplicateReceipts = try await disk.ingestStagedFiles()
                for receipt in duplicateReceipts { acknowledge(receipt) }
                let datasetReceipts = try await disk.receiveCompletedDatasets()
                for receipt in datasetReceipts { acknowledge(receipt) }
                if let persist = onReceiveSession {
                    let completed = try await disk.completedIncoming()
                    for incoming in completed {
                        // A nil callback NEVER acknowledges/discards a session.
                        do {
                            try await persist(incoming.session)
                            try await disk.recordReceived(incoming.receipt)
                            acknowledge(incoming.receipt)
                        } catch {
                            persistenceErrors.append("A session remains pending: \(error.localizedDescription)")
                        }
                    }
                }
                let files = try await disk.outgoingFiles()
                let inFlight = Set(connection.outstandingFileTransfers.compactMap { $0.file.metadata?["partKey"] as? String })
                for file in files where !inFlight.contains(file.key) {
                    connection.transferFile(file.url, metadata: ["kind": "shuttlx-session-v1", "partKey": file.key])
                }
                pendingTransferCount = try await disk.pendingCount()
                refreshStatus()
                let diskIssues = await disk.takeIssues()
                let errors = persistenceErrors + diskIssues
                lastError = errors.isEmpty ? nil : errors.prefix(3).joined(separator: "\n")
                if !errors.isEmpty { syncState = "Some transfers need attention" }
            } catch {
                lastError = "Sync will retry: \(error.localizedDescription)"
                syncState = "Saved locally · sync pending"
            }
        }
    }

    private func acknowledge(_ receipt: SessionTransferReceipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        connection.transferUserInfo(["kind": "shuttlx-ack-v1", "receipt": data])
    }

    private func applyContext(configuration: Data?, status: Data?) {
        do {
            #if os(watchOS)
            if let configuration {
                let value = try JSONDecoder().decode(WatchConfiguration.self, from: configuration)
                settings = value.settings.validated(); layout = value.layout
                UserDefaults.standard.set(configuration, forKey: "watch-configuration-v1")
                onConfigurationReceived?(settings, layout)
            }
            #else
            if let status {
                let value = try JSONDecoder().decode(WatchDeviceStatus.self, from: status)
                deviceStatus = value; onStatusReceived?(value)
            }
            #endif
        } catch { lastError = "The paired app sent an unreadable configuration or status." }
    }

    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let description = error?.localizedDescription
        let config = session.receivedApplicationContext["configuration"] as? Data
        let status = session.receivedApplicationContext["status"] as? Data
        Task { @MainActor in
            self.lastError = description
            self.applyContext(configuration: config, status: status)
            self.refreshStatus()
            #if os(iOS)
            do { try self.configure(settings: self.settings, layout: self.layout) } catch { self.lastError = error.localizedDescription }
            #else
            if let status = self.deviceStatus { try? self.publishStatus(status) }
            #endif
            self.retryPendingTransfers()
        }
    }
    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) { Task { @MainActor in self.refreshStatus() } }
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.refreshStatus(); self.retryPendingTransfers() } }
    #endif
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.refreshStatus(); self.retryPendingTransfers() } }
    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard applicationContext["version"] as? Int == 1 else { return }
        let config = applicationContext["configuration"] as? Data
        let status = applicationContext["status"] as? Data
        Task { @MainActor in self.applyContext(configuration: config, status: status) }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["kind"] as? String == "shuttlx-website-pair-v1",
              let baseString = message["baseURL"] as? String,
              let baseURL = URL(string: baseString),
              let deviceString = message["deviceID"] as? String,
              let deviceID = UUID(uuidString: deviceString),
              let token = message["token"] as? String else { return }
        Task { @MainActor in self.onWebCredentialReceived?(baseURL, deviceID, token) }
    }
    nonisolated public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "shuttlx-session-v1" else { return }
        do {
            try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            // Apple deletes the original after this delegate returns. Move NOW, never in Task.
            let destination = stagingURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("packet")
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            Task { @MainActor in self.retryPendingTransfers() }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = "Could not preserve incoming session: \(message)" }
        }
    }
    nonisolated public func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { self.lastError = "Background transfer will retry: \(message)" }
            // File delivery is NOT persistence acknowledgement. Keep the outbox until receipt.
        }
    }
    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        #if os(iOS)
        if userInfo["kind"] as? String == "shuttlx-layout-v1", let data = userInfo["layout"] as? Data {
            Task { @MainActor in
                do {
                    let layout = try JSONDecoder().decode(WatchLayout.self, from: data)
                    self.onLayoutReceived?(layout)
                } catch { self.lastError = "The Watch layout could not be read." }
            }
            return
        }
        #endif
        guard userInfo["kind"] as? String == "shuttlx-ack-v1", let data = userInfo["receipt"] as? Data else { return }
        Task { @MainActor in
            do {
                let receipt = try JSONDecoder().decode(SessionTransferReceipt.self, from: data)
                try await self.disk.acceptAcknowledgement(receipt)
                try await self.onAcknowledged?(receipt.sessionID)
                self.pendingTransferCount = try await self.disk.pendingCount()
                self.refreshStatus()
            } catch { self.lastError = "Sync confirmation was rejected: \(error.localizedDescription)" }
        }
    }
}
