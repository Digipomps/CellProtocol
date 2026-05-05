// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPVerifierMetadataError: Error, Equatable {
    case invalidVerifierMetadata
    case emptyJWKS
    case missingJWKKeyID
    case duplicateJWKKeyID(String)
    case emptyEncryptedResponseEncValuesSupported
    case emptyVPFormatsSupported
}

public enum OID4VPDirectPostJWTPreparationError: Error, Equatable {
    case unsupportedResponseMode(String?)
    case missingResponseURI
    case missingVerifierMetadata
    case missingJWKS
    case noUsableEncryptionKey
    case unknownKeyIdentifier(String)
    case unsupportedContentEncryption(String)
}

public enum OID4VPVerifierMetadataResolutionError: Error, Equatable {
    case clientMetadataNotAllowedForPreRegisteredClient
    case missingVerifierMetadata(prefix: String)
}

public enum OID4VPClientIdentifierPrefix: Equatable, Sendable {
    case preRegistered
    case redirectURI
    case openidFederation
    case verifierAttestation
    case decentralizedIdentifier
    case x509SanDNS
    case x509Hash
    case other(String)

    public var rawIdentifier: String {
        switch self {
        case .preRegistered:
            return "pre-registered"
        case .redirectURI:
            return "redirect_uri"
        case .openidFederation:
            return "openid_federation"
        case .verifierAttestation:
            return "verifier_attestation"
        case .decentralizedIdentifier:
            return "decentralized_identifier"
        case .x509SanDNS:
            return "x509_san_dns"
        case .x509Hash:
            return "x509_hash"
        case .other(let value):
            return value
        }
    }
}

public enum OID4VPResolvedVerifierMetadataSource: Equatable, Sendable {
    case requestClientMetadata
    case preRegistered
    case openidFederation
    case outOfBand(String)
}

public struct OID4VPResolvedVerifierMetadata: Equatable, Sendable {
    public var metadata: OID4VPVerifierMetadata
    public var source: OID4VPResolvedVerifierMetadataSource
    public var clientIdentifierPrefix: OID4VPClientIdentifierPrefix

    public init(
        metadata: OID4VPVerifierMetadata,
        source: OID4VPResolvedVerifierMetadataSource,
        clientIdentifierPrefix: OID4VPClientIdentifierPrefix
    ) {
        self.metadata = metadata
        self.source = source
        self.clientIdentifierPrefix = clientIdentifierPrefix
    }
}

public protocol OID4VPVerifierMetadataProvider {
    func metadata(for requestObject: OID4VPRequestObject) async throws -> OID4VPResolvedVerifierMetadata?
}

public struct OID4VPVerifierFormatSupport: Codable, Equatable, Sendable {
    public var properties: [String: OID4VPJSONValue]

