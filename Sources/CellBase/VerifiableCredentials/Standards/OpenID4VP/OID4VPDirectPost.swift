// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPDirectPostError: Error, Equatable {
    case unsupportedResponseMode(String?)
    case missingResponseURI
    case missingJWTResponse
    case invalidRedirectURI
}

public struct OID4VPAuthorizationErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var errorDescription: String?
    public var state: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case state
    }

    public init(error: String, errorDescription: String? = nil, state: String? = nil) {
        self.error = error
        self.errorDescription = errorDescription
        self.state = state
    }

    public var formParameters: [String: String] {
        var parameters = ["error": error]
        if let errorDescription {
            parameters["error_description"] = errorDescription
        }
        if let state {
            parameters["state"] = state
        }
        return parameters
    }
}

public struct OID4VPDirectPostSubmission: Equatable, Sendable {
    public var responseURI: URL
    public var responseMode: OID4VPResponseMode
    public var formParameters: [String: String]

    public init(
        responseURI: URL,
        responseMode: OID4VPResponseMode,
        formParameters: [String: String]
    ) {
        self.responseURI = responseURI
        self.responseMode = responseMode
        self.formParameters = formParameters
    }

    public var contentType: String {
        "application/x-www-form-urlencoded"
    }

    public func bodyData() -> Data {
        let encodedPairs = formParameters
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                "\(percentEncodeFormComponent(key))=\(percentEncodeFormComponent(value))"
            }
            .joined(separator: "&")
        return Data(encodedPairs.utf8)
    }

    private func percentEncodeFormComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*-._"))
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}

public struct OID4VPDirectPostCallback: Codable, Equatable, Sendable {
    public var redirectURI: URL?
    public var additionalParameters: [String: OID4VPJSONValue]

    enum CodingKeys: String, CodingKey {
        case redirectURI = "redirect_uri"
    }

    public init(
        redirectURI: URL? = nil,
        additionalParameters: [String: OID4VPJSONValue] = [:]
    ) {
        self.redirectURI = redirectURI
        self.additionalParameters = additionalParameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var redirectURI: URL?
        var additionalParameters: [String: OID4VPJSONValue] = [:]

        for key in container.allKeys {
            if key.stringValue == "redirect_uri" {
                redirectURI = try container.decodeIfPresent(URL.self, forKey: key)
            } else {
                additionalParameters[key.stringValue] = try container.decode(OID4VPJSONValue.self, forKey: key)
            }
        }

        self.redirectURI = redirectURI
        self.additionalParameters = additionalParameters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        if let redirectURI {
            try container.encode(redirectURI, forKey: DynamicCodingKey(stringValue: "redirect_uri"))
        }
        for (key, value) in additionalParameters.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    public func validated() throws -> OID4VPDirectPostCallback {
        if let redirectURI, redirectURI.scheme == nil {
            throw OID4VPDirectPostError.invalidRedirectURI
        }
        return self
    }
}

public enum OID4VPDirectPostBuilder {
    public static func build(
        requestObject: OID4VPRequestObject,
        response: OID4VPResponse,
        jwtResponse: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> OID4VPDirectPostSubmission {
        guard let responseMode = requestObject.responseMode else {
            throw OID4VPDirectPostError.unsupportedResponseMode(nil)
        }
        guard responseMode == .directPost || responseMode == .directPostJwt else {
            throw OID4VPDirectPostError.unsupportedResponseMode(responseMode.rawIdentifier)
        }
        guard let responseURI = requestObject.responseURI else {
            throw OID4VPDirectPostError.missingResponseURI
        }

        let formParameters: [String: String]
        switch responseMode {
        case .directPost:
            formParameters = try response.formParameters(encoder: encoder)
        case .directPostJwt:
            guard let jwtResponse else {
                throw OID4VPDirectPostError.missingJWTResponse
            }
            formParameters = ["response": jwtResponse]
        default:
            throw OID4VPDirectPostError.unsupportedResponseMode(responseMode.rawIdentifier)
        }

        return OID4VPDirectPostSubmission(
            responseURI: responseURI,
            responseMode: responseMode,
            formParameters: formParameters
        )
    }

    public static func buildError(
        requestObject: OID4VPRequestObject,
        errorResponse: OID4VPAuthorizationErrorResponse
    ) throws -> OID4VPDirectPostSubmission {
        guard let responseMode = requestObject.responseMode else {
            throw OID4VPDirectPostError.unsupportedResponseMode(nil)
        }
        guard responseMode == .directPost || responseMode == .directPostJwt else {
            throw OID4VPDirectPostError.unsupportedResponseMode(responseMode.rawIdentifier)
        }
        guard let responseURI = requestObject.responseURI else {
            throw OID4VPDirectPostError.missingResponseURI
        }

        return OID4VPDirectPostSubmission(
            responseURI: responseURI,
            responseMode: responseMode,
            formParameters: errorResponse.formParameters
        )
    }

    public static func parseCallback(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> OID4VPDirectPostCallback {
        let callback = try decoder.decode(OID4VPDirectPostCallback.self, from: data)
        return try callback.validated()
    }
}

public extension OID4VPResponse {
    func formParameters(encoder: JSONEncoder = JSONEncoder()) throws -> [String: String] {
        var parameters: [String: String] = [:]

        if let vpToken {
            encoder.outputFormatting.insert(.sortedKeys)
            let data = try encoder.encode(vpToken)
            parameters["vp_token"] = String(decoding: data, as: UTF8.self)
        }
        if let state {
            parameters["state"] = state
        }
        if let idToken {
            parameters["id_token"] = idToken
        }
        if let code {
            parameters["code"] = code
        }
        if let issuer {
            parameters["iss"] = issuer
        }

        return parameters
    }
}
