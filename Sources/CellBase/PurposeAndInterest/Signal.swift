// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation








public struct Signal {
    // which relationship are we following?
    // what is the target weight?
    // what is the tolerance ± ?
    public var relationship: PerspectiveRelationship
    public var weight: Double
    public var tolerance: Double
    public var token: String
    public var ttl: Double = 1.0 // seconds
    public var hops: Int = 1
    public var collector: HitCollector? = nil
    
    public init(relationship: PerspectiveRelationship, weight: Double, tolerance: Double, token: String, ttl: Double = 1.0, hops: Int = 1, collector: HitCollector? = nil) {
        self.relationship = relationship
        self.weight = weight
        self.tolerance = tolerance
        self.token = token
        self.ttl = ttl
        self.hops = hops
        self.collector = collector
    }
}

public actor HitCollector {
    private var refs = Set<String>()
    public func record(_ ref: String) { refs.insert(ref) }
    public func results() -> [String] { Array(refs) }
}
