// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum DiagnosticProbeCodec {
    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T?) throws -> ValueType {
        guard let value else {
            return .null
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    static func string(from value: ValueType?) -> String? {
        guard let value else { return nil }

        switch value {
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .integer(number):
            return String(number)
        case let .number(number):
            return String(number)
        default:
            return nil
        }
    }

    static func int(from value: ValueType?) -> Int? {
        guard let value else { return nil }

        switch value {
        case let .integer(number):
            return number
        case let .number(number):
            return number
        case let .string(string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func object(from value: ValueType?) -> Object? {
        guard case let .object(object)? = value else {
            return nil
        }
        return object
    }

    static func list(from value: ValueType?) -> [ValueType]? {
        guard case let .list(list)? = value else {
            return nil
        }
        return list
    }
}
