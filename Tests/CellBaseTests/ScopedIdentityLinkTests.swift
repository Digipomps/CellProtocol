// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// PDD egen-agent-mcp, WP3 + WP4 (planbytte 1): avgrenset lenke og RecipientCondition.
/// test.egen-agent.connect, test.egen-agent.auth-negative, test.egen-agent.recipient.
final class ScopedIdentityLinkTests: XCTestCase {
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

    // MARK: - Ordforrådet

    func testPolicyParsesAndFailsClosed() {
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        let grant = ScopedIdentityLinkPolicy.ScopeGrant(permission: "r---", cellUUID: "cell-a", keypath: "documents.list")
        let scopes = ScopedIdentityLinkPolicy.scopes(grants: [grant], recipient: "anthropic", expiresAt: expires, deviceLabel: "Laptop")
        let policy = try? XCTUnwrap(ScopedIdentityLinkPolicy(approvedScopes: scopes))
        XCTAssertEqual(policy?.grants, [grant])
        XCTAssertEqual(policy?.recipient, "anthropic")
        XCTAssertEqual(policy?.expiresAt, expires)
        XCTAssertEqual(policy?.deviceLabel, "Laptop")
        XCTAssertFalse(IdentityLinkScope.grantsSameEntity(scopes))

        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: scopes + [IdentityLinkScope.sameEntity]), "hel og avgrenset samtidig skal ikke gi noe")
        XCTAssertFalse(IdentityLinkScope.grantsSameEntity(scopes + [IdentityLinkScope.sameEntity]), "avgrensning gjør aldri en lenke hel")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: scopes + ["scope.unknown:x"]), "ukjent avgrensning feiler lukket")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: scopes + ["scope.recipient:openai"]), "to mottakere feiler lukket")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: scopes.filter { !$0.hasPrefix("scope.expires:") }), "utløp er påkrevd")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: scopes.filter { !$0.hasPrefix("scope.grant:") }), "minst én tillatelse")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: ["scoped", "scope.grant:rw:cell-a:x", "scope.recipient:local", "scope.expires:2030-01-01T00:00:00Z"]), "tillatelse må være fire tegn")
        XCTAssertNil(ScopedIdentityLinkPolicy(approvedScopes: Array(scopes.dropFirst())), "markøren er påkrevd")
        XCTAssertTrue(IdentityLinkScope.grantsSameEntity([IdentityLinkScope.sameEntity]), "hel lenke er uendret")
    }

    func testRecipientConditionRoundTripsInAgreement() async throws {
        let agreement = await Agreement()
        agreement.conditions = [RecipientCondition(allowedRecipients: ["openai", "local", "openai"])]
        let data = try JSONEncoder().encode(agreement)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"recipient\""), json)
        let decoded = try JSONDecoder().decode(Agreement.self, from: data)
        let condition = try XCTUnwrap(decoded.conditions.first as? RecipientCondition)
        XCTAssertEqual(condition.allowedRecipients, ["local", "openai"])
    }

    // MARK: - Tilgangsavgjørelsen

    func testScopedLinkReadsOnlyWhatTheLinkAndRecipientAllow() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "claude-code-laptop")
        let documents = await makeCell(owner: student, recipients: ["anthropic", "local"])
        let notes = await makeCell(owner: student, recipients: ["anthropic"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }

        let link = try await linkAgent(agent, to: student, domain: documents.identityDomain, grants: [
            .init(permission: "r---", cellUUID: documents.uuid, keypath: "documents.list"),
        ], recipient: "anthropic")

        let allowed = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertTrue(allowed.allowed, allowed.reason)
        XCTAssertEqual(allowed.path, .scopedIdentityLink)
        XCTAssertEqual(allowed.reasonCode, "scoped_identity_link")
        let value = try await documents.get(keypath: "documents.list", requester: agent)
        XCTAssertEqual(value, .string("list"))

        do {
            _ = try await documents.get(keypath: "documents.secret", requester: agent)
            XCTFail("nøkkelsti utenfor lenken skal avvises")
        } catch {}
        let otherKeypath = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.secret", for: agent)
        XCTAssertFalse(otherKeypath.allowed)
        XCTAssertEqual(otherKeypath.reasonCode, "link_scope_missing")

        let write = await documents.authorizationDecision(requestedAccess: "-w--", at: "documents.list", for: agent)
        XCTAssertFalse(write.allowed, "lesetillatelse gir ikke skriving")
        XCTAssertEqual(write.reasonCode, "link_scope_missing")

        let otherCell = await notes.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(otherCell.allowed, "en celle som ikke står i lenken er stengt, selv om studenten eier den")
        XCTAssertEqual(otherCell.reasonCode, "link_scope_missing")

        let admitted = await documents.hasScopedLinkAdmission(for: agent)
        let notAdmitted = await notes.hasScopedLinkAdmission(for: agent)
        XCTAssertTrue(admitted)
        XCTAssertFalse(notAdmitted)
        XCTAssertEqual(link.record.status, .active)
    }

    func testScopedLinkNeverGivesOwnerPower() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "codex-laptop")
        let documents = await makeCell(owner: student, recipients: ["openai"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }
        _ = try await linkAgent(agent, to: student, domain: documents.identityDomain, grants: [
            .init(permission: "r---", cellUUID: documents.uuid, keypath: "documents.list"),
        ], recipient: "openai")

        let state = await documents.determineIdentityState(identity: agent)
        XCTAssertNotEqual(state, .owner)
        do {
            try await documents.requireOwnerAttachProof(requester: agent)
            XCTFail("avgrenset lenke må aldri gi eierbevis")
        } catch {}
    }

    func testRecipientMustBeAllowedByTheCellsAgreement() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "claude-code-laptop")
        let noCondition = await makeCell(owner: student, recipients: nil)
        let localOnly = await makeCell(owner: student, recipients: ["local"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }
        _ = try await linkAgent(agent, to: student, domain: noCondition.identityDomain, grants: [
            .init(permission: "r---", cellUUID: noCondition.uuid, keypath: "documents.list"),
            .init(permission: "r---", cellUUID: localOnly.uuid, keypath: "documents.list"),
        ], recipient: "anthropic")

        let closed = await noCondition.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(closed.allowed, "celle uten RecipientCondition er stengt for agenter")
        XCTAssertEqual(closed.reasonCode, "recipient_not_allowed")

        let wrongRecipient = await localOnly.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(wrongRecipient.allowed)
        XCTAssertEqual(wrongRecipient.reasonCode, "recipient_not_allowed")
        XCTAssertEqual(wrongRecipient.path, .deniedScopedIdentityLink)
    }

    func testExpiryAndRevocationStopTheNextCall() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "claude-code-laptop")
        let documents = await makeCell(owner: student, recipients: ["anthropic"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }
        let expiresAt = Date().addingTimeInterval(3600)
        let link = try await linkAgent(agent, to: student, domain: documents.identityDomain, grants: [
            .init(permission: "r---", cellUUID: documents.uuid, keypath: "documents.list"),
        ], recipient: "anthropic", expiresAt: expiresAt)

        documents.authorizationClock = { expiresAt.addingTimeInterval(1) }
        let expired = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(expired.allowed)
        XCTAssertEqual(expired.reasonCode, "extension_expired")
        let expiredAdmission = await documents.hasScopedLinkAdmission(for: agent)
        XCTAssertFalse(expiredAdmission)

        documents.authorizationClock = Date.init
        await IdentityLinkRegistry.shared.revoke(
            ownerUUID: student.uuid, linkID: link.record.linkID, revokedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        let revoked = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(revoked.allowed)
        XCTAssertEqual(revoked.reasonCode, "extension_revoked")
    }

    func testScopedLinkWithoutKeyControlIsDenied() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "claude-code-laptop")
        let documents = await makeCell(owner: student, recipients: ["anthropic"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }
        let link = try await linkAgent(agent, to: student, domain: documents.identityDomain, grants: [
            .init(permission: "r---", cellUUID: documents.uuid, keypath: "documents.list"),
        ], recipient: "anthropic")

        let impostor = IdentityLinkProtocolService.identity(from: link.record.linkedIdentity)
        let decision = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: impostor)
        XCTAssertFalse(decision.allowed, "samme UUID og nøkkel uten privatnøkkelen skal avvises")
        XCTAssertNotEqual(decision.path, .scopedIdentityLink)
    }

    func testOwnerMayApproveFewerScopesButNeverTurnAScopedRequestWhole() async throws {
        let student = await vault.makeIdentity(displayName: "student")
        let agent = await vault.makeIdentity(displayName: "claude-code-laptop")
        let documents = await makeCell(owner: student, recipients: ["anthropic"])
        defer { Task { await IdentityLinkRegistry.shared.clear(ownerUUID: student.uuid) } }
        let requested = ScopedIdentityLinkPolicy.scopes(grants: [
            .init(permission: "r---", cellUUID: documents.uuid, keypath: "documents.list"),
        ], recipient: "anthropic", expiresAt: Date().addingTimeInterval(3600))
        // Eieren godkjenner uten utløp: lenken kan da ikke leses som avgrenset, og er heller ikke hel.
        let completion = try await makeVerifiedCompletion(
            issuer: student, holder: agent, domains: [documents.identityDomain],
            requestedScopes: requested, approvedScopes: requested.filter { !$0.hasPrefix("scope.expires:") }
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: student.uuid, completion: completion)
        let decision = await documents.authorizationDecision(requestedAccess: "r---", at: "documents.list", for: agent)
        XCTAssertFalse(decision.allowed)
        XCTAssertNotEqual(decision.path, .ownerProof)
    }

    // MARK: - Hjelpere

    private func makeCell(owner: Identity, recipients: [String]?) async -> GeneralCell {
        let cell = await GeneralCell(owner: owner)
        // Eksakte nøkkelstier, så tilgangen avgjøres på hele stien (som for Grant i kontrakter).
        await cell.addInterceptForGet(requester: owner, key: "documents.list") { _, _ in .string("list") }
        await cell.addInterceptForGet(requester: owner, key: "documents.secret") { _, _ in .string("secret") }
        if let recipients {
            cell.agreementTemplate.conditions.append(RecipientCondition(allowedRecipients: recipients))
        }
        return cell
    }

    @discardableResult
    private func linkAgent(
        _ agent: Identity,
        to owner: Identity,
        domain: String,
        grants: [ScopedIdentityLinkPolicy.ScopeGrant],
        recipient: String,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) async throws -> IdentityLinkCompletionResult {
        let scopes = ScopedIdentityLinkPolicy.scopes(grants: grants, recipient: recipient, expiresAt: expiresAt, deviceLabel: "Laptop")
        let completion = try await makeVerifiedCompletion(
            issuer: owner, holder: agent, domains: [domain], requestedScopes: scopes, approvedScopes: scopes
        )
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: completion)
        return completion
    }

    private func makeVerifiedCompletion(
        issuer: Identity, holder: Identity, domains: [String], requestedScopes: [String], approvedScopes: [String]
    ) async throws -> IdentityLinkCompletionResult {
        let now = Date()
        let descriptor = try IdentityLinkProtocolService.descriptor(for: holder)
        var request = IdentityEnrollmentRequest(
            requestID: "request-\(UUID().uuidString)",
            entityBinding: EntityBindingDescriptor(
                mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor", audience: "staging.haven.digipomps.org"
            ),
            newIdentity: descriptor,
            requestedDomains: domains,
            requestedIdentityContexts: ["own-agent"],
            requestedScopes: requestedScopes,
            audience: "staging.haven.digipomps.org",
            origin: "https://staging.haven.digipomps.org",
            createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(600)),
            nonce: Data((0..<32).map(UInt8.init)),
            platform: "macos",
            deviceLabel: "Laptop"
        )
        let payload = try request.canonicalPayloadData()
        let maybeSignature = try await holder.sign(data: payload)
        let signature = try XCTUnwrap(maybeSignature)
        request.proof = IdentityEnrollmentRequestProof(
            byIdentityUUID: holder.uuid, algorithm: descriptor.algorithm, curveType: descriptor.curveType, signature: signature
        )
        let approval = try await IdentityLinkProtocolService.approveEnrollmentRequest(
            request, issuerIdentity: issuer, approvedScopes: approvedScopes,
            createdAt: now, expiresAt: now.addingTimeInterval(300), jti: "jti-\(UUID().uuidString)"
        )
        let credential = try await IdentityLinkProtocolService.issueSameEntityCredential(
            request: request, approval: approval, issuerIdentity: issuer, validUntil: now.addingTimeInterval(600), revocationReference: nil
        )
        let challenge = Data("verifier-challenge-32-bytes-2026".utf8)
        let presentation = try await IdentityLinkProtocolService.makeVerifierBoundPresentation(
            credential: credential, holderIdentity: holder, challenge: challenge, domain: "staging.haven.digipomps.org"
        )
        return try await IdentityLinkProtocolService.verifyCompletion(IdentityLinkCompletionEnvelope(
            request: request, approval: approval, sameEntityCredential: credential, presentation: presentation,
            issuerIdentity: try IdentityLinkProtocolService.descriptor(for: issuer),
            expectedAudience: request.audience, expectedOrigin: request.origin,
            expectedPresentationChallenge: challenge, expectedPresentationDomain: "staging.haven.digipomps.org"
        ))
    }
}
