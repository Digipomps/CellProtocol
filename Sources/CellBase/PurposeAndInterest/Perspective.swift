// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  IntPurContext.swift
//  InterestsTestTool
//
//  Created by Kjetil Hustveit on 23/06/2023.
//

import Foundation


public enum InterestsFrameworkError : Error {
    case urlGenerationError
    case missingJsonData
    
}

public struct InterestsAndPurposesContainer {
    var interests: [Interest]
    var purposes: [Purpose]
    var entities: [EntityRepresentation]
//    var states: [Interest]
}


extension InterestsAndPurposesContainer: Codable {
    enum CodingKeys: CodingKey {
        case interests
        case purposes
        case entityRepresentation
        case states
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        guard let userInfoKey = CodingUserInfoKey(rawValue: "interestFacilitator"),
              let facilitatorInt = decoder.userInfo[userInfoKey] as? Facilitator<Interest> else {
            throw ReferenceLookupError.noInterestEncodingFacilitator
        }
        guard let userInfoKey = CodingUserInfoKey(rawValue: "purposeFacilitator"),
              let facilitatorPur = decoder.userInfo[userInfoKey] as? Facilitator<Purpose> else {
            throw ReferenceLookupError.noInterestEncodingFacilitator
        }
        guard let userInfoKey = CodingUserInfoKey(rawValue: "entityFacilitator"),
              let facilitatorEnt = decoder.userInfo[userInfoKey] as? Facilitator<EntityRepresentation> else {
            throw ReferenceLookupError.noInterestEncodingFacilitator
        }
        print("Facilitator (container): \(facilitatorInt)")
        self.interests = try container.decode([Interest].self, forKey: .interests)
        for currentInterest in self.interests {
            facilitatorInt.add(currentInterest)
        }
        
        self.purposes = try container.decode([Purpose].self, forKey: .purposes)
        for currentPurpose in self.purposes {
            facilitatorPur.add(currentPurpose)
        }
        
        self.entities = try container.decode([EntityRepresentation].self, forKey: .entityRepresentation)
        for currentEntityRepresentation in self.entities {
            facilitatorEnt.add(currentEntityRepresentation)
        }
        
        
    }
    
    public func encode(to encoder: Encoder) throws {
        
        //        guard let userInfoKey = CodingUserInfoKey(rawValue: "facilitator"),
        //           let facilitator = encoder.userInfo[userInfoKey] else {
        //            throw ReferenceLookupError.noEncodingFacilitator
        //        }
        //        print("facilitator: \(facilitator)")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.interests, forKey: .interests)
        try container.encode(self.purposes, forKey: .purposes)
        
    }
    
}

public enum PerspectiveError: Error {
    case noContainer
    case noInterestForReference(String)
    case noPurposeForReference(String)
    case noEntityForReference(String)
    case noPrimaryPurpose
    case purposeExist
    case interestExist
    case entityExist
    case objectToWeightedFailed
}


