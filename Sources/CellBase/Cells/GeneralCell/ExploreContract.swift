// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ExploreContractMethod: String, Codable {
    case get
    case set
}

public enum ExploreContract {
    public static let version = 1

    public enum Field {
        public static let contractVersion = "contractVersion"
        public static let key = "key"
        public static let method = "method"
        public static let input = "input"
        public static let returns = "returns"
        public static let permissions = "permissions"
        public static let required = "required"
        public static let flowEffects = "flowEffects"
        public static let summary = "summary"

        public static let type = "type"
        public static let description = "description"
        public static let properties = "properties"
        public static let requiredKeys = "requiredKeys"
        public static let item = "item"
        public static let oneOf = "oneOf"

        public static let trigger = "trigger"
        public static let topic = "topic"
        public static let contentType = "contentType"
        public static let minimumCount = "minimumCount"
        public static let causationKey = "causationKey"
    }

    public static func defaultContract(
        for key: String,
        method: ExploreContractMethod,
        summary: String = "*"
    ) -> ValueType {
        keyContract(
            key: key,
            method: method,
            input: method == .get ? .null : unknownSchema(description: "Input schema not specified"),
            returns: unknownSchema(description: "Return schema not specified"),
            permissions: [],
            required: false,
            flowEffects: [],
            summary: summary
        )
    }

    public static func keyContract(
        key: String,
        method: ExploreContractMethod,
        input: ValueType? = nil,
        returns: ValueType? = nil,
        permissions: [String] = [],
        required: Bool = false,
        flowEffects: [ValueType] = [],
        summary: String = "*"
    ) -> ValueType {
        var object = Object()
        object[Field.contractVersion] = .integer(version)
        object[Field.key] = .string(key)
        object[Field.method] = .string(method.rawValue)
        object[Field.input] = input ?? (method == .get ? .null : unknownSchema(description: "Input schema not specified"))
        object[Field.returns] = returns ?? unknownSchema(description: "Return schema not specified")
        object[Field.permissions] = .list(permissions.map(ValueType.string))
        object[Field.required] = .bool(required)
        object[Field.flowEffects] = .list(flowEffects)
        object[Field.summary] = .string(summary)
        return normalizeSchema(key: key, schema: .object(object), description: .string(summary))
    }

    public static func schema(type: String, description: String? = nil) -> ValueType {
        var object = Object()
        object[Field.type] = .string(canonicalTypeName(type))
        if let description {
            object[Field.description] = .string(description)
        }
        return .object(object)
    }

    public static func objectSchema(
        properties: Object = [:],
        requiredKeys: [String] = [],
        description: String? = nil
    ) -> ValueType {
        var object = Object()
        object[Field.type] = .string("object")
        object[Field.properties] = .object(properties)
        object[Field.requiredKeys] = .list(requiredKeys.map(ValueType.string))
        if let description {
            object[Field.description] = .string(description)
        }
        return .object(object)
    }

    public static func listSchema(
        item: ValueType = unknownSchema(),
        description: String? = nil
    ) -> ValueType {
        var object = Object()
        object[Field.type] = .string("list")
        object[Field.item] = normalizeSchemaDescriptor(item)
        if let description {
            object[Field.description] = .string(description)
        }
        return .object(object)
    }

    public static func oneOfSchema(
        options: [ValueType],
        description: String? = nil
    ) -> ValueType {
        var object = Object()
        object[Field.oneOf] = .list(options.map(normalizeSchemaDescriptor))
        if let description {
            object[Field.description] = .string(description)
        }
        return .object(object)
    }

    public static func unknownSchema(description: String = "Unspecified") -> ValueType {
        schema(type: "unknown", description: description)
    }

    public static func flowEffect(
        trigger: ExploreContractMethod,
        topic: String,
        contentType: String = "unknown",
        minimumCount: Int = 1,
        causationKey: String? = nil
    ) -> ValueType {
        var object = Object()
        object[Field.trigger] = .string(trigger.rawValue)
        object[Field.topic] = .string(topic)
        object[Field.contentType] = .string(canonicalTypeName(contentType))
        object[Field.minimumCount] = .integer(max(1, minimumCount))
        if let causationKey = normalizedFlowCausationKey(causationKey) {
            object[Field.causationKey] = .string(causationKey)
        }
        return .object(object)
    }

    public static func normalizeSchema(key: String, schema: ValueType, description: ValueType = .string("*")) -> ValueType {
        guard case let .object(schemaObject) = schema else {
            return schema
        }

        return .object(normalizeSchemaObject(key: key, schemaObject: schemaObject, description: description))
    }

