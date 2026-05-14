// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class TrustedIssuerCellContractTests: XCTestCase {
    func testTrustedIssuerContractsAdvertiseStateAndEvaluationSchemas() async throws {
        let previousVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previousVault }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!
        let cell = await TrustedIssuerCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "trustedIssuers.state",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "trustedIssuers.evaluate",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "trustedIssuers.evaluate",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "trustedIssuers.evaluate",
            input: .object([
                "issuerId": .string("did:key:test"),
                "contextId": .string("age_over_13"),
                "candidateVc": .object([:])
            ]),
            requester: outsider
        )
    }
}
