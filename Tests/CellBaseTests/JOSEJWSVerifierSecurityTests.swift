// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class JOSEJWSVerifierSecurityTests: XCTestCase {
    func testES256JWKVerificationBindsAlgorithmCurveAndKeyUse() throws {
        let privateKey = P256.Signing.PrivateKey()
        let signingInput = Data("protected.payload".utf8)
        let signature = try privateKey.signature(for: signingInput).rawRepresentation
        let x963 = privateKey.publicKey.x963Representation
        var jwk = JOSEJWK(
            keyType: "EC",
            publicKeyUse: "sig",
            keyOperations: ["verify"],
            algorithm: "ES256",
            curve: "P-256",
            x: JOSEBase64URL.encode(x963.subdata(in: 1..<33)),
            y: JOSEBase64URL.encode(x963.subdata(in: 33..<65))
        )

        XCTAssertTrue(try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "ES256",
            using: jwk
        ))

        jwk.curve = "secp256k1"
        XCTAssertThrowsError(try verifyES256(signingInput, signature, jwk))

        jwk.curve = "P-256"
        jwk.algorithm = "ES384"
        XCTAssertThrowsError(try verifyES256(signingInput, signature, jwk))

        jwk.algorithm = "ES256"
        jwk.publicKeyUse = "enc"
        XCTAssertThrowsError(try verifyES256(signingInput, signature, jwk))

        jwk.publicKeyUse = "sig"
        jwk.keyOperations = ["encrypt"]
        XCTAssertThrowsError(try verifyES256(signingInput, signature, jwk))
    }

    func testEdDSAJWKVerificationBindsKeyTypeCurveAndLength() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signingInput = Data("protected.payload".utf8)
        let signature = try privateKey.signature(for: signingInput)
        var jwk = JOSEJWK(
            keyType: "OKP",
            publicKeyUse: "sig",
            keyOperations: ["verify"],
            algorithm: "EdDSA",
            curve: "Ed25519",
            x: JOSEBase64URL.encode(privateKey.publicKey.rawRepresentation)
        )

        XCTAssertTrue(try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "EdDSA",
            using: jwk
        ))

        jwk.keyType = "EC"
        XCTAssertThrowsError(try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "EdDSA",
            using: jwk
        ))

        jwk.keyType = "OKP"
        jwk.x = JOSEBase64URL.encode(Data(repeating: 0x01, count: 31))
        XCTAssertThrowsError(try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "EdDSA",
            using: jwk
        ))
    }

    func testDirectES256VerificationRejectsSecp256k1Metadata() throws {
        let privateKey = P256.Signing.PrivateKey()
        let signingInput = Data("protected.payload".utf8)
        let signature = try privateKey.signature(for: signingInput).rawRepresentation

        XCTAssertThrowsError(try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "ES256",
            publicKey: privateKey.publicKey.x963Representation,
            curveType: .secp256k1
        ))
    }

    private func verifyES256(_ signingInput: Data, _ signature: Data, _ jwk: JOSEJWK) throws -> Bool {
        try JOSEJWSVerifier.verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: "ES256",
            using: jwk
        )
    }
}
