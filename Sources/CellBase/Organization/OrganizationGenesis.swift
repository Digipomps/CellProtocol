// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.informasjonssystemer-gruppeentitet.genesis
// purpose://candidate.informasjonssystemer-gruppeentitet.owner-onboarding
//
// A person entity is sealed to the identity that started it (EntityGenesisSeal).
// An organization entity is sealed to a signed GovernancePolicy instead: every
// founder signs a seal that names policy v1 and the custodian key that will act
// for the organization. Later versions form a hash chain, and each step is
// valid only with an ApprovalBundle that satisfies the amendment rule of the
// version it replaces. Changing owners is therefore a new policy version and
// never a new organization key.
//
// Design: CellProtocol/Docs/Organization_Entities_and_Group_Signing_NO.md (PR 2).

public enum OrganizationGenesisError: Error, Equatable, Sendable {
    case noFounders
    case founderNotOwner(String)
    case ownerNotFounder(String)
    case founderSignatureMissing(String)
    case founderSignatureInvalid(String)
    case unexpectedSigner(String)
    case policyHashMismatch
    case initialPolicyMustBeVersionOne
    case initialPolicyHasPredecessor
    case anchorMismatch
}

public enum GovernancePolicyChainError: Error, Equatable, Sendable {
    case versionNotNext(expected: Int, found: Int)
    case previousHashMismatch
    case policyIDChanged
    case proposalNotForThisOrganization
    case proposalNotUnderPreviousPolicy
    case proposalIsNotAnAmendment(String)
    case payloadIsNotTheNewPolicy
    case amendmentRuleNotUsed(expected: String, used: String)
    case approvalsRefused(GovernanceEvaluationError)
}

/// One founder's signature over the seal's canonical payload.
public struct OrganizationFounderSignature: Codable, Equatable, Sendable {
    public var founder: IdentityPublicKeyDescriptor
    public var signedAt: String
    public var signature: Data

    public init(founder: IdentityPublicKeyDescriptor, signedAt: String, signature: Data) {
        self.founder = founder
        self.signedAt = signedAt
        self.signature = signature
    }
}

public struct OrganizationGenesisSeal: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var kind: EntityKind
    /// The organization's stable reference, e.g. `entity:ifi-informasjonssystemer`.
    public var anchorID: String
    public var displayName: String
    /// Organization number or EUID. Nil for groups that are not legal entities.
    public var legalIdentifier: String?
    public var initialPolicyHash: Data
    /// The key the vault holds and signs with for the organization.
    public var custodianKey: IdentityPublicKeyDescriptor
    public var founders: [IdentityPublicKeyDescriptor]
    public var sealedAt: String
    public var signatures: [OrganizationFounderSignature]

    public init(
        version: Int = 1,
        anchorID: String,
        displayName: String,
        legalIdentifier: String? = nil,
        initialPolicyHash: Data,
        custodianKey: IdentityPublicKeyDescriptor,
        founders: [IdentityPublicKeyDescriptor],
        sealedAt: String,
        signatures: [OrganizationFounderSignature] = []
    ) {
        self.version = version
        self.kind = .organization
        self.anchorID = anchorID
        self.displayName = displayName
        self.legalIdentifier = legalIdentifier
        self.initialPolicyHash = initialPolicyHash
        self.custodianKey = custodianKey
        self.founders = founders
        self.sealedAt = sealedAt
        self.signatures = signatures
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signatures"])
    }

    public func sealHash() throws -> Data {
        OrganizationHashing.sha256(try canonicalPayloadData())
    }

    /// Adds `founder`'s signature. Each founder signs with their own key.
    public mutating func sign(as founder: Identity, now: Date = Date()) async throws {
        let descriptor = try IdentityLinkProtocolService.descriptor(for: founder)
        guard founders.contains(descriptor) else {
            throw OrganizationGenesisError.unexpectedSigner(founder.uuid)
        }
        guard let signature = try await founder.sign(data: try canonicalPayloadData()) else {
            throw IdentityVaultError.signingFailed
        }
        signatures.removeAll { $0.founder == descriptor }
        signatures.append(OrganizationFounderSignature(
            founder: descriptor,
            signedAt: IdentityLinkProtocolService.iso8601(now),
            signature: signature
        ))
    }

    /// Fails closed. Every founder has signed, nobody else has, the policy is
    /// v1 with no predecessor, and the founders are exactly its owners.
    public func verify(initialPolicy: GovernancePolicy) throws {
        guard kind == .organization, founders.isEmpty == false else {
            throw OrganizationGenesisError.noFounders
        }
        guard initialPolicy.version == 1 else { throw OrganizationGenesisError.initialPolicyMustBeVersionOne }
        guard initialPolicy.previousPolicyHash == nil else { throw OrganizationGenesisError.initialPolicyHasPredecessor }
        guard try initialPolicy.policyHash() == initialPolicyHash else { throw OrganizationGenesisError.policyHashMismatch }

        let owners = initialPolicy.owners
        for founder in founders where owners.contains(founder) == false {
            throw OrganizationGenesisError.founderNotOwner(founder.uuid)
        }
        for owner in owners where founders.contains(owner) == false {
            throw OrganizationGenesisError.ownerNotFounder(owner.uuid)
        }
        let payload = try canonicalPayloadData()
        for signature in signatures where founders.contains(signature.founder) == false {
            throw OrganizationGenesisError.unexpectedSigner(signature.founder.uuid)
        }
        for founder in founders {
            guard let entry = signatures.first(where: { $0.founder == founder }) else {
                throw OrganizationGenesisError.founderSignatureMissing(founder.uuid)
            }
            guard IdentityPublicKeySignatureVerifier.verify(
                signature: entry.signature,
                messageData: payload,
                descriptor: founder
            ) else {
                throw OrganizationGenesisError.founderSignatureInvalid(founder.uuid)
            }
        }
    }
}

