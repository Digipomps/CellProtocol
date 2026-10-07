// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@_spi(HAVENRuntime) @testable import CellBase

final class OwnerReferenceReadinessTests: XCTestCase {
    private let vault = ReadinessTestIdentityVault()
    private var previousVault: IdentityVaultProtocol?
    private var previousDebug = false
    private var previousSink: CellSecurityEventSink?
    private let sink = InMemoryCellSecurityEventSink()

    override func setUp() {
        super.setUp()
        previousSink = CellBase.securityEventSink
        CellBase.securityEventSink = sink
        previousVault = CellBase.defaultIdentityVault
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.defaultIdentityVault = vault
        CellBase.debugValidateAccessForEverything = false
    }
    override func tearDown() {
        CellBase.securityEventSink = previousSink
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebug
        super.tearDown()
    }
    private func fixture() async throws -> (Identity, ReadinessRefusalProbeCell, Identity) {
        let owner = await vault.makeIdentity(displayName: "owner")
        let foreignVault = ReadinessTestIdentityVault()
        let impostor = await foreignVault.makeIdentity(displayName: "impostor", uuid: owner.uuid)
        let source = await ReadinessRefusalProbeCell(owner: owner)
        let decoded = try JSONDecoder().decode(ReadinessRefusalProbeCell.self, from: JSONEncoder().encode(source))
        return (owner, decoded, impostor)
    }
    private func assertDenied(_ operation: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected reference denial", file: file, line: line) }
        catch CellAuthorizationError.denied(let decision) {
            XCTAssertFalse(decision.allowed, file: file, line: line)
            XCTAssertEqual(decision.path, .deniedIdentityReferenceMismatch, file: file, line: line)
        } catch { XCTFail("Wrong refusal: \(error)", file: file, line: line) }
    }
    func testDecodedGetAndSetRejectBeforeFailClosedReadinessWithoutMutation() async throws {
        let (_, cell, impostor) = try await fixture()
        await assertDenied { _ = try await cell.get(keypath: "probe", requester: impostor) }
        await assertDenied { _ = try await cell.set(keypath: "probe", value: .string("changed"), requester: impostor) }
        XCTAssertEqual(cell.installations, 0)
        XCTAssertEqual(cell.writes, 0)
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.reasonCode == "identity_public_key_mismatch" })
    }
    func testDebugBypassCannotDisableReferencePreflight() async throws {
        CellBase.debugValidateAccessForEverything = true
        let (_, cell, impostor) = try await fixture()
        await assertDenied { _ = try await cell.get(keypath: "probe", requester: impostor) }
        await assertDenied { _ = try await cell.set(keypath: "probe", value: .string("changed"), requester: impostor) }
        XCTAssertEqual(cell.installations, 0)
        XCTAssertEqual(cell.writes, 0)
    }
    func testProvenOwnerRunsReadinessAndReads() async throws {
        let (owner, cell, _) = try await fixture()
        let bound = await cell.bindStoredOwnerToRuntimeIdentity(owner)
        XCTAssertTrue(bound)
        let value = try await cell.get(keypath: "probe", requester: owner)
        XCTAssertEqual(value, .string("ready"))
        XCTAssertEqual(cell.installations, 1)
    }
    func testOtherUUIDWithoutGrantStillDeniedNoGrant() async throws {
        let (owner, cell, _) = try await fixture()
        _ = await cell.bindStoredOwnerToRuntimeIdentity(owner)
        let outsider = await vault.makeIdentity(displayName: "outsider")
        do { _ = try await cell.get(keypath: "probe", requester: outsider); XCTFail("Expected no grant") }
        catch CellAuthorizationError.denied(let decision) { XCTAssertEqual(decision.path, .deniedNoGrant) }
        XCTAssertEqual(cell.installations, 1)
    }
    func testVerifiedLinkedIdentityStillReadsAfterReadiness() async throws {
        let (owner, cell, _) = try await fixture()
        _ = await cell.bindStoredOwnerToRuntimeIdentity(owner)
        let holder = await vault.makeIdentity(displayName: "linked")
        let completion = try await makeVerifiedCompletion(issuer: owner, holder: holder,
            domains: [cell.identityDomain], scopes: [IdentityLinkScope.sameEntity])
        await IdentityLinkRegistry.shared.register(ownerUUID: owner.uuid, completion: completion)
        do {
            let value = try await cell.get(keypath: "probe", requester: holder)
            XCTAssertEqual(value, .string("ready"))
        } catch {
            await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
            throw error
        }
        await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
        XCTAssertEqual(cell.installations, 1)
    }
    func testExploreFlowAdvertiseAndStateRejectBeforeReadiness() async throws {
        let (_, cell, impostor) = try await fixture()
        await assertDenied { _ = try await cell.keys(requester: impostor) }
        await assertDenied { _ = try await cell.typeForKey(key: "probe", requester: impostor) }
        await assertDenied { _ = try await cell.contract(for: "probe", method: .get, requester: impostor) }
        await assertDenied { _ = try await cell.operationContracts(requester: impostor) }
        await assertDenied { _ = try await cell.schemaDescriptionForKey(key: "probe", requester: impostor) }
        await assertDenied { _ = try await cell.flow(requester: impostor) }
        await assertDenied { _ = try await cell.advertise(for: impostor) }
        await assertDenied { _ = try await cell.state(requester: impostor) }
        let admitted = await cell.admit(context: ConnectContext(source: nil, target: cell, identity: impostor))
        XCTAssertEqual(admitted, .denied)
        XCTAssertEqual(cell.installations, 0)
    }
    func testRestoredSameUUIDLinkPreservesProofPathAndRejectsStolenOrRevokedLink() async throws {
        let (owner, cell, holder) = try await fixture()
        // Trusted EntityAnchor restore, as in IdentityLinkRegistryBindingTests.
        // Fresh completion rejects equal issuer/holder UUIDs; this tests the
        // registry's existing restored-record proof path, not new enrollment.
        let record = IdentityLinkRecord(
            linkID: "restored-\(UUID().uuidString)",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor,
                entityAnchorReference: EntityGenesisService.anchorReference),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: holder),
            approvedDomains: [cell.identityDomain], approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity], issuerIdentityUUID: owner.uuid,
            issuerType: .existingDevice, status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        await IdentityLinkRegistry.shared.restore(ownerUUID: owner.uuid, records: [record])
        let stolen = IdentityLinkProtocolService.identity(from: record.linkedIdentity)
        await assertDenied { _ = try await cell.get(keypath: "probe", requester: stolen) }
        XCTAssertEqual(cell.installations, 0)
        _ = await cell.bindStoredOwnerToRuntimeIdentity(owner)
        do {
            let value = try await cell.get(keypath: "probe", requester: holder)
            XCTAssertEqual(value, .string("ready"))
            let decision = await cell.authorizationDecision(requestedAccess: "r---", at: "probe", for: holder)
            XCTAssertEqual(decision.path, .ownerProof)
            XCTAssertEqual(decision.reasonCode, "linked_identity_proof")
            await IdentityLinkRegistry.shared.revoke(ownerUUID: owner.uuid, linkID: record.linkID,
                revokedAt: IdentityLinkProtocolService.iso8601(Date()))
            await assertDenied { _ = try await cell.get(keypath: "probe", requester: holder) }
        } catch {
            await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
            throw error
        }
        await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
    }
    func testOtherUUIDWithSignedGrantStillReads() async throws {
        let (owner, cell, _) = try await fixture()
        _ = await cell.bindStoredOwnerToRuntimeIdentity(owner)
        try await cell.ensureRuntimeReady()
        let other = await vault.makeIdentity(displayName: "grantee")
        cell.agreementTemplate.addGrant("r---", for: "probe")
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "probe")
        agreement.signatories.append(other)
        let state = await cell.addAgreement(agreement, for: other, authorizedBy: owner)
        XCTAssertEqual(state, .signed)
        let value = try await cell.get(keypath: "probe", requester: other)
        XCTAssertEqual(value, .string("ready"))
    }
    func testAttachAbsorbAndAgreementRejectBeforeReadinessEvenInDebug() async throws {
        CellBase.debugValidateAccessForEverything = true
        let (owner, cell, impostor) = try await fixture()
        let emitter = await GeneralCell(owner: owner)
        await assertDenied { _ = try await cell.attach(emitter: emitter, label: "probe", requester: impostor) }
        await assertDenied { try await cell.absorbFlow(label: "probe", requester: impostor) }
        let agreement = Agreement(owner: owner)
        let state = await cell.addAgreement(agreement, for: impostor, authorizedBy: owner)
        XCTAssertEqual(state, .rejected)
        let foreignAuthority = await cell.addAgreement(agreement, for: owner, authorizedBy: impostor)
        XCTAssertEqual(foreignAuthority, .rejected)
        XCTAssertEqual(cell.installations, 0)
    }
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

