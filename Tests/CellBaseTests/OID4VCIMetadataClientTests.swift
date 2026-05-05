// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VCIMetadataClientTests: XCTestCase {
    func testFetchesUnsignedMetadataFromWellKnownEndpoint() async throws {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        let transport = MockOID4VCIHTTPTransport(
            response: OID4VCIHTTPResponse(
                url: metadataURL,
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: Data(
                    """
                    {
                      "credential_issuer": "https://issuer.example.com",
                      "credential_endpoint": "https://issuer.example.com/credential",
                      "credential_configurations_supported": {
                        "UniversityDegreeCredential": {
                          "format": "jwt_vc_json"
                        }
                      }
                    }
                    """.utf8
                )
            )
        )

        let result = try await OID4VCIMetadataClient.fetch(
            credentialIssuer: "https://issuer.example.com",
            transport: transport,
            preferredLanguages: ["en-US", "nb-NO"]
        )

        XCTAssertEqual(result.metadataURL, metadataURL)
        XCTAssertEqual(result.responseContentType, "application/json")
        XCTAssertEqual(result.metadata.credentialIssuer, "https://issuer.example.com")
        XCTAssertNil(result.signedEnvelope)

        let request = await transport.lastRequest
        XCTAssertNotNil(request)
        guard let request else { return }
        XCTAssertEqual(request.url, metadataURL)
        XCTAssertEqual(request.acceptContentTypes, ["application/json"])
        XCTAssertEqual(request.preferredLanguages ?? [], ["en-US", "nb-NO"])
    }

    func testFetchesAndParsesSignedMetadataJWT() async throws {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        let jwt = makeSignedMetadataJWT(
            header: [
                "alg": "ES256",
                "typ": "openidvci-issuer-metadata+jwt",
                "kid": "metadata-key-1"
            ],
            payload: [
                "sub": "https://issuer.example.com",
                "iat": 1_700_000_000,
                "exp": 4_100_000_000,
                "credential_issuer": "https://issuer.example.com",
                "credential_endpoint": "https://issuer.example.com/credential",
                "credential_configurations_supported": [
                    "UniversityDegreeCredential": [
                        "format": "jwt_vc_json"
                    ]
                ]
            ]
        )

        let transport = MockOID4VCIHTTPTransport(
            response: OID4VCIHTTPResponse(
                url: metadataURL,
                statusCode: 200,
                headers: ["Content-Type": "application/jwt"],
                body: Data(jwt.utf8)
            )
        )

        let result = try await OID4VCIMetadataClient.fetch(
            credentialIssuer: "https://issuer.example.com",
            transport: transport,
            preferSignedMetadata: true,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.responseContentType, "application/jwt")
        XCTAssertEqual(result.metadata.credentialIssuer, "https://issuer.example.com")
        XCTAssertEqual(result.signedEnvelope?.header.algorithm, "ES256")
        XCTAssertEqual(result.signedEnvelope?.header.type, "openidvci-issuer-metadata+jwt")
        XCTAssertEqual(result.signedEnvelope?.claims.subject, "https://issuer.example.com")

        let request = await transport.lastRequest
        XCTAssertNotNil(request)
        guard let request else { return }
        XCTAssertEqual(request.acceptContentTypes, ["application/jwt", "application/json"])
    }

    func testRejectsSignedMetadataWithInvalidType() async throws {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        let jwt = makeSignedMetadataJWT(
            header: [
                "alg": "ES256",
                "typ": "JWT"
            ],
            payload: [
                "sub": "https://issuer.example.com",
                "iat": 1_700_000_000,
                "credential_issuer": "https://issuer.example.com",
                "credential_endpoint": "https://issuer.example.com/credential",
                "credential_configurations_supported": [:]
            ]
        )

        let transport = MockOID4VCIHTTPTransport(
            response: OID4VCIHTTPResponse(
                url: metadataURL,
                statusCode: 200,
                headers: ["Content-Type": "application/jwt"],
                body: Data(jwt.utf8)
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await OID4VCIMetadataClient.fetch(
                credentialIssuer: "https://issuer.example.com",
                transport: transport,
                preferSignedMetadata: true
            )
        ) { error in
            XCTAssertEqual(error as? OID4VCIMetadataClientError, .invalidSignedMetadataType("JWT"))
        }
    }

    func testRejectsSignedMetadataWithSubjectMismatch() async throws {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        let jwt = makeSignedMetadataJWT(
            header: [
                "alg": "ES256",
                "typ": "openidvci-issuer-metadata+jwt"
            ],
            payload: [
                "sub": "https://other-issuer.example.com",
                "iat": 1_700_000_000,
                "credential_issuer": "https://other-issuer.example.com",
                "credential_endpoint": "https://other-issuer.example.com/credential",
                "credential_configurations_supported": [:]
            ]
        )

        let transport = MockOID4VCIHTTPTransport(
            response: OID4VCIHTTPResponse(
                url: metadataURL,
                statusCode: 200,
                headers: ["Content-Type": "application/jwt"],
                body: Data(jwt.utf8)
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await OID4VCIMetadataClient.fetch(
                credentialIssuer: "https://issuer.example.com",
                transport: transport,
                preferSignedMetadata: true
            )
        ) { error in
            XCTAssertEqual(
                error as? OID4VCIMetadataClientError,
                .signedMetadataSubjectMismatch(
                    expected: "https://issuer.example.com",
                    actual: "https://other-issuer.example.com"
                )
            )
        }
    }

    func testRejectsUnexpectedStatusCode() async throws {
        let metadataURL = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        let transport = MockOID4VCIHTTPTransport(
            response: OID4VCIHTTPResponse(
                url: metadataURL,
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await OID4VCIMetadataClient.fetch(
                credentialIssuer: "https://issuer.example.com",
                transport: transport
            )
        ) { error in
            XCTAssertEqual(error as? OID4VCIMetadataClientError, .unexpectedStatusCode(503))
        }
    }
}

private actor MockOID4VCIHTTPTransport: OID4VCIHTTPTransport {
    struct RecordedRequest: Equatable, Sendable {
        var url: URL
        var acceptContentTypes: [String]
        var preferredLanguages: [String]?
    }

    let response: OID4VCIHTTPResponse
    private(set) var lastRequest: RecordedRequest?

    init(response: OID4VCIHTTPResponse) {
        self.response = response
    }

    func get(
        url: URL,
        acceptContentTypes: [String],
        preferredLanguages: [String]?
    ) async throws -> OID4VCIHTTPResponse {
        lastRequest = RecordedRequest(
            url: url,
            acceptContentTypes: acceptContentTypes,
            preferredLanguages: preferredLanguages
        )
        return response
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}

private func makeSignedMetadataJWT(
    header: [String: Any],
    payload: [String: Any]
) -> String {
    let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return [
        base64URLEncode(headerData),
        base64URLEncode(payloadData),
        "signature"
    ].joined(separator: ".")
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
