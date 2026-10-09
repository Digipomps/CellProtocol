// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CorrespondenceAttachmentMode: String, Codable, Sendable {
    case reference, fetchOnDemand, copy
}

/// Safe to display before fetching. No content hash, key or local path.
public struct CorrespondenceAttachmentMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var mediaType: String
    public var byteCount: UInt64
    public init(name: String, mediaType: String, byteCount: UInt64) {
        self.name = name; self.mediaType = mediaType; self.byteCount = byteCount
    }
}

/// Signed as part of CorrespondenceInnerEnvelope, then encrypted for members.
public struct CorrespondenceAttachment: Codable, Equatable, Sendable {
    public var attachmentID: String
    public var messageID: String
    public var agreementID: String
    public var cellID: String
    public var senderIdentityUUID: String
    public var metadata: CorrespondenceAttachmentMetadata
    public var mode: CorrespondenceAttachmentMode
    public var reason: String
    public var reference: String?
    public var header: AttachmentStreamHeader
    public var contentKey: Data

    public init(attachmentID: String, messageID: String, agreementID: String,
                cellID: String, senderIdentityUUID: String,
                metadata: CorrespondenceAttachmentMetadata, mode: CorrespondenceAttachmentMode,
                reason: String, reference: String? = nil,
                header: AttachmentStreamHeader, contentKey: Data) {
        self.attachmentID = attachmentID; self.messageID = messageID
        self.agreementID = agreementID; self.cellID = cellID
        self.senderIdentityUUID = senderIdentityUUID; self.metadata = metadata
        self.mode = mode; self.reason = reason; self.reference = reference
        self.header = header; self.contentKey = contentKey
    }

    public func validate(messageID: String, agreementID: String, cellID: String,
                         senderIdentityUUID: String) throws {
        guard self.messageID == messageID, self.agreementID == agreementID,
              self.cellID == cellID, self.senderIdentityUUID == senderIdentityUUID,
              UUID(uuidString: attachmentID) != nil,
              mode == .reference ? (reference != nil && contentKey.isEmpty) : contentKey.count == 32 else {
            throw CorrespondenceAttachmentError.contextMismatch
        }
    }
}

public enum CorrespondenceAttachmentError: Error, Equatable, LocalizedError {
    case contextMismatch, unavailable, expired, incomplete, sizeMismatch
    case wrongSender, wrongRecipient, transferNotOffered, recipientHasNotFetched
    case confirmationRequired, storageFailure(String), cleanupFailure(String)
    public var errorDescription: String? {
        switch self {
        case .contextMismatch: return "Attachment is bound to another message, agreement, Cell or sender."
        case .unavailable: return "Attachment/source is unavailable or was revoked."
        case .expired: return "Attachment expired with its message."
        case .incomplete: return "Transfer is incomplete; no complete file was published."
        case .sizeMismatch: return "Received size differs from the signed metadata."
        case .wrongSender: return "Only the original sender may perform this action."
        case .wrongRecipient: return "Only the intended recipient may perform this action."
        case .transferNotOffered: return "Ownership transfer is available only in copy mode."
        case .recipientHasNotFetched: return "The recipient must finish and verify the download first."
        case .confirmationRequired: return "Explicit consequence confirmation or an existing owner policy is required."
        case .storageFailure: return "attachmentStorageFailed"
        case .cleanupFailure: return "attachmentCleanupFailed"
        }
    }
}

/// Bounded-memory destination. An incomplete file never has the final name.
/// The destination must be inside the application's managed retention storage.
public final class CorrespondenceAttachmentFileReceiver {
    public let destination: URL
    public let temporaryURL: URL
    private let opener: AttachmentStreamOpener
    private let expectedSize: UInt64
    private let handle: FileHandle
    private let writeChunk: (FileHandle, Data) throws -> Void
    private var received: UInt64 = 0
    private var closed = false

    public init(destination: URL, attachment: CorrespondenceAttachment,
                writeChunk: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        self.destination = destination
        temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        expectedSize = attachment.metadata.byteCount
        opener = try AttachmentStreamOpener(header: attachment.header,
            contentKey: SymmetricKey(data: attachment.contentKey))
        self.writeChunk = writeChunk
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CorrespondenceAttachmentError.storageFailure("Destination already exists")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw CorrespondenceAttachmentError.storageFailure("Cannot create partial file")
        }
        handle = try FileHandle(forWritingTo: temporaryURL)
    }

    public func append(_ chunk: AttachmentStreamChunk) throws {
        guard !closed else { throw CorrespondenceAttachmentError.incomplete }
        do {
            let bytes = try opener.append(chunk)
            let sum = received.addingReportingOverflow(UInt64(bytes.count))
            guard !sum.overflow, sum.partialValue <= expectedSize else {
                throw CorrespondenceAttachmentError.sizeMismatch
            }
            try writeChunk(handle, bytes)
            received = sum.partialValue
        } catch { try abort(); throw error }
    }

    public func finish() throws -> URL {
        guard !closed else { throw CorrespondenceAttachmentError.incomplete }
        do {
            try opener.finish()
            guard received == expectedSize else { throw CorrespondenceAttachmentError.sizeMismatch }
            try handle.synchronize()
            try handle.close()
            // moveItem does not replace an existing destination.
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            closed = true
            return destination
        } catch { try abort(); throw error }
    }

    public func abort() throws {
        guard !closed else { return }
        closed = true
        var failures: [String] = []
        do { try handle.close() } catch { failures.append(error.localizedDescription) }
        do { try FileManager.default.removeItem(at: temporaryURL) }
        catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw CorrespondenceAttachmentError.cleanupFailure(failures.joined(separator: "; ")) }
    }

    deinit {
        // Explicit error paths call abort() and report cleanup failure. This is
        // only a last-resort cleanup if an enclosing Task drops its receiver.
        if !closed { try? handle.close(); try? FileManager.default.removeItem(at: temporaryURL) }
    }
}
