// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class CorrespondencePrivacyRegressionTests: XCTestCase {
    private func request() -> CorrespondenceAttachmentRequest {
        .init(messageID: UUID().uuidString, agreementID: UUID().uuidString,
              senderIdentityUUID: UUID().uuidString,
              metadata: .init(name: "synthetic-private.bin", mediaType: "application/octet-stream", byteCount: 1),
              header: AttachmentStreamHeader())
    }
    func testWireAndDurableMetadataExcludeFilename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CorrespondenceAttachmentStorage(root: root)
        let req = request()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(req), as: UTF8.self).contains("synthetic-private.bin"))
        let plan = try await storage.prepare(req, recipientKeys: ["synthetic-recipient"], reference: "unused", now: Date())
        XCTAssertEqual(plan.metadata.name, "")
        let index = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(index.contains("synthetic-private.bin"))
        XCTAssertFalse(index.contains(root.path))
    }
    func testLocalSourcesAreNotPersistedOnHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic-private-source.bin")
        try Data([1]).write(to: file)
        let storage = CorrespondenceAttachmentStorage(root: root)
        try await storage.registerSource(id: "synthetic-source", file: file,
            metadata: .init(name: file.lastPathComponent, mediaType: "application/octet-stream", byteCount: 1),
            retainsStorage: true, referenceURL: file)
        let index = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(index.contains(file.lastPathComponent))
        XCTAssertFalse(index.contains("file:"))
        XCTAssertFalse(index.contains("referenceURL"))
    }
    func testCleanupContinuesAfterOneFailureAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CorrespondenceAttachmentStorage(root: root), now = Date()
        let first = try await storage.prepare(request(), recipientKeys: ["synthetic"], reference: "unused", now: now)
        let second = try await storage.prepare(request(), recipientKeys: ["synthetic"], reference: "unused", now: now)
        await storage.setEraserForTesting { url in
            if url.lastPathComponent == first.attachmentID { throw CorrespondenceAttachmentError.cleanupFailure("synthetic") }
            try FileManager.default.removeItem(at: url)
        }
        do { try await storage.purge(now: now.addingTimeInterval(3601)); XCTFail("Expected one cleanup failure") }
        catch { XCTAssertEqual(error as? CorrespondenceAttachmentError, .cleanupFailure("cleanupFailed")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.attachmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.attachmentID).path))
        await storage.setEraserForTesting { try FileManager.default.removeItem(at: $0) }
        try await storage.purge(now: now.addingTimeInterval(3601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.attachmentID).path))
    }
    func testStorageErrorsHaveFixedDescriptions() {
        XCTAssertEqual(CorrespondenceAttachmentError.storageFailure("synthetic/private/location").errorDescription, "attachmentStorageFailed")
        XCTAssertEqual(CorrespondenceAttachmentError.cleanupFailure("synthetic/private/location").errorDescription, "attachmentCleanupFailed")
    }
    func testLegacyIndexIsRedactedWhenLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CorrespondenceAttachmentStorage(root: root), now = Date()
        let plan = try await storage.prepare(request(), recipientKeys: ["synthetic"], reference: "unused", now: now)
        let index = root.appendingPathComponent("state.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var entries = try XCTUnwrap(document["entries"] as? [String: Any])
        var entry = try XCTUnwrap(entries[plan.attachmentID] as? [String: Any])
        var legacyPlan = try XCTUnwrap(entry["plan"] as? [String: Any])
        var metadata = try XCTUnwrap(legacyPlan["metadata"] as? [String: Any])
        metadata["name"] = "synthetic-legacy-private-name"
        legacyPlan["metadata"] = metadata
        legacyPlan["reference"] = "file:///synthetic/private/source"
        entry["plan"] = legacyPlan
        entries[plan.attachmentID] = entry
        document["entries"] = entries
        document["sources"] = ["legacy": ["file": "file:///synthetic/private/source"]]
        try JSONSerialization.data(withJSONObject: document).write(to: index)
        let restored = CorrespondenceAttachmentStorage(root: root)
        try await restored.purge(now: now)
        let rewritten = try String(contentsOf: index, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("synthetic-legacy-private-name"))
        XCTAssertFalse(rewritten.contains("file:"))
        XCTAssertFalse(rewritten.contains("sources"))
    }

}
