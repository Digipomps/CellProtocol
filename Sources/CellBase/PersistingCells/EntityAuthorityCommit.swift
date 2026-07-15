// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum EntityAuthorityCommitError: Error, Equatable, LocalizedError {
    case invalidSchema(String)
    case invalidIdentifier(String)
    case emptyMutations
    case requesterMismatch
    case payloadHashMismatch
    case requestSignatureInvalid
    case signingUnavailable
    case mutationIDConflict(String)
    case staleEpoch(expected: Int, actual: Int)
    case staleRevision(expected: Int, actual: Int)
    case staleHeadHash(expected: String?, actual: String?)
    case quorumUnavailable(requiredReplicaAcks: Int)
    case journalCorrupt(String)

    public var code: String {
        switch self {
        case .invalidSchema: return "invalid_schema"
        case .invalidIdentifier: return "invalid_identifier"
        case .emptyMutations: return "empty_mutations"
        case .requesterMismatch: return "requester_mismatch"
        case .payloadHashMismatch: return "payload_hash_mismatch"
        case .requestSignatureInvalid: return "request_signature_invalid"
        case .signingUnavailable: return "signing_unavailable"
        case .mutationIDConflict: return "mutation_id_conflict"
        case .staleEpoch: return "stale_epoch"
        case .staleRevision: return "stale_revision"
        case .staleHeadHash: return "stale_head_hash"
        case .quorumUnavailable: return "quorum_unavailable"
        case .journalCorrupt: return "journal_corrupt"
        }
    }

    public var isConflict: Bool {
        switch self {
        case .mutationIDConflict, .staleEpoch, .staleRevision, .staleHeadHash:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidSchema(schema):
            return "Unsupported Entity authority schema: \(schema)"
        case let .invalidIdentifier(identifier):
            return "Invalid Entity authority identifier: \(identifier)"
        case .emptyMutations:
            return "An authority commit must contain at least one mutation."
        case .requesterMismatch:
            return "The signed commit requester does not match the admitted requester."
        case .payloadHashMismatch:
            return "The signed payload hash does not match the batch envelope."
        case .requestSignatureInvalid:
            return "The Entity authority commit request signature is invalid."
        case .signingUnavailable:
            return "The required IdentityVault signing authority is unavailable."
        case let .mutationIDConflict(mutationID):
            return "Mutation ID \(mutationID) is already bound to different content."
        case let .staleEpoch(expected, actual):
            return "Stale Entity authority epoch \(expected); current epoch is \(actual)."
        case let .staleRevision(expected, actual):
            return "Stale Entity authority revision \(expected); current revision is \(actual)."
        case let .staleHeadHash(expected, actual):
            return "Stale Entity authority head hash \(expected ?? "nil"); current head is \(actual ?? "nil")."
        case let .quorumUnavailable(requiredReplicaAcks):
            return "This runtime cannot prove the requested replica quorum of \(requiredReplicaAcks)."
        case let .journalCorrupt(reason):
            return "Entity authority journal validation failed: \(reason)"
        }
    }
}

public struct EntityAuthorityCommitRequest: Codable, Equatable {
    public static let schema = "haven.entity-authority-commit-request.v0"
    public static let localAuthorityFaultPolicy = "haven.local-authority-atomic-file.v0"

