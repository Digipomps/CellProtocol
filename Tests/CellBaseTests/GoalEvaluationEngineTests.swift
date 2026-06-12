// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class GoalEvaluationEngineTests: XCTestCase {
    func testCompositeSemanticLocationAndTimeGoalIsSatisfiedWhenBothLabelsMatch() {
        let definition = workAtLunchDefinition()

        let evaluation = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(
                    sourceID: "semantic-location",
                    observedAt: "2026-06-11T10:55:00Z",
                    labels: ["work"],
                    confidence: 0.94
                ),
                GoalObservation(
                    sourceID: "semantic-time",
                    observedAt: "2026-06-11T10:55:00Z",
                    labels: ["lunch"],
                    confidence: 1.0
                )
            ],
            evaluatedAt: "2026-06-11T10:55:00Z"
        )

        XCTAssertEqual(evaluation.status, .satisfied)
        XCTAssertEqual(evaluation.progress, 1)
        XCTAssertTrue(evaluation.isSatisfied)
        XCTAssertTrue(evaluation.emittedEvents.contains("goal.satisfied"))
    }

    func testCompositeSemanticGoalIsActiveWhenOnlyOneLabelMatches() {
        let definition = workAtLunchDefinition()

        let evaluation = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "semantic-location", labels: ["work"], confidence: 0.94),
                GoalObservation(sourceID: "semantic-time", labels: ["morning"], confidence: 1.0)
            ],
            evaluatedAt: "2026-06-11T08:30:00Z"
        )

        XCTAssertEqual(evaluation.status, .active)
        XCTAssertFalse(evaluation.isSatisfied)
        XCTAssertFalse(evaluation.isTerminal)
    }

    func testMissingEvidenceMakesGoalUnknownInsteadOfInventingState() {
        let definition = workAtLunchDefinition()

        let evaluation = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "semantic-location", labels: ["work"])
            ],
            evaluatedAt: "2026-06-11T10:55:00Z"
        )

        XCTAssertEqual(evaluation.status, .unknown)
        XCTAssertEqual(evaluation.missing, ["evidence-source:semantic-time"])
        XCTAssertEqual(evaluation.evidence.first(where: { $0.sourceID == "semantic-time" })?.status, .missing)
    }

    func testHumanConfirmationGoalIsSatisfiedWhenConfirmationEventArrives() {
        let definition = GoalDefinition(
            goalID: "goal.agent.review.confirm",
            purposeRef: "purpose://agent.local.review-before-action",
            title: "Wait for human approval",
            description: "Satisfied only when the represented person explicitly confirms the pending agent action.",
            lifecycle: .deadline,
            evaluatorKind: .humanConfirmation,
            evidenceSources: [
                GoalEvidenceSource(sourceID: "confirmation-event", endpoint: "cell:///HumanConfirmation", topic: "goal.confirmation", eventType: "goal.confirmed")
            ],
            predicate: GoalPredicate(kind: "event-seen", sourceID: "confirmation-event", expected: "goal.confirmed")
        )

        let evaluation = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "confirmation-event", eventTypes: ["goal.confirmed"], confidence: 1.0)
            ],
            evaluatedAt: "2026-06-11T09:41:00Z"
        )

        XCTAssertEqual(evaluation.status, .satisfied)
        XCTAssertTrue(evaluation.isTerminal)
        XCTAssertEqual(evaluation.confidence, 1)
    }

    func testNetworkGoalTransitionsFromSatisfiedToAtRiskToMissed() {
        let definition = networkDefinition()

        let ok = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "staging-health", consecutiveFailures: 0, confidence: 0.95)
            ],
            evaluatedAt: "2026-06-11T09:30:00Z"
        )
        let atRisk = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "staging-health", consecutiveFailures: 1, confidence: 0.95)
            ],
            evaluatedAt: "2026-06-11T09:31:00Z"
        )
        let missed = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: [
                GoalObservation(sourceID: "staging-health", consecutiveFailures: 3, confidence: 0.95)
            ],
            evaluatedAt: "2026-06-11T09:32:00Z"
        )

        XCTAssertEqual(ok.status, .satisfied)
        XCTAssertEqual(atRisk.status, .atRisk)
        XCTAssertEqual(missed.status, .missed)
        XCTAssertTrue(missed.isTerminal)
    }

    private func workAtLunchDefinition() -> GoalDefinition {
        GoalDefinition(
            goalID: "goal.personal.location.work-at-lunch",
            purposeRef: "purpose://personal.be-at-work-for-lunch",
            title: "Be at work during lunch",
            description: "Satisfied when work and lunch semantic labels are both active.",
            lifecycle: .continuous,
            evaluatorKind: .composite,
            evidenceSources: [
                GoalEvidenceSource(sourceID: "semantic-location", endpoint: "cell:///SemanticLocation", keypath: "semanticLocation.state.currentLabels"),
                GoalEvidenceSource(sourceID: "semantic-time", endpoint: "cell:///SemanticTime", keypath: "semanticTime.state.currentLabels")
            ],
            predicate: GoalPredicate(
                kind: "all",
                all: [
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-location", expected: "work"),
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-time", expected: "lunch")
                ]
            )
        )
    }

    private func networkDefinition() -> GoalDefinition {
        GoalDefinition(
            goalID: "goal.scaffold.network.contact-haven",
            purposeRef: "purpose://scaffold.maintain-haven-contact",
            title: "Keep scaffold in contact with HAVEN",
            description: "Satisfied while health checks keep succeeding.",
            lifecycle: .continuous,
            evaluatorKind: .networkPing,
            evidenceSources: [
                GoalEvidenceSource(sourceID: "staging-health", endpoint: "cell://staging/health")
            ],
            predicate: GoalPredicate(kind: "network-ping", sourceID: "staging-health"),
            statusPolicy: GoalStatusPolicy(atRiskAfterFailures: 1, missedAfterFailures: 3)
        )
    }
}
