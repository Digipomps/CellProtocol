// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPSignedRequestObjectError: Error, Equatable {
    case invalidProtectedHeader
    case invalidRequestObject
    case insecureSigningAlgorithm(String)
    case invalidRequestObjectType(String?)
    case signedRequestNotAllowed(prefix: String)
    case missingKeyIdentifier(prefix: String)
    case missingCertificateChain(prefix: String)
    case missingVerifierAttestationJWT
    case invalidVerifierAttestation
    case invalidVerifierAttestationType(String?)
    case invalidVerifierAttestationConfirmation
    case verifierAttestationSubjectMismatch(expected: String, actual: String)
    case verifierAttestationExpired
    case verifierAttestationNotYetValid
    case issuerClaimMismatch(expected: String, actual: String)
}

public enum OID4VPJWTAudience: Codable, Equatable, Sendable {
    case string(String)
    case array([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            self = .array(try container.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }
}

public struct OID4VPSignedRequestObjectHeader: Codable, Equatable, Sendable {
    public var algorithm: String
    public var type: String?
    public var keyID: String?
    public var certificateChain: [String]?
    public var verifierAttestationJWT: String?

    enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case type = "typ"
        case keyID = "kid"
        case certificateChain = "x5c"
        case verifierAttestationJWT = "jwt"
    }

    public init(
        algorithm: String,
        type: String? = nil,
        keyID: String? = nil,
        certificateChain: [String]? = nil,
        verifierAttestationJWT: String? = nil
    ) {
        self.algorithm = algorithm
        self.type = type
        self.keyID = keyID
        self.certificateChain = certificateChain
        self.verifierAttestationJWT = verifierAttestationJWT
    }
}

public struct OID4VPVerifierAttestationHeader: Codable, Equatable, Sendable {
    public var algorithm: String
    public var type: String?
    public var keyID: String?
    public var certificateChain: [String]?

    enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case type = "typ"
        case keyID = "kid"
        case certificateChain = "x5c"
    }

    public init(
        algorithm: String,
        type: String? = nil,
        keyID: String? = nil,
        certificateChain: [String]? = nil
    ) {
        self.algorithm = algorithm
        self.type = type
        self.keyID = keyID
        self.certificateChain = certificateChain
    }
}

public struct OID4VPVerifierAttestationConfirmation: Codable, Equatable, Sendable {
    public var jwk: JOSEJWK

    public init(jwk: JOSEJWK) {
        self.jwk = jwk
    }
}

public struct OID4VPVerifierAttestationClaims: Codable, Equatable, Sendable {
    public var issuer: String
    public var subject: String
    public var issuedAt: Int?
    public var expiresAt: Int
    public var notBefore: Int?
    public var confirmation: OID4VPVerifierAttestationConfirmation
    public var redirectURIs: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case issuedAt = "iat"
        case expiresAt = "exp"
        case notBefore = "nbf"
        case confirmation = "cnf"
        case redirectURIs = "redirect_uris"
    }

    public init(
        issuer: String,
        subject: String,
        issuedAt: Int? = nil,
        expiresAt: Int,
        notBefore: Int? = nil,
        confirmation: OID4VPVerifierAttestationConfirmation,
        redirectURIs: [String]? = nil
    ) {
        self.issuer = issuer
        self.subject = subject
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.notBefore = notBefore
        self.confirmation = confirmation
        self.redirectURIs = redirectURIs
    }
}

public struct OID4VPVerifierAttestationJWT: Equatable, Sendable {
    public var jws: JOSECompactJWS
    public var header: OID4VPVerifierAttestationHeader
    public var claims: OID4VPVerifierAttestationClaims

    public init(
        jws: JOSECompactJWS,
        header: OID4VPVerifierAttestationHeader,
        claims: OID4VPVerifierAttestationClaims
    ) {
        self.jws = jws
        self.header = header
        self.claims = claims
    }
}

public struct OID4VPSignedRequestObjectClaims: Codable, Equatable, Sendable {
    public var issuer: String?
    public var audience: OID4VPJWTAudience?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case audience = "aud"
    }

    public init(
        issuer: String? = nil,
        audience: OID4VPJWTAudience? = nil
    ) {
        self.issuer = issuer
        self.audience = audience
    }
}

public struct OID4VPSignedRequestObject: Equatable, Sendable {
    public var jws: JOSECompactJWS
    public var header: OID4VPSignedRequestObjectHeader
    public var requestObject: OID4VPRequestObject
    public var requestClaims: OID4VPSignedRequestObjectClaims
    public var verifierAttestation: OID4VPVerifierAttestationJWT?

    public init(
        jws: JOSECompactJWS,
        header: OID4VPSignedRequestObjectHeader,
        requestObject: OID4VPRequestObject,
        requestClaims: OID4VPSignedRequestObjectClaims,
        verifierAttestation: OID4VPVerifierAttestationJWT? = nil
    ) {
        self.jws = jws
        self.header = header
        self.requestObject = requestObject
        self.requestClaims = requestClaims
        self.verifierAttestation = verifierAttestation
    }

