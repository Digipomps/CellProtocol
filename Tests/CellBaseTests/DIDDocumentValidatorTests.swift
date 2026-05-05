// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class DIDDocumentValidatorTests: XCTestCase {
    private func makeIdentity(
        displayName: String = "did-owner",
        publicKey: Data = Data(repeating: 0x22, count: 32),
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

    private func document(from json: String) throws -> DIDDocument {
        try JSONDecoder().decode(DIDDocument.self, from: Data(json.utf8))
    }

    func testValidatorAcceptsGeneratedDidDocument() async throws {
        let identity = makeIdentity()
        let didDocument = try await identity.didDocument()

        let result = try DIDDocumentValidator.validate(didDocument)

        XCTAssertEqual(result.verificationMethodIDs.count, 1)
        XCTAssertEqual(result.assertionMethodIDs.count, 1)
        XCTAssertEqual(result.authenticationMethodIDs.count, 1)
        XCTAssertEqual(result.assertionMethodIDs.first, result.verificationMethodIDs.first)
        XCTAssertEqual(result.authenticationMethodIDs.first, result.verificationMethodIDs.first)
    }

    func testValidatorRejectsMissingReferencedAssertionMethod() throws {
        let didDocument = try document(from: """
        {
          "@context": [
            "https://www.w3.org/ns/did/v1",
            "https://w3id.org/security/multikey/v1"
          ],
          "id": "did:web:example.com",
          "verificationMethod": [
            {
              "id": "did:web:example.com#key-1",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyOne"
            }
          ],
          "authentication": ["did:web:example.com#key-1"],
          "assertionMethod": ["did:web:example.com#missing"]
        }
        """)

        XCTAssertThrowsError(try DIDDocumentValidator.validate(didDocument)) { error in
            XCTAssertEqual(
                error as? DIDDocumentValidationError,
                .missingReferencedVerificationMethod("did:web:example.com#missing")
            )
        }
    }

    func testIssuerBindingAcceptsAssertionKeyID() throws {
        let didDocument = try document(from: """
        {
          "@context": [
            "https://www.w3.org/ns/did/v1",
            "https://w3id.org/security/multikey/v1"
          ],
          "id": "did:web:example.com",
          "verificationMethod": [
            {
              "id": "did:web:example.com#assert-key",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyAssertion"
            },
            {
              "id": "did:web:example.com#auth-key",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyAuthentication"
            }
          ],
          "authentication": ["did:web:example.com#auth-key"],
          "assertionMethod": ["did:web:example.com#assert-key"]
        }
        """)

        XCTAssertNoThrow(
            try DIDIssuerBindingValidator.validateKeyID(
                "did:web:example.com#assert-key",
                issuerIdentifier: "did:web:example.com",
                didDocument: didDocument,
                requiredUse: .assertion
            )
        )
    }

    func testIssuerBindingRejectsAuthenticationKeyForAssertionUse() throws {
        let didDocument = try document(from: """
        {
          "@context": [
            "https://www.w3.org/ns/did/v1",
            "https://w3id.org/security/multikey/v1"
          ],
          "id": "did:web:example.com",
          "verificationMethod": [
            {
              "id": "did:web:example.com#assert-key",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyAssertion"
            },
            {
              "id": "did:web:example.com#auth-key",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyAuthentication"
            }
          ],
          "authentication": ["did:web:example.com#auth-key"],
          "assertionMethod": ["did:web:example.com#assert-key"]
        }
        """)

        XCTAssertThrowsError(
            try DIDIssuerBindingValidator.validateKeyID(
                "did:web:example.com#auth-key",
                issuerIdentifier: "did:web:example.com",
                didDocument: didDocument,
                requiredUse: .assertion
            )
        ) { error in
            XCTAssertEqual(
                error as? DIDIssuerBindingError,
                .keyIDNotAuthorizedForUse(
                    keyID: "did:web:example.com#auth-key",
                    use: "assertion"
                )
            )
        }
    }

    func testIssuerBindingRejectsIssuerDocumentMismatch() throws {
        let didDocument = try document(from: """
        {
          "@context": [
            "https://www.w3.org/ns/did/v1",
            "https://w3id.org/security/multikey/v1"
          ],
          "id": "did:web:example.com",
          "verificationMethod": [
            {
              "id": "did:web:example.com#assert-key",
              "type": "Multikey",
              "controller": "did:web:example.com",
              "publicKeyMultibase": "z6MkhRminvalidKeyAssertion"
            }
          ],
          "authentication": ["did:web:example.com#assert-key"],
          "assertionMethod": ["did:web:example.com#assert-key"]
        }
        """)

        XCTAssertThrowsError(
            try DIDIssuerBindingValidator.validateIssuer(
                issuerIdentifier: "did:web:other.example.com",
                didDocument: didDocument
            )
        ) { error in
            XCTAssertEqual(
                error as? DIDIssuerBindingError,
                .issuerDocumentMismatch(
                    expected: "did:web:other.example.com",
                    actual: "did:web:example.com"
                )
            )
        }
    }
}
