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
@Observable
final class GetConfigurationsTool: Tool {
    // Tool metadata
    let name: String = "getConfigurations"
    let description: String = "Return up to `count` CellConfigurations from ai.candidates as a JSON array of names. Records last arguments and uses cell prompt settings."

    @MainActor var lookupHistory: [Lookup] = []
    
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
    weak var cell: AppleIntelligenceCell?
    let requester: Identity

    public init(cell: AppleIntelligenceCell, requester: Identity) {
        self.cell = cell
        self.requester = requester
    }
    
    func call(arguments: Arguments) async throws -> String {
        print("Tool: GetConfigurationsTool, called with arguments: \(arguments)")
        guard let cell else {
            return "error: cell unavailable"
        }
        await recordLookup(arguments: arguments)
        if let cell = self.cell {
            var obj: Object = [:]
            obj["pointOfInterest"] = .string(arguments.pointOfInterest.rawValue)
            obj["naturalLanguageQuery"] = .string(arguments.naturalLanguageQuery)
            _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.lastToolArguments)", value: .object(obj), requester: requester)
        }
        let vt = try? await cell.get(keypath: "\(AIKeys.root).\(AIKeys.candidates)", requester: requester)
//        var configs: [CellConfiguration] = []
//        if case let .list(list)? = vt {
//            for item in list {
//                if case let .cellConfiguration(conf) = item { configs.append(conf) }
//            }
//        }
//
//        let n = min(arguments.count, configs.count)
//        let selected = Array(configs.prefix(n))
//        let names = selected.map { $0.name }
//        let json = (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) } ?? names.description
//        return .string("json")
        let promptText: String = await {
            if let v = try? await cell.get(keypath: "\(AIKeys.root).\(AIKeys.promptText)", requester: requester), case let .string(s) = v, !s.isEmpty { return s }
            return ""
        }()
        let promptInstructions: String = await {
            if let v = try? await cell.get(keypath: "\(AIKeys.root).\(AIKeys.promptInstructions)", requester: requester), case let .string(s) = v, !s.isEmpty { return s }
            return "You are a helpful assistant. Keep answers concise."
        }()
        let builtPrompt = "Instructions:\n\(promptInstructions)\n\nQuery:\n\(arguments.naturalLanguageQuery)\n\nCategory: \(arguments.pointOfInterest.rawValue)\n\nContext: \(promptText)"
        return builtPrompt
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension GetConfigurationsTool {
    static var categories: String {
        Category.allCases.map {
            $0.rawValue
        }.joined(separator: ", ")
    }
    
    struct Lookup: Identifiable {
        let id = UUID()
        let history: GetConfigurationsTool.Arguments
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension GetConfigurationsTool {
    
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
#endif



