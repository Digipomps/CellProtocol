// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase
@testable import CellApple

final class SkeletonActionButtonExecutionTests: XCTestCase {
    func testNavigationButtonRoundTripsWithoutBecomingCellAction() throws {
        let button = SkeletonButton(
            keypath: "",
            label: "Open The Butterpop Collective",
            url: "/butterpop"
        )
        let encoded = try JSONEncoder().encode(SkeletonElement.Button(button))
        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: encoded)

        guard case let .Button(decodedButton) = decoded else {
            return XCTFail("Expected Button")
        }
        XCTAssertEqual(decodedButton.keypath, "")
        XCTAssertEqual(decodedButton.url, "/butterpop")
        XCTAssertTrue(SkeletonButtonNavigation.isNavigationButton(decodedButton))
    }

    func testNavigationPolicyAllowsHTTPSAndLoopbackButRejectsUnsafeSchemes() {
        let https = SkeletonButton(keypath: "", label: "Open", url: "https://music.example/butterpop")
        XCTAssertEqual(
            SkeletonButtonNavigation.resolveURL(for: https)?.absoluteString,
            "https://music.example/butterpop"
        )

        let relative = SkeletonButton(keypath: "", label: "Open", url: "/butterpop")
        XCTAssertEqual(
            SkeletonButtonNavigation.resolveURL(
                for: relative,
                relativeTo: URL(string: "https://haven.example/porthole")
            )?.absoluteString,
            "https://haven.example/butterpop"
        )
        XCTAssertEqual(
            SkeletonButtonNavigation.resolveURL(
                for: relative,
                relativeTo: URL(string: "http://127.0.0.1:9097/porthole")
            )?.absoluteString,
            "http://127.0.0.1:9097/butterpop"
        )

        let unsafeHTTP = SkeletonButton(keypath: "", label: "Open", url: "http://music.example/butterpop")
        let unsafeScheme = SkeletonButton(keypath: "", label: "Open", url: "javascript:alert(1)")
        let credentialURL = SkeletonButton(keypath: "", label: "Open", url: "https://user:pass@music.example")
        let protocolRelativeURL = SkeletonButton(keypath: "", label: "Open", url: "//music.example/butterpop")
        XCTAssertNil(SkeletonButtonNavigation.resolveURL(for: unsafeHTTP))
        XCTAssertNil(SkeletonButtonNavigation.resolveURL(for: unsafeScheme))
        XCTAssertNil(SkeletonButtonNavigation.resolveURL(for: credentialURL))
        XCTAssertNil(
            SkeletonButtonNavigation.resolveURL(
                for: protocolRelativeURL,
                relativeTo: URL(string: "https://haven.example/porthole")
            )
        )
    }

    func testNonEmptyKeypathKeepsURLButtonAsCellAction() {
        let button = SkeletonButton(
            keypath: "musicWorkspace.publishSelectedMix",
            label: "Publish",
            url: "cell:///MusicWorkspace"
        )
        XCTAssertFalse(SkeletonButtonNavigation.isNavigationButton(button))
        XCTAssertNil(SkeletonButtonNavigation.resolveURL(for: button))
    }

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
