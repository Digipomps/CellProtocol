// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Account erasure contract (PDD_kontosletting_2026-11-20, AP1).
///
/// A holder is any cell or store that keeps data per owner. The identity cell
/// asks every holder, in order: inventory → export → expireAfter (safety net)
/// → erase. Each holder answers erase with a receipt signed by the holder.
///
/// This file defines the contract only. No holder in CellBase implements it
/// yet; holders land in the scaffolds (AP3).
public protocol PersonalDataHolder: Sendable {
    /// Stable name of the holder, used in receipts and inventory rows.
    var personalDataHolderID: String { get }

    /// What the holder keeps about the owner. Never the data itself.
    func inventory(owner: Identity) async throws -> [PersonalDataInventoryRow]

    /// Everything the holder keeps about the owner, for the export file.
    func export(owner: Identity) async throws -> PersonalDataExportPart

    /// Removes the owner's data. Implementations must call
    /// `request.verify(owner:)` before removing anything.
    func erase(_ request: ErasureRequest) async throws -> ErasureReceipt

    /// Arms a deadline after which everything the holder keeps about the owner
    /// is removed, even if `erase` never arrives (AP8 safety net).
    func expireAfter(owner: Identity, ttl: TimeInterval) async throws -> PersonalDataExpiry
}

public struct PersonalDataInventoryRow: Codable, Equatable, Sendable {
    public var holder: String
    /// Kind of record, e.g. "chat.message", "profile", "push.token".
    public var kind: String
    public var count: Int
    public var exportable: Bool
    public var erasable: Bool

    public init(holder: String, kind: String, count: Int, exportable: Bool = true, erasable: Bool = true) {
        self.holder = holder
        self.kind = kind
        self.count = count
        self.exportable = exportable
        self.erasable = erasable
    }
}

public struct PersonalDataExportPart: Codable, Equatable {
    public var holder: String
    public var ownerEntity: String
    public var records: [ValueType]

    public init(holder: String, ownerEntity: String, records: [ValueType]) {
        self.holder = holder
        self.ownerEntity = ownerEntity
        self.records = records
    }
}

public struct PersonalDataExpiry: Codable, Equatable, Sendable {
    public var holder: String
    public var ownerEntity: String
    public var expiresAt: Date

    public init(holder: String, ownerEntity: String, expiresAt: Date) {
        self.holder = holder
        self.ownerEntity = ownerEntity
        self.expiresAt = expiresAt
    }
}

public enum ErasureKeyChoice: String, Codable, Equatable, Sendable, CaseIterable {
    /// Destroy the owner's keys once every holder has sent a receipt.
    case destroy
    /// Lock the owner's keys for 30 days, then destroy.
    case lock30
}

public enum ErasureContractError: Error, Equatable, Sendable {
    case missingSignature
    case invalidSignature
    case notOwner
    case unknownPurpose(String)
    case unknownDomain(String)
    case invalidRequest(String)
}

/// Signed by the owner identity. A holder refuses it on a missing or invalid
/// signature, when the signer is not the owner it holds data for, and on any
/// purpose other than account erasure.
public struct ErasureRequest: Codable, Equatable, Sendable {
    public static let domain = "haven.account.erasure.v1"
    public static let purpose = "purpose://account.erasure"

    public let domain: String
    public let purpose: String
    public let requestID: UUID
    /// UUID of the owner entity (the identity the data belongs to).
    public let ownerEntity: String
    /// UUIDs of every identity covered: the owner and linked identities.
    public let identities: [String]
    public let keyChoice: ErasureKeyChoice
    public let issuedAt: Date
    public let signer: IdentityPublicKeyDescriptor
    public private(set) var signature: Data

    public static func make(
        owner: Identity,
        linkedIdentities: [String] = [],
        keyChoice: ErasureKeyChoice,
        requestID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> ErasureRequest {
        var signer = try ChatInvitationProofUtility.signingDescriptor(for: owner)
        signer.displayName = nil
        var identities = [owner.uuid]
        for uuid in linkedIdentities where !identities.contains(uuid) { identities.append(uuid) }
        var request = ErasureRequest(
            domain: domain, purpose: purpose, requestID: requestID, ownerEntity: owner.uuid,
            identities: identities, keyChoice: keyChoice, issuedAt: now, signer: signer, signature: Data()
        )
        guard let signature = try await owner.sign(data: request.signingPayload()) else {
            throw ErasureContractError.missingSignature
        }
        request.signature = signature
        return request
    }

    /// Unsigned construction, for decoding tests and for forged inputs in tests.
    public init(
        domain: String, purpose: String, requestID: UUID, ownerEntity: String, identities: [String],
        keyChoice: ErasureKeyChoice, issuedAt: Date, signer: IdentityPublicKeyDescriptor, signature: Data
    ) {
        self.domain = domain
        self.purpose = purpose
        self.requestID = requestID
        self.ownerEntity = ownerEntity
        self.identities = identities
        self.keyChoice = keyChoice
        self.issuedAt = issuedAt
        self.signer = signer
        self.signature = signature
    }

    /// The bytes the owner signs: canonical JSON without `signature`.
    public func signingPayload() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }

