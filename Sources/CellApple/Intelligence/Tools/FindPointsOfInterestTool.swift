// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A tool to use alongside the models to find points of interest for a landmark.
*/

import FoundationModels
import SwiftUI

@available(macOS 26.0, iOS 26.0, *)
@Observable
final class FindPointsOfInterestTool: Tool {
    let name = "findPointsOfInterest"
    let description = "Finds points of interest for a landmark."
    
    let landmark: Landmark
    
    @MainActor var lookupHistory: [Lookup] = []
    
    init(landmark: Landmark) {
        self.landmark = landmark
    }

    
    @Generable
    enum Category: String, CaseIterable {
        case campground
        case hotel
        case cafe
        case museum
        case marina
        case restaurant
        case nationalMonument
    }

    @Generable
    struct Arguments {
        @Guide(description: "This is the type of destination to look up for.")
        let pointOfInterest: Category

        @Guide(description: "The natural language query of what to search for.")
        let naturalLanguageQuery: String
    }
    
    @MainActor func recordLookup(arguments: Arguments) {
        lookupHistory.append(Lookup(history: arguments))
    }
    
    func call(arguments: Arguments) async throws -> String {
        print("Tool: FindPointsOfInterestTool, calling with arguments: \(arguments)")
        // This sample app pulls some static data. Real-world apps can get creative.
        await recordLookup(arguments: arguments)
        let results = mapItems(arguments: arguments)
        return "There are these \(arguments.pointOfInterest) in \(landmark.name): \(results.joined(separator: ", "))"
    }
    
    private func mapItems(arguments: Arguments) -> [String] {
        suggestions(category: arguments.pointOfInterest)
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension FindPointsOfInterestTool {
    
    func suggestions(category: Category) -> [String] {
        switch category {
        case .restaurant : ["Restaurant 1", "Restaurant 2", "Restaurant 3"]
        case .campground : ["Campground 1", "Campground 2", "Campground 3"]
        case .hotel : ["Hotel 1", "Hotel 2", "Hotel 3"]
        case .cafe : ["Cafe 1", "Cafe 2", "Cafe 3"]
        case .museum : ["Museum 1", "Museum 2", "Museum 3"]
        case .marina : ["Marina 1", "Marina 2", "Marina 3"]
        case .nationalMonument : ["The National Rock 1", "The National Rock 2", "The National Rock 3"]
        }
    }
}

