// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellApple

final class EntityScannerCellContractTests: XCTestCase {
    func testEntityScannerContractsAdvertiseCapabilitiesAndContactRequest() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await EntityScannerCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "capabilities",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "requestContact",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "requestContact",
            requester: owner,
            expected: ["-w--"]
        )

        let contract = try await CellContractHarness.contractObject(on: cell, key: "requestContact", requester: owner)
        let declaredTopics = ExploreContract.flowEffects(from: .object(contract)).compactMap {
            ExploreContract.string(from: $0[ExploreContract.Field.topic])
        }
        XCTAssertTrue(declaredTopics.contains("scanner.contact.pending"))
        XCTAssertTrue(declaredTopics.contains("scanner.contact.outgoing"))
        XCTAssertTrue(declaredTopics.contains("scanner.status"))

        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "requestContact",
            input: .string(UUID().uuidString),
            requester: outsider
        )
    }
}
