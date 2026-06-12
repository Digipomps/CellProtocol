// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ExploreValidationIssue: Codable, Equatable {
    public var path: String
    public var expected: String
    public var observed: String
    public var message: String

    public init(
        path: String,
        expected: String,
        observed: String,
        message: String
    ) {
        self.path = path
        self.expected = expected
        self.observed = observed
        self.message = message
    }
}

public struct ExploreValidationReport: Codable, Equatable {
    public var ok: Bool
    public var issues: [ExploreValidationIssue]

    public init(ok: Bool, issues: [ExploreValidationIssue]) {
        self.ok = ok
        self.issues = issues
    }
}

public enum ExploreContractValidator {
    public static func validate(
        value: ValueType?,
        against schema: ValueType?,
        path: String = "$"
    ) -> ExploreValidationReport {
        var issues = [ExploreValidationIssue]()
        validateNode(value: value, schema: schema, path: path, issues: &issues)
        return ExploreValidationReport(ok: issues.isEmpty, issues: issues)
    }

    public static func matches(value: ValueType?, schema: ValueType?) -> Bool {
        validate(value: value, against: schema).ok
    }

    public static func defaultSample(for schema: ValueType?) -> ValueType? {
        guard let schema else {
            return nil
        }

        switch schema {
        case .null:
            return .null
        case let .string(typeName):
            return defaultSample(for: ExploreContract.schema(type: typeName))
        case let .object(object):
            if let options = ExploreContract.list(from: object[ExploreContract.Field.oneOf]) {
                for option in options {
                    if let sample = defaultSample(for: option) {
                        return sample
                    }
                }
                return nil
            }

            let schemaType = ExploreContract.schemaType(from: .object(object)) ?? "object"
            switch schemaType {
            case "unknown":
                return nil
            case "null":
                return .null
            case "bool":
                return .bool(true)
            case "integer":
                return .integer(1)
            case "float":
                return .float(1.0)
            case "string":
                return .string("sample")
            case "data":
                return .data(Data("sample".utf8))
            case "list":
                if let itemSchema = object[ExploreContract.Field.item],
                   let item = defaultSample(for: itemSchema) {
                    return .list([item])
                }
                return .list([])
            case "object":
                let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]) ?? [:]
                let requiredKeys = ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?.compactMap {
                    ExploreContract.string(from: $0)
                } ?? Array(propertySchemas.keys)

                var sampleObject = Object()
                for key in requiredKeys {
                    let propertySchema = propertySchemas[key]
                    if let sample = defaultSample(for: propertySchema) {
                        sampleObject[key] = sample
                    } else {
                        sampleObject[key] = .string("sample")
                    }
                }
                return .object(sampleObject)
            default:
                return .string("sample")
            }
        default:
            switch schema.contractTypeName {
            case "bool":
                return .bool(true)
            case "integer":
                return .integer(1)
            case "float":
                return .float(1.0)
            case "string":
                return .string("sample")
            case "list":
                return .list([])
            case "object":
                return .object([:])
            default:
                return nil
            }
        }
    }

    public static func invalidInput(for schema: ValueType?) -> ValueType? {
        guard let schema else {
            return nil
        }

        let candidates: [ValueType] = [
            .string("invalid"),
            .object(["invalid": .bool(true)]),
            .list([.string("invalid")]),
            .integer(-1),
            .bool(false),
            .null
        ]

        for candidate in candidates where !matches(value: candidate, schema: schema) {
            return candidate
        }
        return nil
    }

    public static func deepEqual(_ lhs: ValueType?, _ rhs: ValueType?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case (.null?, .null?):
            return true
        case let (.string(left)?, .string(right)?):
            return left == right
        case let (.bool(left)?, .bool(right)?):
            return left == right
        case let (.number(left)?, .number(right)?):
            return left == right
        case let (.integer(left)?, .integer(right)?):
            return left == right
        case let (.float(left)?, .float(right)?):
            return abs(left - right) < 0.000_001
        case let (.object(left)?, .object(right)?):
            guard Set(left.keys) == Set(right.keys) else {
                return false
            }
            for key in left.keys where !deepEqual(left[key], right[key]) {
                return false
            }
            return true
        case let (.list(left)?, .list(right)?):
            guard left.count == right.count else {
                return false
            }
            for (leftItem, rightItem) in zip(left, right) where !deepEqual(leftItem, rightItem) {
                return false
            }
            return true
        default:
            return false
        }
    }

    private static func validateNode(
        value: ValueType?,
        schema: ValueType?,
        path: String,
        issues: inout [ExploreValidationIssue]
    ) {
        guard let schema else {
            return
        }

        switch schema {
        case .null:
            validateNull(value: value, path: path, issues: &issues)
        case let .string(typeName):
            validateNode(value: value, schema: ExploreContract.schema(type: typeName), path: path, issues: &issues)
        case let .object(object):
            if let options = ExploreContract.list(from: object[ExploreContract.Field.oneOf]) {
                validateOneOf(value: value, options: options, path: path, issues: &issues)
                return
            }

            let schemaType = ExploreContract.schemaType(from: .object(object)) ?? "object"
            switch schemaType {
            case "unknown":
                return
            case "null":
                validateNull(value: value, path: path, issues: &issues)
            case "bool", "integer", "float", "string", "data":
                validatePrimitive(value: value, expectedType: schemaType, path: path, issues: &issues)
            case "list":
                guard case let .list(list)? = value else {
                    appendIssue(path: path, expected: "list", observed: observedTypeName(for: value), issues: &issues)
                    return
                }
                let itemSchema = object[ExploreContract.Field.item]
                for (index, item) in list.enumerated() {
                    validateNode(value: item, schema: itemSchema, path: "\(path)[\(index)]", issues: &issues)
                }
            case "object":
                guard case let .object(actualObject)? = value else {
                    appendIssue(path: path, expected: "object", observed: observedTypeName(for: value), issues: &issues)
                    return
                }

                let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]) ?? [:]
                let requiredKeys = ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?.compactMap {
                    ExploreContract.string(from: $0)
                } ?? []

                for key in requiredKeys where actualObject[key] == nil {
                    appendIssue(
                        path: childPath(parent: path, key: key),
                        expected: "required property",
                        observed: "missing",
                        issues: &issues
                    )
                }

                for (propertyKey, propertySchema) in propertySchemas {
                    guard let actualValue = actualObject[propertyKey] else {
                        continue
                    }
                    validateNode(
                        value: actualValue,
                        schema: propertySchema,
                        path: childPath(parent: path, key: propertyKey),
                        issues: &issues
                    )
                }
            default:
                validatePrimitive(value: value, expectedType: schemaType, path: path, issues: &issues)
            }
        default:
            validatePrimitive(value: value, expectedType: schema.contractTypeName, path: path, issues: &issues)
        }
    }

    private static func validateOneOf(
        value: ValueType?,
        options: ValueTypeList,
        path: String,
        issues: inout [ExploreValidationIssue]
    ) {
        for option in options where matches(value: value, schema: option) {
            return
        }

        appendIssue(
            path: path,
            expected: "oneOf(\(options.map { ExploreContract.schemaType(from: $0) ?? $0.contractTypeName }.joined(separator: ", ")))",
            observed: observedTypeName(for: value),
            issues: &issues
        )
    }

    private static func validateNull(
        value: ValueType?,
        path: String,
        issues: inout [ExploreValidationIssue]
    ) {
        if value == nil { return }
        guard case .null? = value else {
            appendIssue(path: path, expected: "null", observed: observedTypeName(for: value), issues: &issues)
            return
        }
    }

    private static func validatePrimitive(
        value: ValueType?,
        expectedType: String,
        path: String,
        issues: inout [ExploreValidationIssue]
    ) {
        let observed = observedTypeName(for: value)
        switch expectedType {
        case "float":
            guard case .float? = value else {
                appendIssue(path: path, expected: expectedType, observed: observed, issues: &issues)
                return
            }
        default:
            guard value?.contractTypeName == expectedType else {
                appendIssue(path: path, expected: expectedType, observed: observed, issues: &issues)
                return
            }
        }
    }

    private static func appendIssue(
        path: String,
        expected: String,
        observed: String,
        issues: inout [ExploreValidationIssue]
    ) {
        issues.append(
            ExploreValidationIssue(
                path: path,
                expected: expected,
                observed: observed,
                message: "Expected \(expected), observed \(observed)."
            )
        )
    }

    private static func observedTypeName(for value: ValueType?) -> String {
        guard let value else {
            return "missing"
        }
        return value.contractTypeName
    }

    private static func childPath(parent: String, key: String) -> String {
        guard isSimplePathSegment(key) else {
            return "\(parent)[\(String(reflecting: key))]"
        }
        return "\(parent).\(key)"
    }

    private static func isSimplePathSegment(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else {
            return false
        }
        return key.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }
}
