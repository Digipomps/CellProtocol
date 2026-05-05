// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public indirect enum ValueType: Codable {
    case flowElement(FlowElement)
    case bool(Bool)
    case number(Int)
    case integer(Int)
    case float(Double)
    case string(String)
    case object(Object)
    case list(ValueTypeList)
    case data(Data)
    case keyValue(KeyValue)
    case setValueState(SetValueState)
    case setValueResponse(SetValueResponse)
    case cellConfiguration(CellConfiguration)
    case cellReference(CellReference)
    case verifiableCredential(VCClaim)
    case identity(Identity)
    case connectContext(ConnectContext)
    case connectState(ConnectState)
    case contractState(AgreementState)
    case signData(Data)
    case signature(Data)
    case agreementPayload(Agreement)
    case description(AnyCell)
    case cell(Emit & Codable)
    case null

    public init(from decoder: Decoder) throws {
        self = try ValueTypeCodec.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try ValueTypeCodec.encode(self, to: encoder)
    }
}

private enum ValueTypeCodec {
    private typealias WrappedDecoder = (SingleValueDecodingContainer) throws -> ValueType

    private static let wrappedDecoders: [String: WrappedDecoder] = [
        "&flowElement": { .flowElement(try $0.decode(FlowElement.self)) },
        "&connectContext": { .connectContext(try $0.decode(ConnectContext.self)) },
        "&connectState": { .connectState(try $0.decode(ConnectState.self)) },
        "&agreementState": { .contractState(try $0.decode(AgreementState.self)) },
        "&agreementPayload": { .agreementPayload(try $0.decode(Agreement.self)) },
        "&description": { .description(try $0.decode(AnyCell.self)) },
        "&keyValue": { .keyValue(try $0.decode(KeyValue.self)) },
        "&setValueState": { .setValueState(try $0.decode(SetValueState.self)) },
        "&setValueResponse": { .setValueResponse(try $0.decode(SetValueResponse.self)) },
        "&cellConfiguration": { .cellConfiguration(try $0.decode(CellConfiguration.self)) },
        "&cellReference": { .cellReference(try $0.decode(CellReference.self)) },
        "&verifiableCredential": { .verifiableCredential(try $0.decode(VCClaim.self)) },
        "sign": { .signData(try $0.decode(Data.self)) },
        "&signature": { .signature(try $0.decode(Data.self)) },
        "&cell": { .cell(try $0.decode(AnyCell.self)) }
    ]

