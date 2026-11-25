// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// Sikkerhetsrevisjon 2026-11-25, funn E2 og E3: reglene begge EntityAnchor-
/// implementasjonene bruker for alt under `identityLinks`. Kjører også på Linux.
final class EntityAnchorLinkGuardTests: XCTestCase {
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

    // MARK: - E2: lenker er ikke entitetsdata

    func testIdentityLinkKeypathsAreRecognisedHoweverTheyAreWritten() {
        for keypath in ["identityLinks", "identityLinks.records.a", "identityLinks.genesis",
                        "identityLinks.usedApprovalJTIs", " identityLinks.records.a", ".identityLinks.records.a",
                        "identityLinks[0]", "identityLinks[id=1].x", "identityLinks .records"] {
            XCTAssertTrue(EntityAnchorLinkGuard.isIdentityLinkKeypath(keypath), keypath)
            XCTAssertThrowsError(try EntityAnchorLinkGuard.rejectEntityDataMutation(to: keypath), keypath)
        }
        for keypath in ["person.name", "proofs.identityLinks.a", "identityLinksX.records", "relations.identityLinks", ""] {
            XCTAssertFalse(EntityAnchorLinkGuard.isIdentityLinkKeypath(keypath), keypath)
            XCTAssertNoThrow(try EntityAnchorLinkGuard.rejectEntityDataMutation(to: keypath), keypath)
        }
        XCTAssertThrowsError(try EntityAnchorLinkGuard.rejectEntityDataMutations(to: ["person.name", "identityLinks.records.a"]))
        XCTAssertNoThrow(try EntityAnchorLinkGuard.rejectEntityDataMutations(to: ["person.name", "chronicle.x"]))
    }

    func testRawLinkWriteNeedsTheOwnerKeyAndNoFreshAuthenticationDemand() {
        let record = "identityLinks.records.link-a"
        XCTAssertNoThrow(try EntityAnchorLinkGuard.rejectRawLinkWrite(
            to: record, requesterProvesOwnership: true, freshAuthenticationRequired: false))
        XCTAssertThrowsError(try EntityAnchorLinkGuard.rejectRawLinkWrite(
            to: record, requesterProvesOwnership: false, freshAuthenticationRequired: false)) {
            XCTAssertEqual($0 as? EntityAnchorLinkGuardError, .rawLinkWriteRequiresOwnerProof(record))
        }
        // Der verten krever ferskt bevis (staging), finnes ingen rå vei, heller ikke for eieren.
        XCTAssertThrowsError(try EntityAnchorLinkGuard.rejectRawLinkWrite(
            to: record, requesterProvesOwnership: true, freshAuthenticationRequired: true)) {
            XCTAssertEqual($0 as? EntityAnchorLinkGuardError, .rawLinkWriteRequiresFreshAuthentication(record))
        }
    }

    func testRawWriteNeverReplacesTheTreeTheApprovalsOrTheReplayLedger() {
        for keypath in ["identityLinks", "identityLinks.records", "identityLinks.usedApprovalJTIs",
                        "identityLinks.usedApprovalJTIs.jti-1", "identityLinks.approvals", "identityLinks.approvals.a",
                        "identityLinks.somethingNew", "identityLinks[0]", "identityLinks.records.",
                        "identityLinks.records.link-a.status", "identityLinks.records.link-a.linkedIdentity.publicKey",
                        "identityLinks.records.link-a[0]", "identityLinks.records[+]"] {
            XCTAssertThrowsError(try EntityAnchorLinkGuard.rejectRawLinkWrite(
                to: keypath, requesterProvesOwnership: true, freshAuthenticationRequired: false), keypath) {
                XCTAssertEqual($0 as? EntityAnchorLinkGuardError, .rawLinkWriteNotAllowed(keypath), keypath)
            }
        }
    }

    // MARK: - E3: bare entiteten selv godkjenner og utsteder

