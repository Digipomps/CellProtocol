// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class DIDInteroperabilityTests: XCTestCase {
    private func makeIdentity(
        displayName: String = "did-owner",
        publicKey: Data = Data(repeating: 0x11, count: 32),
        curveType: CurveType = .Curve25519,
        algorithm: CurveAlgorithm = .EdDSA
    ) -> Identity {
        let identity = Identity(UUID().uuidString, displayName: displayName, identityVault: CellBase.defaultIdentityVault)
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: algorithm,
            size: publicKey.count,
            curveType: curveType,
            x: nil,
            y: nil,
            compressedKey: publicKey
        )
        return identity
    }

    func testDidWebOriginRoundTripsToWellKnownDidDocument() throws {
        let did = try DIDWebParser.did(from: "https://example.com")
        XCTAssertEqual(did, "did:web:example.com")

        let documentURL = try DIDWebParser.url(from: did)
        XCTAssertEqual(documentURL.absoluteString, "https://example.com/.well-known/did.json")
    }

    func testDidWebPathAndPortRoundTrip() throws {
        let did = try DIDWebParser.did(from: "https://example.com:8443/users/alice")
        XCTAssertEqual(did, "did:web:example.com%3A8443:users:alice")

        let documentURL = try DIDWebParser.url(from: did)
        XCTAssertEqual(documentURL.absoluteString, "https://example.com:8443/users/alice/did.json")
    }

    func testIdentityDidDocumentBuildsMultikeyDocumentByDefault() async throws {
        let identity = makeIdentity()

        let document = try await identity.didDocument()

        XCTAssertTrue(document.id.hasPrefix("did:key:z"))
        XCTAssertEqual(document.verificationMethods?.count, 1)
        XCTAssertEqual(document.assertionMethods?.count, 1)
        XCTAssertEqual(document.authentications?.count, 1)

        guard let verificationMethod = document.verificationMethods?.first else {
            XCTFail("Expected verification method")
            return
        }

        XCTAssertEqual(verificationMethod.type, .Multikey)
        XCTAssertEqual(verificationMethod.controller, document.id)

        switch verificationMethod.publicKeyType {
        case .publicKeyMultibase(let multibase):
            XCTAssertTrue(multibase.hasPrefix("z"))
            XCTAssertEqual(verificationMethod.id, "\(document.id)#\(multibase)")
        default:
            XCTFail("Expected publicKeyMultibase")
        }

        if case .reference(let reference)? = document.assertionMethods?.first {
            XCTAssertEqual(reference, verificationMethod.id)
        } else {
            XCTFail("Expected assertion method reference")
        }

        if case .reference(let reference)? = document.authentications?.first {
            XCTAssertEqual(reference, verificationMethod.id)
        } else {
            XCTFail("Expected authentication reference")
        }
    }

    func testIdentityDidDocumentSupportsDidWeb() async throws {
        let identity = makeIdentity()

        let document = try await identity.didDocument(type: .web, urlString: "https://example.com/users/alice")

        XCTAssertEqual(document.id, "did:web:example.com:users:alice")
        guard let verificationMethod = document.verificationMethods?.first else {
            XCTFail("Expected verification method")
            return
        }
        XCTAssertEqual(verificationMethod.controller, document.id)

        let resolvedURL = try Identity.urlFromWebDid(document.id)
        XCTAssertEqual(resolvedURL.absoluteString, "https://example.com/users/alice/did.json")
    }
}
