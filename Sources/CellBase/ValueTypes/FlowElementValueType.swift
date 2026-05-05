// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FlowElementValueType: Codable {
    case number(Int)
    case string(String)
    case data(Data)
    case bool(Bool)
    case object(Object)
    case list(ValueTypeList)
    
    public init(from decoder: Decoder) throws {
        self = try FlowElementValueTypeCodec.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .data(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value) //
        case let .list(value):
            try container.encode(value) //
            
        }
    }
}

private enum FlowElementValueTypeCodec {
    static func decode(from decoder: Decoder) throws -> FlowElementValueType {
        if let primitiveValue = try decodePrimitiveValue(from: decoder) {
            return primitiveValue
        }

        if let objectValue = try decodeObject(from: decoder) {
            return objectValue
        }

        if let listValue = try decodeList(from: decoder) {
            return listValue
        }

        throw DecodingPDSError.corruptedData
    }

    private static func decodePrimitiveValue(from decoder: Decoder) throws -> FlowElementValueType? {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            return .bool(value)
        }
        if let value = try? container.decode(Int.self) {
            return .number(value)
        }
        if let value = try? container.decode(String.self) {
            return .string(value)
        }
        return nil
    }

    private static func decodeObject(from decoder: Decoder) throws -> FlowElementValueType? {
        guard let keyedContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) else {
            return nil
        }

        var object = Object(propertyValues: [String: ValueType]())
        for key in keyedContainer.allKeys {
            guard let decodedObject = try? keyedContainer.decode(ValueType.self, forKey: key) else {
                continue
            }
            object[key.stringValue] = decodedObject
        }
        return .object(object)
    }

    private static func decodeList(from decoder: Decoder) throws -> FlowElementValueType? {
        guard var unkeyedContainer = try? decoder.unkeyedContainer() else {
            return nil
        }

        var list = ValueTypeList()
        while !unkeyedContainer.isAtEnd {
            guard let decodedObject = try? unkeyedContainer.decode(ValueType.self) else {
                continue
            }
            list.append(decodedObject)
        }
        return .list(list)
    }
}

extension FlowElementValueType {
    public func valueType() throws -> ValueType { // Make this more efficient - only first level that is FlowElementValueType?
        let selfJsonData = try JSONEncoder().encode(self)
        let valueTypes = try JSONDecoder().decode(ValueType.self, from: selfJsonData)
        return valueTypes
    }
}