    public var schema: String
    public var mutationID: String
    public var partitionID: String
    public var epoch: Int
    public var expectedRevision: Int
    public var expectedPreviousHash: String?
    public var payloadHash: String
    public var requesterIdentityUUID: String
    public var requesterSigningKeyFingerprint: String
    public var purposeRef: String
    public var capability: String
    public var faultPolicyID: String
    public var requiredReplicaAcks: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        mutationID: String,
        partitionID: String,
        epoch: Int,
        expectedRevision: Int,
        expectedPreviousHash: String?,
        payloadHash: String,
        requesterIdentityUUID: String,
        requesterSigningKeyFingerprint: String,
        purposeRef: String,
        capability: String,
        faultPolicyID: String,
        requiredReplicaAcks: Int,
        signature: Data
    ) {
        self.schema = schema
        self.mutationID = mutationID
        self.partitionID = partitionID
        self.epoch = epoch
        self.expectedRevision = expectedRevision
        self.expectedPreviousHash = expectedPreviousHash
        self.payloadHash = payloadHash
        self.requesterIdentityUUID = requesterIdentityUUID
        self.requesterSigningKeyFingerprint = requesterSigningKeyFingerprint
        self.purposeRef = purposeRef
        self.capability = capability
        self.faultPolicyID = faultPolicyID
        self.requiredReplicaAcks = requiredReplicaAcks
        self.signature = signature
    }

    public static func signed(
        envelope: EntityBatchPersistEnvelope,
        mutationID: String,
        partitionID: String = "entity",
        epoch: Int,
        expectedRevision: Int,
        expectedPreviousHash: String?,
        requester: Identity,
        purposeRef: String,
        capability: String = "entity.batchPersist",
        faultPolicyID: String = Self.localAuthorityFaultPolicy,
        requiredReplicaAcks: Int = 0
    ) async throws -> Self {
        guard let fingerprint = requester.signingPublicKeyFingerprint else {
            throw EntityAuthorityCommitError.signingUnavailable
        }
        var request = Self(
            mutationID: mutationID,
            partitionID: partitionID,
            epoch: epoch,
            expectedRevision: expectedRevision,
            expectedPreviousHash: expectedPreviousHash,
            payloadHash: try envelope.authorityPayloadHash(),
            requesterIdentityUUID: requester.uuid,
            requesterSigningKeyFingerprint: fingerprint,
            purposeRef: purposeRef,
            capability: capability,
            faultPolicyID: faultPolicyID,
            requiredReplicaAcks: requiredReplicaAcks,
            signature: Data()
        )
        guard let signature = try await requester.sign(data: request.signingData()) else {
            throw EntityAuthorityCommitError.signingUnavailable
        }
        request.signature = signature
        return request
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityCommitRequest(self))
    }

    public func verify(envelope: EntityBatchPersistEnvelope, requester: Identity) throws {
        guard schema == Self.schema else {
            throw EntityAuthorityCommitError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(mutationID)
        try EntityAuthorityCanonical.validateIdentifier(partitionID)
        guard requester.uuid == requesterIdentityUUID,
              requester.signingPublicKeyFingerprint == requesterSigningKeyFingerprint else {
            throw EntityAuthorityCommitError.requesterMismatch
        }
        guard payloadHash == (try envelope.authorityPayloadHash()) else {
            throw EntityAuthorityCommitError.payloadHashMismatch
        }
        guard IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: try signingData(),
            identity: requester
        ) else {
            throw EntityAuthorityCommitError.requestSignatureInvalid
        }
    }

    public init(value: ValueType) throws {
        self = try EntityAuthorityCanonical.decode(Self.self, from: value)
    }

    public func valueType() throws -> ValueType {
        try EntityAuthorityCanonical.valueType(self)
    }
}

public struct EntityAuthorityCommitReceipt: Codable, Equatable {
    public static let schema = "haven.entity-authority-commit-receipt.v0"

    public var schema: String
    public var status: String
    public var mutationID: String
    public var partitionID: String
    public var epoch: Int
    public var revision: Int
    public var previousHash: String?
    public var entryHash: String
    public var payloadHash: String
    public var authorityCellUUID: String
    public var authorityIdentityUUID: String
    public var authoritySigningKeyFingerprint: String
    public var committedAtEpochMilliseconds: Int
    public var durabilityLevel: String
    public var replicationState: String
    public var replicaAckCount: Int
    public var quorumSatisfied: Bool
    public var distributedCommit: Bool
    public var signature: Data

