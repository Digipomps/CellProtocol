// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class PurposeInterestScenarioExperimentTests: XCTestCase {
    func testWeightedRawScenarioBenchmarkIsNotWorseThanCosineBaseline() async throws {
        let weighted = try await PerspectiveMatchingScenarioSupport.evaluate(method: .weightedRaw)
        let cosine = try await PerspectiveMatchingScenarioSupport.evaluate(method: .cosine)

        XCTAssertGreaterThanOrEqual(
            weighted.top1Correct,
            cosine.top1Correct,
            comparisonSummary(weighted: weighted, cosine: cosine)
        )
        XCTAssertGreaterThanOrEqual(
            weighted.top3Correct,
            cosine.top3Correct,
            comparisonSummary(weighted: weighted, cosine: cosine)
        )
        XCTAssertGreaterThanOrEqual(
            weighted.meanReciprocalRank + 1e-12,
            cosine.meanReciprocalRank,
            comparisonSummary(weighted: weighted, cosine: cosine)
        )
    }

    func testCosineBaselineStillFindsExpectedPurposeWithinTop3ForCuratedBenchmark() async throws {
        let cosine = try await PerspectiveMatchingScenarioSupport.evaluate(method: .cosine)

        XCTAssertEqual(
            cosine.top3Correct,
            cosine.totalCases,
            methodSummary(cosine)
        )
    }

    private func comparisonSummary(
        weighted: ScenarioEvaluationSummary,
        cosine: ScenarioEvaluationSummary
    ) -> String {
        """
        weighted: \(methodSummary(weighted))
        cosine: \(methodSummary(cosine))
        """
    }

    private func methodSummary(_ summary: ScenarioEvaluationSummary) -> String {
        let caseSummary = summary.caseResults
            .map { result in
                "\(result.caseID): expected=\(result.expectedPurposeID), top=\(result.topPurposeID ?? "nil"), rr=\(result.reciprocalRank)"
            }
            .joined(separator: " | ")

        return "\(summary.method.rawValue) top1=\(summary.top1Correct)/\(summary.totalCases), top3=\(summary.top3Correct)/\(summary.totalCases), mrr=\(summary.meanReciprocalRank) :: \(caseSummary)"
    }
}
