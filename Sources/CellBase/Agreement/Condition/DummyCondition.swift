// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct DummyCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var queryEndpoint: String // should be Endpoint, URL or GURL
    public var expectation: String
    
    public init() {
        uuid = UUID.init().uuidString
        name = "Condition name"
        queryEndpoint = "http://localhost/"
        expectation = "ok\n"
    }
    
    
    public func isMet(context: ConnectContext) -> ConditionState {
        var state = ConditionState.unresolved
        // test condition here
        let fileUrl = Bundle.main.url(forResource: "ConditionQueryEndPoint", withExtension: "txt")
        
        do {
            let contents = try String(contentsOf: fileUrl!, encoding: String.Encoding.utf8)
            print("\(contents)")
            if contents == expectation {
                state = .met
            }
            
            
        } catch {
            print("Reading contents of url failed. Error: \(error)")
        }
        
        return state
    }
    
    public func resolve(context: ConnectContext) async {
        
    }
}
