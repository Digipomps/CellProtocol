// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class SDGPilotPurposeCatalogTests: XCTestCase {
    func testPilotCatalogExposesThreeDomains() {
        XCTAssertEqual(Set(SDGPilotDomain.allCases), [
            .climateMobility,
            .localChildParticipation,
            .institutionalAccountability
        ])
        XCTAssertEqual(SDGPilotPurposeCatalog.templates().count, 3)
    }

    func testPilotPurposesExposeConcreteGoalsAndHelpers() throws {
        for domain in SDGPilotDomain.allCases {
            let purpose = SDGPilotPurposeCatalog.makePurpose(for: domain)
            let goal = try purpose.getGoal()
            let helpers = try purpose.getHelpers()
            let report = PurposeGoalLint.evaluate(purpose)

            XCTAssertFalse(goal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(helpers.count, 3)
            XCTAssertFalse(report.hasErrors, "Unexpected lint errors for \(domain): \(report.findings)")
            XCTAssertFalse(report.hasWarnings, "Unexpected lint warnings for \(domain): \(report.findings)")
        }
    }

    func testClimatePilotHelperCellsCoverBaselineEvidenceAndFairness() throws {
        let purpose = SDGPilotPurposeCatalog.makePurpose(for: .climateMobility)
        let helpers = try purpose.getHelpers()

        XCTAssertEqual(helpers.map(\.name), [
            "Decarbonize member mobility baseline capture",
            "Decarbonize member mobility evidence routing",
            "Decarbonize member mobility fairness guardrail"
        ])

        let baselineEndpoints = Set(helpers[0].cellReferences?.map(\.endpoint) ?? [])
        let evidenceEndpoints = Set(helpers[1].cellReferences?.map(\.endpoint) ?? [])
        let fairnessEndpoints = Set(helpers[2].cellReferences?.map(\.endpoint) ?? [])

        XCTAssertEqual(baselineEndpoints, ["cell:///Vault"])
        XCTAssertEqual(evidenceEndpoints, ["cell:///CommonsResolver"])
        XCTAssertEqual(fairnessEndpoints, ["cell:///CommonsTaxonomy", "cell:///EntityAtlas"])
    }

    func testInstitutionalAccountabilityPilotRoundTripsThroughPurposeSerialization() throws {
        let purpose = SDGPilotPurposeCatalog.makePurpose(for: .institutionalAccountability)
        let data = try JSONEncoder().encode(purpose)
        let decoded = try JSONDecoder().decode(Purpose.self, from: data)

        XCTAssertEqual(decoded.name, "Publish accountable decisions within the agreed window")
        XCTAssertEqual(try decoded.getHelpers().count, 3)
        XCTAssertEqual(try decoded.getGoal().name, "Publish accountable decisions within the agreed window goal")
    }
}
