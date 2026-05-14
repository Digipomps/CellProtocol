// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentitiesCellContractTests: XCTestCase {
    func testIdentitiesCellAdvertisesIdentityListAndEnforcesReadAccess() async throws {
        let previousVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previousVault }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!
        let visitor = await vault.identity(for: "visitor", makeNewIfNotFound: true)!
        let cell = await IdentitiesCell(owner: owner)
        cell.visitingIdentities[visitor.uuid] = visitor

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "identities",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "identities",
            requester: owner,
            expected: ["r---"]
        )

        let value = try await cell.get(keypath: "identities", requester: owner)
        guard case .list(let identities) = value else {
            XCTFail("Expected identities list, got \(String(describing: value))")
            return
        }
        XCTAssertEqual(identities.count, 1)
        guard case .identity(let returnedIdentity) = identities.first else {
            XCTFail("Expected identity element")
            return
        }
        XCTAssertEqual(returnedIdentity.uuid, visitor.uuid)
        XCTAssertEqual(returnedIdentity.displayName, visitor.displayName)

        try await CellContractHarness.assertGetDenied(
            on: cell,
            key: "identities",
            requester: outsider
        )
    }
}
