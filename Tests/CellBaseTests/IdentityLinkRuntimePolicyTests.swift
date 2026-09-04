// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// WP3a: passkey-beviset må kunne følge approveEnrollment-konvolutten, og runtime-policyen
/// som EntityAnchor håndhever må kunne installeres og nullstilles.
final class IdentityLinkRuntimePolicyTests: XCTestCase {
    func testApprovalEnvelopeCarriesFreshAuthEvidenceIntoSignedApproval() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let issuer = await vault.makeIdentity(displayName: "web-on-staging")
        let holder = await vault.makeIdentity(displayName: "haven-app-phone")
        let now = Date()
        let descriptor = try IdentityLinkProtocolService.descriptor(for: holder)
        var request = IdentityEnrollmentRequest(
            requestID: "request-\(UUID().uuidString)",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor", audience: "staging"),
            newIdentity: descriptor,
            requestedDomains: ["private"], requestedIdentityContexts: ["binding"], requestedScopes: [IdentityLinkScope.sameEntity],
            audience: "staging", origin: "https://staging.haven.digipomps.org",
            createdAt: IdentityLinkProtocolService.iso8601(now), expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(600)),
            nonce: Data((0..<32).map(UInt8.init)), platform: "ios", deviceLabel: "HAVEN-appen"
        )
        let payload = try request.canonicalPayloadData()
        let maybeSignature = try await holder.sign(data: payload)
        let signature = try XCTUnwrap(maybeSignature)
        request.proof = IdentityEnrollmentRequestProof(byIdentityUUID: holder.uuid, algorithm: descriptor.algorithm, curveType: descriptor.curveType, signature: signature)
        let hash = try IdentityLinkProtocolService.requestHash(for: request)
        let evidence = IdentityLinkFreshAuthEvidence(method: "webauthn", challenge: hash, performedAt: IdentityLinkProtocolService.iso8601(now), signature: Data([1, 2, 3]))

        let package = try await IdentityLinkProtocolService.approveEnrollment(
            IdentityLinkApprovalEnvelope(request: request, freshAuthEvidence: evidence),
            issuerIdentity: issuer,
            now: now
        )
        XCTAssertEqual(package.approval.freshAuthEvidence, evidence)

        // Beviset ligger i den signerte payloaden: fjernes det, er signaturen ugyldig.
        var tampered = package.approval
        tampered.freshAuthEvidence = nil
        let tamperedPayload = try tampered.canonicalPayloadData()
        XCTAssertNotEqual(tamperedPayload, try package.approval.canonicalPayloadData())
    }

    func testRuntimePolicyInstallAndReset() async {
        let policy = IdentityLinkRuntimePolicy()
        var before = await policy.requireFreshAuthEvidence
        XCTAssertFalse(before)
        await policy.install(requireFreshAuthEvidence: true, freshAuthVerifier: { _ in true })
        before = await policy.requireFreshAuthEvidence
        XCTAssertTrue(before)
        let verifier = await policy.freshAuthVerifier
        XCTAssertNotNil(verifier)
        await policy.reset()
        let after = await policy.requireFreshAuthEvidence
        XCTAssertFalse(after)
    }
}
