// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VCIIssuerMetadataError: Error {
    case invalidCredentialIssuer
    case invalidMetadataURL
    case mismatchedCredentialIssuer
}

public enum OID4VCIAlgorithmIdentifier: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        self = .integer(try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let stringValue):
            try container.encode(stringValue)
        case .integer(let intValue):
            try container.encode(intValue)
        }
    }
}

public struct OID4VCIDisplayDescriptor: Codable, Equatable, Sendable {
    public struct Logo: Codable, Equatable, Sendable {
        public var uri: URL?
        public var altText: String?

        enum CodingKeys: String, CodingKey {
            case uri
            case altText = "alt_text"
        }

        public init(uri: URL? = nil, altText: String? = nil) {
            self.uri = uri
            self.altText = altText
        }
    }

    public var name: String?
    public var locale: String?
    public var logo: Logo?
    public var backgroundColor: String?
    public var textColor: String?

    enum CodingKeys: String, CodingKey {
        case name
        case locale
        case logo
        case backgroundColor = "background_color"
        case textColor = "text_color"
    }

    public init(
        name: String? = nil,
        locale: String? = nil,
        logo: Logo? = nil,
        backgroundColor: String? = nil,
        textColor: String? = nil
    ) {
        self.name = name
        self.locale = locale
        self.logo = logo
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }
}

public struct OID4VCICredentialClaimDescriptor: Codable, Equatable, Sendable {
    public var path: [String]
    public var mandatory: Bool?
    public var display: [OID4VCIDisplayDescriptor]?

    public init(path: [String], mandatory: Bool? = nil, display: [OID4VCIDisplayDescriptor]? = nil) {
        self.path = path
        self.mandatory = mandatory
        self.display = display
    }
}

public struct OID4VCICredentialMetadata: Codable, Equatable, Sendable {
    public var display: [OID4VCIDisplayDescriptor]?
    public var claims: [OID4VCICredentialClaimDescriptor]?

    public init(
        display: [OID4VCIDisplayDescriptor]? = nil,
        claims: [OID4VCICredentialClaimDescriptor]? = nil
    ) {
        self.display = display
        self.claims = claims
    }
}

public struct OID4VCICredentialDefinition: Codable, Equatable, Sendable {
    public var contexts: [String]?
    public var type: [String]

    enum CodingKeys: String, CodingKey {
        case contexts = "@context"
        case type
    }

    public init(contexts: [String]? = nil, type: [String]) {
        self.contexts = contexts
        self.type = type
    }
}

public struct OID4VCIProofTypeSupport: Codable, Equatable, Sendable {
    public struct KeyAttestationsRequired: Codable, Equatable, Sendable {
        public var keyStorage: [String]?
        public var userAuthentication: [String]?

        enum CodingKeys: String, CodingKey {
            case keyStorage = "key_storage"
            case userAuthentication = "user_authentication"
        }

        public init(keyStorage: [String]? = nil, userAuthentication: [String]? = nil) {
            self.keyStorage = keyStorage
            self.userAuthentication = userAuthentication
        }
    }

    public var proofSigningAlgValuesSupported: [String]
    public var keyAttestationsRequired: KeyAttestationsRequired?

    enum CodingKeys: String, CodingKey {
        case proofSigningAlgValuesSupported = "proof_signing_alg_values_supported"
        case keyAttestationsRequired = "key_attestations_required"
    }

    public init(
        proofSigningAlgValuesSupported: [String],
        keyAttestationsRequired: KeyAttestationsRequired? = nil
    ) {
        self.proofSigningAlgValuesSupported = proofSigningAlgValuesSupported
        self.keyAttestationsRequired = keyAttestationsRequired
    }
}

public struct OID4VCICredentialConfiguration: Codable, Equatable, Sendable {
    public var format: StandardsCredentialFormat
    public var scope: String?
    public var cryptographicBindingMethodsSupported: [String]?
    public var credentialSigningAlgValuesSupported: [OID4VCIAlgorithmIdentifier]?
    public var proofTypesSupported: [String: OID4VCIProofTypeSupport]?
    public var credentialDefinition: OID4VCICredentialDefinition?
    public var credentialMetadata: OID4VCICredentialMetadata?
    public var vct: String?
    public var doctype: String?

    enum CodingKeys: String, CodingKey {
        case format
        case scope
        case cryptographicBindingMethodsSupported = "cryptographic_binding_methods_supported"
        case credentialSigningAlgValuesSupported = "credential_signing_alg_values_supported"
        case proofTypesSupported = "proof_types_supported"
        case credentialDefinition = "credential_definition"
        case credentialMetadata = "credential_metadata"
        case vct
        case doctype
    }

    public init(
        format: StandardsCredentialFormat,
        scope: String? = nil,
        cryptographicBindingMethodsSupported: [String]? = nil,
        credentialSigningAlgValuesSupported: [OID4VCIAlgorithmIdentifier]? = nil,
        proofTypesSupported: [String: OID4VCIProofTypeSupport]? = nil,
        credentialDefinition: OID4VCICredentialDefinition? = nil,
        credentialMetadata: OID4VCICredentialMetadata? = nil,
        vct: String? = nil,
        doctype: String? = nil
    ) {
        self.format = format
        self.scope = scope
        self.cryptographicBindingMethodsSupported = cryptographicBindingMethodsSupported
        self.credentialSigningAlgValuesSupported = credentialSigningAlgValuesSupported
        self.proofTypesSupported = proofTypesSupported
        self.credentialDefinition = credentialDefinition
        self.credentialMetadata = credentialMetadata
        self.vct = vct
        self.doctype = doctype
    }
}