public actor Perspective {
    // What I'm pursuing - what are my active purposes
    var activePurposes: [Weight<Purpose>] = []
    var activeInterests: [Weight<Interest>] = []
    var activeEntities: [Weight<EntityRepresentation>] = []
    
    var hostCell: Emit? // Maybe it should be an enum?
    
    /*
     Add a Perspective Purpose to add a highly weighted Purpose?
     
     something like "I need to have at least one purpose that is at least 0.9"
     What is desirable to do with purposes?
     Add weighted purpose
     remove weighted purpose
     ajdust a purpose's relations
     
     Set up a purpoese's means for determining goal achivement
     Check if goal is met
     */
    
    //Interests
//    var interestsList = [String]()
    var interestNameReferences = [String : [String]]() // Name of interests pointing to references
    var interestReferencesDict = [String : Interest]()
    var interests = [Interest]()
    
    var storageURL: URL?
    //Purposes
    var purposeNameReferences = [String : [String]]() // Name of purpose pointing to references
    var purposeReferencesDict = [String : Purpose]()
    var purposes = [Purpose]()
    
    var entityRepresentationNameReferences = [String : [String]]() // Name of entity pointing to references
    var entityRepresentationReferencesDict = [String : EntityRepresentation]()
    var entityRepresentation = [EntityRepresentation]()
    
    var stateNameReferences = [String : [String]]() // Name of purpose pointing to references
    var stateRepresentationReferencesDict = [String : Interest]()
    var stateRepresentation = [Purpose]()
    
    private var jsonData: Data?
    private var needsRefresh: Bool = true
    private var interestsAndPurposesContainer: InterestsAndPurposesContainer?

    
    public init() {
        
    }
    
//    public init()
    // We'll do this with a delegate protocol...
    func setHostCell(cell: Emit) {
        self.hostCell = cell
    }
    
    func setHostCell(cell: Absorb) {
        
    }
    
    // load
    // persist
    // add
    // delete
    // update
    // find by reference
    // find by name
    // match relationships
    
    
    public func getContainerInterests() throws -> Object? {
        guard let interestsAndPurposesContainer = interestsAndPurposesContainer else {
            throw PerspectiveError.noContainer
        }
        let encoder = self.pimpEncoder()

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let interestsJsonData = try encoder.encode(interestsAndPurposesContainer)
        
        let decoder = self.pimpDecoder()
        
        let containerObject = try decoder.decode(Object.self, from: interestsJsonData)
        
        return containerObject
    }
    func getContainerPurposes() -> [Purpose]? {
        return self.interestsAndPurposesContainer?.purposes
    }
    
    public func setJsonStorageURL(_ fileurl: URL) {
        storageURL = fileurl
    }

    public func addPurpose(_ purpose: Purpose) {
        print("Adding purpose: \(purpose.name)")
        if var purposeRefList = purposeNameReferences[purpose.name] {
            purposeRefList.append(purpose.reference)
        } else {
            purposeNameReferences[purpose.name] = [purpose.reference]
        }
        
//        if 0 == purpose.isA.count && 0 == purpose.hasA.count && 0 == purpose.partOf.count {
            interestsAndPurposesContainer?.purposes.append(purpose)
//        }
    }
    
    public func getPrimaryPurpose() async throws -> Purpose {
        var primaryPurpose: Purpose?
        var lastWeight = 0.0
        for weightedPurpose in activePurposes {
            if weightedPurpose.weight > lastWeight {
                
                primaryPurpose = try await weightedPurpose.node
                lastWeight = weightedPurpose.weight
            }
        }
        if primaryPurpose != nil {
            return primaryPurpose!
        }
        throw PerspectiveError.noPrimaryPurpose
    }
    
    public func addEntityRepresentation(_ entityRepresentation: EntityRepresentation) {
        print("Adding entityRepresentation: \(entityRepresentation.name)")
        if var purposeRefList = purposeNameReferences[entityRepresentation.name] {
            purposeRefList.append(entityRepresentation.reference)
        } else {
            entityRepresentationNameReferences[entityRepresentation.name] = [entityRepresentation.reference]
        }
        
//        if 0 == purpose.isA.count && 0 == purpose.hasA.count && 0 == purpose.partOf.count {
            interestsAndPurposesContainer?.entities.append(entityRepresentation)
//        }
    }
    
    
    
//    func persistPurposes() throws {
//        let encoder = JSONEncoder()
//        let facilitator = Facilitator<Interest>()
////        facilitator.context = self
//        if let userInfoKey = CodingUserInfoKey(rawValue: "purposeFacilitator") {
//            encoder.userInfo[userInfoKey] = facilitator
//        }
//        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
//        let jsonData = try encoder.encode(self.interests)
//
//        try jsonData.write(to: URL(filePath: Interests.filePath))
//    }
    
//     func buildPurposeList() throws {
//        let listOfPurposes = """
//Having a Strong Sense of Family
//Helping Children
//Giving Back to the Community
//Helping Animals
//Living a Healthy Lifestyle
//Prioritizing Fitness
//Incorporating Music
//Appreciating Art
//Embracing Spirituality
//Living a Happy and Ethical Life
//Empowering Others
//Being True to Myself
//Achieving a Meaningful Career
//Cultivating Healthy, Reciprocal Relationships
//Reaching My Fullest and Highest Potential
//Bringing Others Joy
//Helping the Less Fortunate
//Sharing Wisdom
//Appreciating the World Around Me
//"""
         
    public func buildPurposeList() throws {
            let listOfPurposes = """
    Experience nature
    Experience city
    Experience mountain
    Experience coast
    Swimming
    Running
    Walking
    Meditating
    Skiing
    Downhill skiing
    Randonne
    Parachuting
    Paragliding
    Sailing
    Biking
    Hiking
    Play football
    Scuba diving
    Free diving
    Be at some place
    Be with someone
    """
        
        let purposeListLabels = listOfPurposes.split(separator: "\n")


         let purposeAsType = Purpose(name: "purpose", description: "Type of all purposes", actions: [Action]())
    let weightedPurposeType = Weight<Purpose>(weight: 1.0, value: purposeAsType)
        
        for currentPurposeLabel in purposeListLabels { //String(currentInterestLabel).replacingOccurrences(of: " ", with: "")
            let purpose = Purpose(name: String(currentPurposeLabel).trimmingCharacters(in: .whitespaces), description: "Description of purpose", actions: [Action](), types: [weightedPurposeType])
            self.addPurpose(purpose)
        }
        try persistContext()
    }
    
    public func buildEntityRepresentations() throws {
        let listOfNicknames = """
       Artist's Philosopher
       Beekeeper Philosophe
       Father of Existentialism
       Father of Logic
       The Jewish Luther
       Laughing Philosopher
       Longshoreman Philosopher
       Mother of Feminism
       Philosopher of Fascism
       The Philosopher
       Weeping Philosopher
       Bottled Wasp
       the American Aristotle
       """
        
        let entityListLabels = listOfNicknames.split(separator: "\n")
        
        for currentEntityLabel in entityListLabels {
            let entity = EntityRepresentation(name: String(currentEntityLabel).trimmingCharacters(in: .whitespaces), person: Object())
            self.addEntityRepresentation(entity)
        }
        try persistContext()
    }
    
    // MARK: Finding & matching
    public func findInterestByReference(_ reference: String) -> Interest? {
        return interestReferencesDict[reference]
    }
    
    public func matchInterestsByName(_ name: String) -> [Interest] {
        var matches = [Interest]()
        if let matchReferences = interestNameReferences[name] {
            for reference in matchReferences {
                if let match = findInterestByReference(reference) {
                    matches.append(match)
                }
            }
        }
        return matches
    }
    
    public func getInterest(name: String, isA: [Weight<Interest>] = [Weight<Interest>]()) -> Interest {
        let foundInterests = findInterest(name: name, weightedInterests: [Weight<Interest>]())
        if foundInterests.count > 0 {
            return foundInterests[0]
        }
        let interest = Interest(name: name, types: [Weight<Interest>](), parts: [Weight<Interest>](), partOf: [Weight<Interest>](), purposes: [Weight<Purpose>]())
        self.addInterest(interest)
        // hasChanges - should be saved
        return interest
        
    }
    
    public func findInterest(name: String, weightedInterests: [Weight<Interest>]) -> [Interest] {
        var exactMatch = true
        var nameFragment = ""
        if name.last == "*" {
            exactMatch = false
            nameFragment = String(name.dropLast())
        }

        var interestMatches = [Interest]()
        if exactMatch {
            return matchInterestsByName(name)
        } else {
            let dictMatches = interestNameReferences.keys.filter({
//                print("Matching \(nameFragment) with \($0)")
                return $0.starts(with: nameFragment)
            })
            for key in dictMatches {
                interestMatches.append(contentsOf: matchInterestsByName(key))
            }
        }
        return interestMatches
    }
    
    public func findPurposeByReference(_ reference: String) -> Purpose? {
        return purposeReferencesDict[reference]
    }
    
    public func findENtityRepresentationByReference(_ reference: String) -> EntityRepresentation? {
            return entityRepresentationReferencesDict[reference]
        }
    
    public func matchPurposesByName(_ name: String) -> [Purpose] {
        var matches = [Purpose]()
        if let matchReferences = purposeNameReferences[name] {
            for reference in matchReferences {
                if let match = findPurposeByReference(reference) {
                    matches.append(match)
                }
            }
        }
        return matches
    }
    
    public func findPurpose(name: String, weightedPurposes: [Weight<Purpose>]) -> [Purpose] {
        var exactMatch = true
        var nameFragment = ""
        if name.last == "*" {
            exactMatch = false
            nameFragment = String(name.dropLast())
        }

        var purposeMatches = [Purpose]()
        if exactMatch {
            return matchPurposesByName(name)
        } else {
            let dictMatches = purposeNameReferences.keys.filter({
//                print("Matching \(nameFragment) with \($0)")
                return $0.starts(with: nameFragment)
            })
            for key in dictMatches {
                purposeMatches.append(contentsOf: matchPurposesByName(key))
            }
        }
        return purposeMatches
    }
 
    
    public func addInterest(_ interest: Interest) {
        if var interestRefList = interestNameReferences[interest.name] {
            interestRefList.append(interest.reference)
        } else {
            interestNameReferences[interest.name] = [interest.reference]
        }
        
//        if 0 == interest.isA.count && 0 == interest.hasA.count && 0 == interest.partOf.count {
            interestsAndPurposesContainer?.interests.append(interest)
//        }
        
        
    }
    // MARK: Generate data Purposes & Interests
    public func buildInterestList() throws {
       let listOfInterests = """
       Adventure Travel
       Animals
       Animation
       Aquariums
       Archery
       Architecture
       Art
       Artificial Intelligence
       Astronomy
       Baking
       Beekeeping
       Biology
       Bodybuilding / Weight Lifting
       Botany
       Boxing
       Business
       Calligraphy
       Camping
       Canoeing
       Carpentry
       Cheerleading
       Chess
       Climbing
       Coaching
       Coding
       Comic Books / Manga
       Computing
       Concerts
       Cooking / Culinary Arts
       Cosplay
       Crafts
       Cultural Activities
       Cycling
       Dance
       Debate
       Design
       Diving
       Diy
       Documentaries
       Drawing
       Electronics
       Engineering
       Entrepreneurship
       Environmental Action
       Exercise
       Farming
       Fashion
       Festivals
       Film
       Filmmaking
       Fishing
       Fundraising
       Game Mods
       Gardening
       Geocaching
       Go
       Golf
       Gymnastics
       Hiking
       History
       Horseback Riding
       Iconography
       Improv
       Information Security
       Interior Design
       Investing
       Journaling
       Journalism
       Kayaking
       Kite Flying
       Languages
       Live Action Role-playing
       Low Technology
       Maintenance & Repair
       Martial Arts
       Media Production
       Museums
       Music
       Music Performance / Production
       Musical Instruments
       Nail Art
       Orienteering
       Origami
       Painting
       Performance Art
       Photography
       Poker
       Political Participation
       Pool
       Public Speaking
       Reading
       Reuse
       Robotics
       Running
       Sailing
       Science
       Simple Living / Minimalism
       Skateboarding
       Skating
       Skiing / Snowboarding
       Small Business
       Snorkeling
       Songwriting
       Surfing / Bodyboarding
       Swimming
       Table Tennis
       Team Sports
       Technology
       Tennis
       Theatre
       Track & Field
       Travel
       Tutoring
       User Experience
       Video Games
       Visual Communication & Design
       Volunteering
       Windsurfing / Kitesurfing
       Woodworking
       Wrestling
       Writing
"""
       
       let interestListLabels = listOfInterests.split(separator: "\n")
       let types = [Weight<Interest>]()
       let parts = [Weight<Interest>]()
//        var interestAsType = Interest(name: String("Interest").replacingOccurrences(of: " ", with: ""), isA: isA, hasA: hasA, partOf: [WeightedInterest](), purposes: [WeightedPurpose]())
       
        let interestAsType = Interest(name: "Interest", types: types, parts: parts, partOf: [Weight<Interest>](), purposes: [Weight<Purpose>]())
       for currentInterestLabel in interestListLabels {
           let types = [Weight<Interest>]()
           let parts = [Weight<Interest>]()
           
           let interest = Interest(name: String(currentInterestLabel).trimmingCharacters(in: .whitespaces), types: types, parts: parts, partOf: [Weight<Interest>](), purposes: [Weight<Purpose>]())

           interest.types.append(Weight<Interest>(weight: 1.0, value: interestAsType))
//           interestAsType.parts.append(Weight<Interest>(weight: 0.1, value: interest))
           
           self.addInterest(interest)
       }
       try persistContext()
        
        
   }
    @available(*, deprecated)
    public func loadContext() throws  {
        
        if needsRefresh {
            self.needsRefresh = false
            let decoder = JSONDecoder()
            let interestsFacilitator = Facilitator<Interest>()
            let purposesFacilitator = Facilitator<Purpose>()
            let entityRepresentationFacilitator = Facilitator<EntityRepresentation>()
            //        facilitator.context2 = self
            if let userInfoKey = CodingUserInfoKey(rawValue: "interestFacilitator") {
                decoder.userInfo[userInfoKey] = interestsFacilitator
            }
            if let userInfoKey = CodingUserInfoKey(rawValue: "purposeFacilitator") {
                decoder.userInfo[userInfoKey] = purposesFacilitator
            }
            if let userInfoKey = CodingUserInfoKey(rawValue: "entityRepresentationsFacilitator") {
                decoder.userInfo[userInfoKey] = entityRepresentationFacilitator
            }
            if let userInfoKey = CodingUserInfoKey(rawValue: "entityFacilitator") {
                decoder.userInfo[userInfoKey] = entityRepresentationFacilitator
            }
            if let userInfoKey = CodingUserInfoKey(rawValue: "context") {
                decoder.userInfo[userInfoKey] = self
            }
            
            
            if let storageURL {
                self.jsonData = try Data(contentsOf: storageURL)
            }
            if let jsonData = self.jsonData {
                self.interestsAndPurposesContainer = try decoder.decode(InterestsAndPurposesContainer.self, from: jsonData)
                self.interestReferencesDict = interestsFacilitator.referenceablesDict
                self.interestsAndPurposesContainer?.interests = Array(interestReferencesDict.values)
                self.interestNameReferences = interestsFacilitator.interestNameReferences
                
                self.purposeReferencesDict = purposesFacilitator.referenceablesDict
                self.interestsAndPurposesContainer?.purposes = Array(purposeReferencesDict.values)
                self.purposeNameReferences = purposesFacilitator.interestNameReferences

                self.entityRepresentationReferencesDict = entityRepresentationFacilitator.referenceablesDict
                self.interestsAndPurposesContainer?.entities = Array(entityRepresentationReferencesDict.values)
                self.entityRepresentationNameReferences = entityRepresentationFacilitator.interestNameReferences
            } else {
                self.needsRefresh = true
                throw InterestsFrameworkError.missingJsonData
            }
            
        }
    }
    
    public func persistContext() throws {
        
        let encoder = self.pimpEncoder()
        
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(self.interestsAndPurposesContainer)
    
        if let storageURL {
            try jsonData.write(to:storageURL)
        }
        self.needsRefresh = true
    }
    
   
    // Test various stuff
    
    public func testInterestReferences() async {
        for interest in interests {
            
                print("Checking interest: \(interest.name)")
                for wi in interest.parts {
                    if let wi = wi as? Weight<Interest> {
                        print("hasA WheightedInterest.interest: \( await String(describing: try? wi.node.name))")
                    }
                }
            for wi in interest.types {
                if let wi = wi as? Weight<Interest> {
                    print("isA WheightedInterest.interest: \(await String(describing: try? wi.node.name))")
                }
            }
            }
        
    }
    
    public func updateInterest(_ sourceInterest: Interest) async throws {
        let reference = sourceInterest.reference
        
        guard let targetInterest = findInterestByReference(reference) else {
            addInterest(sourceInterest)
            try self.persistContext()
            throw PerspectiveError.noInterestForReference(reference)
        }
        if targetInterest.name != sourceInterest.name { // Maybe create new? will not happen with current reference implementation
            print("Names of interests don't match! incoming: \(sourceInterest.name) target: \(targetInterest.name)")
        }
        // Maybe move this to Interest? (It will mean that Interest uses more memory...)
        if let targetRelation = targetInterest.types as? [Weight<Interest>],
           let sourceRelation = sourceInterest.types as? [Weight<Interest>] {
            targetInterest.types = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.subTypes as? [Weight<Interest>],
           let sourceRelation = sourceInterest.subTypes as? [Weight<Interest>] {
            targetInterest.subTypes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.parts as? [Weight<Interest>],
           let sourceRelation = sourceInterest.parts as? [Weight<Interest>] {
            targetInterest.parts = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.partOf as? [Weight<Interest>],
           let sourceRelation = sourceInterest.partOf as? [Weight<Interest>] {
            targetInterest.partOf =  try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetInterest.interests as? [Weight<Interest>],
           let sourceRelation = sourceInterest.interests as? [Weight<Interest>] {
            targetInterest.interests = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.purposes as? [Weight<Purpose>],
           let sourceRelation = sourceInterest.purposes as? [Weight<Purpose>] {
            targetInterest.purposes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.entities as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceInterest.entities as? [Weight<EntityRepresentation>] {
            targetInterest.entities = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetInterest.states as? [Weight<Interest>],
           let sourceRelation = sourceInterest.states as? [Weight<Interest>] {
            targetInterest.states = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        try self.persistContext()
    }
    
    public func updatePurpose(_ sourcePurpose: Purpose) async throws {
        let reference = sourcePurpose.reference
        
        guard let targetPurpose = findPurposeByReference(reference) else {
            addPurpose(sourcePurpose)
            try self.persistContext()
            throw PerspectiveError.noPurposeForReference(reference)
        }
        if targetPurpose.name != sourcePurpose.name { // Maybe create new? will not happen with current reference implementation
            print("Names of purposes don't match! incoming: \(sourcePurpose.name) target: \(targetPurpose.name)")
        }
        // Maybe move this to Interest? (It will mean that Interest uses more memory...)
        if let targetRelation = targetPurpose.types as? [Weight<Purpose>],
           let sourceRelation = sourcePurpose.types as? [Weight<Purpose>] {
            targetPurpose.types = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.subTypes as? [Weight<Purpose>],
           let sourceRelation = sourcePurpose.subTypes as? [Weight<Purpose>] {
            targetPurpose.subTypes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.parts as? [Weight<Purpose>],
           let sourceRelation = sourcePurpose.parts as? [Weight<Purpose>] {
            targetPurpose.parts = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.partOf as? [Weight<Purpose>],
           let sourceRelation = sourcePurpose.partOf as? [Weight<Purpose>] {
            targetPurpose.partOf =  try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetPurpose.interests as? [Weight<Interest>],
           let sourceRelation = sourcePurpose.interests as? [Weight<Interest>] {
            targetPurpose.interests = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.purposes as? [Weight<Purpose>],
           let sourceRelation = sourcePurpose.purposes as? [Weight<Purpose>] {
            targetPurpose.purposes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.entities as? [Weight<EntityRepresentation>],
           let sourceRelation = sourcePurpose.entities as? [Weight<EntityRepresentation>] {
            targetPurpose.entities = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        
        if let targetRelation = targetPurpose.states as? [Weight<Interest>],
           let sourceRelation = sourcePurpose.states as? [Weight<Interest>] {
            targetPurpose.states = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        try self.persistContext()
    }
    
    public func updateEntityRepresentation(_ sourceEntityRepresentation: EntityRepresentation) async throws {
        let reference = sourceEntityRepresentation.reference

        guard let targetEntity = findENtityRepresentationByReference(reference) else {
            addEntityRepresentation(sourceEntityRepresentation)
            try self.persistContext()
            throw PerspectiveError.noEntityForReference(reference)
        }
        if targetEntity.name != sourceEntityRepresentation.name { // Maybe create new? will not happen with current reference implementation
            print("Names of entities don't match! incoming: \(sourceEntityRepresentation.name) target: \(targetEntity.name)")
        }

        if let targetRelation = targetEntity.types as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceEntityRepresentation.types as? [Weight<EntityRepresentation>] {
            targetEntity.types = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.subTypes as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceEntityRepresentation.subTypes as? [Weight<EntityRepresentation>] {
            targetEntity.subTypes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.parts as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceEntityRepresentation.parts as? [Weight<EntityRepresentation>] {
            targetEntity.parts = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.partOf as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceEntityRepresentation.partOf as? [Weight<EntityRepresentation>] {
            targetEntity.partOf = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.interests as? [Weight<Interest>],
           let sourceRelation = sourceEntityRepresentation.interests as? [Weight<Interest>] {
            targetEntity.interests = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.purposes as? [Weight<Purpose>],
           let sourceRelation = sourceEntityRepresentation.purposes as? [Weight<Purpose>] {
            targetEntity.purposes = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.entities as? [Weight<EntityRepresentation>],
           let sourceRelation = sourceEntityRepresentation.entities as? [Weight<EntityRepresentation>] {
            targetEntity.entities = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }

        if let targetRelation = targetEntity.states as? [Weight<Interest>],
           let sourceRelation = sourceEntityRepresentation.states as? [Weight<Interest>] {
            targetEntity.states = try await self.updateRelation(targetRelation, sourceRelation: sourceRelation)
        }
        try self.persistContext()
    }
    
    public func updateRelation<T>(_ targetRelation: [Weight<T>], sourceRelation: [Weight<T>]) async throws -> [Weight<T>] {
        var targetRelation = targetRelation
        for sourceWeighted in sourceRelation {
            
            
            if let index = targetRelation.firstIndex(where: { $0.reference == sourceWeighted.reference }) {
                
                targetRelation[index].weight = sourceWeighted.weight
                do {
                    let targetNode = try await sourceWeighted.node // Should we just use value and reference?
                    targetRelation[index].value = targetNode
                } catch {
                    targetRelation[index].reference = sourceWeighted.reference
                }
            } else {
                targetRelation.append(sourceWeighted)
            }
        }
        return targetRelation
    }
    
    public func pimpEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let interestFacilitator = Facilitator<Interest>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "interestFacilitator") {
            encoder.userInfo[userInfoKey] = interestFacilitator
        }
        
        let purposeFacilitator = Facilitator<Purpose>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "purposeFacilitator") {
            encoder.userInfo[userInfoKey] = purposeFacilitator
        }
        let entityRepresentationFacilitator = Facilitator<EntityRepresentation>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "entityRepresentationsFacilitator") {
            encoder.userInfo[userInfoKey] = entityRepresentationFacilitator
        }
        if let userInfoKey = CodingUserInfoKey(rawValue: "entityFacilitator") {
            encoder.userInfo[userInfoKey] = entityRepresentationFacilitator
        }
        
        if let userInfoKey = CodingUserInfoKey(rawValue: "context") {
            encoder.userInfo[userInfoKey] = self
        }
        return encoder
    }
    
    public func pimpDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let interestFacilitator = Facilitator<Interest>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "interestFacilitator") {
            decoder.userInfo[userInfoKey] = interestFacilitator
        }
        
        let purposeFacilitator = Facilitator<Purpose>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "purposeFacilitator") {
            decoder.userInfo[userInfoKey] = purposeFacilitator
        }
        
        let entityRepresentationFacilitator = Facilitator<EntityRepresentation>()
        if let userInfoKey = CodingUserInfoKey(rawValue: "entityRepresentationsFacilitator") {
            decoder.userInfo[userInfoKey] = entityRepresentationFacilitator
        }
        if let userInfoKey = CodingUserInfoKey(rawValue: "entityFacilitator") {
            decoder.userInfo[userInfoKey] = entityRepresentationFacilitator
        }
        
        if let userInfoKey = CodingUserInfoKey(rawValue: "context") {
            decoder.userInfo[userInfoKey] = self
        }
        return decoder
    }
    
    // Methods related to scanner and advertising purposes

    private func weightedReference<T: PerspectiveNode & Codable>(_ weighted: Weight<T>) -> String? {
        return weighted.reference ?? weighted.value?.reference
    }

    public func getActivePurposes(minWeight: Double = 0.0, limit: Int = Int.max) -> [Weight<Purpose>] {
        let filtered = activePurposes
            .filter { $0.weight >= minWeight }
            .sorted(by: { $0.weight > $1.weight })
        return Array(filtered.prefix(max(0, limit)))
    }

    public func getActiveInterests(minWeight: Double = 0.0, limit: Int = Int.max) -> [Weight<Interest>] {
        let filtered = activeInterests
            .filter { $0.weight >= minWeight }
            .sorted(by: { $0.weight > $1.weight })
        return Array(filtered.prefix(max(0, limit)))
    }

    public func getActiveEntities(minWeight: Double = 0.0, limit: Int = Int.max) -> [Weight<EntityRepresentation>] {
        let filtered = activeEntities
            .filter { $0.weight >= minWeight }
            .sorted(by: { $0.weight > $1.weight })
        return Array(filtered.prefix(max(0, limit)))
    }

    public func upsertActivePurpose(weighedPurpose: Weight<Purpose>) {
        if let ref = weightedReference(weighedPurpose),
           let index = activePurposes.firstIndex(where: { weightedReference($0) == ref }) {
            activePurposes[index] = weighedPurpose
        } else {
            activePurposes.append(weighedPurpose)
        }
        activePurposes = activePurposes.sorted(by: { $0.weight < $1.weight })
    }

    public func upsertActiveInterest(weighedInterest: Weight<Interest>) {
        if let ref = weightedReference(weighedInterest),
           let index = activeInterests.firstIndex(where: { weightedReference($0) == ref }) {
            activeInterests[index] = weighedInterest
        } else {
            activeInterests.append(weighedInterest)
        }
        activeInterests = activeInterests.sorted(by: { $0.weight < $1.weight })
    }
    
    public func addActivePurpose(weighedPurpose: Weight<Purpose>) throws {
        if activePurposes.contains(where: { purpose in
            if let existingRef = weightedReference(purpose),
               let newRef = weightedReference(weighedPurpose),
               existingRef == newRef {
                return true
            }
            if let existing = purpose.value as? PerspectiveNodeImpl,
               let new = weighedPurpose.value as? PerspectiveNodeImpl {
                return existing == new
            }
            return false
        }
        ) {
            throw PerspectiveError.purposeExist
        }
        activePurposes.append(weighedPurpose)
        activePurposes = activePurposes.sorted(by: { $0.weight < $1.weight })
        // save
        
    }
    
    public func addActiveInterest(weighedInterest: Weight<Interest>) throws {
        if activeInterests.contains(where: { interest in
            if let existingRef = weightedReference(interest),
               let newRef = weightedReference(weighedInterest),
               existingRef == newRef {
                return true
            }
            if let existing = interest.value as? PerspectiveNodeImpl,
               let new = weighedInterest.value as? PerspectiveNodeImpl {
                return existing == new
            }
            return false
        }
        ) {
            throw PerspectiveError.purposeExist
        }
        activeInterests.append(weighedInterest)
        activeInterests = activeInterests.sorted(by: { $0.weight < $1.weight })
    }
    
    public func addActiveEntity(weighedEntity: Weight<EntityRepresentation>) throws {
        if activeEntities.contains(where: { entity in
            if let existingRef = weightedReference(entity),
               let newRef = weightedReference(weighedEntity),
               existingRef == newRef {
                return true
            }
            if let existing = entity.value as? PerspectiveNodeImpl,
               let new = weighedEntity.value as? PerspectiveNodeImpl {
                return existing == new
            }
            return false
        }
        ) {
            throw PerspectiveError.purposeExist
        }
        activeEntities.append(weighedEntity)
        activeEntities = activeEntities.sorted(by: { $0.weight < $1.weight })
    }
    
    // not needed method I would think?
    private func sortActivePurposes() {
        return activePurposes = activePurposes.sorted(by: { $0.weight < $1.weight })
    }
    
//    This can be a simple subset of purposes, maybe without PII. F.ex to be used with EntityScanner
    func advertisedPurposeDict() -> [String: String] {
        
        return ["Test" : "Test"]
    }
    
    
    // Sets active purposes to decoded jason
    public func setPurposeJsonData(data: Data) throws {
        let decoder = self.pimpDecoder()
        self.activePurposes = try decoder.decode([Weight<Purpose>].self, from: data)
    }
    
    public func getPurposeJsonData() throws -> Data {
        let encoder = self.pimpEncoder()
        let purposeJsonData = try encoder.encode(self.activePurposes)
        return purposeJsonData
    }
}
