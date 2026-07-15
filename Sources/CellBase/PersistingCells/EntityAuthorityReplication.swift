// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum EntityAuthorityReplicationError: Error, Equatable, LocalizedError {
    case invalidSchema(String)
    case invalidAdmission(String)
    case invalidPolicy(String)
    case invalidAcknowledgement(String)
    case invalidCertificate(String)
    case invalidReceipt
    case invalidReplayRequest(String)
    case invalidReplayResponse(String)
    case signingUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidSchema(schema):
            return "Unsupported Entity authority replication schema: \(schema)"
        case let .invalidAdmission(reason):
            return "Invalid Entity authority replica admission: \(reason)"
        case let .invalidPolicy(reason):
            return "Invalid Entity authority quorum policy: \(reason)"
        case let .invalidAcknowledgement(reason):
            return "Invalid Entity authority replica acknowledgement: \(reason)"
        case let .invalidCertificate(reason):
            return "Invalid Entity authority replica quorum certificate: \(reason)"
        case .invalidReceipt:
            return "The Entity authority receipt is invalid or does not match the replication evidence."
        case let .invalidReplayRequest(reason):
            return "Invalid Entity authority replay request: \(reason)"
        case let .invalidReplayResponse(reason):
            return "Invalid Entity authority replay response: \(reason)"
        case .signingUnavailable:
            return "The required Entity authority replication signer is unavailable."
        }
    }
}

public enum EntityAuthorityReplicaDurabilityLevel: String, Codable, Sendable {
    /// A transport has delivered bytes. This is never sufficient for a replica quorum.
    case transportDeliveryOnly = "transport_delivery_only"
    /// The replica claims an atomic file replacement, without power-loss proof.
    case atomicFileReplaceWithoutPowerLossProof = "atomic_file_replace_without_power_loss_proof"
    /// The replica claims that the file and parent directory were synchronously flushed.
    case fsyncFileAndParentDirectory = "fsync_file_and_parent_directory"
}

/// Authority-signed admission of one replica identity for one partition epoch.
/// The admission, not a route or transport session, is the source of replica authority.
public struct EntityAuthorityReplicaAdmission: Codable, Equatable {
    public static let schema = "haven.entity-authority-replica-admission.v0"
    public static let capability = "entity.authority.replica.ack"

    public var schema: String
    public var admissionID: String
    public var replicaID: String
    public var partitionID: String
    public var epoch: Int
    public var faultDomainID: String
    public var replicaIdentity: IdentityPublicKeyDescriptor
    public var replicaSigningKeyFingerprint: String
    public var capability: String
    public var authorityIdentityUUID: String
    public var authoritySigningKeyFingerprint: String
    public var issuedAtEpochMilliseconds: Int
    public var expiresAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        admissionID: String,
        replicaID: String,
        partitionID: String,
        epoch: Int,
        faultDomainID: String,
        replicaIdentity: IdentityPublicKeyDescriptor,
        replicaSigningKeyFingerprint: String,
        capability: String = Self.capability,
        authorityIdentityUUID: String,
        authoritySigningKeyFingerprint: String,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.admissionID = admissionID
        self.replicaID = replicaID
        self.partitionID = partitionID
        self.epoch = epoch
        self.faultDomainID = faultDomainID
        self.replicaIdentity = replicaIdentity
        self.replicaSigningKeyFingerprint = replicaSigningKeyFingerprint
        self.capability = capability
        self.authorityIdentityUUID = authorityIdentityUUID
        self.authoritySigningKeyFingerprint = authoritySigningKeyFingerprint
        self.issuedAtEpochMilliseconds = issuedAtEpochMilliseconds
        self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        admissionID: String,
        replicaID: String,
        partitionID: String,
        epoch: Int,
        faultDomainID: String,
        replica: Identity,
        authority: Identity,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard let replicaDescriptor = IdentityPublicKeySignatureVerifier.descriptor(for: replica),
              let replicaFingerprint = replica.signingPublicKeyFingerprint,
              let authorityFingerprint = authority.signingPublicKeyFingerprint else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        var admission = Self(
            admissionID: admissionID,
            replicaID: replicaID,
            partitionID: partitionID,
            epoch: epoch,
            faultDomainID: faultDomainID,
            replicaIdentity: replicaDescriptor,
            replicaSigningKeyFingerprint: replicaFingerprint,
            authorityIdentityUUID: authority.uuid,
            authoritySigningKeyFingerprint: authorityFingerprint,
            issuedAtEpochMilliseconds: issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: expiresAtEpochMilliseconds,
            signature: Data()
        )
        try admission.validateFields(atEpochMilliseconds: issuedAtEpochMilliseconds)
        guard let signature = try await authority.sign(data: admission.signingData()) else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        admission.signature = signature
        return admission
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityReplicaAdmission(self))
    }

    public func verifies(authority: Identity, atEpochMilliseconds: Int) -> Bool {
        do {
            try validateFields(atEpochMilliseconds: atEpochMilliseconds)
            guard authority.uuid == authorityIdentityUUID,
                  authority.signingPublicKeyFingerprint == authoritySigningKeyFingerprint else {
                return false
            }
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: authority
            )
        } catch {
            return false
        }
    }

    private func validateFields(atEpochMilliseconds: Int) throws {
        guard schema == Self.schema else {
            throw EntityAuthorityReplicationError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(admissionID)
        try EntityAuthorityCanonical.validateIdentifier(replicaID)
        try EntityAuthorityCanonical.validateIdentifier(partitionID)
        try EntityAuthorityCanonical.validateIdentifier(faultDomainID)
        guard epoch > 0 else {
            throw EntityAuthorityReplicationError.invalidAdmission("epoch")
        }
        guard capability == Self.capability else {
            throw EntityAuthorityReplicationError.invalidAdmission("capability")
        }
        guard replicaIdentity.uuid.isEmpty == false,
              replicaIdentity.entityAuthoritySigningKeyFingerprint == replicaSigningKeyFingerprint else {
            throw EntityAuthorityReplicationError.invalidAdmission("replica_identity_binding")
        }
        guard issuedAtEpochMilliseconds >= 0,
              expiresAtEpochMilliseconds > issuedAtEpochMilliseconds,
              atEpochMilliseconds >= issuedAtEpochMilliseconds,
              atEpochMilliseconds <= expiresAtEpochMilliseconds else {
            throw EntityAuthorityReplicationError.invalidAdmission("validity_window")
        }
    }
}

