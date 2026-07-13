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

    func testWeightedGraphRuntimeRecordsScoredEvidenceForOneHopMatch() async throws {
        let interest = Interest(name: "runtime-interest", types: [], parts: [], partOf: [], purposes: [])
        let source = Purpose(
            name: "runtime-source-purpose",
            description: "source",
            interests: [Weight<Interest>(weight: 0.5, value: interest)]
        )
        let collector = HitCollector()
        let signal = Signal(
            relationship: .interests,
            weight: 0.5,
            tolerance: 0.01,
            token: "runtime-one-hop",
            collector: collector
        )

        let result = try await WeightedGraphRuntime().match(start: source, signal: signal)
        let hit = try XCTUnwrap(result.hits.first)
        let evidence = try XCTUnwrap(hit.evidence.first)
        let collectorHits = await collector.hitResults()
        let collectorHit = try XCTUnwrap(collectorHits.first)

        XCTAssertEqual(hit.ref, interest.reference)
        XCTAssertEqual(hit.node.kind, .interest)
        XCTAssertEqual(hit.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(hit.path.map(\.reference), [source.reference, interest.reference])
        XCTAssertEqual(evidence.relationship, .interests)
        XCTAssertEqual(evidence.from.reference, source.reference)
        XCTAssertEqual(evidence.to.reference, interest.reference)
        XCTAssertTrue(result.visitedRefs.contains("interest:\(interest.reference)"))
        XCTAssertEqual(collectorHit.ref, interest.reference)
        XCTAssertEqual(result.diagnostics.framesEnqueued, 1)
        XCTAssertEqual(result.diagnostics.framesDequeued, 1)
        XCTAssertEqual(result.diagnostics.edgesExamined, 1)
        XCTAssertEqual(result.diagnostics.edgesWithinTolerance, 1)
        XCTAssertEqual(result.diagnostics.hitsRecorded, 1)
        XCTAssertEqual(result.diagnostics.collectorRecords, 1)
        XCTAssertEqual(result.diagnostics.uniqueVisitedCount, 2)
        XCTAssertEqual(result.diagnostics.uniqueHitCount, 1)
    }

    func testWeightedGraphRuntimeTraversesMultipleRelationshipsAcrossHops() async throws {
        let target = Purpose(name: "runtime-target-purpose", description: "target")
        let bridge = Interest(name: "runtime-bridge-interest", types: [], parts: [], partOf: [], purposes: [
            Weight<Purpose>(weight: 0.5, value: target)
        ])
        let source = Purpose(
            name: "runtime-multihop-source",
            description: "source",
            interests: [Weight<Interest>(weight: 0.5, value: bridge)]
        )
        let signal = Signal(
            relationship: .interests,
            weight: 0.5,
            tolerance: 0.01,
            token: "runtime-multihop",
            hops: 2
        )
        let configuration = WeightedGraphRuntimeConfiguration(
            relationships: [.interests, .purposes],
            maxHops: 2,
            ttl: 1.0
        )

        let result = try await WeightedGraphRuntime().match(
            start: source,
            signal: signal,
            configuration: configuration
        )
        let targetHit = try XCTUnwrap(result.hits.first(where: { $0.ref == target.reference }))

        XCTAssertEqual(targetHit.node.kind, .purpose)
        XCTAssertEqual(targetHit.depth, 2)
        XCTAssertEqual(targetHit.path.map(\.reference), [source.reference, bridge.reference, target.reference])
        XCTAssertEqual(targetHit.evidence.map(\.relationship), [.interests, .purposes])
        XCTAssertEqual(result.maxDepthReached, 2)
        XCTAssertEqual(result.diagnostics.framesEnqueued, 2)
        XCTAssertEqual(result.diagnostics.framesDequeued, 2)
        XCTAssertEqual(result.diagnostics.edgesExamined, 2)
        XCTAssertEqual(result.diagnostics.hitsRecorded, 2)
        XCTAssertEqual(result.diagnostics.skippedByMaxHops, 1)
    }

    func testMatchResultDecodesLegacyPayloadWithoutDiagnostics() throws {
        let data = Data(
            """
            {
              "token": "legacy-runtime-result",
              "hits": [],
              "visitedRefs": [],
              "accumulatedEvidence": [],
              "localVariables": {},
              "elapsedSeconds": 0.0,
              "expired": false,
              "maxDepthReached": 0
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(MatchResult.self, from: data)

        XCTAssertEqual(decoded.token, "legacy-runtime-result")
        XCTAssertEqual(decoded.diagnostics, MatchDiagnostics())
    }

    func testWeightedGraphRuntimeDoesNotLoopThroughCycles() async throws {
        let source = Purpose(name: "runtime-cycle-source", description: "source")
        let target = Purpose(name: "runtime-cycle-target", description: "target")
        source.purposes = [Weight<Purpose>(weight: 0.5, value: target)]
        target.purposes = [Weight<Purpose>(weight: 0.5, value: source)]
        let signal = Signal(
            relationship: .purposes,
            weight: 0.5,
            tolerance: 0.01,
            token: "runtime-cycle",
            hops: 4
        )

        let result = try await WeightedGraphRuntime().match(start: source, signal: signal)
        let refs = Set(result.hits.map(\.ref))

        XCTAssertTrue(refs.contains(target.reference))
        XCTAssertFalse(refs.contains(source.reference))
        XCTAssertEqual(result.maxDepthReached, 1)
        XCTAssertTrue(result.visitedRefs.contains("purpose:\(source.reference)"))
        XCTAssertTrue(result.visitedRefs.contains("purpose:\(target.reference)"))
    }

    func testInterestConditionPurposeSolvedWithinRequiresFreshSuccessfulResolution() {
        let condition = InterestCondition.purposeSolvedWithin(
            PurposeSolvedWithinCondition(
                purposeRef: "purpose.answer-cellprotocol-question",
                maxAgeSeconds: 60.0
            )
        )
        let freshContext = InterestConditionContext(
            evaluatedAt: 1_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.answer-cellprotocol-question",
                    resolvedAt: 950.0
                )
            ]
        )
        let staleContext = InterestConditionContext(
            evaluatedAt: 1_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.answer-cellprotocol-question",
                    resolvedAt: 900.0
                )
            ]
        )
        let failedContext = InterestConditionContext(
            evaluatedAt: 1_000.0,
            purposeResolutions: [
                PurposeResolutionRecord(
                    purposeRef: "purpose.answer-cellprotocol-question",
                    status: .failed,
                    resolvedAt: 990.0
                )
            ]
        )

        XCTAssertTrue(condition.evaluate(in: freshContext))
        XCTAssertFalse(condition.evaluate(in: staleContext))
        XCTAssertFalse(condition.evaluate(in: failedContext))
        XCTAssertFalse(condition.evaluate(in: nil))
    }

    func testInterestConditionSupportsDocumentationMetadataFreshness() {
        let condition = InterestCondition.metadataFreshness(
            MetadataFreshnessCondition(
                key: "doc.Book/15_Documentation_Discovery_and_RAG.last_verified",
                maxAgeSeconds: 86_400.0
            )
        )
        let freshContext = InterestConditionContext(
            evaluatedAt: 200_000.0,
            metadataTimestamps: [
                "doc.Book/15_Documentation_Discovery_and_RAG.last_verified": 150_000.0
            ]
        )
        let staleContext = InterestConditionContext(
            evaluatedAt: 200_000.0,
            metadataTimestamps: [
                "doc.Book/15_Documentation_Discovery_and_RAG.last_verified": 20_000.0
            ]
        )

        XCTAssertTrue(condition.evaluate(in: freshContext))
        XCTAssertFalse(condition.evaluate(in: staleContext))
    }

    func testInterestConditionRoundTripsThroughInterestConstraintField() throws {
        let condition = InterestCondition.all([
            .purposeSolvedWithin(
                PurposeSolvedWithinCondition(
                    purposeRef: "purpose.verify-contracts",
                    maxAgeSeconds: 3_600.0
                )
            ),
            .metadataFreshness(
                MetadataFreshnessCondition(
                    key: "doc.contracts.last_verified",
                    maxAgeSeconds: 86_400.0
                )
            )
        ])
        let interest = Interest(
            name: "interest.contract-docs-current",
            types: [],
            parts: [],
            partOf: [],
            purposes: [],
            condition: condition
        )

        let data = try JSONEncoder().encode(interest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(Interest.self, from: data)

        XCTAssertTrue(json.contains("\"constraint\""))
        XCTAssertTrue(json.contains("\"type\":\"all\""))
        XCTAssertEqual(decoded.condition, condition)
    }

    func testWeightedGraphRuntimeFiltersInterestHitsByConditionContext() async throws {
        let gatedInterest = Interest(
            name: "interest.docs-runtime-verified",
            types: [],
            parts: [],
            partOf: [],
            purposes: [],
            condition: .purposeSolvedWithin(
                PurposeSolvedWithinCondition(
                    purposeRef: "purpose.verify-cellprotocol-docs",
                    maxAgeSeconds: 120.0
                )
            )
        )
        let source = Purpose(
            name: "purpose.answer-doc-question",
            description: "Answer a CellProtocol documentation question.",
            interests: [Weight<Interest>(weight: 0.5, value: gatedInterest)]
        )
        let signal = Signal(
            relationship: .interests,
            weight: 0.5,
            tolerance: 0.01,
            token: "runtime-condition"
        )
        let staleConfig = WeightedGraphRuntimeConfiguration(
            relationships: [.interests],
            maxHops: 1,
            ttl: 1.0,
            conditionContext: InterestConditionContext(
                evaluatedAt: 1_000.0,
                purposeResolutions: [
                    PurposeResolutionRecord(
                        purposeRef: "purpose.verify-cellprotocol-docs",
                        resolvedAt: 800.0
                    )
                ]
            )
        )
        let freshConfig = WeightedGraphRuntimeConfiguration(
            relationships: [.interests],
            maxHops: 1,
            ttl: 1.0,
            conditionContext: InterestConditionContext(
                evaluatedAt: 1_000.0,
                purposeResolutions: [
                    PurposeResolutionRecord(
                        purposeRef: "purpose.verify-cellprotocol-docs",
                        resolvedAt: 950.0
                    )
                ]
            )
        )

        let noContextResult = try await WeightedGraphRuntime().match(start: source, signal: signal)
        let staleResult = try await WeightedGraphRuntime().match(start: source, signal: signal, configuration: staleConfig)
        let freshResult = try await WeightedGraphRuntime().match(start: source, signal: signal, configuration: freshConfig)

        XCTAssertTrue(noContextResult.hits.isEmpty)
        XCTAssertTrue(staleResult.hits.isEmpty)
        XCTAssertEqual(freshResult.hits.first?.ref, gatedInterest.reference)
    }
}
