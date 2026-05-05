// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 21/08/2023.
//

import Foundation

public class Interest: PerspectiveNodeImpl {
    
    var constraint: InterestConstraint = DefaultInterestConstraint()

    
    
    init(name: String, types: [Weight<Interest>], parts: [Weight<Interest>], partOf: [Weight<Interest>], purposes: [Weight<Purpose>], constraint: InterestConstraint = DefaultInterestConstraint()) {
        super.init()
        self.name = name
        self.types = types
        self.subTypes = [Weight<Interest>]()
        self.parts = parts
        self.partOf = partOf
        self.purposes = purposes
        self.entities = [Weight<EntityRepresentation>]()
        self.states = [Weight<Interest>]()
        self.interests = [Weight<Interest>]()
        self.constraint = constraint
    }
    
    
    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.types = try container.decode([Weight<Interest>].self, forKey: .types)
        self.subTypes = try container.decode([Weight<Interest>].self, forKey: .subTypes)
        self.parts = try container.decode([Weight<Interest>].self, forKey: .parts)
        self.partOf = try container.decode([Weight<Interest>].self, forKey: .partOf)
        self.purposes = try container.decode([Weight<Purpose>].self, forKey: .purposes)
        self.interests = try container.decode([Weight<Interest>].self, forKey: .interests)
        self.states = try container.decode([Weight<Interest>].self, forKey: .states)
        self.entities = try container.decode([Weight<EntityRepresentation>].self, forKey: .entities)
        
        self.constraint = DefaultInterestConstraint()
        
//        self.constraint = try container.decode(DefaultInterestConstraint.self, forKey: .constraint) // TODO: Look into if it must be serializable
        
        
    }
    
    enum CodingKeys: CodingKey {
        case name
        case types
        case subTypes
        case parts
        case partOf
        case purposes
        case interests
        case entities
        case states
        case constraint
        
    }
    
    public override func encode(to encoder: Encoder) throws {
 
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        
        // Check whether objects is these relationships is already serialises (and thus eglible for reference)
        let types = self.types as? [Weight<Interest>]
        try container.encode(types, forKey: .types)
        try container.encodeIfPresent(self.subTypes as? [Weight<Interest>], forKey: .subTypes)
        try container.encodeIfPresent(self.parts as? [Weight<Interest>], forKey: .parts)
        try container.encodeIfPresent(self.partOf as? [Weight<Interest>], forKey: .partOf)
        try container.encodeIfPresent(self.purposes as? [Weight<Purpose>], forKey: .purposes)
        try container.encodeIfPresent(self.interests as? [Weight<Interest>], forKey: .interests)
        try container.encodeIfPresent(self.states as? [Weight<Interest>], forKey: .states)
        try container.encodeIfPresent(self.entities as? [Weight<EntityRepresentation>], forKey: .entities)
//        try container.encodeIfPresent(self.constraint, forKey: .constraint)
    }
}

//extension Interest: Referenceable {
//    var reference: String { // Interest id
//        get {
//            return name // For now we use the name
//        }
//    }
//}




extension Interest: WeightedMatch {
    public func match(signal: Signal) async throws { // Perform matching
        switch signal.relationship {
        case .parts:
            CellBase.diagnosticLog("Interest.match relationship=parts", domain: .semantics)
            try await match(weightedNodes: self.parts, with: signal)
            
            
        case .types:
            CellBase.diagnosticLog("Interest.match relationship=types", domain: .semantics)
            try await match(weightedNodes: self.types, with: signal)
        case .partOf:
            CellBase.diagnosticLog("Interest.match relationship=partOf", domain: .semantics)
            try await match(weightedNodes: self.partOf, with: signal)
        case .purposes:
            CellBase.diagnosticLog("Interest.match relationship=purposes", domain: .semantics)
            try await match(weightedNodes: self.purposes, with: signal)
            
        case .interests:
            try await match(weightedNodes: self.interests, with: signal)
            CellBase.diagnosticLog("Interest.match relationship=interests", domain: .semantics)
        case .entities:
            try await match(weightedNodes: self.entities, with: signal)
            CellBase.diagnosticLog("Interest.match relationship=entities", domain: .semantics)
        case .states:
            try await match(weightedNodes: self.states, with: signal)
            CellBase.diagnosticLog("Interest.match relationship=states", domain: .semantics)
        case .subTypes:
            try await match(weightedNodes: self.subTypes, with: signal)
            CellBase.diagnosticLog("Interest.match relationship=subTypes", domain: .semantics)
        }
    }
    
    private func match(weightedNodes: [Weighted], with signal: Signal) async throws {
        for weighted in weightedNodes where isSignalMatch(weighted.weight, signal: signal) {
            if let weightedInterest = weighted as? Weight<Interest> {
                try await weightedInterest.node.hit(signal)
                continue
            }
            if let weightedPurpose = weighted as? Weight<Purpose> {
                try await weightedPurpose.node.hit(signal)
                continue
            }
            if let weightedEntity = weighted as? Weight<EntityRepresentation> {
                try await weightedEntity.node.hit(signal)
            }
        }
    }
    
    private func isSignalMatch(_ edgeWeight: Double, signal: Signal) -> Bool {
        signal.weight > (edgeWeight - signal.tolerance) && signal.weight < (edgeWeight + signal.tolerance)
    }
    
    public func hit(_ signal: Signal) async throws {
        CellBase.diagnosticLog("Interest.hit name=\(name)", domain: .semantics)
        await signal.collector?.record(self.reference)
    }
}
