// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

// the reason for that described here:
// https://medium.com/@sergey.gavrilyuk/dynamic-encodable-with-type-erasure-1875722b3171

import Foundation

public struct AnyEncodable: Encodable {
    var _encodeFunc: (Encoder) throws -> Void
    
    public init(_ encodable: Encodable) {
        func _encode(to encoder: Encoder) throws {
            try encodable.encode(to: encoder)
        }
        self._encodeFunc = _encode
    }
    public func encode(to encoder: Encoder) throws {
        try _encodeFunc(encoder)
    }
}
