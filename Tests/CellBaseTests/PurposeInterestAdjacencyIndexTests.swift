// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class PurposeInterestAdjacencyIndexTests: XCTestCase {
    func testRanksPurposesFromPrecomputedInterestAdjacency() {
        let index = PurposeInterestAdjacencyIndex(
            purposeRefs: [
                "purpose.alpha",
                "purpose.beta",
                "purpose.empty"
            ],
            edges: [
                .init(interestRef: "interest.a", purposeRef: "purpose.alpha", weight: 0.30),
                .init(interestRef: "interest.b", purposeRef: "purpose.alpha", weight: 0.20),
                .init(interestRef: "interest.a", purposeRef: "purpose.beta", weight: 0.80)
            ]
        )

        let rankings = index.rankedPurposes(for: [
            "interest.b",
            "interest.a",
            "interest.a"
        ])

        XCTAssertEqual(rankings.map(\.purposeRef), [
            "purpose.beta",
            "purpose.alpha",
            "purpose.empty"
        ])
        XCTAssertEqual(rankings[0].score, 0.80, accuracy: 0.000_001)
        XCTAssertEqual(rankings[0].matchedInterestRefs, ["interest.a"])
        XCTAssertEqual(rankings[1].score, 0.50, accuracy: 0.000_001)
        XCTAssertEqual(rankings[1].matchedInterestRefs, ["interest.a", "interest.b"])
        XCTAssertEqual(rankings[2].score, 0.0, accuracy: 0.000_001)
        XCTAssertTrue(rankings[2].matchedInterestRefs.isEmpty)
    }

    func testRanksTiesByPurposeRefForDeterministicOutput() {
        let index = PurposeInterestAdjacencyIndex(
            purposeRefs: [
                "purpose.zulu",
                "purpose.alpha"
            ],
            edges: [
                .init(interestRef: "interest.shared", purposeRef: "purpose.zulu", weight: 0.50),
                .init(interestRef: "interest.shared", purposeRef: "purpose.alpha", weight: 0.50)
            ]
        )

        let rankings = index.rankedPurposes(for: ["interest.shared"])

        XCTAssertEqual(rankings.map(\.purposeRef), [
            "purpose.alpha",
            "purpose.zulu"
        ])
    }

    func testCodableRoundTripPreservesIndexContract() throws {
        let index = PurposeInterestAdjacencyIndex(
            purposeRefs: ["purpose.alpha"],
            edges: [
                .init(interestRef: "interest.a", purposeRef: "purpose.alpha", weight: 0.70)
            ]
        )

        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(PurposeInterestAdjacencyIndex.self, from: data)

        XCTAssertEqual(decoded, index)
        XCTAssertEqual(decoded.rankedPurposes(for: ["interest.a"]).first?.purposeRef, "purpose.alpha")
    }
}