/// Authority-signed quorum policy. Only admissions named by this policy may count.
public struct EntityAuthorityReplicaQuorumPolicy: Codable, Equatable {
    public static let schema = "haven.entity-authority-replica-quorum-policy.v0"
    public static let maximumAdmittedReplicas = 64
    public static let maximumAcknowledgementsPerEvaluation = 256

    public var schema: String
    public var policyID: String
    public var partitionID: String
    public var epoch: Int
    public var requiredReplicaAcks: Int
    public var admittedAdmissionIDs: [String]
    public var admittedAdmissionHashes: [String: String]
    public var acceptedDurabilityLevels: [String]
    public var requireDistinctFaultDomains: Bool
    public var authorityIdentityUUID: String
    public var authoritySigningKeyFingerprint: String
    public var issuedAtEpochMilliseconds: Int
    public var expiresAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        policyID: String,
        partitionID: String,
        epoch: Int,
        requiredReplicaAcks: Int,
        admittedAdmissionIDs: [String],
        admittedAdmissionHashes: [String: String],
        acceptedDurabilityLevels: [String],
        requireDistinctFaultDomains: Bool,
        authorityIdentityUUID: String,
        authoritySigningKeyFingerprint: String,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.policyID = policyID
        self.partitionID = partitionID
        self.epoch = epoch
        self.requiredReplicaAcks = requiredReplicaAcks
        self.admittedAdmissionIDs = admittedAdmissionIDs
        self.admittedAdmissionHashes = admittedAdmissionHashes
        self.acceptedDurabilityLevels = acceptedDurabilityLevels
        self.requireDistinctFaultDomains = requireDistinctFaultDomains
        self.authorityIdentityUUID = authorityIdentityUUID
        self.authoritySigningKeyFingerprint = authoritySigningKeyFingerprint
        self.issuedAtEpochMilliseconds = issuedAtEpochMilliseconds
        self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        policyID: String,
        partitionID: String,
        epoch: Int,
        requiredReplicaAcks: Int,
        admissions: [EntityAuthorityReplicaAdmission],
        acceptedDurabilityLevels: [EntityAuthorityReplicaDurabilityLevel],
        requireDistinctFaultDomains: Bool = true,
        authority: Identity,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard let authorityFingerprint = authority.signingPublicKeyFingerprint else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        guard admissions.allSatisfy({
            $0.partitionID == partitionID
                && $0.epoch == epoch
                && $0.verifies(authority: authority, atEpochMilliseconds: issuedAtEpochMilliseconds)
        }) else {
            throw EntityAuthorityReplicationError.invalidPolicy("admission_material")
        }
        let sortedAdmissions = admissions.sorted(by: { $0.admissionID < $1.admissionID })
        let admissionIDs = sortedAdmissions.map(\.admissionID)
        guard admissionIDs.count == Set(admissionIDs).count else {
            throw EntityAuthorityReplicationError.invalidPolicy("duplicate_admission_id")
        }
        let admissionHashes = try Dictionary(
            uniqueKeysWithValues: sortedAdmissions.map {
                ($0.admissionID, try $0.entityAuthorityCanonicalHash())
            }
        )
        let durabilityLevels = acceptedDurabilityLevels.map(\.rawValue).sorted()
        guard durabilityLevels.count == Set(durabilityLevels).count else {
            throw EntityAuthorityReplicationError.invalidPolicy("duplicate_durability_level")
        }
        var policy = Self(
            policyID: policyID,
            partitionID: partitionID,
            epoch: epoch,
            requiredReplicaAcks: requiredReplicaAcks,
            admittedAdmissionIDs: admissionIDs,
            admittedAdmissionHashes: admissionHashes,
            acceptedDurabilityLevels: durabilityLevels,
            requireDistinctFaultDomains: requireDistinctFaultDomains,
            authorityIdentityUUID: authority.uuid,
            authoritySigningKeyFingerprint: authorityFingerprint,
            issuedAtEpochMilliseconds: issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: expiresAtEpochMilliseconds,
            signature: Data()
        )
        try policy.validateFields(atEpochMilliseconds: issuedAtEpochMilliseconds)
        guard let signature = try await authority.sign(data: policy.signingData()) else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        policy.signature = signature
        return policy
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityReplicaQuorumPolicy(self))
    }

    public func verifies(authority: Identity, atEpochMilliseconds: Int) -> Bool {
        do {
            try validateFields(atEpochMilliseconds: atEpochMilliseconds)
            guard authority.uuid == authorityIdentityUUID,
                  authority.signingPublicKeyFingerprint == authoritySigningKeyFingerprint else {
                return false
            }
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: authority
            )
        } catch {
            return false
        }
    }

    public func evaluate(
        receipt: EntityAuthorityCommitReceipt,
        authority: Identity,
        admissions: [EntityAuthorityReplicaAdmission],
        acknowledgements: [EntityAuthorityReplicaAcknowledgement],
        atEpochMilliseconds: Int
    ) throws -> EntityAuthorityReplicaQuorumEvaluation {
        guard admissions.count <= Self.maximumAdmittedReplicas,
              acknowledgements.count <= Self.maximumAcknowledgementsPerEvaluation else {
            throw EntityAuthorityReplicationError.invalidPolicy("replication_material_limit")
        }
        guard receipt.verifies(with: authority) else {
            throw EntityAuthorityReplicationError.invalidReceipt
        }
        guard verifies(authority: authority, atEpochMilliseconds: atEpochMilliseconds) else {
            throw EntityAuthorityReplicationError.invalidPolicy("signature_or_validity")
        }
        guard receipt.partitionID == partitionID, receipt.epoch == epoch else {
            throw EntityAuthorityReplicationError.invalidPolicy("receipt_binding")
        }

        var admissionByID: [String: EntityAuthorityReplicaAdmission] = [:]
        for admission in admissions {
            guard admissionByID[admission.admissionID] == nil else {
                throw EntityAuthorityReplicationError.invalidPolicy("duplicate_admission_material")
            }
            guard admittedAdmissionIDs.contains(admission.admissionID),
                  admittedAdmissionHashes[admission.admissionID] == (try admission.entityAuthorityCanonicalHash()),
                  admission.partitionID == partitionID,
                  admission.epoch == epoch,
                  admission.verifies(authority: authority, atEpochMilliseconds: atEpochMilliseconds) else {
                continue
            }
            admissionByID[admission.admissionID] = admission
        }

        var acceptedReplicaIDs = Set<String>()
        var acceptedFaultDomainIDs = Set<String>()
        var acceptedAcknowledgementHashes = Set<String>()
        var seenAckIDs = Set<String>()
        var rejections: [EntityAuthorityReplicaAckRejection] = []

        let orderedAcknowledgements = try acknowledgements.map {
            (acknowledgement: $0, evidenceHash: try $0.entityAuthorityEvidenceHash())
        }.sorted {
            if $0.acknowledgement.ackID != $1.acknowledgement.ackID {
                return $0.acknowledgement.ackID < $1.acknowledgement.ackID
            }
            return $0.evidenceHash < $1.evidenceHash
        }
        for candidate in orderedAcknowledgements {
            let acknowledgement = candidate.acknowledgement
            guard seenAckIDs.insert(acknowledgement.ackID).inserted else {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "duplicate_ack_id"))
                continue
            }
            guard let admission = admissionByID[acknowledgement.admissionID] else {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "admission_not_authorized"))
                continue
            }
            guard acceptedDurabilityLevels.contains(acknowledgement.durabilityLevel) else {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "durability_not_accepted"))
                continue
            }
            guard acknowledgement.verifies(
                receipt: receipt,
                admission: admission,
                atEpochMilliseconds: atEpochMilliseconds
            ) else {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "ack_signature_or_binding_invalid"))
                continue
            }
            guard acceptedReplicaIDs.contains(admission.replicaID) == false else {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "duplicate_replica"))
                continue
            }
            if requireDistinctFaultDomains,
               acceptedFaultDomainIDs.contains(admission.faultDomainID) {
                rejections.append(.init(ackID: acknowledgement.ackID, reason: "duplicate_fault_domain"))
                continue
            }
            acceptedReplicaIDs.insert(admission.replicaID)
            acceptedFaultDomainIDs.insert(admission.faultDomainID)
            acceptedAcknowledgementHashes.insert(candidate.evidenceHash)
        }

        let replicaIDs = acceptedReplicaIDs.sorted()
        return EntityAuthorityReplicaQuorumEvaluation(
            policyID: policyID,
            receiptHash: try receipt.entityAuthorityCanonicalHash(),
            requiredReplicaAcks: requiredReplicaAcks,
            validReplicaAckCount: replicaIDs.count,
            acceptedReplicaIDs: replicaIDs,
            acceptedFaultDomainIDs: acceptedFaultDomainIDs.sorted(),
            acceptedAcknowledgementHashes: acceptedAcknowledgementHashes.sorted(),
            rejectedAcknowledgements: rejections,
            quorumSatisfied: replicaIDs.count >= requiredReplicaAcks,
            authorityCertificateRequired: true
        )
    }

    private func validateFields(atEpochMilliseconds: Int) throws {
        guard schema == Self.schema else {
            throw EntityAuthorityReplicationError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(policyID)
        try EntityAuthorityCanonical.validateIdentifier(partitionID)
        guard epoch > 0 else {
            throw EntityAuthorityReplicationError.invalidPolicy("epoch")
        }
        guard requiredReplicaAcks > 0,
              requiredReplicaAcks <= admittedAdmissionIDs.count,
              admittedAdmissionIDs.count <= Self.maximumAdmittedReplicas else {
            throw EntityAuthorityReplicationError.invalidPolicy("required_replica_acks")
        }
        guard admittedAdmissionIDs == admittedAdmissionIDs.sorted(),
              admittedAdmissionIDs.count == Set(admittedAdmissionIDs).count else {
            throw EntityAuthorityReplicationError.invalidPolicy("admission_ids_not_canonical")
        }
        try admittedAdmissionIDs.forEach(EntityAuthorityCanonical.validateIdentifier)
        guard Set(admittedAdmissionHashes.keys) == Set(admittedAdmissionIDs),
              admittedAdmissionHashes.values.allSatisfy({ $0.utf8.count == 64 }) else {
            throw EntityAuthorityReplicationError.invalidPolicy("admission_hashes")
        }
        guard acceptedDurabilityLevels.isEmpty == false,
              acceptedDurabilityLevels == acceptedDurabilityLevels.sorted(),
              acceptedDurabilityLevels.count == Set(acceptedDurabilityLevels).count,
              acceptedDurabilityLevels.contains(EntityAuthorityReplicaDurabilityLevel.transportDeliveryOnly.rawValue) == false else {
            throw EntityAuthorityReplicationError.invalidPolicy("durability_levels")
        }
        guard issuedAtEpochMilliseconds >= 0,
              expiresAtEpochMilliseconds > issuedAtEpochMilliseconds,
              atEpochMilliseconds >= issuedAtEpochMilliseconds,
              atEpochMilliseconds <= expiresAtEpochMilliseconds else {
            throw EntityAuthorityReplicationError.invalidPolicy("validity_window")
        }
    }
}

