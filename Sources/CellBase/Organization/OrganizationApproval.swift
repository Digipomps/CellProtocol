// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Members never hold the organization key. They approve a concrete proposal
// with their own key; the custodian signs only once a clause is satisfied.

enum OrganizationHashing {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

public struct OrganizationActionProposal: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var proposalID: String
    public var organizationAnchorID: String
    /// Hash of the policy version this proposal was made under.
    public var policyHash: Data
    public var actionClass: String
    /// Hash of exactly what the organization key will sign.
    public var payloadHash: Data
    /// What the approver is shown. The vault derives it from the payload; it is
    /// never taken from the proposer.
    public var payloadSummary: String
    public var amount: MonetaryAmount?
    public var audience: String
    public var createdAt: String
    public var expiresAt: String
    public var nonce: Data
    public var proposer: IdentityPublicKeyDescriptor

    public init(
        version: Int = 1,
        proposalID: String = UUID().uuidString,
        organizationAnchorID: String,
        policyHash: Data,
        actionClass: String,
        payloadHash: Data,
        payloadSummary: String,
        amount: MonetaryAmount? = nil,
        audience: String,
        createdAt: String,
        expiresAt: String,
        nonce: Data,
        proposer: IdentityPublicKeyDescriptor
    ) {
        self.version = version
        self.proposalID = proposalID
        self.organizationAnchorID = organizationAnchorID
        self.policyHash = policyHash
        self.actionClass = actionClass
        self.payloadHash = payloadHash
        self.payloadSummary = payloadSummary
        self.amount = amount
        self.audience = audience
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.proposer = proposer
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self)
    }

    public func proposalHash() throws -> Data {
        OrganizationHashing.sha256(try canonicalPayloadData())
    }
}

public enum OrganizationApprovalDecision: String, Codable, Sendable {
    case approve
    case reject
}

public struct OrganizationApproval: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var proposalHash: Data
    public var approver: IdentityPublicKeyDescriptor
    public var role: OrganizationRole
    public var decision: OrganizationApprovalDecision
    public var approvedAt: String
    public var freshAuthEvidence: IdentityLinkFreshAuthEvidence?
    public var signature: Data?

    public init(
        version: Int = 1,
        proposalHash: Data,
        approver: IdentityPublicKeyDescriptor,
        role: OrganizationRole,
        decision: OrganizationApprovalDecision,
        approvedAt: String,
        freshAuthEvidence: IdentityLinkFreshAuthEvidence? = nil,
        signature: Data? = nil
    ) {
        self.version = version
        self.proposalHash = proposalHash
        self.approver = approver
        self.role = role
        self.decision = decision
        self.approvedAt = approvedAt
        self.freshAuthEvidence = freshAuthEvidence
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }

    /// Signs with the approver's own identity key (Secure Enclave on Apple).
    public static func signed(
        proposal: OrganizationActionProposal,
        approver: Identity,
        role: OrganizationRole,
        decision: OrganizationApprovalDecision = .approve,
        freshAuthEvidence: IdentityLinkFreshAuthEvidence? = nil,
        now: Date = Date()
    ) async throws -> OrganizationApproval {
        let descriptor = try IdentityLinkProtocolService.descriptor(for: approver)
        var approval = OrganizationApproval(
            proposalHash: try proposal.proposalHash(),
            approver: descriptor,
            role: role,
            decision: decision,
            approvedAt: IdentityLinkProtocolService.iso8601(now),
            freshAuthEvidence: freshAuthEvidence
        )
        guard let signature = try await approver.sign(data: try approval.canonicalPayloadData()) else {
            throw IdentityVaultError.signingFailed
        }
        approval.signature = signature
        return approval
    }

    public func signatureIsValid() -> Bool {
        guard let signature, let payload = try? canonicalPayloadData() else {
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: payload,
            descriptor: approver
        )
    }
}

/// What the custodian verifies before the organization key signs anything.
public struct ApprovalBundle: Codable, Equatable, Sendable {
    public var proposal: OrganizationActionProposal
    public var approvals: [OrganizationApproval]

    public init(proposal: OrganizationActionProposal, approvals: [OrganizationApproval]) {
        self.proposal = proposal
        self.approvals = approvals
    }
}