    public static func parse(
        _ compactSerialization: String,
        now: Date = Date(),
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> OID4VPSignedRequestObject {
        let jws = try JOSECompactJWS(compactSerialization: compactSerialization)
        guard let headerData = jws.protectedHeaderData else {
            throw OID4VPSignedRequestObjectError.invalidProtectedHeader
        }
        guard let payloadData = jws.payloadData else {
            throw OID4VPSignedRequestObjectError.invalidRequestObject
        }

        let header: OID4VPSignedRequestObjectHeader
        let requestClaims: OID4VPSignedRequestObjectClaims
        let requestObject: OID4VPRequestObject
        do {
            header = try decoder.decode(OID4VPSignedRequestObjectHeader.self, from: headerData)
            requestClaims = try decoder.decode(OID4VPSignedRequestObjectClaims.self, from: payloadData)
            requestObject = try OID4VPRequestObject.parse(payloadData, decoder: decoder)
        } catch let error as OID4VPRequestObjectError {
            throw error
        } catch {
            if (try? decoder.decode(OID4VPSignedRequestObjectHeader.self, from: headerData)) == nil {
                throw OID4VPSignedRequestObjectError.invalidProtectedHeader
            }
            throw OID4VPSignedRequestObjectError.invalidRequestObject
        }

        try validateSigningAlgorithm(header.algorithm)
        guard header.type == "oauth-authz-req+jwt" else {
            throw OID4VPSignedRequestObjectError.invalidRequestObjectType(header.type)
        }

        if let issuer = requestClaims.issuer, issuer != requestObject.clientID {
            throw OID4VPSignedRequestObjectError.issuerClaimMismatch(
                expected: requestObject.clientID,
                actual: issuer
            )
        }

        let verifierAttestation: OID4VPVerifierAttestationJWT?
        switch requestObject.resolvedClientIdentifierPrefix {
        case .redirectURI:
            throw OID4VPSignedRequestObjectError.signedRequestNotAllowed(
                prefix: requestObject.resolvedClientIdentifierPrefix.rawIdentifier
            )
        case .decentralizedIdentifier:
            guard let keyID = header.keyID, !keyID.isEmpty else {
                throw OID4VPSignedRequestObjectError.missingKeyIdentifier(
                    prefix: requestObject.resolvedClientIdentifierPrefix.rawIdentifier
                )
            }
            _ = keyID
            verifierAttestation = nil
        case .verifierAttestation:
            guard let verifierAttestationJWT = header.verifierAttestationJWT else {
                throw OID4VPSignedRequestObjectError.missingVerifierAttestationJWT
            }
            let parsedAttestation = try parseVerifierAttestation(
                verifierAttestationJWT,
                expectedSubject: requestObject.clientIdentifierValue,
                now: now,
                decoder: decoder
            )
            verifierAttestation = parsedAttestation
        case .x509SanDNS, .x509Hash:
            guard let certificateChain = header.certificateChain, !certificateChain.isEmpty else {
                throw OID4VPSignedRequestObjectError.missingCertificateChain(
                    prefix: requestObject.resolvedClientIdentifierPrefix.rawIdentifier
                )
            }
            _ = certificateChain
            verifierAttestation = nil
        default:
            verifierAttestation = nil
        }

        return OID4VPSignedRequestObject(
            jws: jws,
            header: header,
            requestObject: requestObject,
            requestClaims: requestClaims,
            verifierAttestation: verifierAttestation
        )
    }

    private static func validateSigningAlgorithm(_ algorithm: String) throws {
        if algorithm == "none" || algorithm.hasPrefix("HS") {
            throw OID4VPSignedRequestObjectError.insecureSigningAlgorithm(algorithm)
        }
    }

    private static func parseVerifierAttestation(
        _ compactSerialization: String,
        expectedSubject: String,
        now: Date,
        decoder: JSONDecoder
    ) throws -> OID4VPVerifierAttestationJWT {
        let jws = try JOSECompactJWS(compactSerialization: compactSerialization)
        guard let headerData = jws.protectedHeaderData,
              let payloadData = jws.payloadData else {
            throw OID4VPSignedRequestObjectError.invalidVerifierAttestation
        }

        let header: OID4VPVerifierAttestationHeader
        let claims: OID4VPVerifierAttestationClaims
        do {
            header = try decoder.decode(OID4VPVerifierAttestationHeader.self, from: headerData)
            claims = try decoder.decode(OID4VPVerifierAttestationClaims.self, from: payloadData)
        } catch {
            throw OID4VPSignedRequestObjectError.invalidVerifierAttestation
        }

        try validateSigningAlgorithm(header.algorithm)
        guard header.type == "verifier-attestation+jwt" else {
            throw OID4VPSignedRequestObjectError.invalidVerifierAttestationType(header.type)
        }

        if claims.subject != expectedSubject {
            throw OID4VPSignedRequestObjectError.verifierAttestationSubjectMismatch(
                expected: expectedSubject,
                actual: claims.subject
            )
        }

        guard !claims.confirmation.jwk.keyType.isEmpty else {
            throw OID4VPSignedRequestObjectError.invalidVerifierAttestationConfirmation
        }

        let nowTimestamp = Int(now.timeIntervalSince1970)
        if claims.expiresAt <= nowTimestamp {
            throw OID4VPSignedRequestObjectError.verifierAttestationExpired
        }
        if let notBefore = claims.notBefore, notBefore > nowTimestamp {
            throw OID4VPSignedRequestObjectError.verifierAttestationNotYetValid
        }

        return OID4VPVerifierAttestationJWT(
            jws: jws,
            header: header,
            claims: claims
        )
    }
}
