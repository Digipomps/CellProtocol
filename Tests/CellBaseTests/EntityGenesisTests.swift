// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

// purpose://candidate.entitetsdata.genesis-seals-to-initiator
// test.entitet.genesis-once — the pure half. The cell-level half (a second
// genesis against a sealed anchor is refused) lives in EntityAnchorGenesisTests.
final class EntityGenesisTests: XCTestCase {

    func testGenesisSealsToInitiatorAndVerifies() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let initiator = await vault.makeIdentity(displayName: "initiator")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let result = try await EntityGenesisService.seal(
            anchorID: "anchor-1",
            initiator: initiator,
            identityDomain: "private",
            trigger: .addressBookImport,
            now: now
        )

        // The record is a normal IdentityLinkRecord the authorizer can use.
        XCTAssertEqual(result.record.linkID, "genesis-anchor-1")
        XCTAssertEqual(result.record.entityBinding.mode, .localEntityAnchor)
        XCTAssertEqual(result.record.entityBinding.entityAnchorReference, EntityGenesisService.anchorReference)
        XCTAssertEqual(result.record.linkedIdentity.uuid, initiator.uuid)
        XCTAssertEqual(result.record.issuerIdentityUUID, initiator.uuid)
        XCTAssertEqual(result.record.issuerType, .existingDevice)
        XCTAssertEqual(result.record.status, .active)
        XCTAssertEqual(result.record.approvedDomains, ["private"])
        XCTAssertEqual(result.record.approvedScopes, [IdentityLinkScope.sameEntity])
        XCTAssertTrue(IdentityLinkScope.grantsSameEntity(result.record.approvedScopes))

        // The seal names the same link and carries a signature that verifies
        // against the key in the record — not against anything in storage.
        XCTAssertEqual(result.seal.linkID, result.record.linkID)
        XCTAssertEqual(result.seal.trigger, .addressBookImport)
        XCTAssertEqual(result.seal.initiatorIdentityUUID, initiator.uuid)
        XCTAssertNotNil(result.seal.proof?.signature)
        XCTAssertNoThrow(try EntityGenesisService.verify(seal: result.seal, record: result.record))
    }

    func testTamperedSealFailsVerification() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let initiator = await vault.makeIdentity(displayName: "initiator")
        let result = try await EntityGenesisService.seal(
            anchorID: "anchor-1",
            initiator: initiator,
            identityDomain: "private",
            trigger: .onboarding
        )

        var tampered = result.seal
        tampered.trigger = .directEdit
        XCTAssertThrowsError(try EntityGenesisService.verify(seal: tampered, record: result.record)) { error in
            XCTAssertEqual(error as? EntityGenesisError, .sealProofInvalid)
        }

        var stripped = result.seal
        stripped.proof = nil
        XCTAssertThrowsError(try EntityGenesisService.verify(seal: stripped, record: result.record)) { error in
            XCTAssertEqual(error as? EntityGenesisError, .sealProofInvalid)
        }
    }

    func testSealDoesNotVerifyAgainstAnotherIdentitysRecord() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let initiator = await vault.makeIdentity(displayName: "initiator")
        let attacker = await vault.makeIdentity(displayName: "attacker")
        let genuine = try await EntityGenesisService.seal(
            anchorID: "anchor-1",
            initiator: initiator,
            identityDomain: "private",
            trigger: .onboarding
        )
        let forged = try await EntityGenesisService.seal(
            anchorID: "anchor-1",
            initiator: attacker,
            identityDomain: "private",
            trigger: .onboarding
        )

        // Attacker swaps in their own record under the genuine seal: the seal
        // names the initiator, the record names the attacker.
        XCTAssertThrowsError(try EntityGenesisService.verify(seal: genuine.seal, record: forged.record)) { error in
            XCTAssertEqual(error as? EntityGenesisError, .sealDoesNotMatchRecord("initiator"))
        }
    }

    func testPairwiseRecordIsRejected() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let initiator = await vault.makeIdentity(displayName: "initiator")
        let result = try await EntityGenesisService.seal(
            anchorID: "anchor-1",
            initiator: initiator,
            identityDomain: "private",
            trigger: .onboarding
        )
        var pairwise = result.record
        pairwise.entityBinding = EntityBindingDescriptor(mode: .pairwise, bindingID: "b1", audience: "register")
        XCTAssertThrowsError(try EntityGenesisService.verify(seal: result.seal, record: pairwise)) { error in
            XCTAssertEqual(error as? EntityGenesisError, .sealDoesNotMatchRecord("entityBinding"))
        }
    }

    func testInitiatorWithoutSigningKeyCannotSeal() async {
        let keyless = Identity(UUID().uuidString, displayName: "keyless", identityVault: nil)
        do {
            _ = try await EntityGenesisService.seal(
                anchorID: "anchor-1",
                initiator: keyless,
                identityDomain: "private",
                trigger: .onboarding
            )
            XCTFail("Expected genesis to refuse an initiator without a signing key")
        } catch let error as EntityGenesisError {
            XCTAssertEqual(error, .initiatorHasNoSigningKey(keyless.uuid))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testGenesisKeypathsAreRecognisedAsImmutable() {
        XCTAssertTrue(EntityGenesisService.isImmutableGenesisKeypath("identityLinks.genesis"))
        XCTAssertTrue(EntityGenesisService.isImmutableGenesisKeypath("identityLinks.genesis.proof"))
        XCTAssertFalse(EntityGenesisService.isImmutableGenesisKeypath("identityLinks.genesisX"))
        XCTAssertFalse(EntityGenesisService.isImmutableGenesisKeypath("identityLinks.records.abc"))
        XCTAssertTrue(EntityGenesisService.isGenesisLink("genesis-anchor-1"))
        XCTAssertFalse(EntityGenesisService.isGenesisLink("approval-123"))
    }
}