    public init(
        schema: String = Self.schema,
        status: String = "authority_committed",
        mutationID: String,
        partitionID: String,
        epoch: Int,
        revision: Int,
        previousHash: String?,
        entryHash: String,
        payloadHash: String,
        authorityCellUUID: String,
        authorityIdentityUUID: String,
        authoritySigningKeyFingerprint: String,
        committedAtEpochMilliseconds: Int,
        durabilityLevel: String = "atomic_file_replace_without_power_loss_proof",
        replicationState: String = "local_authority_only",
        replicaAckCount: Int = 0,
        quorumSatisfied: Bool = false,
        distributedCommit: Bool = false,
        signature: Data
    ) {
        self.schema = schema
        self.status = status
        self.mutationID = mutationID
        self.partitionID = partitionID
        self.epoch = epoch
        self.revision = revision
        self.previousHash = previousHash
        self.entryHash = entryHash
        self.payloadHash = payloadHash
        self.authorityCellUUID = authorityCellUUID
        self.authorityIdentityUUID = authorityIdentityUUID
        self.authoritySigningKeyFingerprint = authoritySigningKeyFingerprint
        self.committedAtEpochMilliseconds = committedAtEpochMilliseconds
        self.durabilityLevel = durabilityLevel
        self.replicationState = replicationState
        self.replicaAckCount = replicaAckCount
        self.quorumSatisfied = quorumSatisfied
        self.distributedCommit = distributedCommit
        self.signature = signature
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityCommitReceipt(self))
    }

    public func verifies(with authority: Identity) -> Bool {
        guard schema == Self.schema,
              status == "authority_committed",
              authority.uuid == authorityIdentityUUID,
              authority.signingPublicKeyFingerprint == authoritySigningKeyFingerprint,
              let data = try? signingData() else {
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: data,
            identity: authority
        )
    }

    public init(value: ValueType) throws {
        self = try EntityAuthorityCanonical.decode(Self.self, from: value)
    }

    public func valueType() throws -> ValueType {
        try EntityAuthorityCanonical.valueType(self)
    }
}

public struct EntityAuthorityJournalEntry: Codable, Equatable {
    public static let schema = "haven.entity-authority-journal-entry.v0"

    public var schema: String
    public var revision: Int
    public var previousHash: String?
    public var entryHash: String
    public var committedAtEpochMilliseconds: Int
    public var envelopeSchema: String
    public var mutations: [EntityBatchPersistMutation]
    public var metadata: Object
    public var request: EntityAuthorityCommitRequest
    public var receipt: EntityAuthorityCommitReceipt

    public init(
        schema: String = Self.schema,
        revision: Int,
        previousHash: String?,
        entryHash: String,
        committedAtEpochMilliseconds: Int,
        envelopeSchema: String,
        mutations: [EntityBatchPersistMutation],
        metadata: Object,
        request: EntityAuthorityCommitRequest,
        receipt: EntityAuthorityCommitReceipt
    ) {
        self.schema = schema
        self.revision = revision
        self.previousHash = previousHash
        self.entryHash = entryHash
        self.committedAtEpochMilliseconds = committedAtEpochMilliseconds
        self.envelopeSchema = envelopeSchema
        self.mutations = mutations
        self.metadata = metadata
        self.request = request
        self.receipt = receipt
    }

    func calculatedEntryHash() throws -> String {
        let material = EntityAuthorityJournalEntryHashMaterial(
            schema: schema,
            revision: revision,
            previousHash: previousHash,
            committedAtEpochMilliseconds: committedAtEpochMilliseconds,
            envelopeSchema: envelopeSchema,
            mutations: mutations,
            metadata: metadata,
            request: request
        )
        return FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: material))
    }
}

public struct EntityAuthorityJournalDocument: Codable, Equatable {
    public static let schema = "haven.entity-authority-journal.v0"

    public var schema: String
    public var partitionID: String
    public var epoch: Int
    public var entries: [EntityAuthorityJournalEntry]

    public init(
        schema: String = Self.schema,
        partitionID: String = "entity",
        epoch: Int = 1,
        entries: [EntityAuthorityJournalEntry] = []
    ) {
        self.schema = schema
        self.partitionID = partitionID
        self.epoch = epoch
        self.entries = entries
    }

    public var revision: Int { entries.last?.revision ?? 0 }
    public var headHash: String? { entries.last?.entryHash }

    public func state(faultPolicyID: String = EntityAuthorityCommitRequest.localAuthorityFaultPolicy) -> EntityAuthorityCommitState {
        EntityAuthorityCommitState(
            partitionID: partitionID,
            epoch: epoch,
            revision: revision,
            headHash: headHash,
            faultPolicyID: faultPolicyID
        )
    }

