// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

extension Data {
    var utf8String: String? {
        String(data: self, encoding: .utf8)
    }
}

extension JSONEncoder {
    public func prettyEncode<T: Encodable>(_ input:T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try encoder.encode(input)).utf8String!
    }
}
