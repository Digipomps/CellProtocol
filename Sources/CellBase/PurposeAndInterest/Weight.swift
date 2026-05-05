// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation

public struct Weight<T: PerspectiveNode & Codable> :  Weighted, Codable {
    
    

    
    public var weight: Double
    
    public var value: PerspectiveNode?
    
    public var reference: String?
    
    weak var context: Perspective?
    var node: T {
        
        get async throws {
            if let value = value as? T {
                CellBase.diagnosticLog("Weight.node returning inline value \(value.name)", domain: .semantics)
                return value
            }
            CellBase.diagnosticLog("Weight.node resolving reference \(String(describing: reference))", domain: .semantics)
            //lookup reference
            guard let context = self.context,
                  let reference = self.reference else {
                throw ReferenceLookupError.referenceNotFound
            }

            if T.self == Interest.self, let value = await context.findInterestByReference(reference) as? T {
                return value
            }
            if T.self == Purpose.self, let value = await context.findPurposeByReference(reference) as? T {
                return value
            }
            if T.self == EntityRepresentation.self, let value = await context.findENtityRepresentationByReference(reference) as? T {
                return value
            }

            throw ReferenceLookupError.referenceNotFound
            
        }
        
        
//        get {
//            return value as! T // Will crash...
//        }
    }
    
    
    public init(weight: Double, value: T? = nil, reference: String? = nil) {
        self.weight = weight
        self.value = value
        self.reference = reference
//        self.type = T.self
    }
    
    enum CodingKeys: CodingKey {
        case weight
        case value
//        case type
        case reference
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.weight = try container.decode(Double.self, forKey: .weight)

        
        self.reference = try container.decodeIfPresent(String.self, forKey: .reference)
        self.value = try container.decodeIfPresent(T.self, forKey: .value)
        if let userInfoKey = CodingUserInfoKey(rawValue: "context"),
           let context = decoder.userInfo[userInfoKey] as? Perspective {
            self.context = context
        }
        
        
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var facilitatorNameKey = "type not set"
        if T.self == Interest.self {
            facilitatorNameKey = "interestFacilitator"
        } else if  T.self == Purpose.self {
            facilitatorNameKey = "purposeFacilitator"
        } else if  T.self == EntityRepresentation.self {
            facilitatorNameKey = "entityRepresentationsFacilitator"
        } else {
            CellBase.diagnosticLog("Weight.encode missing facilitator type match", domain: .semantics)
        }
        guard let userInfoKey = CodingUserInfoKey(rawValue: facilitatorNameKey), // Hmmm this must be thought through
           let facilitator = encoder.userInfo[userInfoKey] as? Facilitator<T> else {
            throw ReferenceLookupError.noInterestEncodingFacilitator
        }
        if  let value = self.value {
            let ref = value.reference
            if facilitator.keyExists(ref) {
                try container.encode(ref, forKey: .reference)
            } else {
                facilitator.referenceablesDict[ref] = (value as! T)
                try container.encode(self.value as! T, forKey: .value)
            }
        } else {
            try container.encode(reference, forKey: .reference)
        }
        
        
        try container.encode(self.weight, forKey: .weight)

    }
    
    public mutating func update( with sourceWeighted: Weight<T> ) async {
        self.weight = sourceWeighted.weight
        do {
            let targetNode = try await sourceWeighted.node
            self.value = targetNode
        } catch {
            self.reference = sourceWeighted.reference
        }
    }
    
    public mutating func update(with sourceWeighted: Weighted) async {
//        self.weight = sourceWeighted.weight
//        if case let sourceWeighted as? Weight<PerspectiveNodeImpl> {
//            do {
//                
//                let targetNode = try await sourceWeighted.node             self.value = targetNode
//            } catch {
//                self.reference = sourceWeighted.reference
//            }
//        }
    }
}
