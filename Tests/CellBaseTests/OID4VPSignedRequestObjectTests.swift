// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPSignedRequestObjectTests: XCTestCase {
    func testParsesDecentralizedIdentifierSignedRequest() throws {
        let signedRequest = makeSignedRequest(
            header: [
                "alg": "RS256",
                "typ": "oauth-authz-req+jwt",
                "kid": "did:example:123#key-1"
            ],
            payload: [
                "iss": "decentralized_identifier:did:example:123",
                "aud": "https://self-issued.me/v2",
                "client_id": "decentralized_identifier:did:example:123",
                "response_type": "vp_token",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        let parsed = try OID4VPSignedRequestObject.parse(signedRequest)

        XCTAssertEqual(parsed.header.keyID, "did:example:123#key-1")
        XCTAssertEqual(parsed.requestObject.clientID, "decentralized_identifier:did:example:123")
        XCTAssertEqual(parsed.requestClaims.issuer, "decentralized_identifier:did:example:123")
        XCTAssertNil(parsed.verifierAttestation)
    }

    func testRejectsSignedRedirectURIRequest() throws {
        let signedRequest = makeSignedRequest(
            header: [
                "alg": "RS256",
                "typ": "oauth-authz-req+jwt"
            ],
            payload: [
                "client_id": "redirect_uri:https://verifier.example.org/callback",
                "response_type": "vp_token",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        XCTAssertThrowsError(try OID4VPSignedRequestObject.parse(signedRequest)) { error in
            XCTAssertEqual(
                error as? OID4VPSignedRequestObjectError,
                .signedRequestNotAllowed(prefix: "redirect_uri")
            )
        }
    }

    func testParsesVerifierAttestationSignedRequest() throws {
        let attestationJWT = makeSignedRequest(
            header: [
                "alg": "ES256",
                "typ": "verifier-attestation+jwt"
            ],
            payload: [
                "iss": "https://trust.example.org",
                "sub": "verifier.example.org",
                "exp": 4_102_444_800,
                "cnf": [
                    "jwk": [
                        "kty": "EC",
                        "kid": "attested-key",
                        "crv": "P-256",
                        "x": "f83OJ3D2xF4P8PfeFEXAMPLE1",
                        "y": "x_FEzRu9V6j4nH4lAEXAMPLE2"
                    ]
                ]
            ],
            signatureData: Data([0x99, 0x01])
        )

        let signedRequest = makeSignedRequest(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "jwt": attestationJWT
            ],
            payload: [
                "client_id": "verifier_attestation:verifier.example.org",
                "response_type": "vp_token",
                "redirect_uri": "https://verifier.example.org/callback",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        let parsed = try OID4VPSignedRequestObject.parse(
            signedRequest,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(parsed.requestObject.clientID, "verifier_attestation:verifier.example.org")
        XCTAssertEqual(parsed.verifierAttestation?.claims.subject, "verifier.example.org")
        XCTAssertEqual(parsed.verifierAttestation?.claims.issuer, "https://trust.example.org")
        XCTAssertEqual(parsed.verifierAttestation?.claims.confirmation.jwk.keyID, "attested-key")
    }

    func testRejectsVerifierAttestationRequestWithoutJWTHeader() throws {
        let signedRequest = makeSignedRequest(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt"
            ],
            payload: [
                "client_id": "verifier_attestation:verifier.example.org",
                "response_type": "vp_token",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        XCTAssertThrowsError(try OID4VPSignedRequestObject.parse(signedRequest)) { error in
            XCTAssertEqual(
                error as? OID4VPSignedRequestObjectError,
                .missingVerifierAttestationJWT
            )
        }
    }

    func testRejectsX509HashRequestWithoutCertificateChain() throws {
        let signedRequest = makeSignedRequest(
            header: [
                "alg": "RS256",
                "typ": "oauth-authz-req+jwt"
            ],
            payload: [
                "client_id": "x509_hash:Uvo3HtuIxuhC92rShpgqcT3YXwrqRxWEviRiA0OZszk",
                "response_type": "vp_token",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        XCTAssertThrowsError(try OID4VPSignedRequestObject.parse(signedRequest)) { error in
            XCTAssertEqual(
                error as? OID4VPSignedRequestObjectError,
                .missingCertificateChain(prefix: "x509_hash")
            )
        }
    }

    func testRejectsInsecureSigningAlgorithm() throws {
        let signedRequest = makeSignedRequest(
            header: [
                "alg": "HS256",
                "typ": "oauth-authz-req+jwt"
            ],
            payload: [
                "client_id": "decentralized_identifier:did:example:123",
                "response_type": "vp_token",
                "dcql_query": [
                    "credentials": [
                        [
                            "id": "pid",
                            "format": "dc+sd-jwt",
                            "meta": [
                                "vct_values": ["https://example.com/pid"]
                            ]
                        ]
                    ]
                ],
                "client_metadata": [
                    "vp_formats_supported": [
                        "dc+sd-jwt": [
                            "sd-jwt_alg_values": ["ES256"]
                        ]
                    ]
                ]
            ]
        )

        XCTAssertThrowsError(try OID4VPSignedRequestObject.parse(signedRequest)) { error in
            XCTAssertEqual(
                error as? OID4VPSignedRequestObjectError,
                .insecureSigningAlgorithm("HS256")
            )
        }
    }

    private func makeSignedRequest(
        header: [String: Any],
        payload: [String: Any],
        signatureData: Data = Data([0x01, 0x02, 0x03])
    ) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [
            JOSEBase64URL.encode(headerData),
            JOSEBase64URL.encode(payloadData),
            JOSEBase64URL.encode(signatureData)
        ].joined(separator: ".")
    }
}
