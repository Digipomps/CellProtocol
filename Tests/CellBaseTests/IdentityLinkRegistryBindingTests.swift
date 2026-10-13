// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

// purpose://candidate.entitetsdata.authorization-resolves-entity — the one
// hardening this task adds to the resolver main already has: only a link bound
// to the local anchor opens the entity. Pairwise and blinded bindings are for
// proving membership to others.
final class IdentityLinkRegistryBindingTests: XCTestCase {
    func testOnlyLocalEntityAnchorBindingOpensTheEntity() async throws {
        let vault = OrganizerAccessTestIdentityVault()
        let owner = await vault.makeIdentity(displayName: "owner")
        let phone = await vault.makeIdentity(displayName: "phone")
        let descriptor = try IdentityLinkProtocolService.descriptor(for: phone)
        let registry = IdentityLinkRegistry()

        func record(_ id: String, _ binding: EntityBindingDescriptor) -> IdentityLinkRecord {
            IdentityLinkRecord(
                linkID: id, entityBinding: binding, linkedIdentity: descriptor,
                approvedDomains: ["private"], approvedIdentityContexts: [],
                approvedScopes: [IdentityLinkScope.sameEntity],
                issuerIdentityUUID: owner.uuid, issuerType: .existingDevice,
                status: .active, linkedAt: IdentityLinkProtocolService.iso8601(Date())
            )
        }

        await registry.restore(ownerUUID: owner.uuid, records: [
            record("pairwise", EntityBindingDescriptor(mode: .pairwise, bindingID: "b1", audience: "register")),
            record("blinded", EntityBindingDescriptor(mode: .blinded, bindingID: "b2", audience: "register"))
        ])
        let none = await registry.sameEntityLink(
            ownerUUID: owner.uuid, requesterUUID: phone.uuid,
            requesterSigningKey: descriptor.publicKey, domain: "private"
        )
        XCTAssertNil(none, "pairwise/blinded bindings must not resolve as same entity")

        await registry.restore(ownerUUID: owner.uuid, records: [
            record("local", EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: EntityGenesisService.anchorReference))
        ])
        let local = await registry.sameEntityLink(
            ownerUUID: owner.uuid, requesterUUID: phone.uuid,
            requesterSigningKey: descriptor.publicKey, domain: "private"
        )
        XCTAssertEqual(local?.linkID, "local")
    }
}
