// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

extension String {
    var utf8Data:Data? {
        data(using: .utf8)
    }
}

extension JSONDecoder {
    public func decode<T:Decodable>(_ type: T.Type, fromString string: String) throws -> T {
        let data = string.utf8Data ?? Data()
        return try decode(type, from: data)
    }
}