/// Replica-signed claim that the exact authority receipt was persisted under an admission.
/// The claim can count only after policy, admission, signature, binding, and durability checks.
public struct EntityAuthorityReplicaAcknowledgement: Codable, Equatable {
    public static let schema = "haven.entity-authority-replica-ack.v0"

    public var schema: String
    public var ackID: String
    public var status: String
    public var admissionID: String
    public var replicaID: String
    public var replicaIdentityUUID: String
    public var replicaSigningKeyFingerprint: String
    public var mutationID: String
    public var partitionID: String
    public var epoch: Int
    public var revision: Int
    public var entryHash: String
    public var payloadHash: String
    public var authorityReceiptHash: String
    public var durabilityLevel: String
    public var persistedAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        ackID: String,
        status: String = "replica_persisted",
        admissionID: String,
        replicaID: String,
        replicaIdentityUUID: String,
        replicaSigningKeyFingerprint: String,
        mutationID: String,
        partitionID: String,
        epoch: Int,
        revision: Int,
        entryHash: String,
        payloadHash: String,
        authorityReceiptHash: String,
        durabilityLevel: String,
        persistedAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.ackID = ackID
        self.status = status
        self.admissionID = admissionID
        self.replicaID = replicaID
        self.replicaIdentityUUID = replicaIdentityUUID
        self.replicaSigningKeyFingerprint = replicaSigningKeyFingerprint
        self.mutationID = mutationID
        self.partitionID = partitionID
        self.epoch = epoch
        self.revision = revision
        self.entryHash = entryHash
        self.payloadHash = payloadHash
        self.authorityReceiptHash = authorityReceiptHash
        self.durabilityLevel = durabilityLevel
        self.persistedAtEpochMilliseconds = persistedAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        receipt: EntityAuthorityCommitReceipt,
        admission: EntityAuthorityReplicaAdmission,
        replica: Identity,
        durabilityLevel: EntityAuthorityReplicaDurabilityLevel,
        persistedAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard replica.uuid == admission.replicaIdentity.uuid,
              replica.signingPublicKeyFingerprint == admission.replicaSigningKeyFingerprint else {
            throw EntityAuthorityReplicationError.invalidAcknowledgement("replica_identity_binding")
        }
        let ackMaterial = Data("\(receipt.mutationID)|\(admission.replicaID)|\(admission.admissionID)".utf8)
        let ackID = "ack-" + FlowHasher.sha256Hex(ackMaterial)
        var acknowledgement = Self(
            ackID: ackID,
            admissionID: admission.admissionID,
            replicaID: admission.replicaID,
            replicaIdentityUUID: replica.uuid,
            replicaSigningKeyFingerprint: admission.replicaSigningKeyFingerprint,
            mutationID: receipt.mutationID,
            partitionID: receipt.partitionID,
            epoch: receipt.epoch,
            revision: receipt.revision,
            entryHash: receipt.entryHash,
            payloadHash: receipt.payloadHash,
            authorityReceiptHash: try receipt.entityAuthorityCanonicalHash(),
            durabilityLevel: durabilityLevel.rawValue,
            persistedAtEpochMilliseconds: persistedAtEpochMilliseconds,
            signature: Data()
        )
        guard let signature = try await replica.sign(data: acknowledgement.signingData()) else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        acknowledgement.signature = signature
        return acknowledgement
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityReplicaAcknowledgement(self))
    }

    public func verifies(
        receipt: EntityAuthorityCommitReceipt,
        admission: EntityAuthorityReplicaAdmission,
        atEpochMilliseconds: Int
    ) -> Bool {
        do {
            guard schema == Self.schema,
                  status == "replica_persisted",
                  admissionID == admission.admissionID,
                  replicaID == admission.replicaID,
                  replicaIdentityUUID == admission.replicaIdentity.uuid,
                  replicaSigningKeyFingerprint == admission.replicaSigningKeyFingerprint,
                  mutationID == receipt.mutationID,
                  partitionID == receipt.partitionID,
                  partitionID == admission.partitionID,
                  epoch == receipt.epoch,
                  epoch == admission.epoch,
                  revision == receipt.revision,
                  entryHash == receipt.entryHash,
                  payloadHash == receipt.payloadHash,
                  authorityReceiptHash == (try receipt.entityAuthorityCanonicalHash()),
                  persistedAtEpochMilliseconds >= admission.issuedAtEpochMilliseconds,
                  persistedAtEpochMilliseconds <= admission.expiresAtEpochMilliseconds,
                  atEpochMilliseconds >= persistedAtEpochMilliseconds else {
                return false
            }
            try EntityAuthorityCanonical.validateIdentifier(ackID)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                descriptor: admission.replicaIdentity
            )
        } catch {
            return false
        }
    }
}