    static func decode(from decoder: Decoder) throws -> ValueType {
        if let wrappedValue = try decodeWrappedValue(from: decoder) {
            return wrappedValue
        }

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

    static func encode(_ value: ValueType, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let .flowElement(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .float(value):
            try container.encode(value)
        case let .data(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .list(value):
            try container.encode(value)
        case let .identity(value):
            try container.encode(value)
        case let .connectContext(value):
            try container.encode(value)
        case let .connectState(value):
            try container.encode(value)
        case let .contractState(value):
            try container.encode(value)
        case let .agreementPayload(value):
            try container.encode(value)
        case let .description(value):
            try container.encode(value)
        case let .keyValue(value):
            try container.encode(value)
        case let .setValueState(value):
            try container.encode(value)
        case let .setValueResponse(value):
            try container.encode(value)
        case let .cellConfiguration(value):
            try container.encode(value)
        case let .cellReference(value):
            try container.encode(value)
        case let .verifiableCredential(value):
            try container.encode(value)
        case let .signData(value):
            try container.encode(value)
        case let .signature(value):
            try container.encode(value)
        case .cell:
            try container.encode("value.announce(for: Identity())")
        case .null:
            try container.encodeNil()
        }
    }

    private static func decodeWrappedValue(from decoder: Decoder) throws -> ValueType? {
        guard
            let key = decoder.codingPath.last?.stringValue,
            let wrappedDecoder = wrappedDecoders[key]
        else {
            return nil
        }

        return try wrappedDecoder(try decoder.singleValueContainer())
    }

    private static func decodePrimitiveValue(from decoder: Decoder) throws -> ValueType? {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            return .null
        }
        if let value = try? container.decode(Bool.self) {
            return .bool(value)
        }
        if let value = try? container.decode(Int.self) {
            return .integer(value)
        }
        if let value = try? container.decode(Double.self) {
            return .float(value)
        }
        if let value = try? container.decode(String.self) {
            return .string(value)
        }
        return nil
    }

    private static func decodeObject(from decoder: Decoder) throws -> ValueType? {
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

    private static func decodeList(from decoder: Decoder) throws -> ValueType? {
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

extension ValueType {
    public func stringValue() throws -> String {
        switch self {
        case .string(let string):
            return string
        case .null:
            return "null"
        default:
            // should throw here
            return "null"
        }
    }
}

extension ValueType {
    // Enkel init fra "literal" (for match-verdier)
     public static func fromLiteral(_ lit: Literal) -> ValueType {
         switch lit {
         case .bool(let b): return .bool(b)
         case .int(let i): return .integer(i)
         case .double(let d): return .float(d)
         case .string(let s): return .string(s)
         }
     }
}

extension ValueType { // Is thhis ever used any more?
    public func publisher() -> AnyPublisher<ValueType, Never> {
        let valuePublisher = Just(self).map { (value) -> ValueType in
            return value
        }
        return valuePublisher.eraseToAnyPublisher()
    }
}

extension ValueType: Equatable {
    public static func == (lhs: ValueType, rhs: ValueType) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (let .string(lhsString), let .string(rhsString)):
                    return lhsString == rhsString
        case (let .flowElement(lhsFlowElement), let .flowElement(rhsFlowElement)):
            return lhsFlowElement == rhsFlowElement
        case (let .bool(lhsBool), let .bool(rhsBool)):
            return lhsBool == rhsBool
        case (let .number(lhsNumber), let .number(rhsNumber)):
            return lhsNumber == rhsNumber
        case (let .integer(lhsInteger), let .integer(rhsInteger)):
            return lhsInteger == rhsInteger
        case (let .float(lhsFloat), let .float(rhsFloat)):
            return lhsFloat == rhsFloat
        case (.object(_), _):
            return false
        case (.list(_), _):
            return false
        case (.data(_), _):
            return false
        case (.keyValue(_), _):
            return false
        case (.setValueState(_), _):
            return false
        case (.cellConfiguration(_), _):
            return false
        case (.verifiableCredential(_), _):
            return false
        case (.identity(_), _):
            return false
        case (.connectState(_), _):
            return false
        case (.contractState(_), _):
            return false
        case (.signData(_), _):
            return false
        case (.signature(_), _):
            return false
        case (.agreementPayload(_), _):
            return false
        case (.description(_), _):
            return false
        case (.cell(_), _):
            return false
        case (_, .flowElement(_)):
            return false
        case (_, .bool(_)):
            return false
        case (_, .number(_)):
            return false
        case (_, .object(_)):
            return false
        case (_, .list(_)):
            return false
        case (_, .data(_)):
            return false
        case (_, .keyValue(_)):
            return false
        case (_, .setValueState(_)):
            return false
        case (_, .cellConfiguration(_)):
            return false
        case (_, .verifiableCredential(_)):
            return false
        case (_, .identity(_)):
            return false
        case (_, .connectState(_)):
            return false
        case (_, .contractState(_)):
            return false
        case (_, .signData(_)):
            return false
        case (_, .signature(_)):
            return false
        case (_, .agreementPayload(_)):
            return false
        case (_, .description(_)):
            return false
        case (_, .cell(_)):
            return false
        case (.flowElement(_), .string(_)):
            return false
        case (.number(_), _):
            return false
        case (_, .null):
            return false
        case (.null, _):
            return false
        default:
            return false
        }
    }
}

extension ValueType {
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(self)
        return String(data: jsonData, encoding: .utf8) ?? "err"
    }
}


extension ValueType: Identifiable {
    public var id: Int {
        hashValue
    }
}


extension ValueType: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .flowElement(value):
            hasher.combine("flowElement")
            hasher.combine(value.id)
        case let .bool(value):
            hasher.combine("bool")
            hasher.combine(value)
        case let .number(value):
            hasher.combine("number")
            hasher.combine(value)
        case let .integer(value):
            hasher.combine("integer")
            hasher.combine(value)
        case let .float(value):
            hasher.combine("float")
            hasher.combine(value)
        case let .string(value):
            hasher.combine("string")
            hasher.combine(value)
        case let .object(value):
            hasher.combine("object")
            hasher.combine(value)
        case let .list(value):
            hasher.combine("list")
            hasher.combine(value)
        case let .data(value):
            hasher.combine("data")
            hasher.combine(value)
        case let .keyValue(value):
            hasher.combine("keyValue")
            hasher.combine(value)
        case let .setValueState(value):
            hasher.combine("setValueState")
            hasher.combine(value)
        case let .setValueResponse(value):
            hasher.combine("setValueResponse")
            hasher.combine(value.state)
            hasher.combine(value.value)
        case let .cellConfiguration(value):
            hasher.combine("cellConfiguration")
            hasher.combine(value.uuid)
        case let .cellReference(value):
            hasher.combine("cellReference")
            hasher.combine(value.id)
        case let .verifiableCredential(value):
            hasher.combine("verifiableCredential")
            hasher.combine(value.uuid)
        case let .identity(value):
            hasher.combine("identity")
            hasher.combine(value.uuid)
        case let .connectContext(value):
            hasher.combine("connectContext")
            hash(value.sourceRepresentation, into: &hasher)
            hash(value.targetRepresentation, into: &hasher)
            hasher.combine(value.identity?.uuid)
        case let .connectState(value):
            hasher.combine("connectState")
            hasher.combine(value)
        case let .contractState(value):
            hasher.combine("contractState")
            hasher.combine(value)
        case let .signData(value):
            hasher.combine("signData")
            hasher.combine(value)
        case let .signature(value):
            hasher.combine("signature")
            hasher.combine(value)
        case let .agreementPayload(value):
            hasher.combine("agreementPayload")
            hasher.combine(value.uuid)
        case let .description(value):
            hasher.combine("description")
            hasher.combine(value.uuid)
        case let .cell(value):
            hasher.combine("cell")
            hasher.combine(value.uuid)
        case .null:
            hasher.combine("null")
        }
    }

    public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }

    private func hash(_ representation: AbsorbCellRepresentation, into hasher: inout Hasher) {
        switch representation {
        case .embedded(let cell):
            hasher.combine("embedded")
            hasher.combine((cell as? Emit)?.uuid)
        case .reference(let uuid):
            hasher.combine("reference")
            hasher.combine(uuid)
        case .none:
            hasher.combine("none")
        }
    }

    private func hash(_ representation: EmitCellRepresentation, into hasher: inout Hasher) {
        switch representation {
        case .embedded(let cell):
            hasher.combine("embedded")
            hasher.combine(cell.uuid)
        case .reference(let uuid):
            hasher.combine("reference")
            hasher.combine(uuid)
        case .none:
            hasher.combine("none")
        }
    }
    
}

extension ValueType {
    /// Access nested values when this ValueType is an object
    /// Usage: let child = value["someKey"]
    public subscript(_ key: String) -> ValueType? {
        switch self {
        case .object(let object):
            return try? object.get(keypath: key)
        default:
            return nil
        }
    }
}

extension SetValueResponse {
    public var hashValue: Int {
        return String("\(self.state)\(self.value)").hashValue
    }
}

 public enum Literal: CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        }
    }
}
