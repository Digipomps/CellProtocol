// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class PurposeAndInterestMatchingTests: XCTestCase {
    private func signal(
        relationship: PerspectiveRelationship,
        weight: Double = 0.5,
        tolerance: Double = 0.01,
        collector: HitCollector
    ) -> Signal {
        Signal(
            relationship: relationship,
            weight: weight,
            tolerance: tolerance,
            token: UUID().uuidString,
            collector: collector
        )
    }

    private func assertMatch(
        matcher: any WeightedMatch,
        relationship: PerspectiveRelationship,
        expectedRef: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let collector = HitCollector()
        try await matcher.match(signal: signal(relationship: relationship, collector: collector))
        let hits = await collector.results()
        XCTAssertTrue(
            hits.contains(expectedRef),
            "Expected hit for relationship \(relationship), got \(hits)",
            file: file,
            line: line
        )
    }

    private func assertNoMatch(
        matcher: any WeightedMatch,
        relationship: PerspectiveRelationship,
        weight: Double,
        tolerance: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let collector = HitCollector()
        try await matcher.match(
            signal: signal(
                relationship: relationship,
                weight: weight,
                tolerance: tolerance,
                collector: collector
            )
        )
        let hits = await collector.results()
        XCTAssertTrue(
            hits.isEmpty,
            "Expected no hits for relationship \(relationship), got \(hits)",
            file: file,
            line: line
        )
    }

    func testPurposeMatchingSupportsTypesSubTypesPartsPartOfAndStates() async throws {
        let type = Purpose(name: "purpose-type", description: "type")
        let subtype = Purpose(name: "purpose-subtype", description: "subtype")
        let part = Purpose(name: "purpose-part", description: "part")
        let parent = Purpose(name: "purpose-parent", description: "parent")
        let state = Interest(name: "purpose-state", types: [], parts: [], partOf: [], purposes: [])

        let source = Purpose(
            name: "source-purpose",
            description: "source",
            states: [Weight<Interest>(weight: 0.5, value: state)],
            types: [Weight<Purpose>(weight: 0.5, value: type)],
            subTypes: [Weight<Purpose>(weight: 0.5, value: subtype)],
            parts: [Weight<Purpose>(weight: 0.5, value: part)],
            partOf: [Weight<Purpose>(weight: 0.5, value: parent)]
        )

        try await assertMatch(matcher: source, relationship: .types, expectedRef: type.reference)
        try await assertMatch(matcher: source, relationship: .subTypes, expectedRef: subtype.reference)
        try await assertMatch(matcher: source, relationship: .parts, expectedRef: part.reference)
        try await assertMatch(matcher: source, relationship: .partOf, expectedRef: parent.reference)
        try await assertMatch(matcher: source, relationship: .states, expectedRef: state.reference)
    }

    func testInterestMatchingSupportsTypesSubTypesPartsPartOfAndStates() async throws {
        let type = Interest(name: "interest-type", types: [], parts: [], partOf: [], purposes: [])
        let subtype = Interest(name: "interest-subtype", types: [], parts: [], partOf: [], purposes: [])
        let part = Interest(name: "interest-part", types: [], parts: [], partOf: [], purposes: [])
        let parent = Interest(name: "interest-parent", types: [], parts: [], partOf: [], purposes: [])
        let state = Interest(name: "interest-state", types: [], parts: [], partOf: [], purposes: [])

        let source = Interest(
            name: "source-interest",
            types: [Weight<Interest>(weight: 0.5, value: type)],
            parts: [Weight<Interest>(weight: 0.5, value: part)],
            partOf: [Weight<Interest>(weight: 0.5, value: parent)],
            purposes: []
        )
        source.subTypes = [Weight<Interest>(weight: 0.5, value: subtype)]
        source.states = [Weight<Interest>(weight: 0.5, value: state)]

        try await assertMatch(matcher: source, relationship: .types, expectedRef: type.reference)
        try await assertMatch(matcher: source, relationship: .subTypes, expectedRef: subtype.reference)
        try await assertMatch(matcher: source, relationship: .parts, expectedRef: part.reference)
        try await assertMatch(matcher: source, relationship: .partOf, expectedRef: parent.reference)
        try await assertMatch(matcher: source, relationship: .states, expectedRef: state.reference)
    }

    func testEntityRepresentationMatchingSupportsTypesSubTypesPartsPartOfAndStates() async throws {
        let type = EntityRepresentation(name: "entity-type")
        let subtype = EntityRepresentation(name: "entity-subtype")
        let part = EntityRepresentation(name: "entity-part")
        let parent = EntityRepresentation(name: "entity-parent")
        let state = Interest(name: "entity-state", types: [], parts: [], partOf: [], purposes: [])

        let source = EntityRepresentation(
            states: [Weight<Interest>(weight: 0.5, value: state)],
            name: "source-entity",
            types: [Weight<EntityRepresentation>(weight: 0.5, value: type)],
            subTypes: [Weight<EntityRepresentation>(weight: 0.5, value: subtype)],
            parts: [Weight<EntityRepresentation>(weight: 0.5, value: part)],
            partOf: [Weight<EntityRepresentation>(weight: 0.5, value: parent)]
        )

        try await assertMatch(matcher: source, relationship: .types, expectedRef: type.reference)
        try await assertMatch(matcher: source, relationship: .subTypes, expectedRef: subtype.reference)
        try await assertMatch(matcher: source, relationship: .parts, expectedRef: part.reference)
        try await assertMatch(matcher: source, relationship: .partOf, expectedRef: parent.reference)
        try await assertMatch(matcher: source, relationship: .states, expectedRef: state.reference)
    }

    func testMatchingDoesNotHitOutsideTolerance() async throws {
        let type = Purpose(name: "tolerance-purpose-type", description: "type")
        let source = Purpose(
            name: "tolerance-source-purpose",
            description: "source",
            types: [Weight<Purpose>(weight: 0.5, value: type)]
        )

        try await assertNoMatch(
            matcher: source,
            relationship: .types,
            weight: 0.9,
            tolerance: 0.05
        )
    }
}
