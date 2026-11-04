// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase

final class RelationalUserFeedbackTests: XCTestCase {
    private let target = RelationalConfigurationReference(configurationUUID: "12345678-1234-4234-8234-123456789001", sourceCellEndpoint: "cell:///Synthetic")
    private let blocks = [RelationalContextBlockSignal(domain: "location", blockId: "home"),
                          RelationalContextBlockSignal(domain: "time", blockId: "morning"),
                          RelationalContextBlockSignal(domain: "company", blockId: "family")]
    private func event(_ id: String, _ kind: RelationalUserFeedbackKind, revision: UInt64, at: Double = 100) -> RelationalUserFeedbackEvent {
        .init(eventId: id, timestamp: at, expectedJournalRevision: revision, sessionId: "session", episodeId: id,
              purposeId: "purpose://family", kind: kind,
              configuration: kind == .purposeChoice || kind == .purposeCorrection ? nil : target,
              contextBlocks: kind == .purposeChoice || kind == .purposeCorrection ? blocks : [])
    }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func testRealIncrementalTrainingSeparatesPurposeFromConfigurationUtility() async throws {
        let engine = RelationalLearningEngine()
        for index in 0..<30 {
            let revision = await engine.journalSnapshot().revision
            _ = try await engine.applyEnvelopeTransaction(.from(event("choice-\(index)", .purposeChoice, revision: revision, at: 100 + Double(index))))
        }
        let purposeScores = await engine.scorePurposes(contextSnapshot: .init(activeContextBlocks: blocks), at: 130)
        XCTAssertGreaterThan(try XCTUnwrap(purposeScores.first).score, 0.9)
        let noUtility = await engine.scoreConfigurations(purposeId: "purpose://family", at: 130)
        XCTAssertTrue(noUtility.isEmpty, "Opening/choosing a purpose is not evidence of surface utility")
        let before = await engine.edges().filter { $0.relationType == .purposeContextBlock }
        for index in 0..<35 {
            let revision = await engine.journalSnapshot().revision
            _ = try await engine.applyEnvelopeTransaction(.from(event("outcome-\(index)", .confirmedOutcome, revision: revision, at: 140 + Double(index))))
        }
        let after = await engine.edges().filter { $0.relationType == .purposeContextBlock }
        XCTAssertEqual(try canonical(before), try canonical(after))
        let utility = await engine.scoreConfigurations(purposeId: "purpose://family", at: 175)
        XCTAssertGreaterThan(try XCTUnwrap(utility.first).score, 0.9)
        XCTAssertEqual(utility.first?.configuration, target)
    }
    func testChosenSurfaceDoesNotPretendThePurposeWasSolved() async throws {
        let engine = RelationalLearningEngine()
        let result = try await engine.applyEnvelopeTransaction(.from(event("open", .configurationChoice, revision: 0)))
        XCTAssertTrue(result.applied); XCTAssertTrue(result.weightUpdates.isEmpty)
        let edges = await engine.edges(); XCTAssertTrue(edges.isEmpty)
    }
    func testCorrectionsHaveNegativeValenceAndExplicitOrderingAuthority() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(.from(event("choice", .purposeChoice, revision: 0)))
        let before = await engine.edges()
        let result = try await engine.applyEnvelopeTransaction(.from(event("wrong-purpose", .purposeCorrection, revision: 1, at: 101)))
        XCTAssertEqual(result.weightUpdates.count, 3)
        XCTAssertTrue(result.weightUpdates.allSatisfy { $0.outcome == .failure && $0.sourceFeedbackKind == .purposeCorrection && $0.sourceFeedbackRevision == 2 })
        let after = await engine.edges()
        for (a,b) in zip(before, after) { XCTAssertLessThan(b.weightStored, a.weightStored) }
    }
    func testWrongSurfaceDoesNotPenalizeCorrectPurpose() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(.from(event("choice", .purposeChoice, revision: 0)))
        _ = try await engine.applyEnvelopeTransaction(.from(event("solved", .confirmedOutcome, revision: 1, at: 101)))
        let before = await engine.edges()
        _ = try await engine.applyEnvelopeTransaction(.from(event("wrong-surface", .configurationCorrection, revision: 2, at: 102)))
        let after = await engine.edges()
        XCTAssertEqual(try canonical(before.filter { $0.relationType == .purposeContextBlock }), try canonical(after.filter { $0.relationType == .purposeContextBlock }))
        XCTAssertLessThan(try XCTUnwrap(after.first { $0.relationType == .purposeConfiguration }).weightStored,
                          try XCTUnwrap(before.first { $0.relationType == .purposeConfiguration }).weightStored)
    }
    func testStaleRevisionRejectsBeforeLearningButKnownRetryRemainsIdempotent() async throws {
        let engine = RelationalLearningEngine()
        let original = try RelationalLearningEventEnvelope.from(event("original", .purposeChoice, revision: 0))
        _ = try await engine.applyEnvelopeTransaction(original)
        let before = await engine.journalSnapshot(), beforeEdges = await engine.edges()
        do { _ = try await engine.applyEnvelopeTransaction(.from(event("concurrent", .purposeCorrection, revision: 0))); XCTFail("stale revision") }
        catch RelationalLearningError.invalidEvent { }
        let duplicate = try await engine.applyEnvelopeTransaction(original)
        XCTAssertFalse(duplicate.applied); XCTAssertNil(duplicate.sequence)
        let after = await engine.journalSnapshot(), afterEdges = await engine.edges()
        XCTAssertEqual(try canonical(before), try canonical(after)); XCTAssertEqual(try canonical(beforeEdges), try canonical(afterEdges))
    }
    func testCausalSameTimeChoicesBothLearnRegardlessOfLexicalEventID() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(.from(event("z-first", .purposeChoice, revision: 0)))
        let before = await engine.edges()
        let result = try await engine.applyEnvelopeTransaction(.from(event("a-next", .purposeChoice, revision: 1)))
        XCTAssertEqual(result.weightUpdates.count, 3)
        let after = await engine.edges()
        for (a,b) in zip(before, after) { XCTAssertGreaterThan(b.weightStored, a.weightStored) }
    }
    func testPositiveChoiceProtectsAgainstOlderInferredResult() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(.from(event("choice", .purposeChoice, revision: 0, at: 200)))
        let before = await engine.edges()
        let old = RelationalPurposeLifecycleEvent(eventId: "late-failure", timestamp: 190, status: .failed,
            purposeId: "purpose://family", activeContextBlocks: blocks, contextConfidence: 1)
        let result = try await engine.applyEnvelopeTransaction(.from(old))
        XCTAssertTrue(result.weightUpdates.isEmpty)
        let after = await engine.edges(); XCTAssertEqual(try canonical(before), try canonical(after))
    }
    func testTypedHistoryRestoreAndReplayPreserveAcceptedCausalHistory() async throws {
        let engine = RelationalLearningEngine()
        for (index,id) in ["z", "a", "q"].enumerated() {
            _ = try await engine.applyEnvelopeTransaction(.from(event(id, .purposeChoice, revision: UInt64(index))))
        }
        let history = await engine.journalSnapshot(), edges = await engine.edges()
        let restored = RelationalLearningEngine(); try await restored.restore(from: history)
        let replayed = RelationalLearningEngine()
        _ = try await replayed.replayTransaction(events: history.records.map(\.envelope), resetFirst: true)
        let restoredEdges = await restored.edges(), replayedEdges = await replayed.edges()
        XCTAssertEqual(try canonical(edges), try canonical(restoredEdges)); XCTAssertEqual(try canonical(edges), try canonical(replayedEdges))
        do { _ = try await replayed.replayTransaction(events: Array(history.records.map(\.envelope).reversed()), resetFirst: true); XCTFail("unordered incremental history must reject") }
        catch RelationalLearningError.invalidEvent { }
        let unchanged = await replayed.edges(), journal = await replayed.journalSnapshot()
        XCTAssertEqual(try canonical(edges), try canonical(unchanged)); XCTAssertEqual(try canonical(history), try canonical(journal))
    }
    func testMalformedOrDowngradedTypedFeedbackRejectsBeforeMutation() async throws {
        let engine = RelationalLearningEngine()
        var invalid = event("invalid", .confirmedOutcome, revision: 0)
        invalid.configuration = .init(configurationUUID: "not-a-uuid", sourceCellEndpoint: "https://example.test")
        var downgraded = try RelationalLearningEventEnvelope.from(event("downgraded", .purposeChoice, revision: 0)); downgraded.schemaVersion = "1.0"
        for envelope in [try .from(invalid), downgraded] {
            do { _ = try await engine.applyEnvelopeTransaction(envelope); XCTFail("invalid typed feedback") }
            catch RelationalLearningError.invalidEvent { }
        }
        let journal = await engine.journalSnapshot(); XCTAssertEqual(journal.revision, 0)
    }
    func testConfigurationUsesExistingNoaRetentionAndPurposeDoesNotGainFromIt() async throws {
        let engine = RelationalLearningEngine()
        for index in 0..<35 {
            _ = try await engine.applyEnvelopeTransaction(.from(event("solved-\(index)", .confirmedOutcome, revision: UInt64(index), at: 100)))
        }
        let now = await engine.scoreConfigurations(purposeId: "purpose://family", at: 100)
        let later = await engine.scoreConfigurations(purposeId: "purpose://family", at: 100 + 14*86400)
        XCTAssertGreaterThan(try XCTUnwrap(now.first).score, 0.9)
        XCTAssertLessThan(try XCTUnwrap(later.first).score, 0.9)
        XCTAssertEqual(try XCTUnwrap(later.first).explain.decayProfileId, RelationalDecayPolicy.defaultNoa.profileId)
        let purposes = await engine.scorePurposes(contextSnapshot: .init(activeContextBlocks: blocks), at: 100)
        XCTAssertTrue(purposes.allSatisfy { $0.score == 0 })
    }
    func testWeakContextCannotRefreshOldHighWeightOrEstablishChoiceBarrier() async throws {
        let engine = RelationalLearningEngine()
        for index in 0..<30 {
            _ = try await engine.applyEnvelopeTransaction(.from(event("trained-\(index)", .purposeChoice, revision: UInt64(index))))
        }
        let before = await engine.edges(), journal = await engine.journalSnapshot()
        for confidence in [0.0, 0.59] {
            var weak = event("weak-\(confidence)", .purposeChoice, revision: journal.revision, at: 100 + 14*86400)
            weak.contextBlocks = blocks.map { .init(domain: $0.domain, blockId: $0.blockId, confidence: confidence) }
            do { _ = try await engine.applyEnvelopeTransaction(.from(weak)); XCTFail("weak feedback cannot refresh old evidence") }
            catch RelationalLearningError.invalidEvent { }
        }
        let after = await engine.edges(), afterJournal = await engine.journalSnapshot()
        XCTAssertEqual(try canonical(before), try canonical(after)); XCTAssertEqual(try canonical(journal), try canonical(afterJournal))
    }
    func testMixedContextOnlyTrainsQualifiedOriginalSignals() async throws {
        let engine = RelationalLearningEngine()
        var mixed = event("mixed", .purposeChoice, revision: 0)
        mixed.contextBlocks[1].confidence = 0.59; mixed.contextBlocks[2].confidence = 0
        let result = try await engine.applyEnvelopeTransaction(.from(mixed))
        XCTAssertEqual(result.weightUpdates.count, 1)
        XCTAssertEqual(result.weightUpdates.first?.edge.toNode.id, blocks[0].node.id)
    }
    func testDerivedTypedWeightsCannotBecomeIndependentLearningOrForgeAuthority() async throws {
        let source = RelationalLearningEngine()
        let first = try await source.applyEnvelopeTransaction(.from(event("original", .purposeChoice, revision: 0)))
        var update = try XCTUnwrap(first.weightUpdates.first)
        let echo = try RelationalLearningEventEnvelope.from(update)
        let duplicate = try await source.applyEnvelopeTransaction(echo)
        XCTAssertFalse(duplicate.applied); XCTAssertNil(duplicate.sequence)
        let empty = RelationalLearningEngine()
        do { _ = try await empty.applyEnvelopeTransaction(echo); XCTFail("orphan derived weight") }
        catch RelationalLearningError.invalidEvent { }
        update.sourceFeedbackRevision = 999_999; update.newWeightStored = 1
        do { _ = try await source.applyEnvelopeTransaction(.from(update)); XCTFail("forged derived authority") }
        catch RelationalLearningError.invalidEvent { }
        let direct = await empty.applyWeightUpdateEvent(update); XCTAssertFalse(direct)
        let emptyEdges = await empty.edges(), journal = await source.journalSnapshot()
        XCTAssertTrue(emptyEdges.isEmpty); XCTAssertEqual(journal.revision, 1)
        let restored = RelationalLearningEngine(); try await restored.restore(from: journal)
        let restoredEcho = try await restored.applyEnvelopeTransaction(echo); XCTAssertNil(restoredEcho.sequence)
    }
    func testConfigurationReferenceNormalizesDecodedUUIDForExactCandidateScoring() async throws {
        let upper = "ABCDEF12-1234-4234-8234-ABCDEF123456"
        let data = try JSONSerialization.data(withJSONObject: ["configurationUUID": upper, "sourceCellEndpoint": "cell:///Synthetic"])
        let decoded = try JSONDecoder().decode(RelationalConfigurationReference.self, from: data)
        try decoded.validate(); XCTAssertEqual(decoded.configurationUUID, upper.lowercased())
        let engine = RelationalLearningEngine()
        var feedback = event("mixed-case", .confirmedOutcome, revision: 0); feedback.configuration = decoded
        _ = try await engine.applyEnvelopeTransaction(.from(feedback))
        let scores = await engine.scoreConfigurations(purposeId: feedback.purposeId, candidateConfigurationIDs: [decoded.node.id], at: 100)
        XCTAssertEqual(scores.count, 1); XCTAssertEqual(scores.first?.configuration, decoded)
    }
    func testV1WeightUpdateWireDoesNotAcquireTypedAuthorityFields() throws {
        let edge = RelationalEdge(fromNode: .init(type: .purpose, id: "p"), relationType: .purposeInterest,
                                  toNode: .init(type: .interest, id: "i"), weightStored: 0.2, lastReinforcedAt: 100,
                                  decayProfileId: RelationalDecayPolicy.defaultNoa.profileId, decayParamsVersion: 1)
        let update = RelationalWeightUpdateEvent(emittedAt: 100, sourceEventId: "legacy", outcome: .success, edge: edge,
                                                previousWeightStored: 0.1, newWeightStored: 0.2, learningRate: 0.08, eligibility: 1, reason: "legacy")
        let envelope = try RelationalLearningEventEnvelope.from(update)
        XCTAssertEqual(envelope.schemaVersion, "1.0"); XCTAssertNil(envelope.payload["sourceFeedbackKind"]); XCTAssertNil(envelope.payload["sourceFeedbackRevision"])
    }
}
