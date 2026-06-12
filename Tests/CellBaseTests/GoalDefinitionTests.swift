// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class GoalDefinitionTests: XCTestCase {
    func testCompositeSemanticLocationAndTimeGoalRoundTrips() throws {
        let definition = GoalDefinition(
            goalID: "goal.personal.location.work-at-lunch",
            purposeRef: "purpose://personal.be-at-work-for-lunch",
            title: "Be at work during lunch",
            description: "Satisfied when the represented person is within their owner-defined Work semantic location during their owner-defined lunch time window.",
            lifecycle: .continuous,
            evaluatorKind: .composite,
            metric: "semantic_location_and_time_match",
            target: "work && lunch",
            timeframe: "owner-defined-lunch-window",
            evidenceSources: [
                GoalEvidenceSource(
                    sourceID: "semantic-location",
                    endpoint: "cell:///SemanticLocation",
                    keypath: "semanticLocation.state.currentLabels",
                    requiredGrant: "location.semantic.read",
                    freshnessSeconds: 300,
                    visibility: .ownerOnly
                ),
                GoalEvidenceSource(
                    sourceID: "semantic-time",
                    endpoint: "cell:///SemanticTime",
                    keypath: "semanticTime.state.currentLabels",
                    requiredGrant: "time.semantic.read",
                    freshnessSeconds: 60,
                    visibility: .statusOnly
                )
            ],
            predicate: GoalPredicate(
                kind: "all",
                all: [
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-location", expected: "work"),
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-time", expected: "lunch")
                ]
            ),
            tolerance: GoalTolerance(locationAccuracyMeters: 100, timeSkewSeconds: 300, confidenceFloor: 0.8),
            statusPolicy: GoalStatusPolicy(approachingWindowSeconds: 900, missedAfterSeconds: 1800, retryIntervalSeconds: 300),
            helperCells: [
                GoalHelperCellRef(
                    endpoint: "cell:///Perspective",
                    purposeRef: "purpose://personal.context.reweight",
                    actionKeypath: "perspective.applyEvent",
                    title: "Reweight current context"
                )
            ],
            privacy: GoalPrivacyPolicy(
                rawEvidenceVisibility: .ownerOnly,
                publishableStatuses: [.unknown, .approaching, .satisfied, .missed],
                doNotExportRawLocation: true,
                retentionSeconds: 3600
            ),
            tags: ["location", "time", "owner-scoped"]
        )

        let decoded = try roundTrip(definition)

        XCTAssertEqual(decoded.schema, GoalDefinition.schemaID)
        XCTAssertEqual(decoded.goalID, definition.goalID)
        XCTAssertEqual(decoded.evaluatorKind, .composite)
        XCTAssertEqual(decoded.evidenceSources.map(\.sourceID), ["semantic-location", "semantic-time"])
        XCTAssertEqual(decoded.predicate?.all.count, 2)
        XCTAssertEqual(decoded.tolerance?.locationAccuracyMeters, 100)
        XCTAssertEqual(decoded.privacy.doNotExportRawLocation, true)
    }

    func testNetworkGoalEvaluationRoundTripsAndTerminalSemantics() throws {
        let definition = GoalDefinition(
            goalID: "goal.scaffold.network.contact-haven",
            purposeRef: "purpose://scaffold.maintain-haven-contact",
            title: "Keep scaffold in contact with HAVEN",
            description: "Satisfied while the scaffold receives a ping or health response within the configured timeout.",
            lifecycle: .continuous,
            evaluatorKind: .networkPing,
            metric: "consecutive_healthcheck_failures",
            target: "< 3",
            evidenceSources: [
                GoalEvidenceSource(
                    sourceID: "staging-health",
                    endpoint: "cell://staging/health",
                    requiredGrant: "network.health.read",
                    freshnessSeconds: 60,
                    visibility: .statusOnly
                )
            ],
            predicate: GoalPredicate(kind: "network-ping", sourceID: "staging-health", operation: "responds-within", expected: "3000ms"),
            tolerance: GoalTolerance(networkTimeoutMilliseconds: 3000),
            statusPolicy: GoalStatusPolicy(atRiskAfterFailures: 1, missedAfterFailures: 3, retryIntervalSeconds: 30),
            helperCells: [
                GoalHelperCellRef(endpoint: "cell:///BridgeDiagnostics", purposeRef: "purpose://diagnose-bridge"),
                GoalHelperCellRef(endpoint: "cell:///AgentReview", purposeRef: "purpose://review-remediation")
            ],
            privacy: GoalPrivacyPolicy(rawEvidenceVisibility: .statusOnly)
        )
        let evaluation = GoalEvaluation(
            goalID: definition.goalID,
            purposeRef: definition.purposeRef,
            status: .atRisk,
            progress: 0.66,
            confidence: 0.9,
            evaluatedAt: "2026-06-11T09:30:00Z",
            evidence: [
                GoalEvaluationEvidence(
                    sourceID: "staging-health",
                    status: .fresh,
                    summary: "One failed health check, below missed threshold.",
                    observedAt: "2026-06-11T09:29:58Z",
                    valueSummary: "consecutiveFailures=1",
                    confidence: 0.9
                )
            ],
            nextCheckAt: "2026-06-11T09:30:30Z",
            emittedEvents: ["goal.evaluation.updated"]
        )

        let decodedDefinition = try roundTrip(definition)
        let decodedEvaluation = try roundTrip(evaluation)

        XCTAssertEqual(decodedDefinition.statusPolicy?.missedAfterFailures, 3)
        XCTAssertEqual(decodedEvaluation.schema, GoalEvaluation.schemaID)
        XCTAssertEqual(decodedEvaluation.status, .atRisk)
        XCTAssertFalse(decodedEvaluation.isSatisfied)
        XCTAssertFalse(decodedEvaluation.isTerminal)
        XCTAssertEqual(decodedEvaluation.evidence.first?.valueSummary, "consecutiveFailures=1")
    }

    func testHumanConfirmationGoalCapturesButtonAsMeasurableOutcome() throws {
        let definition = GoalDefinition(
            goalID: "goal.agent.review.confirm",
            purposeRef: "purpose://agent.local.review-before-action",
            title: "Wait for human approval",
            description: "Satisfied only when the represented person explicitly confirms the pending agent action.",
            lifecycle: .deadline,
            evaluatorKind: .humanConfirmation,
            metric: "confirmation_event",
            target: "confirmed",
            timeframe: "15_minutes",
            evidenceSources: [
                GoalEvidenceSource(
                    sourceID: "confirmation-event",
                    endpoint: "cell:///HumanConfirmation",
                    topic: "goal.confirmation",
                    eventType: "goal.confirmed",
                    requiredGrant: "confirmation.read",
                    freshnessSeconds: 900,
                    visibility: .statusOnly
                )
            ],
            predicate: GoalPredicate(kind: "event-seen", sourceID: "confirmation-event", operation: "equals", expected: "goal.confirmed"),
            helperCells: [
                GoalHelperCellRef(endpoint: "cell:///HumanConfirmation", actionKeypath: "confirmation.request", title: "Ask for confirmation")
            ]
        )
        let waiting = GoalEvaluation(
            goalID: definition.goalID,
            purposeRef: definition.purposeRef,
            status: .active,
            progress: 0,
            confidence: 1,
            evaluatedAt: "2026-06-11T09:40:00Z",
            missing: ["human-confirmation"],
            nextCheckAt: "2026-06-11T09:41:00Z"
        )
        let confirmed = GoalEvaluation(
            goalID: definition.goalID,
            purposeRef: definition.purposeRef,
            status: .satisfied,
            progress: 1,
            confidence: 1,
            evaluatedAt: "2026-06-11T09:41:00Z",
            evidence: [
                GoalEvaluationEvidence(sourceID: "confirmation-event", status: .fresh, summary: "Requester pressed confirm.")
            ],
            emittedEvents: ["goal.satisfied"]
        )

        XCTAssertEqual(try roundTrip(definition).evaluatorKind, .humanConfirmation)
        XCTAssertEqual(try roundTrip(waiting).missing, ["human-confirmation"])
        XCTAssertTrue(try roundTrip(confirmed).isSatisfied)
        XCTAssertTrue(try roundTrip(confirmed).isTerminal)
    }

    func testPerspectiveGoalFieldsCanBecomeGoalDefinition() throws {
        let definition = GoalDefinition.fromPerspectiveFields(
            goalID: "goal.sdg.climate.member-mobility-emissions-intensity",
            purposeID: "purpose.sdg.climate.member-mobility-decarbonization",
            description: "Reduce emissions intensity for member transport.",
            metric: "kgCO2e_per_member_km",
            baseline: "0.42",
            target: "<=0.34",
            timeframe: "2026-01-01/2026-12-31",
            dataSource: "chronicle://transport-emissions",
            evidenceRule: "monthly_average <= 0.34",
            indicatorRefs: ["13.2.2"],
            incentiveOnly: true
        )
        let decoded = try roundTrip(definition)

        XCTAssertEqual(decoded.purposeRef, "purpose.sdg.climate.member-mobility-decarbonization")
        XCTAssertEqual(decoded.metric, "kgCO2e_per_member_km")
        XCTAssertEqual(decoded.baseline, "0.42")
        XCTAssertEqual(decoded.target, "<=0.34")
        XCTAssertEqual(decoded.timeframe, "2026-01-01/2026-12-31")
        XCTAssertEqual(decoded.evidenceSources.first?.keypath, "chronicle://transport-emissions")
        XCTAssertEqual(decoded.predicate?.expected, "monthly_average <= 0.34")
        XCTAssertEqual(decoded.tags, ["13.2.2"])
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
