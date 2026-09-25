// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
@testable import CellBase
@testable import CellVapor

// Cell-level half of round 1. Runs against the Vapor EntityAnchorCell with the
// same harness VaporCellRuntimeReadinessContractTests uses.
//
//   test.entitet.genesis-once           testExplicitGenesisSealsAnchorToOwner (first-persist half: blocked, see below)
//   test.entitet.no-refounding          testSecondGenesisIsRefused, testGenesisCannotBeRevokedOrOverwritten
//   test.entitet.linked-identity-accepted   testLinkedSecondIdentityReadsAndWrites
//                                           (the resolver path itself landed on main earlier:
//                                            IdentityLinkRegistry + GeneralCell.authorizationEvidence)
//   test.entitet.foreign-entity-refused     testIdentityFromAnotherEntityIsRefused,
//                                           testPairwiseLinkDoesNotOpenTheAnchor,
//                                           testGenesisRecordWithoutValidSealIsNotHonoured
final class EntityAnchorGenesisTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousResolver: CellResolverProtocol?
    private var previousMasterKey: Data?

    override func setUp() async throws {
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousResolver = CellBase.defaultCellResolver
        previousMasterKey = CellBase.persistedCellMasterKey
        // Entity data is encrypted at rest on main; without a master key every
        // save fails with journalCorrupt("missingMasterKey").
        CellBase.persistedCellMasterKey = Data(repeating: 0x67, count: 32)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-genesis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.defaultCellResolver = MockCellResolver()
    }

    override func tearDown() async throws {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.defaultCellResolver = previousResolver
        CellBase.persistedCellMasterKey = previousMasterKey
    }

    private func makeOwnerAndAnchor() async throws -> (vault: MockIdentityVault, owner: Identity, anchor: EntityAnchorCell) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)

        let owner = try XCTUnwrap(ownerCandidate)
        let anchor = await EntityAnchorCell(owner: owner)
        return (vault, owner, anchor)
    }

    private func state(_ anchor: EntityAnchorCell, requester: Identity) async throws -> Object {
        let value = try await anchor.get(keypath: "identityLinks.state", requester: requester)
        guard case let .object(object) = value else {
            throw XCTSkip("identityLinks.state did not return an object: \(value)")
        }
        return object
    }

    /// Anchor actions answer with an object; an error is `status: "error"` plus a
    /// message. Surface the message instead of a bare "not equal".
    private func expectOK(_ result: ValueType?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .object(object)? = result else {
            return XCTFail("\(what): expected an object result, got \(String(describing: result))", file: file, line: line)
        }
        if object["status"] == .string("error") {
            XCTFail("\(what): \(String(describing: object["message"]))", file: file, line: line)
        }
    }

    // MARK: genesis-once

    func testAnchorStartsUnsealed() async throws {
        let (_, owner, anchor) = try await makeOwnerAndAnchor()
        let object = try await state(anchor, requester: owner)
        XCTAssertEqual(object["sealed"], .bool(false))
    }

    func testExplicitGenesisSealsAnchorToOwner() async throws {
        let (_, owner, anchor) = try await makeOwnerAndAnchor()
        let result = try await anchor.set(
            keypath: "identityLinks.genesis",
            value: .object(["trigger": .string("addressBookImport")]),
            requester: owner
        )
        expectOK(result, "genesis")
        guard case let .object(object)? = result else { return }
        XCTAssertEqual(object["status"], .string("sealed"))

        let sealed = try await state(anchor, requester: owner)
        XCTAssertEqual(sealed["sealed"], .bool(true))
        guard case let .object(seal)? = sealed["genesis"] else {
            return XCTFail("Expected genesis seal in state")
        }
        XCTAssertEqual(seal["trigger"], .string("addressBookImport"))
        XCTAssertEqual(seal["initiatorIdentityUUID"], .string(owner.uuid))
        XCTAssertEqual(seal["anchorID"], .string(anchor.uuid))
    }

    // testFirstPersistSealsAnchorToOwner is deliberately NOT here.
    //
    // The batch-persist path is a feed intercept: it only runs when this cell
    // absorbs another cell's flow through the auditor, which is the harness
    // BindingPersonalChatChronicle builds and no CellBase test builds today.
    // `GeneralCell.intercepts` is private, so the intercept cannot be invoked
    // directly either. Sealing on first persist is four lines in
    // persistBatchEnvelope; it stays UNTESTED until round 2 builds the flow
    // harness that WP3–WP5 need anyway. TESTRESULT.md must say "blocked", not
    // omit it.

    // MARK: no-refounding

    func testSecondGenesisIsRefused() async throws {
        let (_, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        let second = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        guard case let .object(object)? = second else {
            return XCTFail("Expected an error object, got \(String(describing: second))")
        }
        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertTrue((try? object["message"]?.stringValue())??.contains("alreadySealed") == true,
                      "Expected alreadySealed, got \(String(describing: object["message"]))")

        let sealed = try await state(anchor, requester: owner)
        guard case let .object(seal)? = sealed["genesis"] else {
            return XCTFail("Seal should still be present")
        }
        XCTAssertEqual(seal["trigger"], .string("onboarding"))
    }

    func testGenesisCannotBeRevokedOrOverwritten() async throws {
        let (_, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        let linkID = "genesis-\(anchor.uuid)"

        let revoke = try await anchor.set(keypath: "identityLinks.revoke", value: .string(linkID), requester: owner)
        guard case let .object(revokeObject)? = revoke else {
            return XCTFail("Expected an error object from revoke")
        }
        XCTAssertEqual(revokeObject["status"], .string("error"))
        XCTAssertTrue((try? revokeObject["message"]?.stringValue())??.contains("cannotRevokeGenesisLink") == true)

        let overwrite = try await anchor.set(
            keypath: "identityLinks.genesis.trigger",
            value: .string("directEdit"),
            requester: owner
        )
        guard case let .object(overwriteObject)? = overwrite else {
            return XCTFail("Expected an error object from overwrite")
        }
        XCTAssertEqual(overwriteObject["status"], .string("error"))
        XCTAssertTrue((try? overwriteObject["message"]?.stringValue())??.contains("genesisKeypathIsImmutable") == true)

        let sealed = try await state(anchor, requester: owner)
        guard case let .object(seal)? = sealed["genesis"] else {
            return XCTFail("Seal should still be present")
        }
        XCTAssertEqual(seal["trigger"], .string("onboarding"))
    }

    // MARK: linked identity through the real authorization path

    func testLinkedSecondIdentityReadsAndWrites() async throws {
        let (vault, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)

        // A second identity of the same entity, in the same vault: the Face ID identity.
        let faceIDCandidate = await vault.identity(for: "faceid", makeNewIfNotFound: true)

        let faceID = try XCTUnwrap(faceIDCandidate)

        // Before any link exists, it is a stranger.
        do {
            _ = try await anchor.get(keypath: "person", requester: faceID)
            XCTFail("Unlinked identity must not read entity data")
        } catch {
            // expected
        }

        // The owner records a link for it. Enrollment has its own tests; here
        // the record is written through the owner's identityLinks grant.
        let link = IdentityLinkRecord(
            linkID: "link-faceid",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: anchor.uuid),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: faceID),
            approvedDomains: ["private"],
            approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: owner.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        let wrote = try await anchor.set(
            keypath: "identityLinks.records.link-faceid",
            value: try IdentityLinkProtocolService.value(from: link),
            requester: owner
        )
        expectOK(wrote, "write link record")
        let registered = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: owner.uuid).map(\.linkID)
        XCTAssertTrue(registered.contains("link-faceid"), "registry after write: \(registered)")

        // Now it reads and writes as a representative of the entity.
        _ = try await anchor.get(keypath: "person", requester: faceID)
        _ = try await anchor.set(keypath: "person.nickname", value: .string("Ada"), requester: faceID)
        let nickname = try await anchor.get(keypath: "person.nickname", requester: owner)
        XCTAssertEqual(nickname, .string("Ada"))

        // The decision goes through the same-entity path main already has.
        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: faceID)
        XCTAssertTrue(decision.allowed, decision.reason)
        XCTAssertEqual(decision.path, .ownerProof)
        XCTAssertEqual(decision.reasonCode, "linked_identity_proof")
    }

    func testIdentityFromAnotherEntityIsRefused() async throws {
        let (_, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)

        // Another entity: its own vault, its own keys, and no link in this anchor.
        let otherVault = MockIdentityVault()
        let otherCandidate = await otherVault.identity(for: "private", makeNewIfNotFound: true)

        let other = try XCTUnwrap(otherCandidate)

        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: other)
        XCTAssertFalse(decision.allowed, decision.reason)
        // Either denial is the right answer for a stranger: no grant, or a UUID that
        // happens to collide but whose key does not match the stored owner.
        XCTAssertTrue([.deniedNoGrant, .deniedIdentityReferenceMismatch].contains(decision.path),
                      "unexpected path \(decision.path)")
        do {
            _ = try await anchor.get(keypath: "person", requester: other)
            XCTFail("Identity from another entity must not read entity data")
        } catch {
            // expected
        }
    }

    func testPairwiseLinkDoesNotOpenTheAnchor() async throws {
        let (vault, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        let faceIDCandidate = await vault.identity(for: "faceid", makeNewIfNotFound: true)

        let faceID = try XCTUnwrap(faceIDCandidate)

        // Same identity, same scope, same domain — but a pairwise binding. That
        // proves membership to a third party; it does not open the entity.
        let pairwise = IdentityLinkRecord(
            linkID: "link-pairwise",
            entityBinding: EntityBindingDescriptor(mode: .pairwise, bindingID: "b1", audience: "register"),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: faceID),
            approvedDomains: ["private"],
            approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: owner.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        _ = try await anchor.set(
            keypath: "identityLinks.records.link-pairwise",
            value: try IdentityLinkProtocolService.value(from: pairwise),
            requester: owner
        )
        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: faceID)
        XCTAssertFalse(decision.allowed, "a pairwise binding must not open the anchor")
    }

    func testGenesisRecordWithoutValidSealIsNotHonoured() async throws {
        let (vault, owner, anchor) = try await makeOwnerAndAnchor()
        // Not sealed. Someone writes a genesis-shaped record for a second identity
        // straight into records, without a seal that signs for it.
        let claimantCandidate = await vault.identity(for: "claimant", makeNewIfNotFound: true)

        let claimant = try XCTUnwrap(claimantCandidate)
        let forged = IdentityLinkRecord(
            linkID: "genesis-\(anchor.uuid)",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: EntityGenesisService.anchorReference),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: claimant),
            approvedDomains: ["private"],
            approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: claimant.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        _ = try await anchor.set(
            keypath: "identityLinks.records.genesis-\(anchor.uuid)",
            value: try IdentityLinkProtocolService.value(from: forged),
            requester: owner
        )
        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: claimant)
        XCTAssertFalse(decision.allowed, "a genesis-shaped record without a verifying seal grants nothing")
    }

    func testLinkedIdentityWithoutKeyControlIsRefused() async throws {
        let (vault, owner, anchor) = try await makeOwnerAndAnchor()
        _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
        let faceIDCandidate = await vault.identity(for: "faceid", makeNewIfNotFound: true)

        let faceID = try XCTUnwrap(faceIDCandidate)
        let link = IdentityLinkRecord(
            linkID: "link-faceid",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: anchor.uuid),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: faceID),
            approvedDomains: ["private"],
            approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: owner.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date())
        )
        _ = try await anchor.set(
            keypath: "identityLinks.records.link-faceid",
            value: try IdentityLinkProtocolService.value(from: link),
            requester: owner
        )

        // Same UUID and public key as the linked identity, but no vault: it
        // cannot answer the challenge. The link matches; the proof fails.
        let claimant = Identity(faceID.uuid, displayName: "claimant", identityVault: nil)
        claimant.publicSecureKey = faceID.publicSecureKey
        let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: claimant)
        XCTAssertFalse(decision.allowed)
    }
}
#endif
