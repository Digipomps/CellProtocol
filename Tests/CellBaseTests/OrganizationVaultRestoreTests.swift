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
        let restored = try await restore(try copy(await org.snapshot()))

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

        // The restored vault goes on from where it was: sequence 3, and what it
        // signs next restores again.
        let (second, _) = try await issue(on: restored, role: "student")
        let (revocation2, list2) = try await restored.proposeRevocation(credentialIDs: [second.id], proposer: try d(kjetil), now: t0)
        XCTAssertEqual(list2.sequence, 3)
        XCTAssertEqual(Set(list2.revokedCredentialIDs), [signed.id, second.id])
        let published2 = try await restored.revoke(list: list2, bundle: try await approve(revocation2, by: [kjetil]), now: t0)
        try await CredentialStatusRegistry.shared.accept(published, now: t0)
        try await CredentialStatusRegistry.shared.accept(published2, now: t0)
        let again = try await restore(try copy(await restored.snapshot()))
        let againJournal = await again.journal
        XCTAssertEqual(againJournal.count, 6)
    }

    func testFreshVaultRestoresFromItsGenesisSnapshot() async throws {
        let org = try await makeVault()
        let restored = try await restore(await org.snapshot())
        let journal = await restored.journal
        XCTAssertEqual(journal.count, 1)
        let list = await restored.statusList
        XCTAssertEqual(list?.sequence, 1)
    }

    func testSnapshotIsTiedToTheExpectedOrganization() async throws {
        let org = try await makeVault()
        _ = try await issue(on: org, role: "researcher")
        let good = await org.snapshot()

        // Another key than the sealed custodian key.
        await assertVault(.custodianKeyMismatch) {
            try await OrganizationVault(restoring: good, expectedSealHash: try self.seal.sealHash(),
                credentialType: self.credentialType, custodian: SoftwareOrganizationKeyCustodian(identity: self.otherCustodian))
        }

        var schema = good
        schema.schema = "haven.organization-vault-snapshot.v0"
        await assertRefused(.unsupportedSchema("haven.organization-vault-snapshot.v0"), schema)

        // A complete, self-consistent snapshot of another organization, sealed
        // by someone else over the same custodian key.
        let foreign = try await makeVault(founder: petter).snapshot()
        await assertRefused(.sealNotExpected, foreign)

        // The credential type comes from the caller, not from the storage.
        var retyped = good
        retyped.credentialType = "AnotherRoleCredential"
        await assertRefused(.credentialTypeNotExpected("AnotherRoleCredential"), retyped)
        await assertVault(.snapshotRefused(.credentialTypeNotExpected(credentialType))) {
            try await OrganizationVault(restoring: good, expectedSealHash: try self.seal.sealHash(),
                credentialType: "AnotherRoleCredential", custodian: self.custodian())
        }
    }

    func testJournalMustBeBackedByTheOwnersApprovals() async throws {
        let org = try await makeVault()
        let (first, _) = try await issue(on: org, role: "researcher")
        _ = try await issue(on: org, role: "student")
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [first.id], proposer: try d(kjetil), now: t0)
        _ = try await org.revoke(list: list, bundle: try await approve(revocation, by: [kjetil]), now: t0)
        let good = try copy(await org.snapshot())

        // An entry removed or rewritten without relinking breaks the chain.
        var shortJournal = good
        shortJournal.journal.remove(at: 1)
        await assertRefused(.journalBroken, shortJournal)
        var rewritten = good
        rewritten.journal[1].payloadSummary = "Ufarlig endring"
        await assertRefused(.journalBroken, rewritten)
        var noGenesis = good
        noGenesis.journal[0].ruleID = "roles"
        try await relink(&noGenesis)
        await assertRefused(.journalDoesNotStartAtGenesis, noGenesis)
        for edit: (inout OrganizationJournalEntry) -> Void in [
            { $0.proposalHash = Data() }, { $0.policyVersion = 99 },
            { $0.actionClass = OrganizationActionClass.roleIssue }, { $0.recordedAt = "2020-01-01T00:00:00Z" },
            { $0.payloadSummary = "Noe annet" }, { $0.approverUUIDs = [] }, { $0.payloadHash = Data() },
        ] {
            var genesis = good
            edit(&genesis.journal[0])
            try await relink(&genesis)
            await assertRefused(.journalDoesNotStartAtGenesis, genesis)
        }

        // The chain can be recomputed by whoever holds the storage, but not
        // the custodian's signature over each entry.
        var relinkedOnly = good
        relinkedOnly.journal[2].payloadSummary = "Ufarlig endring"
        try await relink(&relinkedOnly, resign: false)
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 3), relinkedOnly)
        var takenOut = good
        takenOut.journal.remove(at: 1)
        takenOut.journalSignatures.remove(at: 1)
        takenOut.bundles.remove(at: 0)
        takenOut.issued.removeAll { $0.id == first.id }
        try await relink(&takenOut, resign: false)
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 2), takenOut)
        var unsigned = good
        unsigned.journalSignatures.removeLast()
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 4), unsigned)
        var oneTooMany = good
        oneTooMany.journalSignatures.append(good.journalSignatures[0])
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 5), oneTooMany)

        // Behind the signature, every entry must still be what the owners
        // approved: a rewrite signed with the custodian key is refused too.
        var relinkedSummary = good
        relinkedSummary.journal[1].payloadSummary = "Ufarlig endring"
        try await relink(&relinkedSummary)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), relinkedSummary)

        var otherApprovers = good
        otherApprovers.journal[2].approverUUIDs = [petter.uuid]
        try await relink(&otherApprovers)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 3), otherApprovers)

        var otherRule = good
        otherRule.journal[1].ruleID = "anything"
        try await relink(&otherRule)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), otherRule)

        // The recorded time must be a real time inside the proposal's
        // validity, and the action the one the owners approved.
        var beforeProposal = good
        beforeProposal.journal[1].recordedAt = IdentityLinkProtocolService.iso8601(t0.addingTimeInterval(-86_400))
        try await relink(&beforeProposal)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), beforeProposal)
        var afterExpiry = good
        afterExpiry.journal[1].recordedAt = IdentityLinkProtocolService.iso8601(t0.addingTimeInterval(30 * 86_400))
        try await relink(&afterExpiry)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), afterExpiry)
        var notATime = good
        notATime.journal[1].recordedAt = "not a time"
        try await relink(&notATime)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), notATime)
        var otherClass = good
        otherClass.journal[1].actionClass = OrganizationActionClass.roleRevoke
        try await relink(&otherClass)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), otherClass)

        // The same approved entry recorded twice: its nonce is already used.
        var replayed = good
        replayed.journal.insert(good.journal[1], at: 2)
        replayed.bundles.insert(good.bundles[0], at: 1)
        try await relink(&replayed)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 3), replayed)

        // Bundles swapped, dropped, or used for two entries.
        var swapped = good
        swapped.bundles.swapAt(0, 1)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), swapped)
        var missing = good
        missing.bundles.removeLast()
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 4), missing)
        var reused = good
        reused.bundles[1] = reused.bundles[0]
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 3), reused)

        // An approval that is not the owner's signature.
        var forgedApproval = good
        forgedApproval.bundles[0].approvals[0].signature = Data(repeating: 7, count: 64)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), forgedApproval)
    }

    func testStatusListAndCredentialsMustBeTheOnesTheJournalRecords() async throws {
        let org = try await makeVault()
        let (first, _) = try await issue(on: org, role: "researcher")
        let (second, _) = try await issue(on: org, role: "student")
        let genesisList = await org.statusList
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [first.id], proposer: try d(kjetil), now: t0)
        _ = try await org.revoke(list: list, bundle: try await approve(revocation, by: [kjetil]), now: t0)
        let afterFirstRevocation = try copy(await org.snapshot())
        let (revocation2, list2) = try await org.proposeRevocation(credentialIDs: [second.id], proposer: try d(kjetil), now: t0)
        _ = try await org.revoke(list: list2, bundle: try await approve(revocation2, by: [kjetil]), now: t0)
        let good = try copy(await org.snapshot())

        // The older status list put back, so a revoked role looks valid again.
        var rolledBackList = good
        rolledBackList.statusList = genesisList
        await assertRefused(.statusListDoesNotMatchJournal, rolledBackList)
        var olderList = good
        olderList.statusList = afterFirstRevocation.statusList
        await assertRefused(.statusListDoesNotMatchJournal, olderList)
        var unsignedList = good
        unsignedList.statusList?.revokedCredentialIDs = []
        await assertRefused(.statusListNotSignedByCustodian, unsignedList)
        var noList = good
        noList.statusList = nil
        await assertRefused(.statusListMissing, noList)

        // The first revocation taken out of the middle, chain relinked. The
        // sequence the custodian signed still counts it.
        var middleRemoved = good
        middleRemoved.journal.remove(at: 3)
        middleRemoved.bundles.remove(at: 2)
        try await relink(&middleRemoved)
        await assertRefused(.statusListDoesNotMatchJournal, middleRemoved)
        // Same removal with the list from before the second revocation put
        // back: the count agrees, but the journal records another list.
        var middleRemovedOlderList = middleRemoved
        middleRemovedOlderList.statusList = afterFirstRevocation.statusList
        await assertRefused(.statusListDoesNotMatchJournal, middleRemovedOlderList)
        var otherListSignature = good
        otherListSignature.journal[4].signatureHash = OrganizationHashing.sha256(Data("x".utf8))
        try await relink(&otherListSignature)
        await assertRefused(.statusListDoesNotMatchJournal, otherListSignature)

        // A role dropped, a role edited after signing, a role added twice.
        var dropped = good
        dropped.issued.removeLast()
        await assertRefused(.credentialsDoNotMatchJournal, dropped)
        var edited = try copy(good)
        edited.issued[0].credentialSubject[OrganizationRoleCredential.Field.role] = .string("supervisor")
        await assertRefused(.credentialsDoNotMatchJournal, edited)
        var doubled = good
        doubled.issued.append(good.issued[0])
        await assertRefused(.credentialsDoNotMatchJournal, doubled)

        // A signature the custodian did not make, with the journal rewritten
        // to say it did.
        var forged = try copy(good)
        let target = forged.issued[0]
        let wasHash = OrganizationHashing.sha256(target.proof.signatureData)
        target.proof.signatureData = Data(repeating: 9, count: 64)
        let index = try XCTUnwrap(forged.journal.firstIndex { $0.signatureHash == wasHash })
        forged.journal[index].signatureHash = OrganizationHashing.sha256(target.proof.signatureData)
        try await relink(&forged)
        await assertRefused(.credentialNotSignedByCustodian(target.id), forged)
    }

    func testAmendmentsMustBeTheOnesTheJournalRecords() async throws {
        let org = try await makeVault()
        let current = await org.policy
        let v2 = try policy([kjetil, petter], version: 2, previous: try current.policyHash())
        let amendment = try await org.proposeAmendment(next: v2, proposer: try d(kjetil), now: t0)
        try await org.amend(to: v2, bundle: try await approve(amendment, by: [kjetil]), now: t0)
        let afterAmend = try copy(await org.snapshot())
        _ = try await issue(on: org, role: "researcher")
        let good = try copy(await org.snapshot())
        _ = try await restore(good)

        // The amendment kept, its journal entry and bundle cut off.
        var unjournaled = afterAmend
        unjournaled.journal.removeLast()
        unjournaled.journalSignatures.removeLast()
        unjournaled.bundles.removeLast()
        await assertRefused(.amendmentsDoNotMatchJournal, unjournaled)

        // An amendment entry claims a signature it never had.
        var amendSignature = afterAmend
        amendSignature.journal[1].signatureHash = OrganizationHashing.sha256(Data("x".utf8))
        try await relink(&amendSignature)
        await assertRefused(.amendmentsDoNotMatchJournal, amendSignature)

        var missing = good
        missing.amendments = []
        await assertRefused(.amendmentsDoNotMatchJournal, missing)

        // The amendment taken out together with its journal entry and bundle,
        // chain relinked: the role after it was signed under version 2.
        var removed = good
        removed.amendments = []
        removed.journal.remove(at: 1)
        removed.bundles.remove(at: 0)
        try await relink(&removed)
        await assertRefused(.journalEntryNotBackedByApprovals(sequence: 2), removed)

        // Another policy put in the amendment's place.
        var replaced = good
        replaced.amendments[0].policy = try policy([petter], version: 2, previous: try current.policyHash())
        do {
            _ = try await restore(replaced)
            XCTFail("expected the amendment to be refused")
        } catch OrganizationVaultError.amendment {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAmendmentTheVaultNeverAcceptedIsRefused() async throws {
        // The owners signed an amendment but never handed it to the vault.
        // The storage owner appends it with a time of their choosing.
        let org = try await makeVault()
        let current = await org.policy
        let v2 = try policy([petter], version: 2, previous: try current.policyHash())
        let proposal = try await org.proposeAmendment(next: v2, proposer: try d(kjetil), now: t0)
        let bundle = try await approve(proposal, by: [kjetil])
        var snapshot = try copy(await org.snapshot())
        let evaluation = try GovernancePolicyEvaluator.evaluate(policy: current, bundle: bundle, now: t0)
        snapshot.amendments.append(GovernancePolicyAmendment(policy: v2, bundle: bundle))
        snapshot.bundles.append(bundle)
        snapshot.journal.append(OrganizationJournalEntry(
            sequence: 2, previousEntryHash: try snapshot.journal[0].entryHash(),
            recordedAt: IdentityLinkProtocolService.iso8601(t0), actionClass: OrganizationActionClass.policyAmend,
            proposalHash: try proposal.proposalHash(), payloadHash: try v2.policyHash(),
            payloadSummary: proposal.payloadSummary, policyVersion: current.version, ruleID: evaluation.ruleID,
            approverUUIDs: evaluation.approverUUIDs, signatureHash: OrganizationHashing.sha256(Data())))
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 2), snapshot)
        snapshot.journalSignatures.append(snapshot.journalSignatures[0])
        await assertRefused(.journalEntryNotSignedByCustodian(sequence: 2), snapshot)

        // The same snapshot is what the vault itself would have stored, so
        // with the custodian's signature it restores.
        try await relink(&snapshot)
        let restored = try await restore(snapshot)
        let adopted = await restored.policy
        XCTAssertEqual(adopted, v2)
    }

    func testSnapshotWithAnotherInitialPolicyIsRefused() async throws {
        let org = try await makeVault()
        var snapshot = await org.snapshot()
        snapshot.initialPolicy = try policy([petter])
        do {
            _ = try await restore(snapshot)
            XCTFail("expected the initial policy to be refused")
        } catch {}
    }

    func testVaultSignsOnlyCredentialsItCanRestore() async throws {
        let org = try await makeVault()
        let current = await org.policy
        let (proposal, _) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let otherType = try OrganizationRoleCredential.unsigned(
            organizationAnchorID: anchorID, credentialType: "AnotherRoleCredential", custodian: try d(custodianIdentity),
            subject: try d(student), role: "researcher", cohort: "MasterHAVEN26", validUntil: "2027-06-30",
            policyHash: try current.policyHash(), issuedAt: t0)
        let otherPolicy = try OrganizationRoleCredential.unsigned(
            organizationAnchorID: anchorID, credentialType: credentialType, custodian: try d(custodianIdentity),
            subject: try d(student), role: "researcher", cohort: "MasterHAVEN26", validUntil: "2027-06-30",
            policyHash: Data("another policy".utf8), issuedAt: t0)
        for credential in [otherType, otherPolicy] {
            // The owners approve exactly this credential; the vault still refuses.
            var approved = proposal
            approved.nonce = Data(UUID().uuidString.utf8)
            approved.payloadHash = try OrganizationRoleCredential.payloadHash(of: credential)
            approved.payloadSummary = OrganizationRoleCredential.summary(of: credential, displayName: "Informasjonssystemer (Ifi, UiO)")
            let bundle = try await approve(approved, by: [kjetil])
            await assertVault(.credentialNotForThisVault) {
                try await org.issueRole(credential: credential, bundle: bundle, now: self.t0)
            }
            XCTAssertTrue(credential.proof.signatureData.isEmpty)
        }
        let journal = await org.journal
        XCTAssertEqual(journal.count, 1)
    }

    func testCredentialIDIsSignedOnlyOnce() async throws {
        let org = try await makeVault()
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let signed = try await org.issueRole(credential: credential, bundle: try await approve(proposal, by: [kjetil]), now: t0)
        // The credential handed in stays unsigned, and what the vault hands
        // out does not share its proof with what the vault keeps.
        XCTAssertTrue(credential.proof.signatureData.isEmpty)
        signed.proof.signatureData = Data()
        let kept = await org.issued
        XCTAssertFalse(try XCTUnwrap(kept[credential.id]).proof.signatureData.isEmpty)
        let verified = try await XCTUnwrap(kept[credential.id]).verify()
        XCTAssertTrue(verified)
        var second = proposal
        second.nonce = Data("another-nonce".utf8)
        let bundle = try await approve(second, by: [kjetil])
        await assertVault(.credentialAlreadyIssued(credential.id)) {
            try await org.issueRole(credential: credential, bundle: bundle, now: self.t0)
        }
        let journal = await org.journal
        XCTAssertEqual(journal.count, 2)
    }

    func testVaultSignsOneThingAtATime() async throws {
        let gate = Gate()
        let org = try await makeVault(custodian: GatedCustodian(inner: custodian(), gate: gate))
        let (first, _) = try await issue(on: org, role: "researcher")
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [first.id], proposer: try d(kjetil), now: t0)
        let revocationBundle = try await approve(revocation, by: [kjetil])
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "student",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let roleBundle = try await approve(proposal, by: [kjetil])

        // The first call is held at the custodian while the second arrives.
        await gate.close()
        let before = await gate.arrivals
        let t0 = self.t0
        let held = Task { try await org.issueRole(credential: credential, bundle: roleBundle, now: t0) }
        var waited = 0
        while await gate.arrivals == before, waited < 2_000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        let arrived = await gate.arrivals
        XCTAssertEqual(arrived, before + 1)
        await assertVault(.signingInProgress) {
            try await org.revoke(list: list, bundle: revocationBundle, now: t0)
        }
        await gate.open()
        let signed = try await held.value

        // Nothing was lost or signed twice, and the refused call works now.
        let published = try await org.revoke(list: list, bundle: revocationBundle, now: t0)
        XCTAssertEqual(published.sequence, 2)
        let journal = await org.journal
        XCTAssertEqual(journal.map(\.sequence), [1, 2, 3, 4])
        let issued = await org.issued
        XCTAssertEqual(Set(issued.keys), [first.id, signed.id])
        _ = try await restore(try copy(await org.snapshot()))
    }

    func testEverySignatureIsStoredBeforeItIsHandedOut() async throws {
        let stored = StoredSnapshots()
        let org = try await makeVault(store: { try stored.put($0) })
        XCTAssertEqual(stored.all.count, 1, "the genesis state is stored")

        let (signed, _) = try await issue(on: org, role: "researcher")
        XCTAssertEqual(stored.all.count, 2)
        XCTAssertEqual(stored.all.last?.issued.map(\.id), [signed.id])

        // A restart after the store call knows the role.
        let restored = try await restore(try copy(try XCTUnwrap(stored.all.last)))
        let issued = await restored.issued
        XCTAssertEqual(Array(issued.keys), [signed.id])
    }

    func testVaultThatCannotStoreSignsNothingMore() async throws {
        let stored = StoredSnapshots()
        let org = try await makeVault(store: { try stored.put($0) })
        let (first, _) = try await issue(on: org, role: "researcher")

        stored.failing = true
        let (proposal, credential) = try await org.proposeRole(subject: try d(student), role: "student",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", proposer: try d(kjetil), now: t0)
        let bundle = try await approve(proposal, by: [kjetil])
        do {
            _ = try await org.issueRole(credential: credential, bundle: bundle, now: t0)
            XCTFail("the signed role must not be handed out when it was not stored")
        } catch {
            XCTAssertTrue(error is StoredSnapshots.Failure)
        }
        // The signature did not leave the vault: not on the credential handed
        // in, and not through anything that can be read from the vault.
        XCTAssertTrue(credential.proof.signatureData.isEmpty)
        let visible = await org.issued
        XCTAssertEqual(Array(visible.keys), [first.id])
        let visibleJournal = await org.journal
        XCTAssertEqual(visibleJournal.count, 2)
        let visibleSnapshot = await org.snapshot()
        XCTAssertEqual(visibleSnapshot.issued.map(\.id), [first.id])

        // Also after the storage is back: the vault's memory and the storage
        // disagree, so a new vault must start from what was stored.
        stored.failing = false
        let (revocation, list) = try await org.proposeRevocation(credentialIDs: [first.id], proposer: try d(kjetil), now: t0)
        let revocationBundle = try await approve(revocation, by: [kjetil])
        await assertVault(.stateNotStored) {
            try await org.revoke(list: list, bundle: revocationBundle, now: self.t0)
        }
        let restored = try await restore(try copy(try XCTUnwrap(stored.all.last)))
        let issued = await restored.issued
        XCTAssertEqual(Array(issued.keys), [first.id])
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

    /// The seal of the organization the tests expect, as a deployment would
    /// have it in its configuration.
    private var seal: OrganizationGenesisSeal!

    private func makeVault(
        founder: Identity? = nil,
        custodian: OrganizationKeyCustodian? = nil,
        store: OrganizationVaultStore? = nil
    ) async throws -> OrganizationVault {
        let owner = founder ?? kjetil!
        let v1 = try policy([owner])
        var seal = OrganizationGenesisSeal(anchorID: anchorID, displayName: "Informasjonssystemer (Ifi, UiO)",
            initialPolicyHash: try v1.policyHash(), custodianKey: try d(custodianIdentity),
            founders: [try d(owner)], sealedAt: IdentityLinkProtocolService.iso8601(t0))
        try await seal.sign(as: owner, now: t0)
        if founder == nil { self.seal = seal }
        return try await OrganizationVault(seal: seal, initialPolicy: v1, custodian: custodian ?? self.custodian(),
                                           credentialType: credentialType, store: store)
    }

    private func restore(_ snapshot: OrganizationVaultSnapshot) async throws -> OrganizationVault {
        try await OrganizationVault(restoring: snapshot, expectedSealHash: try seal.sealHash(),
                                    credentialType: credentialType, custodian: custodian())
    }

    /// A deep copy through JSON. VCProof is a class, so a plain copy of a
    /// snapshot shares its proofs with the original.
    private func copy(_ snapshot: OrganizationVaultSnapshot) throws -> OrganizationVaultSnapshot {
        try JSONDecoder().decode(OrganizationVaultSnapshot.self, from: try JSONEncoder().encode(snapshot))
    }

    /// Recomputes the hash chain after an edit. Whoever controls the storage
    /// can do that much. With `resign` the entries are signed again with the
    /// custodian key, which only the vault can do: those cases show that the
    /// checks behind the journal signature hold on their own.
    private func relink(_ snapshot: inout OrganizationVaultSnapshot, resign: Bool = true) async throws {
        var previous: Data?
        var signatures: [Data] = []
        for index in snapshot.journal.indices {
            snapshot.journal[index].sequence = index + 1
            snapshot.journal[index].previousEntryHash = previous
            previous = try snapshot.journal[index].entryHash()
            signatures.append(try await custodian().sign(try OrganizationVault.journalSigningData(snapshot.journal[index])))
        }
        if resign { snapshot.journalSignatures = signatures }
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
            try await self.restore(snapshot)
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

private actor Gate {
    private var closed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func close() { closed = true }

    func pass() async {
        arrivals += 1
        guard closed else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        closed = false
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// A custodian that can be held while it is asked for the signing identity.
private struct GatedCustodian: OrganizationKeyCustodian {
    let inner: SoftwareOrganizationKeyCustodian
    let gate: Gate
    var keyIsExportable: Bool { inner.keyIsExportable }

    func publicKey() async throws -> IdentityPublicKeyDescriptor { try await inner.publicKey() }
    func sign(_ data: Data) async throws -> Data { try await inner.sign(data) }
    func signingIdentity() async throws -> Identity {
        await gate.pass()
        return try await inner.signingIdentity()
    }
}

private final class StoredSnapshots: @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var snapshots: [OrganizationVaultSnapshot] = []
    private var fails = false

    var all: [OrganizationVaultSnapshot] { lock.withLock { snapshots } }
    var failing: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }

    func put(_ snapshot: OrganizationVaultSnapshot) throws {
        try lock.withLock {
            if fails { throw Failure() }
            snapshots.append(snapshot)
        }
    }
}
