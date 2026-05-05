// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPRequestObjectError: Error, Equatable {
    case emptyClientID
    case invalidResponseType(String)
    case conflictingPresentationQueryParameters
    case missingPresentationQuery
    case missingResponseURI
    case invalidResponseURI
    case invalidState
}

public enum OID4VPResponseMode: Codable, Equatable, Hashable, Sendable {
    case fragment
    case query
    case formPost
    case directPost
    case directPostJwt
    case dcAPI
    case dcAPIJWT
    case other(String)

    public var rawIdentifier: String {
        switch self {
        case .fragment:
            return "fragment"
        case .query:
            return "query"
        case .formPost:
            return "form_post"
        case .directPost:
            return "direct_post"
        case .directPostJwt:
            return "direct_post.jwt"
        case .dcAPI:
            return "dc_api"
        case .dcAPIJWT:
            return "dc_api.jwt"
        case .other(let value):
            return value
        }
    }

    public var requiresResponseURI: Bool {
        switch self {
        case .directPost, .directPostJwt:
            return true
        default:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        switch identifier {
        case "fragment":
            self = .fragment
        case "query":
            self = .query
        case "form_post":
            self = .formPost
        case "direct_post":
            self = .directPost
        case "direct_post.jwt":
            self = .directPostJwt
        case "dc_api":
            self = .dcAPI
        case "dc_api.jwt":
            self = .dcAPIJWT
        default:
            self = .other(identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawIdentifier)
    }
}

public struct OID4VPResponseType: Codable, Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var components: [String] {
        rawValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    public var includesVPToken: Bool {
        components.contains("vp_token")
    }

    public var includesIDToken: Bool {
        components.contains("id_token")
    }

    public var includesAuthorizationCode: Bool {
        components.contains("code")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct OID4VPRequestObject: Codable, Equatable, Sendable {
    public var clientID: String
    public var responseType: OID4VPResponseType
    public var responseMode: OID4VPResponseMode?
    public var redirectURI: URL?
    public var responseURI: URL?
    public var dcqlQuery: OID4VPDCQLQuery?
    public var scope: String?
    public var nonce: String?
    public var state: String?
    public var clientMetadata: [String: OID4VPJSONValue]?
    public var walletNonce: String?
    public var requestURIMethod: String?
    public var transactionData: [OID4VPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case responseType = "response_type"
        case responseMode = "response_mode"
        case redirectURI = "redirect_uri"
        case responseURI = "response_uri"
        case dcqlQuery = "dcql_query"
        case scope
        case nonce
        case state
        case clientMetadata = "client_metadata"
        case walletNonce = "wallet_nonce"
        case requestURIMethod = "request_uri_method"
        case transactionData = "transaction_data"
    }

    public init(
        clientID: String,
        responseType: OID4VPResponseType,
        responseMode: OID4VPResponseMode? = nil,
        redirectURI: URL? = nil,
        responseURI: URL? = nil,
        dcqlQuery: OID4VPDCQLQuery? = nil,
        scope: String? = nil,
        nonce: String? = nil,
        state: String? = nil,
        clientMetadata: [String: OID4VPJSONValue]? = nil,
        walletNonce: String? = nil,
        requestURIMethod: String? = nil,
        transactionData: [OID4VPJSONValue]? = nil
    ) {
        self.clientID = clientID
        self.responseType = responseType
        self.responseMode = responseMode
        self.redirectURI = redirectURI
        self.responseURI = responseURI
        self.dcqlQuery = dcqlQuery
        self.scope = scope
        self.nonce = nonce
        self.state = state
        self.clientMetadata = clientMetadata
        self.walletNonce = walletNonce
        self.requestURIMethod = requestURIMethod
        self.transactionData = transactionData
    }

    public static func parse(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> OID4VPRequestObject {
        let requestObject = try decoder.decode(OID4VPRequestObject.self, from: data)
        try requestObject.validate()
        return requestObject
    }

    public var clientIdentifierPrefix: String? {
        if let url = URL(string: clientID), url.scheme != nil, url.host != nil {
            return nil
        }
        guard let separator = clientID.firstIndex(of: ":") else {
            return nil
        }
        let prefix = String(clientID[..<separator])
        if prefix.contains("/") {
            return nil
        }
        return prefix
    }

    public var clientIdentifierValue: String {
        guard let separator = clientID.firstIndex(of: ":"), clientIdentifierPrefix != nil else {
            return clientID
        }
        return String(clientID[clientID.index(after: separator)...])
    }

    public func validate() throws {
        guard !clientID.isEmpty else {
            throw OID4VPRequestObjectError.emptyClientID
        }

        let responseTypeComponents = responseType.components
        let allowedResponseTypeComponents = Set(["vp_token", "id_token", "code"])
        guard !responseTypeComponents.isEmpty,
              responseTypeComponents.allSatisfy({ allowedResponseTypeComponents.contains($0) }) else {
            throw OID4VPRequestObjectError.invalidResponseType(responseType.rawValue)
        }

        if dcqlQuery != nil && scope != nil {
            throw OID4VPRequestObjectError.conflictingPresentationQueryParameters
        }

        if responseType.includesVPToken && dcqlQuery == nil && scope == nil {
            throw OID4VPRequestObjectError.missingPresentationQuery
        }

        if let dcqlQuery {
            try dcqlQuery.validate()
        }

        if let responseMode, responseMode.requiresResponseURI {
            guard let responseURI else {
                throw OID4VPRequestObjectError.missingResponseURI
            }
            guard responseURI.scheme?.lowercased() == "https" else {
                throw OID4VPRequestObjectError.invalidResponseURI
            }
        }

        if let state {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            if state.rangeOfCharacter(from: allowed.inverted) != nil {
                throw OID4VPRequestObjectError.invalidState
            }
        }
    }
}
