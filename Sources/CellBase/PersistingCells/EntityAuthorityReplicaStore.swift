// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum EntityAuthorityReplicaStoreError: Error, Equatable, LocalizedError {
    case invalidAdmission
    case replayRejected
    case journalConflict(String)
    case persistenceFailure
    case persistenceVerificationFailed
    case unsupportedDurability

    public var errorDescription: String? {
        switch self {
        case .invalidAdmission:
            return "The replica admission or Identity binding is invalid."
        case .replayRejected:
            return "The authority replay range is incomplete, conflicting, or not receipt-verified."
        case let .journalConflict(reason):
            return "The replica journal conflicts with authority history: \(reason)"
        case .persistenceFailure:
            return "The replica journal could not be persisted."
        case .persistenceVerificationFailed:
            return "The replica journal did not survive an exact persistence read-back."
        case .unsupportedDurability:
            return "Transport delivery cannot be used as replica durability evidence."
        }
    }
}

/// Storage is deliberately expressed below transport. Implementations must return only
/// after the claimed durability boundary has completed; delivery of bytes is not persistence.
public protocol EntityAuthorityReplicaPersistence: Sendable {
    var durabilityLevel: EntityAuthorityReplicaDurabilityLevel { get }
    func load() throws -> Data?
    func store(_ data: Data) throws
}

