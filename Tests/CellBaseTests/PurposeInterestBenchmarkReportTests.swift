// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class PurposeInterestBenchmarkReportTests: XCTestCase {
    func testMarkdownBenchmarkReportSummarizesCuratedAndChallengeFindings() async throws {
        let artifact = try await PerspectiveMatchingScenarioSupport.buildBenchmarkArtifact()
        let markdown = PerspectiveMatchingScenarioSupport.markdownReport(artifact)

        XCTAssertTrue(markdown.contains("# Purpose/Interest Matching Benchmark"))
        XCTAssertTrue(markdown.contains("## Curated"))
        XCTAssertTrue(markdown.contains("## Challenge"))
        XCTAssertTrue(markdown.contains("challenge.work-post-share-vs-feedback-burst"))
        XCTAssertTrue(markdown.contains("weighted=`purpose.share`"))
        XCTAssertTrue(markdown.contains("cosine=`purpose.feedback-burst`"))
    }

    func testMarkdownBenchmarkReportIncludesLocalTuningGuardrails() async throws {
        let tuning = ScenarioWeightTuningConfig(
            tuningId: "test.local-tuning",
            description: "Local overlay for benchmark report.",
            adjustments: [
                ScenarioWeightTuningAdjustment(
                    purposeId: "purpose.feedback-burst",
                    interestId: "interest.onboarding",
                    operation: .set,
                    value: 0.8
                )
            ]
        )
        let artifact = try await PerspectiveMatchingScenarioSupport.buildBenchmarkArtifact(tuning: tuning)
        let markdown = PerspectiveMatchingScenarioSupport.markdownReport(artifact)

        XCTAssertTrue(markdown.contains("## Local Tuning"))
        XCTAssertTrue(markdown.contains("test.local-tuning"))
        XCTAssertTrue(markdown.contains("purpose.human-equal-worth"))
        XCTAssertTrue(markdown.contains("purpose.net-positive-contribution"))
    }
}
