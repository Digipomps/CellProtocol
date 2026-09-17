// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Presentation metadata only. Existing text, actions, identifiers and editable
/// values retain their wire types and behavior in clients without localization.
public struct SkeletonLocalizationConfiguration: Codable, Equatable {
    public var version: Int
    public var sourceLocale: String?
    public var supportedLocales: [String]?
    public var catalogs: [LocalizationCatalogReference]
    public var resources: [LocalizationCatalog]

    public init(version: Int = 1, sourceLocale: String? = nil, supportedLocales: [String]? = nil,
                catalogs: [LocalizationCatalogReference] = [], resources: [LocalizationCatalog] = []) {
        self.version = version
        self.sourceLocale = sourceLocale
        self.supportedLocales = supportedLocales
        self.catalogs = catalogs
        self.resources = resources
    }

    private enum CodingKeys: String, CodingKey { case version, sourceLocale, supportedLocales, catalogs, resources }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sourceLocale = try values.decodeIfPresent(String.self, forKey: .sourceLocale)
        supportedLocales = try values.decodeIfPresent([String].self, forKey: .supportedLocales)
        catalogs = try values.decodeIfPresent([LocalizationCatalogReference].self, forKey: .catalogs) ?? []
        resources = try values.decodeIfPresent([LocalizationCatalog].self, forKey: .resources) ?? []
    }
}

public struct LocalizationCatalogReference: Codable, Equatable {
    public var namespace: String
    public var revision: String
    public init(namespace: String, revision: String) { self.namespace = namespace; self.revision = revision }
}

public struct LocalizationCatalog: Codable, Equatable {
    public var schema: String
    public var namespace: String
    public var revision: String
    public var sourceLocale: String
    public var messages: [String: LocalizationMessage]

    public init(namespace: String, revision: String, sourceLocale: String,
                messages: [String: LocalizationMessage]) {
        schema = "haven.localization-catalog.v1"
        self.namespace = namespace; self.revision = revision
        self.sourceLocale = sourceLocale; self.messages = messages
    }
    private enum CodingKeys: String, CodingKey {
        case schema, namespace, revision, messages
        case sourceLocale = "source_locale"
    }
}

public struct LocalizationMessage: Codable, Equatable {
    public var format: String
    public var arguments: [String: String]?
    public var context: String?
    public var sourceHash: String?
    public var legacyFallback: String?
    public var translations: [String: LocalizationTranslation]

    public init(format: String = "literal", arguments: [String: String]? = nil,
                context: String? = nil, sourceHash: String? = nil, legacyFallback: String? = nil,
                translations: [String: LocalizationTranslation]) {
        self.format = format; self.arguments = arguments; self.context = context
        self.sourceHash = sourceHash; self.legacyFallback = legacyFallback
        self.translations = translations
    }
    private enum CodingKeys: String, CodingKey {
        case format, arguments, context, translations
        case sourceHash = "source_hash"
        case legacyFallback = "legacy_fallback"
    }
}

public struct LocalizationTranslation: Codable, Equatable {
    public var value: String
    public var state: String
    public var sourceHash: String?
    public init(value: String, state: String = "draft", sourceHash: String? = nil) {
        self.value = value; self.state = state; self.sourceHash = sourceHash
    }
    private enum CodingKeys: String, CodingKey {
        case value, state
        case sourceHash = "source_hash"
    }
}

public enum LocalizationBindingScope: String, Codable { case root, item, context }

/// Numeric dates use milliseconds since the Unix epoch, with timezone supplied
/// separately by the host. Catalogs never contain executable arguments.
public enum LocalizationArgumentValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

public struct LocalizationArgumentBinding: Codable, Equatable {
    public var value: LocalizationArgumentValue?
    public var scope: LocalizationBindingScope?
    public var keypath: String?