    public func validateStructure() throws {
        guard schema == Self.schema else {
            throw EntityAuthorityCommitError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(partitionID)
        var expectedRevision = 1
        var expectedPreviousHash: String?
        var mutationIDs: [String: String] = [:]
        for entry in entries {
            let entryPayloadHash = try EntityBatchPersistEnvelope(
                schema: entry.envelopeSchema,
                mutations: entry.mutations,
                metadata: entry.metadata
            ).authorityPayloadHash()
            guard entry.schema == EntityAuthorityJournalEntry.schema else {
                throw EntityAuthorityCommitError.journalCorrupt("entry_schema")
            }
            guard entry.revision == expectedRevision else {
                throw EntityAuthorityCommitError.journalCorrupt("revision_\(entry.revision)_expected_\(expectedRevision)")
            }
            guard entry.previousHash == expectedPreviousHash else {
                throw EntityAuthorityCommitError.journalCorrupt("previous_hash_at_revision_\(entry.revision)")
            }
            guard entry.request.partitionID == partitionID,
                  entry.request.epoch == epoch,
                  entry.request.payloadHash == entryPayloadHash else {
                throw EntityAuthorityCommitError.journalCorrupt("request_binding_at_revision_\(entry.revision)")
            }
            guard entry.entryHash == (try entry.calculatedEntryHash()) else {
                throw EntityAuthorityCommitError.journalCorrupt("entry_hash_at_revision_\(entry.revision)")
            }
            guard entry.receipt.mutationID == entry.request.mutationID,
                  entry.receipt.partitionID == partitionID,
                  entry.receipt.epoch == epoch,
                  entry.receipt.revision == entry.revision,
                  entry.receipt.previousHash == entry.previousHash,
                  entry.receipt.entryHash == entry.entryHash,
                  entry.receipt.payloadHash == entry.request.payloadHash else {
                throw EntityAuthorityCommitError.journalCorrupt("receipt_binding_at_revision_\(entry.revision)")
            }
            if let existingHash = mutationIDs[entry.request.mutationID],
               existingHash != entry.request.payloadHash {
                throw EntityAuthorityCommitError.journalCorrupt("mutation_id_rebound")
            }
            mutationIDs[entry.request.mutationID] = entry.request.payloadHash
            expectedRevision += 1
            expectedPreviousHash = entry.entryHash
        }
    }

    public func replay(on base: Entity) throws -> Entity {
        try validateStructure()
        var snapshot = base
        for entry in entries {
            for mutation in entry.mutations {
                try snapshot.set(keypath: mutation.keypath, setValue: mutation.value)
            }
        }
        return snapshot
    }

    public func verifyReceipts(authority: Identity) throws -> Bool {
        try validateStructure()
        return entries.allSatisfy { $0.receipt.verifies(with: authority) }
    }

    public func appending(
        envelope: EntityBatchPersistEnvelope,
        to snapshot: Entity,
        requester: Identity,
        authority: Identity,
        authorityCellUUID: String,
        committedAtEpochMilliseconds: Int
    ) async throws -> EntityAuthorityCommitOutcome {
        try validateStructure()
        guard envelope.mutations.isEmpty == false else {
            throw EntityAuthorityCommitError.emptyMutations
        }
        guard let request = envelope.commitRequest else {
            throw EntityAuthorityCommitError.invalidSchema("missing_commit_request")
        }
        try request.verify(envelope: envelope, requester: requester)

        if let existing = entries.first(where: { $0.request.mutationID == request.mutationID }) {
            guard existing.request.payloadHash == request.payloadHash,
                  existing.request.requesterIdentityUUID == request.requesterIdentityUUID,
                  existing.request.requesterSigningKeyFingerprint == request.requesterSigningKeyFingerprint else {
                throw EntityAuthorityCommitError.mutationIDConflict(request.mutationID)
            }
            return EntityAuthorityCommitOutcome(
                journal: self,
                snapshot: try replay(on: snapshot),
                receipt: existing.receipt,
                idempotentReplay: true
            )
        }

        guard request.partitionID == partitionID else {
            throw EntityAuthorityCommitError.invalidIdentifier(request.partitionID)
        }
        guard request.epoch == epoch else {
            throw EntityAuthorityCommitError.staleEpoch(expected: request.epoch, actual: epoch)
        }
        guard request.expectedRevision == revision else {
            throw EntityAuthorityCommitError.staleRevision(expected: request.expectedRevision, actual: revision)
        }
        guard request.expectedPreviousHash == headHash else {
            throw EntityAuthorityCommitError.staleHeadHash(expected: request.expectedPreviousHash, actual: headHash)
        }
        guard request.faultPolicyID == EntityAuthorityCommitRequest.localAuthorityFaultPolicy else {
            throw EntityAuthorityCommitError.invalidSchema(request.faultPolicyID)
        }
        guard request.requiredReplicaAcks == 0 else {
            throw EntityAuthorityCommitError.quorumUnavailable(requiredReplicaAcks: request.requiredReplicaAcks)
        }
        guard let authorityFingerprint = authority.signingPublicKeyFingerprint else {
            throw EntityAuthorityCommitError.signingUnavailable
        }

        var updatedSnapshot = snapshot
        for mutation in envelope.mutations {
            try updatedSnapshot.set(keypath: mutation.keypath, setValue: mutation.value)
        }

        let nextRevision = revision + 1
        let hashMaterial = EntityAuthorityJournalEntryHashMaterial(
            schema: EntityAuthorityJournalEntry.schema,
            revision: nextRevision,
            previousHash: headHash,
            committedAtEpochMilliseconds: committedAtEpochMilliseconds,
            envelopeSchema: envelope.schema,
            mutations: envelope.mutations,
            metadata: envelope.metadata,
            request: request
        )
        let entryHash = FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: hashMaterial))
        var receipt = EntityAuthorityCommitReceipt(
            mutationID: request.mutationID,
            partitionID: partitionID,
            epoch: epoch,
            revision: nextRevision,
            previousHash: headHash,
            entryHash: entryHash,
            payloadHash: request.payloadHash,
            authorityCellUUID: authorityCellUUID,
            authorityIdentityUUID: authority.uuid,
            authoritySigningKeyFingerprint: authorityFingerprint,
            committedAtEpochMilliseconds: committedAtEpochMilliseconds,
            signature: Data()
        )
        guard let receiptSignature = try await authority.sign(data: receipt.signingData()) else {
            throw EntityAuthorityCommitError.signingUnavailable
        }
        receipt.signature = receiptSignature
        guard receipt.verifies(with: authority) else {
            throw EntityAuthorityCommitError.signingUnavailable
        }

