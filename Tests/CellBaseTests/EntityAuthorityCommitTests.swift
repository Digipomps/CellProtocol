// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class EntityAuthorityCommitTests: XCTestCase {
    func testLegacyBatchEnvelopeWireShapeRemainsCompatible() throws {
        let legacy = EntityBatchPersistEnvelope(
            schema: "test.batch.v1",
            mutations: [EntityBatchPersistMutation(keypath: "person.name", value: .string("Ada"))],
            metadata: ["source": .string("test")]
        )

        let object = legacy.objectValue()
        XCTAssertNil(object["commitRequest"])
        XCTAssertEqual(try EntityBatchPersistEnvelope(object: object), legacy)

        let encoded = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(EntityBatchPersistEnvelope.self, from: encoded)
        XCTAssertNil(decoded.commitRequest)
        XCTAssertEqual(decoded, legacy)
    }

    func testAuthorityCommitIsSignedHashChainedAndIdempotent() async throws {
        let owner = try await makeOwner("authority-idempotency")
        let base: Entity = ["person": .object([:]), "chronicle": .object([:])]
        var envelope = EntityBatchPersistEnvelope(
            schema: "test.entity-turn.v1",
            mutations: [EntityBatchPersistMutation(keypath: "person.name", value: .string("Ada"))],
            metadata: ["purposeRef": .string("purpose://access.audit.privacy")]
        )
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: "mutation-ada-1",
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: "purpose://access.audit.privacy"
        )

        let initial = EntityAuthorityJournalDocument()
        let committed = try await initial.appending(
            envelope: envelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-test",
            committedAtEpochMilliseconds: 1_000
        )

        XCTAssertFalse(committed.idempotentReplay)
        XCTAssertEqual(committed.journal.revision, 1)
        XCTAssertEqual(try committed.snapshot.get(keypath: "person.name"), .string("Ada"))
        XCTAssertTrue(committed.receipt.verifies(with: owner))
        XCTAssertEqual(committed.receipt.status, "authority_committed")
        XCTAssertFalse(committed.receipt.quorumSatisfied)
        XCTAssertFalse(committed.receipt.distributedCommit)
        XCTAssertEqual(committed.receipt.replicationState, "local_authority_only")

        let receiptWire = try committed.receipt.valueType()
        XCTAssertEqual(try EntityAuthorityCommitReceipt(value: receiptWire), committed.receipt)

        let replayed = try await committed.journal.appending(
            envelope: envelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-test",
            committedAtEpochMilliseconds: 9_999
        )
        XCTAssertTrue(replayed.idempotentReplay)
        XCTAssertEqual(replayed.journal.entries.count, 1)
        XCTAssertEqual(replayed.receipt, committed.receipt)
        XCTAssertEqual(try replayed.snapshot.get(keypath: "person.name"), .string("Ada"))
    }

    func testMutationIDCannotBeReboundToDifferentPayload() async throws {
        let owner = try await makeOwner("authority-conflict")
        let base: Entity = ["person": .object([:])]
        let first = try await signedEnvelope(
            value: "first",
            mutationID: "stable-mutation",
            owner: owner,
            revision: 0,
            headHash: nil
        )
        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: first,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-test",
            committedAtEpochMilliseconds: 1
        )
        let conflicting = try await signedEnvelope(
            value: "second",
            mutationID: "stable-mutation",
            owner: owner,
            revision: 1,
            headHash: committed.journal.headHash
        )

        do {
            _ = try await committed.journal.appending(
                envelope: conflicting,
                to: committed.snapshot,
                requester: owner,
                authority: owner,
                authorityCellUUID: "entity-anchor-test",
                committedAtEpochMilliseconds: 2
            )
            XCTFail("Expected mutation ID rebinding to fail closed")
        } catch let error as EntityAuthorityCommitError {
            XCTAssertEqual(error, .mutationIDConflict("stable-mutation"))
        }
    }

    func testStaleRevisionAndUnavailableQuorumDoNotMutateJournal() async throws {
        let owner = try await makeOwner("authority-cas")
        let base: Entity = ["person": .object([:])]
        var stale = EntityBatchPersistEnvelope(
            schema: "test.entity.v1",
            mutations: [EntityBatchPersistMutation(keypath: "person.state", value: .string("stale"))]
        )
        stale.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: stale,
            mutationID: "stale-1",
            epoch: 1,
            expectedRevision: 3,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: "purpose://access.audit.privacy"
        )

        do {
            _ = try await EntityAuthorityJournalDocument().appending(
                envelope: stale,
                to: base,
                requester: owner,
                authority: owner,
                authorityCellUUID: "entity-anchor-test",
                committedAtEpochMilliseconds: 1
            )
            XCTFail("Expected stale revision to be rejected")
        } catch let error as EntityAuthorityCommitError {
            XCTAssertEqual(error, .staleRevision(expected: 3, actual: 0))
        }

        var quorum = EntityBatchPersistEnvelope(
            schema: "test.entity.v1",
            mutations: [EntityBatchPersistMutation(keypath: "person.state", value: .string("quorum"))]
        )
        quorum.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: quorum,
            mutationID: "quorum-1",
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: "purpose://access.audit.privacy",
            requiredReplicaAcks: 2
        )

        do {
            _ = try await EntityAuthorityJournalDocument().appending(
                envelope: quorum,
                to: base,
                requester: owner,
                authority: owner,
                authorityCellUUID: "entity-anchor-test",
                committedAtEpochMilliseconds: 1
            )
            XCTFail("Expected unavailable quorum to fail before append")
        } catch let error as EntityAuthorityCommitError {
            XCTAssertEqual(error, .quorumUnavailable(requiredReplicaAcks: 2))
        }
    }

    func testJournalTamperingIsDetectedAndReplayRebuildsCommittedValues() async throws {
        let owner = try await makeOwner("authority-replay")
        let base: Entity = ["person": .object([:])]
        let firstEnvelope = try await signedEnvelope(
            value: "one",
            mutationID: "chain-1",
            owner: owner,
            revision: 0,
            headHash: nil
        )
        let first = try await EntityAuthorityJournalDocument().appending(
            envelope: firstEnvelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-test",
            committedAtEpochMilliseconds: 100
        )
        let secondEnvelope = try await signedEnvelope(
            value: "two",
            mutationID: "chain-2",
            owner: owner,
            revision: 1,
            headHash: first.journal.headHash
        )
        let second = try await first.journal.appending(
            envelope: secondEnvelope,
            to: first.snapshot,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-test",
            committedAtEpochMilliseconds: 200
        )

        let rebuilt = try second.journal.replay(on: base)
        XCTAssertEqual(try rebuilt.get(keypath: "person.state"), .string("two"))
        XCTAssertEqual(try second.snapshot.get(keypath: "person.state"), .string("two"))
        XCTAssertTrue(try second.journal.verifyReceipts(authority: owner))

        var tampered = second.journal
        tampered.entries[0].metadata["tampered"] = .bool(true)
        XCTAssertThrowsError(try tampered.validateStructure()) { error in
            XCTAssertEqual((error as? EntityAuthorityCommitError)?.code, "journal_corrupt")
        }

        var receiptTampered = second.journal
        receiptTampered.entries[0].receipt.signature = Data([0x00])
        XCTAssertNoThrow(try receiptTampered.validateStructure())
        XCTAssertFalse(try receiptTampered.verifyReceipts(authority: owner))
    }

    func testInterruptedSnapshotWriteRecoversFromPersistedJournalAfterRestart() async throws {
        let owner = try await makeOwner("authority-restart")
        let base: Entity = [
            "person": .object([:]),
            "localOnly": .string("preserved")
        ]
        let envelope = try await signedEnvelope(
            value: "committed-before-snapshot",
            mutationID: "restart-1",
            owner: owner,
            revision: 0,
            headHash: nil
        )
        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: envelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-restart-test",
            committedAtEpochMilliseconds: 100
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-authority-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let journalURL = directory.appendingPathComponent("entity-authority-journal.json")
        let snapshotURL = directory.appendingPathComponent("keypathstorage.json")

        // This is the write-ahead crash window: journal replacement completed,
        // while the snapshot still contains the pre-commit state.
        try encoder.encode(committed.journal).write(to: journalURL, options: [.atomic])
        try encoder.encode(base).write(to: snapshotURL, options: [.atomic])

        let decoder = JSONDecoder()
        let restoredJournal = try decoder.decode(
            EntityAuthorityJournalDocument.self,
            from: Data(contentsOf: journalURL)
        )
        let staleSnapshot = try decoder.decode(Entity.self, from: Data(contentsOf: snapshotURL))

        XCTAssertTrue(try restoredJournal.verifyReceipts(authority: owner))
        let recovered = try restoredJournal.replay(on: staleSnapshot)
        XCTAssertEqual(
            try recovered.get(keypath: "person.state"),
            .string("committed-before-snapshot")
        )
        XCTAssertEqual(try recovered.get(keypath: "localOnly"), .string("preserved"))
    }

    func testReplicaQuorumCountsOnlyAuthorizedUniqueDurableFaultDomains() async throws {
        let vault = await EphemeralIdentityVault().initialize()
        let authorityCandidate = await vault.identity(for: "authority", makeNewIfNotFound: true)
        let replicaACandidate = await vault.identity(for: "replica-a", makeNewIfNotFound: true)
        let replicaBCandidate = await vault.identity(for: "replica-b", makeNewIfNotFound: true)
        let replicaCCandidate = await vault.identity(for: "replica-c", makeNewIfNotFound: true)
        let authority = try XCTUnwrap(authorityCandidate)
        let replicaA = try XCTUnwrap(replicaACandidate)
        let replicaB = try XCTUnwrap(replicaBCandidate)
        let replicaC = try XCTUnwrap(replicaCCandidate)
        let base: Entity = ["person": .object([:])]
        let envelope = try await signedEnvelope(
            value: "replicate-me",
            mutationID: "replication-1",
            owner: authority,
            revision: 0,
            headHash: nil
        )
        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: envelope,
            to: base,
            requester: authority,
            authority: authority,
            authorityCellUUID: "entity-anchor-replication-test",
            committedAtEpochMilliseconds: 100
        )

        let admissionA = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-a",
            replicaID: "replica-a",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-a",
            replica: replicaA,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let admissionB = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-b",
            replicaID: "replica-b",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-b",
            replica: replicaB,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let admissionC = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-c",
            replicaID: "replica-c",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-a",
            replica: replicaC,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let policy = try await EntityAuthorityReplicaQuorumPolicy.signed(
            policyID: "quorum-2",
            partitionID: "entity",
            epoch: 1,
            requiredReplicaAcks: 2,
            admissions: [admissionB, admissionA],
            acceptedDurabilityLevels: [.atomicFileReplaceWithoutPowerLossProof],
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let ackA = try await EntityAuthorityReplicaAcknowledgement.signed(
            receipt: committed.receipt,
            admission: admissionA,
            replica: replicaA,
            durabilityLevel: .atomicFileReplaceWithoutPowerLossProof,
            persistedAtEpochMilliseconds: 200
        )
        let ackB = try await EntityAuthorityReplicaAcknowledgement.signed(
            receipt: committed.receipt,
            admission: admissionB,
            replica: replicaB,
            durabilityLevel: .atomicFileReplaceWithoutPowerLossProof,
            persistedAtEpochMilliseconds: 200
        )

        let duplicateEvaluation = try policy.evaluate(
            receipt: committed.receipt,
            authority: authority,
            admissions: [admissionA, admissionB],
            acknowledgements: [ackA, ackA],
            atEpochMilliseconds: 250
        )
        XCTAssertFalse(duplicateEvaluation.quorumSatisfied)
        XCTAssertEqual(duplicateEvaluation.validReplicaAckCount, 1)
        XCTAssertEqual(duplicateEvaluation.acceptedAcknowledgementHashes.count, 1)
        XCTAssertEqual(duplicateEvaluation.rejectedAcknowledgements.map(\.reason), ["duplicate_ack_id"])

        let satisfied = try policy.evaluate(
            receipt: committed.receipt,
            authority: authority,
            admissions: [admissionA, admissionB],
            acknowledgements: [ackB, ackA],
            atEpochMilliseconds: 250
        )
        XCTAssertTrue(satisfied.quorumSatisfied)
        XCTAssertEqual(satisfied.acceptedReplicaIDs, ["replica-a", "replica-b"])
        XCTAssertEqual(satisfied.acceptedAcknowledgementHashes.count, 2)
        XCTAssertTrue(satisfied.authorityCertificateRequired)

        let certificate = try await EntityAuthorityReplicaQuorumCertificate.signed(
            receipt: committed.receipt,
            policy: policy,
            admissions: [admissionA, admissionB],
            acknowledgements: [ackB, ackA],
            authority: authority,
            certifiedAtEpochMilliseconds: 250
        )
        XCTAssertTrue(certificate.distributedCommit)
        XCTAssertEqual(certificate.replicaAckCount, 2)
        XCTAssertTrue(certificate.verifies(
            receipt: committed.receipt,
            policy: policy,
            evaluation: satisfied,
            authority: authority
        ))
        XCTAssertEqual(
            try EntityAuthorityReplicaQuorumCertificate(value: certificate.valueType()),
            certificate
        )

        var tamperedCertificate = certificate
        tamperedCertificate.replicaAckCount = 1
        XCTAssertFalse(tamperedCertificate.verifies(
            receipt: committed.receipt,
            policy: policy,
            evaluation: satisfied,
            authority: authority
        ))

        do {
            _ = try await EntityAuthorityReplicaQuorumCertificate.signed(
                receipt: committed.receipt,
                policy: policy,
                admissions: [admissionA, admissionB],
                acknowledgements: [ackA, ackA],
                authority: authority,
                certifiedAtEpochMilliseconds: 250
            )
            XCTFail("An unsatisfied quorum must not produce a certificate")
        } catch let error as EntityAuthorityReplicationError {
            XCTAssertEqual(error, .invalidCertificate("quorum_not_satisfied"))
        }

        let transportOnlyAck = try await EntityAuthorityReplicaAcknowledgement.signed(
            receipt: committed.receipt,
            admission: admissionB,
            replica: replicaB,
            durabilityLevel: .transportDeliveryOnly,
            persistedAtEpochMilliseconds: 200
        )
        let transportEvaluation = try policy.evaluate(
            receipt: committed.receipt,
            authority: authority,
            admissions: [admissionA, admissionB],
            acknowledgements: [ackA, transportOnlyAck],
            atEpochMilliseconds: 250
        )
        XCTAssertFalse(transportEvaluation.quorumSatisfied)
        XCTAssertEqual(transportEvaluation.rejectedAcknowledgements.map(\.reason), ["durability_not_accepted"])

        let reboundAdmissionA = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-a",
            replicaID: "replica-c",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-c",
            replica: replicaC,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let reboundAckA = try await EntityAuthorityReplicaAcknowledgement.signed(
            receipt: committed.receipt,
            admission: reboundAdmissionA,
            replica: replicaC,
            durabilityLevel: .atomicFileReplaceWithoutPowerLossProof,
            persistedAtEpochMilliseconds: 200
        )
        let reboundEvaluation = try policy.evaluate(
            receipt: committed.receipt,
            authority: authority,
            admissions: [reboundAdmissionA, admissionB],
            acknowledgements: [reboundAckA, ackB],
            atEpochMilliseconds: 250
        )
        XCTAssertFalse(reboundEvaluation.quorumSatisfied)
        XCTAssertEqual(reboundEvaluation.validReplicaAckCount, 1)
        XCTAssertEqual(reboundEvaluation.rejectedAcknowledgements.map(\.reason), ["admission_not_authorized"])

        let sameDomainPolicy = try await EntityAuthorityReplicaQuorumPolicy.signed(
            policyID: "quorum-distinct-domains",
            partitionID: "entity",
            epoch: 1,
            requiredReplicaAcks: 2,
            admissions: [admissionA, admissionC],
            acceptedDurabilityLevels: [.atomicFileReplaceWithoutPowerLossProof],
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let ackC = try await EntityAuthorityReplicaAcknowledgement.signed(
            receipt: committed.receipt,
            admission: admissionC,
            replica: replicaC,
            durabilityLevel: .atomicFileReplaceWithoutPowerLossProof,
            persistedAtEpochMilliseconds: 200
        )
        let sameDomainEvaluation = try sameDomainPolicy.evaluate(
            receipt: committed.receipt,
            authority: authority,
            admissions: [admissionA, admissionC],
            acknowledgements: [ackA, ackC],
            atEpochMilliseconds: 250
        )
        XCTAssertFalse(sameDomainEvaluation.quorumSatisfied)
        XCTAssertEqual(sameDomainEvaluation.validReplicaAckCount, 1)
        XCTAssertEqual(sameDomainEvaluation.rejectedAcknowledgements.map(\.reason), ["duplicate_fault_domain"])

        let encoded = try JSONEncoder().encode(satisfied)
        XCTAssertEqual(
            try JSONDecoder().decode(EntityAuthorityReplicaQuorumEvaluation.self, from: encoded),
            satisfied
        )
    }

    func testReplayRangeIsCompleteOnlyWhenContiguousAndReceiptVerified() async throws {
        let owner = try await makeOwner("authority-range")
        let base: Entity = ["person": .object([:])]
        let firstEnvelope = try await signedEnvelope(
            value: "one",
            mutationID: "range-1",
            owner: owner,
            revision: 0,
            headHash: nil
        )
        let first = try await EntityAuthorityJournalDocument().appending(
            envelope: firstEnvelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-range-test",
            committedAtEpochMilliseconds: 100
        )
        let secondEnvelope = try await signedEnvelope(
            value: "two",
            mutationID: "range-2",
            owner: owner,
            revision: 1,
            headHash: first.journal.headHash
        )
        let second = try await first.journal.appending(
            envelope: secondEnvelope,
            to: first.snapshot,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-range-test",
            committedAtEpochMilliseconds: 200
        )

        let completeRequest = EntityAuthorityReplayRangeRequest(
            partitionID: "entity",
            epoch: 1,
            startRevision: 1,
            endRevision: 2,
            expectedPreviousHash: nil
        )
        let complete = try second.journal.replayRange(for: completeRequest)
        XCTAssertEqual(complete.status, .complete)
        XCTAssertTrue(complete.verifies(for: completeRequest, authority: owner))
        let rebuilt = try complete.applying(to: base, for: completeRequest, authority: owner)
        XCTAssertEqual(try rebuilt.get(keypath: "person.state"), .string("two"))

        let incompleteRequest = EntityAuthorityReplayRangeRequest(
            partitionID: "entity",
            epoch: 1,
            startRevision: 1,
            endRevision: 3,
            expectedPreviousHash: nil
        )
        let incomplete = try second.journal.replayRange(for: incompleteRequest)
        XCTAssertEqual(incomplete.status, .incomplete)
        XCTAssertEqual(incomplete.nextMissingRevision, 3)
        XCTAssertThrowsError(
            try incomplete.applying(to: base, for: incompleteRequest, authority: owner)
        )

        let conflictRequest = EntityAuthorityReplayRangeRequest(
            partitionID: "entity",
            epoch: 1,
            startRevision: 2,
            endRevision: 2,
            expectedPreviousHash: "not-the-revision-one-hash"
        )
        let conflict = try second.journal.replayRange(for: conflictRequest)
        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertFalse(conflict.verifies(for: conflictRequest, authority: owner))

        var tampered = complete
        tampered.entries[0].metadata["tampered"] = .bool(true)
        XCTAssertFalse(tampered.verifies(for: completeRequest, authority: owner))

        let wireData = try JSONEncoder().encode(complete)
        XCTAssertEqual(
            try JSONDecoder().decode(EntityAuthorityReplayRangeResponse.self, from: wireData),
            complete
        )

        let oversizedRequest = EntityAuthorityReplayRangeRequest(
            partitionID: "entity",
            epoch: 1,
            startRevision: 1,
            endRevision: EntityAuthorityReplayRangeRequest.maximumEntryCount + 1,
            expectedPreviousHash: nil
        )
        XCTAssertThrowsError(try oversizedRequest.validate())
    }

    private func signedEnvelope(
        value: String,
        mutationID: String,
        owner: Identity,
        revision: Int,
        headHash: String?
    ) async throws -> EntityBatchPersistEnvelope {
        var envelope = EntityBatchPersistEnvelope(
            schema: "test.entity.v1",
            mutations: [EntityBatchPersistMutation(keypath: "person.state", value: .string(value))]
        )
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: mutationID,
            epoch: 1,
            expectedRevision: revision,
            expectedPreviousHash: headHash,
            requester: owner,
            purposeRef: "purpose://access.audit.privacy"
        )
        return envelope
    }

    private func makeOwner(_ domain: String) async throws -> Identity {
        let vault = await EphemeralIdentityVault().initialize()
        let identity = await vault.identity(for: domain, makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }
}
