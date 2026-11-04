// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase

/// WP3: observes the actual ranking API. No test policy masquerades as a product decision.
final class PerspectiveLearningAmbiguityTests: XCTestCase {
    func testMechanicsNoHistoryAndUnknownContextDoNotInventEvidence() async throws {
        let engine = RelationalLearningEngine()
        let empty = await engine.scorePurposes(contextSnapshot: .init(), at: 100)
        XCTAssertTrue(empty.isEmpty)
        _ = try await LearningEvidenceFixture.preference(engine, id: "known-choice", at: 100, weight: 0.9)
        let unknown = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs: ["interest://unknown"]), at: 100)
        let score = try XCTUnwrap(unknown.first)
        XCTAssertEqual(score.score, 0, accuracy: 1e-12)
        XCTAssertTrue(score.explain.topEdges.isEmpty)
    }

    func testCharacterizationExactTieHasLexicalOrderWithoutCertaintyWitness() async throws {
        let engine = RelationalLearningEngine()
        for purpose in ["purpose://b", "purpose://a"] {
            _ = try await LearningEvidenceFixture.preference(engine, id: "choice-" + purpose, at: 100, weight: 0.8, purpose: purpose)
        }
        let scores = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs: [LearningEvidenceFixture.interest]), at: 100)
        XCTAssertEqual(scores.map(\.purposeId), ["purpose://a", "purpose://b"])
        XCTAssertEqual(scores.map(\.score), [0.8, 0.8])
        XCTAssertEqual(scores[0].explain.rawScore, scores[1].explain.rawScore,
            "Lexical tie-breaking is deterministic ordering, not user intent resolution")
    }

    func testCharacterizationNearTiePreservesTheSmallObservedMargin() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "near-a", at: 100, weight: 0.801, purpose: "purpose://a")
        _ = try await LearningEvidenceFixture.preference(engine, id: "near-b", at: 100, weight: 0.8, purpose: "purpose://b")
        let scores = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs: [LearningEvidenceFixture.interest]), at: 100)
        XCTAssertEqual(scores.count, 2)
        XCTAssertEqual(scores[0].score - scores[1].score, 0.001, accuracy: 1e-12)
        XCTAssertEqual(scores[0].purposeId, "purpose://a")
    }

    func testCharacterizationSaturationHidesDifferentRawEvidenceStrengths() async throws {
        let engine = RelationalLearningEngine()
        for (purpose, count) in [("purpose://a", 2), ("purpose://b", 3)] {
            for index in 0..<count {
                _ = try await LearningEvidenceFixture.preference(engine, id: "\(purpose)-\(index)", at: 100,
                    weight: 0.8, purpose: purpose, interest: "interest://signal-\(index)")
            }
        }
        let scores = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs:
            (0..<3).map { "interest://signal-\($0)" }), at: 100)
        XCTAssertEqual(scores.map(\.score), [1, 1])
        XCTAssertEqual(scores[0].explain.rawScore, 1.6, accuracy: 1e-12)
        XCTAssertEqual(scores[1].explain.rawScore, 2.4, accuracy: 1e-12)
        XCTAssertEqual(scores[0].purposeId, "purpose://a",
            "At saturation the runtime uses lexical order, not the larger raw score")
    }

    func testCharacterizationCorrelatedWeakEdgesCanSaturateRankingScore() async throws {
        let engine = RelationalLearningEngine()
        for index in 0..<11 {
            _ = try await LearningEvidenceFixture.preference(engine, id: "weak-\(index)", at: 100,
                weight: 0.1, interest: "interest://same-latent-signal-\(index)")
        }
        let scores = await engine.scorePurposes(contextSnapshot: .init(activeInterestRefs:
            (0..<11).map { "interest://same-latent-signal-\($0)" }), at: 100, explainTopN: 20)
        let score = try XCTUnwrap(scores.first)
        XCTAssertEqual(score.score, 1, accuracy: 1e-12)
        XCTAssertEqual(score.explain.rawScore, 1.1, accuracy: 1e-12)
        XCTAssertEqual(score.explain.topEdges.count, 11)
        // Correlation is latent fixture truth. The ranking API has no causal-
        // independence model; the value 1 must not be presented as 100% certainty.
    }

    func testCharacterizationSingleExplicitChoiceDoesNotExposeEvidenceSampleCount() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "one-choice", at: 100, weight: 0.99)
        let score = try await LearningEvidenceFixture.score(engine, at: 100)
        let journal = await engine.journalSnapshot()
        XCTAssertEqual(score.score, 0.99, accuracy: 1e-12)
        XCTAssertEqual(journal.records.count, 1)
        XCTAssertEqual(score.explain.topEdges.count, 1,
            "A high weight from one explicit choice does not establish repeated predictive accuracy")
    }

    func testCharacterizationPurposePurposeRelationCannotStandInForSurfaceUtility() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "purpose-choice", at: 100, weight: 0.9)
        let before = try await LearningEvidenceFixture.score(engine, at: 100)
        // The only purpose-to-purpose relation is not an executable surface-
        // suitability relation. Do not invent a configuration node or a new API.
        let relation = RelationalExplicitPreferenceEvent(eventId: "related-purpose", timestamp: 100,
            purposeId: LearningEvidenceFixture.purpose, relationType: .purposePurpose,
            targetNode: .init(type: .purpose, id: "purpose://related"), preferenceWeight: 1)
        _ = try await engine.applyEnvelopeTransaction(.from(relation))
        let after = try await LearningEvidenceFixture.score(engine, at: 100)
        XCTAssertEqual(before.score, after.score, accuracy: 1e-12)
        XCTAssertEqual(after.explain.topEdges.count, before.explain.topEdges.count)
        let edges = await engine.edges()
        XCTAssertEqual(edges.count, 2)
    }
}
