// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A vault-issued binding between one signing identity and one runtime domain.
///
/// The binding is context evidence, not a capability or membership credential.
/// Callers must include it inside a signed protocol payload, and recipients must
/// still enforce Resolver, contract, purpose, and capability policy.
public struct IdentityDomainBinding: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.identity.domain-binding.v1"
    public static let vaultContextKind = "vault_context"

    public let schema: String
    public let bindingKind: String
    public let domain: String
    public let identityUUID: String
    public let signingKeyFingerprint: String
    public let grantsAuthority: Bool

    private enum CodingKeys: String, CodingKey {
        case schema
        case bindingKind
        case domain
        case identityUUID
        case signingKeyFingerprint
        case grantsAuthority
    }

    public init?(domain: String, identity: Identity) {
        let normalizedDomain = Self.normalizedDomain(domain)
        guard let normalizedDomain,
              let fingerprint = identity.signingPublicKeyFingerprint,
              fingerprint.isEmpty == false else {
            return nil
        }
        self.schema = Self.currentSchema
        self.bindingKind = Self.vaultContextKind
        self.domain = normalizedDomain
        self.identityUUID = identity.uuid
        self.signingKeyFingerprint = fingerprint
        self.grantsAuthority = false
    }

    public init?(object: Object) {
        guard case let .string(schema)? = object["schema"],
              schema == Self.currentSchema,
              case let .string(bindingKind)? = object["bindingKind"],
              bindingKind == Self.vaultContextKind,
              case let .string(domain)? = object["domain"],
              let normalizedDomain = Self.normalizedDomain(domain),
              case let .string(identityUUID)? = object["identityUUID"],
              identityUUID.isEmpty == false,
              case let .string(signingKeyFingerprint)? = object["signingKeyFingerprint"],
              signingKeyFingerprint.isEmpty == false,
              case let .bool(grantsAuthority)? = object["grantsAuthority"],
              grantsAuthority == false else {
            return nil
        }
        self.schema = schema
        self.bindingKind = bindingKind
        self.domain = normalizedDomain
        self.identityUUID = identityUUID
        self.signingKeyFingerprint = signingKeyFingerprint
        self.grantsAuthority = grantsAuthority
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(String.self, forKey: .schema)
        let bindingKind = try values.decode(String.self, forKey: .bindingKind)
        let domain = try values.decode(String.self, forKey: .domain)
        let identityUUID = try values.decode(String.self, forKey: .identityUUID)
        let signingKeyFingerprint = try values.decode(String.self, forKey: .signingKeyFingerprint)
        let grantsAuthority = try values.decode(Bool.self, forKey: .grantsAuthority)
        guard schema == Self.currentSchema,
              bindingKind == Self.vaultContextKind,
              let normalizedDomain = Self.normalizedDomain(domain),
              identityUUID.isEmpty == false,
              signingKeyFingerprint.isEmpty == false,
              grantsAuthority == false else {
            throw Swift.DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid or authority-bearing identity-domain binding."
            ))
        }
        self.schema = schema
        self.bindingKind = bindingKind
        self.domain = normalizedDomain
        self.identityUUID = identityUUID
        self.signingKeyFingerprint = signingKeyFingerprint
        self.grantsAuthority = grantsAuthority
    }

    public var objectValue: Object {
        [
            "schema": .string(schema),
            "bindingKind": .string(bindingKind),
            "domain": .string(domain),
            "identityUUID": .string(identityUUID),
            "signingKeyFingerprint": .string(signingKeyFingerprint),
            "grantsAuthority": .bool(grantsAuthority)
        ]
    }

    public func matches(identity: Identity) -> Bool {
        guard let fingerprint = identity.signingPublicKeyFingerprint else {
            return false
        }
        return identity.uuid == identityUUID
            && fingerprint == signingKeyFingerprint
            && grantsAuthority == false
    }

    private static func normalizedDomain(_ domain: String) -> String? {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.count <= 256,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7E
              }) else {
            return nil
        }
        return normalized
    }
}
