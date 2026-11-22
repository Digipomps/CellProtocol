// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// Owner-group organizations: genesis, configurable ownership agreements and
/// the policy chain. PDD_informasjonssystemer-gruppeentitet_2026-11-17,
/// tests test.ge.genesis, test.ge.no-same-entity, test.ge.ownership-templates,
/// test.ge.owners-rules and test.ge.policy-chain.
final class OrganizationGenesisTests: XCTestCase {
    private var vault: EphemeralIdentityVault!
    private var kjetil: Identity!
    private var petter: Identity!
    private var third: Identity!
    private var outsider: Identity!
    private var custodian: Identity!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let anchorID = "entity:ifi-informasjonssystemer"

    override func setUp() async throws {
        vault = EphemeralIdentityVault()
        kjetil = try await identity("kjetil")
        petter = try await identity("petter")
        third = try await identity("third")
        outsider = try await identity("outsider")
        custodian = try await identity("vault")
    }

    // MARK: test.ge.genesis

    func testFounderSignedSealVerifies() async throws {
        let (seal, policy) = try await genesis(founders: [kjetil])
        XCTAssertNoThrow(try seal.verify(initialPolicy: policy))
        XCTAssertEqual(seal.kind, .organization)
        XCTAssertNil(seal.legalIdentifier)
    }

    func testSealWithTamperedPolicyIsRefused() async throws {
        let (seal, policy) = try await genesis(founders: [kjetil])
        var other = policy
        other.validFrom = iso(t0.addingTimeInterval(60))
        XCTAssertThrowsError(try seal.verify(initialPolicy: other)) {
            XCTAssertEqual($0 as? OrganizationGenesisError, .policyHashMismatch)
        }
    }