    public init(value: LocalizationArgumentValue) { self.value = value }
    public init(keypath: String, scope: LocalizationBindingScope = .root) {
        self.keypath = keypath; self.scope = scope
    }
    private enum CodingKeys: String, CodingKey { case value, scope, keypath }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(LocalizationArgumentValue.self, forKey: .value)
        scope = try values.decodeIfPresent(LocalizationBindingScope.self, forKey: .scope)
        keypath = try values.decodeIfPresent(String.self, forKey: .keypath)
        guard (value != nil && keypath == nil && scope == nil) ||
              (value == nil && Self.validKeypath(keypath)) else {
            throw Swift.DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Expected a literal value or a scoped localization keypath"))
        }
    }
    static func validKeypath(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !["__proto__", "prototype", "constructor"].contains(String($0))
        }
    }
}

/// Exactly one source: a catalog key with arguments, or an explicit binding to
/// a localized data value. A raw string is never interpreted as a catalog key.
public struct SkeletonLocalizedText: Codable, Equatable {
    public var namespace: String?
    public var key: String?
    public var arguments: [String: LocalizationArgumentBinding]?
    public var valueKeypath: String?
    public var scope: LocalizationBindingScope?

    public init(namespace: String, key: String, arguments: [String: LocalizationArgumentBinding]? = nil) {
        self.namespace = namespace; self.key = key; self.arguments = arguments
    }
    public init(valueKeypath: String, scope: LocalizationBindingScope = .item) {
        self.valueKeypath = valueKeypath; self.scope = scope
    }
    private enum CodingKeys: String, CodingKey { case namespace, key, arguments, valueKeypath, scope }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try values.decodeIfPresent(String.self, forKey: .namespace)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        arguments = try values.decodeIfPresent([String: LocalizationArgumentBinding].self, forKey: .arguments)
        valueKeypath = try values.decodeIfPresent(String.self, forKey: .valueKeypath)
        scope = try values.decodeIfPresent(LocalizationBindingScope.self, forKey: .scope)
        let isCatalog = namespace?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && valueKeypath == nil && scope == nil
        let isValue = LocalizationArgumentBinding.validKeypath(valueKeypath) && namespace == nil && key == nil && arguments == nil
        guard isCatalog || isValue else {
            throw Swift.DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Expected one localization source: catalog reference or localized value keypath"))
        }
    }
}

public struct ResolvedSkeletonText: Codable, Equatable {
    public var text: String
    public var requestedLocale: String?
    public var uiLocale: String
    public var resolvedLocale: String?
    public var fallbackUsed: Bool
    public var fallbackReason: String?
    public var catalogRevision: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case requestedLocale = "requested_locale", uiLocale = "ui_locale", resolvedLocale = "resolved_locale"
        case fallbackUsed = "fallback_used", fallbackReason = "fallback_reason", catalogRevision = "catalog_revision"
    }
}

public extension SkeletonElement {
    /// Collect once when a host accepts a configuration. Item/context bindings
    /// are local reads and must never become remote root projections.
    var localizationRootKeypaths: [String] {
        guard let data = try? JSONEncoder().encode(self),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var paths = Set<String>()
        func walk(_ value: Any) {
            if let entries = value as? [Any] { entries.forEach(walk); return }
            guard let dictionary = value as? [String: Any] else { return }
            if let modifiers = dictionary["modifiers"] as? [String: Any],
               let declarations = modifiers["localization"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: declarations),
               let texts = try? JSONDecoder().decode([String: SkeletonLocalizedText].self, from: data) {
                for text in texts.values {
                    if let path = text.valueKeypath, text.scope == nil || text.scope == .root { paths.insert(path) }
                    for binding in text.arguments?.values ?? Dictionary<String, LocalizationArgumentBinding>().values {
                        if let path = binding.keypath, binding.scope == nil || binding.scope == .root { paths.insert(path) }
                    }
                }
            }
            for (key, child) in dictionary where !["localization", "modifiers", "payload"].contains(key) { walk(child) }
        }
        walk(json)
        return paths.sorted()
    }
}
