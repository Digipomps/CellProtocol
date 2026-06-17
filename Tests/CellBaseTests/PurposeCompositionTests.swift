// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class PurposeCompositionTests: XCTestCase {
    func testAllOfReportsPartialProgressAndMissingPurposeRefs() {
        let composition = PurposeComposition.allOf([
            .leaf("purpose.restaurant.find-quiet-place"),
            .leaf("purpose.restaurant.reserve-table"),
            .leaf("purpose.restaurant.handle-dietary-needs")
        ])
        let context = PurposeCompositionEvaluationContext(
            evaluatedAt: 1_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.find-quiet-place",
                    resolvedAt: 900.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.reserve-table",
                    status: .failed,
                    resolvedAt: 950.0
                )
            ]
        )

        let result = composition.evaluate(in: context)

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.score, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.satisfiedPurposeRefs, ["purpose.restaurant.find-quiet-place"])
        XCTAssertEqual(
            result.missingPurposeRefs,
            [
                "purpose.restaurant.reserve-table",
                "purpose.restaurant.handle-dietary-needs"
            ]
        )
        XCTAssertEqual(result.blockingIndex, 1)
        XCTAssertEqual(result.blockingReason, "requiredChildUnsatisfied")
    }

    func testAnyOfAndAtLeastCanExpressAlternativesInsideRequiredPurposeSet() {
        let composition = PurposeComposition.allOf([
            .anyOf([
                .leaf("purpose.restaurant.seasonal-menu"),
                .leaf("purpose.restaurant.chef-menu")
            ]),
            .atLeast(
                requiredCount: 2,
                children: [
                    .leaf("purpose.restaurant.quiet-table"),
                    .leaf("purpose.restaurant.plant-based-safe"),
                    .leaf("purpose.restaurant.local-food")
                ]
            )
        ])
        let context = PurposeCompositionEvaluationContext(
            evaluatedAt: 2_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.chef-menu",
                    resolvedAt: 1_800.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.quiet-table",
                    resolvedAt: 1_850.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.plant-based-safe",
                    resolvedAt: 1_900.0
                )
            ]
        )

        let result = composition.evaluate(in: context)

        XCTAssertEqual(result.status, .satisfied)
        XCTAssertEqual(result.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(
            result.satisfiedPurposeRefs,
            [
                "purpose.restaurant.chef-menu",
                "purpose.restaurant.quiet-table",
                "purpose.restaurant.plant-based-safe"
            ]
        )
        XCTAssertTrue(result.missingPurposeRefs.isEmpty)
    }

    func testSequenceRequiresSatisfiedChildrenInChronologicalOrder() {
        let composition = PurposeComposition.sequence([
            .leaf("purpose.restaurant.choose-shortlist"),
            .leaf("purpose.restaurant.reserve-table"),
            .leaf("purpose.restaurant.complete-meal")
        ])
        let outOfOrderContext = PurposeCompositionEvaluationContext(
            evaluatedAt: 3_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.choose-shortlist",
                    resolvedAt: 2_500.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.reserve-table",
                    resolvedAt: 2_400.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.complete-meal",
                    resolvedAt: 2_900.0
                )
            ]
        )
        let inOrderContext = PurposeCompositionEvaluationContext(
            evaluatedAt: 3_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.choose-shortlist",
                    resolvedAt: 2_300.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.reserve-table",
                    resolvedAt: 2_500.0
                ),
                PurposeResolutionRecord(
                    purposeRef: "purpose.restaurant.complete-meal",
                    resolvedAt: 2_900.0
                )
            ]
        )

        let outOfOrderResult = composition.evaluate(in: outOfOrderContext)
        let inOrderResult = composition.evaluate(in: inOrderContext)

        XCTAssertEqual(outOfOrderResult.status, .partial)
        XCTAssertEqual(outOfOrderResult.score, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(outOfOrderResult.blockingIndex, 1)
        XCTAssertEqual(outOfOrderResult.blockingReason, "outOfOrderResolution")
        XCTAssertEqual(inOrderResult.status, .satisfied)
        XCTAssertEqual(inOrderResult.completedAt, 2_900.0)
    }

    func testPurposeCompositionRoundTripsThroughPurposeJSON() throws {
        let composition = PurposeComposition.sequence([
            .allOf([
                .leaf("purpose.restaurant.pick-candidate"),
                .leaf("purpose.restaurant.invite-guests")
            ]),
            .leaf("purpose.restaurant.reserve-table")
        ])
        let purpose = Purpose(
            name: "purpose.user.group-restaurant-evening",
            description: "Plan and complete a restaurant evening for a group.",
            composition: composition
        )

        let data = try JSONEncoder().encode(purpose)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(Purpose.self, from: data)

        XCTAssertTrue(json.contains("\"composition\""))
        XCTAssertTrue(json.contains("\"type\":\"sequence\""))
        XCTAssertEqual(decoded.composition, composition)
    }

    func testPurposeWithoutExplicitCompositionEvaluatesAsLeafPurpose() {
        let purpose = Purpose(
            name: "purpose.restaurant.drop-in-lunch",
            description: "Find a fast lunch option nearby."
        )
        let missingResult = purpose.evaluateComposition(
            in: PurposeCompositionEvaluationContext(
                evaluatedAt: 4_000.0
            )
        )
        let satisfiedResult = purpose.evaluateComposition(
            in: PurposeCompositionEvaluationContext(
                evaluatedAt: 4_000.0,
                purposeResolutions: [
                    PurposeResolutionRecord(
                        purposeRef: "purpose.restaurant.drop-in-lunch",
                        resolvedAt: 3_900.0
                    )
                ]
            )
        )

        XCTAssertEqual(missingResult.status, .unsatisfied)
        XCTAssertEqual(missingResult.missingPurposeRefs, ["purpose.restaurant.drop-in-lunch"])
        XCTAssertEqual(satisfiedResult.status, .satisfied)
        XCTAssertEqual(satisfiedResult.satisfiedPurposeRefs, ["purpose.restaurant.drop-in-lunch"])
    }
}
