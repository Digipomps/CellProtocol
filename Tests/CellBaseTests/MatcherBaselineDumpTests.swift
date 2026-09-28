// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

/// Measurement instrument, not a test of behaviour.
///
/// Writes the full ranked output of both flat weighted-sum scenarios to a file,
/// so the same run can be made before and after a change to the matcher and the
/// two files compared byte for byte. Without this, "the tests still pass" only
/// says the top-1 result survived — these scenarios' tests assert the winner and
/// a couple of invariants, not the score vector.
///
/// Inert unless `MATCHER_DUMP_PATH` is set, so ordinary test runs are unaffected.
final class MatcherBaselineDumpTests: XCTestCase {

    func testWriteMatcherDump() async throws {
        guard let path = ProcessInfo.processInfo.environment["MATCHER_DUMP_PATH"],
              !path.isEmpty else {
            throw XCTSkip("MATCHER_DUMP_PATH not set")
        }

        var lines = [String]()

        // --- Form A, instance 1: restaurant -------------------------------
        lines.append("## restaurant.full-rankings")
        for profile in PerspectiveMatchingScenarioSupport.restaurantUserPurposeProfiles
            .sorted(by: { $0.purposeID < $1.purposeID }) {
            let ranked = await PerspectiveMatchingScenarioSupport.restaurantRecommendations(
                forUserPurposeID: profile.purposeID,
                maxResults: Int.max
            )
            lines.append("profile \(profile.purposeID)")
            for recommendation in ranked {
                lines.append(
                    String(
                        format: "  %@ | %@ | %.17g | %@",
                        recommendation.restaurantID,
                        recommendation.advertisedPurposeID,
                        recommendation.score,
                        recommendation.matchedInterestRefs.joined(separator: ",")
                    )
                )
            }
        }

        lines.append("## restaurant.case-results")
        let caseResults = await PerspectiveMatchingScenarioSupport.evaluateRestaurantRecommendationCases()
        for result in caseResults.sorted(by: { $0.caseID < $1.caseID }) {
            lines.append(
                String(
                    format: "  %@ | %@ | %@ | %.17g | %@ | %@",
                    result.caseID,
                    result.topRestaurantID ?? "nil",
                    result.topAdvertisedPurposeID ?? "nil",
                    result.topScore,
                    result.matchedInterestRefs.joined(separator: ","),
                    result.passed ? "pass" : "FAIL"
                )
            )
        }

        // --- Form A, instance 2: conference swarm -------------------------
        lines.append("## conference-swarm.case-results")
        let swarm = try await PerspectiveMatchingScenarioSupport.evaluateConferenceSwarm(iterations: 1)
        lines.append("  top1Correct=\(swarm.top1Correct) top3Correct=\(swarm.top3Correct)")
        lines.append(String(format: "  meanReciprocalRank=%.17g", swarm.meanReciprocalRank))
        lines.append("  privacyViolationCount=\(swarm.privacyViolationCount)")
        for result in swarm.caseResults.sorted(by: { $0.caseID < $1.caseID }) {
            lines.append(
                String(
                    format: "  %@ | raw=%@ | sel=%@ | %.17g | rank=%@ | raw#=%d acc#=%d | %@",
                    result.caseID,
                    result.rawTopOpportunityID ?? "nil",
                    result.selectedOpportunityID ?? "nil",
                    result.selectedScore,
                    result.finalRankOfExpected.map(String.init) ?? "nil",
                    result.rawRankingCount,
                    result.acceptedRankingCount,
                    result.matchedInterestRefs.joined(separator: ",")
                )
            )
        }

        let text = lines.joined(separator: "\n") + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("matcher dump written to \(path) (\(lines.count) lines)")
    }
}
