// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// Norwegian signing rules as data, enforced by a pure evaluator.
/// Design: Docs/Organization_Entities_and_Group_Signing_NO.md, goals M3 and M6.
final class GovernancePolicyEvaluatorTests: XCTestCase {
    private var vault: EphemeralIdentityVault!
    private var chair: Identity!
    private var board1: Identity!
    private var board2: Identity!
    private var ceo: Identity!
    private var procurist: Identity!
    private var outsider: Identity!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var policy: GovernancePolicy!

    override func setUp() async throws {
        vault = EphemeralIdentityVault()
        chair = try await identity("chair")
        board1 = try await identity("board1")
        board2 = try await identity("board2")
        ceo = try await identity("ceo")
        procurist = try await identity("procurist")
        outsider = try await identity("outsider")
        policy = try makeASPolicy()
    }

    // MARK: Rules

    func testChairAloneSatisfiesSignatur() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        let result = try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0)
        XCTAssertEqual(result.ruleID, "signatur")
        XCTAssertEqual(result.clauseIndex, 0)
        XCTAssertEqual(result.approverUUIDs, [chair.uuid])
    }

    func testTwoBoardMembersJointlySatisfySignatur() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(board1, .boardMember), (board2, .boardMember)])
        let result = try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0)
        XCTAssertEqual(result.ruleID, "signatur")
        XCTAssertEqual(result.clauseIndex, 1)
        XCTAssertEqual(Set(result.approverUUIDs), [board1.uuid, board2.uuid])
    }

    func testOneBoardMemberAloneIsNotEnough() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(board1, .boardMember)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .clauseNotSatisfied(ruleID: "signatur"))
        }
    }

    func testSamePersonWithTwoRolesDoesNotCountTwice() async throws {
        // board1 is both chair-deputy and board member in this policy variant:
        // "two board members jointly" must still need two people.
        var twoHats = policy!
        twoHats.members[1].roles = [.boardMember, .procurist]
        let bundle = try await bundle(
            policy: twoHats,
            action: "contract.sign",
            approvals: [(board1, .boardMember), (board1, .boardMember)]
        )
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: twoHats, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .clauseNotSatisfied(ruleID: "signatur"))
        }
    }

    func testProkuraNeedsCeoAndProcuristAndExcludesRealEstate() async throws {
        let ok = try await bundle(action: "contract.sign", approvals: [(ceo, .ceo), (procurist, .procurist)])
        let result = try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: ok, now: t0)
        XCTAssertEqual(result.ruleID, "prokura")

        let realEstate = try await bundle(action: "real_estate.transfer", approvals: [(ceo, .ceo), (procurist, .procurist)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: realEstate, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .actionExcluded(ruleID: "prokura"))
        }
    }

    func testDailyOperationsLimitIsEnforcedInMinorUnits() async throws {
        let within = try await bundle(action: "payment", amount: MonetaryAmount(minorUnits: 100_000_00, currency: "NOK"), approvals: [(ceo, .ceo)])
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: within, now: t0).ruleID, "drift")

        let over = try await bundle(action: "payment", amount: MonetaryAmount(minorUnits: 100_000_01, currency: "NOK"), approvals: [(ceo, .ceo)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: over, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .amountExceedsLimit(ruleID: "drift"))
        }

        let wrongCurrency = try await bundle(action: "payment", amount: MonetaryAmount(minorUnits: 1, currency: "EUR"), approvals: [(ceo, .ceo)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: wrongCurrency, now: t0))

        let noAmount = try await bundle(action: "payment", amount: nil, approvals: [(ceo, .ceo)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: noAmount, now: t0))
    }

    func testChairCanStillSignLargePaymentUnderSignatur() async throws {
        let big = try await bundle(action: "payment", amount: MonetaryAmount(minorUnits: 9_000_000_00, currency: "NOK"), approvals: [(chair, .chair)])
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: big, now: t0).ruleID, "signatur")
    }

    // MARK: Approvals

    func testRejectionVetoes() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)], rejections: [(board1, .boardMember)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .rejected(by: board1.uuid))
        }
    }

    func testOutsiderAndWrongRoleAreRefused() async throws {
        let outsiderBundle = try await bundle(action: "contract.sign", approvals: [(outsider, .chair)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: outsiderBundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approverNotMember(approver: outsider.uuid))
        }
        let wrongRole = try await bundle(action: "contract.sign", approvals: [(board1, .chair)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: wrongRole, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approverLacksRole(approver: board1.uuid, role: "chair"))
        }
    }

    func testTamperedApprovalSignatureIsRefused() async throws {
        var bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        bundle.approvals[0].role = .boardMember
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approvalSignatureInvalid(approver: chair.uuid))
        }
    }

    func testApprovalForAnotherProposalIsRefused() async throws {
        let a = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        var b = try await bundle(action: "credential.issue", approvals: [])
        b.approvals = a.approvals
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: b, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approvalForOtherProposal(approver: chair.uuid))
        }
    }

    func testStalePolicyHashIsRefused() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        var amended = policy!
        amended.version = 2
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: amended, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .policyHashMismatch)
        }
    }

    func testExpiredProposalIsRefused() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: t0.addingTimeInterval(3 * 3600))) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .proposalExpired)
        }
    }

    func testMemberOutsideValidityIsRefused() async throws {
        var rotated = policy!
        rotated.members[0].validUntil = iso(t0.addingTimeInterval(-60))
        let bundle = try await bundle(policy: rotated, action: "contract.sign", approvals: [(chair, .chair)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: rotated, bundle: bundle, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .approverNotValidAt(approver: chair.uuid))
        }
    }

    func testFreshAuthIsRequiredWhenRuleSaysSo() async throws {
        var strict = policy!
        strict.rules[0].requiresFreshAuth = true
        let without = try await bundle(policy: strict, action: "contract.sign", approvals: [(chair, .chair)])
        XCTAssertThrowsError(try GovernancePolicyEvaluator.evaluate(policy: strict, bundle: without, now: t0)) {
            XCTAssertEqual($0 as? GovernanceEvaluationError, .freshAuthRequired(approver: chair.uuid))
        }
        let evidence = IdentityLinkFreshAuthEvidence(method: "passkey", challenge: Data([1, 2, 3]), performedAt: iso(t0))
        let with = try await bundle(policy: strict, action: "contract.sign", approvals: [(chair, .chair)], freshAuth: evidence)
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: strict, bundle: with, now: t0).ruleID, "signatur")
    }

    func testSoleProprietorshipOwnerAlone() async throws {
        let enk = GovernancePolicy.soleProprietorship(
            policyID: "enk-1",
            owner: try IdentityLinkProtocolService.descriptor(for: ceo),
            validFrom: iso(t0.addingTimeInterval(-86_400))
        )
        let bundle = try await bundle(policy: enk, action: "anything.at.all", approvals: [(ceo, .owner)])
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: enk, bundle: bundle, now: t0).ruleID, "signatur")
    }

    func testPolicyAndBundleRoundTripJSON() async throws {
        let bundle = try await bundle(action: "contract.sign", approvals: [(chair, .chair)])
        let decodedPolicy = try JSONDecoder().decode(GovernancePolicy.self, from: try JSONEncoder().encode(policy))
        let decodedBundle = try JSONDecoder().decode(ApprovalBundle.self, from: try JSONEncoder().encode(bundle))
        XCTAssertEqual(decodedPolicy, policy)
        XCTAssertEqual(decodedBundle, bundle)
        XCTAssertEqual(try decodedPolicy.policyHash(), try policy.policyHash())
        XCTAssertEqual(try GovernancePolicyEvaluator.evaluate(policy: decodedPolicy, bundle: decodedBundle, now: t0).ruleID, "signatur")
    }

    // MARK: Helpers

    private func identity(_ context: String) async throws -> Identity {
        guard let identity = await vault.identity(for: context, makeNewIfNotFound: true) else {
            throw IdentityVaultError.noVaultIdentity
        }
        return identity
    }

    private func iso(_ date: Date) -> String {
        IdentityLinkProtocolService.iso8601(date)
    }

    /// A typical AS: chair alone or two board members; CEO + procurist for
    /// prokura except real estate; CEO alone for daily operations under 100 000 NOK.
    private func makeASPolicy() throws -> GovernancePolicy {
        let since = iso(t0.addingTimeInterval(-86_400))
        func member(_ identity: Identity, _ roles: [OrganizationRole]) throws -> OrganizationMember {
            OrganizationMember(identity: try IdentityLinkProtocolService.descriptor(for: identity), roles: roles, validFrom: since)
        }
        return GovernancePolicy(
            policyID: "as-1",
            version: 1,
            members: [
                try member(chair, [.chair, .boardMember]),
                try member(board1, [.boardMember]),
                try member(board2, [.boardMember]),
                try member(ceo, [.ceo]),
                try member(procurist, [.procurist]),
            ],
            rules: [
                SigningRule(
                    ruleID: "signatur",
                    anyOf: [
                        ApprovalClause(requirements: [RoleCount(role: .chair, minimum: 1)]),
                        ApprovalClause(requirements: [RoleCount(role: .boardMember, minimum: 2)]),
                    ],
                    actionClasses: ["contract.sign", "credential.issue", "payment", "real_estate.transfer"]
                ),
                SigningRule(
                    ruleID: "prokura",
                    anyOf: [ApprovalClause(requirements: [RoleCount(role: .ceo, minimum: 1), RoleCount(role: .procurist, minimum: 1)])],
                    actionClasses: ["contract.sign", "payment", "real_estate.transfer"],
                    excludedActions: ["real_estate.transfer", "real_estate.mortgage"]
                ),
                SigningRule(
                    ruleID: "drift",
                    anyOf: [ApprovalClause(requirements: [RoleCount(role: .ceo, minimum: 1)])],
                    actionClasses: ["payment", "contract.sign"],
                    limits: ActionLimits(maxAmount: MonetaryAmount(minorUnits: 100_000_00, currency: "NOK"))
                ),
            ],
            amendmentRuleID: "signatur",
            validFrom: since
        )
    }

    private func bundle(
        policy override: GovernancePolicy? = nil,
        action: String,
        amount: MonetaryAmount? = nil,
        approvals: [(Identity, OrganizationRole)],
        rejections: [(Identity, OrganizationRole)] = [],
        freshAuth: IdentityLinkFreshAuthEvidence? = nil
    ) async throws -> ApprovalBundle {
        let policy = override ?? self.policy!
        let proposal = OrganizationActionProposal(
            organizationAnchorID: "org-anchor",
            policyHash: try policy.policyHash(),
            actionClass: action,
            payloadHash: Data(repeating: 7, count: 32),
            payloadSummary: "Test",
            amount: amount,
            audience: "cell:///OrganizationVault",
            createdAt: iso(t0.addingTimeInterval(-60)),
            expiresAt: iso(t0.addingTimeInterval(3600)),
            nonce: Data((0..<16).map { UInt8($0) }),
            proposer: try IdentityLinkProtocolService.descriptor(for: ceo)
        )
        var signed: [OrganizationApproval] = []
        for (identity, role) in approvals {
            signed.append(try await OrganizationApproval.signed(proposal: proposal, approver: identity, role: role, freshAuthEvidence: freshAuth, now: t0))
        }
        for (identity, role) in rejections {
            signed.append(try await OrganizationApproval.signed(proposal: proposal, approver: identity, role: role, decision: .reject, now: t0))
        }
        return ApprovalBundle(proposal: proposal, approvals: signed)
    }
}
