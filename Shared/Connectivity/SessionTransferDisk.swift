import Foundation
import CryptoKit
import ShuttlXCore

struct SessionTransferReceipt: Codable, Sendable, Equatable {
    let version: Int
    let transferID: UUID
    let sessionID: UUID
    let digest: String
}

private struct TransferManifest: Codable, Sendable, Equatable {
    let version: Int
    let kind: String
    let transferID: UUID
    let sessionID: UUID
    let digest: String
    let byteCount: Int
    let partCount: Int
    var receipt: SessionTransferReceipt { .init(version: version, transferID: transferID, sessionID: sessionID, digest: digest) }
    func validate() throws {
        guard version == 1, ["session", "dataset"].contains(kind), transferID == sessionID, byteCount > 0, byteCount <= SessionTransferDisk.maxBytes,
              partCount == (byteCount + SessionTransferDisk.partBytes - 1) / SessionTransferDisk.partBytes,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw TransferFailure.invalidManifest }
    }
}

private struct TransferPacket: Codable, Sendable {
    let manifest: TransferManifest
    let index: Int
    let digest: String
    let payload: Data
}

struct OutgoingSessionFile: Sendable { let url: URL; let key: String }
struct IncomingSession: Sendable { let session: Session; let receipt: SessionTransferReceipt }

enum TransferFailure: LocalizedError {
    case invalidManifest, invalidChunk, identityConflict, oversized, incompleteSession
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "Unsupported or invalid session transfer metadata."
        case .invalidChunk: "A session chunk failed its integrity check."
        case .identityConflict: "Session identity conflicts with an existing saved transfer."
        case .oversized: "The session exceeds the supported transfer size. It remains saved on Watch."
        case .incompleteSession: "Only completed, real sessions can be synchronized."
        }
    }
}