private final class ReadinessRefusalProbeCell: GeneralCell {
    var installations = 0
    var writes = 0
    required init(owner: Identity) async { await super.init(owner: owner) }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    override func installCellRuntimeBindingsForAccess() async throws {
        installations += 1
        guard let owner = await verifiedRuntimeOwnerIdentity() else { throw ProbeError.persistedOwnerHomeVaultUnavailable }
        await addInterceptForGet(requester: owner, key: "probe") { _, _ in .string("ready") }
        await addInterceptForSet(requester: owner, key: "probe") { [weak self] _, _, _ in
            self?.writes += 1
            return .string("changed")
        }
    }
    enum ProbeError: Error { case persistedOwnerHomeVaultUnavailable }
}

private actor ReadinessTestIdentityVault: IdentityVaultProtocol {
    private var identities: [String: Identity] = [:]
    private var privateKeys: [String: Curve25519.Signing.PrivateKey] = [:]

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identities[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identities[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else { return nil }
        let identity = makeIdentity(displayName: identityContext)
        identities[identityContext] = identity
        return identity
    }

    func saveIdentity(_ identity: Identity) async {
        identities[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let privateKey = privateKeys[identity.uuid] else {
            throw TestError.noPrivateKey
        }
        return try privateKey.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0x42, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("test-key-\(tag)", "test-iv-\(tag)")
    }

    func makeIdentity(displayName: String, uuid: String = UUID().uuidString) -> Identity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = Identity(uuid, displayName: displayName, identityVault: self)
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .EdDSA,
            size: 32,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: privateKey.publicKey.rawRepresentation
        )
        privateKeys[identity.uuid] = privateKey
        return identity
    }

    enum TestError: Error {
        case noPrivateKey
    }
}