public struct OID4VCIRequestEncryptionSupport: Codable, Equatable, Sendable {
    public var encryptionRequired: Bool

    enum CodingKeys: String, CodingKey {
        case encryptionRequired = "encryption_required"
    }

    public init(encryptionRequired: Bool) {
        self.encryptionRequired = encryptionRequired
    }
}

public struct OID4VCIBatchCredentialIssuanceSupport: Codable, Equatable, Sendable {
    public var batchSize: Int

    enum CodingKeys: String, CodingKey {
        case batchSize = "batch_size"
    }

    public init(batchSize: Int) {
        self.batchSize = batchSize
    }
}

public struct OID4VCIIssuerMetadata: Codable, Equatable, Sendable {
    public var credentialIssuer: String
    public var authorizationServers: [String]?
    public var credentialEndpoint: URL
    public var nonceEndpoint: URL?
    public var deferredCredentialEndpoint: URL?
    public var notificationEndpoint: URL?
    public var credentialRequestEncryption: OID4VCIRequestEncryptionSupport?
    public var batchCredentialIssuance: OID4VCIBatchCredentialIssuanceSupport?
    public var credentialConfigurationsSupported: [String: OID4VCICredentialConfiguration]
    public var display: [OID4VCIDisplayDescriptor]?

    enum CodingKeys: String, CodingKey {
        case credentialIssuer = "credential_issuer"
        case authorizationServers = "authorization_servers"
        case credentialEndpoint = "credential_endpoint"
        case nonceEndpoint = "nonce_endpoint"
        case deferredCredentialEndpoint = "deferred_credential_endpoint"
        case notificationEndpoint = "notification_endpoint"
        case credentialRequestEncryption = "credential_request_encryption"
        case batchCredentialIssuance = "batch_credential_issuance"
        case credentialConfigurationsSupported = "credential_configurations_supported"
        case display
    }

    public init(
        credentialIssuer: String,
        authorizationServers: [String]? = nil,
        credentialEndpoint: URL,
        nonceEndpoint: URL? = nil,
        deferredCredentialEndpoint: URL? = nil,
        notificationEndpoint: URL? = nil,
        credentialRequestEncryption: OID4VCIRequestEncryptionSupport? = nil,
        batchCredentialIssuance: OID4VCIBatchCredentialIssuanceSupport? = nil,
        credentialConfigurationsSupported: [String: OID4VCICredentialConfiguration],
        display: [OID4VCIDisplayDescriptor]? = nil
    ) {
        self.credentialIssuer = credentialIssuer
        self.authorizationServers = authorizationServers
        self.credentialEndpoint = credentialEndpoint
        self.nonceEndpoint = nonceEndpoint
        self.deferredCredentialEndpoint = deferredCredentialEndpoint
        self.notificationEndpoint = notificationEndpoint
        self.credentialRequestEncryption = credentialRequestEncryption
        self.batchCredentialIssuance = batchCredentialIssuance
        self.credentialConfigurationsSupported = credentialConfigurationsSupported
        self.display = display
    }

    public var credentialIssuerURL: URL? {
        URL(string: credentialIssuer)
    }

    public var resolvedAuthorizationServerIdentifiers: [String] {
        if let authorizationServers, !authorizationServers.isEmpty {
            return authorizationServers
        }
        return [credentialIssuer]
    }

    public var supportedFormats: Set<StandardsCredentialFormat> {
        Set(credentialConfigurationsSupported.values.map(\.format))
    }

    public func configuration(id: String) -> OID4VCICredentialConfiguration? {
        credentialConfigurationsSupported[id]
    }

    public func validateIssuerIdentifier() throws {
        guard let issuerURL = credentialIssuerURL,
              let scheme = issuerURL.scheme?.lowercased(),
              scheme == "https",
              issuerURL.query == nil,
              issuerURL.fragment == nil else {
            throw OID4VCIIssuerMetadataError.invalidCredentialIssuer
        }
    }

    public func validatedAgainst(metadataURL: URL) throws {
        try validateIssuerIdentifier()
        let expectedURL = try Self.metadataURL(for: credentialIssuer)
        if expectedURL != metadataURL {
            throw OID4VCIIssuerMetadataError.mismatchedCredentialIssuer
        }
    }

    public static func metadataURL(for credentialIssuerIdentifier: String) throws -> URL {
        guard let issuerURL = URL(string: credentialIssuerIdentifier),
              let scheme = issuerURL.scheme?.lowercased(),
              scheme == "https",
              issuerURL.query == nil,
              issuerURL.fragment == nil else {
            throw OID4VCIIssuerMetadataError.invalidCredentialIssuer
        }

        guard var components = URLComponents(url: issuerURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            throw OID4VCIIssuerMetadataError.invalidCredentialIssuer
        }

        let issuerPath = components.path
        let normalizedPath = issuerPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            components.path = "/.well-known/openid-credential-issuer"
        } else {
            components.path = "/.well-known/openid-credential-issuer/\(normalizedPath)"
        }
        components.query = nil
        components.fragment = nil

        guard let metadataURL = components.url, metadataURL.host == host else {
            throw OID4VCIIssuerMetadataError.invalidMetadataURL
        }
        return metadataURL
    }
}