public struct EntityAuthorityReplicaAckRejection: Codable, Equatable {
    public var ackID: String
    public var reason: String

    public init(ackID: String, reason: String) {
        self.ackID = ackID
        self.reason = reason
    }
}

/// Deterministic evaluation result. It is not itself an authority-signed commit certificate.
public struct EntityAuthorityReplicaQuorumEvaluation: Codable, Equatable {
    public var policyID: String
    public var receiptHash: String
    public var requiredReplicaAcks: Int
    public var validReplicaAckCount: Int
    public var acceptedReplicaIDs: [String]
    public var acceptedFaultDomainIDs: [String]
    /// Hashes of the accepted signed acknowledgement content, excluding the signature bytes.
    /// This stays stable when a signer legitimately produces a new signature for the same claim.
    public var acceptedAcknowledgementHashes: [String]
    public var rejectedAcknowledgements: [EntityAuthorityReplicaAckRejection]
    public var quorumSatisfied: Bool
    public var authorityCertificateRequired: Bool

    public init(
        policyID: String,
        receiptHash: String,
        requiredReplicaAcks: Int,
        validReplicaAckCount: Int,
        acceptedReplicaIDs: [String],
        acceptedFaultDomainIDs: [String],
        acceptedAcknowledgementHashes: [String],
        rejectedAcknowledgements: [EntityAuthorityReplicaAckRejection],
        quorumSatisfied: Bool,
        authorityCertificateRequired: Bool
    ) {
        self.policyID = policyID
        self.receiptHash = receiptHash
        self.requiredReplicaAcks = requiredReplicaAcks
        self.validReplicaAckCount = validReplicaAckCount
        self.acceptedReplicaIDs = acceptedReplicaIDs
        self.acceptedFaultDomainIDs = acceptedFaultDomainIDs
        self.acceptedAcknowledgementHashes = acceptedAcknowledgementHashes
        self.rejectedAcknowledgements = rejectedAcknowledgements
        self.quorumSatisfied = quorumSatisfied
        self.authorityCertificateRequired = authorityCertificateRequired
    }
}

/// Authority-signed attestation that a specific receipt satisfied a specific replica policy.
/// The original receipt remains immutable and local-authority-only; this supplemental certificate
/// is the proof of distributed commit within the explicitly named quorum and durability policy.
public struct EntityAuthorityReplicaQuorumCertificate: Codable, Equatable {
    public static let schema = "haven.entity-authority-replica-quorum-certificate.v0"

