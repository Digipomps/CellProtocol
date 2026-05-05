// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class PurposeGoalLintTests: XCTestCase {
    func testPurposeGoalLintFlagsMissingDescriptionAndGoal() {
        let purpose = Purpose(name: "Contract helper", description: "")

        let report = PurposeGoalLint.evaluate(purpose)
        let codes = Set(report.findings.map(\.code))

        XCTAssertTrue(codes.contains("purpose.description.missing"))
        XCTAssertTrue(codes.contains("goal.missing"))
        XCTAssertTrue(report.hasWarnings)
    }

    func testPurposeGoalLintAcceptsConcreteGoal() {
        var goal = CellConfiguration(name: "Approve contract")
        goal.description = "Success when the person presses approve and the contract state becomes signed."

        let purpose = Purpose(
            name: "Approve contract flow",
            description: "Guide the person through contract approval and expose the signed state.",
            goal: goal,
            helperCells: [CellConfiguration(name: "Approval helper")]
        )

        let report = PurposeGoalLint.evaluate(purpose)

        XCTAssertFalse(report.hasErrors)
        XCTAssertFalse(report.hasWarnings, "Unexpected findings: \(report.findings)")
    }

    func testPurposeGoalLintFlagsVagueGoalWording() {
        var goal = CellConfiguration(name: "Make things better")
        goal.description = "Improve the experience eventually."

        let purpose = Purpose(
            name: "General improvement",
            description: "Improve things for users.",
            goal: goal
        )

        let report = PurposeGoalLint.evaluate(purpose)
        let codes = Set(report.findings.map(\.code))

        XCTAssertTrue(codes.contains("goal.wording.vague"))
        XCTAssertTrue(codes.contains("goal.timeline.unbounded"))
        XCTAssertTrue(codes.contains("goal.successSignal.missing"))
    }

    func testPurposeGoalLintHelperCellsSuppressMissingGoalWarning() {
        let purpose = Purpose(
            name: "Guide onboarding",
            description: "Guide the person to complete onboarding by opening the correct helper flow.",
            helperCells: [CellConfiguration(name: "Onboarding helper")]
        )

        let report = PurposeGoalLint.evaluate(purpose)
        let codes = Set(report.findings.map(\.code))

        XCTAssertFalse(codes.contains("goal.missing"))
    }
}
