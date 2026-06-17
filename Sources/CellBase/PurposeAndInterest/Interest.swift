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
    public var condition: InterestCondition = .always

    
    
    public init(
        name: String,
        types: [Weight<Interest>],
        parts: [Weight<Interest>],
        partOf: [Weight<Interest>],
        purposes: [Weight<Purpose>],
        condition: InterestCondition = .always
    ) {
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
        self.condition = condition
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
        self.condition = try container.decodeIfPresent(InterestCondition.self, forKey: .constraint) ?? .always
        
        
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
        if condition != .always {
            try container.encode(condition, forKey: .constraint)
        }
    }

    public func conditionSatisfied(in context: InterestConditionContext?) -> Bool {
        condition.evaluate(in: context)
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
        CellBase.diagnosticLog("Interest.match relationship=\(signal.relationship)", domain: .semantics)
        _ = try await WeightedGraphRuntime().match(start: self, signal: signal)
    }

    public func hit(_ signal: Signal) async throws {
        CellBase.diagnosticLog("Interest.hit name=\(name)", domain: .semantics)
        await signal.collector?.record(self.reference)
    }
}
