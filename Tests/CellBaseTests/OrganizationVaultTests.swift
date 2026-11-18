// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// The organization vault, role credentials, status lists and the Agreement
/// condition that reads them. PDD_informasjonssystemer-gruppeentitet_2026-11-17,
/// tests test.ge.vault-negative, test.ge.journal, test.ge.role-vc-fixture,
/// test.ge.revoke-next-access, test.ge.status-offline, test.ge.condition-interop
/// (Swift column) and test.ge.issuer-not-trusted.
final class OrganizationVaultTests: XCTestCase {
    private var vault: EphemeralIdentityVault!
    private var kjetil: Identity!
    private var petter: Identity!
    private var student: Identity!
    private var outsider: Identity!
    private var custodianIdentity: Identity!
    private let anchorID = "entity:ifi-informasjonssystemer"
    private let credentialType = "InformasjonssystemerRoleCredential"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        vault = EphemeralIdentityVault()
        kjetil = try await identity("kjetil")
        petter = try await identity("petter")
        student = try await identity("student")
        outsider = try await identity("outsider")
        custodianIdentity = try await identity("org-vault")
        await CredentialStatusRegistry.shared.clear()
    }

    override func tearDown() async throws {
        await CredentialStatusRegistry.shared.clear()
        CellBase.defaultCellResolver = nil
    }

    // MARK: test.ge.vault-negative

    func testVaultRefusesWrongCustodianKey() async throws {
        let (seal, policy) = try await genesis()
        let other = SoftwareOrganizationKeyCustodian(identity: outsider)
        do {
            _ = try await OrganizationVault(seal: seal, initialPolicy: policy, custodian: other, credentialType: credentialType)
            XCTFail("vault accepted a key the seal does not name")
        } catch {
            XCTAssertEqual(error as? OrganizationVaultError, .custodianKeyMismatch)
        }
    }

    func testVaultSignsOnlyApprovedRoleAndRefusesReplayAndTampering() async throws {
        let org = try await makeVault()
        let (proposal, credential) = try await org.proposeRole(
            subject: try d(student), role: "researcher", cohort: "MasterHAVEN26",
            validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let bundle = try await approve(proposal, by: [kjetil])
        let signed = try await org.issueRole(credential: credential, bundle: bundle, now: t0)
        let verified = try await signed.verify()
        XCTAssertTrue(verified)
        XCTAssertEqual(signed.type, ["VerifiableCredential", OrganizationRoleCredential.genericType, credentialType])
        XCTAssertEqual(signed.credentialSubject["id"], .string(try student.did()))

        // Same bundle again: nonce already used.
        await assertVault(.nonceAlreadyUsed) { try await org.issueRole(credential: credential, bundle: bundle, now: self.t0) }

        // Another role under an approval for this one.
        let (proposal2, _) = try await org.proposeRole(subject: try d(student), role: "student", cohort: "MasterHAVEN26",
            validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        var swapped = credential
        swapped.credentialSubject[OrganizationRoleCredential.Field.role] = .string("supervisor")
        let bundle2 = try await approve(proposal2, by: [kjetil])
        await assertVault(.payloadDoesNotMatchApprovedHash) { try await org.issueRole(credential: swapped, bundle: bundle2, now: self.t0) }

        // Proposer-written summary that differs from the payload.
        var (proposal3, credential3) = try await org.proposeRole(subject: try d(student), role: "student", cohort: nil,
            validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        proposal3.payloadSummary = "Ufarlig endring"
        let bundle3 = try await approve(proposal3, by: [kjetil])
        await assertVault(.summaryDoesNotMatchPayload) { try await org.issueRole(credential: credential3, bundle: bundle3, now: self.t0) }

        // An outsider's approval, and an expired proposal.
        let (proposal4, credential4) = try await org.proposeRole(subject: try d(student), role: "student", cohort: nil,
            validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let bundle4 = try await approve(proposal4, by: [outsider])
        await assertVault(.refused(.approverNotMember(approver: outsider.uuid))) {
            try await org.issueRole(credential: credential4, bundle: bundle4, now: self.t0)
        }
        let bundle5 = try await approve(proposal4, by: [kjetil])
        await assertVault(.refused(.proposalExpired)) {
            try await org.issueRole(credential: credential4, bundle: bundle5, now: self.t0.addingTimeInterval(8 * 86_400))
        }
    }

    func testVaultRefusesAmendmentWithoutAllOwnersAndJournalsWhoApproved() async throws {
        let org = try await makeVault()
        let current = await org.policy
        let v2 = try policy([kjetil, petter], version: 2, previous: try current.policyHash())
        let proposal = try await org.proposeAmendment(next: v2, proposer: try d(kjetil), now: t0)
        try await org.amend(to: v2, bundle: try await approve(proposal, by: [kjetil]), now: t0)
        let owners = await org.policy.owners.map(\.uuid)
        XCTAssertEqual(Set(owners), [kjetil.uuid, petter.uuid])

        let v3 = try policy([kjetil, petter, outsider], version: 3, previous: try v2.policyHash())
        let p3 = try await org.proposeAmendment(next: v3, proposer: try d(kjetil), now: t0)
        await assertVault(.amendment(.approvalsRefused(.clauseNotSatisfied(ruleID: OwnershipAgreement.governanceRuleID)))) {
            try await org.amend(to: v3, bundle: try await self.approve(p3, by: [self.kjetil]), now: self.t0)
        }

        // test.ge.journal
        let journal = await org.journal
        XCTAssertEqual(journal.map(\.actionClass), [OrganizationActionClass.roleStatusPublish, OrganizationActionClass.policyAmend])
        XCTAssertEqual(journal.last?.approverUUIDs, [kjetil.uuid])
        let intact = await org.journalIsIntact()
        XCTAssertTrue(intact)
        let chained = try await org.verifyChain()
        XCTAssertEqual(chained, v2)
    }

    // MARK: test.ge.revoke-next-access / test.ge.status-offline / condition

    func testRoleOpensCellUntilRevokedAndStatusMirrorFailsClosedWhenStale() async throws {
        let org = try await makeVault()
        let issuerDID = try await org.issuerDID()
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2099-06-30", proposer: try d(kjetil), now: Date())
        let signed = try await org.issueRole(credential: credential, bundle: try await approve(proposal, by: [kjetil]), now: Date())
        let firstListOptional = await org.statusList
        let firstList = try XCTUnwrap(firstListOptional)
        try await CredentialStatusRegistry.shared.accept(firstList)

        let rig = try await conditionRig(issuerDID: issuerDID, credential: signed)
        var state = await rig.condition.isMet(context: ConnectContext(source: nil, target: rig.target, identity: student))
        XCTAssertEqual(state, .met, "a valid researcher role from the group opens the cell")

        // Wrong role in the statement.
        let wrongRole = ProvedClaimCondition(name: rig.contextID,
            statement: "identity.claims.informasjonssystemer_researcher = \"supervisor\"",
            requiredCredentialType: credentialType, subjectClaimPath: OrganizationRoleCredential.Field.role)
        state = await wrongRole.isMet(context: ConnectContext(source: nil, target: rig.target, identity: student))
        XCTAssertEqual(state, .unresolved)

        // Stale mirror: unknown, closed. No call to the organization is involved.
        let staleStatus = await CredentialStatusRegistry.shared.status(issuerDID: issuerDID, credentialID: signed.id,
            now: Date().addingTimeInterval(CredentialStatusRegistry.defaultMaximumAge + 1))
        XCTAssertEqual(staleStatus, .unknown)

        // Revoke: the next check is refused.
        let (rp, list) = try await org.proposeRevocation(credentialIDs: [signed.id], proposer: try d(kjetil), now: Date())
        let revoked = try await org.revoke(list: list, bundle: try await approve(rp, by: [kjetil]), now: Date())
        try await CredentialStatusRegistry.shared.accept(revoked)
        state = await rig.condition.isMet(context: ConnectContext(source: nil, target: rig.target, identity: student))
        XCTAssertEqual(state, .unresolved, "a revoked role no longer opens the cell")

        // An older list cannot roll the revocation back.
        do {
            try await CredentialStatusRegistry.shared.accept(firstList)
            XCTFail("older list accepted")
        } catch {
            XCTAssertEqual(error as? CredentialStatusMirrorError, .sequenceNotNewer(current: 2, offered: 1))
        }
    }

    func testIssuerNotTrustedOrExpiredRoleIsRefused() async throws {
        let org = try await makeVault()
        let issuerDID = try await org.issuerDID()
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2020-01-01", proposer: try d(kjetil), now: Date())
        let expired = try await org.issueRole(credential: credential, bundle: try await approve(proposal, by: [kjetil]), now: Date())
        let expiredListOptional = await org.statusList
        try await CredentialStatusRegistry.shared.accept(try XCTUnwrap(expiredListOptional))
        let rig = try await conditionRig(issuerDID: issuerDID, credential: expired)
        let expiredState = await rig.condition.isMet(context: ConnectContext(source: nil, target: rig.target, identity: student))
        XCTAssertEqual(expiredState, .unresolved, "validUntil inside credentialSubject is enforced")

        let (p2, c2) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2099-01-01", proposer: try d(kjetil), now: Date())
        let valid = try await org.issueRole(credential: c2, bundle: try await approve(p2, by: [kjetil]), now: Date())
        let untrusted = try await conditionRig(issuerDID: issuerDID, credential: valid, registerIssuer: false)
        let untrustedState = await untrusted.condition.isMet(context: ConnectContext(source: nil, target: untrusted.target, identity: student))
        XCTAssertEqual(untrustedState, .unresolved, "a group is not a trusted issuer until the node says so")
    }

    func testCredentialSurvivesJSONRoundTrip() async throws {
        let org = try await makeVault()
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "student",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let signed = try await org.issueRole(credential: credential, bundle: try await approve(proposal, by: [kjetil]), now: t0)
        let decoded = try JSONDecoder().decode(VCClaim.self, from: try JSONEncoder().encode(signed))
        let verified = try await decoded.verify()
        XCTAssertTrue(verified)
        XCTAssertEqual(try OrganizationRoleCredential.payloadHash(of: decoded), proposal.payloadHash)
    }

    // MARK: test.ge.condition-interop (shared table, Swift column)

    private struct AccessScenario: Decodable {
        let id: String
        let credential: String
        let issuerTrusted: Bool
        let status: String
        let expectedRole: String
        let decision: String
        let reason: String
    }

    private struct AccessMatrix: Decodable {
        let scenarios: [AccessScenario]
    }

    /// fixtures/interop/v1/org.access-matrix.json: Python and Go check the same
    /// table with their ports. Here every scenario runs the real path:
    /// ProvedClaimCondition for the decision, TrustedIssuerCell for the reason.
    func testAccessMatrixMatchesSharedTable() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/interop/v1/org.access-matrix.json")
        let matrix = try JSONDecoder().decode(AccessMatrix.self, from: Data(contentsOf: url))
        XCTAssertEqual(matrix.scenarios.count, 7)
        for scenario in matrix.scenarios {
            await CredentialStatusRegistry.shared.clear()
            let org = try await makeVault()
            let issuerDID = try await org.issuerDID()
            let (proposal, unsigned) = try await org.proposeRole(subject: try d(student), role: "researcher",
                cohort: "MasterHAVEN26", validUntil: scenario.credential == "expired" ? "2020-01-01" : "2099-06-30",
                proposer: try d(kjetil), now: Date())
            var credential = try await org.issueRole(credential: unsigned, bundle: try await approve(proposal, by: [kjetil]), now: Date())
            if scenario.credential == "tampered" {
                credential.credentialSubject[OrganizationRoleCredential.Field.role] = .string(scenario.expectedRole)
            }
            let firstListOptional = await org.statusList
            let firstList = try XCTUnwrap(firstListOptional)
            switch scenario.status {
            case "fresh":
                try await CredentialStatusRegistry.shared.accept(firstList)
            case "stale":
                try await CredentialStatusRegistry.shared.accept(firstList, now: Date().addingTimeInterval(-601))
            case "revoked":
                let (rp, list) = try await org.proposeRevocation(credentialIDs: [credential.id], proposer: try d(kjetil), now: Date())
                try await CredentialStatusRegistry.shared.accept(try await org.revoke(list: list, bundle: try await approve(rp, by: [kjetil]), now: Date()))
            default:
                XCTFail("\(scenario.id): unknown status \(scenario.status)")
            }

            let rig = try await conditionRig(issuerDID: issuerDID, credential: credential,
                                             registerIssuer: scenario.issuerTrusted, expectedRole: scenario.expectedRole)
            let state = await rig.condition.isMet(context: ConnectContext(source: nil, target: rig.target, identity: student))
            XCTAssertEqual(state == .met ? "met" : "unresolved", scenario.decision, scenario.id)

            let resolved = try await CellBase.defaultCellResolver?.cellAtEndpoint(endpoint: "cell:///TrustedIssuers", requester: student)
            let trusted = try XCTUnwrap(resolved as? Meddle)
            let response = try await trusted.set(keypath: "trustedIssuers.evaluate", value: .object([
                "issuerId": .string(issuerDID), "contextId": .string(rig.contextID),
                "requesterId": .string(try student.did()),
                "candidateVc": .object(try JSONDecoder().decode(Object.self, from: try JSONEncoder().encode(credential))),
            ]), requester: student)
            guard case .object(let body)? = response, case .list(let reasons)? = body["reasons"] else {
                XCTFail("\(scenario.id): no reasons in \(String(describing: response))")
                continue
            }
            XCTAssertTrue(reasons.contains(.string(scenario.reason)), "\(scenario.id): \(reasons) lacks \(scenario.reason)")
        }
    }

    // MARK: Helpers

    private struct ConditionRig {
        let target: GeneralCell
        let condition: ProvedClaimCondition
        let contextID: String
    }

    private func conditionRig(issuerDID: String, credential: VCClaim, registerIssuer: Bool = true,
                              expectedRole: String = "researcher") async throws -> ConditionRig {
        CellBase.debugValidateAccessForEverything = false
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        let registryOwner = try await identity("node-owner")
        let targetOwner = try await identity("target-owner")
        let contextID = "informasjonssystemer.researcher"

        let anchor = TestEmitCell(owner: student, uuid: "student-anchor-\(UUID().uuidString)")
        _ = try await anchor.set(keypath: "claims.informasjonssystemer_researcher",
                                 value: .verifiableCredential(credential), requester: student)
        try await resolver.registerNamedEmitCell(name: "EntityAnchor", emitCell: anchor, scope: .identityUnique, identity: student)

        let trusted = await TrustedIssuerCell(owner: registryOwner)
        try await resolver.registerNamedEmitCell(name: "TrustedIssuers", emitCell: trusted, scope: .scaffoldUnique, identity: student)
        _ = try await trusted.set(keypath: "trustedIssuers.policy.upsert", value: .object([
            "contextId": .string(contextID),
            "threshold": .float(0.5),
            "maximumCredentialAgeSeconds": .float(400.0 * 86_400.0),
            "requireRevocationCheck": .bool(true),
            "requireSubjectBinding": .bool(true),
            "requireIndependentSources": .integer(0),
            "acceptedDidMethods": .list([.string("did:key")]),
            "claimSchema": .object([
                "credentialType": .string(credentialType),
                "subjectPath": .string("credentialSubject.role"),
                "operator": .string("=="),
                "expectedValue": .string(expectedRole),
            ]),
        ]), requester: registryOwner)
        if registerIssuer {
            _ = try await trusted.set(keypath: "trustedIssuers.issuer.upsert", value: .object([
                "issuerId": .string(issuerDID),
                "displayName": .string("Informasjonssystemer (Ifi, UiO)"),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextID)]),
            ]), requester: registryOwner)
        }
        let target = await GeneralCell(owner: targetOwner)
        let condition = ProvedClaimCondition(
            name: contextID,
            statement: "identity.claims.informasjonssystemer_researcher = \"\(expectedRole)\"",
            requiredCredentialType: credentialType,
            subjectClaimPath: OrganizationRoleCredential.Field.role)
        return ConditionRig(target: target, condition: condition, contextID: contextID)
    }

    private func identity(_ context: String) async throws -> Identity {
        guard let identity = await vault.identity(for: context, makeNewIfNotFound: true) else {
            throw IdentityVaultError.noVaultIdentity
        }
        return identity
    }

    private func d(_ identity: Identity) throws -> IdentityPublicKeyDescriptor {
        try IdentityLinkProtocolService.descriptor(for: identity)
    }

    private func iso(_ date: Date) -> String { IdentityLinkProtocolService.iso8601(date) }

    private func policy(_ owners: [Identity], version: Int = 1, previous: Data? = nil) throws -> GovernancePolicy {
        try GovernancePolicy.ownerGroup(policyID: anchorID, version: version, previousPolicyHash: previous,
            owners: try owners.map(d), agreement: .rolesOneGovernanceAll,
            validFrom: iso(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func genesis() async throws -> (OrganizationGenesisSeal, GovernancePolicy) {
        let v1 = try policy([kjetil])
        var seal = OrganizationGenesisSeal(anchorID: anchorID, displayName: "Informasjonssystemer (Ifi, UiO)",
            initialPolicyHash: try v1.policyHash(), custodianKey: try d(custodianIdentity),
            founders: [try d(kjetil)], sealedAt: iso(t0))
        try await seal.sign(as: kjetil, now: t0)
        return (seal, v1)
    }

    private func makeVault() async throws -> OrganizationVault {
        let (seal, v1) = try await genesis()
        return try await OrganizationVault(seal: seal, initialPolicy: v1,
            custodian: SoftwareOrganizationKeyCustodian(identity: custodianIdentity), credentialType: credentialType)
    }

    private func approve(_ proposal: OrganizationActionProposal, by approvers: [Identity]) async throws -> ApprovalBundle {
        var approvals: [OrganizationApproval] = []
        let at = ISO8601DateFormatter().date(from: proposal.createdAt) ?? t0
        for approver in approvers {
            approvals.append(try await OrganizationApproval.signed(proposal: proposal, approver: approver, role: .owner, now: at))
        }
        return ApprovalBundle(proposal: proposal, approvals: approvals)
    }

    private func assertVault<T>(_ expected: OrganizationVaultError, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OrganizationVaultError, expected, file: file, line: line)
        }
    }
}