        let entry = EntityAuthorityJournalEntry(
            revision: nextRevision,
            previousHash: headHash,
            entryHash: entryHash,
            committedAtEpochMilliseconds: committedAtEpochMilliseconds,
            envelopeSchema: envelope.schema,
            mutations: envelope.mutations,
            metadata: envelope.metadata,
            request: request,
            receipt: receipt
        )
        var updatedJournal = self
        updatedJournal.entries.append(entry)
        try updatedJournal.validateStructure()
        return EntityAuthorityCommitOutcome(
            journal: updatedJournal,
            snapshot: updatedSnapshot,
            receipt: receipt,
            idempotentReplay: false
        )
    }
}

public struct EntityAuthorityCommitState: Codable, Equatable {
    public static let schema = "haven.entity-authority-commit-state.v0"

    public var schema: String
    public var partitionID: String
    public var epoch: Int
    public var revision: Int
    public var headHash: String?
    public var faultPolicyID: String
    public var durabilityLevel: String
    public var replicationState: String
    public var distributedQuorumAvailable: Bool

    public init(
        schema: String = Self.schema,
        partitionID: String,
        epoch: Int,
        revision: Int,
        headHash: String?,
        faultPolicyID: String,
        durabilityLevel: String = "atomic_file_replace_without_power_loss_proof",
        replicationState: String = "local_authority_only",
        distributedQuorumAvailable: Bool = false
    ) {
        self.schema = schema
        self.partitionID = partitionID
        self.epoch = epoch
        self.revision = revision
        self.headHash = headHash
        self.faultPolicyID = faultPolicyID
        self.durabilityLevel = durabilityLevel
        self.replicationState = replicationState
        self.distributedQuorumAvailable = distributedQuorumAvailable
    }

    public init(value: ValueType) throws {
        self = try EntityAuthorityCanonical.decode(Self.self, from: value)
    }

    public func valueType() throws -> ValueType {
        try EntityAuthorityCanonical.valueType(self)
    }
}

public struct EntityAuthorityCommitOutcome: Equatable {
    public var journal: EntityAuthorityJournalDocument
    public var snapshot: Entity
    public var receipt: EntityAuthorityCommitReceipt
    public var idempotentReplay: Bool

