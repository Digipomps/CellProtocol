// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import HavenPerspectiveSchemas

final class PerspectiveSchemaTests: XCTestCase {
    func testPerspectiveGoalRoundTripsExtendedMeasurementFields() throws {
        let document = PerspectiveDocument(
            pre: .init(
                purposes: ["purpose.sdg.climate-stability-and-adaptation"],
                goals: [
                    .init(
                        goalID: "goal.sdg.climate.emissions-intensity-reduction",
                        purposeID: "purpose.sdg.climate-stability-and-adaptation",
                        description: "Reduce emissions intensity for member transport",
                        metric: "kgCO2e_per_member_km",
                        baseline: "0.42",
                        target: "<=0.34",
                        timeframe: "2026-01-01/2026-12-31",
                        dataSource: "chronicle://transport-emissions",
                        evidenceRule: "monthly_average <= 0.34",
                        indicatorRefs: ["13.2.2"],
                        incentiveOnly: true
                    )
                ],
                interests: ["interest.sustainability"],
                constraints: ["must_not_reduce_access_for_low_income_members"],
                visibilityPolicyRef: "policy://private"
            ),
            during: .init(),
            post: .init()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let decoded = try JSONDecoder().decode(PerspectiveDocument.self, from: data)

        XCTAssertEqual(decoded.pre.goals.first?.goalID, "goal.sdg.climate.emissions-intensity-reduction")
        XCTAssertEqual(decoded.pre.goals.first?.purposeID, "purpose.sdg.climate-stability-and-adaptation")
        XCTAssertEqual(decoded.pre.goals.first?.baseline, "0.42")
        XCTAssertEqual(decoded.pre.goals.first?.timeframe, "2026-01-01/2026-12-31")
        XCTAssertEqual(decoded.pre.goals.first?.dataSource, "chronicle://transport-emissions")
        XCTAssertEqual(decoded.pre.goals.first?.evidenceRule, "monthly_average <= 0.34")
        XCTAssertEqual(decoded.pre.goals.first?.indicatorRefs, ["13.2.2"])
    }

    func testSDGPilotPerspectiveExamplesDecode() throws {
        let examples: [(name: String, purposeID: String, goalID: String)] = [
            (
                name: "sdg-climate-mobility.json",
                purposeID: "purpose.sdg.climate.member-mobility-decarbonization",
                goalID: "goal.sdg.climate.member-mobility-emissions-intensity"
            ),
            (
                name: "sdg-local-child-participation.json",
                purposeID: "purpose.sdg.local-child-participation-and-belonging",
                goalID: "goal.sdg.local-child-participation.active-retention-rate"
            ),
            (
                name: "sdg-institutional-accountability.json",
                purposeID: "purpose.sdg.institutional-decision-transparency-and-remedy",
                goalID: "goal.sdg.institutional.decision-rationale-publication-latency"
            )
        ]

        let decoder = JSONDecoder()
        for example in examples {
            let data = try Data(contentsOf: exampleURL(named: example.name))
            let document = try decoder.decode(PerspectiveDocument.self, from: data)

            XCTAssertEqual(document.pre.goals.first?.goalID, example.goalID, example.name)
            XCTAssertEqual(document.pre.goals.first?.purposeID, example.purposeID, example.name)
            XCTAssertTrue(document.pre.purposes.contains("purpose.human-equal-worth"), example.name)
            XCTAssertTrue(document.pre.purposes.contains("purpose.net-positive-contribution"), example.name)
            XCTAssertEqual(document.during.goals.first?.goalID, example.goalID, example.name)
            XCTAssertEqual(document.post.goals.first?.goalID, example.goalID, example.name)
        }
    }

    func testOperationalPerspectiveExamplesDecode() throws {
        let examples: [(name: String, prePurpose: String, duringPurpose: String, postPurpose: String)] = [
            (
                name: "conference-ai-networking.json",
                prePurpose: "purpose.network",
                duringPurpose: "purpose.learn",
                postPurpose: "purpose.collaborate"
            ),
            (
                name: "restaurant-team-dinner.json",
                prePurpose: "purpose.buy",
                duringPurpose: "purpose.discuss",
                postPurpose: "purpose.share"
            ),
            (
                name: "work-hiring-and-collaboration.json",
                prePurpose: "purpose.hire",
                duringPurpose: "purpose.collaborate",
                postPurpose: "purpose.share"
            ),
            (
                name: "home-weekend-recovery.json",
                prePurpose: "purpose.home.recover-and-recreate",
                duringPurpose: "purpose.home.be-present",
                postPurpose: "purpose.home.reflect-and-reset"
            ),
            (
                name: "family-care-coordination.json",
                prePurpose: "purpose.family.coordinate-care",
                duringPurpose: "purpose.family.share-time",
                postPurpose: "purpose.family.adjust-plan"
            )
        ]

        let decoder = JSONDecoder()
        for example in examples {
            let data = try Data(contentsOf: exampleURL(named: example.name))
            let document = try decoder.decode(PerspectiveDocument.self, from: data)

            XCTAssertEqual(dominantPurpose(in: document.pre), example.prePurpose, example.name)
            XCTAssertEqual(dominantPurpose(in: document.during), example.duringPurpose, example.name)
            XCTAssertEqual(dominantPurpose(in: document.post), example.postPurpose, example.name)

            XCTAssertTrue(document.pre.purposes.contains("purpose.human-equal-worth"), example.name)
            XCTAssertTrue(document.pre.purposes.contains("purpose.net-positive-contribution"), example.name)
            XCTAssertFalse(document.pre.goals.isEmpty, example.name)
            XCTAssertFalse(document.during.goals.isEmpty, example.name)
            XCTAssertFalse(document.post.goals.isEmpty, example.name)
            XCTAssertFalse(document.pre.interests.isEmpty, example.name)
            XCTAssertFalse(document.during.interests.isEmpty, example.name)
            XCTAssertFalse(document.post.interests.isEmpty, example.name)
        }
    }

    private func exampleURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("commons/examples/perspectives/\(name)")
    }

    private func dominantPurpose(in snapshot: PerspectiveSnapshot) -> String? {
        let mandatoryPurposes: Set<String> = [
            "purpose.human-equal-worth",
            "purpose.net-positive-contribution"
        ]
        return snapshot.purposes.last(where: { !mandatoryPurposes.contains($0) }) ?? snapshot.purposes.last
    }
}
