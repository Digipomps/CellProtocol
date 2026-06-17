// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class RestaurantPurposeRecommendationTests: XCTestCase {
    func testRestaurantDatasetSeparatesAdvertisedPurposesFromUserPurposes() {
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.restaurantAdvertisedPurposes.count, 12)
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.restaurantUserPurposeProfiles.count, 6)
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.restaurantRecommendationCases.count, 6)

        let advertisedIDs = PerspectiveMatchingScenarioSupport.restaurantAdvertisedPurposes.map(\.matchPurposeID)
        XCTAssertEqual(Set(advertisedIDs).count, advertisedIDs.count)

        let userPurposeIDs = PerspectiveMatchingScenarioSupport.restaurantUserPurposeProfiles.map(\.purposeID)
        XCTAssertEqual(Set(userPurposeIDs).count, userPurposeIDs.count)
    }

    func testRestaurantRecommendationCasesMatchExpectedAdvertisedPurpose() async {
        let results = await PerspectiveMatchingScenarioSupport.evaluateRestaurantRecommendationCases()
        let failures = results
            .filter { !$0.passed }
            .map {
                "\($0.caseID): expected=\($0.expectedRestaurantID)/\($0.expectedAdvertisedPurposeID) top=\($0.topRestaurantID ?? "nil")/\($0.topAdvertisedPurposeID ?? "nil")"
            }

        XCTAssertEqual(results.count, PerspectiveMatchingScenarioSupport.restaurantRecommendationCases.count)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        for result in results {
            XCTAssertGreaterThan(result.topScore, 0.0, result.caseID)
            XCTAssertGreaterThanOrEqual(result.matchedInterestRefs.count, 3, result.caseID)
        }
    }

    func testSameUserGetsDifferentRestaurantsForDifferentPurposes() async throws {
        let teamDinnerRecommendations = await PerspectiveMatchingScenarioSupport.restaurantRecommendations(
            forUserPurposeID: "purpose.user.team-dinner",
            maxResults: 1
        )
        let quietMealRecommendations = await PerspectiveMatchingScenarioSupport.restaurantRecommendations(
            forUserPurposeID: "purpose.user.quiet-seasonal-meal",
            maxResults: 1
        )
        let plantSafeRecommendations = await PerspectiveMatchingScenarioSupport.restaurantRecommendations(
            forUserPurposeID: "purpose.user.plant-based-safe",
            maxResults: 1
        )
        let teamDinner = try XCTUnwrap(teamDinnerRecommendations.first)
        let quietMeal = try XCTUnwrap(quietMealRecommendations.first)
        let plantSafe = try XCTUnwrap(plantSafeRecommendations.first)

        XCTAssertEqual(teamDinner.restaurantID, "restaurant.brostein")
        XCTAssertEqual(teamDinner.advertisedPurposeID, "purpose.team-dinner")
        XCTAssertEqual(quietMeal.restaurantID, "restaurant.nordlys")
        XCTAssertEqual(quietMeal.advertisedPurposeID, "purpose.calm-conversation")
        XCTAssertEqual(plantSafe.restaurantID, "restaurant.gronn")
        XCTAssertEqual(plantSafe.advertisedPurposeID, "purpose.dietary-safe-plant-based")
    }
}