    public var schema: String
    public var certificateID: String
    public var status: String
    public var mutationID: String
    public var partitionID: String
    public var epoch: Int
    public var revision: Int
    public var entryHash: String
    public var payloadHash: String
    public var receiptHash: String
    public var policyID: String
    public var policyHash: String
    public var evaluationHash: String
    public var requiredReplicaAcks: Int
    public var replicaAckCount: Int
    public var acceptedReplicaIDs: [String]
    public var acceptedFaultDomainIDs: [String]
    public var acceptedAcknowledgementHashes: [String]
    public var distributedCommit: Bool
    public var authorityIdentityUUID: String
    public var authoritySigningKeyFingerprint: String
    public var certifiedAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        certificateID: String,
        status: String = "replica_quorum_certified",
        mutationID: String,
        partitionID: String,
        epoch: Int,
        revision: Int,
        entryHash: String,
        payloadHash: String,
        receiptHash: String,
        policyID: String,
        policyHash: String,
        evaluationHash: String,
        requiredReplicaAcks: Int,
        replicaAckCount: Int,
        acceptedReplicaIDs: [String],
        acceptedFaultDomainIDs: [String],
        acceptedAcknowledgementHashes: [String],
        distributedCommit: Bool = true,
        authorityIdentityUUID: String,
        authoritySigningKeyFingerprint: String,
        certifiedAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.certificateID = certificateID
        self.status = status
        self.mutationID = mutationID
        self.partitionID = partitionID
        self.epoch = epoch
        self.revision = revision
        self.entryHash = entryHash
        self.payloadHash = payloadHash
        self.receiptHash = receiptHash
        self.policyID = policyID
        self.policyHash = policyHash
        self.evaluationHash = evaluationHash
        self.requiredReplicaAcks = requiredReplicaAcks
        self.replicaAckCount = replicaAckCount
        self.acceptedReplicaIDs = acceptedReplicaIDs
        self.acceptedFaultDomainIDs = acceptedFaultDomainIDs
        self.acceptedAcknowledgementHashes = acceptedAcknowledgementHashes
        self.distributedCommit = distributedCommit
        self.authorityIdentityUUID = authorityIdentityUUID
        self.authoritySigningKeyFingerprint = authoritySigningKeyFingerprint
        self.certifiedAtEpochMilliseconds = certifiedAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        receipt: EntityAuthorityCommitReceipt,
        policy: EntityAuthorityReplicaQuorumPolicy,
        admissions: [EntityAuthorityReplicaAdmission],
        acknowledgements: [EntityAuthorityReplicaAcknowledgement],
        authority: Identity,
        certifiedAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard let authorityFingerprint = authority.signingPublicKeyFingerprint else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        let evaluation = try policy.evaluate(
            receipt: receipt,
            authority: authority,
            admissions: admissions,
            acknowledgements: acknowledgements,
            atEpochMilliseconds: certifiedAtEpochMilliseconds
        )
        guard evaluation.quorumSatisfied,
              evaluation.authorityCertificateRequired,
              evaluation.validReplicaAckCount >= evaluation.requiredReplicaAcks,
              evaluation.acceptedAcknowledgementHashes.count == evaluation.validReplicaAckCount else {
            throw EntityAuthorityReplicationError.invalidCertificate("quorum_not_satisfied")
        }

        let receiptHash = try receipt.entityAuthorityCanonicalHash()
        let policyHash = try policy.entityAuthorityCanonicalHash()
        let evaluationHash = try evaluation.entityAuthorityCanonicalHash()
        let certificateMaterial = Data("\(receiptHash)|\(policyHash)|\(evaluationHash)".utf8)
        var certificate = Self(
            certificateID: "certificate-" + FlowHasher.sha256Hex(certificateMaterial),
            mutationID: receipt.mutationID,
            partitionID: receipt.partitionID,
            epoch: receipt.epoch,
            revision: receipt.revision,
            entryHash: receipt.entryHash,
            payloadHash: receipt.payloadHash,
            receiptHash: receiptHash,
            policyID: policy.policyID,
            policyHash: policyHash,
            evaluationHash: evaluationHash,
            requiredReplicaAcks: evaluation.requiredReplicaAcks,
            replicaAckCount: evaluation.validReplicaAckCount,
            acceptedReplicaIDs: evaluation.acceptedReplicaIDs,
            acceptedFaultDomainIDs: evaluation.acceptedFaultDomainIDs,
            acceptedAcknowledgementHashes: evaluation.acceptedAcknowledgementHashes,
            authorityIdentityUUID: authority.uuid,
            authoritySigningKeyFingerprint: authorityFingerprint,
            certifiedAtEpochMilliseconds: certifiedAtEpochMilliseconds,
            signature: Data()
        )
        try certificate.validateFields(receipt: receipt, policy: policy, evaluation: evaluation, authority: authority)
        guard let signature = try await authority.sign(data: certificate.signingData()) else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        certificate.signature = signature
        guard certificate.verifies(
            receipt: receipt,
            policy: policy,
            evaluation: evaluation,
            authority: authority
        ) else {
            throw EntityAuthorityReplicationError.signingUnavailable
        }
        return certificate
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedEntityAuthorityReplicaQuorumCertificate(self))
    }

    public func verifies(
        receipt: EntityAuthorityCommitReceipt,
        policy: EntityAuthorityReplicaQuorumPolicy,
        evaluation: EntityAuthorityReplicaQuorumEvaluation,
        authority: Identity
    ) -> Bool {
        do {
            try validateFields(receipt: receipt, policy: policy, evaluation: evaluation, authority: authority)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: authority
            )
        } catch {
            return false
        }
    }

    public init(value: ValueType) throws {
        self = try EntityAuthorityCanonical.decode(Self.self, from: value)
    }

    public func valueType() throws -> ValueType {
        try EntityAuthorityCanonical.valueType(self)
    }

    private func validateFields(
        receipt: EntityAuthorityCommitReceipt,
        policy: EntityAuthorityReplicaQuorumPolicy,
        evaluation: EntityAuthorityReplicaQuorumEvaluation,
        authority: Identity
    ) throws {
        guard schema == Self.schema else {
            throw EntityAuthorityReplicationError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(certificateID)
        guard status == "replica_quorum_certified", distributedCommit else {
            throw EntityAuthorityReplicationError.invalidCertificate("status")
        }
        guard receipt.verifies(with: authority),
              policy.verifies(authority: authority, atEpochMilliseconds: certifiedAtEpochMilliseconds) else {
            throw EntityAuthorityReplicationError.invalidCertificate("authority_material")
        }
        guard authority.uuid == authorityIdentityUUID,
              authority.signingPublicKeyFingerprint == authoritySigningKeyFingerprint,
              certifiedAtEpochMilliseconds >= receipt.committedAtEpochMilliseconds else {
            throw EntityAuthorityReplicationError.invalidCertificate("authority_binding")
        }
        guard mutationID == receipt.mutationID,
              partitionID == receipt.partitionID,
              epoch == receipt.epoch,
              revision == receipt.revision,
              entryHash == receipt.entryHash,
              payloadHash == receipt.payloadHash,
              receiptHash == (try receipt.entityAuthorityCanonicalHash()) else {
            throw EntityAuthorityReplicationError.invalidCertificate("receipt_binding")
        }
        guard policyID == policy.policyID,
              partitionID == policy.partitionID,
              epoch == policy.epoch,
              policyHash == (try policy.entityAuthorityCanonicalHash()) else {
            throw EntityAuthorityReplicationError.invalidCertificate("policy_binding")
        }
        guard evaluation.policyID == policyID,
              evaluation.receiptHash == receiptHash,
              evaluation.quorumSatisfied,
              evaluation.authorityCertificateRequired,
              evaluationHash == (try evaluation.entityAuthorityCanonicalHash()),
              requiredReplicaAcks == evaluation.requiredReplicaAcks,
              replicaAckCount == evaluation.validReplicaAckCount,
              replicaAckCount >= requiredReplicaAcks,
              acceptedReplicaIDs == evaluation.acceptedReplicaIDs,
              acceptedFaultDomainIDs == evaluation.acceptedFaultDomainIDs,
              acceptedAcknowledgementHashes == evaluation.acceptedAcknowledgementHashes,
              acceptedReplicaIDs.count == replicaAckCount,
              acceptedAcknowledgementHashes.count == replicaAckCount else {
            throw EntityAuthorityReplicationError.invalidCertificate("evaluation_binding")
        }
        guard acceptedReplicaIDs == acceptedReplicaIDs.sorted(),
              acceptedReplicaIDs.count == Set(acceptedReplicaIDs).count,
              acceptedFaultDomainIDs == acceptedFaultDomainIDs.sorted(),
              acceptedFaultDomainIDs.count == Set(acceptedFaultDomainIDs).count,
              acceptedAcknowledgementHashes == acceptedAcknowledgementHashes.sorted(),
              acceptedAcknowledgementHashes.count == Set(acceptedAcknowledgementHashes).count,
              acceptedAcknowledgementHashes.allSatisfy({ $0.utf8.count == 64 }) else {
            throw EntityAuthorityReplicationError.invalidCertificate("noncanonical_evidence")
        }
        let expectedCertificateID = "certificate-" + FlowHasher.sha256Hex(
            Data("\(receiptHash)|\(policyHash)|\(evaluationHash)".utf8)
        )
        guard certificateID == expectedCertificateID else {
            throw EntityAuthorityReplicationError.invalidCertificate("certificate_id")
        }
    }
}

