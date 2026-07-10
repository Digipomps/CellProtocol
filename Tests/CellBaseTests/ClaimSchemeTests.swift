// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class ClaimSchemeTests: XCTestCase {
    func testEverySchemeKindHasCriticalQuestions() {
        for kind in ClaimSchemeKind.allCases {
            XCTAssertFalse(
                ClaimSchemeCatalog.criticalQuestions(for: kind).isEmpty,
                "\(kind) has no critical questions"
            )
            XCTAssertFalse(
                ClaimSchemeCatalog.premiseRoles(for: kind).isEmpty,
                "\(kind) has no premise roles"
            )
        }
    }

    func testExpertOpinionCatalogIsStable() {
        let cqs = ClaimSchemeCatalog.criticalQuestions(for: .expertOpinion)
        XCTAssertEqual(
            cqs.map(\.cqID),
            [
                "expert-opinion.expertise",
                "expert-opinion.field",
                "expert-opinion.assertion",
                "expert-opinion.trustworthiness",
                "expert-opinion.consistency",
                "expert-opinion.evidence"
            ]
        )
    }

    func testCriticalQuestionIDsAreGloballyUnique() {
        var seen = Set<String>()
        for kind in ClaimSchemeKind.allCases {
            for cq in ClaimSchemeCatalog.criticalQuestions(for: kind) {
                XCTAssertFalse(seen.contains(cq.cqID), "duplicate cqID \(cq.cqID)")
                seen.insert(cq.cqID)
            }
        }
    }

    func testInstantiationAutoPopulatesUnexaminedQuestions() {
        let instance = ClaimSchemeInstance(
            instanceID: "scheme.jorn-erik.expert",
            kind: .expertOpinion,
            claimRef: "claim.local-too-weak"
        )
        XCTAssertEqual(instance.criticalQuestions.count, 6)
        XCTAssertTrue(instance.criticalQuestions.allSatisfy { $0.status == .unexamined })
        XCTAssertEqual(instance.schema, "haven.claim-scheme.v0")
    }

    func testExplicitCriticalQuestionsArePreserved() {
        let instance = ClaimSchemeInstance(
            instanceID: "scheme.x",
            kind: .sign,
            claimRef: "claim.y",
            criticalQuestions: [
                CriticalQuestionState(cqID: "sign.reliability", question: "reliable?", status: .answered)
            ]
        )
        XCTAssertEqual(instance.criticalQuestions.count, 1)
        XCTAssertEqual(instance.criticalQuestions.first?.status, .answered)
    }

    func testEvaluateAllUnexaminedIsOpen() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .causeToEffect, claimRef: "claim.c"
        )
        let result = instance.evaluate()
        XCTAssertEqual(result.status, .open)
        XCTAssertEqual(result.applicableCQCount, 3)
        XCTAssertEqual(result.answeredCQCount, 0)
        XCTAssertEqual(result.completeness, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.unexaminedCQs.count, 3)
        XCTAssertTrue(result.challengedCQs.isEmpty)
    }

    func testEvaluateExcludesNotApplicableFromDenominator() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .expertOpinion, claimRef: "claim.c",
            criticalQuestions: [
                CriticalQuestionState(cqID: "expert-opinion.expertise", question: "q", status: .answered),
                CriticalQuestionState(cqID: "expert-opinion.field", question: "q", status: .answered),
                CriticalQuestionState(cqID: "expert-opinion.assertion", question: "q", status: .notApplicable),
                CriticalQuestionState(cqID: "expert-opinion.trustworthiness", question: "q", status: .unexamined)
            ]
        )
        let result = instance.evaluate()
        XCTAssertEqual(result.applicableCQCount, 3)
        XCTAssertEqual(result.answeredCQCount, 2)
        XCTAssertEqual(result.completeness, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.status, .open)
    }

    func testEvaluateAllAnsweredIsWellSupported() {
        let cqs = ClaimSchemeCatalog.criticalQuestions(for: .sign).map {
            CriticalQuestionState(cqID: $0.cqID, question: $0.question, status: .answered)
        }
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .sign, claimRef: "claim.c", criticalQuestions: cqs
        )
        let result = instance.evaluate()
        XCTAssertEqual(result.status, .wellSupported)
        XCTAssertEqual(result.completeness, 1.0, accuracy: 0.0001)
    }

    func testChallengedQuestionMakesStatusChallenged() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .analogy, claimRef: "claim.c",
            criticalQuestions: [
                CriticalQuestionState(cqID: "analogy.similarity", question: "q", status: .answered),
                CriticalQuestionState(cqID: "analogy.differences", question: "q", status: .challenged),
                CriticalQuestionState(cqID: "analogy.counter-analogy", question: "q", status: .unexamined)
            ]
        )
        let result = instance.evaluate()
        XCTAssertEqual(result.status, .challenged)
        XCTAssertEqual(result.challengedCQs.map(\.cqID), ["analogy.differences"])
    }

    func testDeducedSubtasksTagClaimRef() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .sign, claimRef: "claim.market"
        )
        let subtasks = instance.deducedSubtasks()
        XCTAssertEqual(subtasks.count, 2)
        XCTAssertTrue(subtasks.allSatisfy { $0.hasPrefix("[claim.market] ") })
    }

    func testUndercutCountersUseChallengedQuestions() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .expertOpinion, claimRef: "claim.c",
            criticalQuestions: [
                CriticalQuestionState(cqID: "expert-opinion.trustworthiness", question: "biased?", status: .challenged, addressedByClaimRef: "claim.bias-evidence"),
                CriticalQuestionState(cqID: "expert-opinion.field", question: "q", status: .answered)
            ]
        )
        let counters = instance.undercutCounters()
        XCTAssertEqual(counters.count, 1)
        XCTAssertEqual(counters.first?.role, .undercuts)
        XCTAssertEqual(counters.first?.composition.leafClaimRefs, ["claim.bias-evidence"])
    }

    func testApplyingChallengesReturnsBaseWhenNoneChallenged() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .sign, claimRef: "claim.c"
        )
        let base = ClaimComposition.leaf("claim.c")
        XCTAssertEqual(instance.applyingChallenges(to: base), base)
    }

    // The integration proof: a challenged critical question, routed through the
    // undercut bridge, actually discounts the claim's score in the existing
    // ClaimComposition evaluation.
    func testChallengedQuestionUndercutsScoreInCompositionEvaluation() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .expertOpinion, claimRef: "claim.local-too-weak",
            criticalQuestions: [
                CriticalQuestionState(
                    cqID: "expert-opinion.field",
                    question: "expert in claim-extraction specifically?",
                    status: .challenged,
                    addressedByClaimRef: "claim.no-extraction-benchmark"
                )
            ]
        )
        let composition = instance.applyingChallenges(to: .leaf("claim.local-too-weak"))

        let context = ClaimCompositionEvaluationContext(
            evaluatedAt: 1_000.0,
            supportRecords: [
                ClaimSupportRecord(claimRef: "claim.local-too-weak", sourceAuditStatus: .supported, checkedAt: 900.0),
                ClaimSupportRecord(claimRef: "claim.no-extraction-benchmark", sourceAuditStatus: .supported, checkedAt: 900.0)
            ]
        )
        let result = composition.evaluate(in: context)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0001)
    }

    func testSchemeInstanceEncodeDecodeRoundTrip() throws {
        let instance = ClaimSchemeInstance(
            instanceID: "scheme.1",
            kind: .practicalReasoning,
            claimRef: "claim.ship-market-module",
            slotBindings: ["goal": "claim.investors-need-numbers", "action": "claim.build-market-module"],
            criticalQuestions: [
                CriticalQuestionState(cqID: "practical-reasoning.alternatives", question: "alt?", status: .challenged, addressedByClaimRef: "claim.founder-authored-number", note: "layer-1 claim without layer-3 module"),
                CriticalQuestionState(cqID: "practical-reasoning.feasibility", question: "possible?", status: .unexamined)
            ]
        )
        let data = try JSONEncoder().encode(instance)
        let decoded = try JSONDecoder().decode(ClaimSchemeInstance.self, from: data)
        XCTAssertEqual(decoded, instance)
    }

    func testSchemeInstanceDecodesStableWireShape() throws {
        let json = """
        {
          "schema": "haven.claim-scheme.v0",
          "instanceID": "s1",
          "kind": "expert-opinion",
          "claimRef": "claim.c",
          "slotBindings": { "source": "Jørn Erik" },
          "criticalQuestions": [
            { "cqID": "expert-opinion.field", "question": "q", "status": "not-applicable" },
            { "cqID": "expert-opinion.evidence", "question": "q", "status": "challenged" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ClaimSchemeInstance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .expertOpinion)
        XCTAssertEqual(decoded.criticalQuestions.first?.status, .notApplicable)
        let result = decoded.evaluate()
        XCTAssertEqual(result.status, .challenged)
        XCTAssertEqual(result.applicableCQCount, 1)
    }

    func testEvaluationIsDeterministic() {
        let instance = ClaimSchemeInstance(
            instanceID: "s", kind: .negativeConsequences, claimRef: "claim.c",
            criticalQuestions: [
                CriticalQuestionState(cqID: "negative-consequences.likelihood", question: "q", status: .answered),
                CriticalQuestionState(cqID: "negative-consequences.evidence", question: "q", status: .unexamined),
                CriticalQuestionState(cqID: "negative-consequences.counterbalance", question: "q", status: .challenged)
            ]
        )
        XCTAssertEqual(instance.evaluate(), instance.evaluate())
    }
}
