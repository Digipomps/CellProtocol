// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPResponseError: Error, Equatable {
    case requestDoesNotCarryDCQL
    case unsatisfiedRequiredConstraints
    case missingPresentation(queryID: String, candidateID: String)
}

public enum OID4VPResponsePresentation: Codable, Equatable, Sendable {
    case string(String)
    case object([String: OID4VPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            self = .object(try container.decode([String: OID4VPJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct OID4VPResponse: Codable, Equatable, Sendable {
    public var vpToken: [String: [OID4VPResponsePresentation]]?
    public var state: String?
    public var idToken: String?
    public var code: String?
    public var issuer: String?

    enum CodingKeys: String, CodingKey {
        case vpToken = "vp_token"
        case state
        case idToken = "id_token"
        case code
        case issuer = "iss"
    }

    public init(
        vpToken: [String: [OID4VPResponsePresentation]]? = nil,
        state: String? = nil,
        idToken: String? = nil,
        code: String? = nil,
        issuer: String? = nil
    ) {
        self.vpToken = vpToken
        self.state = state
        self.idToken = idToken
        self.code = code
        self.issuer = issuer
    }

    public var hasVPToken: Bool {
        !(vpToken ?? [:]).isEmpty
    }

    public func presentations(for credentialID: String) -> [OID4VPResponsePresentation] {
        vpToken?[credentialID] ?? []
    }
}

public enum OID4VPResponseBuilder {
    public static func build(
        requestObject: OID4VPRequestObject,
        matchResult: OID4VPRequestMatchResult,
        idToken: String? = nil,
        code: String? = nil,
        issuer: String? = nil
    ) throws -> OID4VPResponse {
        guard let dcqlQuery = requestObject.dcqlQuery else {
            throw OID4VPResponseError.requestDoesNotCarryDCQL
        }
        guard matchResult.satisfiesRequiredConstraints else {
            throw OID4VPResponseError.unsatisfiedRequiredConstraints
        }

        var vpToken: [String: [OID4VPResponsePresentation]] = [:]

        for credentialQuery in dcqlQuery.credentials {
            let matches = matchResult.matches(for: credentialQuery.id)
            guard !matches.isEmpty else {
                continue
            }

            let selectedMatches = credentialQuery.allowsMultiple ? matches : [matches[0]]
            let presentations = try selectedMatches.map { match in
                guard let presentation = match.candidate.presentation else {
                    throw OID4VPResponseError.missingPresentation(
                        queryID: credentialQuery.id,
                        candidateID: match.candidate.id
                    )
                }
                return presentation
            }
            vpToken[credentialQuery.id] = presentations
        }

        return OID4VPResponse(
            vpToken: vpToken.isEmpty ? nil : vpToken,
            state: requestObject.state,
            idToken: idToken,
            code: code,
            issuer: issuer
        )
    }
}
