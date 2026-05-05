// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation


// Goals must have a machine solvable way to determine if it is resolved. But that goal could be to get a human to press a button
//Should we differ between goals that are ongoing and goals that has a definitive end?
public class Goal: GeneralCell {
//    public var name: String
    public var goalDefinitionString: String // This is still undefined but should be a well defined test that is measurable
//    public init(name: String, goalDefinitionString: String) {
//        self.name = name
//        self.goalDefinitionString = goalDefinitionString
//    }
    
    required public init(owner: Identity) async {
        fatalError("init(owner:) has not been implemented")
    }
    
    enum CodingKeys: CodingKey {
        case goalDefinitionString
        case generalCell
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalDefinitionString = try container.decode(String.self, forKey: .goalDefinitionString)
        try super.init(from: decoder)
        
//        // NB! This may not always work and could end up biting us in the butt at some point BEWARE!!!
//        Task {
//            await setupPermissions(owner: getOwner())
//            await setupKeys(owner: getOwner())
//        }
    }
    
    public func setName(name: String) {
        
    }
    
    /*
     Goal definitions is a rule for when the goal is resolved - and when it should be aborted?
     
     <payload>.<somekeypath> = | < | > <some value>
     f.ex flow.
     
     need a cell configuration too set up events we're waiting for
     
     
     */
    
    public func setGoalDefinition(name: String) {
        
    }
    
    public func setupGoalResolver(resolver: CellConfiguration) {
        
    }
    
}
