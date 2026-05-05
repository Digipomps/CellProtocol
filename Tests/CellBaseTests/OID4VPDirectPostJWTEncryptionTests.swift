// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@testable import CellBase

final class OID4VPDirectPostJWTEncryptionTests: XCTestCase {
    func testEncryptsDirectPostJWTResponseAndRecipientCanDecryptIt() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(recipientPrivateKey: recipientPrivateKey)
        let response = OID4VPResponse(
            vpToken: ["pid": [.string("jwt-presentation")]],
            state: "state-123",
            issuer: "https://wallet.example.org"
        )
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: response
        )

        let jwe = try OID4VPDirectPostJWTEncryptor.encrypt(preparation: preparation)
        let protectedHeader: Data = try XCTUnwrap(jwe.protectedHeaderData)
        let protectedHeaderObject = try JSONSerialization.jsonObject(with: protectedHeader) as? [String: Any]

        XCTAssertEqual(protectedHeaderObject?["alg"] as? String, "ECDH-ES")
        XCTAssertEqual(protectedHeaderObject?["enc"] as? String, "A128GCM")
        XCTAssertEqual(protectedHeaderObject?["kid"] as? String, "enc-1")
        XCTAssertNotNil(protectedHeaderObject?["epk"] as? [String: Any])

        let plaintext = try decrypt(
            jwe: jwe,
            recipientPrivateKey: recipientPrivateKey
        )

        let plaintextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: AnyHashable])
        XCTAssertEqual(plaintextObject["iss"] as? String, "https://wallet.example.org")
        XCTAssertEqual(plaintextObject["state"] as? String, "state-123")
        let vpToken = try XCTUnwrap(plaintextObject["vp_token"] as? [String: [String]])
        XCTAssertEqual(vpToken["pid"], ["jwt-presentation"])
    }

    func testBuildsDirectPostJWTSubmissionWithCompactResponseParameter() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(recipientPrivateKey: recipientPrivateKey)
        let response = OID4VPResponse(code: "auth-code-123")
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: response
        )

        let submission = try OID4VPDirectPostJWTEncryptor.buildSubmission(preparation: preparation)

        XCTAssertEqual(submission.responseMode, .directPostJwt)
        let compactJWE = try JOSECompactJWE(compactSerialization: try XCTUnwrap(submission.formParameters["response"]))
        XCTAssertEqual(compactJWE.encryptedKeySegment, "")
    }

    func testEncryptsWrappedDirectPostJWTResponseAndRecipientCanDecryptIt() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(
            recipientPrivateKey: recipientPrivateKey,
            keyManagementAlgorithm: "ECDH-ES+A256KW",
            encryptedResponseEncValuesSupported: ["A192GCM"]
        )
        let response = OID4VPResponse(state: "state-123", code: "auth-code-123")
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: response
        )

        let jwe = try OID4VPDirectPostJWTEncryptor.encrypt(preparation: preparation)
        let protectedHeader: Data = try XCTUnwrap(jwe.protectedHeaderData)
        let protectedHeaderObject = try XCTUnwrap(JSONSerialization.jsonObject(with: protectedHeader) as? [String: Any])

        XCTAssertEqual(protectedHeaderObject["alg"] as? String, "ECDH-ES+A256KW")
        XCTAssertEqual(protectedHeaderObject["enc"] as? String, "A192GCM")
        XCTAssertFalse(jwe.encryptedKeySegment.isEmpty)

        let plaintext = try decrypt(
            jwe: jwe,
            recipientPrivateKey: recipientPrivateKey
        )
        let plaintextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: AnyHashable])
        XCTAssertEqual(plaintextObject["code"] as? String, "auth-code-123")
        XCTAssertEqual(plaintextObject["state"] as? String, "state-123")
    }

    func testRejectsUnsupportedContentEncryptionAlgorithmDuringJWEConstruction() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(
            recipientPrivateKey: recipientPrivateKey,
            encryptedResponseEncValuesSupported: ["A128CBC-HS256"]
        )
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: OID4VPResponse()
        )

        XCTAssertThrowsError(try OID4VPDirectPostJWTEncryptor.encrypt(preparation: preparation)) { error in
            XCTAssertEqual(
                error as? OID4VPDirectPostJWTEncryptionError,
                .unsupportedContentEncryption("A128CBC-HS256")
            )
        }
    }

    private func makeRequestObject(
        recipientPrivateKey: P256.KeyAgreement.PrivateKey,
        keyManagementAlgorithm: String = "ECDH-ES",
        encryptedResponseEncValuesSupported: [String] = ["A128GCM"]
    ) -> OID4VPRequestObject {
        let publicKey = recipientPrivateKey.publicKey.x963Representation
        let x = JOSEBase64URL.encode(publicKey.subdata(in: 1..<33))
        let y = JOSEBase64URL.encode(publicKey.subdata(in: 33..<65))

        return OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            clientMetadata: [
                "jwks": .object([
                    "keys": .array([
                        .object([
                            "kty": .string("EC"),
                            "kid": .string("enc-1"),
                            "use": .string("enc"),
                            "alg": .string(keyManagementAlgorithm),
                            "crv": .string("P-256"),
                            "x": .string(x),
                            "y": .string(y)
                        ])
                    ])
                ]),
                "encrypted_response_enc_values_supported": .array(
                    encryptedResponseEncValuesSupported.map(OID4VPJSONValue.string)
                )
            ]
        )
    }

    private func decrypt(
        jwe: JOSECompactJWE,
        recipientPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let headerData: Data = try XCTUnwrap(jwe.protectedHeaderData)
        let headerObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        )
        let algorithm = try XCTUnwrap(headerObject["alg"] as? String)
        let contentEncryptionAlgorithm = try XCTUnwrap(headerObject["enc"] as? String)
        let epk = try XCTUnwrap(headerObject["epk"] as? [String: Any])
        let x = try XCTUnwrap(epk["x"] as? String)
        let y = try XCTUnwrap(epk["y"] as? String)

        let epkData = Data([0x04]) + (try JOSEBase64URL.decode(x)) + (try JOSEBase64URL.decode(y))
        let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: epkData)
        let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let contentEncryptionKeyData: Data
        if algorithm == "ECDH-ES" {
            contentEncryptionKeyData = concatKDF(
                sharedSecret: sharedSecretData,
                algorithmIdentifier: contentEncryptionAlgorithm,
                keyLengthBits: keyLengthBits(for: contentEncryptionAlgorithm)
            )
        } else {
            let keyEncryptionKey = concatKDF(
                sharedSecret: sharedSecretData,
                algorithmIdentifier: algorithm,
                keyLengthBits: keyLengthBits(for: algorithm)
            )
            let wrappedKey = try JOSEBase64URL.decode(jwe.encryptedKeySegment)
            contentEncryptionKeyData = try JOSEAESKeyWrap.unwrap(wrappedKey: wrappedKey, using: keyEncryptionKey)
        }
        let contentEncryptionKey = SymmetricKey(data: contentEncryptionKeyData)

        switch contentEncryptionAlgorithm {
        case "A128GCM", "A192GCM", "A256GCM":
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: jwe.initializationVector),
                ciphertext: jwe.ciphertext,
                tag: jwe.authenticationTag
            )

            return try AES.GCM.open(
                sealedBox,
                using: contentEncryptionKey,
                authenticating: Data(jwe.protectedHeaderSegment.utf8)
            )
        default:
            XCTFail("Unsupported content encryption algorithm in test: \(contentEncryptionAlgorithm)")
            return Data()
        }
    }

    private func concatKDF(
        sharedSecret: Data,
        algorithmIdentifier: String,
        keyLengthBits: Int
    ) -> Data {
        let otherInfo =
            lengthPrefixed(Data(algorithmIdentifier.utf8)) +
            lengthPrefixed(Data()) +
            lengthPrefixed(Data()) +
            UInt32(keyLengthBits).bigEndianData +
            UInt32(0).bigEndianData

        let roundData = UInt32(1).bigEndianData + sharedSecret + otherInfo
        let digest = SHA256.hash(data: roundData)
        return Data(Data(digest).prefix(keyLengthBits / 8))
    }

    private func lengthPrefixed(_ data: Data) -> Data {
        UInt32(data.count).bigEndianData + data
    }

    private func keyLengthBits(for algorithmIdentifier: String) -> Int {
        switch algorithmIdentifier {
        case "A128GCM", "ECDH-ES+A128KW":
            return 128
        case "A192GCM", "ECDH-ES+A192KW":
            return 192
        case "A256GCM", "ECDH-ES+A256KW":
            return 256
        default:
            return 128
        }
    }
}

private extension UInt32 {
    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}
