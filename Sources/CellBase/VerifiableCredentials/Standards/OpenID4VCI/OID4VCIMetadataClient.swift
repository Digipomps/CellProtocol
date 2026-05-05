// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OID4VCIMetadataClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case unsupportedContentType(String?)
    case invalidSignedMetadataJWT
    case invalidSignedMetadataAlgorithm(String)
    case invalidSignedMetadataType(String?)
    case missingSignedMetadataSubject
    case signedMetadataSubjectMismatch(expected: String, actual: String)
    case missingSignedMetadataIssuedAt
    case expiredSignedMetadata
}

public struct OID4VCIHTTPResponse: Equatable, Sendable {
    public var url: URL
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, statusCode: Int, headers: [String: String], body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func headerValue(for name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol OID4VCIHTTPTransport {
    func get(
        url: URL,
        acceptContentTypes: [String],
        preferredLanguages: [String]?
    ) async throws -> OID4VCIHTTPResponse
}

public struct FoundationOID4VCIHTTPTransport: OID4VCIHTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(
        url: URL,
        acceptContentTypes: [String],
        preferredLanguages: [String]?
    ) async throws -> OID4VCIHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !acceptContentTypes.isEmpty {
            request.setValue(acceptContentTypes.joined(separator: ", "), forHTTPHeaderField: "Accept")
        }
        if let preferredLanguages, !preferredLanguages.isEmpty {
            request.setValue(preferredLanguages.joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
        }

        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let keyString = key as? String else { continue }
            headers[keyString] = String(describing: value)
        }

        return OID4VCIHTTPResponse(
            url: url,
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

public struct OID4VCISignedMetadataHeader: Codable, Equatable, Sendable {
    public var algorithm: String
    public var type: String?
    public var keyID: String?
    public var certificateChain: [String]?
    public var trustChain: [String]?

    enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case type = "typ"
        case keyID = "kid"
        case certificateChain = "x5c"
        case trustChain = "trust_chain"
    }

    public init(
        algorithm: String,
        type: String? = nil,
        keyID: String? = nil,
        certificateChain: [String]? = nil,
        trustChain: [String]? = nil
    ) {
        self.algorithm = algorithm
        self.type = type
        self.keyID = keyID
        self.certificateChain = certificateChain
        self.trustChain = trustChain
    }
}

public struct OID4VCISignedMetadataClaims: Codable, Equatable, Sendable {
    public var issuer: String?
    public var subject: String
    public var issuedAt: Int
    public var expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case issuedAt = "iat"
        case expiresAt = "exp"
    }

    public init(
        issuer: String? = nil,
        subject: String,
        issuedAt: Int,
        expiresAt: Int? = nil
    ) {
        self.issuer = issuer
        self.subject = subject
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct OID4VCISignedMetadataEnvelope: Equatable, Sendable {
    public var compactJWT: String
    public var header: OID4VCISignedMetadataHeader
    public var claims: OID4VCISignedMetadataClaims
    public var signature: String

    public init(
        compactJWT: String,
        header: OID4VCISignedMetadataHeader,
        claims: OID4VCISignedMetadataClaims,
        signature: String
    ) {
        self.compactJWT = compactJWT
        self.header = header
        self.claims = claims
        self.signature = signature
    }
}

public struct OID4VCIMetadataFetchResult: Equatable, Sendable {
    public var metadataURL: URL
    public var responseContentType: String
    public var metadata: OID4VCIIssuerMetadata
    public var signedEnvelope: OID4VCISignedMetadataEnvelope?

    public init(
        metadataURL: URL,
        responseContentType: String,
        metadata: OID4VCIIssuerMetadata,
        signedEnvelope: OID4VCISignedMetadataEnvelope? = nil
    ) {
        self.metadataURL = metadataURL
        self.responseContentType = responseContentType
        self.metadata = metadata
        self.signedEnvelope = signedEnvelope
    }
}

private enum OID4VCIMetadataMediaType: String {
    case json = "application/json"
    case jwt = "application/jwt"

    static func parse(_ headerValue: String?) -> OID4VCIMetadataMediaType? {
        guard let headerValue else { return nil }
        let rawMediaType = headerValue.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let rawMediaType else { return nil }
        return OID4VCIMetadataMediaType(rawValue: rawMediaType)
    }
}

public enum OID4VCIMetadataClient {
    public static func fetch<T: OID4VCIHTTPTransport>(
        credentialIssuer: String,
        transport: T,
        preferSignedMetadata: Bool = false,
        preferredLanguages: [String]? = nil,
        referenceDate: Date = Date(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> OID4VCIMetadataFetchResult {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: credentialIssuer)
        let acceptContentTypes = preferSignedMetadata
            ? ["application/jwt", "application/json"]
            : ["application/json"]

        let response = try await transport.get(
            url: metadataURL,
            acceptContentTypes: acceptContentTypes,
            preferredLanguages: preferredLanguages
        )

        guard response.statusCode == 200 else {
            throw OID4VCIMetadataClientError.unexpectedStatusCode(response.statusCode)
        }

        let contentType = response.headerValue(for: "Content-Type")
        guard let mediaType = OID4VCIMetadataMediaType.parse(contentType) else {
            throw OID4VCIMetadataClientError.unsupportedContentType(contentType)
        }

        switch mediaType {
        case .json:
            let metadata = try decoder.decode(OID4VCIIssuerMetadata.self, from: response.body)
            try metadata.validatedAgainst(metadataURL: metadataURL)
            return OID4VCIMetadataFetchResult(
                metadataURL: metadataURL,
                responseContentType: mediaType.rawValue,
                metadata: metadata
            )
        case .jwt:
            let compactJWT = String(decoding: response.body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let signedMetadata = try parseSignedMetadata(
                compactJWT,
                expectedCredentialIssuer: credentialIssuer,
                referenceDate: referenceDate,
                decoder: decoder
            )
            try signedMetadata.metadata.validatedAgainst(metadataURL: metadataURL)
            return OID4VCIMetadataFetchResult(
                metadataURL: metadataURL,
                responseContentType: mediaType.rawValue,
                metadata: signedMetadata.metadata,
                signedEnvelope: signedMetadata.envelope
            )
        }
    }

    private static func parseSignedMetadata(
        _ compactJWT: String,
        expectedCredentialIssuer: String,
        referenceDate: Date,
        decoder: JSONDecoder
    ) throws -> (metadata: OID4VCIIssuerMetadata, envelope: OID4VCISignedMetadataEnvelope) {
        let segments = compactJWT.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw OID4VCIMetadataClientError.invalidSignedMetadataJWT
        }

        let headerData = try decodeBase64URLSegment(String(segments[0]))
        let payloadData = try decodeBase64URLSegment(String(segments[1]))
        let signature = String(segments[2])

        let header = try decoder.decode(OID4VCISignedMetadataHeader.self, from: headerData)
        try validate(header: header)

        let claims = try decoder.decode(OID4VCISignedMetadataClaims.self, from: payloadData)
        try validate(claims: claims, expectedCredentialIssuer: expectedCredentialIssuer, referenceDate: referenceDate)

        let metadata = try decoder.decode(OID4VCIIssuerMetadata.self, from: payloadData)
        if metadata.credentialIssuer != claims.subject {
            throw OID4VCIMetadataClientError.signedMetadataSubjectMismatch(
                expected: claims.subject,
                actual: metadata.credentialIssuer
            )
        }

        return (
            metadata,
            OID4VCISignedMetadataEnvelope(
                compactJWT: compactJWT,
                header: header,
                claims: claims,
                signature: signature
            )
        )
    }

    private static func validate(header: OID4VCISignedMetadataHeader) throws {
        let algorithm = header.algorithm
        if algorithm == "none" || algorithm.uppercased().hasPrefix("HS") {
            throw OID4VCIMetadataClientError.invalidSignedMetadataAlgorithm(algorithm)
        }
        guard header.type == "openidvci-issuer-metadata+jwt" else {
            throw OID4VCIMetadataClientError.invalidSignedMetadataType(header.type)
        }
    }

    private static func validate(
        claims: OID4VCISignedMetadataClaims,
        expectedCredentialIssuer: String,
        referenceDate: Date
    ) throws {
        guard !claims.subject.isEmpty else {
            throw OID4VCIMetadataClientError.missingSignedMetadataSubject
        }
        guard claims.issuedAt > 0 else {
            throw OID4VCIMetadataClientError.missingSignedMetadataIssuedAt
        }
        guard claims.subject == expectedCredentialIssuer else {
            throw OID4VCIMetadataClientError.signedMetadataSubjectMismatch(
                expected: expectedCredentialIssuer,
                actual: claims.subject
            )
        }
        if let expiresAt = claims.expiresAt,
           referenceDate.timeIntervalSince1970 > TimeInterval(expiresAt) {
            throw OID4VCIMetadataClientError.expiredSignedMetadata
        }
    }

    private static func decodeBase64URLSegment(_ segment: String) throws -> Data {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        if paddingLength > 0 {
            base64 += String(repeating: "=", count: paddingLength)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw OID4VCIMetadataClientError.invalidSignedMetadataJWT
        }
        return data
    }
}
