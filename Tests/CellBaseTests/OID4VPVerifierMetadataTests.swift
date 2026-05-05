// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPVerifierMetadataTests: XCTestCase {
    func testParsesVerifierMetadataFromRequestObjectClientMetadata() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    [
                        "kty": .string("EC"),
                        "kid": .string("enc-1"),
                        "use": .string("enc"),
                        "alg": .string("ECDH-ES"),
                        "crv": .string("P-256"),
                        "x": .string("YO4epjifD-KWeq1sL2tNmm36BhXnkJ0He-WqMYrp9Fk"),
                        "y": .string("Hekpm0zfK7C-YccH5iBjcIXgf6YdUvNUac_0At55Okk")
                    ]
                ],
                encryptedResponseEncValuesSupported: [.string("A128GCM")],
                vpFormatsSupported: [
                    "dc+sd-jwt": .object([
                        "sd-jwt_alg_values": .array([.string("ES256")]),
                        "kb-jwt_alg_values": .array([.string("ES256")])
                    ])
                ]
            )
        )

        let metadata = try XCTUnwrap(requestObject.parsedVerifierMetadata())

        XCTAssertEqual(metadata.jwks?.keys.count, 1)
        XCTAssertEqual(metadata.jwks?.keys.first?.keyID, "enc-1")
        XCTAssertEqual(metadata.supportedContentEncryptionAlgorithms, ["A128GCM"])
        XCTAssertEqual(metadata.vpFormatsSupported?["dc+sd-jwt"]?.properties["sd-jwt_alg_values"], .array([.string("ES256")]))
    }

    func testRejectsVerifierMetadataWithDuplicateJWKIDs() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc")],
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc")]
                ]
            )
        )

        XCTAssertThrowsError(try requestObject.parsedVerifierMetadata()) { error in
            XCTAssertEqual(error as? OID4VPVerifierMetadataError, .duplicateJWKKeyID("enc-1"))
        }
    }

    func testBuildsDirectPostJWTPreparationWithDefaultEncryptionAlgorithm() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc"), "alg": .string("ECDH-ES")]
                ]
            )
        )
        let response = OID4VPResponse(
            vpToken: ["pid": [.string("jwt-presentation")]],
            state: "state-123"
        )

        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: response
        )

        XCTAssertEqual(preparation.responseURI.absoluteString, "https://verifier.example.org/post")
        XCTAssertEqual(preparation.selectedKey.keyID, "enc-1")
        XCTAssertEqual(preparation.selectedContentEncryptionAlgorithm, "A128GCM")
        XCTAssertEqual(preparation.suggestedKeyManagementAlgorithm, "ECDH-ES")
        XCTAssertEqual(
            String(decoding: preparation.payloadData, as: UTF8.self),
            #"{"state":"state-123","vp_token":{"pid":["jwt-presentation"]}}"#
        )
    }

    func testBuildsDirectPostJWTPreparationWithPreferredKeyAndEncryptionAlgorithm() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("sig-1"), "use": .string("sig")],
                    ["kty": .string("EC"), "kid": .string("enc-2"), "use": .string("enc"), "alg": .string("ECDH-ES")]
                ],
                encryptedResponseEncValuesSupported: [.string("A128CBC-HS256"), .string("A128GCM")]
            )
        )

        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: OID4VPResponse(code: "abc"),
            preferredKeyID: "enc-2",
            preferredContentEncryptionAlgorithm: "A128CBC-HS256"
        )

        XCTAssertEqual(preparation.selectedKey.keyID, "enc-2")
        XCTAssertEqual(preparation.selectedContentEncryptionAlgorithm, "A128CBC-HS256")
    }

    func testRejectsDirectPostJWTPreparationWithoutVerifierMetadata() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ])
        )

        XCTAssertThrowsError(
            try OID4VPDirectPostJWTPreparationBuilder.build(
                requestObject: requestObject,
                response: OID4VPResponse()
            )
        ) { error in
            XCTAssertEqual(error as? OID4VPDirectPostJWTPreparationError, .missingVerifierMetadata)
        }
    }

    func testRejectsUnsupportedPreferredContentEncryptionAlgorithm() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: makeClientMetadata(
                jwks: [
                    ["kty": .string("EC"), "kid": .string("enc-1"), "use": .string("enc")]
                ],
                encryptedResponseEncValuesSupported: [.string("A128GCM")]
            )
        )

        XCTAssertThrowsError(
            try OID4VPDirectPostJWTPreparationBuilder.build(
                requestObject: requestObject,
                response: OID4VPResponse(),
                preferredContentEncryptionAlgorithm: "A256GCM"
            )
        ) { error in
            XCTAssertEqual(
                error as? OID4VPDirectPostJWTPreparationError,
                .unsupportedContentEncryption("A256GCM")
            )
        }
    }

    private func makeClientMetadata(
        jwks: [[String: OID4VPJSONValue]]? = nil,
        encryptedResponseEncValuesSupported: [OID4VPJSONValue]? = nil,
        vpFormatsSupported: [String: OID4VPJSONValue]? = nil
    ) -> [String: OID4VPJSONValue] {
        var metadata: [String: OID4VPJSONValue] = [:]
        if let jwks {
            metadata["jwks"] = .object(["keys": .array(jwks.map(OID4VPJSONValue.object))])
        }
        if let encryptedResponseEncValuesSupported {
            metadata["encrypted_response_enc_values_supported"] = .array(encryptedResponseEncValuesSupported)
        }
        if let vpFormatsSupported {
            metadata["vp_formats_supported"] = .object(vpFormatsSupported)
        }
        return metadata
    }
}
