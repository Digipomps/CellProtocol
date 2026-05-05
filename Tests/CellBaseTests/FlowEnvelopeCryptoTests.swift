// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class FlowEnvelopeCryptoTests: XCTestCase {
    private func makeEnvelope(identity: Identity) throws -> FlowEnvelope {
        let payload = FlowElement(
            id: "crypto-1",
            title: "crypto.event",
            content: .string("hello"),
            properties: .init(type: .event, contentType: .string)
        )

        return try FlowEnvelope(
            streamId: "stream-crypto",
            sequence: 1,
            domain: "private",
            producerCell: "cell://origin",
            producerIdentity: identity.uuid,
            payload: payload
        )
    }

    func testSignAndVerifyEnvelopeWithProvenance() async throws {
        let vault = MockIdentityVault()
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let envelope = try makeEnvelope(identity: identity)

        let signed = try await FlowEnvelopeSigner.sign(
            envelope,
            with: identity,
            ensureProvenance: true,
            signProvenance: true
        )

        XCTAssertNotNil(signed.signature)
        XCTAssertEqual(signed.signatureKeyId, identity.uuid)
        XCTAssertNotNil(signed.provenance)
        XCTAssertNotNil(signed.provenance?.originSignature)

        let verified = try await FlowEnvelopeVerifier.verify(
            signed,
            producerIdentity: identity,
            requireProvenanceSignature: true
        )
        XCTAssertTrue(verified)
    }

    func testVerifyFailsWhenPayloadIsTampered() async throws {
        let vault = MockIdentityVault()
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let envelope = try makeEnvelope(identity: identity)
        let signed = try await FlowEnvelopeSigner.sign(envelope, with: identity)

        var tampered = signed
        tampered.payload = FlowElement(
            id: "crypto-1",
            title: "crypto.event",
            content: .string("tampered"),
            properties: .init(type: .event, contentType: .string)
        )

        do {
            _ = try await FlowEnvelopeVerifier.verify(tampered, producerIdentity: identity)
            XCTFail("Expected payload tampering to fail")
        } catch let error as FlowIntegrityError {
            switch error {
            case .payloadHashMismatch:
                break
            default:
                XCTFail("Expected payloadHashMismatch, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testVerifyFailsWithWrongProducerIdentity() async throws {
        let vault = MockIdentityVault()
        let producer = await vault.identity(for: "producer", makeNewIfNotFound: true)!
        let wrongIdentity = await vault.identity(for: "wrong", makeNewIfNotFound: true)!
        let envelope = try makeEnvelope(identity: producer)

        let signed = try await FlowEnvelopeSigner.sign(envelope, with: producer)

        do {
            _ = try await FlowEnvelopeVerifier.verify(signed, producerIdentity: wrongIdentity)
            XCTFail("Expected signature verification to fail with wrong identity")
        } catch let error as FlowIntegrityError {
            XCTAssertEqual(error, .invalidProducerSignature)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testVerifyFailsWhenProvenanceIsTampered() async throws {
        let vault = MockIdentityVault()
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let envelope = try makeEnvelope(identity: identity)

        let signed = try await FlowEnvelopeSigner.sign(
            envelope,
            with: identity,
            ensureProvenance: true,
            signProvenance: true
        )

        var tampered = signed
        if var provenance = tampered.provenance {
            provenance.originCell = "cell://attacker"
            tampered.provenance = provenance
        }

        do {
            _ = try await FlowEnvelopeVerifier.verify(
                tampered,
                producerIdentity: identity,
                requireProvenanceSignature: true
            )
            XCTFail("Expected tampered provenance signature to fail")
        } catch let error as FlowIntegrityError {
            XCTAssertEqual(error, .invalidProvenanceSignature)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
