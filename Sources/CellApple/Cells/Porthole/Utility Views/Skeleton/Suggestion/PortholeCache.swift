// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PortholeCache.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 09/01/2026.
//
import Foundation
import CellBase

public actor PortholeCache {
    private var cache: Object = [:]

    
    public func get(_ keypath: String) -> ValueType? {
        return try? self.cache.get(keypath: keypath)
    }
    
    public func set(_ value: ValueType, for keypath: String)  {
//        print("set(\(value), for: \(keypath))")
        try? self.cache.set(value, keypath: keypath) // TODO: Fix so we can delete - aka send nil
    }

    /// Subscript access for keypath-based cache operations.
    /// Usage (from async context):
    ///   let v = await cache["some.path"]
    ///   await cache["some.path"] = .string("value")
    public subscript(_ keypath: String) -> ValueType? {
        get {
            return try? self.cache.get(keypath: keypath)
        }
        set {
            if let v = newValue {
                try? self.cache.set(v, keypath: keypath)
            }
        }
    }
}
