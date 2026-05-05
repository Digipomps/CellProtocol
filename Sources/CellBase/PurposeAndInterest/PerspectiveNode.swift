// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 20/09/2023.
//

import Foundation
import CellBase

enum PerspectiveNodeRelation: String {
    case types
    case subTypes
    case partOf
    case parts
    case interests
    case purposes
    case entities
    case states
}

//enum StringEnumError: Error { ...redeclaration
//    case decodeError(String)
//}

extension PerspectiveNodeRelation: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

public class PerspectiveNodeImpl: PerspectiveNode, Referenceable {
    public var name: String = ""
    
    public var types: [Weighted] = []
    
    public var subTypes: [Weighted] = []
    
    public var parts: [Weighted]  = []
    
    public var partOf: [Weighted]  = []
    
    public var interests: [Weighted]  = []
    
    public var purposes: [Weighted] = []
    
    public var entities: [Weighted] = []
    
    public var states: [Weighted] = []
    
//    public var description: String?
    
    public var reference: String { // Interest id
        get {
            return name // For now we use the name
        }
    }
    
    public init() {
        
    }
    
    public required init(from decoder: any Decoder) throws {
        
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
    
    public func get(keypath: String) async throws {
        let keypathArray = keypath.split(separator: ".")
        var lastKey: String = "$"
        
        for currentKey in keypathArray {
            lastKey = String(currentKey)
            if let relation = PerspectiveNodeRelation(rawValue: lastKey) {
                
            } else {
                // Check out other relations
            }
            
        }
    }
    
    public func set(keypath: String, setValue: ValueType?) async throws {
        let keypathArray = keypath.split(separator: ".")
        
    }
}

extension PerspectiveNodeImpl: Equatable {
    public static func == (lhs: PerspectiveNodeImpl, rhs: PerspectiveNodeImpl) -> Bool {
        // TODO: Add comparison of relations
        return type(of: lhs) == type(of: rhs) && lhs.name == rhs.name
        
    }
}

//class TestNode: PerspectiveNodeImpl {
//    override init() {
//        super.init()
//        types = [Weight<Interest>]()
//    }
//}