/// Disk and hashing work stays off the UI actor. All names come from decoded UUID/Int values.
actor SessionTransferDisk {
    static let partBytes = 192 * 1024
    static let maxBytes = 128 * 1024 * 1024
    private var issues: [String] = []
    private let root: URL
    private let fm = FileManager.default
    private var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    private var outbox: URL { root.appendingPathComponent("Outbox", isDirectory: true) }
    private var receipts: URL { root.appendingPathComponent("Receipts", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    init(root: URL) { self.root = root }

    private func prepare() throws {
        for folder in [inbox, outbox, receipts, staging] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func folders(_ url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).filter {
            UUID(uuidString: $0.lastPathComponent) != nil && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
    }
    private func savedReceipt(_ sessionID: UUID) throws -> SessionTransferReceipt? {
        let url = receipts.appendingPathComponent(sessionID.uuidString).appendingPathExtension("json")
        return fm.fileExists(atPath: url.path) ? try decode(SessionTransferReceipt.self, url) : nil
    }
    private func manifestURL(_ folder: URL) -> URL { folder.appendingPathComponent("manifest.json") }
    private func packetURL(_ folder: URL, index: Int) -> URL { folder.appendingPathComponent("part-\(index).packet") }

    func enqueue(_ session: Session) throws {
        guard session.endedAt != nil, !session.isDemo else { throw TransferFailure.incompleteSession }
        try SessionValidator.validate(session)
        try enqueuePayload(try encode(session), id: session.id, kind: "session")
    }

    func enqueueDataset(_ data: Data, id: UUID) throws {
        _ = try MotionRecording.decode(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = object["id"] as? String, UUID(uuidString: identifier) == id else {
            throw TransferFailure.identityConflict
        }
        // Re-encoding a saved trace can change JSON key order. Canonical bytes keep
        // retry digests stable across launches and formatting changes.
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try enqueuePayload(canonical, id: id, kind: "dataset")
    }

    private func enqueuePayload(_ data: Data, id: UUID, kind: String) throws {
        try prepare()
        guard data.count <= Self.maxBytes else { throw TransferFailure.oversized }
        let digest = hash(data)
        let manifest = TransferManifest(version: 1, kind: kind, transferID: id, sessionID: id, digest: digest,
                                        byteCount: data.count, partCount: (data.count + Self.partBytes - 1) / Self.partBytes)
        if let receipt = try savedReceipt(id) {
            guard receipt == manifest.receipt else { throw TransferFailure.identityConflict }
            return
        }
        let folder = outbox.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: manifestURL(folder).path) {
            guard try decode(TransferManifest.self, manifestURL(folder)) == manifest else { throw TransferFailure.identityConflict }
        }
        for index in 0..<manifest.partCount {
            let start = index * Self.partBytes
            let payload = data.subdata(in: start..<min(data.count, start + Self.partBytes))
            try write(TransferPacket(manifest: manifest, index: index, digest: hash(payload), payload: payload), to: packetURL(folder, index: index))
        }
        // Commit manifest last: incomplete staging cannot be sent.
        try write(manifest, to: manifestURL(folder))
    }

    func outgoingFiles() throws -> [OutgoingSessionFile] {
        try prepare()
        return try folders(outbox).flatMap { folder -> [OutgoingSessionFile] in
            guard fm.fileExists(atPath: manifestURL(folder).path) else { return [] }
            let manifest = try decode(TransferManifest.self, manifestURL(folder)); try manifest.validate()
            return (0..<manifest.partCount).compactMap { index in
                let url = packetURL(folder, index: index)
                return fm.fileExists(atPath: url.path) ? OutgoingSessionFile(url: url, key: "\(manifest.transferID.uuidString):\(index)") : nil
            }
        }
    }
    func pendingCount() throws -> Int { try prepare(); return try folders(outbox).count }
    func isAcknowledged(_ id: UUID) throws -> Bool { try prepare(); return try savedReceipt(id) != nil }

    func ingestStagedFiles() throws -> [SessionTransferReceipt] {
        try prepare()
        var duplicates: [SessionTransferReceipt] = []
        for url in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.fileSizeKey]) where url.pathExtension == "packet" {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size < Self.partBytes * 2 else { throw TransferFailure.oversized }
                let packet = try decode(TransferPacket.self, url)
                try packet.manifest.validate()
                let manifest = packet.manifest
                guard packet.index >= 0, packet.index < manifest.partCount,
                      packet.payload.count == min(Self.partBytes, manifest.byteCount - packet.index * Self.partBytes),
                      hash(packet.payload) == packet.digest else { throw TransferFailure.invalidChunk }
                if let receipt = try savedReceipt(manifest.sessionID) {
                    guard receipt == manifest.receipt else { throw TransferFailure.identityConflict }
                    duplicates.append(receipt)
                } else {
                    let folder = inbox.appendingPathComponent(manifest.transferID.uuidString, isDirectory: true)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: manifestURL(folder).path) {
                        guard try decode(TransferManifest.self, manifestURL(folder)) == manifest else { throw TransferFailure.identityConflict }
                    } else { try write(manifest, to: manifestURL(folder)) }
                    try write(packet, to: packetURL(folder, index: packet.index))
                }
                try fm.removeItem(at: url)
            } catch {
                handleIncomingFailure(error, at: url)
            }
        }
        return duplicates
    }

    func completedIncoming() throws -> [IncomingSession] {
        try prepare()
        var results: [IncomingSession] = []
        for folder in try folders(inbox) {
            do {
            let manifest = try decode(TransferManifest.self, manifestURL(folder)); try manifest.validate()
            guard manifest.kind == "session" else { continue }
            guard (0..<manifest.partCount).allSatisfy({ fm.fileExists(atPath: packetURL(folder, index: $0).path) }) else { continue }
            var combined = Data(); combined.reserveCapacity(manifest.byteCount)
            // Numeric indexes, never lexicographic filename ordering (part-10 before part-2).
            for index in 0..<manifest.partCount {
                let packet = try decode(TransferPacket.self, packetURL(folder, index: index))
                guard packet.index == index, packet.manifest == manifest, hash(packet.payload) == packet.digest else { throw TransferFailure.invalidChunk }
                combined.append(packet.payload)
            }
            guard combined.count == manifest.byteCount, hash(combined) == manifest.digest else { throw TransferFailure.invalidChunk }
            let session = try JSONDecoder().decode(Session.self, from: combined)
            guard session.id == manifest.sessionID, session.endedAt != nil, !session.isDemo else { throw TransferFailure.identityConflict }
            try SessionValidator.validate(session)
            results.append(IncomingSession(session: session, receipt: manifest.receipt))
            } catch { handleIncomingFailure(error, at: folder) }
        }
        return results
    }

    func receiveCompletedDatasets() throws -> [SessionTransferReceipt] {
        try prepare()
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuttlXDatasets", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var delivered: [SessionTransferReceipt] = []
        for folder in try folders(inbox) {
            do {
            let manifest = try decode(TransferManifest.self, manifestURL(folder)); try manifest.validate()
            guard manifest.kind == "dataset", (0..<manifest.partCount).allSatisfy({ fm.fileExists(atPath: packetURL(folder, index: $0).path) }) else { continue }
            var combined = Data()
            for index in 0..<manifest.partCount {
                let packet = try decode(TransferPacket.self, packetURL(folder, index: index))
                guard packet.index == index, packet.manifest == manifest, hash(packet.payload) == packet.digest else { throw TransferFailure.invalidChunk }
                combined.append(packet.payload)
            }
            guard combined.count == manifest.byteCount, hash(combined) == manifest.digest,
                  let object = try JSONSerialization.jsonObject(with: combined) as? [String: Any],
                  let idString = object["id"] as? String, UUID(uuidString: idString) == manifest.sessionID,
                  object["samples"] is [Any], object["label"] is String else { throw TransferFailure.invalidChunk }
            _ = try MotionRecording.decode(combined)
            try combined.write(to: destination.appendingPathComponent(manifest.sessionID.uuidString).appendingPathExtension("json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try recordReceived(manifest.receipt)
            delivered.append(manifest.receipt)
            } catch { handleIncomingFailure(error, at: folder) }
        }
        return delivered
    }

    func receivedDatasetFiles() throws -> [URL] {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuttlXDatasets", isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else { return [] }
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func takeIssues() -> [String] {
        let result = issues
        issues.removeAll()
        return result
    }

    private func handleIncomingFailure(_ error: Error, at url: URL) {
        let invalid = error is DecodingError || error is TransferFailure || error is SessionValidationError
            || error is MotionRecording.RecordingError
        if invalid {
            do {
                let rejected = root.appendingPathComponent("Rejected", isDirectory: true)
                try fm.createDirectory(at: rejected, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: rejected.appendingPathComponent(UUID().uuidString))
                issues.append("An invalid transfer was isolated. Other sessions can still sync.")
            } catch {
                issues.append("An invalid transfer could not be isolated; it remains saved for retry.")
            }
        } else {
            // File protection, unavailable storage and write failures are retryable.
            // Keep the source at its original location and never acknowledge it.
            issues.append("A transfer remains pending: \(error.localizedDescription)")
        }
        if issues.count > 20 { issues.removeFirst(issues.count - 20) }
    }

    func recordReceived(_ receipt: SessionTransferReceipt) throws {
        try prepare()
        // Called ONLY after the iPhone's async persistence callback succeeds.
        try write(receipt, to: receipts.appendingPathComponent(receipt.sessionID.uuidString).appendingPathExtension("json"))
        let folder = inbox.appendingPathComponent(receipt.transferID.uuidString, isDirectory: true)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
    }

    func acceptAcknowledgement(_ receipt: SessionTransferReceipt) throws {
        try prepare()
        guard receipt.version == 1, receipt.transferID == receipt.sessionID else { throw TransferFailure.invalidManifest }
        let folder = outbox.appendingPathComponent(receipt.transferID.uuidString, isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            guard try savedReceipt(receipt.sessionID) == receipt else { throw TransferFailure.identityConflict }
            return
        }
        let manifest = try decode(TransferManifest.self, manifestURL(folder))
        guard receipt == manifest.receipt else { throw TransferFailure.identityConflict }
        // A small durable receipt prevents a finished Watch session from being requeued on launch.
        try write(receipt, to: receipts.appendingPathComponent(receipt.sessionID.uuidString).appendingPathExtension("json"))
        try fm.removeItem(at: folder)
    }
}
