// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ValueTypeViewFinder.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 03/04/2024.
//

import Foundation
import CellBase
import SwiftUI

public typealias VTVF = ValueTypeViewFinder

public struct ValueTypeViewFinder {
    
    @ViewBuilder public static func view(for valueType: ValueType ) -> some View {
    
            switch valueType {
            case .string(let value):
                 Text(value)
                
            case .bool(let value):
                Text(String(value))
                
            case .data(let value):
                Text(value.base64EncodedString())
                
            case .float(let value):
                Text(String(value))
                
            case .integer(let value):
                Text(String(value))
                
            case .list(let value):
                ListView(list: value)
                
            case .number(let value):
                Text(String(value))
                
            case .object(let value):
                ObjectView(object: value)
                
            case .verifiableCredential(let value):
                Text("View for Verifiable Credential not yet implemented")
                
            default:
                let jsonData = try? JSONEncoder().encode(valueType)
                if jsonData == nil {
                    Text("Encoding json yielded nil")
                }
                
                let jsonString = String(data: jsonData!, encoding: .utf8)
                
                if jsonString == nil {
                    Text("Converting to jsonString yielded nil")
                } else {
                    Text(jsonString!)
                }
            }
            
        
            
    }
    
}
