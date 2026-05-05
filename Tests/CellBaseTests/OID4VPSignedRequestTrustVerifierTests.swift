// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@testable import CellBase

final class OID4VPSignedRequestTrustVerifierTests: XCTestCase {
    func testVerifiesDecentralizedIdentifierSignedRequestAgainstDIDDocument() async throws {
        let signingKey = P256.Signing.PrivateKey()
        let multibase = try XCTUnwrap(try makeP256Multibase(for: signingKey.publicKey))
        let did = "did:key:\(multibase)"
        let keyID = "\(did)#\(multibase)"
        let didDocument = try XCTUnwrap(
            try JSONDecoder().decode(
                DIDDocument.self,
                from: Data(try DIDKeyParser.createDIDDocument(from: did).utf8)
            )
        )

        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "kid": keyID
            ],
            payload: [
                "iss": "decentralized_identifier:\(did)",
                "client_id": "decentralized_identifier:\(did)",
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
            ],
            signer: { signingInput in
                try signingKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider(
            didDocumentsByIdentifier: [did: didDocument]
        )

        let result = try await OID4VPSignedRequestTrustVerifier.verify(
            signedRequest,
            provider: provider
        )

        XCTAssertEqual(
            result.source,
            .decentralizedIdentifier(did: did, keyID: keyID)
        )
        XCTAssertTrue(result.requestSignatureVerified)
        XCTAssertFalse(result.verifierAttestationSignatureVerified)
    }

    func testRejectsDecentralizedIdentifierRequestWhenDIDDocumentIsMissing() async throws {
        let signingKey = P256.Signing.PrivateKey()
        let multibase = try XCTUnwrap(try makeP256Multibase(for: signingKey.publicKey))
        let did = "did:key:\(multibase)"
        let keyID = "\(did)#\(multibase)"

        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "kid": keyID
            ],
            payload: [
                "client_id": "decentralized_identifier:\(did)",
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
            ],
            signer: { signingInput in
                try signingKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider()

        do {
            _ = try await OID4VPSignedRequestTrustVerifier.verify(
                signedRequest,
                provider: provider
            )
            XCTFail("Expected missing DID document to fail trust verification")
        } catch {
            XCTAssertEqual(
                error as? OID4VPSignedRequestTrustVerificationError,
                .missingDIDDocument(did)
            )
        }
    }

