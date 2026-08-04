// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum AuthorizationPolicyBindingError: Error, Equatable, Sendable, LocalizedError {
    case unknownField(String)
    case unsupportedSchema(String)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .unknownField(let field):
            return "Authorization policy binding contains an unknown field: \(field)"
        case .unsupportedSchema(let schema):
            return "Authorization policy binding schema is not supported: \(schema)"
        case .invalidField(let field):
            return "Authorization policy binding contains an invalid field: \(field)"
        }
    }
}

/// A static, issuer-signed ceiling reference for one Agreement.
///
/// This value never grants authority. A Contract/Grant or supported owner path
/// must authorize the operation independently. Per-use purpose, destination,
/// data, plan, and payload facts belong in a separate action context.
public struct AuthorizationPolicyBinding: Codable, Equatable, Sendable {
    public static let schemaV1 = "cellprotocol.authorization-policy-binding.v1"
    public static let sortedJSONCanonicalizationV1 = "sorted-json-v1"

    public var schema: String
    public var policyID: String
    public var policyVersion: String
    public var policyDigest: String
    public var configDigest: String
    public var taxonomyDigest: String
    public var actionFamily: String
    public var canonicalizationVersion: String

    public init(
        schema: String = Self.schemaV1,
        policyID: String,
        policyVersion: String,
        policyDigest: String,
        configDigest: String,
        taxonomyDigest: String,
        actionFamily: String,
        canonicalizationVersion: String = Self.sortedJSONCanonicalizationV1
    ) throws {
        self.schema = schema
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.policyDigest = policyDigest
        self.configDigest = configDigest
        self.taxonomyDigest = taxonomyDigest
        self.actionFamily = actionFamily
        self.canonicalizationVersion = canonicalizationVersion
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowedFields = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = container.allKeys
            .map(\.stringValue)
            .filter({ allowedFields.contains($0) == false })
            .sorted()
            .first {
            throw AuthorizationPolicyBindingError.unknownField(unknown)
        }

        schema = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.schema.rawValue))
        policyID = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.policyID.rawValue))
        policyVersion = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.policyVersion.rawValue))
        policyDigest = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.policyDigest.rawValue))
        configDigest = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.configDigest.rawValue))
        taxonomyDigest = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.taxonomyDigest.rawValue))
        actionFamily = try container.decode(String.self, forKey: DynamicCodingKey(CodingKeys.actionFamily.rawValue))
        canonicalizationVersion = try container.decode(
            String.self,
            forKey: DynamicCodingKey(CodingKeys.canonicalizationVersion.rawValue)
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(policyID, forKey: .policyID)
        try container.encode(policyVersion, forKey: .policyVersion)
        try container.encode(policyDigest, forKey: .policyDigest)
        try container.encode(configDigest, forKey: .configDigest)
        try container.encode(taxonomyDigest, forKey: .taxonomyDigest)
        try container.encode(actionFamily, forKey: .actionFamily)
        try container.encode(canonicalizationVersion, forKey: .canonicalizationVersion)
    }

    public func validate() throws {
        guard schema == Self.schemaV1 else {
            throw AuthorizationPolicyBindingError.unsupportedSchema(schema)
        }
        try Self.validateToken(policyID, field: "policyId")
        try Self.validateToken(policyVersion, field: "policyVersion")
        try Self.validateDigest(policyDigest, field: "policyDigest")
        try Self.validateDigest(configDigest, field: "configDigest")
        try Self.validateDigest(taxonomyDigest, field: "taxonomyDigest")
        try Self.validateToken(actionFamily, field: "actionFamily")
        guard canonicalizationVersion == Self.sortedJSONCanonicalizationV1 else {
            throw AuthorizationPolicyBindingError.invalidField("canonicalizationVersion")
        }
    }

    var authorizationDeduplicationKey: String {
        [
            schema,
            policyID,
            policyVersion,
            policyDigest,
            configDigest,
            taxonomyDigest,
            actionFamily,
            canonicalizationVersion
        ].joined(separator: "|")
    }

    private static func validateToken(_ value: String, field: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == value,
              value.isEmpty == false,
              value.count <= 256,
              value.contains(where: \.isNewline) == false else {
            throw AuthorizationPolicyBindingError.invalidField(field)
        }
    }

    private static func validateDigest(_ value: String, field: String) throws {
        guard value.count == 71,
              value.hasPrefix("sha256:"),
              value.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw AuthorizationPolicyBindingError.invalidField(field)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case policyID = "policyId"
        case policyVersion
        case policyDigest
        case configDigest
        case taxonomyDigest
        case actionFamily
        case canonicalizationVersion
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
