// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation

public class Facilitator<T> where T: Referenceable {
    var referenceablesDict = [String : T]()
    var interestNameReferences = [String : [String]]() // Name of interests pointing to references
//    var context: Interests? // Change to generics to get Purposes support
//    var context2: IntPurContext? // Change to generics to get Purposes support
//
    
    public init() {
    }
    
     func add(_ interest: T) where T: Referenceable {
        let key = interest.reference
        referenceablesDict[key] = interest
        
         if var interestRefList = interestNameReferences[interest.name] {
             interestRefList.append(interest.reference)
         } else {
             interestNameReferences[interest.name] = [interest.reference]
         }
         
    }
    
    func getValue(for reference: String) -> T? {
        return referenceablesDict[reference]
    }
    
    func keyExists(_ key: String) -> Bool {
        return referenceablesDict[key] != nil
    }
    func exists(_ interest: T) -> Bool {
        let key = interest.reference
        return referenceablesDict[key] != nil
    }
}
