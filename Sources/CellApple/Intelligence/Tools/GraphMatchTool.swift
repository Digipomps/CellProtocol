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
    
    
    private unowned let aiCell: AppleIntelligenceCell
    private let requester: Identity

    init(cell: AppleIntelligenceCell, requester: Identity) {
        self.aiCell = cell
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

        // 2) Finn startnode
        let perspective = perspectiveCell.context
        let startRef = try await resolveStartRef(args: arguments.args, perspective: perspective)

        // 3) Kjør match
        let collector = HitCollector()
//        let rel = try parseRelationship(arguments.args.relationship)
//        let signal = Signal(relationship: rel,
//                            weight: arguments.args.weight,
//                            tolerance: arguments.args.tolerance,
//                            token: UUID().uuidString,
//                            ttl: arguments.args.ttl ?? 1.0 /*,
//                            collector: collector*/)
//
//        if let start = await findNode(ref: startRef, type: arguments.args.startType, perspective: perspective) {
//            try await start.match(signal: signal)
//        } else {
//            return "Start node not found"
//        }

        // 4) Resultat
        let refs = await collector.results()
//        let limited = Array(refs.prefix(arguments.args.limit ?? 50))
        // Pakk i et enkelt JSON-objekt
//        let response: [String: Any] = [
//            "hits": limited.map { ["ref": $0] },
//            "count": limited.count
//        ]
        return  "Found startRef: \(startRef)"
    }

    private func parseRelationship(_ s: String) throws -> PerspectiveRelationship {
        switch s {
        case "types": return .types
        case "subTypes": return .subTypes
        case "parts": return .parts
        case "partOf": return .partOf
        case "interests": return .interests
        case "purposes": return .purposes
        case "entities": return .entities
        case "states": return .states
        default: throw NSError(domain: "GraphMatchTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown relationship"])
        }
    }

    private func resolveStartRef(args: GraphMatchArguments, perspective: Perspective) async throws -> String {
//        if let r = args.startRef, !r.isEmpty { return r }
        // Fallback til høyest vektet aktiv purpose
        if let best = try? await perspective.getPrimaryPurpose() {
            return best.reference
        }
        throw NSError(domain: "GraphMatchTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "No startRef and no active purposes"])
    }

    private func findNode(ref: String, type: String?, perspective: Perspective) async -> (any WeightedMatch)? {
        print("findNode ref: \(ref) type: \(String(describing: type)) ")
        switch type {
        case "interest":
            return await perspective.findInterestByReference(ref)
        case "entity":
            return await perspective.findENtityRepresentationByReference(ref)
        case "purpose", nil:
            if let p = await perspective.findPurposeByReference(ref) { return p }
            if let i = await perspective.findInterestByReference(ref) { return i }
            if let e = await perspective.findENtityRepresentationByReference(ref) { return e }
            return nil
        default:
            return nil
        }
    }
}

#endif
