import Foundation
import XCTest
import ShuttlXCore
@testable import Transport

final class TransferDiskTests: XCTestCase {
    func testDatasetRetryIgnoresJSONFormattingAndKeyOrder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SessionTransferDisk(root: root)
        let id = UUID()
        let object: [String: Any] = [
            "id": id.uuidString, "label": "smash", "source": "Test recording",
            "samples": [["timestamp": 0, "acceleration": ["x": 0, "y": 0, "z": 0], "rotation": ["x": 0, "y": 0, "z": 0]]]
        ]
        let compact = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try await sender.enqueueDataset(compact, id: id)
        try await sender.enqueueDataset(pretty, id: id)
        let pending = try await sender.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShuttlX-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func session(name: String = "Recorded session") -> Session {
        Session(startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_060),
                activeDuration: 60, name: name, shots: [ShotEvent(timestamp: 1)])
    }
    private func stage(_ files: [OutgoingSessionFile], root: URL) throws {
        let staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.copyItem(at: file.url, to: staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("packet"))
        }
    }

    func testReorderedMultiPartSessionAndDurableAcknowledgement() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SessionTransferDisk(root: root.appendingPathComponent("sender"))
        let receiverRoot = root.appendingPathComponent("receiver")
        let receiver = SessionTransferDisk(root: receiverRoot)
        let original = session(name: String(repeating: "Large transfer fixture ", count: 120_000))
        try await sender.enqueue(original)
        let files = try await sender.outgoingFiles()
        XCTAssertGreaterThan(files.count, 10)
        try stage(Array(files.reversed()), root: receiverRoot)
        _ = try await receiver.ingestStagedFiles()
        let incoming = try await receiver.completedIncoming()
        XCTAssertEqual(incoming.count, 1)
        XCTAssertEqual(incoming.first?.session, original)
        let beforeAck = try await sender.pendingCount()
        XCTAssertEqual(beforeAck, 1)
        let receipt = try XCTUnwrap(incoming.first?.receipt)
        try await receiver.recordReceived(receipt)
        try await sender.acceptAcknowledgement(receipt)
        try await sender.acceptAcknowledgement(receipt)
        try await sender.enqueue(original)
        let afterAck = try await sender.pendingCount()
        XCTAssertEqual(afterAck, 0)
    }

    func testPartialTransferNeverCompletesAndDuplicateChunksAreSafe() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SessionTransferDisk(root: root.appendingPathComponent("sender"))
        let receiverRoot = root.appendingPathComponent("receiver")
        let receiver = SessionTransferDisk(root: receiverRoot)
        try await sender.enqueue(session(name: String(repeating: "x", count: 500_000)))
        let files = try await sender.outgoingFiles()
        try stage([files[0], files[0]], root: receiverRoot)
        _ = try await receiver.ingestStagedFiles()
        let partial = try await receiver.completedIncoming()
        XCTAssertTrue(partial.isEmpty)
        try stage(Array(files.dropFirst()), root: receiverRoot)
        _ = try await receiver.ingestStagedFiles()
        let complete = try await receiver.completedIncoming()
        XCTAssertEqual(complete.count, 1)
    }

    func testMalformedPacketDoesNotBlockHealthySession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SessionTransferDisk(root: root.appendingPathComponent("sender"))
        let receiverRoot = root.appendingPathComponent("receiver")
        let receiver = SessionTransferDisk(root: receiverRoot)
        let original = session()
        try await sender.enqueue(original)
        try stage(try await sender.outgoingFiles(), root: receiverRoot)
        try Data("not JSON".utf8).write(to: receiverRoot.appendingPathComponent("Staging/broken.packet"))
        _ = try await receiver.ingestStagedFiles()
        let incoming = try await receiver.completedIncoming()
        let issues = await receiver.takeIssues()
        XCTAssertEqual(incoming.first?.session.id, original.id)
        XCTAssertFalse(issues.isEmpty)
    }

    func testConflictingIdentityDoesNotReplaceOutbox() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SessionTransferDisk(root: root)
        let original = session()
        try await sender.enqueue(original)
        var changed = original
        changed.name = "Different content"
        do {
            try await sender.enqueue(changed)
            XCTFail("Conflicting immutable session should be rejected")
        } catch TransferFailure.identityConflict {}
        let pending = try await sender.pendingCount()
        XCTAssertEqual(pending, 1)
    }
}
