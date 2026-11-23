// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class SecureKeyDerivationTests: XCTestCase {

    /// The shared table. A port must give the same answers.
    func testUseFollowsAlgorithm() {
        let expected: [(CurveAlgorithm, KeyUse)] = [
            (.EdDSA, .signature),
            (.ECDSA, .signature),
            (.X25519, .keyAgreement),
            (.ECDH, .keyAgreement),
            (.FHMQV, .keyAgreement),
            (.ECIES, .encrypt),
            (.EEECC, .encrypt),
        ]
        for (algorithm, use) in expected {
            XCTAssertEqual(SecureKey.derivedUse(for: algorithm), use, "\(algorithm)")
            XCTAssertEqual(algorithm.derivedKeyUse, use, "\(algorithm)")
        }
    }

    func testSizeFollowsCurve() {
        XCTAssertEqual(SecureKey.derivedSize(for: .Curve25519), 256)
        XCTAssertEqual(SecureKey.derivedSize(for: .P256), 256)
        XCTAssertEqual(SecureKey.derivedSize(for: .secp256k1), 256)
    }

    func testDerivingInitializer() {
        let ed = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false, algorithm: .EdDSA,
                           curveType: .Curve25519, x: nil, y: nil, compressedKey: Data(repeating: 1, count: 32))
        XCTAssertEqual(ed.use, .signature)
        XCTAssertEqual(ed.size, 256)
        XCTAssertTrue(ed.useAndSizeMatchDerivation)

        let x = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: true, algorithm: .X25519,
                          curveType: .Curve25519, x: nil, y: nil, compressedKey: nil)
        XCTAssertEqual(x.use, .keyAgreement)
        XCTAssertEqual(x.size, 256)

        // P-256 keys are 256 bits whether they are 33 (compressed) or 65 bytes.
        let p256 = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false, algorithm: .ECDSA,
                             curveType: .P256, x: nil, y: nil, compressedKey: Data(repeating: 2, count: 33))
        XCTAssertEqual(p256.use, .signature)
        XCTAssertEqual(p256.size, 256)
    }

    /// The deriving initializer encodes exactly like the explicit one with the
    /// table's values, so switching a call site does not change any bytes.
    func testDerivingInitializerEncodesLikeExplicitValues() throws {
        let date = Date(timeIntervalSince1970: 1_793_102_400)
        let key = Data(repeating: 7, count: 32)
        let derived = SecureKey(date: date, privateKey: false, algorithm: .EdDSA, curveType: .Curve25519,
                                x: nil, y: nil, compressedKey: key)
        let explicit = SecureKey(date: date, privateKey: false, use: .signature, algorithm: .EdDSA, size: 256,
                                 curveType: .Curve25519, x: nil, y: nil, compressedKey: key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(derived), try encoder.encode(explicit))
    }

    /// Older call sites store a byte length; the check reports it.
    func testLegacyByteLengthIsReported() {
        let legacy = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false, use: .signature, algorithm: .EdDSA,
                               size: 32, curveType: .Curve25519, x: nil, y: nil, compressedKey: nil)
        XCTAssertFalse(legacy.useAndSizeMatchDerivation)
        let wrongUse = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false, use: .keyAgreement, algorithm: .EdDSA,
                                 size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: nil)
        XCTAssertFalse(wrongUse.useAndSizeMatchDerivation)
    }
}