/// Atomic replacement provides crash-safe file replacement on supported local filesystems.
/// It does not claim that the file and parent directory survive sudden power loss.
public struct AtomicFileEntityAuthorityReplicaPersistence: EntityAuthorityReplicaPersistence {
    public let fileURL: URL
    public let durabilityLevel = EntityAuthorityReplicaDurabilityLevel.atomicFileReplaceWithoutPowerLossProof

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func store(_ data: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

/// The complete, admission-bound journal stored by one replica.
public struct EntityAuthorityReplicaStoreDocument: Codable, Equatable {
    public static let schema = "haven.entity-authority-replica-store.v0"

    public var schema: String
    public var admissionID: String
    public var admissionHash: String
    public var replicaID: String
    public var partitionID: String
    public var epoch: Int
    public var persistedAtEpochMilliseconds: Int
    public var journal: EntityAuthorityJournalDocument

    public init(
        schema: String = Self.schema,
        admissionID: String,
        admissionHash: String,
        replicaID: String,
        partitionID: String,
        epoch: Int,
        persistedAtEpochMilliseconds: Int,
        journal: EntityAuthorityJournalDocument
    ) {
        self.schema = schema
        self.admissionID = admissionID
        self.admissionHash = admissionHash
        self.replicaID = replicaID
        self.partitionID = partitionID
        self.epoch = epoch
        self.persistedAtEpochMilliseconds = persistedAtEpochMilliseconds
        self.journal = journal
    }

    public var revision: Int { journal.revision }
    public var headHash: String? { journal.headHash }
}

/// Serializes merge, persistence verification, and acknowledgement signing for one replica.
/// An acknowledgement is produced only after the exact merged journal has been read back.
public actor EntityAuthorityReplicaStore {
    private let persistence: any EntityAuthorityReplicaPersistence
    private let admission: EntityAuthorityReplicaAdmission
    private let authority: Identity
    private let replica: Identity

    public init(
        persistence: any EntityAuthorityReplicaPersistence,
        admission: EntityAuthorityReplicaAdmission,
        authority: Identity,
        replica: Identity
    ) {
        self.persistence = persistence
        self.admission = admission
        self.authority = authority
        self.replica = replica
    }

    public func storedDocument() throws -> EntityAuthorityReplicaStoreDocument? {
        guard let data = try loadData() else {
            return nil
        }
        let document = try decodeDocument(data)
        try validate(document: document)
        return document
    }

    /// Persists a complete authority replay range and returns one replica-signed
    /// acknowledgement for every receipt in that range. The method is idempotent for
    /// byte-equivalent history and fails closed on a gap or any divergent revision.
    public func persist(
        response: EntityAuthorityReplayRangeResponse,
        for request: EntityAuthorityReplayRangeRequest,
        persistedAtEpochMilliseconds: Int
    ) async throws -> [EntityAuthorityReplicaAcknowledgement] {
        guard persistence.durabilityLevel != .transportDeliveryOnly else {
            throw EntityAuthorityReplicaStoreError.unsupportedDurability
        }
        guard admission.verifies(
            authority: authority,
            atEpochMilliseconds: persistedAtEpochMilliseconds
        ), replica.uuid == admission.replicaIdentity.uuid,
           replica.signingPublicKeyFingerprint == admission.replicaSigningKeyFingerprint else {
            throw EntityAuthorityReplicaStoreError.invalidAdmission
        }
        guard response.status == .complete,
              response.verifies(for: request, authority: authority) else {
            throw EntityAuthorityReplicaStoreError.replayRejected
        }

        let existing = try storedDocument()
        var journal = existing?.journal ?? EntityAuthorityJournalDocument(
            partitionID: admission.partitionID,
            epoch: admission.epoch
        )
        try merge(response.entries, into: &journal)
        guard try journal.verifyReceipts(authority: authority) else {
            throw EntityAuthorityReplicaStoreError.replayRejected
        }

        let expected = EntityAuthorityReplicaStoreDocument(
            admissionID: admission.admissionID,
            admissionHash: try admission.entityAuthorityCanonicalHash(),
            replicaID: admission.replicaID,
            partitionID: admission.partitionID,
            epoch: admission.epoch,
            persistedAtEpochMilliseconds: persistedAtEpochMilliseconds,
            journal: journal
        )
        try validate(document: expected)
        let expectedData = try EntityAuthorityCanonical.data(for: expected)

        do {
            try persistence.store(expectedData)
        } catch {
            throw EntityAuthorityReplicaStoreError.persistenceFailure
        }

        guard let reloadedData = try loadData(),
              reloadedData == expectedData else {
            throw EntityAuthorityReplicaStoreError.persistenceVerificationFailed
        }
        let reloaded = try decodeDocument(reloadedData)
        guard reloaded == expected else {
            throw EntityAuthorityReplicaStoreError.persistenceVerificationFailed
        }
        try validate(document: reloaded)

        var acknowledgements: [EntityAuthorityReplicaAcknowledgement] = []
        acknowledgements.reserveCapacity(response.entries.count)
        for entry in response.entries {
            let acknowledgement = try await EntityAuthorityReplicaAcknowledgement.signed(
                receipt: entry.receipt,
                admission: admission,
                replica: replica,
                durabilityLevel: persistence.durabilityLevel,
                persistedAtEpochMilliseconds: persistedAtEpochMilliseconds
            )
            acknowledgements.append(acknowledgement)
        }
        return acknowledgements
    }

    private func merge(
        _ incomingEntries: [EntityAuthorityJournalEntry],
        into journal: inout EntityAuthorityJournalDocument
    ) throws {
        try journal.validateStructure()
        for entry in incomingEntries {
            if entry.revision <= journal.entries.count {
                guard journal.entries[entry.revision - 1] == entry else {
                    throw EntityAuthorityReplicaStoreError.journalConflict(
                        "divergent_revision_\(entry.revision)"
                    )
                }
                continue
            }
            guard entry.revision == journal.entries.count + 1 else {
                throw EntityAuthorityReplicaStoreError.journalConflict(
                    "missing_revision_\(journal.entries.count + 1)"
                )
            }
            guard entry.previousHash == journal.headHash else {
                throw EntityAuthorityReplicaStoreError.journalConflict(
                    "previous_hash_at_revision_\(entry.revision)"
                )
            }
            journal.entries.append(entry)
        }
        try journal.validateStructure()
    }

    private func validate(document: EntityAuthorityReplicaStoreDocument) throws {
        guard document.schema == EntityAuthorityReplicaStoreDocument.schema,
              document.admissionID == admission.admissionID,
              document.admissionHash == (try admission.entityAuthorityCanonicalHash()),
              document.replicaID == admission.replicaID,
              document.partitionID == admission.partitionID,
              document.epoch == admission.epoch,
              document.journal.partitionID == admission.partitionID,
              document.journal.epoch == admission.epoch,
              document.persistedAtEpochMilliseconds >= admission.issuedAtEpochMilliseconds,
              document.persistedAtEpochMilliseconds <= admission.expiresAtEpochMilliseconds,
              admission.verifies(
                authority: authority,
                atEpochMilliseconds: document.persistedAtEpochMilliseconds
              ) else {
            throw EntityAuthorityReplicaStoreError.invalidAdmission
        }
        try document.journal.validateStructure()
        guard try document.journal.verifyReceipts(authority: authority) else {
            throw EntityAuthorityReplicaStoreError.replayRejected
        }
    }

    private func loadData() throws -> Data? {
        do {
            return try persistence.load()
        } catch {
            throw EntityAuthorityReplicaStoreError.persistenceFailure
        }
    }

    private func decodeDocument(_ data: Data) throws -> EntityAuthorityReplicaStoreDocument {
        do {
            return try JSONDecoder().decode(EntityAuthorityReplicaStoreDocument.self, from: data)
        } catch {
            throw EntityAuthorityReplicaStoreError.persistenceVerificationFailed
        }
    }
}
