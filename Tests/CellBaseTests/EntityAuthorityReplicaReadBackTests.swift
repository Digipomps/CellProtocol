// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// The replica store verifies what it persisted by reading it back. A JSON round
/// trip reads `.data` back as `.string`, `.number` as `.integer` and a
/// whole-number `.float` as `.integer`, so a structural comparison failed with
/// `persistenceVerificationFailed` although the bytes were identical. The check
/// now compares canonical bytes.
final class EntityAuthorityReplicaReadBackTests: XCTestCase {

    private struct Setup {
        let authority: Identity
        let replica: Identity
        let admission: EntityAuthorityReplicaAdmission
        let persistence: AtomicFileEntityAuthorityReplicaPersistence
        let directory: URL

        func store() -> EntityAuthorityReplicaStore {
            EntityAuthorityReplicaStore(persistence: persistence, admission: admission, authority: authority, replica: replica)
        }
    }

    /// Values whose case changes in a JSON round trip, in an object, a list and a nested object.
    private static let caseChangingValues: [ValueType] = [
        .object([
            "blob": .data(Data([0x00, 0xFF, 0x10])),
            "count": .number(7),
            "whole": .float(2.0),
            "items": .list([.data(Data("x".utf8)), .number(1), .object(["n": .number(2)])]),
        ]),
        .list([.number(3), .data(Data([0x01]))]),
    ]

    private func makeSetup(_ suffix: String) async throws -> Setup {
        let authority = try await makeIdentity("readback-authority-\(suffix)")
        let replica = try await makeIdentity("readback-storage-\(suffix)")
        let admission = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-readback",
            replicaID: "replica-readback",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-readback",
            replica: replica,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 10_000
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-authority-readback-\(UUID().uuidString)", isDirectory: true)
        return Setup(authority: authority, replica: replica, admission: admission,
                     persistence: AtomicFileEntityAuthorityReplicaPersistence(fileURL: directory.appendingPathComponent("replica.json")),
                     directory: directory)
    }

    private func rangeRequest(for journal: EntityAuthorityJournalDocument, through revision: Int) -> EntityAuthorityReplayRangeRequest {
        EntityAuthorityReplayRangeRequest(partitionID: journal.partitionID, epoch: journal.epoch,
                                          startRevision: 1, endRevision: revision, expectedPreviousHash: nil)
    }

    /// A retry of identical entries is idempotent although the stored copy was read back from JSON.
    func testRetryOfIdenticalEntriesWithCaseChangingValuesIsIdempotent() async throws {
        let setup = try await makeSetup("retry")
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let journal = try await makeJournal(authority: setup.authority, values: Self.caseChangingValues)
        let request = rangeRequest(for: journal, through: Self.caseChangingValues.count)
        let response = try journal.replayRange(for: request)

        _ = try await setup.store().persist(response: response, for: request, persistedAtEpochMilliseconds: 500)
        // A new store instance reads the journal back from the file before merging.
        let retry = try await setup.store().persist(response: response, for: request, persistedAtEpochMilliseconds: 600)
        XCTAssertEqual(retry.count, Self.caseChangingValues.count)
        let storedCandidate = try await setup.store().storedDocument()
        let stored = try XCTUnwrap(storedCandidate)
        XCTAssertEqual(stored.persistedAtEpochMilliseconds, 600)
        XCTAssertEqual(try EntityAuthorityCanonical.data(for: stored.journal), try EntityAuthorityCanonical.data(for: journal))
    }

    /// A different entry at a stored revision is still a conflict.
    func testDivergentEntryIsStillAConflict() async throws {
        let setup = try await makeSetup("conflict")
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let journal = try await makeJournal(authority: setup.authority, values: Self.caseChangingValues)
        let request = rangeRequest(for: journal, through: 1)
        _ = try await setup.store().persist(response: try journal.replayRange(for: request), for: request, persistedAtEpochMilliseconds: 500)

        let other = try await makeJournal(authority: setup.authority,
                                          values: [.object(["blob": .data(Data([0x02])), "count": .number(8)])],
                                          mutationPrefix: "replica-readback-other")
        let otherRequest = rangeRequest(for: other, through: 1)
        do {
            _ = try await setup.store().persist(response: try other.replayRange(for: otherRequest), for: otherRequest,
                                                persistedAtEpochMilliseconds: 600)
            XCTFail("expected journalConflict")
        } catch let error as EntityAuthorityReplicaStoreError {
            XCTAssertEqual(error, .journalConflict("divergent_revision_1"))
        }
    }

    func testReadBackAcceptsValuesWhoseCaseChangesInJSON() async throws {
        let authority = try await makeIdentity("readback-authority")
        let replica = try await makeIdentity("readback-storage")
        let admission = try await EntityAuthorityReplicaAdmission.signed(
            admissionID: "admission-readback",
            replicaID: "replica-readback",
            partitionID: "entity",
            epoch: 1,
            faultDomainID: "fault-domain-readback",
            replica: replica,
            authority: authority,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 10_000
        )
        let values: [ValueType] = [
            .object([
                "blob": .data(Data([0x00, 0xFF, 0x10])),
                "count": .number(7),
                "whole": .float(2.0),
                "items": .list([.data(Data("x".utf8)), .number(1), .object(["n": .number(2)])]),
            ]),
            .list([.number(3), .data(Data([0x01]))]),
        ]
        let journal = try await makeJournal(authority: authority, values: values)
        let request = EntityAuthorityReplayRangeRequest(
            partitionID: journal.partitionID,
            epoch: journal.epoch,
            startRevision: 1,
            endRevision: values.count,
            expectedPreviousHash: nil
        )
        let response = try journal.replayRange(for: request)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-authority-readback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AtomicFileEntityAuthorityReplicaPersistence(fileURL: directory.appendingPathComponent("replica.json"))
        let store = EntityAuthorityReplicaStore(persistence: persistence, admission: admission, authority: authority, replica: replica)

        let acknowledgements = try await store.persist(response: response, for: request, persistedAtEpochMilliseconds: 500)
        XCTAssertEqual(acknowledgements.count, values.count)

        // A restarted store reads the same journal bytes back.
        let restarted = EntityAuthorityReplicaStore(persistence: persistence, admission: admission, authority: authority, replica: replica)
        let storedCandidate = try await restarted.storedDocument()
        let stored = try XCTUnwrap(storedCandidate)
        XCTAssertEqual(try EntityAuthorityCanonical.data(for: stored.journal), try EntityAuthorityCanonical.data(for: journal))
    }

    // MARK: - Fixture

    private func makeJournal(authority: Identity, values: [ValueType],
                             mutationPrefix: String = "replica-readback") async throws -> EntityAuthorityJournalDocument {
        var journal = EntityAuthorityJournalDocument()
        var snapshot: Entity = ["person": .object([:])]
        for (index, value) in values.enumerated() {
            var envelope = EntityBatchPersistEnvelope(
                schema: "test.replica.v1",
                mutations: [EntityBatchPersistMutation(keypath: "person.state", value: value)]
            )
            envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
                envelope: envelope,
                mutationID: "\(mutationPrefix)-\(index + 1)",
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

    private func makeIdentity(_ domain: String) async throws -> Identity {
        let vault = await EphemeralIdentityVault().initialize()
        let identity = await vault.identity(for: domain, makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }
}