public struct EntityAuthorityReplayRangeRequest: Codable, Equatable {
    public static let schema = "haven.entity-authority-replay-range-request.v0"
    public static let maximumEntryCount = 4_096

    public var schema: String
    public var partitionID: String
    public var epoch: Int
    public var startRevision: Int
    public var endRevision: Int
    public var expectedPreviousHash: String?

    public init(
        schema: String = Self.schema,
        partitionID: String,
        epoch: Int,
        startRevision: Int,
        endRevision: Int,
        expectedPreviousHash: String?
    ) {
        self.schema = schema
        self.partitionID = partitionID
        self.epoch = epoch
        self.startRevision = startRevision
        self.endRevision = endRevision
        self.expectedPreviousHash = expectedPreviousHash
    }

    public func validate() throws {
        guard schema == Self.schema else {
            throw EntityAuthorityReplicationError.invalidSchema(schema)
        }
        try EntityAuthorityCanonical.validateIdentifier(partitionID)
        guard epoch > 0,
              startRevision > 0,
              endRevision >= startRevision,
              endRevision - startRevision < Self.maximumEntryCount else {
            throw EntityAuthorityReplicationError.invalidReplayRequest("revision_range")
        }
    }
}

public enum EntityAuthorityReplayRangeStatus: String, Codable, Sendable {
    case complete
    case incomplete
    case conflict
}

public struct EntityAuthorityReplayRangeResponse: Codable, Equatable {
    public static let schema = "haven.entity-authority-replay-range-response.v0"

    public var schema: String
    public var partitionID: String
    public var epoch: Int
    public var startRevision: Int
    public var endRevision: Int
    public var expectedPreviousHash: String?
    public var status: EntityAuthorityReplayRangeStatus
    public var entries: [EntityAuthorityJournalEntry]
    public var sourceHeadRevision: Int
    public var sourceHeadHash: String?
    public var nextMissingRevision: Int?
    public var conflictReason: String?

    public init(
        schema: String = Self.schema,
        partitionID: String,
        epoch: Int,
        startRevision: Int,
        endRevision: Int,
        expectedPreviousHash: String?,
        status: EntityAuthorityReplayRangeStatus,
        entries: [EntityAuthorityJournalEntry],
        sourceHeadRevision: Int,
        sourceHeadHash: String?,
        nextMissingRevision: Int?,
        conflictReason: String?
    ) {
        self.schema = schema
        self.partitionID = partitionID
        self.epoch = epoch
        self.startRevision = startRevision
        self.endRevision = endRevision
        self.expectedPreviousHash = expectedPreviousHash
        self.status = status
        self.entries = entries
        self.sourceHeadRevision = sourceHeadRevision
        self.sourceHeadHash = sourceHeadHash
        self.nextMissingRevision = nextMissingRevision
        self.conflictReason = conflictReason
    }

    public func validate(for request: EntityAuthorityReplayRangeRequest) throws {
        try request.validate()
        guard schema == Self.schema else {
            throw EntityAuthorityReplicationError.invalidSchema(schema)
        }
        guard partitionID == request.partitionID,
              epoch == request.epoch,
              startRevision == request.startRevision,
              endRevision == request.endRevision,
              expectedPreviousHash == request.expectedPreviousHash else {
            throw EntityAuthorityReplicationError.invalidReplayResponse("request_binding")
        }
        guard entries.count <= EntityAuthorityReplayRangeRequest.maximumEntryCount else {
            throw EntityAuthorityReplicationError.invalidReplayResponse("entry_limit")
        }
        guard sourceHeadRevision >= 0,
              (sourceHeadRevision == 0) == (sourceHeadHash == nil) else {
            throw EntityAuthorityReplicationError.invalidReplayResponse("source_head")
        }

        var expectedRevision = startRevision
        var previousHash = expectedPreviousHash
        for entry in entries {
            try entry.validateReplayBinding(
                partitionID: partitionID,
                epoch: epoch,
                expectedRevision: expectedRevision,
                expectedPreviousHash: previousHash
            )
            expectedRevision += 1
            previousHash = entry.entryHash
        }

        switch status {
        case .complete:
            guard entries.last?.revision == endRevision,
                  nextMissingRevision == nil,
                  conflictReason == nil,
                  sourceHeadRevision >= endRevision else {
                throw EntityAuthorityReplicationError.invalidReplayResponse("false_complete")
            }
        case .incomplete:
            let nextRevision = entries.last.map { $0.revision + 1 } ?? startRevision
            guard nextRevision <= endRevision,
                  nextMissingRevision == nextRevision,
                  conflictReason == nil,
                  sourceHeadRevision < endRevision else {
                throw EntityAuthorityReplicationError.invalidReplayResponse("incomplete_shape")
            }
        case .conflict:
            guard entries.isEmpty,
                  nextMissingRevision == startRevision,
                  conflictReason?.isEmpty == false else {
                throw EntityAuthorityReplicationError.invalidReplayResponse("conflict_shape")
            }
        }
    }