    func testSealMissingAFounderSignatureIsRefused() async throws {
        let policy = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll)
        var seal = try makeSeal(policy: policy, founders: [kjetil, petter])
        try await seal.sign(as: kjetil, now: t0)
        XCTAssertThrowsError(try seal.verify(initialPolicy: policy)) {
            XCTAssertEqual($0 as? OrganizationGenesisError, .founderSignatureMissing(self.petter.uuid))
        }
        try await seal.sign(as: petter, now: t0)
        XCTAssertNoThrow(try seal.verify(initialPolicy: policy))
    }

    func testSealWithEditedFieldAfterSigningIsRefused() async throws {
        var (seal, policy) = try await genesis(founders: [kjetil])
        seal.displayName = "Universitetet i Oslo"
        XCTAssertThrowsError(try seal.verify(initialPolicy: policy)) {
            XCTAssertEqual($0 as? OrganizationGenesisError, .founderSignatureInvalid(self.kjetil.uuid))
        }
    }

    func testOutsiderCannotSignSeal() async throws {
        var (seal, _) = try await genesis(founders: [kjetil])
        do {
            try await seal.sign(as: outsider, now: t0)
            XCTFail("outsider signed the seal")
        } catch {
            XCTAssertEqual(error as? OrganizationGenesisError, .unexpectedSigner(outsider.uuid))
        }
    }

    func testFoundersMustBeExactlyTheOwners() async throws {
        let policy = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll)
        var seal = try makeSeal(policy: policy, founders: [kjetil])
        try await seal.sign(as: kjetil, now: t0)
        XCTAssertThrowsError(try seal.verify(initialPolicy: policy)) {
            XCTAssertEqual($0 as? OrganizationGenesisError, .ownerNotFounder(self.petter.uuid))
        }
    }

    // MARK: test.ge.no-same-entity

    func testPersonCannotBeSameEntityAsOrganization() async throws {
        let registry = IdentityLinkRegistry()
        let organizationOwner = custodian.uuid
        let domain = "haven.digipomps.org"
        await registry.register(ownerUUID: organizationOwner, completion: try link(kjetil, domain: domain))
        await registry.register(ownerUUID: organizationOwner, completion: try link(custodian, domain: domain))

        // Before marking, the generic registry would honour the link: that is the gap.
        let before = await registry.sameEntityLink(ownerUUID: organizationOwner, requesterUUID: kjetil.uuid,
            requesterSigningKey: kjetil.publicSecureKey?.compressedKey, domain: domain)
        XCTAssertNotNil(before)

        await registry.markOrganization(ownerUUID: organizationOwner, machineIdentityUUIDs: [custodian.uuid])
        let person = await registry.sameEntityLink(ownerUUID: organizationOwner, requesterUUID: kjetil.uuid,
            requesterSigningKey: kjetil.publicSecureKey?.compressedKey, domain: domain)
        XCTAssertNil(person, "a person must never act as the organization")
        let machine = await registry.sameEntityLink(ownerUUID: organizationOwner, requesterUUID: custodian.uuid,
            requesterSigningKey: custodian.publicSecureKey?.compressedKey, domain: domain)
        XCTAssertNotNil(machine, "the organization's own vault identity may")
        let marked = await registry.isOrganization(ownerUUID: organizationOwner)
        XCTAssertTrue(marked)
    }

    // MARK: test.ge.ownership-templates / test.ge.owners-rules

    func testStartingAgreementOneOwnerGivesRolesButNotOwners() async throws {
        let policy = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll)
        let issue = try await bundle(policy, OrganizationActionClass.roleIssue, [kjetil])
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: issue, now: t0).ruleID, OwnershipAgreement.rolesRuleID)

        let amendAlone = try await bundle(policy, OrganizationActionClass.policyAmend, [kjetil])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: amendAlone, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .clauseNotSatisfied(ruleID: OwnershipAgreement.governanceRuleID))
        }
        let amendBoth = try await bundle(policy, OrganizationActionClass.policyAmend, [kjetil, petter])
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: amendBoth, now: t0).ruleID, OwnershipAgreement.governanceRuleID)
    }

    func testSameOwnerApprovingTwiceCountsOnce() async throws {
        let policy = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll)
        let twice = try await bundle(policy, OrganizationActionClass.policyAmend, [kjetil, kjetil])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: twice, now: t0))
    }

    func testTemplatesGiveTheirOwnOutcomesWithoutCodeChange() async throws {
        let owners: [Identity] = [kjetil, petter, third]
        // (template, approvers, action) -> accepted?
        let cases: [(OwnershipAgreement, [Identity], String, Bool)] = [
            (.rolesOneGovernanceAll, [kjetil], OrganizationActionClass.roleIssue, true),
            (.rolesOneGovernanceAll, [kjetil, petter], OrganizationActionClass.policyAmend, false),
            (.rolesOneGovernanceAll, [kjetil, petter, third], OrganizationActionClass.policyAmend, true),
            (.allTwo, [kjetil], OrganizationActionClass.roleIssue, false),
            (.allTwo, [kjetil, third], OrganizationActionClass.roleRevoke, true),
            (.oneAlone, [petter], OrganizationActionClass.policyAmend, true),
            (.twoOfThree, [petter], OrganizationActionClass.policyAmend, false),
            (.twoOfThree, [petter, third], OrganizationActionClass.policyAmend, true),
        ]
        for (agreement, approvers, action, accepted) in cases {
            let policy = try ownerPolicy(owners, agreement)
            let b = try await bundle(policy, action, approvers)
            let result = try? GovernancePolicyEvaluator.evaluate(policy: policy, bundle: b, now: t0)
            XCTAssertEqual(result != nil, accepted, "\(agreement.templateID) \(action) by \(approvers.count)")
        }
    }

    func testQuorumThatCannotBeMetIsRefusedAtBuildTime() throws {
        XCTAssertThrowsError(try ownerPolicy([kjetil], .allTwo)) {
            XCTAssertEqual($0 as? OwnershipAgreementError, .quorumCannotBeMet(rule: OwnershipAgreement.rolesRuleID, ownerCount: 1))
        }
    }

    func testOutsiderCannotGiveRoles() async throws {
        let policy = try ownerPolicy([kjetil], .rolesOneGovernanceAll)
        let b = try await bundle(policy, OrganizationActionClass.roleIssue, [outsider])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: b, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approverNotMember(approver: self.outsider.uuid))
        }
    }

    // MARK: test.ge.policy-chain

    func testKjetilAloneThenPetterAddedAsNewVersion() async throws {
        let (seal, v1) = try await genesis(founders: [kjetil])
        let v2 = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll, version: 2, previous: try v1.policyHash())
        let step = try await amendment(from: v1, to: v2, approvers: [kjetil])
        let current = try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [step])
        XCTAssertEqual(current, v2)
        XCTAssertEqual(Set(current.owners.map(\.uuid)), [kjetil.uuid, petter.uuid])
        XCTAssertEqual(step.bundle.proposal.payloadSummary.contains("Ny eier"), true)

        // Under v2, adding a third owner needs both.
        let v3 = try ownerPolicy([kjetil, petter, third], .rolesOneGovernanceAll, version: 3, previous: try v2.policyHash())
        let kjetilAlone = try await amendment(from: v2, to: v3, approvers: [kjetil])
        XCTAssertThrowsError(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [step, kjetilAlone])) {
            XCTAssertEqual($0 as? GovernancePolicyChainError,
                .approvalsRefused(.clauseNotSatisfied(ruleID: OwnershipAgreement.governanceRuleID)))
        }
        let both = try await amendment(from: v2, to: v3, approvers: [kjetil, petter])
        XCTAssertEqual(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [step, both]), v3)
    }

    func testAgreementChangeIsANewVersionUnderTheCurrentRule() async throws {
        let (seal, v1) = try await genesis(founders: [kjetil])
        let v2 = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll, version: 2, previous: try v1.policyHash())
        let step2 = try await amendment(from: v1, to: v2, approvers: [kjetil])
        let v3 = try ownerPolicy([kjetil, petter], .allTwo, version: 3, previous: try v2.policyHash())
        let step3 = try await amendment(from: v2, to: v3, approvers: [kjetil, petter])
        let current = try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [step2, step3])
        XCTAssertEqual(current.evidence.first { $0.kind == OwnershipAgreement.evidenceKind }?.reference, "all-two")
        XCTAssertTrue(step3.bundle.proposal.payloadSummary.contains("all-two"))
        // Under all-two, one owner can no longer give a role.
        let issue = try await bundle(current, OrganizationActionClass.roleIssue, [kjetil])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: current, bundle: issue, now: t0))
    }

    func testChainRefusesSkippedVersionWrongPredecessorAndSwappedPayload() async throws {
        let (seal, v1) = try await genesis(founders: [kjetil])
        let skipped = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll, version: 3, previous: try v1.policyHash())
        let a = try await amendment(from: v1, to: skipped, approvers: [kjetil])
        XCTAssertThrowsError(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [a])) {
            XCTAssertEqual($0 as? GovernancePolicyChainError, .versionNotNext(expected: 2, found: 3))
        }
        let orphan = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll, version: 2, previous: Data(repeating: 7, count: 32))
        let b = try await amendment(from: v1, to: orphan, approvers: [kjetil])
        XCTAssertThrowsError(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [b])) {
            XCTAssertEqual($0 as? GovernancePolicyChainError, .previousHashMismatch)
        }
        let v2 = try ownerPolicy([kjetil, petter], .rolesOneGovernanceAll, version: 2, previous: try v1.policyHash())
        var swapped = try await amendment(from: v1, to: v2, approvers: [kjetil])
        swapped.policy = try ownerPolicy([kjetil, outsider], .rolesOneGovernanceAll, version: 2, previous: try v1.policyHash())
        XCTAssertThrowsError(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [swapped])) {
            XCTAssertEqual($0 as? GovernancePolicyChainError, .payloadIsNotTheNewPolicy)
        }
    }

    func testRoleIssueBundleCannotAmendThePolicy() async throws {
        let (seal, v1) = try await genesis(founders: [kjetil])
        let v2 = try ownerPolicy([kjetil, outsider], .rolesOneGovernanceAll, version: 2, previous: try v1.policyHash())
        let roleBundle = try await bundle(v1, OrganizationActionClass.roleIssue, [kjetil], payload: try v2.policyHash())
        let step = GovernancePolicyAmendment(policy: v2, bundle: roleBundle)
        XCTAssertThrowsError(try GovernancePolicyChain.verify(seal: seal, initialPolicy: v1, amendments: [step])) {
            XCTAssertEqual($0 as? GovernancePolicyChainError, .proposalIsNotAnAmendment(OrganizationActionClass.roleIssue))
        }
    }

    // MARK: Helpers

    private func identity(_ context: String) async throws -> Identity {
        guard let identity = await vault.identity(for: context, makeNewIfNotFound: true) else {
            throw IdentityVaultError.noVaultIdentity
        }
        return identity
    }

    private func iso(_ date: Date) -> String { IdentityLinkProtocolService.iso8601(date) }

    private func descriptor(_ identity: Identity) throws -> IdentityPublicKeyDescriptor {
        try IdentityLinkProtocolService.descriptor(for: identity)
    }

    private func ownerPolicy(
        _ owners: [Identity],
        _ agreement: OwnershipAgreement,
        version: Int = 1,
        previous: Data? = nil
    ) throws -> GovernancePolicy {
        try GovernancePolicy.ownerGroup(
            policyID: anchorID,
            version: version,
            previousPolicyHash: previous,
            owners: try owners.map(descriptor),
            agreement: agreement,
            validFrom: iso(t0.addingTimeInterval(-86_400))
        )
    }

    private func makeSeal(policy: GovernancePolicy, founders: [Identity]) throws -> OrganizationGenesisSeal {
        OrganizationGenesisSeal(
            anchorID: anchorID,
            displayName: "Informasjonssystemer (Ifi, UiO)",
            initialPolicyHash: try policy.policyHash(),
            custodianKey: try descriptor(custodian),
            founders: try founders.map(descriptor),
            sealedAt: iso(t0)
        )
    }

    private func genesis(founders: [Identity]) async throws -> (OrganizationGenesisSeal, GovernancePolicy) {
        let policy = try ownerPolicy(founders, .rolesOneGovernanceAll)
        var seal = try makeSeal(policy: policy, founders: founders)
        for founder in founders { try await seal.sign(as: founder, now: t0) }
        return (seal, policy)
    }

    private func bundle(
        _ policy: GovernancePolicy,
        _ action: String,
        _ approvers: [Identity],
        payload: Data = Data(repeating: 1, count: 32)
    ) async throws -> ApprovalBundle {
        let proposal = OrganizationActionProposal(
            organizationAnchorID: anchorID,
            policyHash: try policy.policyHash(),
            actionClass: action,
            payloadHash: payload,
            payloadSummary: "test",
            audience: anchorID,
            createdAt: iso(t0.addingTimeInterval(-60)),
            expiresAt: iso(t0.addingTimeInterval(3_600)),
            nonce: Data(UUID().uuidString.utf8),
            proposer: try descriptor(approvers.first ?? kjetil)
        )
        var approvals: [OrganizationApproval] = []
        for approver in approvers {
            approvals.append(try await OrganizationApproval.signed(proposal: proposal, approver: approver, role: .owner, now: t0))
        }
        return ApprovalBundle(proposal: proposal, approvals: approvals)
    }

    private func amendment(from current: GovernancePolicy, to next: GovernancePolicy, approvers: [Identity]) async throws -> GovernancePolicyAmendment {
        let proposal = try GovernancePolicyAmendment.proposal(
            replacing: current, with: next, organizationAnchorID: anchorID,
            proposer: try descriptor(approvers[0]),
            createdAt: iso(t0.addingTimeInterval(-60)), expiresAt: iso(t0.addingTimeInterval(3_600)),
            nonce: Data(UUID().uuidString.utf8))
        var approvals: [OrganizationApproval] = []
        for approver in approvers {
            approvals.append(try await OrganizationApproval.signed(proposal: proposal, approver: approver, role: .owner, now: t0))
        }
        return GovernancePolicyAmendment(policy: next, bundle: ApprovalBundle(proposal: proposal, approvals: approvals))
    }

    private func link(_ identity: Identity, domain: String) throws -> IdentityLinkCompletionResult {
        let record = IdentityLinkRecord(
            linkID: "link-\(identity.uuid)",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: EntityGenesisService.anchorReference),
            linkedIdentity: try descriptor(identity),
            approvedDomains: [domain],
            approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: custodian.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: iso(t0)
        )
        return IdentityLinkCompletionResult(record: record, requestHash: Data(), approvalJTI: "jti", credentialID: "cred", presentationID: "pres")
    }
}
