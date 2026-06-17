// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

public struct RestaurantAdvertisedPurpose: Codable, Sendable {
    public var restaurantID: String
    public var restaurantName: String
    public var purposeID: String
    public var description: String
    public var interestWeights: [String: Double]

    public init(
        restaurantID: String,
        restaurantName: String,
        purposeID: String,
        description: String,
        interestWeights: [String: Double]
    ) {
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.purposeID = purposeID
        self.description = description
        self.interestWeights = interestWeights
    }

    public var matchPurposeID: String {
        "\(restaurantID).\(purposeID)"
    }
}

public struct RestaurantUserPurposeProfile: Codable, Sendable {
    public var userID: String
    public var purposeID: String
    public var description: String
    public var interestWeights: [String: Double]

    public init(
        userID: String,
        purposeID: String,
        description: String,
        interestWeights: [String: Double]
    ) {
        self.userID = userID
        self.purposeID = purposeID
        self.description = description
        self.interestWeights = interestWeights
    }
}

public struct RestaurantRecommendationCase: Codable, Sendable {
    public var caseID: String
    public var userPurposeID: String
    public var expectedRestaurantID: String
    public var expectedAdvertisedPurposeID: String

    public init(
        caseID: String,
        userPurposeID: String,
        expectedRestaurantID: String,
        expectedAdvertisedPurposeID: String
    ) {
        self.caseID = caseID
        self.userPurposeID = userPurposeID
        self.expectedRestaurantID = expectedRestaurantID
        self.expectedAdvertisedPurposeID = expectedAdvertisedPurposeID
    }
}

public struct RestaurantRecommendation: Codable, Sendable, Equatable {
    public var restaurantID: String
    public var restaurantName: String
    public var advertisedPurposeID: String
    public var matchPurposeID: String
    public var score: Double
    public var matchedInterestRefs: [String]

    public init(
        restaurantID: String,
        restaurantName: String,
        advertisedPurposeID: String,
        matchPurposeID: String,
        score: Double,
        matchedInterestRefs: [String]
    ) {
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.advertisedPurposeID = advertisedPurposeID
        self.matchPurposeID = matchPurposeID
        self.score = score
        self.matchedInterestRefs = matchedInterestRefs
    }
}

public struct RestaurantRecommendationCaseResult: Codable, Sendable {
    public var caseID: String
    public var expectedRestaurantID: String
    public var expectedAdvertisedPurposeID: String
    public var topRestaurantID: String?
    public var topAdvertisedPurposeID: String?
    public var topScore: Double
    public var matchedInterestRefs: [String]
    public var passed: Bool

    public init(
        caseID: String,
        expectedRestaurantID: String,
        expectedAdvertisedPurposeID: String,
        topRestaurantID: String?,
        topAdvertisedPurposeID: String?,
        topScore: Double,
        matchedInterestRefs: [String],
        passed: Bool
    ) {
        self.caseID = caseID
        self.expectedRestaurantID = expectedRestaurantID
        self.expectedAdvertisedPurposeID = expectedAdvertisedPurposeID
        self.topRestaurantID = topRestaurantID
        self.topAdvertisedPurposeID = topAdvertisedPurposeID
        self.topScore = topScore
        self.matchedInterestRefs = matchedInterestRefs
        self.passed = passed
    }
}

