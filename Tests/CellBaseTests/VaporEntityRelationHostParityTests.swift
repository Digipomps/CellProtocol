// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellVapor

extension EntityRelationHostParityTests {
    func testVaporRelationAdmissionMatrix() async throws {
        let owner = try await owner()
        try await verify(await EntityAnchorCell(owner: owner), owner: owner)
    }
}