/// One step in the policy chain: the new version and the approvals that
/// adopted it under the previous version's amendment rule.
public struct GovernancePolicyAmendment: Codable, Equatable, Sendable {
    public var policy: GovernancePolicy
    public var bundle: ApprovalBundle

    public init(policy: GovernancePolicy, bundle: ApprovalBundle) {
        self.policy = policy
        self.bundle = bundle
    }

    /// A proposal to replace `current` with `next`. The approvers see a summary
    /// derived from `next`, never one supplied by the proposer.
    public static func proposal(
        replacing current: GovernancePolicy,
        with next: GovernancePolicy,
        organizationAnchorID: String,
        proposer: IdentityPublicKeyDescriptor,
        createdAt: String,
        expiresAt: String,
        nonce: Data
    ) throws -> OrganizationActionProposal {
        OrganizationActionProposal(
            organizationAnchorID: organizationAnchorID,
            policyHash: try current.policyHash(),
            actionClass: OrganizationActionClass.policyAmend,
            payloadHash: try next.policyHash(),
            payloadSummary: summary(replacing: current, with: next),
            audience: organizationAnchorID,
            createdAt: createdAt,
            expiresAt: expiresAt,
            nonce: nonce,
            proposer: proposer
        )
    }

    /// Plain Norwegian, built from the two policies only.
    public static func summary(replacing current: GovernancePolicy, with next: GovernancePolicy) -> String {
        let before = Set(current.owners.map(\.uuid))
        let after = Set(next.owners.map(\.uuid))
        let added = next.owners.filter { before.contains($0.uuid) == false }.map { $0.displayName ?? $0.uuid }
        let removed = current.owners.filter { after.contains($0.uuid) == false }.map { $0.displayName ?? $0.uuid }
        var parts = ["Policy v\(current.version) → v\(next.version)."]
        if added.isEmpty == false { parts.append("Ny eier: \(added.joined(separator: ", ")).") }
        if removed.isEmpty == false { parts.append("Fjernet eier: \(removed.joined(separator: ", ")).") }
        let agreementBefore = current.evidence.first { $0.kind == OwnershipAgreement.evidenceKind }?.reference
        let agreementAfter = next.evidence.first { $0.kind == OwnershipAgreement.evidenceKind }?.reference
        if agreementBefore != agreementAfter, let agreementAfter {
            parts.append("Eierskapsavtale: \(agreementAfter).")
        }
        return parts.joined(separator: " ")
    }
}

public enum GovernancePolicyChain {
    /// Verifies genesis and every amendment in order and returns the policy in
    /// force. Throws at the first step that does not hold.
    public static func verify(
        seal: OrganizationGenesisSeal,
        initialPolicy: GovernancePolicy,
        amendments: [GovernancePolicyAmendment]
    ) throws -> GovernancePolicy {
        try seal.verify(initialPolicy: initialPolicy)
        var current = initialPolicy
        for amendment in amendments {
            try verify(step: amendment, replacing: current, organizationAnchorID: seal.anchorID)
            current = amendment.policy
        }
        return current
    }

    public static func verify(
        step amendment: GovernancePolicyAmendment,
        replacing current: GovernancePolicy,
        organizationAnchorID: String
    ) throws {
        let next = amendment.policy
        let proposal = amendment.bundle.proposal
        guard next.policyID == current.policyID else { throw GovernancePolicyChainError.policyIDChanged }
        guard next.version == current.version + 1 else {
            throw GovernancePolicyChainError.versionNotNext(expected: current.version + 1, found: next.version)
        }
        guard next.previousPolicyHash == (try current.policyHash()) else {
            throw GovernancePolicyChainError.previousHashMismatch
        }
        guard proposal.organizationAnchorID == organizationAnchorID else {
            throw GovernancePolicyChainError.proposalNotForThisOrganization
        }
        guard proposal.actionClass == OrganizationActionClass.policyAmend else {
            throw GovernancePolicyChainError.proposalIsNotAnAmendment(proposal.actionClass)
        }
        guard proposal.policyHash == (try current.policyHash()) else {
            throw GovernancePolicyChainError.proposalNotUnderPreviousPolicy
        }
        guard proposal.payloadHash == (try next.policyHash()) else {
            throw GovernancePolicyChainError.payloadIsNotTheNewPolicy
        }
        // Evaluated at the moment of the newest approval, so a chain stays
        // verifiable after its proposals expire.
        let evaluation: GovernanceEvaluation
        do {
            evaluation = try GovernancePolicyEvaluator.evaluate(
                policy: current,
                bundle: amendment.bundle,
                now: decisionTime(of: amendment.bundle)
            )
        } catch let error as GovernanceEvaluationError {
            throw GovernancePolicyChainError.approvalsRefused(error)
        }
        guard evaluation.ruleID == current.amendmentRuleID else {
            throw GovernancePolicyChainError.amendmentRuleNotUsed(expected: current.amendmentRuleID, used: evaluation.ruleID)
        }
    }

    static func decisionTime(of bundle: ApprovalBundle) -> Date {
        let formatter = ISO8601DateFormatter()
        let times = bundle.approvals.compactMap { formatter.date(from: $0.approvedAt) }
        return times.max() ?? formatter.date(from: bundle.proposal.createdAt) ?? Date.distantPast
    }
}
