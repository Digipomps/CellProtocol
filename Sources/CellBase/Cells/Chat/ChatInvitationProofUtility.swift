// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ChatInvitationProofUtilityError: Error, Equatable {
    case missingIdentityVault
    case missingSigningKey
    case missingRandomness
    case missingSignature
    case inviterMismatch
    case inviteeMismatch
    case chatCellMismatch
    case invitationHashMismatch
    case expiredArtifact
    case invalidArtifactProof
    case invalidAcceptanceProof
    case unsupportedVersion
    case invalidPurpose
    case invalidProofType
    case invalidTimestamp
    case invalidNonce
}

public struct ChatInvitationArtifactProof: Codable, Equatable, Sendable {
    public var type: String
    public var byIdentityUUID: String
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType
    public var signature: Data?

    public init(
        type: String = "signature",
        byIdentityUUID: String,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        signature: Data? = nil
    ) {
        self.type = type
        self.byIdentityUUID = byIdentityUUID
        self.algorithm = algorithm
        self.curveType = curveType
        self.signature = signature
    }
}

public struct ChatInvitationArtifact: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var invitationID: String
    public var purpose: String
    public var chatCellUUID: String
    public var topic: String
    public var audienceMode: String
    public var suiteID: String
    public var persistenceMode: String
    public var inviterIdentity: IdentityPublicKeyDescriptor
    public var invitedIdentity: IdentityPublicKeyDescriptor
    public var createdAt: String
    public var expiresAt: String
    public var nonce: Data
    public var proof: ChatInvitationArtifactProof?

    public init(
        version: Int = 1,
        invitationID: String,
        purpose: String = "chat_invitation",
        chatCellUUID: String,
        topic: String,
        audienceMode: String,
        suiteID: String,
        persistenceMode: String,
        inviterIdentity: IdentityPublicKeyDescriptor,
        invitedIdentity: IdentityPublicKeyDescriptor,
        createdAt: String,
        expiresAt: String,
        nonce: Data,
        proof: ChatInvitationArtifactProof? = nil
    ) {
        self.version = version
        self.invitationID = invitationID
        self.purpose = purpose
        self.chatCellUUID = chatCellUUID
        self.topic = topic
        self.audienceMode = audienceMode
        self.suiteID = suiteID
        self.persistenceMode = persistenceMode
        self.inviterIdentity = inviterIdentity
        self.invitedIdentity = invitedIdentity
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

public struct ChatInvitationAcceptanceProof: Codable, Equatable, Sendable {
    public var type: String
    public var byIdentityUUID: String
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType
    public var signature: Data?

    public init(
        type: String = "signature",
        byIdentityUUID: String,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        signature: Data? = nil
    ) {
        self.type = type
        self.byIdentityUUID = byIdentityUUID
        self.algorithm = algorithm
        self.curveType = curveType
        self.signature = signature
    }
}

public struct ChatInvitationAcceptance: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var acceptanceID: String
    public var purpose: String
    public var invitationID: String
    public var invitationHash: Data
    public var chatCellUUID: String
    public var inviterIdentityUUID: String
    public var inviteeIdentity: IdentityPublicKeyDescriptor
    public var createdAt: String
    public var nonce: Data
    public var proof: ChatInvitationAcceptanceProof?

    public init(
        version: Int = 1,
        acceptanceID: String,
        purpose: String = "accept_chat_invitation",
        invitationID: String,
        invitationHash: Data,
        chatCellUUID: String,
        inviterIdentityUUID: String,
        inviteeIdentity: IdentityPublicKeyDescriptor,
        createdAt: String,
        nonce: Data,
        proof: ChatInvitationAcceptanceProof? = nil
    ) {
        self.version = version
        self.acceptanceID = acceptanceID
        self.purpose = purpose
        self.invitationID = invitationID
        self.invitationHash = invitationHash
        self.chatCellUUID = chatCellUUID
        self.inviterIdentityUUID = inviterIdentityUUID
        self.inviteeIdentity = inviteeIdentity
        self.createdAt = createdAt
        self.nonce = nonce
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

public enum ChatInvitationProofUtility {
    public static func invitationHash(for artifact: ChatInvitationArtifact) throws -> Data {
        hash(data: try artifact.canonicalPayloadData())
    }

    public static func signingDescriptor(for identity: Identity) throws -> IdentityPublicKeyDescriptor {
        guard let publicSecureKey = identity.publicSecureKey,
              let publicKey = publicSecureKey.compressedKey else {
            throw ChatInvitationProofUtilityError.missingSigningKey
        }

        return IdentityPublicKeyDescriptor(
            uuid: identity.uuid,
            displayName: identity.displayName,
            publicKey: publicKey,
            algorithm: publicSecureKey.algorithm,
            curveType: publicSecureKey.curveType
        )
    }

    public static func identity(from descriptor: IdentityPublicKeyDescriptor, identityVault: IdentityVaultProtocol? = nil) -> Identity {
        let identity = Identity(
            descriptor.uuid,
            displayName: descriptor.displayName ?? descriptor.uuid,
            identityVault: identityVault
        )
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: descriptor.algorithm,
            size: descriptor.publicKey.count * 8,
            curveType: descriptor.curveType,
            x: nil,
            y: nil,
            compressedKey: descriptor.publicKey
        )
        return identity
    }

    public static func generateInvitationArtifact(
        chatCellUUID: String,
        topic: String,
        audienceMode: String,
        suiteID: String,
        persistenceMode: String,
        inviter: Identity,
        invited: Identity,
        invitationID: String = UUID().uuidString,
        createdAt: String,
        expiresAt: String,
        nonce: Data? = nil
    ) async throws -> ChatInvitationArtifact {
        let vault = try identityVault(for: inviter)
        let inviterDescriptor = try signingDescriptor(for: inviter)
        let invitedDescriptor = try signingDescriptor(for: invited)
        let invitationNonce: Data
        if let nonce {
            invitationNonce = nonce
        } else {
            invitationNonce = try await randomNonce(using: vault)
        }

        var artifact = ChatInvitationArtifact(
            invitationID: invitationID,
            chatCellUUID: chatCellUUID,
            topic: topic,
            audienceMode: audienceMode,
            suiteID: suiteID,
            persistenceMode: persistenceMode,
            inviterIdentity: inviterDescriptor,
            invitedIdentity: invitedDescriptor,
            createdAt: createdAt,
            expiresAt: expiresAt,
            nonce: invitationNonce,
            proof: ChatInvitationArtifactProof(
                byIdentityUUID: inviter.uuid,
                algorithm: inviterDescriptor.algorithm,
                curveType: inviterDescriptor.curveType
            )
        )
        try validateInvitationPayload(artifact)

        let signature = try await vault.signMessageForIdentity(
            messageData: try artifact.canonicalPayloadData(),
            identity: inviter
        )
        artifact.proof?.signature = signature
        return artifact
    }

    public static func verifyInvitationArtifact(
        _ artifact: ChatInvitationArtifact,
        expectedChatCellUUID: String? = nil,
        expectedInviterUUID: String? = nil,
        identityVault: IdentityVaultProtocol? = nil
    ) async throws -> Bool {
        // Retained for source compatibility. Verification is deliberately
        // independent of caller-provided or process-global signing authority.
        _ = identityVault
        try validateInvitationPayload(artifact)
        if let expectedChatCellUUID, artifact.chatCellUUID != expectedChatCellUUID {
            throw ChatInvitationProofUtilityError.chatCellMismatch
        }
        if let expectedInviterUUID, artifact.inviterIdentity.uuid != expectedInviterUUID {
            throw ChatInvitationProofUtilityError.inviterMismatch
        }
        if isExpired(artifact.expiresAt) {
            throw ChatInvitationProofUtilityError.expiredArtifact
        }
        guard let proof = artifact.proof,
              let signature = proof.signature else {
            throw ChatInvitationProofUtilityError.missingSignature
        }
        guard proof.byIdentityUUID == artifact.inviterIdentity.uuid,
              proof.type == "signature",
              proof.algorithm == artifact.inviterIdentity.algorithm,
              proof.curveType == artifact.inviterIdentity.curveType else {
            if proof.type != "signature" {
                throw ChatInvitationProofUtilityError.invalidProofType
            }
            throw ChatInvitationProofUtilityError.inviterMismatch
        }

        let verified = IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: try artifact.canonicalPayloadData(),
            descriptor: artifact.inviterIdentity
        )
        guard verified else {
            throw ChatInvitationProofUtilityError.invalidArtifactProof
        }
        return true
    }

    public static func generateAcceptance(
        for artifact: ChatInvitationArtifact,
        invitee: Identity,
        acceptanceID: String = UUID().uuidString,
        createdAt: String,
        nonce: Data? = nil
    ) async throws -> ChatInvitationAcceptance {
        let inviteeDescriptor = try signingDescriptor(for: invitee)
        guard descriptor(inviteeDescriptor, matches: artifact.invitedIdentity) else {
            throw ChatInvitationProofUtilityError.inviteeMismatch
        }
        _ = try await verifyInvitationArtifact(artifact, identityVault: invitee.identityVault ?? CellBase.defaultIdentityVault)

        let vault = try identityVault(for: invitee)
        let acceptanceNonce: Data
        if let nonce {
            acceptanceNonce = nonce
        } else {
            acceptanceNonce = try await randomNonce(using: vault)
        }
        let artifactHash = try invitationHash(for: artifact)

        var acceptance = ChatInvitationAcceptance(
            acceptanceID: acceptanceID,
            invitationID: artifact.invitationID,
            invitationHash: artifactHash,
            chatCellUUID: artifact.chatCellUUID,
            inviterIdentityUUID: artifact.inviterIdentity.uuid,
            inviteeIdentity: inviteeDescriptor,
            createdAt: createdAt,
            nonce: acceptanceNonce,
            proof: ChatInvitationAcceptanceProof(
                byIdentityUUID: invitee.uuid,
                algorithm: inviteeDescriptor.algorithm,
                curveType: inviteeDescriptor.curveType
            )
        )
        try validateAcceptancePayload(acceptance, for: artifact)

        let signature = try await vault.signMessageForIdentity(
            messageData: try acceptance.canonicalPayloadData(),
            identity: invitee
        )
        acceptance.proof?.signature = signature
        return acceptance
    }

    public static func verifyAcceptance(
        _ acceptance: ChatInvitationAcceptance,
        for artifact: ChatInvitationArtifact,
        expectedChatCellUUID: String? = nil,
        identityVault: IdentityVaultProtocol? = nil
    ) async throws -> Bool {
        _ = try await verifyInvitationArtifact(
            artifact,
            expectedChatCellUUID: expectedChatCellUUID,
            expectedInviterUUID: acceptance.inviterIdentityUUID,
            identityVault: identityVault
        )
        try validateAcceptancePayload(acceptance, for: artifact)

        guard acceptance.invitationID == artifact.invitationID else {
            throw ChatInvitationProofUtilityError.invitationHashMismatch
        }
        guard acceptance.chatCellUUID == artifact.chatCellUUID else {
            throw ChatInvitationProofUtilityError.chatCellMismatch
        }
        guard descriptor(acceptance.inviteeIdentity, matches: artifact.invitedIdentity) else {
            throw ChatInvitationProofUtilityError.inviteeMismatch
        }
        let expectedInvitationHash = try invitationHash(for: artifact)
        guard acceptance.invitationHash == expectedInvitationHash else {
            throw ChatInvitationProofUtilityError.invitationHashMismatch
        }
        guard let proof = acceptance.proof,
              let signature = proof.signature else {
            throw ChatInvitationProofUtilityError.missingSignature
        }
        guard proof.byIdentityUUID == acceptance.inviteeIdentity.uuid,
              proof.type == "signature",
              proof.algorithm == acceptance.inviteeIdentity.algorithm,
              proof.curveType == acceptance.inviteeIdentity.curveType else {
            if proof.type != "signature" {
                throw ChatInvitationProofUtilityError.invalidProofType
            }
            throw ChatInvitationProofUtilityError.inviteeMismatch
        }

        let verified = IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: try acceptance.canonicalPayloadData(),
            descriptor: acceptance.inviteeIdentity
        )
        guard verified else {
            throw ChatInvitationProofUtilityError.invalidAcceptanceProof
        }
        return true
    }

    private static func identityVault(for identity: Identity) throws -> IdentityVaultProtocol {
        if let vault = identity.identityVault ?? CellBase.defaultIdentityVault {
            return vault
        }
        throw ChatInvitationProofUtilityError.missingIdentityVault
    }

    private static func randomNonce(using vault: IdentityVaultProtocol) async throws -> Data {
        guard let nonce = await vault.randomBytes64() else {
            throw ChatInvitationProofUtilityError.missingRandomness
        }
        return nonce
    }

    public static func isExpired(_ timestamp: String) -> Bool {
        guard let date = date(from: timestamp) else {
            return true
        }
        return date < Date()
    }

    private static func validateInvitationPayload(
        _ artifact: ChatInvitationArtifact,
        now: Date = Date()
    ) throws {
        guard artifact.version == 1 else {
            throw ChatInvitationProofUtilityError.unsupportedVersion
        }
        guard artifact.purpose == "chat_invitation" else {
            throw ChatInvitationProofUtilityError.invalidPurpose
        }
        try validateNonce(artifact.nonce)
        guard let createdAt = date(from: artifact.createdAt),
              let expiresAt = date(from: artifact.expiresAt),
              expiresAt > createdAt,
              createdAt <= now.addingTimeInterval(IdentitySigningChallenge.allowedClockSkew) else {
            throw ChatInvitationProofUtilityError.invalidTimestamp
        }
        guard expiresAt >= now else {
            throw ChatInvitationProofUtilityError.expiredArtifact
        }
    }

    private static func validateAcceptancePayload(
        _ acceptance: ChatInvitationAcceptance,
        for artifact: ChatInvitationArtifact,
        now: Date = Date()
    ) throws {
        guard acceptance.version == 1 else {
            throw ChatInvitationProofUtilityError.unsupportedVersion
        }
        guard acceptance.purpose == "accept_chat_invitation" else {
            throw ChatInvitationProofUtilityError.invalidPurpose
        }
        try validateNonce(acceptance.nonce)
        guard let invitationCreatedAt = date(from: artifact.createdAt),
              let invitationExpiresAt = date(from: artifact.expiresAt),
              let acceptanceCreatedAt = date(from: acceptance.createdAt),
              acceptanceCreatedAt >= invitationCreatedAt.addingTimeInterval(-IdentitySigningChallenge.allowedClockSkew),
              acceptanceCreatedAt <= invitationExpiresAt,
              acceptanceCreatedAt <= now.addingTimeInterval(IdentitySigningChallenge.allowedClockSkew) else {
            throw ChatInvitationProofUtilityError.invalidTimestamp
        }
    }

    private static func validateNonce(_ nonce: Data) throws {
        guard nonce.count >= IdentitySigningChallenge.minimumNonceBytes,
              nonce.count <= IdentitySigningChallenge.maximumNonceBytes else {
            throw ChatInvitationProofUtilityError.invalidNonce
        }
    }

    private static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    private static func hash(data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func descriptor(
        _ lhs: IdentityPublicKeyDescriptor,
        matches rhs: IdentityPublicKeyDescriptor
    ) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.publicKey == rhs.publicKey
            && lhs.algorithm == rhs.algorithm
            && lhs.curveType == rhs.curveType
    }
}
