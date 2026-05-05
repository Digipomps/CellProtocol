// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 21/08/2023.
//

import Foundation

public enum PurposeRep: Codable {
    case value(Purpose)
    case reference(PurposeReference)
}

public enum PurposeRelationship {
    case interests
    case isA
    case hasA
    case actions
    case partOf
}

public enum PerspectiveRelationship {
    case purposes
    case interests
    case entities
    case states
    case types
    case parts
    case partOf
    case subTypes
    
}

public enum InterestRep: Codable {
    case value(Interest)
    case reference(Reference)
}

public enum ReferenceLookupError: Error {
    case referenceNotFound
    case malformedReference
    case noInterestEncodingFacilitator
    case noPurposeEncodingFacilitator
    case noContext
}

public protocol WeightedMatch {
    func match(signal: Signal) async throws
    func hit(_ signal: Signal) async throws
}

public protocol Weighted: Codable {
    var weight: Double { set get }
    
    var value: PerspectiveNode? { set get }
    var reference: String?  { set get }
    
    mutating func update(with sourceWeighted: Weighted ) async
}

enum WeightError: Error {
    case unknownType
}



public protocol Referenceable: Codable {
    var reference: String { get }
    var name: String { get }
}

public struct Reference: Referenceable, Codable {
    public var reference: String
    public var name: String
}

public protocol PerspectiveNode: Referenceable {
    var name: String { get set }
    var reference: String { get }
    var types: [Weighted] { get set }
    var subTypes: [Weighted] { get set }
    var parts: [Weighted] { get set }
    var partOf: [Weighted] { get set }
    var interests: [Weighted] { get set }
    var purposes: [Weighted] { get set }
    var entities: [Weighted] { get set }
    var states: [Weighted] { get set }
    
}



protocol InterestConstraint: Codable {
    func within() -> Bool
}


