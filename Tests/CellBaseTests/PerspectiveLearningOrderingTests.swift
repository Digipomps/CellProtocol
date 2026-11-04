// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase

final class PerspectiveLearningOrderingTests: XCTestCase {
    private let purpose = "purpose://ordering"
    private let interest = RelationalNode(type: .interest, id: "interest://work")

    private func preference(_ id: String, at time: Double, weight: Double,
                            target: RelationalNode? = nil,
                            relation: RelationalEdgeRelationType = .purposeInterest) throws -> RelationalLearningEventEnvelope {
        try .from(RelationalExplicitPreferenceEvent(eventId: id, timestamp: time,
            purposeId: purpose, relationType: relation, targetNode: target ?? interest,
            preferenceWeight: weight))
    }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testEqualTimeExplicitChoicesConvergeUsingOriginalSourceID() async throws {
        let a = try preference("a", at: 200, weight: 0.9)
        let z = try preference("z", at: 200, weight: 0.2)
        let first = RelationalLearningEngine(), second = RelationalLearningEngine()
        for event in [a, z] { _ = try await first.applyEnvelopeTransaction(event) }
        for event in [z, a] { _ = try await second.applyEnvelopeTransaction(event) }
        let firstEdges = await first.edges(), secondEdges = await second.edges()
        XCTAssertEqual(try canonical(firstEdges), try canonical(secondEdges))
        XCTAssertEqual(try XCTUnwrap(firstEdges.first).weightStored, 0.2, accuracy: 1e-12)
        let replay = RelationalLearningEngine()
        _ = try await replay.replayTransaction(events: [z, a], resetFirst: true)
        let replayEdges = await replay.edges()
        XCTAssertEqual(try canonical(firstEdges), try canonical(replayEdges))
    }

