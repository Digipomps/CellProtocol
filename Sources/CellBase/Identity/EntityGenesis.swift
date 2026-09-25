// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.entitetsdata.genesis-seals-to-initiator
//
// Genesis is the one moment that cannot be undone. The first time an entity
// needs to persist entity data, its anchor is sealed to the identity that
// started it: a single IdentityLinkRecord, issued by the initiator to itself,
// bound to this anchor, and signed so the seal can be verified later without
// trusting the storage it was read from.
//
// Everything about entity ownership rests on this record. There is no
// "unseal", and a second genesis against a sealed anchor is refused.

public enum EntityGenesisTrigger: String, Codable, Sendable, CaseIterable {
    case onboarding
    case addressBookImport
    case verifiableCredential
    case fileUpload
    case directEdit
    /// The anchor had to persist something and nobody named a trigger. Recorded
    /// honestly rather than guessed.
    case firstPersist
}

public enum EntityGenesisError: Error, Equatable, Sendable {
    case alreadySealed(linkID: String)
    case notSealed
    case initiatorHasNoSigningKey(String)
    case initiatorIsNotOwner(requester: String, owner: String)
    case sealProofInvalid
    case sealDoesNotMatchRecord(String)
    case cannotRevokeGenesisLink(String)
    case genesisKeypathIsImmutable(String)
}

/// The seal itself. Stored at `identityLinks.genesis`; its presence means the
/// anchor is sealed. The `proof` is the initiator's signature over the
/// canonical payload of every other field.
public struct EntityGenesisSeal: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var anchorID: String
    public var sealedAt: String
    public var trigger: EntityGenesisTrigger
    public var linkID: String
    public var initiatorIdentityUUID: String
    public var proof: IdentityEnrollmentApprovalProof?

    public init(
        version: Int = 1,
        anchorID: String,
        sealedAt: String,
        trigger: EntityGenesisTrigger,
        linkID: String,
        initiatorIdentityUUID: String,
        proof: IdentityEnrollmentApprovalProof? = nil
    ) {
        self.version = version
        self.anchorID = anchorID
        self.sealedAt = sealedAt
        self.trigger = trigger
        self.linkID = linkID
        self.initiatorIdentityUUID = initiatorIdentityUUID
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

public struct EntityGenesisResult: Equatable, Sendable {
    public var seal: EntityGenesisSeal
    public var record: IdentityLinkRecord
}

public enum EntityGenesisService {
    public static let sealKeypath = "identityLinks.genesis"
    public static let recordsKeypath = "identityLinks.records"
    public static let genesisLinkIDPrefix = "genesis-"

    /// The initiator acts *as* the entity. `IdentityLinkScope.sameEntity` is the
    /// scope `GeneralCell.authorizationEvidence` already honours through
    /// `IdentityLinkRegistry`, so a genesis link goes through the same path as
    /// any other same-entity link — there is no second resolver.
    public static let initiatorScopes = [IdentityLinkScope.sameEntity]

    /// Convention used by enrollment requests and `Identity.entityAnchorReference`.
    public static let anchorReference = "cell:///EntityAnchor"

    public static func genesisLinkID(anchorID: String) -> String {
        genesisLinkIDPrefix + anchorID
    }

    /// Builds and signs the seal. Pure apart from the signature: nothing is
    /// stored here. The caller must already have proven that `initiator` is
    /// the anchor's owner — this function cannot check that and says so.
    public static func seal(
        anchorID: String,
        initiator: Identity,
        identityDomain: String,
        trigger: EntityGenesisTrigger,
        now: Date = Date()
    ) async throws -> EntityGenesisResult {
        let descriptor: IdentityPublicKeyDescriptor
        do {
            descriptor = try IdentityLinkProtocolService.descriptor(for: initiator)
        } catch {
            throw EntityGenesisError.initiatorHasNoSigningKey(initiator.uuid)
        }

        let sealedAt = IdentityLinkProtocolService.iso8601(now)
        let linkID = genesisLinkID(anchorID: anchorID)

        let record = IdentityLinkRecord(
            linkID: linkID,
            entityBinding: EntityBindingDescriptor(
                mode: .localEntityAnchor,
                entityAnchorReference: anchorReference
            ),
            linkedIdentity: descriptor,
            approvedDomains: [identityDomain],
            approvedIdentityContexts: [],
            approvedScopes: initiatorScopes,
            issuerIdentityUUID: initiator.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: sealedAt
        )

        var seal = EntityGenesisSeal(
            anchorID: anchorID,
            sealedAt: sealedAt,
            trigger: trigger,
            linkID: linkID,
            initiatorIdentityUUID: initiator.uuid
        )
        let payload = try seal.canonicalPayloadData()
        guard let signature = try await initiator.sign(data: payload) else {
            throw IdentityVaultError.signingFailed
        }
        seal.proof = IdentityEnrollmentApprovalProof(
            issuerIdentityUUID: initiator.uuid,
            issuerType: .existingDevice,
            algorithm: descriptor.algorithm,
            curveType: descriptor.curveType,
            signature: signature
        )
        return EntityGenesisResult(seal: seal, record: record)
    }

    /// Verifies a stored seal against the record it points at. Both come from
    /// storage, so neither is trusted on its own: the seal must be signed by
    /// the key in the record, and the two must describe the same link.
    public static func verify(seal: EntityGenesisSeal, record: IdentityLinkRecord) throws {
        guard seal.linkID == record.linkID else {
            throw EntityGenesisError.sealDoesNotMatchRecord("linkID")
        }
        guard seal.initiatorIdentityUUID == record.linkedIdentity.uuid,
              seal.initiatorIdentityUUID == record.issuerIdentityUUID else {
            throw EntityGenesisError.sealDoesNotMatchRecord("initiator")
        }
        guard record.entityBinding.mode == .localEntityAnchor else {
            throw EntityGenesisError.sealDoesNotMatchRecord("entityBinding")
        }
        guard record.issuerType == .existingDevice, record.status == .active else {
            throw EntityGenesisError.sealDoesNotMatchRecord("record")
        }
        guard let signature = seal.proof?.signature else {
            throw EntityGenesisError.sealProofInvalid
        }
        let payload = try seal.canonicalPayloadData()
        guard IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: payload,
            descriptor: record.linkedIdentity
        ) else {
            throw EntityGenesisError.sealProofInvalid
        }
    }

    public static func isGenesisLink(_ linkID: String) -> Bool {
        linkID.hasPrefix(genesisLinkIDPrefix)
    }

    /// Keypaths that no set may touch except genesis itself.
    public static func isImmutableGenesisKeypath(_ keypath: String) -> Bool {
        keypath == sealKeypath || keypath.hasPrefix(sealKeypath + ".")
    }

    public static func safeRecordKey(_ linkID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(linkID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    public static func recordKeypath(linkID: String) -> String {
        recordsKeypath + "." + safeRecordKey(linkID)
    }
}
