// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One combined owner/cell-bound authority: canonical motor journal + accepted
/// original feedback + routing revision. No resolver-save Bool is a receipt.
struct PerspectiveRoutingStore {
    typealias Factory = @Sendable (URL) -> any EntityAuthorityReplicaPersistence
    let ownerUUID: String
    let cellUUID: String
    var factory: Factory = { AtomicFileEntityAuthorityReplicaPersistence(fileURL: $0) }
    private var binding: String { "perspective-routing.v1|\(ownerUUID.utf8.count):\(ownerUUID)\(cellUUID.utf8.count):\(cellUUID)" }
    private func fileURL() throws -> URL {
        guard let root = CellBase.documentRootPath, !root.isEmpty else { throw PerspectiveRoutingError.unavailable("private document root required") }
        var path = try CellStoragePathPolicy.component("PerspectiveLearning", under: URL(fileURLWithPath: root))
        path = try CellStoragePathPolicy.component(ownerUUID, under: path)
        path = try CellStoragePathPolicy.component(cellUUID, under: path)
        return try CellStoragePathPolicy.filename("routing.enc", under: path)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let directory = try fileURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("routing.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw PerspectiveRoutingError.unavailable("private transaction lock unavailable") }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PerspectiveRoutingError.unavailable("private transaction lock unavailable") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func read() throws -> PerspectiveRoutingDocument? {
        guard let encrypted = try factory(fileURL()).load() else { return nil }
        guard encrypted.count <= 8*1024*1024, CellPersistenceCrypto.isEncryptedEnvelope(encrypted) else { throw PerspectiveRoutingError.unavailable("invalid encrypted routing authority") }
        let bytes = try CellPersistenceCrypto.decodeFromStorage(stored: encrypted, uuid: binding)
        let document = try JSONDecoder().decode(PerspectiveRoutingDocument.self, from: bytes)
        guard document.schema == 1, document.ownerUUID == ownerUUID, document.cellUUID == cellUUID,
              document.revision >= 0, document.accepted.count <= 2048 else { throw PerspectiveRoutingError.unavailable("routing authority binding mismatch") }
        try document.motorJournal.validateShapeAndSize()
        try Self.validateFeedbackBinding(document)
        return document
    }
    /// Counters are derived only from the exact accepted originals in this
    /// authority's motor journal. Encryption alone is not internal consistency.
    static func validateFeedbackBinding(_ document: PerspectiveRoutingDocument) throws {
        let originals = document.motorJournal.records.filter { $0.envelope.eventType == .userFeedback }
        guard originals.count == document.accepted.count else { throw PerspectiveRoutingError.unavailable("routing feedback journal mismatch") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var seen = Set<String>()
        for record in originals {
            let event = try RelationalLearningCodec.decode(RelationalUserFeedbackEvent.self, from: record.envelope.payload)
            guard seen.insert(event.eventId).inserted, let accepted = document.accepted[event.eventId],
                  accepted.feedback.eventID == event.eventId, accepted.motorApplied,
                  accepted.motorSequence == record.sequence, event.expectedJournalRevision == record.sequence - 1,
                  accepted.canonicalPayload == (try encoder.encode(accepted.feedback)),
                  accepted.feedback.kind == event.kind, accepted.feedback.purposeRef == event.purposeId,
                  accepted.feedback.configuration == event.configuration, accepted.feedback.sessionID == event.sessionId,
                  accepted.feedback.episodeID == event.episodeId, accepted.feedback.occurredAt == event.timestamp else {
                throw PerspectiveRoutingError.unavailable("routing feedback authority mismatch")
            }
        }
    }
    func load() throws -> PerspectiveRoutingDocument? { try locked { try read() } }
    func commit(_ document: PerspectiveRoutingDocument, replacing revision: Int) throws {
        try locked {
            let existing = try read()
            guard (existing?.revision ?? 0) == revision, document.revision == revision + 1 else { throw PerspectiveRoutingError.persistenceConflict }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let plain = try encoder.encode(document)
            guard plain.count <= 4*1024*1024 else { throw PerspectiveRoutingError.unavailable("routing authority capacity reached") }
            let encrypted = try CellPersistenceCrypto.encodeForStorage(plaintext: plain, uuid: binding,
                options: CellStorageWriteOptions(ownerIdentityUUID: ownerUUID, encryptedAtRestRequired: true))
            let persistence = try factory(fileURL())
            do { try persistence.store(encrypted) }
            catch {
                // Unknown write outcome: reread THIS exact identity before doing anything else.
                guard let actual = try persistence.load(), actual == encrypted,
                      try CellPersistenceCrypto.decodeFromStorage(stored: actual, uuid: binding) == plain else { throw error }
            }
            guard let actual = try persistence.load(), actual == encrypted,
                  try CellPersistenceCrypto.decodeFromStorage(stored: actual, uuid: binding) == plain else {
                throw PerspectiveRoutingError.unavailable("routing authority readback mismatch")
            }
        }
    }
}
