// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@testable import CellBase

final class OID4VPDirectPostJWTSubmissionAdapterTests: XCTestCase {
    func testBuildsDirectPostJWTSubmissionPlanFromRequestAndCandidates() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(recipientPrivateKey: recipientPrivateKey)
        let candidate = OID4VPCredentialCandidate(
            id: "credential-1",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([
                "given_name": .string("Ada")
            ]),
            presentation: .string("eyJhbGciOiJFUzI1NiJ9.sd-jwt-vc")
        )

        let plan = try OID4VPDirectPostJWTSubmissionAdapter.build(
            requestObject: requestObject,
            candidates: [candidate],
            issuer: "https://wallet.example.org"
        )

        XCTAssertTrue(plan.matchResult.satisfiesRequiredConstraints)
        XCTAssertEqual(plan.response.state, "state-123")
        XCTAssertEqual(plan.response.issuer, "https://wallet.example.org")
        XCTAssertEqual(plan.submission.responseMode, .directPostJwt)
        XCTAssertEqual(plan.submission.responseURI.absoluteString, "https://verifier.example.org/post")

        let compactResponse = try XCTUnwrap(plan.submission.formParameters["response"])
        XCTAssertEqual(compactResponse, plan.jwe.compactSerialization)

        let plaintext = try decrypt(jwe: plan.jwe, recipientPrivateKey: recipientPrivateKey)
        let plaintextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: AnyHashable])
        XCTAssertEqual(plaintextObject["iss"] as? String, "https://wallet.example.org")
        XCTAssertEqual(plaintextObject["state"] as? String, "state-123")
        let vpToken = try XCTUnwrap(plaintextObject["vp_token"] as? [String: [String]])
        XCTAssertEqual(vpToken["pid"], ["eyJhbGciOiJFUzI1NiJ9.sd-jwt-vc"])
    }

    func testRejectsPlanWhenRequiredCredentialQueryIsUnsatisfied() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = makeRequestObject(recipientPrivateKey: recipientPrivateKey)
        let wrongCandidate = OID4VPCredentialCandidate(
            id: "credential-2",
            format: .jwtVcJson,
            meta: ["types": .array([.string("MembershipCredential")])],
            claims: .object([:]),
            presentation: .string("jwt-presentation")
        )

        XCTAssertThrowsError(
            try OID4VPDirectPostJWTSubmissionAdapter.build(
                requestObject: requestObject,
                candidates: [wrongCandidate]
            )
        ) { error in
            XCTAssertEqual(error as? OID4VPResponseError, .unsatisfiedRequiredConstraints)
        }
    }

    func testBuildsDirectPostJWTSubmissionPlanForPreRegisteredVerifierUsingMetadataProvider() async throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let requestObject = OID4VPRequestObject(
            clientID: "verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "pid",
                    format: .sdJwtVc,
                    meta: ["vct_values": .array([.string("https://example.com/pid")])]
                )
            ]),
            state: "state-123"
        )

        let publicKey = recipientPrivateKey.publicKey.x963Representation
        let x = JOSEBase64URL.encode(publicKey.subdata(in: 1..<33))
        let y = JOSEBase64URL.encode(publicKey.subdata(in: 33..<65))
        let metadataProvider = OID4VPStaticVerifierMetadataProvider(records: [
            OID4VPStaticVerifierMetadataRecord(
                clientIDs: ["verifier.example.org"],
                metadata: OID4VPVerifierMetadata(
                    jwks: JOSEJWKSet(keys: [
                        JOSEJWK(
                            keyType: "EC",
                            keyID: "enc-1",
                            publicKeyUse: "enc",
                            algorithm: "ECDH-ES",
                            curve: "P-256",
                            x: x,
                            y: y
                        )
                    ]),
                    encryptedResponseEncValuesSupported: ["A128GCM"]
                ),
                source: .preRegistered
            )
        ])
        let candidate = OID4VPCredentialCandidate(
            id: "credential-1",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([
                "given_name": .string("Ada")
            ]),
            presentation: .string("eyJhbGciOiJFUzI1NiJ9.sd-jwt-vc")
        )

        let plan = try await OID4VPDirectPostJWTSubmissionAdapter.build(
            requestObject: requestObject,
            candidates: [candidate],
            metadataProvider: metadataProvider,
            issuer: "https://wallet.example.org"
        )

        XCTAssertEqual(plan.resolvedVerifierMetadata?.source, .preRegistered)
        XCTAssertEqual(plan.resolvedVerifierMetadata?.clientIdentifierPrefix, .preRegistered)
        XCTAssertEqual(plan.preparation.selectedKey.keyID, "enc-1")

        let plaintext = try decrypt(jwe: plan.jwe, recipientPrivateKey: recipientPrivateKey)
        let plaintextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: AnyHashable])
        XCTAssertEqual(plaintextObject["iss"] as? String, "https://wallet.example.org")
        XCTAssertEqual(plaintextObject["state"] as? String, "state-123")
    }

    private func makeRequestObject(
        recipientPrivateKey: P256.KeyAgreement.PrivateKey
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
                OID4VPDCQLCredentialQuery(
                    id: "pid",
                    format: .sdJwtVc,
                    meta: ["vct_values": .array([.string("https://example.com/pid")])]
                )
            ]),
            state: "state-123",
            clientMetadata: [
                "jwks": .object([
                    "keys": .array([
                        .object([
                            "kty": .string("EC"),
                            "kid": .string("enc-1"),
                            "use": .string("enc"),
                            "alg": .string("ECDH-ES"),
                            "crv": .string("P-256"),
                            "x": .string(x),
                            "y": .string(y)
                        ])
                    ])
                ]),
                "encrypted_response_enc_values_supported": .array([.string("A128GCM")])
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
        let contentEncryptionKeyData = concatKDF(
            sharedSecret: sharedSecretData,
            algorithmIdentifier: algorithm == "ECDH-ES" ? contentEncryptionAlgorithm : algorithm,
            keyLengthBits: keyLengthBits(for: contentEncryptionAlgorithm)
        )
        let contentEncryptionKey = SymmetricKey(data: contentEncryptionKeyData)
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

    private func keyLengthBits(for contentEncryptionAlgorithm: String) -> Int {
        switch contentEncryptionAlgorithm {
        case "A128GCM":
            return 128
        case "A192GCM":
            return 192
        case "A256GCM":
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