    func testVerifiesVerifierAttestationAndRequestSignature() async throws {
        let attestationIssuerKey = P256.Signing.PrivateKey()
        let verifierKey = P256.Signing.PrivateKey()
        let verifierJWK = makeP256JWK(
            publicKey: verifierKey.publicKey,
            keyID: "verifier-key-1"
        )
        let attestationIssuerJWK = makeP256JWK(
            publicKey: attestationIssuerKey.publicKey,
            keyID: "issuer-key-1"
        )

        let attestationJWT = try makeCompactJWS(
            header: [
                "alg": "ES256",
                "typ": "verifier-attestation+jwt",
                "kid": "issuer-key-1"
            ],
            payload: [
                "iss": "https://trust.example.org",
                "sub": "verifier.example.org",
                "exp": 4_102_444_800,
                "cnf": [
                    "jwk": [
                        "kty": verifierJWK.keyType,
                        "kid": verifierJWK.keyID!,
                        "crv": verifierJWK.curve!,
                        "x": verifierJWK.x!,
                        "y": verifierJWK.y!
                    ]
                ],
                "redirect_uris": ["https://verifier.example.org/callback"]
            ],
            signer: { signingInput in
                try attestationIssuerKey.signature(for: signingInput).rawRepresentation
            }
        )

        let signedRequest = try makeSignedRequestObject(
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
            ],
            signer: { signingInput in
                try verifierKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider(
            verifierAttestationIssuerKeys: [
                "https://trust.example.org": JOSEJWKSet(keys: [attestationIssuerJWK])
            ]
        )

        let result = try await OID4VPSignedRequestTrustVerifier.verify(
            signedRequest,
            provider: provider
        )

        XCTAssertEqual(
            result.source,
            .verifierAttestation(
                issuer: "https://trust.example.org",
                subject: "verifier.example.org"
            )
        )
        XCTAssertTrue(result.requestSignatureVerified)
        XCTAssertTrue(result.verifierAttestationSignatureVerified)
    }

    func testRejectsVerifierAttestationWhenIssuerIsNotTrusted() async throws {
        let attestationIssuerKey = P256.Signing.PrivateKey()
        let verifierKey = P256.Signing.PrivateKey()
        let verifierJWK = makeP256JWK(
            publicKey: verifierKey.publicKey,
            keyID: "verifier-key-1"
        )

        let attestationJWT = try makeCompactJWS(
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
                        "kty": verifierJWK.keyType,
                        "kid": verifierJWK.keyID!,
                        "crv": verifierJWK.curve!,
                        "x": verifierJWK.x!,
                        "y": verifierJWK.y!
                    ]
                ]
            ],
            signer: { signingInput in
                try attestationIssuerKey.signature(for: signingInput).rawRepresentation
            }
        )

        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "jwt": attestationJWT
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
            ],
            signer: { signingInput in
                try verifierKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider()

        do {
            _ = try await OID4VPSignedRequestTrustVerifier.verify(
                signedRequest,
                provider: provider
            )
            XCTFail("Expected missing trusted attestation issuer to fail")
        } catch {
            XCTAssertEqual(
                error as? OID4VPSignedRequestTrustVerificationError,
                .missingTrustedAttestationIssuer("https://trust.example.org")
            )
        }
    }

    #if canImport(Security)
    func testVerifiesX509HashSignedRequest() async throws {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: Self.testCertificatePrivateKeyPEM)
        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "x5c": [Self.testCertificateDERBase64]
            ],
            payload: [
                "client_id": "x509_hash:\(Self.testCertificateSHA256Thumbprint)",
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
                ]
            ],
            signer: { signingInput in
                try privateKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider(
            x509TrustAnchorsByClientID: [
                "x509_hash:\(Self.testCertificateSHA256Thumbprint)": [Self.testCertificateDERData]
            ]
        )

        let result = try await OID4VPSignedRequestTrustVerifier.verify(
            signedRequest,
            provider: provider
        )

        XCTAssertEqual(
            result.source,
            .x509Hash(hash: Self.testCertificateSHA256Thumbprint)
        )
        XCTAssertTrue(result.requestSignatureVerified)
    }

    func testVerifiesX509SanDNSSignedRequest() async throws {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: Self.testCertificatePrivateKeyPEM)
        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "x5c": [Self.testCertificateDERBase64]
            ],
            payload: [
                "client_id": "x509_san_dns:client.example.org",
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
                ]
            ],
            signer: { signingInput in
                try privateKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider(
            x509TrustAnchorsByClientID: [
                "x509_san_dns:client.example.org": [Self.testCertificateDERData]
            ]
        )

        let result = try await OID4VPSignedRequestTrustVerifier.verify(
            signedRequest,
            provider: provider
        )

        XCTAssertEqual(result.source, .x509SanDNS(dnsName: "client.example.org"))
        XCTAssertTrue(result.requestSignatureVerified)
    }

    func testRejectsX509HashWhenLeafCertificateHashDoesNotMatch() async throws {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: Self.testCertificatePrivateKeyPEM)
        let signedRequest = try makeSignedRequestObject(
            header: [
                "alg": "ES256",
                "typ": "oauth-authz-req+jwt",
                "x5c": [Self.testCertificateDERBase64]
            ],
            payload: [
                "client_id": "x509_hash:not-the-real-hash",
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
                ]
            ],
            signer: { signingInput in
                try privateKey.signature(for: signingInput).rawRepresentation
            }
        )

        let provider = OID4VPStaticSignedRequestTrustMaterialProvider(
            x509TrustAnchorsByClientID: [
                "x509_hash:not-the-real-hash": [Self.testCertificateDERData]
            ]
        )

        do {
            _ = try await OID4VPSignedRequestTrustVerifier.verify(
                signedRequest,
                provider: provider
            )
            XCTFail("Expected x509 hash mismatch to fail")
        } catch {
            XCTAssertEqual(
                error as? OID4VPSignedRequestTrustVerificationError,
                .x509LeafCertificateHashMismatch(
                    expected: "not-the-real-hash",
                    actual: Self.testCertificateSHA256Thumbprint
                )
            )
        }
    }
    #endif

    private func makeP256Multibase(for publicKey: P256.Signing.PublicKey) throws -> String? {
        guard let compactRepresentation = publicKey.compactRepresentation else {
            return nil
        }
        return try DIDKeyParser.multibaseEncodedPublicKey(compactRepresentation, curveType: .P256)
    }

    private func makeP256JWK(
        publicKey: P256.Signing.PublicKey,
        keyID: String
    ) -> JOSEJWK {
        let x963Representation = publicKey.x963Representation
        let x = JOSEBase64URL.encode(x963Representation.subdata(in: 1..<33))
        let y = JOSEBase64URL.encode(x963Representation.subdata(in: 33..<65))
        return JOSEJWK(
            keyType: "EC",
            keyID: keyID,
            algorithm: "ES256",
            curve: "P-256",
            x: x,
            y: y
        )
    }

    private func makeSignedRequestObject(
        header: [String: Any],
        payload: [String: Any],
        signer: (Data) throws -> Data
    ) throws -> OID4VPSignedRequestObject {
        let compactSerialization = try makeCompactJWS(
            header: header,
            payload: payload,
            signer: signer
        )
        return try OID4VPSignedRequestObject.parse(
            compactSerialization,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeCompactJWS(
        header: [String: Any],
        payload: [String: Any],
        signer: (Data) throws -> Data
    ) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let protectedSegment = JOSEBase64URL.encode(headerData)
        let payloadSegment = JOSEBase64URL.encode(payloadData)
        let signingInput = Data("\(protectedSegment).\(payloadSegment)".utf8)
        let signature = try signer(signingInput)
        return [protectedSegment, payloadSegment, JOSEBase64URL.encode(signature)].joined(separator: ".")
    }

    #if canImport(Security)
    private static let testCertificateDERBase64 =
        "MIIBnzCCAUSgAwIBAgIULCrinYGpYa0iVRmtTX4+qqQP74QwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSY2xpZW50LmV4YW1wbGUub3JnMB4XDTI2MDMyNTA1NDA0MloXDTM2MDMyMjA1NDA0MlowHTEbMBkGA1UEAwwSY2xpZW50LmV4YW1wbGUub3JnMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtFjWSfyDbJhylq7+rdI8hNYxXCfnDfLVx0kYG1ZZzWS3cMZiW1WHGRPvaUhj9KxQq4u7wrU+hJjKPhGVmlGZq6NiMGAwHQYDVR0RBBYwFIISY2xpZW50LmV4YW1wbGUub3JnMAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUrPA4g/VM8R9+7g+QFnul51tGCJIwCgYIKoZIzj0EAwIDSQAwRgIhAOkYyc2jSkBd5xGQ1ohkqrPfbL8+swg1VMZ0Fj2gdxmyAiEAru/z0txiEg7E/cK6cyNtRk3WRv+AuO+52m5NQ+iP0iY="
    private static let testCertificateDERData = Data(base64Encoded: testCertificateDERBase64)!
    private static let testCertificateSHA256Thumbprint = "FJGLmSeKv0XkvF0ltl-tiMMUnfX4x7q2ctDUXpRLZGw"
    private static let testCertificatePrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgQ1ZcgTiap8W/NfVA
    gyP1RrKh6NzDwX3Z1ygcOvxYqFehRANCAAS0WNZJ/INsmHKWrv6t0jyE1jFcJ+cN
    8tXHSRgbVlnNZLdwxmJbVYcZE+9pSGP0rFCri7vCtT6EmMo+EZWaUZmr
    -----END PRIVATE KEY-----
    """
    #endif
}
