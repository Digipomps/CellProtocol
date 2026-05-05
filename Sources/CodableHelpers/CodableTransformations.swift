// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct JSONTransformation {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    
    public init() {}
    
    public func transform<T: Decodable>(into type: T.Type, from input: Encodable) throws -> T {
        let data = try encoder.encode(input)
        return try decoder.decode(type, from: data)
    }
}
