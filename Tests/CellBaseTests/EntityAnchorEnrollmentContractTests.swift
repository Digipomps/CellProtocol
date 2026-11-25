// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
@testable import CellBase
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

final class EntityAnchorEnrollmentContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousResolver: CellResolverProtocol?
    private var previousKey: Data?
    private var previousDebug = false
    private var root: URL!
    private var scaffoldVault: MockIdentityVault!

    override func setUp() async throws {
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousResolver = CellBase.defaultCellResolver
        previousKey = CellBase.persistedCellMasterKey
        previousDebug = CellBase.debugValidateAccessForEverything
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-enrollment-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x67, count: 32)
        CellBase.defaultCellResolver = MockCellResolver()
        // The scaffold's own vault: whoever runs the process. Entities never use it.
        scaffoldVault = MockIdentityVault()
        CellBase.defaultIdentityVault = scaffoldVault
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() async throws {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.defaultCellResolver = previousResolver
        CellBase.persistedCellMasterKey = previousKey
        CellBase.debugValidateAccessForEverything = previousDebug
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Both scaffolds

    private enum Scaffold: String, CaseIterable {
        case local = "CellApple (personlig scaffold)"
        case cloud = "CellVapor (skyscaffold)"

        func anchor(owner: Identity) async -> GeneralCell {
            switch self {
            case .local: return await AppleEntityAnchorCell(owner: owner)
            case .cloud: return await VaporEntityAnchorCell(owner: owner)
            }
        }

        /// The same cell after a restart: encoded, decoded, reading its files again.
        func restart(_ anchor: GeneralCell) throws -> GeneralCell {
            let snapshot = try JSONEncoder().encode(anchor)
            switch self {
            case .local: return try JSONDecoder().decode(AppleEntityAnchorCell.self, from: snapshot)
            case .cloud: return try JSONDecoder().decode(VaporEntityAnchorCell.self, from: snapshot)
            }
        }
    }

    private func forEachScaffold(_ body: (Scaffold, GeneralCell, SimulatedEntity) async throws -> Void) async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("A-\(scaffold)")
            let anchor = await scaffold.anchor(owner: entity.owner)
            try await body(scaffold, anchor, entity)
        }
    }


    /// F1/F2: a verified enrollment remains listed while genesis remains usable.
    func testF1F2VerifiedEnrollmentIsListedAndRestored() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] F1/F2"
            let genesis = try await seal(anchor, owner: entity.owner)
            let holder = await entity.identity("phone")
            let record = try await enroll(anchor, issuer: entity.owner, holder: holder)
            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertEqual(links, [record], tag)
            let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: holder)
            XCTAssertTrue(decision.allowed, tag)
            XCTAssertEqual(decision.reasonCode, "linked_identity_proof", tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
            let restored = try scaffold.restart(anchor)
            try await restored.installCellRuntimeBindingsForAccess()
            let restoredLinks = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertEqual(restoredLinks, [record], tag)
            try await assertGenesisUnchanged(restored, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// F1: a legacy owner-written self-link is not classified as genesis by its shape.
    func testF1StoredSelfLinkIsStillListed() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let genesis = try await seal(anchor, owner: entity.owner)
            // The enrollment protocol rejects identical keys. Exercise the
            // existing owner-authorized record restore API for this shape.
            var record = try await EntityGenesisService.seal(anchorID: "ordinary-self",
                initiator: entity.owner, identityDomain: anchor.identityDomain, trigger: .onboarding).record
            record.linkID = "ordinary-self-link"
            let result = try await anchor.set(keypath: EntityGenesisService.recordKeypath(linkID: record.linkID),
                value: try IdentityLinkProtocolService.value(from: record), requester: entity.owner)
            guard case let .object(object)? = result else { return XCTFail("missing store result") }
            XCTAssertEqual(object["status"], .string("stored"))
            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertEqual(links, [record], scaffold.rawValue)
            // Both records match sameEntityLink; revoke the legacy self-link
            // before asking that lookup specifically for genesis.
            _ = try await anchor.set(keypath: "identityLinks.revoke", value: .string(record.linkID), requester: entity.owner)
            try await assertGenesisUnchanged(anchor, owner: entity.owner, genesis: genesis, tag: scaffold.rawValue)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// F1/F2: missing fresh-auth and an incorrect presentation challenge admit nothing and preserve genesis.
    func testF1F2IncompleteAndIncorrectEvidencePreserveGenesis() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] F1/F2"
            let genesis = try await seal(anchor, owner: entity.owner)
            let holder = await entity.identity("phone")
            for missing in [true, false] {
                var envelope = try await makeEnvelope(issuer: entity.owner, holder: holder,
                    domains: [anchor.identityDomain], scopes: [IdentityLinkScope.sameEntity])
                if missing { envelope.requireFreshAuthEvidence = true }
                else { envelope.expectedPresentationChallenge = Data("wrong-challenge".utf8) }
                let result = try await anchor.set(keypath: "identityLinks.completeEnrollment",
                    value: try IdentityLinkProtocolService.value(from: envelope), requester: entity.owner)
                guard case let .object(object)? = result else { return XCTFail("\(tag) missing error result") }
                XCTAssertEqual(object["status"], .string("error"), "\(tag) \(object)")
                let expectedError = missing ? "missingFreshAuth" : "invalidPresentation"
                XCTAssertEqual(object["message"], .string(expectedError), tag)
                let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
                XCTAssertTrue(links.isEmpty, tag)
                let member = await IdentityLinkRegistry.shared.sameEntityLink(ownerUUID: entity.owner.uuid,
                    requesterUUID: holder.uuid, requesterSigningKey: holder.publicSecureKey?.compressedKey,
                    domain: anchor.identityDomain)
                XCTAssertNil(member, tag)
                try await assertGenesisUnchanged(anchor, owner: entity.owner, genesis: genesis, tag: tag)
            }
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
            let restored = try scaffold.restart(anchor)
            try await restored.installCellRuntimeBindingsForAccess()
            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertTrue(links.isEmpty, tag)
            try await assertGenesisUnchanged(restored, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// F1/F2: revocation removes only the enrolled identity, also after registry rebuild.
    func testF1F2RevocationPreservesGenesisAfterRestore() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] F1/F2"
            let genesis = try await seal(anchor, owner: entity.owner)
            let holder = await entity.identity("phone")
            let record = try await enroll(anchor, issuer: entity.owner, holder: holder)
            let result = try await anchor.set(keypath: "identityLinks.revoke", value: .string(record.linkID), requester: entity.owner)
            guard case let .object(object)? = result else { return XCTFail("\(tag) missing revoke result") }
            XCTAssertEqual(object["status"], .string("revoked"), tag)
            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertTrue(links.isEmpty, tag)
            try await assertGenesisUnchanged(anchor, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
            let restored = try scaffold.restart(anchor)
            try await restored.installCellRuntimeBindingsForAccess()
            let restoredLinks = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertTrue(restoredLinks.isEmpty, tag)
            let decision = await restored.authorizationDecision(requestedAccess: "r---", at: "person", for: holder)
            XCTAssertFalse(decision.allowed, tag)
            try await assertGenesisUnchanged(restored, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    // MARK: - Sikkerhetsrevisjon 2026-11-25 (E2, E3, E4)

    /// E3: en godkjenning signert av en nøkkel som ikke er entiteten, lenker ingenting
    /// når en lenket enhet sender den inn, og heller ikke fra eierens sesjon der
    /// verten krever ferskt bevis (staging).
    func testE3ForeignIssuerCannotCompleteAnEnrollment() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] E3"
            let genesis = try await seal(anchor, owner: entity.owner)
            let phone = await entity.identity("phone")
            let enrolled = try await enroll(anchor, issuer: entity.owner, holder: phone)
            let stranger = await SimulatedEntity.make("B-\(scaffold)")
            let holder = await stranger.identity("phone")

            func refused(by requester: Identity, _ note: String) async throws {
                let envelope = try await makeEnvelope(issuer: stranger.owner, holder: holder,
                    domains: [anchor.identityDomain], scopes: [IdentityLinkScope.sameEntity])
                let result = try await anchor.set(keypath: "identityLinks.completeEnrollment",
                    value: try IdentityLinkProtocolService.value(from: envelope), requester: requester)
                guard case let .object(object)? = result, case let .string(message)? = object["message"] else {
                    return XCTFail("\(tag) \(note): missing error result")
                }
                XCTAssertEqual(object["status"], .string("error"), "\(tag) \(note)")
                XCTAssertTrue(message.hasPrefix("issuer_is_not_the_entity"), "\(tag) \(note): \(message)")
            }

            try await refused(by: phone, "linked device")
            await IdentityLinkRuntimePolicy.shared.install(requireFreshAuthEvidence: true, freshAuthVerifier: { _ in true })
            try await refused(by: entity.owner, "owner session on a fresh-auth host")
            await IdentityLinkRuntimePolicy.shared.reset()

            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertEqual(links, [enrolled], tag)
            let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: holder)
            XCTAssertFalse(decision.allowed, tag)
            try await assertGenesisUnchanged(anchor, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// E3: en hel lenket identitet er entiteten og kan utstede neste lenke.
    func testE3WholeLinkedIdentityCanIssueTheNextLink() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] E3"
            _ = try await seal(anchor, owner: entity.owner)
            let phone = await entity.identity("phone")
            _ = try await enroll(anchor, issuer: entity.owner, holder: phone)
            let tablet = await entity.identity("tablet")
            let record = try await enroll(anchor, issuer: phone, holder: tablet)
            XCTAssertEqual(record.issuerIdentityUUID, phone.uuid, tag)
            let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: tablet)
            XCTAssertTrue(decision.allowed, tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// E2: en rå lenkepost krever eierens egen nøkkel, og finnes ikke der verten krever ferskt bevis.
    func testE2RawLinkRecordNeedsOwnerKeyAndNoFreshAuthenticationDemand() async throws {
        try await forEachScaffold { scaffold, anchor, entity in
            let tag = "[\(scaffold.rawValue)] E2"
            let genesis = try await seal(anchor, owner: entity.owner)
            let phone = await entity.identity("phone")
            let enrolled = try await enroll(anchor, issuer: entity.owner, holder: phone)
            let tablet = await entity.identity("tablet")
            let raw = IdentityLinkRecord(
                linkID: "raw-tablet",
                entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: anchor.uuid),
                linkedIdentity: try IdentityLinkProtocolService.descriptor(for: tablet),
                approvedDomains: [anchor.identityDomain], approvedIdentityContexts: [],
                approvedScopes: [IdentityLinkScope.sameEntity], issuerIdentityUUID: phone.uuid,
                issuerType: .existingDevice, status: .active, linkedAt: IdentityLinkProtocolService.iso8601(Date()))
            let rawValue = try IdentityLinkProtocolService.value(from: raw)
            let keypath = EntityGenesisService.recordKeypath(linkID: raw.linkID)

            func refused(_ requester: Identity, _ keypath: String, _ value: ValueType, _ code: String, _ note: String) async throws {
                let result = try await anchor.set(keypath: keypath, value: value, requester: requester)
                guard case let .object(object)? = result, case let .string(message)? = object["message"] else {
                    return XCTFail("\(tag) \(note): missing error result")
                }
                XCTAssertEqual(object["status"], .string("error"), "\(tag) \(note)")
                XCTAssertTrue(message.hasPrefix(code), "\(tag) \(note): \(message)")
            }

            // En lenket enhet er entiteten, men lager ikke nye lenker ved å skrive poster.
            try await refused(phone, keypath, rawValue, "raw_link_write_requires_owner_proof", "linked device")
            // Verken hele treet eller gjenbruksloggen kan skrives rått, heller ikke av eieren.
            try await refused(entity.owner, "identityLinks.usedApprovalJTIs", .object([:]), "raw_link_write_not_allowed", "replay ledger")
            try await refused(entity.owner, "identityLinks.records", .object([:]), "raw_link_write_not_allowed", "record set")
            // Der verten krever ferskt bevis (staging), finnes ingen rå vei.
            await IdentityLinkRuntimePolicy.shared.install(requireFreshAuthEvidence: true, freshAuthVerifier: nil)
            try await refused(entity.owner, keypath, rawValue, "raw_link_write_requires_fresh_authentication", "fresh auth host")
            await IdentityLinkRuntimePolicy.shared.reset()

            let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
            XCTAssertEqual(links, [enrolled], tag)
            let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: tablet)
            XCTAssertFalse(decision.allowed, tag)
            try await assertGenesisUnchanged(anchor, owner: entity.owner, genesis: genesis, tag: tag)
            await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
        }
    }

    /// E4: malen for avtaler gir aldri identityLinks.
    func testE4AgreementTemplateDoesNotGrantIdentityLinks() async throws {
        try await forEachScaffold { scaffold, anchor, _ in
            let granted = anchor.agreementTemplate.grants.map(\.keypath)
            XCTAssertFalse(granted.contains { EntityAnchorLinkGuard.isIdentityLinkKeypath($0) },
                "[\(scaffold.rawValue)] E4 \(granted)")
        }
    }

    private func seal(_ anchor: GeneralCell, owner: Identity) async throws -> ValueType {
        let result = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        guard case let .object(object)? = result, object["status"] == .string("sealed") else {
            XCTFail("Expected sealed, got \(String(describing: result))")
            throw ContractTestError.unexpectedResult
        }
        return try await anchor.get(keypath: "identityLinks", requester: owner)
    }

    private func assertGenesisUnchanged(_ anchor: GeneralCell, owner: Identity, genesis: ValueType, tag: String) async throws {
        guard case let .object(original) = genesis,
              let sealValue = original["genesis"] else { throw ContractTestError.unexpectedResult }
        let seal = try JSONDecoder().decode(EntityGenesisSeal.self, from: JSONEncoder().encode(sealValue))
        let current = try await anchor.get(keypath: "identityLinks.genesis", requester: owner)
        XCTAssertEqual(try CanonicalPayloadEncoder.data(for: current), try CanonicalPayloadEncoder.data(for: sealValue), tag)
        let storedRecord = try await anchor.get(keypath: EntityGenesisService.recordKeypath(linkID: seal.linkID), requester: owner)
        guard case let .object(records)? = original["records"],
              let originalRecord = records[EntityGenesisService.safeRecordKey(seal.linkID)] else {
            throw ContractTestError.unexpectedResult
        }
        XCTAssertEqual(try CanonicalPayloadEncoder.data(for: storedRecord), try CanonicalPayloadEncoder.data(for: originalRecord), tag)
        let expected = try JSONDecoder().decode(IdentityLinkRecord.self, from: JSONEncoder().encode(originalRecord))
        let member = await IdentityLinkRegistry.shared.sameEntityLink(ownerUUID: owner.uuid,
            requesterUUID: owner.uuid, requesterSigningKey: owner.publicSecureKey?.compressedKey, domain: anchor.identityDomain)
        XCTAssertEqual(member, expected, tag)
        XCTAssertNoThrow(try EntityGenesisService.verify(seal: seal, record: expected), tag)
        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: owner)
        XCTAssertTrue(decision.allowed, tag)
    }

    private func enroll(_ anchor: GeneralCell, issuer: Identity, holder: Identity) async throws -> IdentityLinkRecord {
        let envelope = try await makeEnvelope(issuer: issuer, holder: holder,
            domains: [anchor.identityDomain], scopes: [IdentityLinkScope.sameEntity])
        let result = try await anchor.set(keypath: "identityLinks.completeEnrollment",
            value: try IdentityLinkProtocolService.value(from: envelope), requester: issuer)
        guard case let .object(object)? = result, object["status"] == .string("completed"), let record = object["record"] else {
            XCTFail("Expected completed, got \(String(describing: result))")
            throw ContractTestError.unexpectedResult
        }
        return try JSONDecoder().decode(IdentityLinkRecord.self, from: JSONEncoder().encode(record))
    }

    private enum ContractTestError: Error { case unexpectedResult }

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
#endif
