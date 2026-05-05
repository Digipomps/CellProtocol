// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol CanonicalPayloadSignable: Encodable {
    func canonicalPayloadData() throws -> Data
}

public enum IdentityLinkIssuerType: String, Codable, Sendable {
    case existingDevice
    case custodian
    case recoveryAuthority
}

public enum IdentityLinkStatus: String, Codable, Sendable {
    case active
    case revoked
    case expired
    case pending
}

public enum EntityBindingMode: String, Codable, Sendable {
    case localEntityAnchor
    case pairwise
    case blinded
}

public struct IdentityPublicKeyDescriptor: Codable, Equatable, Sendable {
    public var uuid: String
    public var displayName: String?
    public var publicKey: Data
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType

    public init(
        uuid: String,
        displayName: String? = nil,
        publicKey: Data,
        algorithm: CurveAlgorithm,
        curveType: CurveType
    ) {
        self.uuid = uuid
        self.displayName = displayName
        self.publicKey = publicKey
        self.algorithm = algorithm
        self.curveType = curveType
    }
}

public struct EntityBindingDescriptor: Codable, Equatable, Sendable {
    public var mode: EntityBindingMode
    public var entityAnchorReference: String?
    public var bindingID: String?
    public var audience: String?

    public init(
        mode: EntityBindingMode,
        entityAnchorReference: String? = nil,
        bindingID: String? = nil,
        audience: String? = nil
    ) {
        self.mode = mode
        self.entityAnchorReference = entityAnchorReference
        self.bindingID = bindingID
        self.audience = audience
    }
}

public struct IdentityEnrollmentRequestProof: Codable, Equatable, Sendable {
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

public struct IdentityEnrollmentRequest: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var requestID: String
    public var purpose: String
    public var entityBinding: EntityBindingDescriptor?
    public var newIdentity: IdentityPublicKeyDescriptor
    public var requestedDomains: [String]
    public var requestedIdentityContexts: [String]
    public var requestedScopes: [String]
    public var audience: String
    public var origin: String
    public var createdAt: String
    public var expiresAt: String
    public var nonce: Data
    public var platform: String?
    public var deviceLabel: String?
    public var proof: IdentityEnrollmentRequestProof?