    func testOrderingIsScopedToCompleteEdgeIncludingTargetType() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("new", at: 500, weight: 0.2))
        let other = RelationalNode(type: .interest, id: "interest://other")
        _ = try await engine.applyEnvelopeTransaction(preference("other", at: 50, weight: 0.8, target: other))
        let entity = RelationalNode(type: .entityRepresentation, id: interest.id)
        _ = try await engine.applyEnvelopeTransaction(preference("entity", at: 30, weight: 0.7, target: entity, relation: .purposeEntity))
        let edges = await engine.edges()
        XCTAssertEqual(edges.count, 3)
        XCTAssertEqual(try XCTUnwrap(edges.first(where: { $0.toNode == other })).lastReinforcedAt, 50)
        XCTAssertEqual(try XCTUnwrap(edges.first(where: { $0.toNode == entity })).lastReinforcedAt, 30)
    }

    func testUniqueStaleCorrectionIsDurablyConsumedWithoutEmittingWeightChange() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("new", at: 200, weight: 0.2))
        let old = try preference("old", at: 100, weight: 0.9)
        let result = try await engine.applyEnvelopeTransaction(old)
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.ignoredReason, "stale_event")
        XCTAssertEqual(result.sequence, 2)
        XCTAssertTrue(result.weightUpdates.isEmpty)
        let journal = await engine.journalSnapshot()
        let restored = RelationalLearningEngine()
        try await restored.restore(from: journal)
        let edges = await restored.edges()
        XCTAssertEqual(try XCTUnwrap(edges.first).weightStored, 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(edges.first).lastReinforcedAt, 200)
        let duplicate = try await restored.applyEnvelopeTransaction(old)
        XCTAssertFalse(duplicate.applied)
        XCTAssertNil(duplicate.sequence)
        let after = await restored.journalSnapshot()
        XCTAssertEqual(try canonical(journal), try canonical(after))
    }

    func testDirectWeightUpdateCannotBypassExplicitCorrectionOrdering() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("new", at: 200, weight: 0.2))
        let event = RelationalExplicitPreferenceEvent(eventId: "old-direct", timestamp: 100,
            purposeId: purpose, relationType: .purposeInterest, targetNode: interest, preferenceWeight: 0.9)
        let update = await engine.deriveExplicitPreferenceWeightUpdate(event)
        let applied = await engine.applyWeightUpdateEvent(update)
        XCTAssertFalse(applied)
        let edges = await engine.edges()
        XCTAssertEqual(try XCTUnwrap(edges.first).weightStored, 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(edges.first).lastReinforcedAt, 200)
    }

    func testNewerOutcomeStillLearnsButOlderOutcomeDoesNotRollClockBack() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("choice", at: 200, weight: 0.2))
        let new = RelationalPurposeLifecycleEvent(eventId: "success-new", timestamp: 210, status: .succeeded,
            purposeId: purpose, activeInterestRefs: [interest.id], contextConfidence: 1)
        let newResult = try await engine.applyEnvelopeTransaction(.from(new))
        XCTAssertEqual(newResult.weightUpdates.count, 1)
        let before = await engine.edges()
        XCTAssertGreaterThan(try XCTUnwrap(before.first).weightStored, 0.2)
        let old = RelationalPurposeLifecycleEvent(eventId: "failure-old", timestamp: 205, status: .failed,
            purposeId: purpose, activeInterestRefs: [interest.id], contextConfidence: 1)
        let oldResult = try await engine.applyEnvelopeTransaction(.from(old))
        XCTAssertEqual(oldResult.weightUpdates.count, 1, "A valid outcome after the correction must not be lost")
        let after = await engine.edges()
        XCTAssertLessThan(try XCTUnwrap(after.first).weightStored, try XCTUnwrap(before.first).weightStored)
        XCTAssertEqual(try XCTUnwrap(after.first).lastReinforcedAt, 210)
        let beforeCorrection = RelationalPurposeLifecycleEvent(eventId: "failure-before-choice", timestamp: 190, status: .failed,
            purposeId: purpose, activeInterestRefs: [interest.id], contextConfidence: 1)
        let staleResult = try await engine.applyEnvelopeTransaction(.from(beforeCorrection))
        XCTAssertTrue(staleResult.weightUpdates.isEmpty)
        let protected = await engine.edges()
        XCTAssertEqual(try canonical(after), try canonical(protected))
    }

    func testGeneratedWeightEchoDoesNotLearnOrJournalAgain() async throws {
        let engine = RelationalLearningEngine()
        let first = try await engine.applyEnvelopeTransaction(preference("source", at: 200, weight: 0.8))
        let echo = try await engine.applyEnvelopeTransaction(.from(try XCTUnwrap(first.weightUpdates.first)))
        XCTAssertFalse(echo.applied)
        XCTAssertNil(echo.sequence)
        let journal = await engine.journalSnapshot()
        XCTAssertEqual(journal.revision, 1)
    }

    func testConflictingEventIdentityRejectsBeforeStateOrReplayReset() async throws {
        let engine = RelationalLearningEngine()
        let original = try preference("same-id", at: 200, weight: 0.2)
        let conflict = try preference("same-id", at: 200, weight: 0.9)
        _ = try await engine.applyEnvelopeTransaction(original)
        let before = await engine.journalSnapshot()
        do {
            _ = try await engine.applyEnvelopeTransaction(conflict)
            XCTFail("contradictory retry must be rejected")
        } catch RelationalLearningError.invalidEvent { }
        do {
            _ = try await engine.replayTransaction(events: [original, conflict], resetFirst: true)
            XCTFail("conflicting replay must not reset the existing state")
        } catch RelationalLearningError.invalidEvent { }
        let after = await engine.journalSnapshot()
        XCTAssertEqual(try canonical(before), try canonical(after))
    }

    func testV1RestorePreservesOriginalSemanticsAndMigratesOnceBeforeNewRecords() async throws {
        let oldJournal = try RelationalLearningPersistedJournal(version: 1, revision: 2, records: [
            .init(sequence: 1, envelope: preference("new-legacy", at: 200, weight: 0.2)),
            .init(sequence: 2, envelope: preference("old-legacy", at: 100, weight: 0.9))
        ])
        let engine = RelationalLearningEngine()
        try await engine.restore(from: oldJournal)
        let oldEdges = await engine.edges(), roundtrip = await engine.journalSnapshot()
        XCTAssertEqual(try XCTUnwrap(oldEdges.first).weightStored, 0.9, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(oldEdges.first).lastReinforcedAt, 100)
        XCTAssertEqual(try canonical(roundtrip), try canonical(oldJournal))
        let middle = try await engine.applyEnvelopeTransaction(preference("middle", at: 150, weight: 0.6))
        XCTAssertFalse(middle.applied)
        XCTAssertEqual(middle.sequence, 3)
        let migrated = await engine.journalSnapshot()
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.legacyRecordCount, 2)
        let restored = RelationalLearningEngine()
        try await restored.restore(from: migrated)
        let restoredEdges = await restored.edges()
        XCTAssertEqual(try canonical(oldEdges), try canonical(restoredEdges))
        _ = try await restored.applyEnvelopeTransaction(preference("fresh", at: 250, weight: 0.1))
        let freshEdges = await restored.edges()
        XCTAssertEqual(try XCTUnwrap(freshEdges.first).weightStored, 0.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(freshEdges.first).lastReinforcedAt, 250)
    }

    func testInvalidMigrationPrefixIsRejectedBeforeReset() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("valid", at: 200, weight: 0.2))
        let before = await engine.journalSnapshot()
        for invalid in [RelationalLearningPersistedJournal(version: 2, legacyRecordCount: 1),
                        RelationalLearningPersistedJournal(version: 1, legacyRecordCount: 0),
                        RelationalLearningPersistedJournal(version: 99)] {
            do { try await engine.restore(from: invalid); XCTFail("invalid migration must fail") }
            catch RelationalLearningError.invalidJournal { }
        }
        let after = await engine.journalSnapshot()
        XCTAssertEqual(try canonical(before), try canonical(after))
    }
    func testMalformedLegacyJournalRollsBackEveryExistingState() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(preference("existing", at: 500, weight: 0.3))
        let before = await engine.journalSnapshot(), beforeEdges = await engine.edges()
        let duplicate = try preference("duplicate", at: 100, weight: 0.9)
        let malformed = RelationalLearningPersistedJournal(version: 1, revision: 2, records: [
            .init(sequence: 1, envelope: duplicate), .init(sequence: 2, envelope: duplicate)
        ])
        do { try await engine.restore(from: malformed); XCTFail("unrestorable journal must fail") }
        catch RelationalLearningError.invalidJournal { }
        let after = await engine.journalSnapshot(), afterEdges = await engine.edges()
        XCTAssertEqual(try canonical(before), try canonical(after))
        XCTAssertEqual(try canonical(beforeEdges), try canonical(afterEdges))
        let duplicateExisting = try await engine.applyEnvelopeTransaction(preference("existing", at: 500, weight: 0.3))
        XCTAssertFalse(duplicateExisting.applied)
        XCTAssertNil(duplicateExisting.sequence)
    }

}
