// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import HavenPerspectiveSchemas
import PurposeInterestBenchmarkSupport
@testable import CellBase

final class PurposeInterestScenarioRankingTests: XCTestCase {
    func testScenarioFixturesRankExpectedPurposeAcrossPhases() async throws {
        for exampleName in PerspectiveMatchingScenarioSupport.exampleNames {
            let document = try PerspectiveMatchingScenarioSupport.loadDocument(named: exampleName)

            for phase in PerspectiveScenarioPhase.allCases {
                let snapshot = PerspectiveMatchingScenarioSupport.snapshot(for: phase, in: document)
                let expectedPurposeID = try XCTUnwrap(
                    PerspectiveMatchingScenarioSupport.expectedTopPurposeID(for: snapshot),
                    "Missing expected purpose in \(exampleName) \(phase.rawValue)"
                )

                let scores = await PerspectiveMatchingScenarioSupport.score(snapshot: snapshot)
                let top = try XCTUnwrap(scores.first, "No scores returned for \(exampleName) \(phase.rawValue)")
                let scoreSummary = scores
                    .map { "\($0.purposeId)=\($0.explain.rawScore)" }
                    .joined(separator: ", ")

                XCTAssertEqual(
                    top.purposeId,
                    expectedPurposeID,
                    "Unexpected top purpose for \(exampleName) \(phase.rawValue). Scores: \(scoreSummary)"
                )
            }
        }
    }

    func testTopRankIncludesExplainableInterestEvidence() async throws {
        for exampleName in PerspectiveMatchingScenarioSupport.exampleNames {
            let document = try PerspectiveMatchingScenarioSupport.loadDocument(named: exampleName)

            for phase in PerspectiveScenarioPhase.allCases {
                let snapshot = PerspectiveMatchingScenarioSupport.snapshot(for: phase, in: document)
                let scores = await PerspectiveMatchingScenarioSupport.score(snapshot: snapshot)
                let top = try XCTUnwrap(scores.first, "No top score for \(exampleName) \(phase.rawValue)")

                XCTAssertFalse(top.explain.topEdges.isEmpty, "Missing explain edges for \(exampleName) \(phase.rawValue)")

                let matchedInterestRefs = Set(top.explain.topEdges.map { $0.edge.toNode.id })
                    .intersection(snapshot.interests)
                XCTAssertFalse(
                    matchedInterestRefs.isEmpty,
                    "Expected top result evidence to overlap active interests for \(exampleName) \(phase.rawValue)"
                )
            }
        }
    }
}
