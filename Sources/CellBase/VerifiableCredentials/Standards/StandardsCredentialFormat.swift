// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum StandardsCredentialFormat: Codable, Equatable, Hashable, Sendable {
    case jwtVcJson
    case jwtVcJsonLd
    case ldpVc
    case sdJwtVc
    case isoMdoc
    case other(String)

    public var rawIdentifier: String {
        switch self {
        case .jwtVcJson:
            return "jwt_vc_json"
        case .jwtVcJsonLd:
            return "jwt_vc_json-ld"
        case .ldpVc:
            return "ldp_vc"
        case .sdJwtVc:
            return "dc+sd-jwt"
        case .isoMdoc:
            return "mso_mdoc"
        case .other(let identifier):
            return identifier
        }
    }

    public var isKnownStandard: Bool {
        if case .other = self {
            return false
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        switch identifier {
        case "jwt_vc_json":
            self = .jwtVcJson
        case "jwt_vc_json-ld":
            self = .jwtVcJsonLd
        case "ldp_vc":
            self = .ldpVc
        case "dc+sd-jwt":
            self = .sdJwtVc
        case "mso_mdoc":
            self = .isoMdoc
        default:
            self = .other(identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawIdentifier)
    }
}
