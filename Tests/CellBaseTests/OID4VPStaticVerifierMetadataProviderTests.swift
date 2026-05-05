// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPStaticVerifierMetadataProviderTests: XCTestCase {
    func testStaticProviderReturnsMetadataForExactClientID() async throws {
        let provider = OID4VPStaticVerifierMetadataProvider(records: [
            OID4VPStaticVerifierMetadataRecord(
                clientIDs: ["verifier.example.org"],
                metadata: OID4VPVerifierMetadata(
                    jwks: JOSEJWKSet(keys: [
                        JOSEJWK(keyType: "EC", keyID: "enc-1", publicKeyUse: "enc")
                    ]),
                    encryptedResponseEncValuesSupported: ["A256GCM"]
                )
            )
        ])

        let requestObject = OID4VPRequestObject(
            clientID: "verifier.example.org",
            responseType: OID4VPResponseType("vp_token")
        )

        let resolvedMetadata = try await provider.metadata(for: requestObject)

        XCTAssertEqual(resolvedMetadata?.source, .preRegistered)
        XCTAssertEqual(resolvedMetadata?.clientIdentifierPrefix, .preRegistered)
        XCTAssertEqual(resolvedMetadata?.metadata.jwks?.keys.first?.keyID, "enc-1")
        XCTAssertEqual(resolvedMetadata?.metadata.supportedContentEncryptionAlgorithms, ["A256GCM"])
    }

    func testStaticProviderSupportsMultipleAliasesForSameVerifier() async throws {
        let provider = OID4VPStaticVerifierMetadataProvider(records: [
            OID4VPStaticVerifierMetadataRecord(
                clientIDs: [
                    "verifier.example.org",
                    "redirect_uri:https://verifier.example.org/callback"
                ],
                metadata: OID4VPVerifierMetadata(
                    jwks: JOSEJWKSet(keys: [
                        JOSEJWK(keyType: "EC", keyID: "enc-2", publicKeyUse: "enc")
                    ])
                ),
                source: .outOfBand("static-registry")
            )
        ])

        let requestObject = OID4VPRequestObject(
            clientID: "redirect_uri:https://verifier.example.org/callback",
            responseType: OID4VPResponseType("vp_token")
        )

        let resolvedMetadata = try await provider.metadata(for: requestObject)

        XCTAssertEqual(resolvedMetadata?.source, .outOfBand("static-registry"))
        XCTAssertEqual(resolvedMetadata?.clientIdentifierPrefix, .redirectURI)
        XCTAssertEqual(resolvedMetadata?.metadata.jwks?.keys.first?.keyID, "enc-2")
    }

    func testCompositeProviderFallsBackToSecondProvider() async throws {
        let emptyProvider = OID4VPStaticVerifierMetadataProvider(records: [])
        let staticProvider = OID4VPStaticVerifierMetadataProvider(records: [
            OID4VPStaticVerifierMetadataRecord(
                clientIDs: ["openid_federation:https://verifier.example.org"],
                metadata: OID4VPVerifierMetadata(
                    jwks: JOSEJWKSet(keys: [
                        JOSEJWK(keyType: "EC", keyID: "federated-enc", publicKeyUse: "enc")
                    ])
                ),
                source: .openidFederation
            )
        ])
        let provider = OID4VPCompositeVerifierMetadataProvider(
            providers: [emptyProvider, staticProvider]
        )
        let requestObject = OID4VPRequestObject(
            clientID: "openid_federation:https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token")
        )

        let resolvedMetadata = try await provider.metadata(for: requestObject)

        XCTAssertEqual(resolvedMetadata?.source, .openidFederation)
        XCTAssertEqual(resolvedMetadata?.clientIdentifierPrefix, .openidFederation)
        XCTAssertEqual(resolvedMetadata?.metadata.jwks?.keys.first?.keyID, "federated-enc")
    }
}
