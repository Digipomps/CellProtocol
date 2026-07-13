// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(Testing) @testable import CellBase
@testable import CellApple

final class PortholeViewModelAvailabilityTests: XCTestCase {
    @MainActor
    func testInitializationRemainsIdleWhenPortholeIsUnavailable() async {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        try? await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            type: GeneralCell.self
        )

        let viewModel = PortholeViewModel()
        await viewModel.initializationTask?.value

        XCTAssertNil(viewModel.portholeCell)

        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        await resolver.resetRuntimeStateForTesting()
    }
}