    public init(
        version: Int = 1,
        requestID: String,
        purpose: String = "link_identity",
        entityBinding: EntityBindingDescriptor? = nil,
        newIdentity: IdentityPublicKeyDescriptor,
        requestedDomains: [String],
        requestedIdentityContexts: [String],
        requestedScopes: [String],
        audience: String,
        origin: String,
        createdAt: String,
        expiresAt: String,
        nonce: Data,
        platform: String? = nil,
        deviceLabel: String? = nil,
        proof: IdentityEnrollmentRequestProof? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.purpose = purpose
        self.entityBinding = entityBinding
        self.newIdentity = newIdentity
        self.requestedDomains = requestedDomains
        self.requestedIdentityContexts = requestedIdentityContexts
        self.requestedScopes = requestedScopes
        self.audience = audience
        self.origin = origin
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.platform = platform
        self.deviceLabel = deviceLabel
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

public struct IdentityEnrollmentApprovalProof: Codable, Equatable, Sendable {
    public var type: String
    public var issuerIdentityUUID: String
    public var issuerType: IdentityLinkIssuerType
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType
    public var signature: Data?

    public init(
        type: String = "signature",
        issuerIdentityUUID: String,
        issuerType: IdentityLinkIssuerType,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        signature: Data? = nil
    ) {
        self.type = type
        self.issuerIdentityUUID = issuerIdentityUUID
        self.issuerType = issuerType
        self.algorithm = algorithm
        self.curveType = curveType
        self.signature = signature
    }
}

public struct IdentityEnrollmentApproval: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var approvalID: String
    public var purpose: String
    public var requestHash: Data
    public var entityBinding: EntityBindingDescriptor
    public var subjectIdentity: IdentityPublicKeyDescriptor
    public var approvedDomains: [String]
    public var approvedIdentityContexts: [String]
    public var approvedScopes: [String]
    public var issuerIdentityUUID: String
    public var issuerType: IdentityLinkIssuerType
    public var audience: String
    public var origin: String
    public var createdAt: String
    public var expiresAt: String
    public var jti: String
    public var freshAuthRequired: Bool
    public var freshAuthMethod: String?
    public var freshAuthPerformedAt: String?
    public var proof: IdentityEnrollmentApprovalProof?

    public init(
        version: Int = 1,
        approvalID: String,
        purpose: String = "approve_link_identity",
        requestHash: Data,
        entityBinding: EntityBindingDescriptor,
        subjectIdentity: IdentityPublicKeyDescriptor,
        approvedDomains: [String],
        approvedIdentityContexts: [String],
        approvedScopes: [String],
        issuerIdentityUUID: String,
        issuerType: IdentityLinkIssuerType,
        audience: String,
        origin: String,
        createdAt: String,
        expiresAt: String,
        jti: String,
        freshAuthRequired: Bool,
        freshAuthMethod: String? = nil,
        freshAuthPerformedAt: String? = nil,
        proof: IdentityEnrollmentApprovalProof? = nil
    ) {
        self.version = version
        self.approvalID = approvalID
        self.purpose = purpose
        self.requestHash = requestHash
        self.entityBinding = entityBinding
        self.subjectIdentity = subjectIdentity
        self.approvedDomains = approvedDomains
        self.approvedIdentityContexts = approvedIdentityContexts
        self.approvedScopes = approvedScopes
        self.issuerIdentityUUID = issuerIdentityUUID
        self.issuerType = issuerType
        self.audience = audience
        self.origin = origin
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.jti = jti
        self.freshAuthRequired = freshAuthRequired
        self.freshAuthMethod = freshAuthMethod
        self.freshAuthPerformedAt = freshAuthPerformedAt
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

public struct SameEntityIdentityLinkCredentialSubject: Codable, Equatable, Sendable {
    public var id: String
    public var linkType: String
    public var entityBinding: EntityBindingDescriptor
    public var linkedIdentity: IdentityPublicKeyDescriptor
    public var approvedDomains: [String]
    public var approvedIdentityContexts: [String]
    public var approvedScopes: [String]
    public var enrollmentRequestHash: Data
    public var assuranceSource: String
    public var assuranceLevel: String
    public var validUntil: String
    public var revocationReference: String?

    public init(
        id: String,
        linkType: String = "same_entity",
        entityBinding: EntityBindingDescriptor,
        linkedIdentity: IdentityPublicKeyDescriptor,
        approvedDomains: [String],
        approvedIdentityContexts: [String],
        approvedScopes: [String],
        enrollmentRequestHash: Data,
        assuranceSource: String,
        assuranceLevel: String,
        validUntil: String,
        revocationReference: String? = nil
    ) {
        self.id = id
        self.linkType = linkType
        self.entityBinding = entityBinding
        self.linkedIdentity = linkedIdentity
        self.approvedDomains = approvedDomains
        self.approvedIdentityContexts = approvedIdentityContexts
        self.approvedScopes = approvedScopes
        self.enrollmentRequestHash = enrollmentRequestHash
        self.assuranceSource = assuranceSource
        self.assuranceLevel = assuranceLevel
        self.validUntil = validUntil
        self.revocationReference = revocationReference
    }
}

public struct IdentityLinkRecord: Codable, Equatable, Sendable {
    public var linkID: String
    public var entityBinding: EntityBindingDescriptor
    public var linkedIdentity: IdentityPublicKeyDescriptor
    public var approvedDomains: [String]
    public var approvedIdentityContexts: [String]
    public var approvedScopes: [String]
    public var issuerIdentityUUID: String
    public var issuerType: IdentityLinkIssuerType
    public var status: IdentityLinkStatus
    public var linkedAt: String
    public var lastUsedAt: String?
    public var revokedAt: String?
    public var revocationReference: String?

    public init(
        linkID: String,
        entityBinding: EntityBindingDescriptor,
        linkedIdentity: IdentityPublicKeyDescriptor,
        approvedDomains: [String],
        approvedIdentityContexts: [String],
        approvedScopes: [String],
        issuerIdentityUUID: String,
        issuerType: IdentityLinkIssuerType,
        status: IdentityLinkStatus = .active,
        linkedAt: String,
        lastUsedAt: String? = nil,
        revokedAt: String? = nil,
        revocationReference: String? = nil
    ) {
        self.linkID = linkID
        self.entityBinding = entityBinding
        self.linkedIdentity = linkedIdentity
        self.approvedDomains = approvedDomains
        self.approvedIdentityContexts = approvedIdentityContexts
        self.approvedScopes = approvedScopes
        self.issuerIdentityUUID = issuerIdentityUUID
        self.issuerType = issuerType
        self.status = status
        self.linkedAt = linkedAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
        self.revocationReference = revocationReference
    }
}

public struct IdentityLinkRevocation: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var linkID: String
    public var reason: String
    public var revokedAt: String
    public var revokedByIdentityUUID: String
    public var issuerType: IdentityLinkIssuerType
    public var proof: IdentityEnrollmentApprovalProof?

    public init(
        version: Int = 1,
        linkID: String,
        reason: String,
        revokedAt: String,
        revokedByIdentityUUID: String,
        issuerType: IdentityLinkIssuerType,
        proof: IdentityEnrollmentApprovalProof? = nil
    ) {
        self.version = version
        self.linkID = linkID
        self.reason = reason
        self.revokedAt = revokedAt
        self.revokedByIdentityUUID = revokedByIdentityUUID
        self.issuerType = issuerType
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}
