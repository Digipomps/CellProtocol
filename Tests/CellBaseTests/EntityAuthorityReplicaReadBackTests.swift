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

    private func makeJournal(authority: Identity, values: [ValueType]) async throws -> EntityAuthorityJournalDocument {
        var journal = EntityAuthorityJournalDocument()
        var snapshot: Entity = ["person": .object([:])]
        for (index, value) in values.enumerated() {
            var envelope = EntityBatchPersistEnvelope(
                schema: "test.replica.v1",
                mutations: [EntityBatchPersistMutation(keypath: "person.state", value: value)]
            )
            envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
                envelope: envelope,
                mutationID: "replica-readback-\(index + 1)",
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
