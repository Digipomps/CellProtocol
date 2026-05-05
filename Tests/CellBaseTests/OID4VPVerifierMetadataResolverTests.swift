// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPVerifierMetadataResolverTests: XCTestCase {
    func testResolvesRedirectURIVerifierMetadataFromRequestClientMetadata() async throws {
        let requestObject = OID4VPRequestObject(
            clientID: "redirect_uri:https://verifier.example.org/callback",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc")]
                ]
            )
        )

        let resolvedMetadata = try await OID4VPVerifierMetadataResolver.resolve(requestObject: requestObject)

        XCTAssertEqual(resolvedMetadata.source, .requestClientMetadata)
        XCTAssertEqual(resolvedMetadata.clientIdentifierPrefix, .redirectURI)
        XCTAssertEqual(resolvedMetadata.metadata.jwks?.keys.first?.keyID, "enc-1")
    }

    func testRejectsRequestClientMetadataForPreRegisteredClient() async throws {
        let requestObject = OID4VPRequestObject(
            clientID: "verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc")]
                ]
            )
        )

        do {
            _ = try await OID4VPVerifierMetadataResolver.resolve(
                requestObject: requestObject,
                provider: MockVerifierMetadataProvider(metadata: nil)
            )
            XCTFail("Expected metadata resolution to fail for pre-registered client metadata")
        } catch {
            XCTAssertEqual(
                error as? OID4VPVerifierMetadataResolutionError,
                .clientMetadataNotAllowedForPreRegisteredClient
            )
        }
    }

    func testResolvesOpenIDFederationVerifierMetadataFromProviderAndIgnoresEmbeddedMetadata() async throws {
        let requestObject = OID4VPRequestObject(
            clientID: "openid_federation:https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("ignored-embedded"), "use": .string("enc")]
                ]
            )
        )

        let provider = MockVerifierMetadataProvider(
            metadata: OID4VPResolvedVerifierMetadata(
                metadata: OID4VPVerifierMetadata(
                    jwks: JOSEJWKSet(keys: [
                        JOSEJWK(keyType: "EC", keyID: "federated-enc", publicKeyUse: "enc")
                    ]),
                    encryptedResponseEncValuesSupported: ["A256GCM"]
                ),
                source: .openidFederation,
                clientIdentifierPrefix: .openidFederation
            )
        )

        let resolvedMetadata = try await OID4VPVerifierMetadataResolver.resolve(
            requestObject: requestObject,
            provider: provider
        )

        XCTAssertEqual(resolvedMetadata.source, .openidFederation)
        XCTAssertEqual(resolvedMetadata.clientIdentifierPrefix, .openidFederation)
        XCTAssertEqual(resolvedMetadata.metadata.jwks?.keys.first?.keyID, "federated-enc")
        XCTAssertEqual(resolvedMetadata.metadata.supportedContentEncryptionAlgorithms, ["A256GCM"])
    }

    private func makeClientMetadata(
        jwks: [[String: OID4VPJSONValue]]? = nil
    ) -> [String: OID4VPJSONValue] {
        var metadata: [String: OID4VPJSONValue] = [:]
        if let jwks {
            metadata["jwks"] = .object(["keys": .array(jwks.map(OID4VPJSONValue.object))])
        }
        return metadata
    }
}

private struct MockVerifierMetadataProvider: OID4VPVerifierMetadataProvider {
    let metadata: OID4VPResolvedVerifierMetadata?

    func metadata(for requestObject: OID4VPRequestObject) async throws -> OID4VPResolvedVerifierMetadata? {
        metadata
    }
}
