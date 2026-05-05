// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentityLinkingModelsTests: XCTestCase {
    func testIdentityLinkCompletionAcceptsBoundCredentialAndRejectsReplay() async throws {
        let fixture = try await makeCompletionFixture(jti: "approval-jti-happy-path")

        let result = try await IdentityLinkProtocolService.verifyCompletion(
            fixture.envelope,
            now: fixture.now
        )

        XCTAssertEqual(result.record.status, .active)
        XCTAssertEqual(result.record.linkID, fixture.envelope.approval.approvalID)
        XCTAssertEqual(result.record.linkedIdentity.uuid, fixture.holder.uuid)
        XCTAssertEqual(result.record.approvedDomains, ["private", "scaffold"])
        XCTAssertEqual(result.approvalJTI, "approval-jti-happy-path")
        XCTAssertEqual(result.credentialID, fixture.envelope.sameEntityCredential.id)
        XCTAssertEqual(result.presentationID, fixture.envelope.presentation.id)

        await assertIdentityLinkCompletionThrows(.replayDetected("approval-jti-happy-path")) {
            _ = try await IdentityLinkProtocolService.verifyCompletion(
                fixture.envelope,
                now: fixture.now,
                usedApprovalJTIs: ["approval-jti-happy-path"]
            )
        }
    }

    func testIdentityLinkCompletionRejectsAudienceMismatch() async throws {
        var fixture = try await makeCompletionFixture(jti: "approval-jti-audience")
        fixture.envelope.expectedAudience = "staging.invalid.example"

        await assertIdentityLinkCompletionThrows(
            .audienceMismatch(expected: "staging.invalid.example", actual: "staging.haven.digipomps.org")
        ) {
            _ = try await IdentityLinkProtocolService.verifyCompletion(
                fixture.envelope,
                now: fixture.now
            )
        }
    }

    func testIdentityLinkCompletionRejectsHolderKeySubstitution() async throws {
        var fixture = try await makeCompletionFixture(jti: "approval-jti-holder")
        let attacker = await fixture.vault.makeIdentity(displayName: "attacker-phone")
        fixture.envelope.presentation = try await IdentityLinkProtocolService.makeVerifierBoundPresentation(
            credential: fixture.envelope.sameEntityCredential,
            holderIdentity: attacker,
            challenge: fixture.presentationChallenge,
            domain: fixture.presentationDomain
        )

        await assertIdentityLinkCompletionThrows(.holderMismatch) {
            _ = try await IdentityLinkProtocolService.verifyCompletion(
                fixture.envelope,
                now: fixture.now
            )
        }
    }

    func testIdentityLinkCompletionRejectsWrongPresentationChallenge() async throws {
        var fixture = try await makeCompletionFixture(jti: "approval-jti-challenge")
        fixture.envelope.expectedPresentationChallenge = Data("different-verifier-challenge".utf8)

        await assertIdentityLinkCompletionThrows(.invalidPresentation) {
            _ = try await IdentityLinkProtocolService.verifyCompletion(
                fixture.envelope,
                now: fixture.now
            )
        }
    }

    func testEnrollmentRequestCanonicalPayloadExcludesProof() throws {
        let request = IdentityEnrollmentRequest(
            requestID: "request-1",
            entityBinding: EntityBindingDescriptor(
                mode: .pairwise,
                bindingID: "binding-1",
                audience: "staging.haven.digipomps.org"
            ),
            newIdentity: IdentityPublicKeyDescriptor(
                uuid: "identity-1",
                displayName: "Kjetil iPhone",
                publicKey: Data([0x01, 0x02, 0x03]),
                algorithm: .EdDSA,
                curveType: .Curve25519
            ),
            requestedDomains: ["private"],
            requestedIdentityContexts: ["private"],
            requestedScopes: ["entity-auth"],
            audience: "staging.haven.digipomps.org",
            origin: "haven://binding/add-device",
            createdAt: "2026-03-22T10:15:00Z",
            expiresAt: "2026-03-22T10:20:00Z",
            nonce: Data([0xAA, 0xBB, 0xCC]),
            platform: "ios",
            deviceLabel: "Kjetil iPhone",
            proof: IdentityEnrollmentRequestProof(
                byIdentityUUID: "identity-1",
                algorithm: .EdDSA,
                curveType: .Curve25519,
                signature: Data([0x10, 0x20])
            )
        )

        let canonical = try request.canonicalPayloadData()
        let canonicalObject = try JSONSerialization.jsonObject(with: canonical, options: []) as? [String: Any]

        XCTAssertNotNil(canonicalObject)
        XCTAssertNil(canonicalObject?["proof"])
        XCTAssertEqual(canonicalObject?["requestID"] as? String, "request-1")
    }

    func testEnrollmentApprovalCanonicalPayloadExcludesProof() throws {
        let approval = IdentityEnrollmentApproval(
            approvalID: "approval-1",
            requestHash: Data([0x01, 0x02]),
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor"),
            subjectIdentity: IdentityPublicKeyDescriptor(
                uuid: "identity-1",
                publicKey: Data([0x01, 0x02, 0x03]),
                algorithm: .ECDSA,
                curveType: .secp256k1
            ),
            approvedDomains: ["private", "scaffold"],
            approvedIdentityContexts: ["private", "scaffold"],
            approvedScopes: ["entity-auth", "personal-cells"],
            issuerIdentityUUID: "issuer-1",
            issuerType: .custodian,
            audience: "staging.haven.digipomps.org",
            origin: "https://staging.haven.digipomps.org",
            createdAt: "2026-03-22T10:16:00Z",
            expiresAt: "2026-03-22T10:21:00Z",
            jti: "jti-1",
            freshAuthRequired: true,
            freshAuthMethod: "biometric_or_passkey",
            freshAuthPerformedAt: "2026-03-22T10:16:00Z",
            proof: IdentityEnrollmentApprovalProof(
                issuerIdentityUUID: "issuer-1",
                issuerType: .custodian,
                algorithm: .ECDSA,
                curveType: .secp256k1,
                signature: Data([0xAB])
            )
        )

        let canonical = try approval.canonicalPayloadData()
        let canonicalObject = try JSONSerialization.jsonObject(with: canonical, options: []) as? [String: Any]

        XCTAssertNotNil(canonicalObject)
        XCTAssertNil(canonicalObject?["proof"])
        XCTAssertEqual(canonicalObject?["issuerIdentityUUID"] as? String, "issuer-1")
    }

    func testSameEntityCredentialSubjectRoundTrips() throws {
        let subject = SameEntityIdentityLinkCredentialSubject(
            id: "did:key:zExampleTargetDid",
            entityBinding: EntityBindingDescriptor(
                mode: .pairwise,
                bindingID: "pairwise-binding-1",
                audience: "staging.haven.digipomps.org"
            ),
            linkedIdentity: IdentityPublicKeyDescriptor(
                uuid: "identity-1",
                displayName: "Kjetil iPhone",
                publicKey: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                algorithm: .EdDSA,
                curveType: .Curve25519
            ),
            approvedDomains: ["private", "scaffold"],
            approvedIdentityContexts: ["private", "scaffold"],
            approvedScopes: ["entity-auth"],
            enrollmentRequestHash: Data([0x12, 0x34]),
            assuranceSource: "fresh_auth_and_possession",
            assuranceLevel: "high",
            validUntil: "2026-03-22T10:21:00Z",
            revocationReference: "cell:///EntityAnchor/proofs/identityLinks/1"
        )

        let encoded = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(SameEntityIdentityLinkCredentialSubject.self, from: encoded)

        XCTAssertEqual(decoded, subject)
    }

    func testChatCryptoSuiteRequiresAgilityMetadata() {
        XCTAssertEqual(ContentCryptoSuite.chatMessageV1.purpose, .chatMessage)
        XCTAssertEqual(ContentCryptoSuite.chatMessageV1.contentAlgorithm, .chachaPoly)
        XCTAssertEqual(ContentCryptoSuite.chatMessageV1.keyAgreementAlgorithm, .x25519HKDFSHA256)
        XCTAssertEqual(ContentCryptoSuite.chatMessageV1.keyWrappingAlgorithm, .x25519SharedSecret)
        XCTAssertTrue(ContentCryptoSuite.chatMessageV1.requiresSenderSignature)
        XCTAssertTrue(ContentCryptoSuite.chatMessageV1.supportsForwardSecrecy)
    }

    func testContentCryptoPolicyDefaultsToExplicitSuiteSelection() {
        let policy = ContentCryptoPolicy.chatDefault

        XCTAssertEqual(policy.preferredSuiteID, ContentCryptoSuite.chatMessageV1.id)
        XCTAssertEqual(policy.acceptedSuiteIDs, [ContentCryptoSuite.chatMessageV1.id])
        XCTAssertFalse(policy.allowLegacyFallback)
    }

    private struct CompletionFixture {
        var vault: OrganizerAccessTestIdentityVault
        var issuer: Identity
        var holder: Identity
        var envelope: IdentityLinkCompletionEnvelope
        var now: Date
        var presentationChallenge: Data
        var presentationDomain: String
    }

    private func makeCompletionFixture(jti: String) async throws -> CompletionFixture {
        let vault = OrganizerAccessTestIdentityVault()
        let issuer = await vault.makeIdentity(displayName: "existing-binding-device")
        let holder = await vault.makeIdentity(displayName: "binding-phone")
        let now = Date()
        let presentationChallenge = Data("verifier-challenge-32-bytes-2026".utf8)
        let presentationDomain = "staging.haven.digipomps.org"
        let request = try await makeSignedEnrollmentRequest(
            holder: holder,
            now: now,
            expiresAt: now.addingTimeInterval(600)
        )
        let approval = try await IdentityLinkProtocolService.approveEnrollmentRequest(
            request,
            issuerIdentity: issuer,
            issuerType: .existingDevice,
            createdAt: now,
            expiresAt: now.addingTimeInterval(300),
            jti: jti,
            freshAuthRequired: true,
            freshAuthPerformedAt: now
        )
        let credential = try await IdentityLinkProtocolService.issueSameEntityCredential(
            request: request,
            approval: approval,
            issuerIdentity: issuer,
            validUntil: now.addingTimeInterval(600),
            revocationReference: "cell:///EntityAnchor/proofs/identityLinks/\(approval.approvalID)"
        )
        let presentation = try await IdentityLinkProtocolService.makeVerifierBoundPresentation(
            credential: credential,
            holderIdentity: holder,
            challenge: presentationChallenge,
            domain: presentationDomain
        )
        let envelope = IdentityLinkCompletionEnvelope(
            request: request,
            approval: approval,
            sameEntityCredential: credential,
            presentation: presentation,
            issuerIdentity: try IdentityLinkProtocolService.descriptor(for: issuer),
            expectedAudience: request.audience,
            expectedOrigin: request.origin,
            expectedPresentationChallenge: presentationChallenge,
            expectedPresentationDomain: presentationDomain
        )
        return CompletionFixture(
            vault: vault,
            issuer: issuer,
            holder: holder,
            envelope: envelope,
            now: now,
            presentationChallenge: presentationChallenge,
            presentationDomain: presentationDomain
        )
    }

    private func makeSignedEnrollmentRequest(
        holder: Identity,
        now: Date,
        expiresAt: Date
    ) async throws -> IdentityEnrollmentRequest {
        let descriptor = try IdentityLinkProtocolService.descriptor(for: holder)
        var request = IdentityEnrollmentRequest(
            requestID: "request-\(UUID().uuidString)",
            entityBinding: EntityBindingDescriptor(
                mode: .localEntityAnchor,
                entityAnchorReference: "cell:///EntityAnchor",
                audience: "staging.haven.digipomps.org"
            ),
            newIdentity: descriptor,
            requestedDomains: ["private", "scaffold"],
            requestedIdentityContexts: ["private", "scaffold"],
            requestedScopes: ["entity-auth", "personal-cells"],
            audience: "staging.haven.digipomps.org",
            origin: "haven://binding/add-device",
            createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(expiresAt),
            nonce: Data((0..<32).map(UInt8.init)),
            platform: "ios",
            deviceLabel: "Binding phone"
        )
        let payload = try request.canonicalPayloadData()
        guard let signature = try await holder.sign(data: payload) else {
            throw TestError.signingFailed
        }
        request.proof = IdentityEnrollmentRequestProof(
            byIdentityUUID: holder.uuid,
            algorithm: descriptor.algorithm,
            curveType: descriptor.curveType,
            signature: signature
        )
        return request
    }

    private func assertIdentityLinkCompletionThrows(
        _ expected: IdentityLinkCompletionError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected IdentityLinkCompletionError.\(expected)", file: file, line: line)
        } catch let error as IdentityLinkCompletionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected IdentityLinkCompletionError.\(expected), got \(error)", file: file, line: line)
        }
    }

    private enum TestError: Error {
        case signingFailed
    }
}
