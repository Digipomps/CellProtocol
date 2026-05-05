// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 05/09/2023.
//

import Foundation

public struct Fullfilled {
    public var purposes: [Purpose] = []
    public var interests: [Interest] = []

    public init(purposes: [Purpose] = [], interests: [Interest] = []) {
        self.purposes = purposes
        self.interests = interests
    }
}

public struct AgreementReference: Codable, Equatable {
    public var id: String
    public var label: String
    public var counterparty: String?
    public var purpose: String?
    public var dataPointer: String?
    public var recordState: AgreementState?
    public var savedAt: Int?
    public var savedAtText: String?
    public var recordKeypath: String?
    public var sourceEntityKeypath: String?

    public init(
        id: String,
        label: String,
        counterparty: String? = nil,
        purpose: String? = nil,
        dataPointer: String? = nil,
        recordState: AgreementState? = nil,
        savedAt: Int? = nil,
        savedAtText: String? = nil,
        recordKeypath: String? = nil,
        sourceEntityKeypath: String? = nil
    ) {
        self.id = id
        self.label = label
        self.counterparty = counterparty
        self.purpose = purpose
        self.dataPointer = dataPointer
        self.recordState = recordState
        self.savedAt = savedAt
        self.savedAtText = savedAtText
        self.recordKeypath = recordKeypath
        self.sourceEntityKeypath = sourceEntityKeypath
    }
}


public class EntityRepresentation:  PerspectiveNodeImpl {

    var fulfilled: Fullfilled = Fullfilled() // Until Interests and Purposes are moved
    var person: Entity = [:]
    var identities: [Identity] = []
    public var agreementRefs: [AgreementReference] = []
    
    public init(interests: [Weight<Interest>] = [], purposes: [Weight<Purpose>] = [], entities: [Weight<EntityRepresentation>] = [], states: [Weight<Interest>] = [], name: String, types: [Weight<EntityRepresentation>] = [], subTypes: [Weight<EntityRepresentation>] = [], parts: [Weight<EntityRepresentation>] = [], partOf:[ Weight<EntityRepresentation>] = [], fulfilled: Fullfilled = Fullfilled(), person: Entity = [:], identities: [Identity] = [], agreementRefs: [AgreementReference] = []) {
        super.init()
        self.interests = interests
        self.purposes = purposes
        self.entities = entities
        self.states = states
        self.name = name
        self.types = types
        self.subTypes = subTypes
        self.parts = parts
        self.partOf = partOf
        self.fulfilled = fulfilled
        self.person = person
        self.identities = identities
        self.agreementRefs = agreementRefs
        
        
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
        case agreementRefs
        
    }
    
    required public init(from decoder: Decoder) throws {
        super.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.types = try container.decode([Weight<EntityRepresentation>].self, forKey: .types)
        self.subTypes = try container.decode([Weight<EntityRepresentation>].self, forKey: .subTypes)
        self.parts = try container.decode([Weight<EntityRepresentation>].self, forKey: .parts)
        self.partOf = try container.decode([Weight<EntityRepresentation>].self, forKey: .partOf)
        self.purposes = try container.decode([Weight<Purpose>].self, forKey: .purposes)
        self.interests = try container.decode([Weight<Interest>].self, forKey: .interests)
        self.entities = try container.decode([Weight<EntityRepresentation>].self, forKey: .entities)
        self.states = try container.decode([Weight<Interest>].self, forKey: .states)
        self.agreementRefs = (try? container.decode([AgreementReference].self, forKey: .agreementRefs)) ?? []
    }
    
    public override func encode(to encoder: Encoder) throws { // TODO: Check this override
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        
        // Check whether objects is these relationships is already serialises (and thus eglible for reference)
        let types = self.types as? [Weight<EntityRepresentation>]
        try container.encode(types, forKey: .types)
        try container.encodeIfPresent(self.subTypes as? [Weight<EntityRepresentation>], forKey: .subTypes)
        try container.encodeIfPresent(self.parts as? [Weight<EntityRepresentation>], forKey: .parts)
        try container.encodeIfPresent(self.partOf as? [Weight<EntityRepresentation>], forKey: .partOf)
        try container.encodeIfPresent(self.purposes as? [Weight<Purpose>], forKey: .purposes)
        try container.encodeIfPresent(self.interests as? [Weight<Interest>], forKey: .interests)
        try container.encodeIfPresent(self.states as? [Weight<Interest>], forKey: .states)
        try container.encodeIfPresent(self.entities as? [Weight<EntityRepresentation>], forKey: .entities)
        try container.encode(self.agreementRefs, forKey: .agreementRefs)

        // TODO: add encoding of person, fulfilled and identities ...and relations???
    
    }
    
    
   /*
    Purposes: things I want to achieve
    Interests: things I'm concerned about
    States: What is the situation?
    Entities: Who is involved?
    
    */
}
