// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class PurposeInterestChallengeExperimentTests: XCTestCase {
    func testChallengeCasesRespectMethodSpecificTopExpectations() async throws {
        for challengeCase in PerspectiveMatchingScenarioSupport.challengeCases {
            guard case let .methodSpecificTopPurpose(expectations) = challengeCase.expectation else {
                continue
            }

            for (method, expectedPurposeID) in expectations {
                let rankings = await PerspectiveMatchingScenarioSupport.rankedPurposes(
                    interests: challengeCase.interests,
                    method: method,
                    includeChallengeDecoys: true
                )
                let top = try XCTUnwrap(rankings.first, "No rankings for \(challengeCase.caseID) \(method.rawValue)")
                let rankingSummary = rankings
                    .map { "\($0.purposeId)=\($0.score)" }
                    .joined(separator: ", ")

                XCTAssertEqual(
                    top.purposeId,
                    expectedPurposeID,
                    "Unexpected top purpose for \(challengeCase.caseID) \(method.rawValue). Rankings: \(rankingSummary)"
                )
            }
        }
    }

    func testChallengeNegativeCasesDoNotProduceConfidentMatches() async throws {
        let weightedFloor = try await PerspectiveMatchingScenarioSupport.challengeConfidenceFloor(method: .weightedRaw)
        let cosineFloor = try await PerspectiveMatchingScenarioSupport.challengeConfidenceFloor(method: .cosine)

        for challengeCase in PerspectiveMatchingScenarioSupport.challengeCases {
            guard case .noConfidentMatch = challengeCase.expectation else {
                continue
            }

            let weightedTop = await confidentTopPurposeID(
                for: challengeCase.interests,
                method: .weightedRaw,
                floor: weightedFloor
            )
            let cosineTop = await confidentTopPurposeID(
                for: challengeCase.interests,
                method: .cosine,
                floor: cosineFloor
            )

            XCTAssertNil(weightedTop, "Expected no confident weighted match for \(challengeCase.caseID), got \(String(describing: weightedTop))")
            XCTAssertNil(cosineTop, "Expected no confident cosine match for \(challengeCase.caseID), got \(String(describing: cosineTop))")
        }
    }

    func testChallengeSetContainsAtLeastOneWeightedVsCosineDisagreement() async {
        var disagreements = 0

        for challengeCase in PerspectiveMatchingScenarioSupport.challengeCases {
            guard case .methodSpecificTopPurpose = challengeCase.expectation else {
                continue
            }

            let weighted = await PerspectiveMatchingScenarioSupport.rankedPurposes(
                interests: challengeCase.interests,
                method: .weightedRaw,
                includeChallengeDecoys: true
            ).first?.purposeId

            let cosine = await PerspectiveMatchingScenarioSupport.rankedPurposes(
                interests: challengeCase.interests,
                method: .cosine,
                includeChallengeDecoys: true
            ).first?.purposeId

            if weighted != cosine {
                disagreements += 1
            }
        }

        XCTAssertGreaterThanOrEqual(disagreements, 1, "Expected at least one method disagreement in challenge set.")
    }

    func testLocalTuningCanShiftWeightedTopWithoutMutatingSharedProfiles() async {
        let interests = [
            "interest.feedback",
            "interest.documentation",
            "interest.onboarding"
        ]
        let tuning = ScenarioWeightTuningConfig(
            tuningId: "test.local-feedback-burst",
            description: "Treat onboarding feedback as strong local evidence.",
            adjustments: [
                ScenarioWeightTuningAdjustment(
                    purposeId: "purpose.feedback-burst",
                    interestId: "interest.onboarding",
                    operation: .set,
                    value: 0.8
                )
            ]
        )

        let globalTop = await PerspectiveMatchingScenarioSupport.rankedPurposes(
            interests: interests,
            method: .weightedRaw,
            includeChallengeDecoys: true
        ).first?.purposeId
        let tunedTop = await PerspectiveMatchingScenarioSupport.rankedPurposes(
            interests: interests,
            method: .weightedRaw,
            includeChallengeDecoys: true,
            tuning: tuning
        ).first?.purposeId
        let globalTopAfterTuning = await PerspectiveMatchingScenarioSupport.rankedPurposes(
            interests: interests,
            method: .weightedRaw,
            includeChallengeDecoys: true
        ).first?.purposeId

        XCTAssertEqual(globalTop, "purpose.share")
        XCTAssertEqual(tunedTop, "purpose.feedback-burst")
        XCTAssertEqual(globalTopAfterTuning, "purpose.share")
    }

    private func confidentTopPurposeID(
        for interests: [String],
        method: ScenarioRankingMethod,
        floor: Double
    ) async -> String? {
        let rankings = await PerspectiveMatchingScenarioSupport.rankedPurposes(
            interests: interests,
            method: method,
            includeChallengeDecoys: true
        )
        guard let top = rankings.first else {
            return nil
        }
        guard top.score >= floor else {
            return nil
        }
        guard Set(top.matchedInterestRefs).count >= 2 else {
            return nil
        }
        return top.purposeId
    }
}
