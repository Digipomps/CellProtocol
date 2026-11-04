// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase

/// WP1. These are mechanics tests of the native learner, not an autonomous UI policy.
final class PerspectiveLearningEvidenceTests: XCTestCase {
    func testMechanicsContextAndStartedPurposeDoNotReinforceWithoutOutcome() async throws {
        let engine = RelationalLearningEngine()
        _ = try await engine.applyEnvelopeTransaction(.from(RelationalContextTransitionEvent(
            eventId: "exposure-context", timestamp: 100, domain: "place", toBlockId: "home")))
        let result = try await LearningEvidenceFixture.lifecycle(engine, id: "exposure-start", at: 101, status: .started)
        let edges = await engine.edges()
        XCTAssertTrue(result.weightUpdates.isEmpty)
        XCTAssertTrue(edges.isEmpty, "Presence and starting a purpose are not a confirmed outcome")
        let journal = await engine.journalSnapshot()
        XCTAssertEqual(journal.revision, 2, "Observed inputs can be journaled without preference reinforcement")
    }

    func testMechanicsExplicitChoiceAndCorrectionSetTheRequestedWeight() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "choice", at: 100, weight: 0.9)
        let selected = await engine.edges()
        XCTAssertEqual(try XCTUnwrap(selected.first).weightStored, 0.9, accuracy: 1e-12)
        _ = try await LearningEvidenceFixture.preference(engine, id: "correction", at: 110, weight: 0.2)
        let corrected = await engine.edges()
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(try XCTUnwrap(corrected.first).weightStored, 0.2, accuracy: 1e-12)
        XCTAssertEqual(corrected.first?.metadata["sourcePreferenceEventId"], "correction")
    }

    func testMechanicsConfirmedSuccessAndFailureHaveDistinctDirections() async throws {
        let success = RelationalLearningEngine(), failure = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.lifecycle(success, id: "solved", at: 100, status: .succeeded)
        _ = try await LearningEvidenceFixture.lifecycle(failure, id: "unsolved", at: 100, status: .failed)
        let positive = await success.edges(), negative = await failure.edges()
        XCTAssertEqual(try XCTUnwrap(positive.first).weightStored, 0.172, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(negative.first).weightStored, 0.095, accuracy: 1e-12)
    }

    func testMechanicsActivePassiveAndContextEligibilityAreKeptSeparate() async throws {
        let engine = RelationalLearningEngine()
        let event = RelationalPurposeLifecycleEvent(eventId: "eligibility", timestamp: 100, status: .succeeded,
            purposeId: LearningEvidenceFixture.purpose,
            activeInterestRefs: ["interest://active"], passiveInterestRefs: ["interest://passive"],
            activeContextBlocks: [.init(domain: "place", blockId: "home", confidence: 0.8)], contextConfidence: 1)
        let result = try await engine.applyEnvelopeTransaction(.from(event))
        XCTAssertEqual(result.weightUpdates.count, 3)
        let edges = await engine.edges()
        XCTAssertEqual(try XCTUnwrap(edges.first { $0.toNode.id == "interest://active" }).weightStored, 0.172, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(edges.first { $0.toNode.id == "interest://passive" }).weightStored, 0.1216, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(edges.first { $0.toNode.id == "place:home" }).weightStored, 0.1288, accuracy: 1e-12)
    }

    func testMechanicsLowContextConfidenceDoesNotReinforce() async throws {
        let engine = RelationalLearningEngine()
        let event = RelationalPurposeLifecycleEvent(eventId: "low-confidence", timestamp: 100, status: .succeeded,
            purposeId: LearningEvidenceFixture.purpose, activeInterestRefs: [LearningEvidenceFixture.interest], contextConfidence: 0.59)
        let result = try await engine.applyEnvelopeTransaction(.from(event))
        let edges = await engine.edges()
        XCTAssertTrue(result.applied)
        XCTAssertTrue(result.weightUpdates.isEmpty)
        XCTAssertTrue(edges.isEmpty, "The 0.6 input gate is not evidence of a safe UI-switch threshold")
    }

    func testMechanicsDuplicateStrongFeedbackDoesNotReinforceTwiceOrGrowJournal() async throws {
        let engine = RelationalLearningEngine()
        let event = RelationalPurposeLifecycleEvent(eventId: "one-result", timestamp: 100, status: .succeeded,
            purposeId: LearningEvidenceFixture.purpose, activeInterestRefs: [LearningEvidenceFixture.interest], contextConfidence: 1)
        let envelope = try RelationalLearningEventEnvelope.from(event)
        let first = try await engine.applyEnvelopeTransaction(envelope)
        let edgesBefore = await engine.edges(), journalBefore = await engine.journalSnapshot()
        let duplicate = try await engine.applyEnvelopeTransaction(envelope)
        let edgesAfter = await engine.edges(), journalAfter = await engine.journalSnapshot()
        XCTAssertTrue(first.applied)
        XCTAssertFalse(duplicate.applied)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(edgesBefore), try LearningEvidenceFixture.canonical(edgesAfter))
        XCTAssertEqual(try LearningEvidenceFixture.canonical(journalBefore), try LearningEvidenceFixture.canonical(journalAfter))
    }

    func testMechanicsOneOutcomeDoesNotPenalizeAnotherLegitimatePurpose() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "family", at: 100, weight: 0.8, purpose: "purpose://family")
        _ = try await LearningEvidenceFixture.preference(engine, id: "work", at: 100, weight: 0.8, purpose: "purpose://work")
        _ = try await LearningEvidenceFixture.lifecycle(engine, id: "family-result", at: 110, status: .succeeded, purpose: "purpose://family")
        let edges = await engine.edges()
        XCTAssertEqual(try XCTUnwrap(edges.first { $0.fromNode.id == "purpose://work" }).weightStored, 0.8, accuracy: 1e-12)
        XCTAssertGreaterThan(try XCTUnwrap(edges.first { $0.fromNode.id == "purpose://family" }).weightStored, 0.8)
    }

    func testMechanicsJournalRestorePreservesChoicesAndDuplicateProtection() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "restore-choice", at: 100, weight: 0.8)
        _ = try await LearningEvidenceFixture.lifecycle(engine, id: "restore-result", at: 110, status: .succeeded)
        let journal = await engine.journalSnapshot()
        let restored = RelationalLearningEngine()
        try await restored.restore(from: journal)
        let original = await engine.edges(), copy = await restored.edges()
        XCTAssertEqual(try LearningEvidenceFixture.canonical(original), try LearningEvidenceFixture.canonical(copy))
        let duplicate = try await LearningEvidenceFixture.lifecycle(restored, id: "restore-result", at: 110, status: .succeeded)
        XCTAssertFalse(duplicate.applied)
        let restoredJournal = await restored.journalSnapshot()
        XCTAssertEqual(restoredJournal.revision, journal.revision)
    }
}

