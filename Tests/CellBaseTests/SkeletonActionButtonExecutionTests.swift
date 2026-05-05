// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase
@testable import CellApple

final class SkeletonActionButtonExecutionTests: XCTestCase {
    func testSkeletonButtonRequiresExplicitRequester() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
        }

        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let privateIdentity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let sourceIdentity = await vault.identity(for: "conference-shell", makeNewIfNotFound: true)!

        let cell = await GeneralCell(owner: sourceIdentity)
        await cell.addInterceptForGet(requester: sourceIdentity, key: "state.title") { _, _ in
            .string("Conference AI Assistant")
        }
        try await resolver.registerNamedEmitCell(
            name: "Porthole",
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: sourceIdentity
        )

        let button = SkeletonButton(
            keypath: "state.title",
            label: "Read title"
        )

        let withoutRequester = await button.execute(requester: nil)
        XCTAssertNil(withoutRequester)

        let withRequester = await button.execute(requester: sourceIdentity)
        XCTAssertEqual(withRequester, .string("Conference AI Assistant"))
        XCTAssertNotEqual(sourceIdentity.uuid, privateIdentity.uuid)
    }

    func testResolvedActionButtonPreservesExplicitPayloadOverCache() {
        let button = SkeletonButton(
            keypath: "aiGateway.setDraftPrompt",
            label: "Daily brief",
            payload: .string("preset prompt")
        )

        let resolved = resolvedActionButton(button, cachedValue: .string(""))

        XCTAssertEqual(resolved.payload, .string("preset prompt"))
    }

    func testResolvedActionButtonFallsBackToCachedPayloadWhenButtonHasNoPayload() {
        let button = SkeletonButton(
            keypath: "aiGateway.setDraftPrompt",
            label: "Reuse cached prompt",
            payload: nil
        )

        let resolved = resolvedActionButton(button, cachedValue: .string("cached prompt"))

        XCTAssertEqual(resolved.payload, .string("cached prompt"))
    }
}
