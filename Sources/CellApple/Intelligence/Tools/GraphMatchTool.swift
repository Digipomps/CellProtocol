// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  GraphMatchTool.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 03/02/2026.
//
import Foundation
@preconcurrency import CellBase

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
//struct GraphMatchArguments: Codable {
//    var startRef: String?
//    var startType: String? // "interest" | "purpose" | "entity"
//    var relationship: String // "types", "parts", "partOf", "interests", "purposes", "entities", "states", "subTypes"
//    var weight: Double
//    var tolerance: Double
//    var ttl: Double?
//    var limit: Int?
//}

@Generable
enum GraphMatchArguments: String, CaseIterable {
    case work
    case dine
    case exercise
    case learn
    case sleep
    case commute
    case relationship
}

@available(iOS 26.0, macOS 26.0, *)
final class GraphMatchTool: Tool {
    let name = "graph_match"
    let description = "Match on Purpose, Interest or Entity"
    
    
    private let requester: Identity

    init(requester: Identity) {
        self.requester = requester
    }
    
    @Generable
    struct Arguments {
        @Guide(description: "This is the purpose look up for.")
        let args: GraphMatchArguments

        @Guide(description: "The natural language query of what to search for.")
        let naturalLanguageQuery: String
    }

    func call(arguments: Arguments) async throws -> String {
        print("Tool: GraphMatchTool arguments: \(arguments)")
//        let args = try JSONDecoder().decode(GraphMatchArguments.self, from: arguments)
        // 1) Resolve PerspectiveCell
        guard let resolver = CellBase.defaultCellResolver,
              let perspectiveCell = try await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester) as? PerspectiveCell else {
//            return try JSONEncoder().encode(["error": "PerspectiveCell not available"])
            return "PerspectiveCell not available"
        }

        let data = try await perspectiveCell.matchPrimaryPurposeGraph(requester: requester)
        return String(data: data, encoding: .utf8) ?? "Graph match result could not be encoded"
    }

}

#endif
