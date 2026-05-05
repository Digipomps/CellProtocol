// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

struct CommonsCellCodec {
    struct TermResolveRequest: Codable {
        var termID: String
        var lang: String?
        var namespace: String?

        init(termID: String, lang: String? = nil, namespace: String? = nil) {
            self.termID = termID
            self.lang = lang
            self.namespace = namespace
        }

        enum CodingKeys: String, CodingKey {
            case termID = "term_id"
            case lang
            case locale
            case namespace
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.termID = try container.decode(String.self, forKey: .termID)
            self.lang = try container.decodeIfPresent(String.self, forKey: .lang)
                ?? container.decodeIfPresent(String.self, forKey: .locale)
            self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(termID, forKey: .termID)
            try container.encodeIfPresent(lang, forKey: .lang)
            try container.encodeIfPresent(namespace, forKey: .namespace)
        }
    }

    struct TermBatchResolveRequest: Decodable {
        var terms: [TermResolveRequest]
        var locale: String?
        var namespace: String?

        enum CodingKeys: String, CodingKey {
            case terms
            case locale
            case lang
            case namespace
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.terms = try container.decode([TermResolveRequest].self, forKey: .terms)
            self.locale = try container.decodeIfPresent(String.self, forKey: .locale)
                ?? container.decodeIfPresent(String.self, forKey: .lang)
            self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        }
    }

    struct LocalizationCoverageRequest: Codable {
        var namespace: String
        var requiredLocales: [String]

        init(namespace: String, requiredLocales: [String] = []) {
            self.namespace = namespace
            self.requiredLocales = requiredLocales
        }

        enum CodingKeys: String, CodingKey {
            case namespace
            case requiredLocales = "required_locales"
            case requiredLocalesCamel = "requiredLocales"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.namespace = try container.decode(String.self, forKey: .namespace)
            self.requiredLocales = try container.decodeIfPresent([String].self, forKey: .requiredLocales)
                ?? container.decodeIfPresent([String].self, forKey: .requiredLocalesCamel)
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(namespace, forKey: .namespace)
            try container.encode(requiredLocales, forKey: .requiredLocales)
        }
    }

    struct GuidanceRequest: Codable {
        var namespace: String
    }

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

    static func success(_ payload: ValueType) -> ValueType {
        .object([
            "status": .string("ok"),
            "result": payload
        ])
    }

    static func success(message: String, extra: Object = [:]) -> ValueType {
        var object: Object = [
            "status": .string("ok"),
            "message": .string(message)
        ]

        for (key, value) in extra {
            object[key] = value
        }

        return .object(object)
    }

    static func error(_ error: Error, operation: String) -> ValueType {
        .object([
            "status": .string("error"),
            "operation": .string(operation),
            "message": .string("\(error)")
        ])
    }

    static func error(message: String, operation: String) -> ValueType {
        .object([
            "status": .string("error"),
            "operation": .string(operation),
            "message": .string(message)
        ])
    }
}