    public static func object(from value: ValueType?) -> Object? {
        guard case let .object(object)? = value else {
            return nil
        }
        return object
    }

    public static func list(from value: ValueType?) -> ValueTypeList? {
        guard case let .list(list)? = value else {
            return nil
        }
        return list
    }

    public static func string(from value: ValueType?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    public static func bool(from value: ValueType?) -> Bool? {
        guard case let .bool(bool)? = value else {
            return nil
        }
        return bool
    }

    public static func int(from value: ValueType?) -> Int? {
        switch value {
        case let .integer(int)?:
            return int
        case let .number(int)?:
            return int
        default:
            return nil
        }
    }

    public static func schemaType(from value: ValueType?) -> String? {
        guard let value else {
            return nil
        }

        switch value {
        case .null:
            return "null"
        case let .string(typeName):
            return canonicalTypeName(typeName)
        case let .object(object):
            if object[Field.oneOf] != nil {
                return "oneOf"
            }
            if let typeName = string(from: object[Field.type]) {
                return canonicalTypeName(typeName)
            }
            return "object"
        default:
            return value.contractTypeName
        }
    }

    public static func flowEffects(from schema: ValueType) -> [Object] {
        guard case let .object(schemaObject) = schema,
              let effects = list(from: schemaObject[Field.flowEffects]) else {
            return []
        }

        return effects.compactMap { effect in
            ExploreContract.object(from: effect)
        }
    }

    public static func canonicalTypeName(_ typeName: String) -> String {
        switch typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bool", "boolean":
            return "bool"
        case "number", "int", "integer":
            return "integer"
        case "float", "double":
            return "float"
        case "string", "text":
            return "string"
        case "object", "dictionary", "map":
            return "object"
        case "list", "array":
            return "list"
        case "data", "binary":
            return "data"
        case "null", "none":
            return "null"
        case "":
            return "unknown"
        default:
            return typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func normalizeSchemaObject(key: String, schemaObject: Object, description: ValueType) -> Object {
        var normalized = schemaObject

        let methodString = string(from: normalized[Field.method])
            ?? string(from: normalized["operation"])
            ?? "unspecified"

        normalized[Field.contractVersion] = normalized[Field.contractVersion] ?? .integer(version)
        normalized[Field.key] = normalized[Field.key] ?? .string(key)
        normalized[Field.method] = .string(methodString)
        normalized[Field.input] = normalizeInput(
            explicitValue: normalized[Field.input],
            legacyPayload: normalized["payload"],
            methodString: methodString
        )
        normalized[Field.returns] = normalizeOutput(from: normalized[Field.returns])
        normalized[Field.permissions] = normalizePermissions(from: normalized[Field.permissions])
        normalized[Field.required] = normalizeRequired(from: normalized[Field.required])
        normalized[Field.flowEffects] = normalizeFlowEffects(from: normalized[Field.flowEffects])
        normalized[Field.summary] = normalizeSummary(existing: normalized[Field.summary], description: description)

        normalized.removeValue(forKey: "payload")
        normalized.removeValue(forKey: "operation")

        return normalized
    }

    private static func normalizeInput(
        explicitValue: ValueType?,
        legacyPayload: ValueType?,
        methodString: String
    ) -> ValueType {
        if let explicitValue {
            return normalizeSchemaDescriptor(explicitValue)
        }
        if let legacyPayload {
            return normalizeSchemaDescriptor(legacyPayload)
        }
        if canonicalTypeName(methodString) == ExploreContractMethod.get.rawValue {
            return .null
        }
        return unknownSchema(description: "Input schema not specified")
    }

    private static func normalizeOutput(from value: ValueType?) -> ValueType {
        guard let value else {
            return unknownSchema(description: "Return schema not specified")
        }
        return normalizeSchemaDescriptor(value)
    }

    private static func normalizePermissions(from value: ValueType?) -> ValueType {
        guard let value else {
            return .list([])
        }

        switch value {
        case let .string(string):
            return .list([.string(string)])
        case let .list(list):
            let normalized = list.compactMap { item -> ValueType? in
                guard let string = string(from: item) else {
                    return nil
                }
                return .string(string)
            }
            return .list(normalized)
        default:
            return .list([])
        }
    }

    private static func normalizeRequired(from value: ValueType?) -> ValueType {
        guard let bool = bool(from: value) else {
            return .bool(false)
        }
        return .bool(bool)
    }

    private static func normalizeFlowEffects(from value: ValueType?) -> ValueType {
        guard let value else {
            return .list([])
        }

        let normalizedList: [ValueType]
        switch value {
        case let .list(list):
            normalizedList = list.compactMap(normalizeFlowEffect)
        case .object:
            normalizedList = normalizeFlowEffect(value).map { [$0] } ?? []
        default:
            normalizedList = []
        }

        return .list(normalizedList)
    }

    private static func normalizeFlowEffect(_ value: ValueType) -> ValueType? {
        guard case let .object(object) = value else {
            return nil
        }

        var normalized = object
        normalized[Field.trigger] = .string(string(from: object[Field.trigger]) ?? ExploreContractMethod.set.rawValue)
        normalized[Field.topic] = .string(string(from: object[Field.topic]) ?? "unspecified")
        normalized[Field.contentType] = .string(canonicalTypeName(string(from: object[Field.contentType]) ?? "unknown"))
        normalized[Field.minimumCount] = .integer(max(1, int(from: object[Field.minimumCount]) ?? 1))
        if let causationKey = normalizedFlowCausationKey(string(from: object[Field.causationKey])) {
            normalized[Field.causationKey] = .string(causationKey)
        } else {
            normalized.removeValue(forKey: Field.causationKey)
        }
        return .object(normalized)
    }

    private static func normalizedFlowCausationKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizeSummary(existing: ValueType?, description: ValueType) -> ValueType {
        if let existingSummary = string(from: existing) {
            return .string(existingSummary)
        }
        if let descriptionSummary = string(from: description) {
            return .string(descriptionSummary)
        }
        return .string("*")
    }

    private static func normalizeSchemaDescriptor(_ value: ValueType) -> ValueType {
        switch value {
        case .null:
            return .null
        case let .string(typeName):
            return schema(type: typeName)
        case let .object(object):
            if object[Field.type] != nil || object[Field.properties] != nil || object[Field.item] != nil || object[Field.oneOf] != nil {
                var normalized = object
                if normalized[Field.type] == nil {
                    if let options = list(from: normalized[Field.oneOf]) {
                        normalized[Field.oneOf] = .list(options.map(normalizeSchemaDescriptor))
                    } else {
                        normalized[Field.type] = .string("object")
                    }
                }
                return .object(normalized)
            }

            let normalizedProperties = Object(uniqueKeysWithValues: object.map { key, value in
                (key, normalizeSchemaDescriptor(value))
            })
            return objectSchema(properties: normalizedProperties)
        case let .list(list):
            if let first = list.first {
                return listSchema(item: normalizeSchemaDescriptor(first))
            }
            return listSchema(item: unknownSchema())
        default:
            return schema(type: value.contractTypeName)
        }
    }
}

public extension GeneralCell {
    func registerExploreContract(
        requester: Identity,
        key: String,
        method: ExploreContractMethod,
        input: ValueType? = nil,
        returns: ValueType? = nil,
        permissions: [String] = [],
        required: Bool = false,
        flowEffects: [ValueType] = [],
        description: ValueType = .string("*")
    ) async {
        let summary = ExploreContract.string(from: description) ?? "*"
        let schema = ExploreContract.keyContract(
            key: key,
            method: method,
            input: input,
            returns: returns,
            permissions: permissions,
            required: required,
            flowEffects: flowEffects,
            summary: summary
        )

        await registerExploreSchema(
            requester: requester,
            key: key,
            schema: schema,
            description: description
        )
    }
}

public extension ValueType {
    var contractTypeName: String {
        switch self {
        case .flowElement:
            return "flowElement"
        case .bool:
            return "bool"
        case .number, .integer:
            return "integer"
        case .float:
            return "float"
        case .string:
            return "string"
        case .object:
            return "object"
        case .list:
            return "list"
        case .data:
            return "data"
        case .keyValue:
            return "keyValue"
        case .setValueState:
            return "setValueState"
        case .setValueResponse:
            return "setValueResponse"
        case .cellConfiguration:
            return "cellConfiguration"
        case .cellReference:
            return "cellReference"
        case .verifiableCredential:
            return "verifiableCredential"
        case .identity:
            return "identity"
        case .connectContext:
            return "connectContext"
        case .connectState:
            return "connectState"
        case .contractState:
            return "contractState"
        case .signData:
            return "signData"
        case .signature:
            return "signature"
        case .agreementPayload:
            return "agreementPayload"
        case .description:
            return "description"
        case .cell:
            return "cell"
        case .null:
            return "null"
        }
    }
}