    func testOwnerKeyBelongsToTheEntityAndAStrangerDoesNot() async throws {
        let owner = await vault.makeIdentity(displayName: "owner")
        let stranger = await vault.makeIdentity(displayName: "stranger")
        let registry = IdentityLinkRegistry()
        let ownerDescriptor = try IdentityLinkProtocolService.descriptor(for: owner)
        let strangerDescriptor = try IdentityLinkProtocolService.descriptor(for: stranger)

        let ownerBelongs = await EntityAnchorLinkGuard.belongsToEntity(ownerDescriptor, owner: owner, identityDomain: "private", registry: registry)
        XCTAssertTrue(ownerBelongs)
        let strangerBelongs = await EntityAnchorLinkGuard.belongsToEntity(strangerDescriptor, owner: owner, identityDomain: "private", registry: registry)
        XCTAssertFalse(strangerBelongs)

        // Eierens UUID med en annen nøkkel er ikke eieren.
        var spoofed = strangerDescriptor
        spoofed.uuid = owner.uuid
        let spoofedBelongs = await EntityAnchorLinkGuard.belongsToEntity(spoofed, owner: owner, identityDomain: "private", registry: registry)
        XCTAssertFalse(spoofedBelongs)

        // En fremmed utsteder: avvist for en lenket enhet, og avvist for alle der verten krever ferskt bevis.
        for (provesOwnership, freshRequired) in [(false, false), (false, true), (true, true)] {
            do {
                try await EntityAnchorLinkGuard.requireIssuer(strangerDescriptor, owner: owner, identityDomain: "private",
                    requesterProvesOwnership: provesOwnership, freshAuthenticationRequired: freshRequired, registry: registry)
                XCTFail("en fremmed utsteder skal avvises (\(provesOwnership), \(freshRequired))")
            } catch {
                XCTAssertEqual(error as? EntityAnchorLinkGuardError, .issuerIsNotTheEntity(stranger.uuid))
            }
        }
        // Bare eierens egen nøkkel, på en vert uten kravet, kan ta imot en lenke andre har utstedt.
        try await EntityAnchorLinkGuard.requireIssuer(strangerDescriptor, owner: owner, identityDomain: "private",
            requesterProvesOwnership: true, freshAuthenticationRequired: false, registry: registry)
        // Entitetens egen utsteder godtas alltid.
        try await EntityAnchorLinkGuard.requireIssuer(ownerDescriptor, owner: owner, identityDomain: "private",
            requesterProvesOwnership: false, freshAuthenticationRequired: true, registry: registry)
        do {
            try await EntityAnchorLinkGuard.requireApprover(stranger, owner: owner, identityDomain: "private", registry: registry)
            XCTFail("en fremmed godkjenner skal avvises")
        } catch {
            XCTAssertEqual(error as? EntityAnchorLinkGuardError, .approverIsNotTheEntity(stranger.uuid))
        }
        try await EntityAnchorLinkGuard.requireApprover(owner, owner: owner, identityDomain: "private", registry: registry)
    }

    func testOnlyAWholeActiveLocalLinkInTheRightDomainBelongs() async throws {
        let owner = await vault.makeIdentity(displayName: "owner")
        let phone = await vault.makeIdentity(displayName: "phone")
        let descriptor = try IdentityLinkProtocolService.descriptor(for: phone)

        func belongs(_ record: IdentityLinkRecord, domain: String = "private") async -> Bool {
            let registry = IdentityLinkRegistry()
            await registry.restore(ownerUUID: owner.uuid, records: [record])
            return await EntityAnchorLinkGuard.belongsToEntity(descriptor, owner: owner, identityDomain: domain, registry: registry)
        }
        func record(scopes: [String] = [IdentityLinkScope.sameEntity], status: IdentityLinkStatus = .active,
                    binding: EntityBindingDescriptor = EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor")) -> IdentityLinkRecord {
            IdentityLinkRecord(
                linkID: "link-phone", entityBinding: binding, linkedIdentity: descriptor,
                approvedDomains: ["private"], approvedIdentityContexts: [], approvedScopes: scopes,
                issuerIdentityUUID: owner.uuid, issuerType: .existingDevice, status: status,
                linkedAt: IdentityLinkProtocolService.iso8601(Date()))
        }

        let whole = await belongs(record())
        XCTAssertTrue(whole, "en hel, aktiv lenke i dette ankeret er entiteten")
        let otherDomain = await belongs(record(), domain: "work")
        XCTAssertFalse(otherDomain, "domenet må stå i lenken")
        let revoked = await belongs(record(status: .revoked))
        XCTAssertFalse(revoked, "en tilbakekalt lenke godkjenner ingenting")
        let narrow = await belongs(record(scopes: ["read_profile"]))
        XCTAssertFalse(narrow, "en lenke uten same_entity godkjenner ingenting")
        let pairwise = await belongs(record(binding: EntityBindingDescriptor(mode: .pairwise, bindingID: "b1", audience: "register")))
        XCTAssertFalse(pairwise, "en parvis binding åpner ikke entiteten")
    }
}