    public init(properties: [String: OID4VPJSONValue]) {
        self.properties = properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.properties = try container.decode([String: OID4VPJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(properties)
    }
}

public struct OID4VPVerifierMetadata: Codable, Equatable, Sendable {
    public var jwks: JOSEJWKSet?
    public var encryptedResponseEncValuesSupported: [String]?
    public var vpFormatsSupported: [String: OID4VPVerifierFormatSupport]?

    enum CodingKeys: String, CodingKey {
        case jwks
        case encryptedResponseEncValuesSupported = "encrypted_response_enc_values_supported"
        case vpFormatsSupported = "vp_formats_supported"
    }

    public init(
        jwks: JOSEJWKSet? = nil,
        encryptedResponseEncValuesSupported: [String]? = nil,
        vpFormatsSupported: [String: OID4VPVerifierFormatSupport]? = nil
    ) {
        self.jwks = jwks
        self.encryptedResponseEncValuesSupported = encryptedResponseEncValuesSupported
        self.vpFormatsSupported = vpFormatsSupported
    }

    public var supportedContentEncryptionAlgorithms: [String] {
        encryptedResponseEncValuesSupported ?? ["A128GCM"]
    }

    public func validate() throws {
        if let jwks {
            guard !jwks.keys.isEmpty else {
                throw OID4VPVerifierMetadataError.emptyJWKS
            }

            var seenKeyIDs = Set<String>()
            for key in jwks.keys {
                guard let keyID = key.keyID, !keyID.isEmpty else {
                    throw OID4VPVerifierMetadataError.missingJWKKeyID
                }
                if !seenKeyIDs.insert(keyID).inserted {
                    throw OID4VPVerifierMetadataError.duplicateJWKKeyID(keyID)
                }
            }
        }

        if let encryptedResponseEncValuesSupported, encryptedResponseEncValuesSupported.isEmpty {
            throw OID4VPVerifierMetadataError.emptyEncryptedResponseEncValuesSupported
        }

        if let vpFormatsSupported, vpFormatsSupported.isEmpty {
            throw OID4VPVerifierMetadataError.emptyVPFormatsSupported
        }
    }
}

public struct OID4VPDirectPostJWTPreparation: Equatable, Sendable {
    public var responseURI: URL
    public var selectedContentEncryptionAlgorithm: String
    public var selectedKey: JOSEJWK
    public var payload: OID4VPResponse
    public var payloadData: Data

    public init(
        responseURI: URL,
        selectedContentEncryptionAlgorithm: String,
        selectedKey: JOSEJWK,
        payload: OID4VPResponse,
        payloadData: Data
    ) {
        self.responseURI = responseURI
        self.selectedContentEncryptionAlgorithm = selectedContentEncryptionAlgorithm
        self.selectedKey = selectedKey
        self.payload = payload
        self.payloadData = payloadData
    }

    public var suggestedKeyManagementAlgorithm: String? {
        selectedKey.algorithm
    }

    public var contentType: String {
        "application/x-www-form-urlencoded"
    }
}

public enum OID4VPDirectPostJWTPreparationBuilder {
    public static func build(
        requestObject: OID4VPRequestObject,
        response: OID4VPResponse,
        preferredKeyID: String? = nil,
        preferredContentEncryptionAlgorithm: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> OID4VPDirectPostJWTPreparation {
        guard let verifierMetadata = try requestObject.parsedVerifierMetadata() else {
            throw OID4VPDirectPostJWTPreparationError.missingVerifierMetadata
        }
        let responseURI = try validatedResponseURI(from: requestObject)
        return try build(
            responseURI: responseURI,
            verifierMetadata: verifierMetadata,
            response: response,
            preferredKeyID: preferredKeyID,
            preferredContentEncryptionAlgorithm: preferredContentEncryptionAlgorithm,
            encoder: encoder
        )
    }

    public static func build(
        requestObject: OID4VPRequestObject,
        resolvedVerifierMetadata: OID4VPResolvedVerifierMetadata,
        response: OID4VPResponse,
        preferredKeyID: String? = nil,
        preferredContentEncryptionAlgorithm: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> OID4VPDirectPostJWTPreparation {
        let responseURI = try validatedResponseURI(from: requestObject)
        return try build(
            responseURI: responseURI,
            verifierMetadata: resolvedVerifierMetadata.metadata,
            response: response,
            preferredKeyID: preferredKeyID,
            preferredContentEncryptionAlgorithm: preferredContentEncryptionAlgorithm,
            encoder: encoder
        )
    }

    public static func build(
        responseURI: URL,
        verifierMetadata: OID4VPVerifierMetadata,
        response: OID4VPResponse,
        preferredKeyID: String? = nil,
        preferredContentEncryptionAlgorithm: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> OID4VPDirectPostJWTPreparation {
        guard let jwks = verifierMetadata.jwks else {
            throw OID4VPDirectPostJWTPreparationError.missingJWKS
        }

        let encryptionCapableKeys = jwks.keys.filter(\.isEncryptionCapable)
        guard !encryptionCapableKeys.isEmpty else {
            throw OID4VPDirectPostJWTPreparationError.noUsableEncryptionKey
        }

        let selectedKey: JOSEJWK
        if let preferredKeyID {
            guard let matchingKey = encryptionCapableKeys.first(where: { $0.keyID == preferredKeyID }) else {
                throw OID4VPDirectPostJWTPreparationError.unknownKeyIdentifier(preferredKeyID)
            }
            selectedKey = matchingKey
        } else {
            selectedKey = encryptionCapableKeys[0]
        }

        let supportedAlgorithms = verifierMetadata.supportedContentEncryptionAlgorithms
        let selectedContentEncryptionAlgorithm: String
        if let preferredContentEncryptionAlgorithm {
            guard supportedAlgorithms.contains(preferredContentEncryptionAlgorithm) else {
                throw OID4VPDirectPostJWTPreparationError.unsupportedContentEncryption(
                    preferredContentEncryptionAlgorithm
                )
            }
            selectedContentEncryptionAlgorithm = preferredContentEncryptionAlgorithm
        } else {
            selectedContentEncryptionAlgorithm = supportedAlgorithms[0]
        }

        encoder.outputFormatting.insert(.sortedKeys)
        let payloadData = try encoder.encode(response)

        return OID4VPDirectPostJWTPreparation(
            responseURI: responseURI,
            selectedContentEncryptionAlgorithm: selectedContentEncryptionAlgorithm,
            selectedKey: selectedKey,
            payload: response,
            payloadData: payloadData
        )
    }

    private static func validatedResponseURI(from requestObject: OID4VPRequestObject) throws -> URL {
        guard let responseMode = requestObject.responseMode else {
            throw OID4VPDirectPostJWTPreparationError.unsupportedResponseMode(nil)
        }
        guard responseMode == .directPostJwt else {
            throw OID4VPDirectPostJWTPreparationError.unsupportedResponseMode(responseMode.rawIdentifier)
        }
        guard let responseURI = requestObject.responseURI else {
            throw OID4VPDirectPostJWTPreparationError.missingResponseURI
        }
        return responseURI
    }
}

public extension OID4VPRequestObject {
    var resolvedClientIdentifierPrefix: OID4VPClientIdentifierPrefix {
        guard let clientIdentifierPrefix else {
            return .preRegistered
        }

        switch clientIdentifierPrefix {
        case "redirect_uri":
            return .redirectURI
        case "openid_federation":
            return .openidFederation
        case "verifier_attestation":
            return .verifierAttestation
        case "decentralized_identifier":
            return .decentralizedIdentifier
        case "x509_san_dns":
            return .x509SanDNS
        case "x509_hash":
            return .x509Hash
        default:
            return .other(clientIdentifierPrefix)
        }
    }

    func parsedVerifierMetadata(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> OID4VPVerifierMetadata? {
        guard let clientMetadata else {
            return nil
        }

        do {
            encoder.outputFormatting.insert(.sortedKeys)
            let data = try encoder.encode(clientMetadata)
            let metadata = try decoder.decode(OID4VPVerifierMetadata.self, from: data)
            try metadata.validate()
            return metadata
        } catch let error as OID4VPVerifierMetadataError {
            throw error
        } catch {
            throw OID4VPVerifierMetadataError.invalidVerifierMetadata
        }
    }
}

public enum OID4VPVerifierMetadataResolver {
    public static func resolve(
        requestObject: OID4VPRequestObject,
        provider: (any OID4VPVerifierMetadataProvider)? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> OID4VPResolvedVerifierMetadata {
        let requestMetadata = try requestObject.parsedVerifierMetadata(
            encoder: encoder,
            decoder: decoder
        )
        let providerMetadata = try await provider?.metadata(for: requestObject)
        let clientIdentifierPrefix = requestObject.resolvedClientIdentifierPrefix

        switch clientIdentifierPrefix {
        case .preRegistered:
            guard requestMetadata == nil else {
                throw OID4VPVerifierMetadataResolutionError.clientMetadataNotAllowedForPreRegisteredClient
            }
            guard let providerMetadata else {
                throw OID4VPVerifierMetadataResolutionError.missingVerifierMetadata(
                    prefix: clientIdentifierPrefix.rawIdentifier
                )
            }
            try providerMetadata.metadata.validate()
            return providerMetadata.withClientIdentifierPrefix(clientIdentifierPrefix)
        case .openidFederation:
            guard let providerMetadata else {
                throw OID4VPVerifierMetadataResolutionError.missingVerifierMetadata(
                    prefix: clientIdentifierPrefix.rawIdentifier
                )
            }
            try providerMetadata.metadata.validate()
            return providerMetadata.withClientIdentifierPrefix(clientIdentifierPrefix)
        default:
            if let requestMetadata {
                return OID4VPResolvedVerifierMetadata(
                    metadata: requestMetadata,
                    source: .requestClientMetadata,
                    clientIdentifierPrefix: clientIdentifierPrefix
                )
            }
            if let providerMetadata {
                try providerMetadata.metadata.validate()
                return providerMetadata.withClientIdentifierPrefix(clientIdentifierPrefix)
            }
            throw OID4VPVerifierMetadataResolutionError.missingVerifierMetadata(
                prefix: clientIdentifierPrefix.rawIdentifier
            )
        }
    }
}

private extension OID4VPResolvedVerifierMetadata {
    func withClientIdentifierPrefix(
        _ clientIdentifierPrefix: OID4VPClientIdentifierPrefix
    ) -> OID4VPResolvedVerifierMetadata {
        OID4VPResolvedVerifierMetadata(
            metadata: metadata,
            source: source,
            clientIdentifierPrefix: clientIdentifierPrefix
        )
    }
}
