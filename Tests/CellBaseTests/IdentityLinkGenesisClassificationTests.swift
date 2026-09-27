// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentityLinkGenesisClassificationTests: XCTestCase {
    /// F1: neither a prefix nor a self-link nor an unverified seal is classification evidence.
    func testF1ClassificationRequiresVerifiedSealAndExactRecord() async throws {
        let entity = await SimulatedEntity.make("classification")
        var genesis = try await EntityGenesisService.seal(anchorID: "classification", initiator: entity.owner,
            identityDomain: "private", trigger: .firstPersist)
        // A valid pair with a different name is still classified by verification.
        genesis.record.linkID = "signed-record-without-reserved-prefix"
        genesis.seal.linkID = genesis.record.linkID
        let signature = try await entity.owner.sign(data: genesis.seal.canonicalPayloadData())
        genesis.seal.proof?.signature = try XCTUnwrap(signature)
        let registry = IdentityLinkRegistry()
        var prefixed = genesis.record
        prefixed.linkID = "genesis-name-alone-is-not-proof"
        var selfEnrollment = genesis.record
        selfEnrollment.linkID = "ordinary-self-link"
        let records = [genesis.record, prefixed, selfEnrollment]
        await registry.restore(ownerUUID: entity.owner.uuid, records: records, genesisSeal: genesis.seal)
        let classified = await registry.activeLinks(ownerUUID: entity.owner.uuid)
        XCTAssertEqual(Set(classified.map(\.linkID)), Set([prefixed.linkID, selfEnrollment.linkID]))
        let member = await registry.sameEntityLink(ownerUUID: entity.owner.uuid, requesterUUID: entity.owner.uuid,
            requesterSigningKey: entity.owner.publicSecureKey?.compressedKey, domain: "private")
        XCTAssertNotNil(member, "F2: classification must not remove authorization records")

        // restore's records are trusted input from the runtime. A bad seal must
        // never hide one of those records under the genesis classification.
        var invalid = genesis.seal
        invalid.proof = nil
        await registry.restore(ownerUUID: entity.owner.uuid, records: records, genesisSeal: invalid)
        let unclassified = await registry.activeLinks(ownerUUID: entity.owner.uuid)
        XCTAssertEqual(unclassified.count, 3)
        invalid = genesis.seal
        invalid.anchorID = "tampered"
        await registry.restore(ownerUUID: entity.owner.uuid, records: records, genesisSeal: invalid)
        let tampered = await registry.activeLinks(ownerUUID: entity.owner.uuid)
        XCTAssertEqual(tampered.count, 3)
        await registry.restore(ownerUUID: entity.owner.uuid, records: [genesis.record], genesisSeal: genesis.seal)
        await registry.clear(ownerUUID: entity.owner.uuid)
        await registry.restore(ownerUUID: entity.owner.uuid, records: [genesis.record])
        let cleared = await registry.activeLinks(ownerUUID: entity.owner.uuid)
        XCTAssertEqual(cleared, [genesis.record], "F1: clear/restore cannot retain stale classification")
    }

    /// F2: the resolver's GeneralCell evidence path can still use a genesis record.
    func testF2GenesisRemainsAvailableToResolverEvidence() async throws {
        let entity = await SimulatedEntity.make("resolver-genesis")
        let genesis = try await EntityGenesisService.seal(anchorID: "resolver", initiator: entity.owner,
            identityDomain: "private", trigger: .firstPersist)
        // A UUID-only owner descriptor cannot take the direct owner-reference
        // branch. This isolates the resolver's registry + key-control path.
        let descriptor = Identity(entity.owner.uuid, displayName: "owner reference", identityVault: nil)
        let cell = await GeneralCell(owner: descriptor)
        await IdentityLinkRegistry.shared.restore(ownerUUID: entity.owner.uuid, records: [genesis.record], genesisSeal: genesis.seal)
        let decision = await cell.authorizationDecision(requestedAccess: "r---", at: "person", for: entity.owner)
        XCTAssertTrue(decision.allowed, decision.reason)
        XCTAssertEqual(decision.reasonCode, "linked_identity_proof")
        let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: entity.owner.uuid)
        XCTAssertTrue(links.isEmpty, "F1: authorizing through genesis does not make it an enrollment")
        let claimant = SimulatedEntity.keylessClaimant(of: entity.owner)
        let denied = await cell.authorizationDecision(requestedAccess: "r---", at: "person", for: claimant)
        XCTAssertFalse(denied.allowed, "F2: key control is still required")
        await IdentityLinkRegistry.shared.clear(ownerUUID: entity.owner.uuid)
    }
}
