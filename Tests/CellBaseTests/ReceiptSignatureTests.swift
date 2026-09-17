// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// purposeRef: purpose://candidate.tillitspakke-agentflaate.signert-kvittering
final class ReceiptSignatureTests: XCTestCase {
    func testLegacyJSONWithoutSignatureDecodesAsUnsigned() throws {
        let receipt = try legacyReceipt()
        XCTAssertNil(receipt.signature)
        XCTAssertEqual(receipt.verify(against: Identity()), .unsigned)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertNil(object["signature"])
        XCTAssertEqual(object["receiptId"] as? String, "receipt://fixture/decision-1")
    }

    func testSignsWithVaultAndVerifiesWithPublicIdentityOnly() async throws {
        let signer = try await identity()
        let receipt = try await legacyReceipt().signed(by: signer)
        let publicSigner = signer.publicIdentitySnapshot()
        XCTAssertNil(publicSigner.identityVault)
        XCTAssertEqual(receipt.signature?.algorithm, "Ed25519")
        XCTAssertEqual(receipt.signature?.signedAt, receipt.createdAt)
        XCTAssertEqual(receipt.verify(against: publicSigner), .valid)
        let roundTrip = try JSONDecoder().decode(ActionDecisionReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(roundTrip, receipt)
        XCTAssertEqual(roundTrip.verify(against: publicSigner), .valid)

        // Verify independently against the canonical legacy object: the signed
        // message is the whole receipt, with no signature field or envelope.
        let object = try JSONSerialization.jsonObject(with: Data(Self.legacyJSON.utf8))
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(receipt.signature).value))
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: canonical, identity: publicSigner))
    }

    func testChangingOneBindingDigestInvalidatesDecisionSignature() async throws {
        let signer = try await identity()
        var receipt = try await legacyReceipt().signed(by: signer)
        receipt.bindings.policyDigest = "sha256:" + String(repeating: "b", count: 64)
        XCTAssertEqual(receipt.verify(against: signer), .invalid)
    }

    func testChangingDecisionExecutionOrIssuanceInvalidatesSignature() async throws {
        let signer = try await identity()
        let receipt = try await legacyReceipt().signed(by: signer)
        var changed = receipt
        changed.decisionStatus = .denied
        XCTAssertEqual(changed.verify(against: signer), .invalid)
        XCTAssertEqual(receipt.recordingExecution(.failed).verify(against: signer), .invalid)
        changed = receipt
        changed.createdAt = "2026-09-09T00:00:01Z"
        changed.signature?.signedAt = changed.createdAt
        XCTAssertEqual(changed.verify(against: signer), .invalid)
    }

    func testSignatureMetadataAndMalformedBase64FailClosed() async throws {
        let signer = try await identity()
        let receipt = try await legacyReceipt().signed(by: signer)
        let mutations: [(inout ReceiptSignature) -> Void] = [
            { $0.signerRef = "identity://attacker" },
            { $0.algorithm = "P256-ECDSA-SHA256" },
            { $0.signedAt = "2026-09-09T00:00:01Z" },
            { $0.value = "not base64!" },
            { $0.value = "" },
            { $0.value += "\n" }
        ]
        for mutation in mutations {
            var changed = receipt
            var signature = try XCTUnwrap(changed.signature)
            mutation(&signature)
            changed.signature = signature
            XCTAssertEqual(changed.verify(against: signer), .invalid)
        }
    }

    func testWrongKeyWithSameUUIDCannotVerify() async throws {
        let signer = try await identity()
        let other = try await identity() // Separate vault, same deterministic UUID, different key.
        XCTAssertEqual(signer.uuid, other.uuid)
        XCTAssertNotEqual(signer.signingPublicKeyFingerprint, other.signingPublicKeyFingerprint)
        let receipt = try await legacyReceipt().signed(by: signer)
        XCTAssertEqual(receipt.verify(against: other), .invalid)
    }

    func testCanonicalTimestampNormalizationAndResigningIgnoreOldSignature() async throws {
        let signer = try await identity()
        let first = try await legacyReceipt().signed(by: signer)
        var offset = first
        offset.createdAt = "2026-09-09T02:00:00.000+02:00"
        let second = try await offset.signed(by: signer)
        var firstUnsigned = first
        firstUnsigned.signature = nil
        var secondUnsigned = second
        secondUnsigned.signature = nil
        XCTAssertEqual(try ReceiptSigning.canonicalBytes(firstUnsigned), try ReceiptSigning.canonicalBytes(secondUnsigned))
        XCTAssertEqual(first.verify(against: signer), .valid)
        XCTAssertEqual(second.verify(against: signer), .valid)
        XCTAssertEqual(first.signature?.signedAt, second.signature?.signedAt)
        var fractional = first
        fractional.createdAt = "2026-09-09T00:00:00.000000001Z"
        let third = try await fractional.signed(by: signer)
        var thirdUnsigned = third
        thirdUnsigned.signature = nil
        XCTAssertNotEqual(try ReceiptSigning.canonicalBytes(firstUnsigned), try ReceiptSigning.canonicalBytes(thirdUnsigned))
        XCTAssertEqual(third.verify(against: signer), .valid)
    }

    func testMissingVaultAndInvalidTimestampDoNotProduceSignature() async throws {
        let signer = try await identity()
        do {
            _ = try await legacyReceipt().signed(by: signer.publicIdentitySnapshot())
            XCTFail("Public descriptors must not sign")
        } catch IdentityVaultError.noVaultIdentity { }
        var malformed = try legacyReceipt()
        malformed.createdAt = "2026-02-31T00:00:00Z"
        do {
            _ = try await malformed.signed(by: signer)
            XCTFail("Invalid timestamp must not be signed")
        } catch AgentTrustPackageCanonicalEncoder.ValidationError.invalidTimestamp { }
    }

    func testP256SignsViaIdentityVaultAPIAndPublicKeyVerifier() async throws {
        let vault = ReceiptP256FixtureVault()
        let resolved = await vault.identity(for: "receipt", makeNewIfNotFound: true)
        let signer = try XCTUnwrap(resolved)
        let decision = try await legacyReceipt().signed(by: signer)
        XCTAssertEqual(decision.signature?.algorithm, "P256-ECDSA-SHA256")
        XCTAssertEqual(decision.verify(against: signer.publicIdentitySnapshot()), .valid)
        let effect = try await effectReceipt().signed(by: signer)
        XCTAssertEqual(effect.signature?.algorithm, "P256-ECDSA-SHA256")
        XCTAssertEqual(effect.verify(against: signer.publicIdentitySnapshot()), .valid)
    }

    func testEffectSignatureRoundTripAndTamperedCeilingAndPackageDigests() async throws {
        let signer = try await identity()
        let receipt = try await effectReceipt().signed(by: signer)
        let roundTrip = try JSONDecoder().decode(EffectReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(roundTrip, receipt)
        XCTAssertEqual(roundTrip.verify(against: signer.publicIdentitySnapshot()), .valid)
        var changed = receipt
        changed.bindings.ceilingDigest = "sha256:changed"
        XCTAssertEqual(changed.verify(against: signer), .invalid)
        changed = receipt
        changed.bindings.packageDigest = "sha256:changed"
        XCTAssertEqual(changed.verify(against: signer), .invalid)
        changed = receipt
        changed.credentialsUsed = true
        XCTAssertEqual(changed.verify(against: signer), .invalid)
        changed = receipt
        changed.bytes += 1
        XCTAssertEqual(changed.verify(against: signer), .invalid)
    }

    func testUnsignedEffectRoundTripAndNoRawContentFields() throws {
        let receipt = try effectReceipt()
        let data = try JSONEncoder().encode(receipt)
        let roundTrip = try JSONDecoder().decode(EffectReceipt.self, from: data)
        XCTAssertEqual(roundTrip.verify(against: Identity()), .unsigned)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set([
            "schema", "receiptID", "cellRef", "action", "destinationHost", "method", "bytes",
            "credentialsUsed", "decisionStatus", "executionStatus", "bindings", "createdAt"
        ]))
        XCTAssertEqual(object["destinationHost"] as? String, "example.org")
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["private-path", "query-sentinel", "body-sentinel", "credentialAlias", "Authorization", "textPreview"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
    }

    func testEffectHostRejectsURLPathQueryCredentialsAndPortOnEncodeAndDecode() throws {
        for host in ["https://example.org/private-path", "example.org/private-path", "example.org?query-sentinel",
                     "example.org#fragment", "user:password@example.org", "example.org:8443", "example.org\n"] {
            var receipt = try effectReceipt()
            receipt.destinationHost = host
            XCTAssertThrowsError(try JSONEncoder().encode(receipt), host)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(effectReceipt())) as? [String: Any])
            object["destinationHost"] = host
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(EffectReceipt.self, from: data), host)
        }
        var receipt = try effectReceipt()
        receipt.reason = "request failed: body-sentinel"
        XCTAssertThrowsError(try JSONEncoder().encode(receipt))
    }

    private func identity() async throws -> Identity {
        let vault = EphemeralIdentityVault()
        let resolved = await vault.identity(for: "receipt", makeNewIfNotFound: true)
        return try XCTUnwrap(resolved)
    }

    private func legacyReceipt() throws -> ActionDecisionReceipt {
        try JSONDecoder().decode(ActionDecisionReceipt.self, from: Data(Self.legacyJSON.utf8))
    }

    private func effectReceipt() throws -> EffectReceipt {
        // Model-level fixture only; this does not exercise WebFetchCell issuance.
        let source = URL(string: "https://example.org/private-path?q=query-sentinel")!
        return try EffectReceipt(
            receiptID: "receipt://fixture/effect-1", cellRef: "cell:///WebFetch",
            destinationHost: source.host!, method: "GET", bytes: 42, credentialsUsed: false,
            decisionStatus: .allowed, executionStatus: .completed,
            bindings: .init(ceilingDigest: "sha256:ceiling", packageDigest: "sha256:package"),
            createdAt: "2026-09-09T00:00:00Z"
        )
    }

    // Frozen pre-WP9 shape: deliberately no signature key.
    private static let legacyJSON = #"""
    {"schema":"haven.action-decision-receipt.v1","receiptId":"receipt://fixture/decision-1","intentRef":"intent://fixture/1","contextRef":"context://fixture/1","decisionStatus":"allowed","executionStatus":"completed","authorityPath":"owner_path","checks":{"exactPrimaryPurposeMatch":true,"externalActionCeilingSatisfied":true,"storageDoesNotAuthorizeDisclosure":true,"trustPackageDidNotAuthorize":true,"ownerPathDidNotBypassCeiling":true,"bindingDigestsMatch":true},"bindings":{"purposeDigest":"sha256:purpose","actionDigest":"sha256:action","destinationDigest":"sha256:destination","dataManifestDigest":"sha256:data","planDigest":"sha256:plan","configDigest":"sha256:config","policyDigest":"sha256:policy","taxonomyDigest":"sha256:taxonomy","payloadDigest":"sha256:payload"},"containsSecrets":false,"createdAt":"2026-09-09T00:00:00Z"}
    """#
}

/// In-memory P256 fixture implementing the existing vault protocol, without
/// Keychain or network. Production receipt code imports no crypto primitives.
private actor ReceiptP256FixtureVault: IdentityVaultProtocol {
    private let key = P256.Signing.PrivateKey()
    func initialize() async -> IdentityVaultProtocol { self }
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        let identity = Identity("receipt-p256-fixture", displayName: "Receipt fixture", identityVault: self)
        identity.publicSecureKey = SecureKey(
            date: Date(timeIntervalSince1970: 0), privateKey: false, use: .signature,
            algorithm: .ECDSA, size: 256, curveType: .P256, x: nil, y: nil,
            compressedKey: key.publicKey.x963Representation
        )
        return identity
    }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard identity.uuid == "receipt-p256-fixture",
              identity.publicSecureKey?.compressedKey == key.publicKey.x963Representation else {
            throw IdentityVaultError.signingFailed
        }
        return try key.signature(for: messageData).derRepresentation
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: messageData, identity: identity)
    }
    // The fixture has one fixed identity and no persistence or encryption store.
    func addIdentity(identity: inout Identity, for identityContext: String) async { }
    func saveIdentity(_ identity: Identity) async { }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        throw IdentityVaultError.signingFailed
    }
}
