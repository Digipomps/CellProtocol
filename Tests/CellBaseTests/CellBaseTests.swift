// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import CellBase

final class CellBaseTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
//        XCTAssertEqual(CellBase().text, "Hello, World!")
    }
   
    
    func testEnums() throws {
        var enumCase = "secp256k1****"
        if let json = "\"\(enumCase)\"".data(using: .utf8) {
            XCTAssertThrowsError(try JSONDecoder().decode(CurveType.self, from: json))
        }
        
        enumCase = "secp256k1"
        if let json = "\"\(enumCase)\"".data(using: .utf8) {
            var curveType: CurveType?
            XCTAssertNoThrow(curveType = try JSONDecoder().decode(CurveType.self, from: json))
            XCTAssertTrue(curveType == CurveType.secp256k1)
        }

        enumCase = "P-256"
        if let json = "\"\(enumCase)\"".data(using: .utf8) {
            var curveType: CurveType?
            XCTAssertNoThrow(curveType = try JSONDecoder().decode(CurveType.self, from: json))
            XCTAssertTrue(curveType == CurveType.P256)
        }
        
        enumCase = "ECDSA****"
        if let json = "\"\(enumCase)\"".data(using: .utf8) {
            XCTAssertThrowsError(try JSONDecoder().decode(CurveAlgorithm.self, from: json))
        }
        
        enumCase = "ECDSA"
        if let json = "\"\(enumCase)\"".data(using: .utf8) {
            XCTAssertNoThrow(try JSONDecoder().decode(CurveAlgorithm.self, from: json))
        }
    }

    #if canImport(CryptoKit)
    func testDIDKeyParserRoundTripsP256Multikey() throws {
        let signingKey = P256.Signing.PrivateKey()
        guard let compactPublicKey = signingKey.publicKey.compactRepresentation else {
            throw XCTSkip("Compact P-256 representation unavailable")
        }

        let multibase = try DIDKeyParser.multibaseEncodedPublicKey(compactPublicKey, curveType: .P256)
        let parsed = try DIDKeyParser.extractPublicKeyAndDID(from: "did:key:\(multibase)")

        XCTAssertEqual(parsed.keyType, "Multikey")
        XCTAssertEqual(parsed.curveType, .P256)
        XCTAssertEqual(parsed.publicKey, compactPublicKey)
        XCTAssertEqual(parsed.multibase, multibase)
    }
    #endif
}

