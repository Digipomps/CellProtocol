// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPDCQLError: Error, Equatable {
    case emptyCredentials
    case emptyCredentialSets
    case invalidIdentifier(String)
    case duplicateCredentialID(String)
    case duplicateClaimID(credentialID: String, claimID: String)
    case emptyTrustedAuthorities(credentialID: String)
    case emptyTrustedAuthorityValues(credentialID: String, type: String)
    case emptyClaims(credentialID: String)
    case emptyClaimValues(credentialID: String, claimID: String?)
    case emptyClaimPath(credentialID: String, claimID: String?)
    case claimSetsWithoutClaims(credentialID: String)
    case claimSetReferencesUnknownClaim(credentialID: String, claimID: String)
    case credentialSetReferencesUnknownCredential(credentialID: String)
    case emptyCredentialSetOptions
    case emptyCredentialSetOption
}

public enum OID4VPJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([OID4VPJSONValue])
    case object([String: OID4VPJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([OID4VPJSONValue].self) {
            self = .array(arrayValue)
        } else {
            self = .object(try container.decode([String: OID4VPJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum OID4VPDCQLPrimitiveValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        }
    }
}

public enum OID4VPDCQLPathSegment: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
    case wildcard

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .wildcard
        } else if let intValue = try? container.decode(Int.self) {
            self = .index(intValue)
        } else {
            self = .key(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .key(let value):
            try container.encode(value)
        case .index(let value):
            try container.encode(value)
        case .wildcard:
            try container.encodeNil()
        }
    }
}

public struct OID4VPDCQLTrustedAuthorityQuery: Codable, Equatable, Sendable {
    public var type: String
    public var values: [String]

    public init(type: String, values: [String]) {
        self.type = type
        self.values = values
    }
}

public struct OID4VPDCQLClaimsQuery: Codable, Equatable, Sendable {
    public var id: String?
    public var path: [OID4VPDCQLPathSegment]
    public var values: [OID4VPDCQLPrimitiveValue]?

    public init(
        id: String? = nil,
        path: [OID4VPDCQLPathSegment],
        values: [OID4VPDCQLPrimitiveValue]? = nil
    ) {
        self.id = id
        self.path = path
        self.values = values
    }
}

public struct OID4VPDCQLCredentialQuery: Codable, Equatable, Sendable {
    public var id: String
    public var format: StandardsCredentialFormat
    public var multiple: Bool?
    public var meta: [String: OID4VPJSONValue]
    public var trustedAuthorities: [OID4VPDCQLTrustedAuthorityQuery]?
    public var requireCryptographicHolderBinding: Bool?
    public var claims: [OID4VPDCQLClaimsQuery]?
    public var claimSets: [[String]]?

    enum CodingKeys: String, CodingKey {
        case id
        case format
        case multiple
        case meta
        case trustedAuthorities = "trusted_authorities"
        case requireCryptographicHolderBinding = "require_cryptographic_holder_binding"
        case claims
        case claimSets = "claim_sets"
    }

    public init(
        id: String,
        format: StandardsCredentialFormat,
        multiple: Bool? = nil,
        meta: [String: OID4VPJSONValue],
        trustedAuthorities: [OID4VPDCQLTrustedAuthorityQuery]? = nil,
        requireCryptographicHolderBinding: Bool? = nil,
        claims: [OID4VPDCQLClaimsQuery]? = nil,
        claimSets: [[String]]? = nil
    ) {
        self.id = id
        self.format = format
        self.multiple = multiple
        self.meta = meta
        self.trustedAuthorities = trustedAuthorities
        self.requireCryptographicHolderBinding = requireCryptographicHolderBinding
        self.claims = claims
        self.claimSets = claimSets
    }

    public var allowsMultiple: Bool {
        multiple ?? false
    }

    public var requiresCryptographicHolderBinding: Bool {
        requireCryptographicHolderBinding ?? true
    }
}

public struct OID4VPDCQLCredentialSetQuery: Codable, Equatable, Sendable {
    public var options: [[String]]
    public var required: Bool?

    public init(options: [[String]], required: Bool? = nil) {
        self.options = options
        self.required = required
    }

    public var isRequired: Bool {
        required ?? true
    }
}

public struct OID4VPDCQLQuery: Codable, Equatable, Sendable {
    public var credentials: [OID4VPDCQLCredentialQuery]
    public var credentialSets: [OID4VPDCQLCredentialSetQuery]?

    enum CodingKeys: String, CodingKey {
        case credentials
        case credentialSets = "credential_sets"
    }

    public init(
        credentials: [OID4VPDCQLCredentialQuery],
        credentialSets: [OID4VPDCQLCredentialSetQuery]? = nil
    ) {
        self.credentials = credentials
        self.credentialSets = credentialSets
    }

    public static func parse(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> OID4VPDCQLQuery {
        let query = try decoder.decode(OID4VPDCQLQuery.self, from: data)
        try query.validate()
        return query
    }

    public func credentialQuery(id: String) -> OID4VPDCQLCredentialQuery? {
        credentials.first(where: { $0.id == id })
    }

    public func validate() throws {
        guard !credentials.isEmpty else {
            throw OID4VPDCQLError.emptyCredentials
        }

        var knownCredentialIDs = Set<String>()
        for credential in credentials {
            try Self.validateIdentifier(credential.id)
            if !knownCredentialIDs.insert(credential.id).inserted {
                throw OID4VPDCQLError.duplicateCredentialID(credential.id)
            }
            try Self.validate(credential: credential)
        }

        if let credentialSets {
            guard !credentialSets.isEmpty else {
                throw OID4VPDCQLError.emptyCredentialSets
            }
            for credentialSet in credentialSets {
                guard !credentialSet.options.isEmpty else {
                    throw OID4VPDCQLError.emptyCredentialSetOptions
                }
                for option in credentialSet.options {
                    guard !option.isEmpty else {
                        throw OID4VPDCQLError.emptyCredentialSetOption
                    }
                    for credentialID in option {
                        guard knownCredentialIDs.contains(credentialID) else {
                            throw OID4VPDCQLError.credentialSetReferencesUnknownCredential(credentialID: credentialID)
                        }
                    }
                }
            }
        }
    }

    private static func validate(credential: OID4VPDCQLCredentialQuery) throws {
        if let trustedAuthorities = credential.trustedAuthorities {
            guard !trustedAuthorities.isEmpty else {
                throw OID4VPDCQLError.emptyTrustedAuthorities(credentialID: credential.id)
            }
            for authority in trustedAuthorities {
                guard !authority.values.isEmpty else {
                    throw OID4VPDCQLError.emptyTrustedAuthorityValues(credentialID: credential.id, type: authority.type)
                }
            }
        }

        var knownClaimIDs = Set<String>()
        if let claims = credential.claims {
            guard !claims.isEmpty else {
                throw OID4VPDCQLError.emptyClaims(credentialID: credential.id)
            }

            for claim in claims {
                if let id = claim.id {
                    try validateIdentifier(id)
                    if !knownClaimIDs.insert(id).inserted {
                        throw OID4VPDCQLError.duplicateClaimID(credentialID: credential.id, claimID: id)
                    }
                }

                guard !claim.path.isEmpty else {
                    throw OID4VPDCQLError.emptyClaimPath(credentialID: credential.id, claimID: claim.id)
                }
                if let values = claim.values, values.isEmpty {
                    throw OID4VPDCQLError.emptyClaimValues(credentialID: credential.id, claimID: claim.id)
                }
            }
        }

        if let claimSets = credential.claimSets {
            guard credential.claims != nil else {
                throw OID4VPDCQLError.claimSetsWithoutClaims(credentialID: credential.id)
            }
            for claimSet in claimSets {
                guard !claimSet.isEmpty else {
                    throw OID4VPDCQLError.emptyCredentialSetOption
                }
                for claimID in claimSet {
                    guard knownClaimIDs.contains(claimID) else {
                        throw OID4VPDCQLError.claimSetReferencesUnknownClaim(credentialID: credential.id, claimID: claimID)
                    }
                }
            }
        }
    }

    private static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty else {
            throw OID4VPDCQLError.invalidIdentifier(identifier)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if identifier.rangeOfCharacter(from: allowed.inverted) != nil {
            throw OID4VPDCQLError.invalidIdentifier(identifier)
        }
    }
}
