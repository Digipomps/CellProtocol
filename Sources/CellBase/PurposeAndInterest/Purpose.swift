// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 21/08/2023.
//

import Foundation

public class Purpose: PerspectiveNodeImpl {
    public private(set) var goal: CellConfiguration? // Change to CellReference?
    // Helper cells can automate remediation or provide user-facing guidance.
    public private(set) var helperCells = [CellConfiguration]()
    var description: String?
//    init(name: String, description: String, goal: Goal, actions: [Action], interests: [WeightedInterest], hasA: [WeightedPurpose], partOf: [WeightedPurpose], types: [WeightedPurpose]) {
        public init(name: String, description: String, /*goal: Goal = Goal(name: "Default Goal", test: "notification.content.state = ok"),*/ actions: [Action] = [], interests: [Weight<Interest>] = [], purposes: [Weight<Purpose>] = [], entities: [Weight<EntityRepresentation>] = [], states: [Weight<Interest>] = [], types: [Weight<Purpose>] = [], subTypes: [Weight<Purpose>] = [], parts: [Weight<Purpose>] = [], partOf:[ Weight<Purpose>] = [], goal: CellConfiguration? = nil, helperCells: [CellConfiguration] = []) {
            self.goal = goal
            self.helperCells = helperCells
            
            super.init()
            self.name = name
            self.description = description
            
            self.interests = interests
            self.purposes = purposes
            self.entities = entities
            self.states = states
            self.types = types
            self.subTypes = subTypes
            self.parts = parts
            self.partOf = partOf
            
        }
        
        enum CodingKeys: CodingKey {
            case name
            case description
            case types
            case subTypes
            case parts
            case partOf
            case purposes
            case interests
            case entities
            case states
            case constraint
            case goal
            case helperCells
        }
        
    required public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
        self.goal = try container.decodeIfPresent(CellConfiguration.self, forKey: .goal)
        self.helperCells = try container.decodeIfPresent([CellConfiguration].self, forKey: .helperCells) ?? []
            super.init()
            
            self.name = try container.decode(String.self, forKey: .name)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.types = try container.decode([Weight<Purpose>].self, forKey: .types)
            self.subTypes = try container.decode([Weight<Purpose>].self, forKey: .subTypes)
            self.parts = try container.decode([Weight<Purpose>].self, forKey: .parts)
            self.partOf = try container.decode([Weight<Purpose>].self, forKey: .partOf)
            self.purposes = try container.decode([Weight<Purpose>].self, forKey: .purposes)
            self.interests = try container.decode([Weight<Interest>].self, forKey: .interests)
            self.entities = try container.decode([Weight<EntityRepresentation>].self, forKey: .entities)
            self.states = try container.decode([Weight<Interest>].self, forKey: .states)
        }
        
    public override func encode(to encoder: Encoder) throws {
        
//        guard let userInfoKey = CodingUserInfoKey(rawValue: "facilitator"),
//           let facilitator = encoder.userInfo[userInfoKey] else {
//            throw ReferenceLookupError.noEncodingFacilitator
//        }
//        print("facilitator: \(facilitator)")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encodeIfPresent(self.description, forKey: .description)
        
        // Check whether objects is these relationships is already serialises (and thus eglible for reference)
        let types = self.types as? [Weight<Purpose>]
        try container.encode(types, forKey: .types)
        try container.encodeIfPresent(self.goal, forKey: .goal)
        try container.encodeIfPresent(self.helperCells, forKey: .helperCells)
        try container.encodeIfPresent(self.subTypes as? [Weight<Purpose>], forKey: .subTypes)
        try container.encodeIfPresent(self.parts as? [Weight<Purpose>], forKey: .parts)
        try container.encodeIfPresent(self.partOf as? [Weight<Purpose>], forKey: .partOf)
        try container.encodeIfPresent(self.purposes as? [Weight<Purpose>], forKey: .purposes)
        try container.encodeIfPresent(self.interests as? [Weight<Interest>], forKey: .interests)
        try container.encodeIfPresent(self.states as? [Weight<Interest>], forKey: .states)
        try container.encodeIfPresent(self.entities as? [Weight<EntityRepresentation>], forKey: .entities)
//        try container.encodeIfPresent(self.constraint, forKey: .constraint)
    }

    public func getGoal() throws -> CellConfiguration {
        if goal == nil {
            throw PurposeError.noGoal
        }
        
        return goal!
    }
    
    public func setGoal(_ goal: CellConfiguration) {
        // Some validation here?
        self.goal = goal
    }
    
    public func getHelpers() throws -> [CellConfiguration] {
        return helperCells
    }
    
    public func addHelperCell(_ helper: CellConfiguration) {
        // Some validation here?
        self.helperCells.append(helper)
    }

    public func setHelperCells(_ helpers: [CellConfiguration]) {
        self.helperCells = helpers
    }

    public func clearHelperCells() {
        self.helperCells.removeAll()
    }
}

