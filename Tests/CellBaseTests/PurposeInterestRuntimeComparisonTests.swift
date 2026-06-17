// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class PurposeInterestRuntimeComparisonTests: XCTestCase {
    func testWeightedSignalRanksThroughGraphRuntimeEvidence() async {
        let rankings = await PerspectiveMatchingScenarioSupport.rankedPurposes(
            interests: [
                "interest.feedback",
                "interest.documentation",
                "interest.onboarding"
            ],
            method: .weightedSignal,
            includeChallengeDecoys: true
        )

        let top = rankings.first
        XCTAssertEqual(top?.purposeId, "purpose.share")
        XCTAssertEqual(
            Set(top?.matchedInterestRefs ?? []),
            Set([
                "interest.feedback",
                "interest.documentation",
                "interest.onboarding"
            ])
        )
        XCTAssertGreaterThan(top?.score ?? 0.0, 0.0)
    }

    func testRuntimeComparisonArtifactReportsMethodCostsWithoutHardThresholds() async throws {
        let artifact = try await PerspectiveMatchingScenarioSupport.buildRuntimeComparisonArtifact(
            iterations: 2,
            methods: [.weightedSignal, .cosine],
            includeChallengeCases: true
        )

        XCTAssertEqual(artifact.schemaVersion, "1.0")
        XCTAssertTrue(artifact.notes.contains { $0.contains("sparse cosine") })
        XCTAssertEqual(artifact.measurements.map(\.method), [.weightedSignal, .cosine])

        for measurement in artifact.measurements {
            XCTAssertEqual(measurement.iterations, 2)
            XCTAssertGreaterThan(measurement.caseCount, 0)
            XCTAssertGreaterThan(measurement.rankingCount, 0)
            XCTAssertGreaterThan(measurement.totalElapsedNanoseconds, 0)
            XCTAssertGreaterThan(measurement.averageNanosecondsPerCase, 0.0)
        }
    }

    func testRuntimeComparisonMarkdownNamesSignalAndSparseCosine() async throws {
        let artifact = try await PerspectiveMatchingScenarioSupport.buildRuntimeComparisonArtifact(
            iterations: 1,
            methods: [.weightedSignal, .cosine],
            includeChallengeCases: false
        )
        let markdown = PerspectiveMatchingScenarioSupport.markdownRuntimeComparisonReport(artifact)

        XCTAssertTrue(markdown.contains("# Purpose/Interest Runtime Comparison"))
        XCTAssertTrue(markdown.contains("weightedSignal"))
        XCTAssertTrue(markdown.contains("cosine"))
        XCTAssertTrue(markdown.contains("not an external word-vector or embedding baseline yet"))
    }

    func testLargeConferenceDatasetRanksExpectedPurposesWithWeightedSignal() async {
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceProfiles.count, 20)
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceTextCases.count, 24)

        let summary = await PerspectiveMatchingScenarioSupport.evaluateConferenceDataset(method: .weightedSignal)
        let misses = summary.caseResults
            .filter { $0.topPurposeID != $0.expectedPurposeID }
            .map { "\($0.caseID): expected=\($0.expectedPurposeID) top=\($0.topPurposeID ?? "nil")" }

        XCTAssertEqual(summary.totalCases, PerspectiveMatchingScenarioSupport.conferenceTextCases.count)
        XCTAssertEqual(summary.top1Correct, summary.totalCases, "Unexpected weightedSignal misses: \(misses.joined(separator: ", "))")
        XCTAssertEqual(summary.top3Correct, summary.totalCases)
    }

    func testConferenceRuntimeComparisonUsesLargerDataset() async {
        let artifact = await PerspectiveMatchingScenarioSupport.buildConferenceRuntimeComparisonArtifact(
            iterations: 2,
            methods: [.weightedSignal, .cosine]
        )

        XCTAssertTrue(artifact.notes.contains { $0.contains("Conference dataset") })
        XCTAssertEqual(artifact.measurements.map(\.method), [.weightedSignal, .cosine])
        for measurement in artifact.measurements {
            XCTAssertEqual(measurement.caseCount, PerspectiveMatchingScenarioSupport.conferenceTextCases.count)
            XCTAssertGreaterThan(measurement.rankingCount, 0)
            XCTAssertGreaterThan(measurement.averageNanosecondsPerCase, 0)
        }
    }

    func testLayeredConferenceScenariosCarryLocalVariablesIntoNextMatchLayer() async throws {
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceLayeredScenarios.count, 8)

        for scenario in PerspectiveMatchingScenarioSupport.conferenceLayeredScenarios {
            let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceLayeredScenario(scenario)

            XCTAssertEqual(result.firstLayerPurposeID, scenario.firstLayerPurposeID, scenario.caseID)
            XCTAssertEqual(result.selectedCandidateID, scenario.expectedCandidateID, scenario.caseID)
            XCTAssertEqual(result.selectedPurposeID, scenario.expectedPurposeID, scenario.caseID)
            XCTAssertEqual(result.carriedLocalVariables, scenario.localVariables, scenario.caseID)
            XCTAssertGreaterThan(result.layer1HitCount, 0, scenario.caseID)
            XCTAssertGreaterThan(result.layer2HitCount, 0, scenario.caseID)
            XCTAssertGreaterThan(result.layer3HitCount, 0, scenario.caseID)
        }
    }

    func testLayeredConferenceScenarioRejectsCandidateWhenLocalVariablesDoNotMatch() async throws {
        var scenario = try XCTUnwrap(PerspectiveMatchingScenarioSupport.conferenceLayeredScenarios.first)
        scenario.localVariables["consent.intros"] = "false"

        let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceLayeredScenario(scenario)

        XCTAssertEqual(result.firstLayerPurposeID, scenario.firstLayerPurposeID)
        XCTAssertNil(result.selectedCandidateID)
        XCTAssertNil(result.selectedPurposeID)
        XCTAssertEqual(result.carriedLocalVariables["consent.intros"], "false")
    }
}
