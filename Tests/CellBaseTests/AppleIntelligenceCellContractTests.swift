// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellApple

final class AppleIntelligenceCellContractTests: XCTestCase {
    func testAppleIntelligenceContractsAdvertiseStateAndPromptKeys() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: "ai.state",
                requester: owner,
                expectedMethod: .get,
                expectedInputType: "null",
                expectedReturnType: "object"
            )
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: "ai.sendPrompt",
                requester: owner,
                expectedMethod: .set,
                expectedInputType: "oneOf",
                expectedReturnType: "string"
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: "ai.sendPrompt",
                requester: owner,
                expected: ["-w--"]
            )
            try await CellContractHarness.assertSetDenied(
                on: cell,
                key: "ai.sendPrompt",
                input: .string("hello"),
                requester: outsider
            )
        } else {
            throw XCTSkip("AppleIntelligenceCell contracts require macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }
}