    public init(
        journal: EntityAuthorityJournalDocument,
        snapshot: Entity,
        receipt: EntityAuthorityCommitReceipt,
        idempotentReplay: Bool
    ) {
        self.journal = journal
        self.snapshot = snapshot
        self.receipt = receipt
        self.idempotentReplay = idempotentReplay
    }
}

private struct UnsignedEntityAuthorityCommitRequest: Codable {
    var schema: String
    var mutationID: String
    var partitionID: String
    var epoch: Int
    var expectedRevision: Int
    var expectedPreviousHash: String?
    var payloadHash: String
    var requesterIdentityUUID: String
    var requesterSigningKeyFingerprint: String
    var purposeRef: String
    var capability: String
    var faultPolicyID: String
    var requiredReplicaAcks: Int

    init(_ request: EntityAuthorityCommitRequest) {
        schema = request.schema
        mutationID = request.mutationID
        partitionID = request.partitionID
        epoch = request.epoch
        expectedRevision = request.expectedRevision
        expectedPreviousHash = request.expectedPreviousHash
        payloadHash = request.payloadHash
        requesterIdentityUUID = request.requesterIdentityUUID
        requesterSigningKeyFingerprint = request.requesterSigningKeyFingerprint
        purposeRef = request.purposeRef
        capability = request.capability
        faultPolicyID = request.faultPolicyID
        requiredReplicaAcks = request.requiredReplicaAcks
    }
}

private struct UnsignedEntityAuthorityCommitReceipt: Codable {
    var schema: String
    var status: String
    var mutationID: String
    var partitionID: String
    var epoch: Int
    var revision: Int
    var previousHash: String?
    var entryHash: String
    var payloadHash: String
    var authorityCellUUID: String
    var authorityIdentityUUID: String
    var authoritySigningKeyFingerprint: String
    var committedAtEpochMilliseconds: Int
    var durabilityLevel: String
    var replicationState: String
    var replicaAckCount: Int
    var quorumSatisfied: Bool
    var distributedCommit: Bool

    init(_ receipt: EntityAuthorityCommitReceipt) {
        schema = receipt.schema
        status = receipt.status
        mutationID = receipt.mutationID
        partitionID = receipt.partitionID
        epoch = receipt.epoch
        revision = receipt.revision
        previousHash = receipt.previousHash
        entryHash = receipt.entryHash
        payloadHash = receipt.payloadHash
        authorityCellUUID = receipt.authorityCellUUID
        authorityIdentityUUID = receipt.authorityIdentityUUID
        authoritySigningKeyFingerprint = receipt.authoritySigningKeyFingerprint
        committedAtEpochMilliseconds = receipt.committedAtEpochMilliseconds
        durabilityLevel = receipt.durabilityLevel
        replicationState = receipt.replicationState
        replicaAckCount = receipt.replicaAckCount
        quorumSatisfied = receipt.quorumSatisfied
        distributedCommit = receipt.distributedCommit
    }
}

private struct EntityAuthorityJournalEntryHashMaterial: Codable {
    var schema: String
    var revision: Int
    var previousHash: String?
    var committedAtEpochMilliseconds: Int
    var envelopeSchema: String
    var mutations: [EntityBatchPersistMutation]
    var metadata: Object
    var request: EntityAuthorityCommitRequest
}

private struct EntityAuthorityPayloadMaterial: Codable {
    var schema: String
    var mutations: [EntityBatchPersistMutation]
    var metadata: Object
}

enum EntityAuthorityCanonical {
    static func data<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func valueType<T: Encodable>(_ value: T) throws -> ValueType {
        try JSONDecoder().decode(ValueType.self, from: data(for: value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(type, from: encoder.encode(value))
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard identifier.isEmpty == false,
              identifier.utf8.count <= 256,
              identifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "-_.:"))
                      .contains($0)
              }) else {
            throw EntityAuthorityCommitError.invalidIdentifier(identifier)
        }
    }
}

extension EntityBatchPersistEnvelope {
    public func authorityPayloadData() throws -> Data {
        try EntityAuthorityCanonical.data(for: EntityAuthorityPayloadMaterial(
            schema: schema,
            mutations: mutations,
            metadata: metadata
        ))
    }

    public func authorityPayloadHash() throws -> String {
        FlowHasher.sha256Hex(try authorityPayloadData())
    }
}
