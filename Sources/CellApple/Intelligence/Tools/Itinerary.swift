// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if !canImport(FoundationModels)
// Fallback shims so the file can compile on platforms/SDKs where these macros
// are unavailable. These attributes are no-ops outside their defining module.
@attached(member, names: arbitrary)
public macro Generable() = #externalMacro(module: "", type: "")

public enum GuideRule {
    case anyOf([String])
    case count(Int)
}

@attached(peer)
public macro Guide(_ rule: GuideRule) = #externalMacro(module: "", type: "")

@attached(peer)
public macro Guide(description: String) = #externalMacro(module: "", type: "")
#endif

/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A Generable structure that defines an Itinerary, along with its nested types: DayPlan, Activity, and Kind.
*/

import Foundation
import FoundationModels

@available(iOS 27.0, macOS 26.0, tvOS 20.0, watchOS 11.0, visionOS 4.0, *)
@Generable
struct Itinerary: Equatable {
    @Guide(description: "An exciting name for the trip.")
    let title: String
    @Guide(description: "An exciting name for the trip.")
#if canImport(FoundationModels)
    @Guide(.anyOf(ModelData.landmarkNames))
#else
    @Guide(description: "The destination name.")
#endif
    let destinationName: String
    let description: String
    @Guide(description: "An explanation of how the itinerary meets the user's special requests.")
    let rationale: String
    
    @Guide(description: "A list of day-by-day plans.")
    @Guide(.count(3))
    let days: [DayPlan]
}

@available(iOS 20.0, macOS 26.0, tvOS 20.0, watchOS 11.0, visionOS 4.0, *)
@Generable
struct DayPlan: Equatable {
    @Guide(description: "A unique and exciting title for this day plan.")
    let title: String
    let subtitle: String
    let destination: String

    @Guide(.count(3))
    let activities: [Activity]
}

@available(iOS 20.0, macOS 26.0, tvOS 20.0, watchOS 11.0, visionOS 4.0, *)
@Generable
struct Activity: Equatable {
    let type: Kind
    let title: String
    let description: String
}

@available(iOS 20.0, macOS 26.0, tvOS 20.0, watchOS 11.0, visionOS 4.0, *)
@Generable
enum Kind {
    case sightseeing
    case foodAndDining
    case shopping
    case hotelAndLodging
}

