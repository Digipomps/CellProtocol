// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// purpose://candidate.entity-link.resolver-honours-link — WP2.
/// test.resolver.linked-identity-reads, test.resolver.revoked-link-denied,
/// test.resolver.scope-fails-closed, test.security.server-cannot-mint-link.
final class IdentityLinkRegistryTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private let vault = OrganizerAccessTestIdentityVault()

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = vault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testLinkedIdentityReadsAsOwnerAndRevocationDeniesAgain() async throws {
        let owner = await vault.makeIdentity(displayName: "web-on-staging")
        let phone = await vault.makeIdentity(displayName: "haven-app-phone")
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("owner only") }
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid) } }

        let before = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: phone)
        XCTAssertFalse(before.allowed)
        XCTAssertEqual(before.path, .deniedNoGrant)

        let completion = try await makeVerifiedCompletion(
            issuer: owner, holder: phone, domains: [cell.identityDomain], scopes: [IdentityLinkScope.sameEntity]
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: completion)

        let after = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: phone)
        XCTAssertTrue(after.allowed, after.reason)
        XCTAssertEqual(after.path, .ownerProof)
        XCTAssertEqual(after.reasonCode, "linked_identity_proof")
        let value = try await cell.get(keypath: "secret", requester: phone)
        XCTAssertEqual(value, .string("owner only"))

        await IdentityLinkRegistry.shared.revoke(
            ownerUUID: owner.uuid, linkID: completion.record.linkID, revokedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        let revoked = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: phone)
        XCTAssertFalse(revoked.allowed)
        XCTAssertEqual(revoked.path, .deniedNoGrant)
    }

    func testScopeAndDomainFailClosed() async throws {
        let owner = await vault.makeIdentity(displayName: "web-on-staging")
        let phone = await vault.makeIdentity(displayName: "haven-app-phone")
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("owner only") }
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid) } }

        let wrongScope = try await makeVerifiedCompletion(
            issuer: owner, holder: phone, domains: [cell.identityDomain], scopes: ["read-calendar"]
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: wrongScope)
        let scopeDecision = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: phone)
        XCTAssertFalse(scopeDecision.allowed, "scope utenfor same_entity må feile lukket")

        await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
        let wrongDomain = try await makeVerifiedCompletion(
            issuer: owner, holder: phone, domains: ["some-other-domain"], scopes: [IdentityLinkScope.sameEntity]
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: wrongDomain)
        let domainDecision = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: phone)
        XCTAssertFalse(domainDecision.allowed, "domene som ikke står i approvedDomains må feile lukket")
    }

    func testStolenLinkRecordWithoutKeyControlIsDenied() async throws {
        // En angriper som kjenner telefonens UUID og offentlige nøkkel, men ikke privatnøkkelen.
        let owner = await vault.makeIdentity(displayName: "web-on-staging")
        let phone = await vault.makeIdentity(displayName: "haven-app-phone")
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("owner only") }
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid) } }

        let completion = try await makeVerifiedCompletion(
            issuer: owner, holder: phone, domains: [cell.identityDomain], scopes: [IdentityLinkScope.sameEntity]
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: completion)

        let impostor = IdentityLinkProtocolService.identity(from: completion.record.linkedIdentity)
        let decision = await cell.authorizationDecision(requestedAccess: "r---", at: "secret", for: impostor)
        XCTAssertFalse(decision.allowed, "samme UUID og nøkkel uten kontroll over privatnøkkelen skal avvises")
    }

    func testServerCannotMintLinkWhenPolicyRequiresFreshAuthEvidence() async throws {
        // test.security.server-cannot-mint-link: en approval signert av utstedernøkkelen alene,
        // uten passkey-bevis, gir ingen completion — og dermed ingenting å registrere.
        let owner = await vault.makeIdentity(displayName: "scaffold-held-web-key")
        let phone = await vault.makeIdentity(displayName: "haven-app-phone")
        var envelope = try await makeEnvelope(issuer: owner, holder: phone, domains: ["private"], scopes: [IdentityLinkScope.sameEntity])
        envelope.requireFreshAuthEvidence = true
        do {
            _ = try await IdentityLinkProtocolService.verifyCompletion(envelope, freshAuthVerifier: { _ in true })
            XCTFail("approval uten freshAuthEvidence må avvises når policyen krever det")
        } catch let error as IdentityLinkCompletionError {
            XCTAssertEqual(error, .missingFreshAuth)
        }
        let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: owner.uuid)
        XCTAssertTrue(links.isEmpty)
    }

    // MARK: - Helpers

    private func makeVerifiedCompletion(
        issuer: Identity, holder: Identity, domains: [String], scopes: [String]
    ) async throws -> IdentityLinkCompletionResult {
        let envelope = try await makeEnvelope(issuer: issuer, holder: holder, domains: domains, scopes: scopes)
        return try await IdentityLinkProtocolService.verifyCompletion(envelope)
    }

    private func makeEnvelope(
        issuer: Identity, holder: Identity, domains: [String], scopes: [String]
    ) async throws -> IdentityLinkCompletionEnvelope {
        let now = Date()
        let descriptor = try IdentityLinkProtocolService.descriptor(for: holder)
        var request = IdentityEnrollmentRequest(
            requestID: "request-\(UUID().uuidString)",
            entityBinding: EntityBindingDescriptor(
                mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor", audience: "staging.haven.digipomps.org"
            ),
            newIdentity: descriptor,
            requestedDomains: domains,
            requestedIdentityContexts: ["binding"],
            requestedScopes: scopes,
            audience: "staging.haven.digipomps.org",
            origin: "https://staging.haven.digipomps.org",
            createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(600)),
            nonce: Data((0..<32).map(UInt8.init)),
            platform: "ios",
            deviceLabel: "HAVEN-appen"
        )
        let payload = try request.canonicalPayloadData()
        let maybeSignature = try await holder.sign(data: payload)
        let signature = try XCTUnwrap(maybeSignature)
        request.proof = IdentityEnrollmentRequestProof(
            byIdentityUUID: holder.uuid, algorithm: descriptor.algorithm, curveType: descriptor.curveType, signature: signature
        )
        let approval = try await IdentityLinkProtocolService.approveEnrollmentRequest(
            request, issuerIdentity: issuer, createdAt: now, expiresAt: now.addingTimeInterval(300), jti: "jti-\(UUID().uuidString)"
        )
        let credential = try await IdentityLinkProtocolService.issueSameEntityCredential(
            request: request, approval: approval, issuerIdentity: issuer, validUntil: now.addingTimeInterval(600), revocationReference: nil
        )
        let challenge = Data("verifier-challenge-32-bytes-2026".utf8)
        let presentation = try await IdentityLinkProtocolService.makeVerifierBoundPresentation(
            credential: credential, holderIdentity: holder, challenge: challenge, domain: "staging.haven.digipomps.org"
        )
        return IdentityLinkCompletionEnvelope(
            request: request, approval: approval, sameEntityCredential: credential, presentation: presentation,
            issuerIdentity: try IdentityLinkProtocolService.descriptor(for: issuer),
            expectedAudience: request.audience, expectedOrigin: request.origin,
            expectedPresentationChallenge: challenge, expectedPresentationDomain: "staging.haven.digipomps.org"
        )
    }
}