    public func verifies(
        for request: EntityAuthorityReplayRangeRequest,
        authority: Identity
    ) -> Bool {
        do {
            try validate(for: request)
            guard status != .conflict else {
                return false
            }
            return entries.allSatisfy { $0.receipt.verifies(with: authority) }
        } catch {
            return false
        }
    }

    /// Applies only a complete, receipt-verified range. Partial replay is never silently committed.
    public func applying(
        to base: Entity,
        for request: EntityAuthorityReplayRangeRequest,
        authority: Identity
    ) throws -> Entity {
        guard status == .complete,
              verifies(for: request, authority: authority) else {
            throw EntityAuthorityReplicationError.invalidReplayResponse("range_not_complete_and_verified")
        }
        var snapshot = base
        for entry in entries {
            for mutation in entry.mutations {
                try snapshot.set(keypath: mutation.keypath, setValue: mutation.value)
            }
        }
        return snapshot
    }
}

public extension EntityAuthorityJournalDocument {
    func replayRange(
        for request: EntityAuthorityReplayRangeRequest
    ) throws -> EntityAuthorityReplayRangeResponse {
        try request.validate()
        try validateStructure()
        guard request.partitionID == partitionID else {
            throw EntityAuthorityReplicationError.invalidReplayRequest("partition")
        }
        guard request.epoch == epoch else {
            throw EntityAuthorityReplicationError.invalidReplayRequest("epoch")
        }

        if request.startRevision > revision + 1 {
            return EntityAuthorityReplayRangeResponse(
                partitionID: partitionID,
                epoch: epoch,
                startRevision: request.startRevision,
                endRevision: request.endRevision,
                expectedPreviousHash: request.expectedPreviousHash,
                status: .incomplete,
                entries: [],
                sourceHeadRevision: revision,
                sourceHeadHash: headHash,
                nextMissingRevision: request.startRevision,
                conflictReason: nil
            )
        }

        let actualPreviousHash: String? = request.startRevision == 1
            ? nil
            : entries[request.startRevision - 2].entryHash
        guard actualPreviousHash == request.expectedPreviousHash else {
            return EntityAuthorityReplayRangeResponse(
                partitionID: partitionID,
                epoch: epoch,
                startRevision: request.startRevision,
                endRevision: request.endRevision,
                expectedPreviousHash: request.expectedPreviousHash,
                status: .conflict,
                entries: [],
                sourceHeadRevision: revision,
                sourceHeadHash: headHash,
                nextMissingRevision: request.startRevision,
                conflictReason: "previous_hash_mismatch"
            )
        }

        let availableEndRevision = min(request.endRevision, revision)
        let rangeEntries: [EntityAuthorityJournalEntry]
        if availableEndRevision < request.startRevision {
            rangeEntries = []
        } else {
            rangeEntries = Array(entries[(request.startRevision - 1)...(availableEndRevision - 1)])
        }
        let complete = availableEndRevision == request.endRevision
        return EntityAuthorityReplayRangeResponse(
            partitionID: partitionID,
            epoch: epoch,
            startRevision: request.startRevision,
            endRevision: request.endRevision,
            expectedPreviousHash: request.expectedPreviousHash,
            status: complete ? .complete : .incomplete,
            entries: rangeEntries,
            sourceHeadRevision: revision,
            sourceHeadHash: headHash,
            nextMissingRevision: complete ? nil : availableEndRevision + 1,
            conflictReason: nil
        )
    }
}

public extension EntityAuthorityCommitReceipt {
    func entityAuthorityCanonicalHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: self))
    }
}

public extension EntityAuthorityReplicaAdmission {
    func entityAuthorityCanonicalHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: self))
    }
}

public extension EntityAuthorityReplicaQuorumPolicy {
    func entityAuthorityCanonicalHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: self))
    }
}

public extension EntityAuthorityReplicaAcknowledgement {
    /// Hash of the signed claim rather than the signature bytes, so legitimate re-signing
    /// of the same evidence cannot create a second quorum vote.
    func entityAuthorityEvidenceHash() throws -> String {
        FlowHasher.sha256Hex(try signingData())
    }
}

public extension EntityAuthorityReplicaQuorumEvaluation {
    func entityAuthorityCanonicalHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: self))
    }
}

private extension EntityAuthorityJournalEntry {
    func validateReplayBinding(
        partitionID: String,
        epoch: Int,
        expectedRevision: Int,
        expectedPreviousHash: String?
    ) throws {
        let envelope = EntityBatchPersistEnvelope(
            schema: envelopeSchema,
            mutations: mutations,
            metadata: metadata
        )
        guard schema == Self.schema,
              revision == expectedRevision,
              previousHash == expectedPreviousHash,
              request.partitionID == partitionID,
              request.epoch == epoch,
              request.payloadHash == (try envelope.authorityPayloadHash()),
              entryHash == (try calculatedEntryHash()),
              receipt.mutationID == request.mutationID,
              receipt.partitionID == partitionID,
              receipt.epoch == epoch,
              receipt.revision == revision,
              receipt.previousHash == previousHash,
              receipt.entryHash == entryHash,
              receipt.payloadHash == request.payloadHash else {
            throw EntityAuthorityReplicationError.invalidReplayResponse("entry_binding_at_revision_\(revision)")
        }
    }
}

