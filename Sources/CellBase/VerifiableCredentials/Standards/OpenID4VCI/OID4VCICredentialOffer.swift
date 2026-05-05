// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VCICredentialOfferError: Error, Equatable {
    case missingOfferParameter
    case conflictingOfferParameters
    case invalidOfferURI
    case invalidCredentialIssuer
    case emptyCredentialConfigurationIDs
    case duplicateCredentialConfigurationID(String)
    case emptyPreAuthorizedCode
    case invalidTransactionCodeLength
    case invalidAuthorizationServer
}

public enum OID4VCITransactionCodeInputMode: Codable, Equatable, Hashable, Sendable {
    case numeric
    case text
    case other(String)

    public var rawIdentifier: String {
        switch self {
        case .numeric:
            return "numeric"
        case .text:
            return "text"
        case .other(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "numeric":
            self = .numeric
        case "text":
            self = .text
        default:
            self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawIdentifier)
    }
}

public struct OID4VCITransactionCode: Codable, Equatable, Sendable {
    public var inputMode: OID4VCITransactionCodeInputMode?
    public var length: Int?
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case inputMode = "input_mode"
        case length
        case description
    }

    public init(
        inputMode: OID4VCITransactionCodeInputMode? = nil,
        length: Int? = nil,
        description: String? = nil
    ) {
        self.inputMode = inputMode
        self.length = length
        self.description = description
    }

    public func validate() throws {
        if let length, length <= 0 {
            throw OID4VCICredentialOfferError.invalidTransactionCodeLength
        }
    }
}

public struct OID4VCIAuthorizationCodeGrant: Codable, Equatable, Sendable {
    public var issuerState: String?
    public var authorizationServer: String?

    enum CodingKeys: String, CodingKey {
        case issuerState = "issuer_state"
        case authorizationServer = "authorization_server"
    }

    public init(
        issuerState: String? = nil,
        authorizationServer: String? = nil
    ) {
        self.issuerState = issuerState
        self.authorizationServer = authorizationServer
    }

    public func validate() throws {
        if let authorizationServer {
            guard OID4VCICredentialOffer.isValidHTTPSIdentifier(authorizationServer) else {
                throw OID4VCICredentialOfferError.invalidAuthorizationServer
            }
        }
    }
}

public struct OID4VCIPreAuthorizedCodeGrant: Codable, Equatable, Sendable {
    public var preAuthorizedCode: String
    public var transactionCode: OID4VCITransactionCode?
    public var authorizationServer: String?

    enum CodingKeys: String, CodingKey {
        case preAuthorizedCode = "pre-authorized_code"
        case transactionCode = "tx_code"
        case authorizationServer = "authorization_server"
    }

    public init(
        preAuthorizedCode: String,
        transactionCode: OID4VCITransactionCode? = nil,
        authorizationServer: String? = nil
    ) {
        self.preAuthorizedCode = preAuthorizedCode
        self.transactionCode = transactionCode
        self.authorizationServer = authorizationServer
    }

    public func validate() throws {
        guard !preAuthorizedCode.isEmpty else {
            throw OID4VCICredentialOfferError.emptyPreAuthorizedCode
        }
        try transactionCode?.validate()
        if let authorizationServer {
            guard OID4VCICredentialOffer.isValidHTTPSIdentifier(authorizationServer) else {
                throw OID4VCICredentialOfferError.invalidAuthorizationServer
            }
        }
    }
}

public struct OID4VCICredentialOfferGrants: Codable, Equatable, Sendable {
    public var authorizationCode: OID4VCIAuthorizationCodeGrant?
    public var preAuthorizedCode: OID4VCIPreAuthorizedCodeGrant?

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case preAuthorizedCode = "urn:ietf:params:oauth:grant-type:pre-authorized_code"
    }

    public init(
        authorizationCode: OID4VCIAuthorizationCodeGrant? = nil,
        preAuthorizedCode: OID4VCIPreAuthorizedCodeGrant? = nil
    ) {
        self.authorizationCode = authorizationCode
        self.preAuthorizedCode = preAuthorizedCode
    }

    public var isEmpty: Bool {
        authorizationCode == nil && preAuthorizedCode == nil
    }

    public func validate() throws {
        try authorizationCode?.validate()
        try preAuthorizedCode?.validate()
    }
}

public struct OID4VCICredentialOffer: Codable, Equatable, Sendable {
    public var credentialIssuer: String
    public var credentialConfigurationIDs: [String]
    public var grants: OID4VCICredentialOfferGrants?

    enum CodingKeys: String, CodingKey {
        case credentialIssuer = "credential_issuer"
        case credentialConfigurationIDs = "credential_configuration_ids"
        case grants
    }

    public init(
        credentialIssuer: String,
        credentialConfigurationIDs: [String],
        grants: OID4VCICredentialOfferGrants? = nil
    ) {
        self.credentialIssuer = credentialIssuer
        self.credentialConfigurationIDs = credentialConfigurationIDs
        self.grants = grants
    }

    public static func parse(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> OID4VCICredentialOffer {
        let offer = try decoder.decode(OID4VCICredentialOffer.self, from: data)
        try offer.validate()
        return offer
    }

    public func validate() throws {
        guard Self.isValidHTTPSIdentifier(credentialIssuer) else {
            throw OID4VCICredentialOfferError.invalidCredentialIssuer
        }
        guard !credentialConfigurationIDs.isEmpty else {
            throw OID4VCICredentialOfferError.emptyCredentialConfigurationIDs
        }

        var seen = Set<String>()
        for identifier in credentialConfigurationIDs {
            if !seen.insert(identifier).inserted {
                throw OID4VCICredentialOfferError.duplicateCredentialConfigurationID(identifier)
            }
        }

        try grants?.validate()
    }

    fileprivate static func isValidHTTPSIdentifier(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            return false
        }
        return true
    }
}

public enum OID4VCICredentialOfferEnvelope: Equatable, Sendable {
    case byValue(OID4VCICredentialOffer)
    case byReference(URL)

    public static func parse(url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> OID4VCICredentialOfferEnvelope {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OID4VCICredentialOfferError.invalidOfferURI
        }

        let queryItems = components.queryItems ?? []
        let credentialOfferValue = queryItems.first(where: { $0.name == "credential_offer" })?.value
        let credentialOfferURIValue = queryItems.first(where: { $0.name == "credential_offer_uri" })?.value

        switch (credentialOfferValue, credentialOfferURIValue) {
        case (.none, .none):
            throw OID4VCICredentialOfferError.missingOfferParameter
        case (.some, .some):
            throw OID4VCICredentialOfferError.conflictingOfferParameters
        case (.some(let offerValue), .none):
            let offer = try OID4VCICredentialOffer.parse(Data(offerValue.utf8), decoder: decoder)
            return .byValue(offer)
        case (.none, .some(let offerURIValue)):
            guard let offerURL = URL(string: offerURIValue),
                  offerURL.scheme?.lowercased() == "https",
                  offerURL.host != nil else {
                throw OID4VCICredentialOfferError.invalidOfferURI
            }
            return .byReference(offerURL)
        }
    }

    public var offer: OID4VCICredentialOffer? {
        if case .byValue(let offer) = self {
            return offer
        }
        return nil
    }

    public var offerURL: URL? {
        if case .byReference(let url) = self {
            return url
        }
        return nil
    }
}
