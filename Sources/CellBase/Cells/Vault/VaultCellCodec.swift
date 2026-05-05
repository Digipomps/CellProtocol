// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum VaultCellCodec {
    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    static func string(from value: ValueType?) -> String? {
        guard let value else { return nil }

        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    static func success(operation: String, payload: ValueType) -> ValueType {
        .object([
            "status": .string("ok"),
            "operation": .string(operation),
            "result": payload
        ])
    }

    static func error(_ payload: VaultCellErrorPayload) -> ValueType {
        if let encoded = try? encode(payload) {
            return encoded
        }

        return .object([
            "status": .string("error"),
            "operation": .string(payload.operation),
            "code": .string(payload.code),
            "message": .string(payload.message),
            "field_errors": .list([])
        ])
    }
}