    /// Identity reconstructed from the signer's public key.
    public var signerIdentity: Identity { ChatInvitationProofUtility.identity(from: signer) }

    /// - Parameter owner: the identity the holder keeps data for, as the holder
    ///   knows it (public key is enough).
    public func verify(owner: Identity) throws {
        guard domain == Self.domain else { throw ErasureContractError.unknownDomain(domain) }
        guard purpose == Self.purpose else { throw ErasureContractError.unknownPurpose(purpose) }
        guard !signature.isEmpty else { throw ErasureContractError.missingSignature }
        guard ownerEntity == signer.uuid, identities.first == ownerEntity,
              Set(identities).count == identities.count,
              issuedAt.timeIntervalSince1970.isFinite else {
            throw ErasureContractError.invalidRequest("owner, signer and identities disagree")
        }
        let signerIdentity = signerIdentity
        guard owner.referencesSameSigningIdentity(as: signerIdentity) else {
            throw ErasureContractError.notOwner
        }
        guard let payload = try? signingPayload(),
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: payload, identity: signerIdentity) else {
            throw ErasureContractError.invalidSignature
        }
    }
}

/// Signed by the holder. `remainsWithOthers` names holders this holder knows
/// still keep copies (for example a peer's chat history), so the receipt never
/// claims more than the holder removed.
public struct ErasureReceipt: Codable, Equatable, Sendable {
    public static let domain = "haven.account.erasure.receipt.v1"

    public let domain: String
    public let holder: String
    public let requestID: UUID
    public let ownerEntity: String
    public let removedCount: Int
    public let remainsWithOthers: [String]
    public let at: Date
    public let holderSigner: IdentityPublicKeyDescriptor
    public private(set) var signature: Data

    public static func make(
        for request: ErasureRequest,
        holder: String,
        removedCount: Int,
        remainsWithOthers: [String] = [],
        holderIdentity: Identity,
        now: Date = Date()
    ) async throws -> ErasureReceipt {
        guard removedCount >= 0 else { throw ErasureContractError.invalidRequest("negative removedCount") }
        var signer = try ChatInvitationProofUtility.signingDescriptor(for: holderIdentity)
        signer.displayName = nil
        var receipt = ErasureReceipt(
            domain: domain, holder: holder, requestID: request.requestID, ownerEntity: request.ownerEntity,
            removedCount: removedCount, remainsWithOthers: remainsWithOthers, at: now,
            holderSigner: signer, signature: Data()
        )
        guard let signature = try await holderIdentity.sign(data: receipt.signingPayload()) else {
            throw ErasureContractError.missingSignature
        }
        receipt.signature = signature
        return receipt
    }

    public init(
        domain: String, holder: String, requestID: UUID, ownerEntity: String, removedCount: Int,
        remainsWithOthers: [String], at: Date, holderSigner: IdentityPublicKeyDescriptor, signature: Data
    ) {
        self.domain = domain
        self.holder = holder
        self.requestID = requestID
        self.ownerEntity = ownerEntity
        self.removedCount = removedCount
        self.remainsWithOthers = remainsWithOthers
        self.at = at
        self.holderSigner = holderSigner
        self.signature = signature
    }

    public func signingPayload() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }

    /// Checks that the receipt answers `request` and is signed by `holderIdentity`.
    public func verify(request: ErasureRequest, holderIdentity: Identity) throws {
        guard domain == Self.domain else { throw ErasureContractError.unknownDomain(domain) }
        guard !signature.isEmpty else { throw ErasureContractError.missingSignature }
        guard requestID == request.requestID, ownerEntity == request.ownerEntity, removedCount >= 0 else {
            throw ErasureContractError.invalidRequest("receipt does not answer the request")
        }
        let signerIdentity = ChatInvitationProofUtility.identity(from: holderSigner)
        guard holderIdentity.referencesSameSigningIdentity(as: signerIdentity) else {
            throw ErasureContractError.notOwner
        }
        guard let payload = try? signingPayload(),
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: payload, identity: signerIdentity) else {
            throw ErasureContractError.invalidSignature
        }
    }
}
