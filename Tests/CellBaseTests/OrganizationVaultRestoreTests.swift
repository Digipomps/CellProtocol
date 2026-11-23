// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

// purpose://candidate.informasjonssystemer-gruppeentitet.vault
//
// test.ge.vault-restore: a vault started from its stored snapshot remembers
// what it signed, and a snapshot that cannot account for a signature is refused.
final class OrganizationVaultRestoreTests: XCTestCase {
    private var vault: EphemeralIdentityVault!
    private var kjetil: Identity!
    private var petter: Identity!
    private var student: Identity!
    private var custodianIdentity: Identity!
    private var otherCustodian: Identity!
    private let anchorID = "entity:ifi-informasjonssystemer"
    private let credentialType = "InformasjonssystemerRoleCredential"
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUp() async throws {
        vault = EphemeralIdentityVault()
        kjetil = try await identity("kjetil")
        petter = try await identity("petter")
        student = try await identity("student")
        custodianIdentity = try await identity("custodian")
        otherCustodian = try await identity("other-custodian")
        await CredentialStatusRegistry.shared.clear()
    }

    override func tearDown() async throws {
        await CredentialStatusRegistry.shared.clear()
        CellBase.defaultCellResolver = nil
    }

    func testRestoredVaultRemembersRolesSequencePolicyAndNonces() async throws {
        let org = try await makeVault()
        let (signed, roleBundle) = try await issue(on: org, role: "researcher")
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [signed.id], proposer: try d(kjetil), now: t0)
        let published = try await org.revoke(list: list, bundle: try await approve(revocation, by: [kjetil]), now: t0)
        let current = await org.policy
        let v2 = try policy([kjetil, petter], version: 2, previous: try current.policyHash())
        let amendment = try await org.proposeAmendment(next: v2, proposer: try d(kjetil), now: t0)
        try await org.amend(to: v2, bundle: try await approve(amendment, by: [kjetil]), now: t0)

        // Through JSON, as a cell would store it.
        let stored = try JSONEncoder().encode(await org.snapshot())
        let snapshot = try JSONDecoder().decode(OrganizationVaultSnapshot.self, from: stored)
        let restored = try await OrganizationVault(restoring: snapshot, custodian: custodian())

        let restoredPolicy = await restored.policy
        XCTAssertEqual(restoredPolicy, v2)
        let restoredList = await restored.statusList
        XCTAssertEqual(restoredList, published)
        XCTAssertEqual(restoredList?.sequence, 2)
        let journal = await restored.journal
        XCTAssertEqual(journal.map(\.actionClass), [
            OrganizationActionClass.roleStatusPublish, OrganizationActionClass.roleIssue,
            OrganizationActionClass.roleRevoke, OrganizationActionClass.policyAmend,
        ])
        let intact = await restored.journalIsIntact()
        XCTAssertTrue(intact)
        let issued = await restored.issued
        XCTAssertEqual(Array(issued.keys), [signed.id])

        // The bundle that issued the role cannot be used again after a restart.
        let (_, credentialAgain) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        await assertVault(.nonceAlreadyUsed) {
            try await restored.issueRole(credential: credentialAgain, bundle: roleBundle, now: self.t0)
        }