/// Deterministic input helpers only. They do not decide purposes, suitability or confidence.
enum LearningEvidenceFixture {
    static let purpose = "purpose://learning-fixture"
    static let interest = "interest://learning-fixture"
    static let day: TimeInterval = 86_400

    @discardableResult
    static func preference(_ engine: RelationalLearningEngine, id: String, at timestamp: TimeInterval,
                           weight: Double, purpose: String = LearningEvidenceFixture.purpose, interest: String = LearningEvidenceFixture.interest) async throws -> RelationalLearningTransactionResult {
        try await engine.applyEnvelopeTransaction(.from(RelationalExplicitPreferenceEvent(
            eventId: id, timestamp: timestamp, purposeId: purpose, relationType: .purposeInterest,
            targetNode: .init(type: .interest, id: interest), preferenceWeight: weight)))
    }

    @discardableResult
    static func lifecycle(_ engine: RelationalLearningEngine, id: String, at timestamp: TimeInterval,
                          status: RelationalPurposeLifecycleStatus, purpose: String = LearningEvidenceFixture.purpose,
                          metadata: [String: String] = [:]) async throws -> RelationalLearningTransactionResult {
        try await engine.applyEnvelopeTransaction(.from(RelationalPurposeLifecycleEvent(
            eventId: id, timestamp: timestamp, status: status, purposeId: purpose,
            activeInterestRefs: [interest], contextConfidence: 1, metadata: metadata)))
    }

    static func score(_ engine: RelationalLearningEngine, at timestamp: TimeInterval,
                      purpose: String = LearningEvidenceFixture.purpose) async throws -> RelationalPurposeScore {
        let scores = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs: [interest]), at: timestamp)
        return try XCTUnwrap(scores.first { $0.purposeId == purpose })
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
