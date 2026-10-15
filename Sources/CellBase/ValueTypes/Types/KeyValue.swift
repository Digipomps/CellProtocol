// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct KeyValue: Codable, Hashable {
    public var key: String
    public var value: ValueType? = nil
    public var target: String? = nil
    
    enum CodingKeys: String, CodingKey
    {
        case key
        case string
        case number
        case integer
        case float
        case object
        case list
        case value
        case target
    }
    
    public init(key: String, value: ValueType? = nil, target: String? = nil) {
        self.key = key
        self.value = value
        self.target = target
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        target = try values.decodeIfPresent(String.self, forKey: .target)

        // Validate every known typed field before applying the legacy priority.
        let string = try values.decodeIfPresent(String.self, forKey: .string).map(ValueType.string)
        let number = try values.decodeIfPresent(Int.self, forKey: .number).map(ValueType.number)
        let float = try values.decodeIfPresent(Double.self, forKey: .float).map(ValueType.float)
        let integer = try values.decodeIfPresent(Int.self, forKey: .integer).map(ValueType.integer)
        let object = try values.decodeIfPresent(WireObject.self, forKey: .object).map { ValueType.object($0.value) }
        let list = try values.decodeIfPresent(ValueTypeList.self, forKey: .list).map(ValueType.list)
        if let selected = [string, number, float, integer, object, list].compactMap({ $0 }).first {
            value = selected
            return
        }

        if let typedValue = try values.decodeIfPresent(ValueType.self, forKey: .value) {
            value = typedValue
        } else if values.contains(.value), (try? values.decodeNil(forKey: .value)) == true {
            value = .null
        }

    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(value)
        hasher.combine(target)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(target, forKey: .target)
        switch value {
        case let .object(value):
            try container.encode(WireObject(value), forKey: .object)
        
        case let .list(value):
            try container.encode(value, forKey: .list)
                       
        case let .string(value):
            try container.encode(value, forKey: .string)
            
        case let .number(value):
            try container.encode(value, forKey: .number)
            
        case let .integer(value):
            try container.encode(value, forKey: .integer)
            
        case let .float(value):
            try container.encode(value, forKey: .float)
        
        case nil:
            break
        
        default:
            try container.encode(value, forKey: .value)
        }
    }

    private static let typedValueDecodePriority: [CodingKeys] = [
        .string,
        .number,
        .float,
        .integer,
        .object,
        .list
    ]
}