        // The restored vault goes on from where it was: sequence 3, and the
        // v2 policy now needs both owners to change the agreement.
        let (second, _) = try await issue(on: restored, role: "student")
        let (revocation2, list2) = try await restored.proposeRevocation(credentialIDs: [second.id], proposer: try d(kjetil), now: t0)
        XCTAssertEqual(list2.sequence, 3)
        XCTAssertEqual(list2.revokedCredentialIDs, [signed.id, second.id])
        let published2 = try await restored.revoke(list: list2, bundle: try await approve(revocation2, by: [kjetil]), now: t0)
        try await CredentialStatusRegistry.shared.accept(published, now: t0)
        try await CredentialStatusRegistry.shared.accept(published2, now: t0)
    }

    func testFreshVaultRestoresFromItsGenesisSnapshot() async throws {
        let org = try await makeVault()
        let restored = try await OrganizationVault(restoring: await org.snapshot(), custodian: custodian())
        let journal = await restored.journal
        XCTAssertEqual(journal.count, 1)
        let list = await restored.statusList
        XCTAssertEqual(list?.sequence, 1)
    }

    func testSnapshotThatCannotAccountForASignatureIsRefused() async throws {
        let org = try await makeVault()
        let (signed, _) = try await issue(on: org, role: "researcher")
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [signed.id], proposer: try d(kjetil), now: t0)
        _ = try await org.revoke(list: list, bundle: try await approve(revocation, by: [kjetil]), now: t0)
        let good = await org.snapshot()
        let genesisOnly = try await makeVault().snapshot()

        // Another key than the sealed custodian key.
        await assertVault(.custodianKeyMismatch) {
            try await OrganizationVault(restoring: good, custodian: SoftwareOrganizationKeyCustodian(identity: self.otherCustodian))
        }

        var schema = good
        schema.schema = "haven.organization-vault-snapshot.v0"
        await assertRefused(.unsupportedSchema("haven.organization-vault-snapshot.v0"), schema)

        // A journal entry removed, or rewritten.
        var shortJournal = good
        shortJournal.journal.remove(at: 1)
        await assertRefused(.journalBroken, shortJournal)
        var rewritten = good
        rewritten.journal[1].payloadSummary = "Ufarlig endring"
        await assertRefused(.journalBroken, rewritten)

        // The older status list put back, so the revoked role looks valid again.
        var rolledBackList = good
        rolledBackList.statusList = genesisOnly.statusList
        await assertRefused(.statusListDoesNotMatchJournal, rolledBackList)
        var unsignedList = good
        unsignedList.statusList?.revokedCredentialIDs = []
        await assertRefused(.statusListNotSignedByCustodian, unsignedList)
        var noList = good
        noList.statusList = nil
        await assertRefused(.statusListMissing, noList)

        // A role dropped, a role edited after signing, a role added.
        var dropped = good
        dropped.issued = []
        await assertRefused(.credentialsDoNotMatchJournal, dropped)
        var edited = good
        edited.issued[0].credentialSubject[OrganizationRoleCredential.Field.role] = .string("supervisor")
        await assertRefused(.credentialsDoNotMatchJournal, edited)
        var doubled = good
        doubled.issued.append(good.issued[0])
        await assertRefused(.credentialsDoNotMatchJournal, doubled)

        // A nonce forgotten, which would let its bundle be replayed.
        var forgotten = good
        forgotten.usedNonces.removeLast()
        await assertRefused(.noncesDoNotMatchJournal, forgotten)
    }

    func testAmendmentMissingFromSnapshotIsRefused() async throws {
        let org = try await makeVault()
        let current = await org.policy
        let v2 = try policy([kjetil, petter], version: 2, previous: try current.policyHash())
        let amendment = try await org.proposeAmendment(next: v2, proposer: try d(kjetil), now: t0)
        try await org.amend(to: v2, bundle: try await approve(amendment, by: [kjetil]), now: t0)
        var snapshot = await org.snapshot()
        snapshot.amendments = []
        await assertRefused(.amendmentsDoNotMatchJournal, snapshot)
    }

    // MARK: Rig

    private func identity(_ context: String) async throws -> Identity {
        guard let identity = await vault.identity(for: context, makeNewIfNotFound: true) else {
            throw IdentityVaultError.noVaultIdentity
        }
        return identity
    }

    private func d(_ identity: Identity) throws -> IdentityPublicKeyDescriptor {
        try IdentityLinkProtocolService.descriptor(for: identity)
    }

    private func custodian() -> SoftwareOrganizationKeyCustodian {
        SoftwareOrganizationKeyCustodian(identity: custodianIdentity)
    }

    private func policy(_ owners: [Identity], version: Int = 1, previous: Data? = nil) throws -> GovernancePolicy {
        try GovernancePolicy.ownerGroup(policyID: anchorID, version: version, previousPolicyHash: previous,
            owners: try owners.map(d), agreement: .rolesOneGovernanceAll,
            validFrom: IdentityLinkProtocolService.iso8601(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func makeVault() async throws -> OrganizationVault {
        let v1 = try policy([kjetil])
        var seal = OrganizationGenesisSeal(anchorID: anchorID, displayName: "Informasjonssystemer (Ifi, UiO)",
            initialPolicyHash: try v1.policyHash(), custodianKey: try d(custodianIdentity),
            founders: [try d(kjetil)], sealedAt: IdentityLinkProtocolService.iso8601(t0))
        try await seal.sign(as: kjetil, now: t0)
        return try await OrganizationVault(seal: seal, initialPolicy: v1, custodian: custodian(), credentialType: credentialType)
    }

    private func issue(on org: OrganizationVault, role: String) async throws -> (VCClaim, ApprovalBundle) {
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: role,
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let bundle = try await approve(proposal, by: [kjetil])
        return (try await org.issueRole(credential: credential, bundle: bundle, now: t0), bundle)
    }

    private func approve(_ proposal: OrganizationActionProposal, by approvers: [Identity]) async throws -> ApprovalBundle {
        var approvals: [OrganizationApproval] = []
        for approver in approvers {
            approvals.append(try await OrganizationApproval.signed(proposal: proposal, approver: approver, role: .owner, now: t0))
        }
        return ApprovalBundle(proposal: proposal, approvals: approvals)
    }

    private func assertRefused(_ expected: OrganizationVaultSnapshotError, _ snapshot: OrganizationVaultSnapshot,
                               file: StaticString = #filePath, line: UInt = #line) async {
        await assertVault(.snapshotRefused(expected), file: file, line: line) {
            try await OrganizationVault(restoring: snapshot, custodian: self.custodian())
        }
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
