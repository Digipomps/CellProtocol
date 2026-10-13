import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

final class CorrespondenceAttachmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }
    private func manifest(_ plan: CorrespondenceAttachmentPlan, _ request: CorrespondenceAttachmentRequest,
                          key: Data) -> CorrespondenceAttachment {
        CorrespondenceAttachment(attachmentID: plan.attachmentID, messageID: request.messageID,
            agreementID: request.agreementID, cellID: "cell", senderIdentityUUID: "sender",
            metadata: plan.metadata, mode: plan.mode, reason: plan.reason, reference: plan.reference,
            header: plan.header, contentKey: key)
    }
    private func request() -> CorrespondenceAttachmentRequest {
        CorrespondenceAttachmentRequest(messageID: UUID().uuidString, agreementID: "agreement", senderIdentityUUID: "sender")
    }
    private func copy(_ storage: CorrespondenceAttachmentStorage, bytes: Data) async throws
        -> (CorrespondenceAttachmentRequest, CorrespondenceAttachment, [AttachmentStreamChunk]) {
        let sealed = try AttachmentStreamV1.seal(plaintext: bytes)
        var req = request()
        req.metadata = CorrespondenceAttachmentMetadata(name: "example.bin", mediaType: "application/octet-stream", byteCount: UInt64(bytes.count))
        req.header = sealed.stream.header
        let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "source", now: now)
        req.attachmentID = plan.attachmentID
        for chunk in sealed.stream.chunks { req.chunk = chunk; try await storage.upload(req, now: now) }
        req.chunk = nil
        try await storage.publish(req, expiresAt: now.addingTimeInterval(10), now: now)
        return (req, manifest(plan, req, key: sealed.contentKey.withUnsafeBytes { Data($0) }), sealed.stream.chunks)
    }
    private func download(_ storage: CorrespondenceAttachmentStorage, request: CorrespondenceAttachmentRequest,
                          attachment: CorrespondenceAttachment, to path: URL) async throws {
        let receiver = try CorrespondenceAttachmentFileReceiver(destination: path, attachment: attachment)
        var req = request
        var index: UInt64 = 0
        while true {
            req.index = index
            let chunk = try await storage.fetch(req, recipientKey: "recipient", now: now)
            try receiver.append(chunk)
            if chunk.isFinal { break }
            index += 1
        }
        _ = try receiver.finish()
        try await storage.receipt(request, recipientKey: "recipient", now: now)
    }
    private func fails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }

    func testCopySelectionAndRecipientByteExactRoundTrip() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let bytes = Data((0..<150_007).map { UInt8($0 % 251) })
        let (req, attachment, _) = try await copy(storage, bytes: bytes)
        XCTAssertEqual(attachment.mode, .copy)
        let destination = root.appendingPathComponent("recipient.file")
        try await download(storage, request: req, attachment: attachment, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testReferenceAndFetchOnDemandAreChosenByObservedReachabilityWithoutSendTimeBytes() async throws {
        for reachable in [false, true] {
            let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
            let bytes = Data(repeating: 7, count: 130_003)
            let source = root.appendingPathComponent("source.bin"); try bytes.write(to: source)
            let metadata = CorrespondenceAttachmentMetadata(name: "source.bin", mediaType: "application/octet-stream", byteCount: UInt64(bytes.count))
            try await storage.registerSource(id: "source", file: source, metadata: metadata, retainsStorage: true, referenceURL: reachable ? source : nil)
            if reachable { _ = try await storage.probe(sourceID: "source", recipientKey: "recipient", now: now) }
            var req = request(); req.sourceID = "source"
            let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "cell:///source", now: now)
            req.attachmentID = plan.attachmentID
            XCTAssertEqual(plan.mode, reachable ? .reference : .fetchOnDemand)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sender/" + plan.attachmentID).path)
            XCTAssertTrue(files.isEmpty)
            try await storage.publish(req, expiresAt: now.addingTimeInterval(10), now: now)
            let attachment = manifest(plan, req, key: plan.sourceContentKey ?? Data())
            if reachable {
                let reference = try XCTUnwrap(plan.reference.flatMap(URL.init(string:)))
                XCTAssertEqual(reference, source)
                XCTAssertEqual(try Data(contentsOf: reference), bytes)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sender/" + plan.attachmentID).path).isEmpty)
            } else {
                let destination = root.appendingPathComponent("recipient.file")
                try await download(storage, request: req, attachment: attachment, to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), bytes)
            }
            req.confirmation = CorrespondenceAttachmentTransfer.confirmation
            let transferRequest = req
            await fails { try await storage.transfer(transferRequest, now: self.now) }
        }
    }

    func testNonRetainingSourcePolicySelectsCopy() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let file = root.appendingPathComponent("file"); try Data([1]).write(to: file)
        try await storage.registerSource(id: "source", file: file,
            metadata: .init(name: "file", mediaType: "text/plain", byteCount: 1), retainsStorage: false, referenceURL: file)
        _ = try await storage.probe(sourceID: "source", recipientKey: "recipient", now: now)
        var req = request(); req.sourceID = "source"
        let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "source", now: now)
        XCTAssertEqual(plan.mode, .copy)
    }

    func testMetadataHasNoHashKeyOrChunksAndDoesNotFetch() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root)
        let (req, _, _) = try await copy(storage, bytes: Data([1,2,3]))
        let plan = try await storage.metadata(req, now: now)
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        for forbidden in ["hash", "contentKey", "sourceContentKey", "chunks", "combinedCiphertext"] { XCTAssertFalse(json.contains("\"" + forbidden + "\":"), forbidden) }
        await fails { try await storage.receipt(req, recipientKey: "recipient", now: self.now) }
    }

    func testWrongMessageAndAgreementCannotFetchStream() async throws {
        let storage = CorrespondenceAttachmentStorage(root: try root())
        let (req, attachment, _) = try await copy(storage, bytes: Data([9]))
        for alternate in ["message", "agreement"] {
            var wrong = req; wrong.index = 0
            if alternate == "message" { wrong.messageID = UUID().uuidString }
            else { wrong.agreementID = "another-agreement" }
            let request = wrong
            await fails { _ = try await storage.fetch(request, recipientKey: "recipient", now: self.now) }
            XCTAssertThrowsError(try attachment.validate(messageID: wrong.messageID, agreementID: wrong.agreementID, cellID: "cell", senderIdentityUUID: "sender"))
        }
    }

    func testExpiredAttachmentIsUnavailableAndStoredBytesArePurged() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root)
        let (req, _, _) = try await copy(storage, bytes: Data([9]))
        try await storage.purge(now: now.addingTimeInterval(11))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(req.attachmentID!).path))
        await fails { _ = try await storage.metadata(req, now: self.now.addingTimeInterval(11)) }
    }

    func testInterruptedOrTamperedStreamNeverPublishesHalfFile() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let (_, attachment, chunks) = try await copy(storage, bytes: Data(repeating: 1, count: 65_540))
        for tamper in [false, true] {
            let path = root.appendingPathComponent(UUID().uuidString)
            let receiver = try CorrespondenceAttachmentFileReceiver(destination: path, attachment: attachment)
            if tamper {
                var chunk = chunks[0]; chunk.combinedCiphertext[15] ^= 1
                XCTAssertThrowsError(try receiver.append(chunk))
            } else {
                try receiver.append(chunks[0]); XCTAssertThrowsError(try receiver.finish())
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiver.temporaryURL.path))
        }
    }

    func testFullDestinationDiskReturnsErrorAndRemovesPartialFile() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let (_, attachment, chunks) = try await copy(storage, bytes: Data(repeating: 1, count: 131_079))
        var writes = 0
        let path = root.appendingPathComponent("recipient.file")
        let receiver = try CorrespondenceAttachmentFileReceiver(destination: path, attachment: attachment) { handle, bytes in
            writes += 1
            if writes == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            try handle.write(contentsOf: bytes)
        }
        try receiver.append(chunks[0]); XCTAssertThrowsError(try receiver.append(chunks[1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiver.temporaryURL.path))
    }

    func testTransferRequiresDownloadAndExplicitOwnerConsequenceThenSurvivesExpiry() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let (initial, attachment, _) = try await copy(storage, bytes: Data([1,2,3]))
        var req = initial; req.confirmation = CorrespondenceAttachmentTransfer.confirmation
        let confirmed = req
        await fails { try await storage.transfer(confirmed, now: self.now) }
        let path = root.appendingPathComponent("recipient.file")
        try await download(storage, request: initial, attachment: attachment, to: path)
        await fails { try await storage.transfer(initial, now: self.now) }
        try await storage.transfer(confirmed, now: now)
        await fails { try await storage.acceptTransfer(initial, recipientKey: "other", now: self.now) }
        try await storage.acceptTransfer(initial, recipientKey: "recipient", now: now)
        try await storage.purge(now: now.addingTimeInterval(11))
        let status = try await storage.status(initial, now: now.addingTimeInterval(11))
        XCTAssertTrue(status.1)
        XCTAssertEqual(try Data(contentsOf: path), Data([1,2,3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sender/" + attachment.attachmentID).path))
        await fails { try await storage.revoke(initial, now: self.now) }
    }
}

extension CorrespondenceAttachmentTests {
    func testFullSenderDiskRevokesAndRemovesPartialImport() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root)
        let sealed = try AttachmentStreamV1.seal(plaintext: Data(repeating: 2, count: 140_000))
        var req = request(); req.metadata = .init(name: "file", mediaType: "application/test", byteCount: 140_000)
        req.header = sealed.stream.header
        let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "unused", now: now)
        req.attachmentID = plan.attachmentID
        req.chunk = sealed.stream.chunks[0]
        try await storage.upload(req, now: now)
        await storage.setWriterForTesting { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        req.chunk = sealed.stream.chunks[1]
        let failedRequest = req
        await fails { try await storage.upload(failedRequest, now: self.now) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(plan.attachmentID).path))
        await fails { try await storage.publish(failedRequest, expiresAt: self.now.addingTimeInterval(10), now: self.now) }
    }

    func testMissingFinalChunkCannotPublishAndRestartKeepsCompleteCopy() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root)
        let sealed = try AttachmentStreamV1.seal(plaintext: Data([1,2,3]))
        var req = request(); req.metadata = .init(name: "file", mediaType: "text/plain", byteCount: 3)
        req.header = sealed.stream.header
        let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "unused", now: now)
        req.attachmentID = plan.attachmentID; req.chunk = sealed.stream.chunks[0]
        try await storage.upload(req, now: now)
        let unfinished = req
        await fails { try await storage.publish(unfinished, expiresAt: self.now.addingTimeInterval(10), now: self.now) }
        req.chunk = sealed.stream.chunks[1]; try await storage.upload(req, now: now); req.chunk = nil
        try await storage.publish(req, expiresAt: now.addingTimeInterval(10), now: now)
        let restored = CorrespondenceAttachmentStorage(root: root)
        let attachment = manifest(plan, req, key: sealed.contentKey.withUnsafeBytes { Data($0) })
        let destination = root.appendingPathComponent("restored.file")
        try await download(restored, request: req, attachment: attachment, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1,2,3]))
    }

    func testReceiverRejectsExtraChunkAndWrongSignedSize() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let (_, attachment, chunks) = try await copy(storage, bytes: Data([7,8]))
        let path = root.appendingPathComponent("extra.file")
        let receiver = try CorrespondenceAttachmentFileReceiver(destination: path, attachment: attachment)
        for chunk in chunks { try receiver.append(chunk) }
        XCTAssertThrowsError(try receiver.append(chunks[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        var incorrect = attachment; incorrect.metadata.byteCount = 3
        let other = try CorrespondenceAttachmentFileReceiver(destination: path, attachment: incorrect)
        for chunk in chunks { try other.append(chunk) }
        XCTAssertThrowsError(try other.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testUnfinishedSourceStreamAfterRestartFailsClosedAndStaleProbeDoesNotSelectReference() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let file = root.appendingPathComponent("file"); try Data([1]).write(to: file)
        try await storage.registerSource(id: "source", file: file,
            metadata: .init(name: "file", mediaType: "text/plain", byteCount: 1), retainsStorage: true, referenceURL: file)
        _ = try await storage.probe(sourceID: "source", recipientKey: "recipient", now: now.addingTimeInterval(-301))
        var req = request(); req.sourceID = "source"
        let plan = try await storage.prepare(req, recipientKeys: ["recipient"], reference: "source", now: now)
        XCTAssertEqual(plan.mode, .fetchOnDemand)
        req.attachmentID = plan.attachmentID
        try await storage.publish(req, expiresAt: now.addingTimeInterval(10), now: now)
        req.index = 0
        let restored = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let request = req
        await fails { _ = try await restored.fetch(request, recipientKey: "recipient", now: self.now) }
    }
}


extension CorrespondenceAttachmentTests {
    func testFailedTransferStateWriteDoesNotClaimOwnershipOrDeleteSenderCopy() async throws {
        let root = try root(); let storage = CorrespondenceAttachmentStorage(root: root.appendingPathComponent("sender"))
        let (initial, attachment, _) = try await copy(storage, bytes: Data([1,2,3]))
        try await download(storage, request: initial, attachment: attachment, to: root.appendingPathComponent("recipient.file"))
        var offer = initial; offer.confirmation = CorrespondenceAttachmentTransfer.confirmation
        try await storage.transfer(offer, now: now)
        await storage.setIndexWriterForTesting { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        await fails { try await storage.acceptTransfer(initial, recipientKey: "recipient", now: self.now) }
        let status = try await storage.status(initial, now: now)
        XCTAssertFalse(status.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sender/" + attachment.attachmentID).path))
    }
}
