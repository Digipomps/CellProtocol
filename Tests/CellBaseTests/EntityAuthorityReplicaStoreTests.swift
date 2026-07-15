// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class EntityAuthorityReplicaStoreTests: XCTestCase {
    func testReplicaPersistsReadBackBeforeAcknowledgingAndRecoversAfterRestart() async throws {
        let fixture = try await makeFixture(entryCount: 2, suffix: "restart")
        let request = replayRequest(for: fixture.journal, startRevision: 1, endRevision: 2)
        let response = try fixture.journal.replayRange(for: request)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-authority-replica-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("replica.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = AtomicFileEntityAuthorityReplicaPersistence(fileURL: fileURL)
        let store = EntityAuthorityReplicaStore(
            persistence: persistence,
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )
        let acknowledgements = try await store.persist(
            response: response,
            for: request,
            persistedAtEpochMilliseconds: 500
        )

        XCTAssertEqual(acknowledgements.count, 2)
        for (acknowledgement, entry) in zip(acknowledgements, response.entries) {
            XCTAssertTrue(acknowledgement.verifies(
                receipt: entry.receipt,
                admission: fixture.admission,
                atEpochMilliseconds: 501
            ))
            XCTAssertEqual(
                acknowledgement.durabilityLevel,
                EntityAuthorityReplicaDurabilityLevel.atomicFileReplaceWithoutPowerLossProof.rawValue
            )
        }
        let stored = try await store.storedDocument()
        XCTAssertEqual(stored?.revision, 2)

        let restarted = EntityAuthorityReplicaStore(
            persistence: persistence,
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )
        let restartedDocument = try await restarted.storedDocument()
        XCTAssertEqual(restartedDocument?.journal, fixture.journal)

        let retryAcknowledgements = try await restarted.persist(
            response: response,
            for: request,
            persistedAtEpochMilliseconds: 600
        )
        XCTAssertEqual(retryAcknowledgements.count, 2)
        let retriedDocument = try await restarted.storedDocument()
        XCTAssertEqual(retriedDocument?.journal.entries.count, 2)
        XCTAssertEqual(retriedDocument?.persistedAtEpochMilliseconds, 600)
    }

    func testReplicaDoesNotAcknowledgeFailedOrLyingPersistence() async throws {
        let fixture = try await makeFixture(entryCount: 1, suffix: "failure")
        let request = replayRequest(for: fixture.journal, startRevision: 1, endRevision: 1)
        let response = try fixture.journal.replayRange(for: request)

        for mode in [TestReplicaPersistence.Mode.failStore, .discardStore] {
            let persistence = TestReplicaPersistence(mode: mode)
            let store = EntityAuthorityReplicaStore(
                persistence: persistence,
                admission: fixture.admission,
                authority: fixture.authority,
                replica: fixture.replica
            )
            do {
                _ = try await store.persist(
                    response: response,
                    for: request,
                    persistedAtEpochMilliseconds: 500
                )
                XCTFail("Persistence without verified read-back must never return an acknowledgement")
            } catch let error as EntityAuthorityReplicaStoreError {
                switch mode {
                case .failStore:
                    XCTAssertEqual(error, .persistenceFailure)
                case .discardStore:
                    XCTAssertEqual(error, .persistenceVerificationFailed)
                case .normal:
                    XCTFail("Normal persistence was not under test")
                }
            }
            XCTAssertNil(try persistence.load())
        }
    }

    func testReplicaRejectsIncompleteTamperedAndTransportOnlyRanges() async throws {
        let fixture = try await makeFixture(entryCount: 2, suffix: "reject")
        let incompleteRequest = EntityAuthorityReplayRangeRequest(
            partitionID: "entity",
            epoch: 1,
            startRevision: 1,
            endRevision: 3,
            expectedPreviousHash: nil
        )
        let incomplete = try fixture.journal.replayRange(for: incompleteRequest)
        let persistence = TestReplicaPersistence(mode: .normal)
        let store = EntityAuthorityReplicaStore(
            persistence: persistence,
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )

        await assertStoreError(.replayRejected) {
            _ = try await store.persist(
                response: incomplete,
                for: incompleteRequest,
                persistedAtEpochMilliseconds: 500
            )
        }

        let completeRequest = replayRequest(for: fixture.journal, startRevision: 1, endRevision: 2)
        var tampered = try fixture.journal.replayRange(for: completeRequest)
        tampered.entries[0].metadata["tampered"] = .bool(true)
        await assertStoreError(.replayRejected) {
            _ = try await store.persist(
                response: tampered,
                for: completeRequest,
                persistedAtEpochMilliseconds: 500
            )
        }

        let transportStore = EntityAuthorityReplicaStore(
            persistence: TestReplicaPersistence(mode: .normal, durabilityLevel: .transportDeliveryOnly),
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )
        await assertStoreError(.unsupportedDurability) {
            _ = try await transportStore.persist(
                response: try fixture.journal.replayRange(for: completeRequest),
                for: completeRequest,
                persistedAtEpochMilliseconds: 500
            )
        }
        XCTAssertNil(try persistence.load())
    }

    func testReplicaRejectsMissingAndDivergentHistory() async throws {
        let fixture = try await makeFixture(entryCount: 2, suffix: "conflict")

        let gapRequest = replayRequest(for: fixture.journal, startRevision: 2, endRevision: 2)
        let gapResponse = try fixture.journal.replayRange(for: gapRequest)
        let gapStore = EntityAuthorityReplicaStore(
            persistence: TestReplicaPersistence(mode: .normal),
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )
        await assertStoreError(.journalConflict("missing_revision_1")) {
            _ = try await gapStore.persist(
                response: gapResponse,
                for: gapRequest,
                persistedAtEpochMilliseconds: 500
            )
        }

        let persistence = TestReplicaPersistence(mode: .normal)
        let store = EntityAuthorityReplicaStore(
            persistence: persistence,
            admission: fixture.admission,
            authority: fixture.authority,
            replica: fixture.replica
        )
        let originalRequest = replayRequest(for: fixture.journal, startRevision: 1, endRevision: 1)
        _ = try await store.persist(
            response: fixture.journal.replayRange(for: originalRequest),
            for: originalRequest,
            persistedAtEpochMilliseconds: 500
        )

        let alternateJournal = try await makeJournal(
            authority: fixture.authority,
            values: ["alternate"],
            suffix: "conflict-alternate"
        )
        let alternateRequest = replayRequest(for: alternateJournal, startRevision: 1, endRevision: 1)
        await assertStoreError(.journalConflict("divergent_revision_1")) {
            _ = try await store.persist(
                response: try alternateJournal.replayRange(for: alternateRequest),
                for: alternateRequest,
                persistedAtEpochMilliseconds: 600
            )
        }
        let storedAfterConflict = try await store.storedDocument()
        XCTAssertEqual(storedAfterConflict?.journal.entries.first, fixture.journal.entries.first)
    }

    private func makeFixture(entryCount: Int, suffix: String) async throws -> ReplicaFixture {
        let authority = try await makeIdentity("replica-authority-\(suffix)")
        let replica = try await makeIdentity("replica-storage-\(suffix)")
        let admission = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-\(suffix)",
            replicaID: "replica-\(suffix)",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-\(suffix)",
            replica: replica,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 10_000
        )
        let values = (1...entryCount).map { "value-\($0)" }
        return ReplicaFixture(
            authority: authority,
            replica: replica,
            admission: admission,
            journal: try await makeJournal(authority: authority, values: values, suffix: suffix)
        )
    }

    private func makeJournal(
        authority: Identity,
        values: [String],
        suffix: String
    ) async throws -> EntityAuthorityJournalDocument {
        var journal = EntityAuthorityJournalDocument()
        var snapshot: Entity = ["person": .object([:])]
        for (index, value) in values.enumerated() {
            var envelope = EntityBatchPersistEnvelope(
                schema: "test.replica.v1",
                mutations: [
                    EntityBatchPersistMutation(keypath: "person.state", value: .string(value))
                ]
            )
            envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
                envelope: envelope,
                mutationID: "replica-\(suffix)-\(index + 1)",
                epoch: 1,
                expectedRevision: journal.revision,
                expectedPreviousHash: journal.headHash,
                requester: authority,
                purposeRef: "purpose://access.audit.privacy"
            )
            let outcome = try await journal.appending(
                envelope: envelope,
                to: snapshot,
                requester: authority,
                authority: authority,
                authorityCellUUID: "entity-anchor-replica-test",
                committedAtEpochMilliseconds: 110 + index
            )
            journal = outcome.journal
            snapshot = outcome.snapshot
        }
        return journal
    }

    private func replayRequest(
        for journal: EntityAuthorityJournalDocument,
        startRevision: Int,
        endRevision: Int
    ) -> EntityAuthorityReplayRangeRequest {
        EntityAuthorityReplayRangeRequest(
            partitionID: journal.partitionID,
            epoch: journal.epoch,
            startRevision: startRevision,
            endRevision: endRevision,
            expectedPreviousHash: startRevision == 1 ? nil : journal.entries[startRevision - 2].entryHash
        )
    }

    private func makeIdentity(_ domain: String) async throws -> Identity {
        let vault = await EphemeralIdentityVault().initialize()
        let identity = await vault.identity(for: domain, makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }

    private func assertStoreError(
        _ expected: EntityAuthorityReplicaStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected replica store error \(expected)")
        } catch let error as EntityAuthorityReplicaStoreError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct ReplicaFixture {
    let authority: Identity
    let replica: Identity
    let admission: EntityAuthorityReplicaAdmission
    let journal: EntityAuthorityJournalDocument
}

private final class TestReplicaPersistence: EntityAuthorityReplicaPersistence, @unchecked Sendable {
    enum Mode {
        case normal
        case failStore
        case discardStore
    }

    enum Failure: Error {
        case intentional
    }

    let durabilityLevel: EntityAuthorityReplicaDurabilityLevel
    private let mode: Mode
    private let lock = NSLock()
    private var data: Data?

    init(
        mode: Mode,
        durabilityLevel: EntityAuthorityReplicaDurabilityLevel = .atomicFileReplaceWithoutPowerLossProof
    ) {
        self.mode = mode
        self.durabilityLevel = durabilityLevel
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func store(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .normal:
            self.data = data
        case .failStore:
            throw Failure.intentional
        case .discardStore:
            break
        }
    }
}