public extension PerspectiveMatchingScenarioSupport {
    static let restaurantAdvertisedPurposes: [RestaurantAdvertisedPurpose] = [
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.nordlys",
            restaurantName: "Nordlys",
            purposeID: "purpose.calm-conversation",
            description: "Quiet seasonal Nordic food for conversation-heavy meals.",
            interestWeights: [
                "interest.restaurant.quiet-conversation": 0.95,
                "interest.restaurant.low-noise": 0.90,
                "interest.restaurant.nordic-cooking": 0.70,
                "interest.restaurant.seasonal-menu": 0.75,
                "interest.restaurant.reservation-timing": 0.65,
                "interest.restaurant.hospitality": 0.70
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.nordlys",
            restaurantName: "Nordlys",
            purposeID: "purpose.seasonal-local-food",
            description: "Local ingredients and seasonal menus with a Nordic profile.",
            interestWeights: [
                "interest.restaurant.local-food": 0.90,
                "interest.restaurant.seasonal-menu": 0.95,
                "interest.restaurant.nordic-cooking": 0.85,
                "interest.restaurant.special-occasion": 0.40
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.brostein",
            restaurantName: "Brostein",
            purposeID: "purpose.team-dinner",
            description: "Reliable group dinners with shared plates and enough structure for teams.",
            interestWeights: [
                "interest.restaurant.team-bonding": 0.95,
                "interest.restaurant.group-seating": 0.90,
                "interest.restaurant.shared-plates": 0.80,
                "interest.restaurant.quiet-conversation": 0.75,
                "interest.restaurant.reservation-timing": 0.70,
                "interest.restaurant.budget-friendly": 0.55,
                "interest.restaurant.dietary-safety": 0.60
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.brostein",
            restaurantName: "Brostein",
            purposeID: "purpose.after-work-networking",
            description: "After-work venue for informal networking, craft drinks and shared snacks.",
            interestWeights: [
                "interest.restaurant.after-work": 0.85,
                "interest.restaurant.craft-drinks": 0.80,
                "interest.restaurant.networking": 0.75,
                "interest.restaurant.shared-plates": 0.60
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.gronn",
            restaurantName: "Gronn",
            purposeID: "purpose.dietary-safe-plant-based",
            description: "Plant-based menu with clear allergen handling and dietary safety.",
            interestWeights: [
                "interest.restaurant.vegetarian": 0.95,
                "interest.restaurant.vegan": 0.90,
                "interest.restaurant.gluten-free": 0.85,
                "interest.restaurant.dietary-safety": 0.95,
                "interest.restaurant.accessibility": 0.60
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.gronn",
            restaurantName: "Gronn",
            purposeID: "purpose.plant-based-discovery",
            description: "Seasonal plant-based food for people who want discovery without risk.",
            interestWeights: [
                "interest.restaurant.vegetarian": 0.85,
                "interest.restaurant.vegan": 0.80,
                "interest.restaurant.local-food": 0.65,
                "interest.restaurant.seasonal-menu": 0.75,
                "interest.restaurant.special-occasion": 0.45
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.sjomat",
            restaurantName: "Sjomat",
            purposeID: "purpose.seafood-experience",
            description: "Seafood-focused local experience by the water.",
            interestWeights: [
                "interest.restaurant.seafood": 0.95,
                "interest.restaurant.waterfront-view": 0.80,
                "interest.restaurant.local-food": 0.75,
                "interest.restaurant.special-occasion": 0.75,
                "interest.restaurant.hospitality": 0.60
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.kantine",
            restaurantName: "Kantine",
            purposeID: "purpose.quick-work-lunch",
            description: "Fast, affordable work lunch with low planning overhead.",
            interestWeights: [
                "interest.restaurant.quick-service": 0.95,
                "interest.restaurant.budget-friendly": 0.90,
                "interest.restaurant.low-effort-planning": 0.75,
                "interest.restaurant.accessibility": 0.50,
                "interest.restaurant.local-food": 0.40
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.familiebord",
            restaurantName: "Familiebord",
            purposeID: "purpose.family-friendly-meal",
            description: "Family meal with children, dietary safety and predictable logistics.",
            interestWeights: [
                "interest.restaurant.family-time": 0.95,
                "interest.restaurant.children": 0.95,
                "interest.restaurant.dietary-safety": 0.80,
                "interest.restaurant.budget-friendly": 0.75,
                "interest.restaurant.group-seating": 0.70,
                "interest.restaurant.low-effort-planning": 0.80
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.omakase",
            restaurantName: "Omakase",
            purposeID: "purpose.special-occasion-tasting",
            description: "Tasting-menu restaurant for focused special occasions.",
            interestWeights: [
                "interest.restaurant.tasting-menu": 0.95,
                "interest.restaurant.special-occasion": 0.95,
                "interest.restaurant.quiet-conversation": 0.65,
                "interest.restaurant.reservation-timing": 0.80,
                "interest.restaurant.seafood": 0.60
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.solsiden",
            restaurantName: "Solsiden",
            purposeID: "purpose.outdoor-weekend-meal",
            description: "Low-effort weekend meal with outdoor seating and a waterfront view.",
            interestWeights: [
                "interest.restaurant.outdoor-seating": 0.95,
                "interest.restaurant.waterfront-view": 0.95,
                "interest.restaurant.low-effort-planning": 0.70,
                "interest.restaurant.family-time": 0.55,
                "interest.restaurant.local-food": 0.50
            ]
        ),
        RestaurantAdvertisedPurpose(
            restaurantID: "restaurant.mezze",
            restaurantName: "Mezze",
            purposeID: "purpose.inclusive-group-sharing",
            description: "Inclusive shared-table meal with vegetarian options and group hospitality.",
            interestWeights: [
                "interest.restaurant.shared-plates": 0.95,
                "interest.restaurant.vegetarian": 0.85,
                "interest.restaurant.dietary-safety": 0.80,
                "interest.restaurant.group-seating": 0.85,
                "interest.restaurant.hospitality": 0.75,
                "interest.restaurant.budget-friendly": 0.60
            ]
        )
    ]

    static let restaurantUserPurposeProfiles: [RestaurantUserPurposeProfile] = [
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.team-dinner",
            description: "Find a restaurant for team bonding with conversation, logistics and dietary safety.",
            interestWeights: [
                "interest.restaurant.team-bonding": 0.95,
                "interest.restaurant.quiet-conversation": 0.85,
                "interest.restaurant.dietary-safety": 0.80,
                "interest.restaurant.group-seating": 0.80,
                "interest.restaurant.reservation-timing": 0.75,
                "interest.restaurant.budget-friendly": 0.65,
                "interest.restaurant.local-food": 0.40
            ]
        ),
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.quiet-seasonal-meal",
            description: "Prefer calm conversation, low noise and seasonal local food.",
            interestWeights: [
                "interest.restaurant.quiet-conversation": 0.95,
                "interest.restaurant.low-noise": 0.90,
                "interest.restaurant.local-food": 0.75,
                "interest.restaurant.seasonal-menu": 0.80,
                "interest.restaurant.reservation-timing": 0.60
            ]
        ),
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.family-low-effort",
            description: "Find a low-effort family meal with children, budget and dietary safety handled.",
            interestWeights: [
                "interest.restaurant.family-time": 0.95,
                "interest.restaurant.children": 0.95,
                "interest.restaurant.dietary-safety": 0.75,
                "interest.restaurant.budget-friendly": 0.80,
                "interest.restaurant.low-effort-planning": 0.85
            ]
        ),
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.celebration-discovery",
            description: "Choose a special occasion place with tasting menu, reservation quality and some quiet.",
            interestWeights: [
                "interest.restaurant.special-occasion": 0.95,
                "interest.restaurant.tasting-menu": 0.90,
                "interest.restaurant.seafood": 0.65,
                "interest.restaurant.quiet-conversation": 0.40,
                "interest.restaurant.reservation-timing": 0.80
            ]
        ),
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.after-work-network",
            description: "Find an informal place for after-work networking and shared snacks.",
            interestWeights: [
                "interest.restaurant.after-work": 0.90,
                "interest.restaurant.networking": 0.90,
                "interest.restaurant.craft-drinks": 0.75,
                "interest.restaurant.shared-plates": 0.60
            ]
        ),
        RestaurantUserPurposeProfile(
            userID: "user.kjetil",
            purposeID: "purpose.user.plant-based-safe",
            description: "Prioritize vegetarian or vegan food with trustworthy dietary handling.",
            interestWeights: [
                "interest.restaurant.vegetarian": 0.95,
                "interest.restaurant.vegan": 0.80,
                "interest.restaurant.dietary-safety": 0.95,
                "interest.restaurant.gluten-free": 0.70,
                "interest.restaurant.local-food": 0.40
            ]
        )
    ]

    static let restaurantRecommendationCases: [RestaurantRecommendationCase] = [
        RestaurantRecommendationCase(caseID: "restaurant.user-team-dinner", userPurposeID: "purpose.user.team-dinner", expectedRestaurantID: "restaurant.brostein", expectedAdvertisedPurposeID: "purpose.team-dinner"),
        RestaurantRecommendationCase(caseID: "restaurant.user-quiet-seasonal", userPurposeID: "purpose.user.quiet-seasonal-meal", expectedRestaurantID: "restaurant.nordlys", expectedAdvertisedPurposeID: "purpose.calm-conversation"),
        RestaurantRecommendationCase(caseID: "restaurant.user-family-low-effort", userPurposeID: "purpose.user.family-low-effort", expectedRestaurantID: "restaurant.familiebord", expectedAdvertisedPurposeID: "purpose.family-friendly-meal"),
        RestaurantRecommendationCase(caseID: "restaurant.user-celebration", userPurposeID: "purpose.user.celebration-discovery", expectedRestaurantID: "restaurant.omakase", expectedAdvertisedPurposeID: "purpose.special-occasion-tasting"),
        RestaurantRecommendationCase(caseID: "restaurant.user-after-work", userPurposeID: "purpose.user.after-work-network", expectedRestaurantID: "restaurant.brostein", expectedAdvertisedPurposeID: "purpose.after-work-networking"),
        RestaurantRecommendationCase(caseID: "restaurant.user-plant-safe", userPurposeID: "purpose.user.plant-based-safe", expectedRestaurantID: "restaurant.gronn", expectedAdvertisedPurposeID: "purpose.dietary-safe-plant-based")
    ]

    static func restaurantRecommendations(
        forUserPurposeID userPurposeID: String,
        maxResults: Int = 10
    ) async -> [RestaurantRecommendation] {
        guard let userProfile = restaurantUserPurposeProfiles.first(where: { $0.purposeID == userPurposeID }) else {
            return []
        }
        return await restaurantRecommendations(for: userProfile, maxResults: maxResults)
    }

    static func restaurantRecommendations(
        for userProfile: RestaurantUserPurposeProfile,
        maxResults: Int = 10
    ) async -> [RestaurantRecommendation] {
        let purposeNodes = Dictionary(
            uniqueKeysWithValues: restaurantAdvertisedPurposes.map { advertisedPurpose in
                (
                    advertisedPurpose.matchPurposeID,
                    Purpose(
                        name: advertisedPurpose.matchPurposeID,
                        description: advertisedPurpose.description
                    )
                )
            }
        )

        var purposeEdgesByInterest = [String: [Weight<Purpose>]]()
        for advertisedPurpose in restaurantAdvertisedPurposes {
            guard let purpose = purposeNodes[advertisedPurpose.matchPurposeID] else { continue }
            for (interestID, restaurantWeight) in advertisedPurpose.interestWeights
                where userProfile.interestWeights[interestID] != nil {
                purposeEdgesByInterest[interestID, default: []].append(
                    Weight<Purpose>(weight: restaurantWeight, value: purpose)
                )
            }
        }

        let runtime = WeightedGraphRuntime()
        var scoresByMatchID = [String: Double]()
        var matchedInterestsByMatchID = [String: Set<String>]()

        for (interestID, userWeight) in userProfile.interestWeights {
            let interest = Interest(
                name: interestID,
                types: [],
                parts: [],
                partOf: [],
                purposes: purposeEdgesByInterest[interestID] ?? []
            )
            let signal = Signal(
                relationship: .purposes,
                weight: 0.5,
                tolerance: Double.greatestFiniteMagnitude,
                token: "restaurant.\(userProfile.purposeID).\(interestID)",
                ttl: 5.0,
                hops: 1
            )

            guard let result = try? await runtime.match(start: interest, signal: signal) else {
                continue
            }

            for hit in result.hits where hit.node.kind == .purpose {
                let restaurantWeight = hit.evidence.last(where: { $0.relationship == .purposes })?.edgeWeight ?? 0.0
                scoresByMatchID[hit.ref, default: 0.0] += userWeight * restaurantWeight
                matchedInterestsByMatchID[hit.ref, default: []].insert(interestID)
            }
        }

        let recommendations = restaurantAdvertisedPurposes.map { advertisedPurpose -> RestaurantRecommendation in
            RestaurantRecommendation(
                restaurantID: advertisedPurpose.restaurantID,
                restaurantName: advertisedPurpose.restaurantName,
                advertisedPurposeID: advertisedPurpose.purposeID,
                matchPurposeID: advertisedPurpose.matchPurposeID,
                score: scoresByMatchID[advertisedPurpose.matchPurposeID] ?? 0.0,
                matchedInterestRefs: Array(matchedInterestsByMatchID[advertisedPurpose.matchPurposeID] ?? []).sorted()
            )
        }

        return Array(
            recommendations.sorted {
                if $0.score == $1.score {
                    if $0.restaurantID == $1.restaurantID {
                        return $0.advertisedPurposeID < $1.advertisedPurposeID
                    }
                    return $0.restaurantID < $1.restaurantID
                }
                return $0.score > $1.score
            }
            .prefix(maxResults)
        )
    }

    static func evaluateRestaurantRecommendationCases() async -> [RestaurantRecommendationCaseResult] {
        var results = [RestaurantRecommendationCaseResult]()
        for recommendationCase in restaurantRecommendationCases {
            let recommendations = await restaurantRecommendations(
                forUserPurposeID: recommendationCase.userPurposeID,
                maxResults: 3
            )
            let top = recommendations.first
            let passed = top?.restaurantID == recommendationCase.expectedRestaurantID &&
                top?.advertisedPurposeID == recommendationCase.expectedAdvertisedPurposeID
            results.append(
                RestaurantRecommendationCaseResult(
                    caseID: recommendationCase.caseID,
                    expectedRestaurantID: recommendationCase.expectedRestaurantID,
                    expectedAdvertisedPurposeID: recommendationCase.expectedAdvertisedPurposeID,
                    topRestaurantID: top?.restaurantID,
                    topAdvertisedPurposeID: top?.advertisedPurposeID,
                    topScore: top?.score ?? 0.0,
                    matchedInterestRefs: top?.matchedInterestRefs ?? [],
                    passed: passed
                )
            )
        }
        return results
    }
}