private extension IdentityPublicKeyDescriptor {
    var entityAuthoritySigningKeyFingerprint: String {
        [
            algorithm.rawValue,
            curveType.rawValue,
            publicKey.base64EncodedString()
        ].joined(separator: ":")
    }
}

private struct UnsignedEntityAuthorityReplicaAdmission: Codable {
    var schema: String
    var admissionID: String
    var replicaID: String
    var partitionID: String
    var epoch: Int
    var faultDomainID: String
    var replicaIdentity: IdentityPublicKeyDescriptor
    var replicaSigningKeyFingerprint: String
    var capability: String
    var authorityIdentityUUID: String
    var authoritySigningKeyFingerprint: String
    var issuedAtEpochMilliseconds: Int
    var expiresAtEpochMilliseconds: Int

    init(_ admission: EntityAuthorityReplicaAdmission) {
        schema = admission.schema
        admissionID = admission.admissionID
        replicaID = admission.replicaID
        partitionID = admission.partitionID
        epoch = admission.epoch
        faultDomainID = admission.faultDomainID
        replicaIdentity = admission.replicaIdentity
        replicaSigningKeyFingerprint = admission.replicaSigningKeyFingerprint
        capability = admission.capability
        authorityIdentityUUID = admission.authorityIdentityUUID
        authoritySigningKeyFingerprint = admission.authoritySigningKeyFingerprint
        issuedAtEpochMilliseconds = admission.issuedAtEpochMilliseconds
        expiresAtEpochMilliseconds = admission.expiresAtEpochMilliseconds
    }
}

private struct UnsignedEntityAuthorityReplicaQuorumPolicy: Codable {
    var schema: String
    var policyID: String
    var partitionID: String
    var epoch: Int
    var requiredReplicaAcks: Int
    var admittedAdmissionIDs: [String]
    var admittedAdmissionHashes: [String: String]
    var acceptedDurabilityLevels: [String]
    var requireDistinctFaultDomains: Bool
    var authorityIdentityUUID: String
    var authoritySigningKeyFingerprint: String
    var issuedAtEpochMilliseconds: Int
    var expiresAtEpochMilliseconds: Int

    init(_ policy: EntityAuthorityReplicaQuorumPolicy) {
        schema = policy.schema
        policyID = policy.policyID
        partitionID = policy.partitionID
        epoch = policy.epoch
        requiredReplicaAcks = policy.requiredReplicaAcks
        admittedAdmissionIDs = policy.admittedAdmissionIDs
        admittedAdmissionHashes = policy.admittedAdmissionHashes
        acceptedDurabilityLevels = policy.acceptedDurabilityLevels
        requireDistinctFaultDomains = policy.requireDistinctFaultDomains
        authorityIdentityUUID = policy.authorityIdentityUUID
        authoritySigningKeyFingerprint = policy.authoritySigningKeyFingerprint
        issuedAtEpochMilliseconds = policy.issuedAtEpochMilliseconds
        expiresAtEpochMilliseconds = policy.expiresAtEpochMilliseconds
    }
}

private struct UnsignedEntityAuthorityReplicaAcknowledgement: Codable {
    var schema: String
    var ackID: String
    var status: String
    var admissionID: String
    var replicaID: String
    var replicaIdentityUUID: String
    var replicaSigningKeyFingerprint: String
    var mutationID: String
    var partitionID: String
    var epoch: Int
    var revision: Int
    var entryHash: String
    var payloadHash: String
    var authorityReceiptHash: String
    var durabilityLevel: String
    var persistedAtEpochMilliseconds: Int

    init(_ acknowledgement: EntityAuthorityReplicaAcknowledgement) {
        schema = acknowledgement.schema
        ackID = acknowledgement.ackID
        status = acknowledgement.status
        admissionID = acknowledgement.admissionID
        replicaID = acknowledgement.replicaID
        replicaIdentityUUID = acknowledgement.replicaIdentityUUID
        replicaSigningKeyFingerprint = acknowledgement.replicaSigningKeyFingerprint
        mutationID = acknowledgement.mutationID
        partitionID = acknowledgement.partitionID
        epoch = acknowledgement.epoch
        revision = acknowledgement.revision
        entryHash = acknowledgement.entryHash
        payloadHash = acknowledgement.payloadHash
        authorityReceiptHash = acknowledgement.authorityReceiptHash
        durabilityLevel = acknowledgement.durabilityLevel
        persistedAtEpochMilliseconds = acknowledgement.persistedAtEpochMilliseconds
    }
}

private struct UnsignedEntityAuthorityReplicaQuorumCertificate: Codable {
    var schema: String
    var certificateID: String
    var status: String
    var mutationID: String
    var partitionID: String
    var epoch: Int
    var revision: Int
    var entryHash: String
    var payloadHash: String
    var receiptHash: String
    var policyID: String
    var policyHash: String
    var evaluationHash: String
    var requiredReplicaAcks: Int
    var replicaAckCount: Int
    var acceptedReplicaIDs: [String]
    var acceptedFaultDomainIDs: [String]
    var acceptedAcknowledgementHashes: [String]
    var distributedCommit: Bool
    var authorityIdentityUUID: String
    var authoritySigningKeyFingerprint: String
    var certifiedAtEpochMilliseconds: Int

    init(_ certificate: EntityAuthorityReplicaQuorumCertificate) {
        schema = certificate.schema
        certificateID = certificate.certificateID
        status = certificate.status
        mutationID = certificate.mutationID
        partitionID = certificate.partitionID
        epoch = certificate.epoch
        revision = certificate.revision
        entryHash = certificate.entryHash
        payloadHash = certificate.payloadHash
        receiptHash = certificate.receiptHash
        policyID = certificate.policyID
        policyHash = certificate.policyHash
        evaluationHash = certificate.evaluationHash
        requiredReplicaAcks = certificate.requiredReplicaAcks
        replicaAckCount = certificate.replicaAckCount
        acceptedReplicaIDs = certificate.acceptedReplicaIDs
        acceptedFaultDomainIDs = certificate.acceptedFaultDomainIDs
        acceptedAcknowledgementHashes = certificate.acceptedAcknowledgementHashes
        distributedCommit = certificate.distributedCommit
        authorityIdentityUUID = certificate.authorityIdentityUUID
        authoritySigningKeyFingerprint = certificate.authoritySigningKeyFingerprint
        certifiedAtEpochMilliseconds = certificate.certifiedAtEpochMilliseconds
    }
}
