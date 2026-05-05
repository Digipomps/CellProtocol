// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 26/11/2022.
//

import Foundation

public typealias FlowElementIntercept = ((FlowElement, Identity) async -> FlowElement?)
public typealias SetValueForKeyIntercept = ((ValueType, Identity) async -> Void)
public typealias ValueForKeyIntercept = ((Identity) async -> (ValueType))

public typealias SetValueIntercept = ((String, ValueType, Identity) async throws -> ValueType?)
public typealias GetValueIntercept = (( String, Identity) async throws -> (ValueType))

actor Intercepts {
    var feedIntercept: FlowElementIntercept?
    var interceptSetValueForKeys: [String : SetValueForKeyIntercept] = [:]
    var interceptValueForKeys: [String : ValueForKeyIntercept] = [:]
    
    var interceptSetValueForKeypaths: [String : SetValueIntercept] = [:]
    var interceptValueForKeypaths: [String : GetValueIntercept] = [:]
    
    func storeFeedIntercept(_ intercept: @escaping FlowElementIntercept) {
        feedIntercept = intercept
    }
    func loadFeedIntercept() -> FlowElementIntercept? {
        return feedIntercept
    }

    func storeInterceptValueForKey(key: String, intercept: @escaping ValueForKeyIntercept) {
        interceptValueForKeys[key] = intercept
    }
    func loadInterceptValueForKey(key: String) -> ValueForKeyIntercept? {
        return interceptValueForKeys[key]
    }
    func storeInterceptSetValueForKey(key: String, intercept: @escaping SetValueForKeyIntercept) {
        interceptSetValueForKeys[key] = intercept
    }
    func loadInterceptSetValueForKey(key: String) -> SetValueForKeyIntercept? {
        return interceptSetValueForKeys[key]
    }
    
    // Keypath lookup
    func storeInterceptGet(keypath: String, intercept: @escaping GetValueIntercept) {
        interceptValueForKeypaths[keypath] = intercept
    }
    func loadInterceptGet(keypath: String) -> GetValueIntercept? {
        return interceptValueForKeypaths[keypath]
    }
    func storeInterceptSet(keypath: String, intercept: @escaping SetValueIntercept) {
        interceptSetValueForKeypaths[keypath] = intercept
    }
    func loadInterceptSet(keypath: String) -> SetValueIntercept? {
        return interceptSetValueForKeypaths[keypath]
    }
}