enum PurposeError: Error {
    case noGoal
    case noHelperCells
}


extension Purpose: WeightedMatch {
    public func match(signal: Signal) async throws {
        CellBase.diagnosticLog("Purpose.match relationship=\(signal.relationship)", domain: .semantics)
        
        switch signal.relationship {
        case .parts:
            CellBase.diagnosticLog("Purpose.match relationship=parts", domain: .semantics)
            try await match(weightedNodes: self.parts, with: signal)
            
            
        case .types:
            CellBase.diagnosticLog("Purpose.match relationship=types", domain: .semantics)
            try await match(weightedNodes: self.types, with: signal)
        case .partOf:
            CellBase.diagnosticLog("Purpose.match relationship=partOf", domain: .semantics)
            try await match(weightedNodes: self.partOf, with: signal)
        case .purposes:
            CellBase.diagnosticLog("Purpose.match relationship=purposes", domain: .semantics)
            try await match(weightedNodes: self.purposes, with: signal)
            
        case .interests:
            try await match(weightedNodes: self.interests, with: signal)
            CellBase.diagnosticLog("Purpose.match relationship=interests", domain: .semantics)
        case .entities:
            try await match(weightedNodes: self.entities, with: signal)
            CellBase.diagnosticLog("Purpose.match relationship=entities", domain: .semantics)
        case .states:
            try await match(weightedNodes: self.states, with: signal)
            CellBase.diagnosticLog("Purpose.match relationship=states", domain: .semantics)
        case .subTypes:
            try await match(weightedNodes: self.subTypes, with: signal)
            CellBase.diagnosticLog("Purpose.match relationship=subTypes", domain: .semantics)
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
        CellBase.diagnosticLog("Purpose.hit name=\(name)", domain: .semantics)
        await signal.collector?.record(self.reference)
    }
}

extension EntityRepresentation: WeightedMatch {
    public func match(signal: Signal) async throws {
        CellBase.diagnosticLog("EntityRepresentation.match relationship=\(signal.relationship)", domain: .semantics)
        switch signal.relationship {
        case .parts:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=parts", domain: .semantics)
            try await match(weightedNodes: self.parts, with: signal)
        case .types:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=types", domain: .semantics)
            try await match(weightedNodes: self.types, with: signal)
        case .partOf:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=partOf", domain: .semantics)
            try await match(weightedNodes: self.partOf, with: signal)
        case .purposes:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=purposes", domain: .semantics)
            try await match(weightedNodes: self.purposes, with: signal)
        case .interests:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=interests", domain: .semantics)
            try await match(weightedNodes: self.interests, with: signal)
        case .entities:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=entities", domain: .semantics)
            try await match(weightedNodes: self.entities, with: signal)
        case .states:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=states", domain: .semantics)
            try await match(weightedNodes: self.states, with: signal)
        case .subTypes:
            CellBase.diagnosticLog("EntityRepresentation.match relationship=subTypes", domain: .semantics)
            try await match(weightedNodes: self.subTypes, with: signal)
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
        CellBase.diagnosticLog("EntityRepresentation.hit name=\(name)", domain: .semantics)
        await signal.collector?.record(self.reference)
    }
}


public struct PurposeReference: Codable {
    public var keypath: String
}



//@available(macOS 13.0, *)
extension Purpose {
    public static func generatePurposes() async throws {
        let context = Perspective() // Should we use a singleton?
        try await context.loadContext()
        var purposes = [Purpose]()
        purposes.append(
            
            
            Purpose(name: "Test purpose", description: "Act as a generic Purpose test", actions: [Action]())
            
        )
        purposes.append(
            Purpose(name: "Be with friends", description: "Meet entities that is within the friends social group", actions: [Action]())
            //interests: be social, meet friends
            //isA: be social
            // partOf:
            // hasA: Meet Neal and Bob (friends)
        )
        purposes.append(
            Purpose(name: "Be with family", description: "Meet entities that is within the family social group", actions: [Action]())
            //interests: be social, meet family
            //isA: be social, be with family
            // partOf:
            // hasA:
        
        )
        purposes.append(
            Purpose(name: "Be solitary", description: "Be by your own", actions: [Action]())
            
            //interests: self realization, introvert
            //isA:
            // partOf:
            // hasA: Meditation,
        )
        purposes.append(
            Purpose(name: "Experience randonee", description: "Experience a randonne tour", actions: [Action]())
            //interests: be social, meet friends
            //isA: be social
            // partOf:
            // hasA: "Be in randonnee tour, experience winter, experience mountains, Be with friendse"
        )
        purposes.append(
            Purpose(name: "Run", description: "Jog or run", actions: [Action]())
            //interests: be social, meet friends
            //isA: be social
            // partOf:
            // hasA: "Be in randonnee tour, experience winter, experience mountains, Be with friendse"
        )
        
        
        var laGarrotxaInterests = [Weight<Interest>]()
        await laGarrotxaInterests.append(
//            WeightedInterest(weight: 7.0, interest: context.getInterest(name: "Volcano"))
            
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Volcano"))
        )
        await laGarrotxaInterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Forest"))
        )
        await laGarrotxaInterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Outdoor activity"))
        )
        await laGarrotxaInterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Medieval atmosphere"))
        )
        
        
        
