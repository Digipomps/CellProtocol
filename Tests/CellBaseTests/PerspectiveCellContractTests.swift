// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellApple

final class PerspectiveCellContractTests: XCTestCase {
    func testInitialPurposeTemplateUsesEventGoalReferenceAndConcreteGoalText() {
        let purpose = PerspectiveCell.initialPurposeTemplate(ownerUUID: "owner-123")

        XCTAssertEqual(purpose.name, "Initial Purpose")
        XCTAssertEqual(purpose.helperCells.count, 1)
        XCTAssertEqual(purpose.helperCells.first?.cellReferences?.first?.endpoint, "cell:///Purposes")

        guard let goal = purpose.goal else {
            XCTFail("Expected initial purpose goal")
            return
        }
        XCTAssertEqual(goal.cellReferences?.first?.endpoint, "cell:///EventGoal")
        XCTAssertTrue(goal.description?.contains("count > 1") ?? false)
        XCTAssertTrue(goal.description?.contains("weight >= 1.0") ?? false)
        XCTAssertTrue(goal.description?.contains("owner-123") ?? false)

        let report = PurposeGoalLint.evaluate(purpose)
        XCTAssertFalse(report.hasErrors, "Unexpected errors: \(report.findings)")
        XCTAssertFalse(report.hasWarnings, "Unexpected warnings: \(report.findings)")
    }
}
