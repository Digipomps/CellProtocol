// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class ClaimCompositionTests: XCTestCase {
    private func context(
        _ records: [(ref: String, status: ClaimSourceAuditStatus, confidence: Double?)],
        policy: ClaimScorePolicy = .conservative
    ) -> ClaimCompositionEvaluationContext {
        ClaimCompositionEvaluationContext(
            evaluatedAt: 1_000.0,
            supportRecords: records.map {
                ClaimSupportRecord(
                    claimRef: $0.ref,
                    sourceAuditStatus: $0.status,
                    confidence: $0.confidence,
                    checkedAt: 900.0
                )
            },
            scorePolicy: policy
        )
    }

    func testAllOfUsesWeakestLinkAndReportsMissingClaims() {
        let composition = ClaimComposition.allOf([
            .leaf("claim.premise.a"),
            .leaf("claim.premise.b")
        ])
        let result = composition.evaluate(
            in: context([("claim.premise.a", .supported, nil)])
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.supportedClaimRefs, ["claim.premise.a"])
        XCTAssertEqual(result.missingClaimRefs, ["claim.premise.b"])
        XCTAssertEqual(result.blockingIndex, 1)
        XCTAssertEqual(result.blockingReason, "requiredChildUnsupported")
    }

    func testAllOfContradictedPremiseMakesParentUnsupportedNotContradicted() {
        let composition = ClaimComposition.allOf([
            .leaf("claim.premise.a"),
            .leaf("claim.premise.b")
        ])
        let result = composition.evaluate(
            in: context([
                ("claim.premise.a", .supported, nil),
                ("claim.premise.b", .contradicted, nil)
            ])
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.contradictedClaimRefs, ["claim.premise.b"])
        XCTAssertEqual(result.blockingIndex, 1)
        XCTAssertEqual(result.blockingReason, "premiseContradicted")
    }

    func testAnyOfTakesStrongestAlternative() {
        let composition = ClaimComposition.anyOf([
            .leaf("claim.route.top-down"),
            .leaf("claim.route.bottom-up")
        ])
        let result = composition.evaluate(
            in: context([
                ("claim.route.top-down", .sourceMissing, nil),
                ("claim.route.bottom-up", .supported, nil)
            ])
        )

        XCTAssertEqual(result.status, .supported)
        XCTAssertEqual(result.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.missingClaimRefs, [])
        XCTAssertNil(result.blockingReason)
    }

    func testAtLeastQuorumScoresTopContributions() {
        let composition = ClaimComposition.atLeast(
            requiredCount: 2,
            children: [
                .leaf("claim.line.a"),
                .leaf("claim.line.b"),
                .leaf("claim.line.c")
            ]
        )
        let satisfied = composition.evaluate(
            in: context([
                ("claim.line.a", .supported, nil),
                ("claim.line.b", .supported, nil)
            ])
        )
        XCTAssertEqual(satisfied.status, .supported)
        XCTAssertEqual(satisfied.score, 1.0, accuracy: 0.0001)

        let partial = composition.evaluate(
            in: context([("claim.line.a", .supported, nil)])
        )
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.score, 0.5, accuracy: 0.0001)
        XCTAssertEqual(partial.blockingReason, "tooFewChildrenSupported")
    }

    func testRebutReducesScore() {
        let composition = ClaimComposition.countered(
            base: .leaf("claim.main"),
            counters: [
                ClaimCounter(role: .rebuts, composition: .leaf("claim.counter"))
            ]
        )
        let result = composition.evaluate(
            in: context([
                ("claim.main", .supported, nil),
                ("claim.counter", .partlySupported, nil)
            ])
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.score, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.blockingReason, "counteredSupportReduced")
    }

    func testDominantRebutContradictsClaim() {
        let composition = ClaimComposition.countered(
            base: .leaf("claim.main"),
            counters: [
                ClaimCounter(role: .rebuts, composition: .leaf("claim.counter"))
            ]
        )
        let result = composition.evaluate(
            in: context([
                ("claim.main", .partlySupported, nil),
                ("claim.counter", .supported, nil)
            ])
        )

        XCTAssertEqual(result.status, .contradicted)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.blockingReason, "rebuttalDominates")
    }

    func testUndercutDiscountsWithoutContradicting() {
        let composition = ClaimComposition.countered(
            base: .leaf("claim.main"),
            counters: [
                ClaimCounter(role: .undercuts, composition: .leaf("claim.undercutter"))
            ]
        )
        let result = composition.evaluate(
            in: context([
                ("claim.main", .supported, nil),
                ("claim.undercutter", .supported, nil)
            ])
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.blockingReason, "counteredSupportEliminated")

        let halfUndercut = composition.evaluate(
            in: context([
                ("claim.main", .supported, nil),
                ("claim.undercutter", .partlySupported, nil)
            ])
        )
        XCTAssertEqual(halfUndercut.status, .partial)
        XCTAssertEqual(halfUndercut.score, 0.5, accuracy: 0.0001)
    }

    func testCounterLedgersAreNotMergedIntoParent() {
        let composition = ClaimComposition.countered(
            base: .leaf("claim.main"),
            counters: [
                ClaimCounter(role: .rebuts, composition: .leaf("claim.counter"))
            ]
        )
        let result = composition.evaluate(
            in: context([
                ("claim.main", .supported, nil),
                ("claim.counter", .supported, nil)
            ])
        )

        XCTAssertEqual(result.supportedClaimRefs, ["claim.main"])
        XCTAssertEqual(result.childResults.count, 2)
        XCTAssertEqual(result.childResults[1].supportedClaimRefs, ["claim.counter"])
    }

    func testLeafConfidenceScalesScore() {
        let result = ClaimComposition.leaf("claim.main").evaluate(
            in: context([("claim.main", .supported, 0.8)])
        )
        XCTAssertEqual(result.status, .supported)
        XCTAssertEqual(result.score, 0.8, accuracy: 0.0001)
    }

    func testUnauditedEvidenceGivesNoSupportByDefault() {
        let result = ClaimComposition.leaf("claim.main").evaluate(
            in: context([("claim.main", .needsExternalSourceAudit, nil)])
        )
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.blockingReason, "sourceNotAudited")
        XCTAssertEqual(result.missingClaimRefs, ["claim.main"])
    }

    func testLatestSupportRecordBeforeEvaluationTimeWins() {
        let evaluationContext = ClaimCompositionEvaluationContext(
            evaluatedAt: 1_000.0,
            supportRecords: [
                ClaimSupportRecord(claimRef: "claim.main", sourceAuditStatus: .contradicted, checkedAt: 800.0),
                ClaimSupportRecord(claimRef: "claim.main", sourceAuditStatus: .supported, checkedAt: 900.0),
                ClaimSupportRecord(claimRef: "claim.main", sourceAuditStatus: .contradicted, checkedAt: 1_100.0)
            ]
        )
        let result = ClaimComposition.leaf("claim.main").evaluate(in: evaluationContext)

        XCTAssertEqual(result.status, .supported)
    }

    func testLeafClaimRefsIncludesCounterClaims() {
        let composition = ClaimComposition.countered(
            base: .allOf([.leaf("claim.a"), .leaf("claim.b")]),
            counters: [
                ClaimCounter(role: .undercuts, composition: .leaf("claim.c"))
            ]
        )
        XCTAssertEqual(composition.leafClaimRefs, ["claim.a", "claim.b", "claim.c"])
    }

    func testCompositionEncodeDecodeRoundTrip() throws {
        let composition = ClaimComposition.countered(
            base: .atLeast(
                requiredCount: 2,
                children: [
                    .leaf("claim.a", name: "First line"),
                    .anyOf([.leaf("claim.b"), .leaf("claim.c")]),
                    .allOf([.leaf("claim.d")])
                ]
            ),
            counters: [
                ClaimCounter(role: .rebuts, composition: .leaf("claim.e")),
                ClaimCounter(role: .undercuts, composition: .leaf("claim.f"))
            ]
        )

        let data = try JSONEncoder().encode(composition)
        let decoded = try JSONDecoder().decode(ClaimComposition.self, from: data)

        XCTAssertEqual(decoded, composition)
    }

    func testCompositionDecodesStableWireShape() throws {
        let json = """
        {
          "type": "countered",
          "base": { "type": "claim", "claimRef": "claim.main" },
          "counters": [
            {
              "role": "undercuts",
              "composition": { "type": "claim", "claimRef": "claim.attack" }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ClaimComposition.self, from: Data(json.utf8))

        guard case .countered(let base, let counters) = decoded else {
            return XCTFail("Expected countered composition")
        }
        XCTAssertEqual(base.leafClaimRefs, ["claim.main"])
        XCTAssertEqual(counters.count, 1)
        XCTAssertEqual(counters.first?.role, .undercuts)
    }

    func testEvaluationIsDeterministic() {
        let composition = ClaimComposition.countered(
            base: .allOf([.leaf("claim.a"), .leaf("claim.b")]),
            counters: [
                ClaimCounter(role: .rebuts, composition: .leaf("claim.c"))
            ]
        )
        let evaluationContext = context([
            ("claim.a", .supported, 0.9),
            ("claim.b", .partlySupported, nil),
            ("claim.c", .partlySupported, 0.4)
        ])

        let first = composition.evaluate(in: evaluationContext)
        let second = composition.evaluate(in: evaluationContext)

        XCTAssertEqual(first, second)
    }

    func testScorePolicyOverrideChangesScoreNotStatus() {
        let permissive = ClaimScorePolicy(unauditedScore: 0.5)
        let result = ClaimComposition.leaf("claim.main").evaluate(
            in: context([("claim.main", .notCheckable, nil)], policy: permissive)
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.score, 0.5, accuracy: 0.0001)
    }
}
