// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class ClaimDefinitionTests: XCTestCase {
    func testWireVocabularyMatchesTextReliabilityContract() {
        XCTAssertEqual(ClaimType.factual.rawValue, "factual")
        XCTAssertEqual(ClaimType.causal.rawValue, "causal")
        XCTAssertEqual(ClaimType.normative.rawValue, "normative")
        XCTAssertEqual(ClaimType.predictive.rawValue, "predictive")
        XCTAssertEqual(ClaimType.statistical.rawValue, "statistical")
        XCTAssertEqual(ClaimType.projectCapability.rawValue, "project_capability")

        XCTAssertEqual(ClaimStrength.assertive.rawValue, "assertive")
        XCTAssertEqual(ClaimStrength.moderated.rawValue, "moderated")
        XCTAssertEqual(ClaimStrength.speculative.rawValue, "speculative")

        XCTAssertEqual(ClaimSourceAuditStatus.supported.rawValue, "supported")
        XCTAssertEqual(ClaimSourceAuditStatus.partlySupported.rawValue, "partly_supported")
        XCTAssertEqual(ClaimSourceAuditStatus.contradicted.rawValue, "contradicted")
        XCTAssertEqual(ClaimSourceAuditStatus.sourceMissing.rawValue, "source_missing")
        XCTAssertEqual(ClaimSourceAuditStatus.notFound.rawValue, "not_found")
        XCTAssertEqual(ClaimSourceAuditStatus.notCheckable.rawValue, "not_checkable")
        XCTAssertEqual(ClaimSourceAuditStatus.textOnlyNotAudited.rawValue, "text_only_not_audited")
        XCTAssertEqual(ClaimSourceAuditStatus.needsExternalSourceAudit.rawValue, "needs_external_source_audit")
        XCTAssertEqual(ClaimSourceAuditStatus.sourceCueWithoutAnchor.rawValue, "source_cue_without_anchor")
    }

    func testClaimDefinitionEncodeDecodeRoundTrip() throws {
        let claim = ClaimDefinition(
            claimID: "claim.market.bottom-up-estimate",
            statement: "Bottom-up market estimate reaches 120 MNOK within 3 years",
            claimType: .statistical,
            strength: .moderated,
            quote: "vi estimerer 120 MNOK innen tre år",
            isInferred: false,
            sourceRefs: ["https://example.org/marketdata"],
            purposeRef: "purpose://value-and-commons",
            goalID: "goal.market.bottom-up-estimate",
            supports: [
                ClaimSupportNode(
                    supportID: "support.assumption.conversion-rate",
                    kind: .assumption,
                    statement: "Conversion rate stays above 2 percent",
                    sourceAuditStatus: .needsExternalSourceAudit,
                    confidence: 0.6
                ),
                ClaimSupportNode(
                    supportID: "support.counter.competitor-pricing",
                    kind: .counterargument,
                    statement: "Competitor pricing undercuts the assumed price point",
                    sourceRefs: ["https://example.org/competitor"],
                    sourceAuditStatus: .partlySupported
                )
            ],
            composition: .countered(
                base: .allOf([
                    .leaf("claim.market.segment-size"),
                    .leaf("claim.market.price-point")
                ]),
                counters: [
                    ClaimCounter(role: .rebuts, composition: .leaf("claim.market.competitor-pricing"))
                ]
            ),
            tags: ["investor-case"]
        )

        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(ClaimDefinition.self, from: data)

        XCTAssertEqual(decoded, claim)
        XCTAssertEqual(decoded.schema, "haven.claim-definition.v0")
    }

    func testClaimDefinitionDecodesStableWireShape() throws {
        let json = """
        {
          "schema": "haven.claim-definition.v0",
          "claimID": "claim.team.delivery-track-record",
          "statement": "The team has shipped comparable systems before",
          "claimType": "project_capability",
          "strength": "assertive",
          "isInferred": false,
          "sourceRefs": [],
          "supports": [
            {
              "supportID": "support.evidence.shipped-product",
              "kind": "evidence",
              "statement": "Product X shipped in 2024",
              "sourceRefs": ["https://example.org/product-x"],
              "sourceAuditStatus": "needs_external_source_audit"
            }
          ],
          "composition": {
            "type": "anyOf",
            "children": [
              { "type": "claim", "claimRef": "claim.team.product-x" },
              { "type": "claim", "claimRef": "claim.team.product-y" }
            ]
          },
          "tags": []
        }
        """
        let decoded = try JSONDecoder().decode(ClaimDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.claimType, .projectCapability)
        XCTAssertEqual(decoded.supports.first?.kind, .evidence)
        XCTAssertEqual(decoded.supports.first?.sourceAuditStatus, .needsExternalSourceAudit)
        XCTAssertEqual(decoded.composition?.leafClaimRefs, ["claim.team.product-x", "claim.team.product-y"])
    }

    func testEvaluateCompositionFallsBackToOwnClaimID() {
        let claim = ClaimDefinition(
            claimID: "claim.standalone",
            statement: "Standalone claim",
            claimType: .factual
        )
        let context = ClaimCompositionEvaluationContext(
            evaluatedAt: 1_000.0,
            supportRecords: [
                ClaimSupportRecord(
                    claimRef: "claim.standalone",
                    sourceAuditStatus: .supported,
                    checkedAt: 900.0
                )
            ]
        )

        let result = claim.evaluateComposition(in: context)

        XCTAssertEqual(result.status, .supported)
        XCTAssertEqual(result.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.supportedClaimRefs, ["claim.standalone"])
    }

    func testSupportNodeClampsConfidence() {
        let node = ClaimSupportNode(
            supportID: "support.q",
            kind: .qualifier,
            statement: "Only valid for the Nordic market",
            confidence: 1.7
        )
        XCTAssertEqual(node.confidence, 1.0)
    }
}
