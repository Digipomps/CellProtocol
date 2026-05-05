// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentitiesCellContractTests: XCTestCase {
    func testIdentitiesCellAdvertisesIdentityListAndEnforcesReadAccess() async throws {
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let outsider = TestFixtures.makeIdentity(displayName: "outsider", uuid: TestFixtures.fixedUUID2)
        let visitor = TestFixtures.makeIdentity(displayName: "visitor", uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
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
