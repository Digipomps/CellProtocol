// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// The condition is that one have to be logged in...
public struct LoginCondition : Codable, Condition {
    public var uuid: String
    public func resolve(context: ConnectContext) async {
        
    }
    
    public var name: String
    public var loginEndpoint: String
    public var type: Int = 0
    
    public func isMet(context: ConnectContext) -> ConditionState {
        var state = ConditionState.unresolved
        return state
    }
    public init() {
        uuid = UUID().uuidString
        name = "Test Grant Condition"
        loginEndpoint = ""
    }
}
