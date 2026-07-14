// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AppleIntelligenceTools.swift
//  CellProtocol
//
//  Created by Assistant on 14/01/2026.
//

import Foundation
import CellBase
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
final class GetConfigurationsTool: Tool, @unchecked Sendable {
    // Tool metadata
    let name: String = "getConfigurations"
    let description: String = "Return up to 20 CellConfigurations from ai.candidates as a JSON array of names. Records the bounded last-arguments snapshot."

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
    
    private let cell: AppleIntelligenceCell
    private let requester: Identity

    public init(cell: AppleIntelligenceCell, requester: Identity) {
        self.cell = cell
        self.requester = requester
    }
    
    func call(arguments: Arguments) async throws -> String {
        print("Tool: GetConfigurationsTool, called with arguments: \(arguments)")
        var argumentsObject: Object = [:]
        argumentsObject["pointOfInterest"] = .string(arguments.pointOfInterest.rawValue)
        argumentsObject["naturalLanguageQuery"] = .string(arguments.naturalLanguageQuery)
        await cell.storeLastToolArguments(.object(argumentsObject), requester: requester)

        guard case let .list(values) = try await cell.get(
            keypath: "\(AIKeys.root).\(AIKeys.candidates)",
            requester: requester
        ) else {
            return "[]"
        }
        let names = values.compactMap { value -> String? in
            guard case let .cellConfiguration(configuration) = value else { return nil }
            return configuration.name
        }
        let selectedNames = Array(names.prefix(20))
        return (try? JSONEncoder().encode(selectedNames))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    }
}
#endif
