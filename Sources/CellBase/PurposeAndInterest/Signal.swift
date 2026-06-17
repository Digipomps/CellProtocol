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
    public var localVariables: Object = [:]
    public var collector: HitCollector? = nil
    
    public init(
        relationship: PerspectiveRelationship,
        weight: Double,
        tolerance: Double,
        token: String,
        ttl: Double = 1.0,
        hops: Int = 1,
        localVariables: Object = [:],
        collector: HitCollector? = nil
    ) {
        self.relationship = relationship
        self.weight = weight
        self.tolerance = tolerance
        self.token = token
        self.ttl = ttl
        self.hops = hops
        self.localVariables = localVariables
        self.collector = collector
    }
}

public actor HitCollector {
    private var refs = Set<String>()
    private var hitsByRef = [String: MatchHit]()

    public func record(_ ref: String) { refs.insert(ref) }

    public func record(_ hit: MatchHit) {
        refs.insert(hit.ref)
        if let existing = hitsByRef[hit.ref] {
            if hit.score > existing.score || (hit.score == existing.score && hit.depth < existing.depth) {
                hitsByRef[hit.ref] = hit
            }
        } else {
            hitsByRef[hit.ref] = hit
        }
    }

    public func results() -> [String] { Array(refs) }

    public func hitResults() -> [MatchHit] {
        hitsByRef.values.sorted {
            if $0.score == $1.score {
                if $0.depth == $1.depth {
                    return $0.ref < $1.ref
                }
                return $0.depth < $1.depth
            }
            return $0.score > $1.score
        }
    }
}
