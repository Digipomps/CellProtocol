// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase

/// WP2. Injected event/score time; no sleeps and no production decay changes.
final class PerspectiveLearningDecayTests: XCTestCase {
    func testMechanicsNoaRuntimeCheckpointsKeepStoredAndEffectiveWeightsSeparate() async throws {
        let engine = RelationalLearningEngine()
        let origin = 1_700_000_000.0
        _ = try await LearningEvidenceFixture.preference(engine, id: "checkpoint-choice", at: origin, weight: 0.9)
        // Independent arithmetic fixture, not values obtained from scorePurposes.
        let checkpoints: [(Double, Double)] = [(0, 1), (7, 0.6835875567398052),
            (14, 0.3978454904520783), (30, 0.0992261727484916),
            (60, 0.050467357437799065), (120, 0.050000015592150414)]
        for (days, retention) in checkpoints {
            let score = try await LearningEvidenceFixture.score(engine, at: origin + days * LearningEvidenceFixture.day)
            let explanation = try XCTUnwrap(score.explain.topEdges.first, "day=\(days)")
            XCTAssertEqual(explanation.edge.weightStored, 0.9, accuracy: 1e-12, "day=\(days)")
            XCTAssertEqual(explanation.edge.lastReinforcedAt, origin, "day=\(days)")
            XCTAssertEqual(explanation.effectiveWeight, 0.9 * retention, accuracy: 1e-10, "day=\(days)")
            XCTAssertEqual(score.score, explanation.effectiveWeight, accuracy: 1e-12)
        }
        let journal = await engine.journalSnapshot()
        XCTAssertEqual(journal.revision, 1, "Scoring and aging must not themselves be feedback events")
    }

    func testMechanicsSameAndBackwardScoreTimesDoNotRefreshWeightsOrJournal() async throws {
        let engine = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(engine, id: "clock-choice", at: 1_000, weight: 0.8)
        let before = await engine.journalSnapshot()
        let same = try await LearningEvidenceFixture.score(engine, at: 1_000)
        let backward = try await LearningEvidenceFixture.score(engine, at: 900)
        let repeated = try await LearningEvidenceFixture.score(engine, at: 1_000)
        XCTAssertEqual(same.score, 0.8, accuracy: 1e-12)
        XCTAssertEqual(backward.score, same.score, accuracy: 1e-12, "Current runtime clamps negative age to zero")
        XCTAssertEqual(try LearningEvidenceFixture.canonical(same), try LearningEvidenceFixture.canonical(repeated))
        let after = await engine.journalSnapshot()
        XCTAssertEqual(try LearningEvidenceFixture.canonical(before), try LearningEvidenceFixture.canonical(after))
    }

    func testMechanicsNoDecayControlUsesActualEngineWithPolicyOverride() async throws {
        let engine = RelationalLearningEngine()
        let policy = RelationalDecayPolicy(profileId: "noa", version: 2, effectiveFromTimestamp: 0, kind: .none)
        _ = try await engine.applyEnvelopeTransaction(.from(RelationalDecayPolicyUpdatedEvent(
            eventId: "no-decay-control", emittedAt: 0, policy: policy)))
        _ = try await LearningEvidenceFixture.preference(engine, id: "stable-choice", at: 1, weight: 0.9)
        let later = try await LearningEvidenceFixture.score(engine, at: 1 + 120 * LearningEvidenceFixture.day)
        XCTAssertEqual(later.score, 0.9, accuracy: 1e-12)
        XCTAssertEqual(later.explain.topEdges.first?.decayParamsVersion, 2)
        _ = try await LearningEvidenceFixture.lifecycle(engine, id: "still-learns", at: 1 + 120 * LearningEvidenceFixture.day, status: .succeeded)
        let updated = await engine.edges()
        XCTAssertEqual(try XCTUnwrap(updated.first).weightStored, 0.908, accuracy: 1e-12,
            "No decay is a learning arm, distinct from frozen weights")
    }

    func testMechanicsVacationSilenceAndObservedAlternativeChoicesAreDifferentEvidence() async throws {
        let vacation = RelationalLearningEngine(), changedRoutine = RelationalLearningEngine()
        for engine in [vacation, changedRoutine] {
            _ = try await LearningEvidenceFixture.preference(engine, id: "home-choice", at: 1, weight: 0.8, purpose: "purpose://home")
        }
        let now = 1 + 60 * LearningEvidenceFixture.day
        _ = try await LearningEvidenceFixture.preference(changedRoutine, id: "new-work-choice", at: now, weight: 0.8, purpose: "purpose://work")
        let quietHome = try await LearningEvidenceFixture.score(vacation, at: now, purpose: "purpose://home")
        let changedHome = try await LearningEvidenceFixture.score(changedRoutine, at: now, purpose: "purpose://home")
        XCTAssertEqual(quietHome.score, changedHome.score, accuracy: 1e-12,
            "Current engine is not contrastive: selecting another purpose does not punish the old purpose")
        let quietEdges = await vacation.edges(), activeEdges = await changedRoutine.edges()
        XCTAssertEqual(quietEdges.count, 1)
        XCTAssertEqual(activeEdges.count, 2)
        let alternate = try await LearningEvidenceFixture.score(changedRoutine, at: now, purpose: "purpose://work")
        XCTAssertGreaterThan(alternate.score, changedHome.score)
    }

