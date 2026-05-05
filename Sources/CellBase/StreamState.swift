// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 03/05/2024.
//

import Foundation
public enum StreamState : String, Error {
    case flowing
    case suspended
    case notConnected
    case denied
}

extension StreamState : Codable {
    
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
    
}