        purposes.append(
            Purpose(name: "LA GARROTXA", description: "OUTDOOR ACTIVITIES AND A MEDIEVAL ATMOSPHERE", actions: [Action]())
            //interests: be social, meet friends
            //isA: be social
            // partOf:
            // hasA: "Be in randonnee tour, experience winter, experience mountains, Be with friends"
        )
        
        var urdaibainterests = [Weight<Interest>]()
        await urdaibainterests.append(
             // is a location - in spain and france
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Basque Country"))
        )
        
        await urdaibainterests.append(
             // is a location - in spain
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Province of Biscay"))
        )
        
        await urdaibainterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Bird watching"))
        )
        
        await urdaibainterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Forest"))
        )
        
        await urdaibainterests.append(
            Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Fauna"))
        )

        await urdaibainterests.append(
                    Weight<Interest>(weight: 7.0, value: context.getInterest(name: "Sandbank"))
                )

        
        purposes.append(
            Purpose(name: "URDAIBAI BIOSPHERE RESERVE", description: "Birdwatching and nature experiences in URDAIBAI BIOSPHERE RESERVE", actions: [Action]())
            //interests: be social, meet friends
            //isA: be social
            // partOf:
        )
        
        try await context.persistContext()
        
        /*
         Purposes in spain: https://www.adventure.travel/spain
         
         LA GARROTXA: OUTDOOR ACTIVITIES AND A MEDIEVAL ATMOSPHERE
         volcanic
         forest
         "volcanic cooking"
         Outdoor activities - interest in activities happening outdoor
         medieval atmosphere - interest and property (description)
         foot - (walk, hike) both interest and activity
         in 4x4s - an interest but also an action? like rent a 4X4
         
         horse back [riding]
         
         URDAIBAI BIOSPHERE RESERVE
         province of Biscay
         between capes Matxitxaco and Ogoño
         12-kilometre stretch of sandbanks
         Biosphere Reserve (1984)
         Basque Country
          Low altitude mountains with steep slopes give way to a valley that leads to the Cantabrian Sea, forming a wide estuary. The floodplain turns into marshland, while also shaping cliffs and beaches
         Bird watching
         holm oak forests, bushes, heath, crags and aquatic plants
         
         
         BEWITCHING GARAJONAY NATIONAL PARK
         
         ORDESA Y MONTE PERDIDO NATIONAL PARK ROUTE IN THE PYRENEES
         
         
         One day in Toledo
         https://www.spain.info/en/route/toledo/
            Morning: the Cathedral (architecture, paintings, birds eye view), Alcázar fortress (cup of coffee or a snack),  visit museum - Santa Cruz Museum
            Lunch in  Calle Alfileritos
         AFTERNOON: A tour through the Jewish quarter
         old church of San Marcos (archaeological, paintings), Tránsito Synagogue, Sephardic Museum.Santa María la Blanca, monastery of San Juan de los Reyes, crafts and souvenir shops, Toledo steel, Mosque of Cristo de la Luz, Puerta del Sol, church of Santiago del Arrabal, Bisagra Gate.
         A great panoramic spot for watching the sunset
         What to see:
         Santa Cruz Museum
         Alcázar fortress in Toledo
         Toledo Cathedral
         Church of Santo Tomé (Toledo)
         El Tránsito synagogue
         Santa María La Blanca synagogue
         Monastery of San Juan de los Reyes
         Cristo de la Luz mosque
         Puerta del Sol (Toledo)
         Santiago del Arrabal Church
         Nueva de Bisagra Gate
         Parador de Toledo
         
        
         */
        
    }
}


/*
 My purposes
 Work
 Develop interests and purposes framwork - split into develop and design?
 
 Be with friends - activity - with some of a group of entities
 Be with family - activity - with some of a group of entities
 Be solitary - activity - with none other entities
 Meet new people - activity - make new connections to person entitites
 Make new friends - aktivity -  make new connections to person entitites that represents more than just connect
 Experience randonee - experience. Includes go on randonne tour
 Experience winter
 Experience spring
 Experience autumn
 Experience summer
 Excercise
 Run
 Walk
 Hike
 Experience nature
 Experience cities
 Experience Norway
 Experience Oslo
 Experience Japan
 Experience Forests
 Experience Mountains
 Stay at a hotel
 Experience beach
 Experience warm weather
 Experience salt water
 Experience pool bathing
 
 */