    func testMechanicsWeeklyConfirmedOutcomeRefreshesOnlyObservedRoutine() async throws {
        let weekly = RelationalLearningEngine(), silent = RelationalLearningEngine()
        for engine in [weekly, silent] {
            _ = try await LearningEvidenceFixture.preference(engine, id: "weekly-choice", at: 1, weight: 0.7)
        }
        for week in 1...8 {
            _ = try await LearningEvidenceFixture.lifecycle(weekly, id: "weekly-result-\(week)",
                at: 1 + Double(week * 7) * LearningEvidenceFixture.day, status: .succeeded)
        }
        let now = 1 + 60 * LearningEvidenceFixture.day
        let observed = try await LearningEvidenceFixture.score(weekly, at: now)
        let unobserved = try await LearningEvidenceFixture.score(silent, at: now)
        XCTAssertGreaterThan(observed.score, unobserved.score)
        XCTAssertEqual(observed.explain.topEdges.first?.edge.lastReinforcedAt, 1 + 56 * LearningEvidenceFixture.day)
        XCTAssertEqual(unobserved.explain.topEdges.first?.edge.lastReinforcedAt, 1)
    }

    func testMechanicsNegativeFeedbackAfterPauseComparedWithMatchedClockRefresh() async throws {
        let failed = RelationalLearningEngine(), contextOnly = RelationalLearningEngine(), matchedClock = RelationalLearningEngine()
        for engine in [failed, contextOnly, matchedClock] {
            _ = try await LearningEvidenceFixture.preference(engine, id: "old-strong-preference", at: 1, weight: 0.9)
        }
        let now = 1 + 120 * LearningEvidenceFixture.day
        let before = try await LearningEvidenceFixture.score(failed, at: now)
        for engine in [failed, contextOnly, matchedClock] {
            _ = try await engine.applyEnvelopeTransaction(.from(RelationalContextTransitionEvent(
                eventId: "fresh-context", timestamp: now, domain: "place", toBlockId: "home")))
        }
        _ = try await LearningEvidenceFixture.lifecycle(failed, id: "failed-after-pause", at: now, status: .failed)
        // Explicitly matched clock control: reset the same preference to itself at the
        // same instant. This is a mechanics intervention, not a user signal or new policy.
        _ = try await LearningEvidenceFixture.preference(matchedClock, id: "clock-only-intervention", at: now, weight: 0.9)
        let negative = try await LearningEvidenceFixture.score(failed, at: now)
        let freshContext = try await LearningEvidenceFixture.score(contextOnly, at: now)
        let refreshed = try await LearningEvidenceFixture.score(matchedClock, at: now)
        XCTAssertEqual(before.score, freshContext.score, accuracy: 1e-12)
        XCTAssertEqual(negative.score, 0.855, accuracy: 1e-12)
        XCTAssertEqual(refreshed.score, 0.9, accuracy: 1e-12)
        XCTAssertGreaterThan(negative.score, before.score,
            "Failure resets reinforcement time; an increase versus stale state alone is not evidence of positive learning")
        XCTAssertLessThan(negative.score, refreshed.score,
            "With identical clock refresh, failure decreases preference strength")
    }

    func testCharacterizationFailureMetadataDoesNotSeparateWrongPurposeFromBadSurfaceOrAbort() async throws {
        var measured = [Double]()
        // The native API has only succeeded/failed. Mapping abort to failed is an
        // explicit test intervention; this does not claim a native abort action exists.
        for reason in ["wrong-purpose", "bad-surface", "goal-failure", "abort-mapped-to-failure"] {
            let engine = RelationalLearningEngine()
            _ = try await LearningEvidenceFixture.preference(engine, id: "selected", at: 1, weight: 0.9)
            _ = try await LearningEvidenceFixture.lifecycle(engine, id: "negative-\(reason)",
                at: 1 + 120 * LearningEvidenceFixture.day, status: .failed, metadata: ["reason": reason])
            let edges = await engine.edges()
            measured.append(try XCTUnwrap(edges.first).weightStored)
        }
        XCTAssertEqual(measured, Array(repeating: 0.855, count: 4),
            "Metadata does not provide independent surface utility or outcome semantics")
    }

    func testMechanicsContextTTLExpiresWithoutErasingHistoricalPreference() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let goal = GoalDefinition(goalID: "at-home", purposeRef: LearningEvidenceFixture.purpose,
            title: "Home", description: "Home", lifecycle: .continuous, evaluatorKind: .statePredicate,
            evidenceSources: [.init(sourceID: "place")],
            predicate: .init(kind: "contains-label", sourceID: "place", expected: "home"))
        var context = PerspectiveContextState(configuration: .init(
            sources: [.init(sourceID: "place", endpoint: "cell:///fixture-place")],
            rules: [.init(id: "home-rule", definition: goal, label: "home", purposeWeights: [LearningEvidenceFixture.purpose: 0.9])]))
        try context.ingest(.init(revision: 1, observedAt: origin, validUntil: origin.addingTimeInterval(60),
            transition: "entered", labels: ["home"]), sourceID: "place", eventID: "home", snapshot: false, now: origin)
        let learner = RelationalLearningEngine()
        _ = try await LearningEvidenceFixture.preference(learner, id: "preference", at: origin.timeIntervalSince1970, weight: 0.9)
        XCTAssertEqual(context.decision(now: origin).labels, ["home"])
        let expired = context.decision(now: origin.addingTimeInterval(60))
        XCTAssertTrue(expired.purposeWeights.isEmpty)
        XCTAssertEqual(expired.unknownSources, ["place"])
        let history = await learner.edges()
        XCTAssertEqual(try XCTUnwrap(history.first).weightStored, 0.9, accuracy: 1e-12,
            "A TTL clears present context; it is not a negative preference update")
    }
}
