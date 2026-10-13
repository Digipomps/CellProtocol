// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// The completeness flag must tell a finished search from one that ran out of
/// time. Only one of HAVEN's four matchers did that before 2026-09-24.
///
/// The expired case is tested through `aggregate` with a constructed
/// `MatchResult`, not by calling `match` with `ttl: 0` and hoping the clock has
/// moved past a zero deadline before the first check. That kind of test is
/// green in practice and unstable in principle.
final class InterestPurposeWeightedSumTests: XCTestCase {

    // Every number here is exactly representable, so the expected sums are exact.
    private let candidates = [
        InterestPurposeCandidate(matchPurposeID: "p.a", interestWeights: ["i.x": 0.5, "i.y": 0.25]),
        InterestPurposeCandidate(matchPurposeID: "p.b", interestWeights: ["i.x": 0.25]),
    ]

    func testFinishedTraversalIsCompleteAndScoresEveryCandidate() async throws {
        let result = try await InterestPurposeWeightedSum.match(
            requesterInterestWeights: ["i.x": 1.0, "i.y": 0.5],
            candidates: candidates,
            tokenPrefix: "test.complete"
        )

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.incompleteInterestIDs, [])
        XCTAssertEqual(result.matches.map(\.matchPurposeID), ["p.a", "p.b"])
        XCTAssertEqual(result.matches[0].score, 0.625)   // 1.0 × 0.5 + 0.5 × 0.25
        XCTAssertEqual(result.matches[1].score, 0.25)    // 1.0 × 0.25
        XCTAssertEqual(result.matches[0].matchedInterestRefs, ["i.x", "i.y"])
        XCTAssertEqual(result.matches[1].matchedInterestRefs, ["i.x"])
    }

    func testExpiredTraversalMarksResultIncompleteButKeepsWhatWasFound() {
        let result = InterestPurposeWeightedSum.aggregate(
            candidates: candidates,
            traversals: [
                traversal("i.x", weight: 1.0, hits: [hit("p.a", 0.5), hit("p.b", 0.25)], expired: false),
                traversal("i.y", weight: 0.5, hits: [hit("p.a", 0.25)], expired: true),
            ]
        )

        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.incompleteInterestIDs, ["i.y"])
        // The flag does not hide the partial answer; the caller decides what it is worth.
        XCTAssertEqual(result.matches.map(\.matchPurposeID), ["p.a", "p.b"])
        XCTAssertEqual(result.matches[0].score, 0.625)
    }

    func testIncompleteInterestsAreReportedSortedAndOnce() {
        let result = InterestPurposeWeightedSum.aggregate(
            candidates: candidates,
            traversals: [
                traversal("i.y", weight: 0.5, hits: [], expired: true),
                traversal("i.x", weight: 1.0, hits: [], expired: true),
            ]
        )

        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.incompleteInterestIDs, ["i.x", "i.y"])
        XCTAssertEqual(result.matches.map(\.score), [0.0, 0.0])
    }

    // MARK: - Fixtures

    private func traversal(
        _ interestID: String, weight: Double, hits: [MatchHit], expired: Bool
    ) -> InterestPurposeWeightedSum.InterestTraversal {
        InterestPurposeWeightedSum.InterestTraversal(
            interestID: interestID,
            requesterWeight: weight,
            result: MatchResult(
                token: "test.\(interestID)",
                hits: hits,
                visitedRefs: [],
                accumulatedEvidence: [],
                elapsedSeconds: 0,
                expired: expired,
                maxDepthReached: 1
            )
        )
    }

    private func hit(_ purposeID: String, _ edgeWeight: Double) -> MatchHit {
        let from = WeightedGraphNodeRef(kind: .interest, reference: "interest", name: "interest")
        let to = WeightedGraphNodeRef(kind: .purpose, reference: purposeID, name: purposeID)
        let evidence = MatchEvidence(
            relationship: .purposes,
            from: from,
            to: to,
            edgeWeight: edgeWeight,
            requestedWeight: 0.5,
            tolerance: .greatestFiniteMagnitude,
            contribution: 1.0,
            accumulatedScore: 1.0,
            depth: 1
        )
        return MatchHit(ref: purposeID, node: to, score: 1.0, depth: 1, path: [from, to], evidence: [evidence])
    }
}
