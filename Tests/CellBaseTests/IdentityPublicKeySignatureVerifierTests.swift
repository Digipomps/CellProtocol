// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class IdentityPublicKeySignatureVerifierTests: XCTestCase {
    func testP256SignatureRequiresExactAlgorithmAndCurveMetadata() throws {
        let privateKey = P256.Signing.PrivateKey()
        let message = Data("metadata-bound-signature".utf8)
        let signature = try privateKey.signature(for: message).derRepresentation
        let identity = Identity("p256-signer", displayName: "P-256 signer", identityVault: nil)
        identity.publicSecureKey = publicKey(
            privateKey.publicKey.x963Representation,
            algorithm: .ECDSA,
            curveType: .P256
        )

        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: message,
            identity: identity
        ))

        identity.publicSecureKey = publicKey(
            privateKey.publicKey.x963Representation,
            algorithm: .ECDSA,
            curveType: .secp256k1
        )
        XCTAssertFalse(IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: message,
            identity: identity
        ))

        identity.publicSecureKey = publicKey(
            privateKey.publicKey.x963Representation,
            algorithm: .EdDSA,
            curveType: .P256
        )
        XCTAssertFalse(IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: message,
            identity: identity
        ))
    }

    func testDecodedPublicIdentityVerifiesWithoutAnyVault() async throws {
        let vault = await EphemeralIdentityVault().initialize()
        let resolvedIdentity = await vault.identity(for: "decoded-verifier", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(resolvedIdentity)
        let message = Data("public-only-verification".utf8)
        let resolvedSignature = try await identity.sign(data: message)
        let signature = try XCTUnwrap(resolvedSignature)
        let decoded = try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(identity))

        XCTAssertNil(decoded.identityVault)
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: message,
            identity: decoded
        ))
    }

    func testPublicIdentitySnapshotNeverRelabelsPrivateKeyMaterial() {
        let sentinel = Data(repeating: 0xA5, count: 32)
        let identity = Identity("private-material", displayName: "private", identityVault: nil)
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: true,
            use: .signature,
            algorithm: .EdDSA,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: sentinel
        )

        let snapshot = identity.publicIdentitySnapshot()

        XCTAssertNil(snapshot.publicSecureKey)
        XCTAssertNil(snapshot.identityVault)
        XCTAssertNil(snapshot.homeVaultReference)
    }

    func testIdentityControlProofRequiresExactHomeVaultAndPrivateKey() async throws {
        let homeVault = await EphemeralIdentityVault().initialize()
        let otherVault = await EphemeralIdentityVault().initialize()
        let resolvedIdentity = await homeVault.identity(for: "control-proof", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(resolvedIdentity)

        let validProof = await IdentitySigningChallenge.proveControl(
            of: identity,
            domain: "test",
            resource: "identity-control",
            action: "verify",
            audience: "IdentityPublicKeySignatureVerifierTests"
        )
        XCTAssertTrue(validProof)

        identity.identityVault = otherVault
        let wrongVaultProof = await IdentitySigningChallenge.proveControl(
            of: identity,
            domain: "test",
            resource: "identity-control",
            action: "verify",
            audience: "IdentityPublicKeySignatureVerifierTests"
        )
        XCTAssertFalse(wrongVaultProof)

        identity.identityVault = nil
        let detachedProof = await IdentitySigningChallenge.proveControl(
            of: identity,
            domain: "test",
            resource: "identity-control",
            action: "verify",
            audience: "IdentityPublicKeySignatureVerifierTests"
        )
        XCTAssertFalse(detachedProof)
    }

    func testChallengeBoundsRejectOversizedNonceScopeAndValidity() throws {
        let vault = EphemeralIdentityVault()
        let identity = Identity("challenge-bounds", displayName: "Challenge bounds", identityVault: vault)
        identity.publicSecureKey = publicKey(Data(repeating: 0x01, count: 32), algorithm: .EdDSA, curveType: .Curve25519)

        for challenge in [
            IdentitySigningChallenge(
                identityUUID: identity.uuid,
                publicKeyFingerprint: identity.signingPublicKeyFingerprint,
                domain: "test",
                resource: "resource",
                action: "verify",
                audience: "tests",
                nonce: Data(repeating: 1, count: IdentitySigningChallenge.maximumNonceBytes + 1)
            ),
            IdentitySigningChallenge(
                identityUUID: identity.uuid,
                publicKeyFingerprint: identity.signingPublicKeyFingerprint,
                domain: String(repeating: "x", count: IdentitySigningChallenge.maximumScopeCharacters + 1),
                resource: "resource",
                action: "verify",
                audience: "tests",
                nonce: Data(repeating: 1, count: IdentitySigningChallenge.minimumNonceBytes)
            ),
            IdentitySigningChallenge(
                identityUUID: identity.uuid,
                publicKeyFingerprint: identity.signingPublicKeyFingerprint,
                domain: "test",
                resource: "resource",
                action: "verify",
                audience: "tests",
                nonce: Data(repeating: 1, count: IdentitySigningChallenge.minimumNonceBytes),
                validity: IdentitySigningChallenge.defaultValidity + 1
            )
        ] {
            XCTAssertThrowsError(try IdentitySigningChallenge.validateSigningData(
                JSONEncoder().encode(challenge),
                for: identity
            ))
        }
    }

    func testVCPresentationBindsHolderDIDAndProofMetadataToPublicKey() async throws {
        let vault = await EphemeralIdentityVault().initialize()
        let resolvedHolder = await vault.identity(
            for: "presentation-holder",
            makeNewIfNotFound: true
        )
        let resolvedOther = await vault.identity(
            for: "presentation-other",
            makeNewIfNotFound: true
        )
        let holder = try XCTUnwrap(resolvedHolder)
        let other = try XCTUnwrap(resolvedOther)
        let challenge = Data(repeating: 0x42, count: 32)
        let domain = "presentation.example"
        var presentation = try await VCPresentation(
            type: "BoundPresentation",
            holderIdentity: holder,
            subjectIdentity: holder,
            verifiableCredentials: []
        )
        try await presentation.bindAndSign(
            holderIdentity: holder,
            challenge: challenge,
            domain: domain
        )

        let verified = try await presentation.verifyHolderProof(
            expectedChallenge: challenge,
            expectedDomain: domain
        )
        XCTAssertTrue(verified)

        let decoded = try JSONDecoder().decode(
            VCPresentation.self,
            from: JSONEncoder().encode(presentation)
        )
        let decodedVerified = try await decoded.verifyHolderProof(
            expectedChallenge: challenge,
            expectedDomain: domain
        )
        XCTAssertTrue(decodedVerified)

        presentation.holder = .reference(try other.did())
        let forgedHolderSignature = try await holder.sign(
            data: presentation.canonicalPayloadData()
        )
        presentation.proof.signatureData = try XCTUnwrap(forgedHolderSignature)
        let forgedHolderVerified = try await presentation.verifyHolderProof(
            expectedChallenge: challenge,
            expectedDomain: domain
        )
        XCTAssertFalse(forgedHolderVerified)

        presentation.holder = .reference(try holder.did())
        let restoredHolderSignature = try await holder.sign(
            data: presentation.canonicalPayloadData()
        )
        presentation.proof.signatureData = try XCTUnwrap(restoredHolderSignature)
        presentation.proof.verificationMethod = other.uuid
        let wrongVerificationMethod = try await presentation.verifyHolderProof(
            expectedChallenge: challenge,
            expectedDomain: domain
        )
        XCTAssertFalse(wrongVerificationMethod)

        presentation.proof.verificationMethod = holder.uuid
        presentation.proof.type = .EcdsaSecp256r1Signature2019
        let wrongProofType = try await presentation.verifyHolderProof(
            expectedChallenge: challenge,
            expectedDomain: domain
        )
        XCTAssertFalse(wrongProofType)
    }

    private func publicKey(_ data: Data, algorithm: CurveAlgorithm, curveType: CurveType) -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: algorithm,
            size: 256,
            curveType: curveType,
            x: nil,
            y: nil,
            compressedKey: data
        )
    }
}
