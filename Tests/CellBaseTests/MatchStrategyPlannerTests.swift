// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class MatchStrategyPlannerTests: XCTestCase {
    func testPlannerUsesGpuBatchSparseFilterForLargeNonSensitiveCandidateSet() {
        let plan = MatchStrategyPlanner().plan(
            for: MatchTaskProfile(
                candidateCount: 2_000,
                activeInterestCount: 4,
                preconfiguredGraphAvailable: true,
                precomputedAdjacencyAvailable: false,
                batchSize: 64,
                gpuAvailable: true
            )
        )

        XCTAssertEqual(plan.primary.kind, .sparseVectorFilter)
        XCTAssertEqual(plan.primary.cognitiveMode, .system1Preconfigured)
        XCTAssertEqual(plan.primary.computePlacement, .gpuBatch)
        XCTAssertGreaterThan(plan.primary.gpuSuitability, 0.8)
        XCTAssertEqual(plan.primary.recommendedBatchSize, 64)
    }

    func testPlannerPrefersCachedWeightedSignalWhenAdjacencyAndExplanationAreNeeded() {
        let plan = MatchStrategyPlanner().plan(
            for: MatchTaskProfile(
                candidateCount: 2_000,
                activeInterestCount: 4,
                preconfiguredGraphAvailable: true,
                precomputedAdjacencyAvailable: true,
                requiresExplanation: true,
                batchSize: 1,
                gpuAvailable: true
            )
        )

        XCTAssertEqual(plan.primary.kind, .cachedWeightedSignal)
        XCTAssertEqual(plan.primary.computePlacement, .cpuLocal)
        XCTAssertEqual(plan.primary.cognitiveMode, .system1Preconfigured)
        XCTAssertTrue(plan.primary.rationale.contains { $0.contains("adjacency index is precomputed") })
    }

    func testPlannerUsesLayeredSignalForPrivacyAndLocalVariables() {
        let plan = MatchStrategyPlanner().plan(
            for: MatchTaskProfile(
                candidateCount: 500,
                activeInterestCount: 5,
                preconfiguredGraphAvailable: true,
                precomputedAdjacencyAvailable: false,
                localVariableLayerCount: 3,
                privacySensitivity: 0.95,
                batchSize: 32,
                gpuAvailable: true
            )
        )

        XCTAssertEqual(plan.primary.kind, .layeredSignal)
        XCTAssertEqual(plan.primary.cognitiveMode, .system1Preconfigured)
        XCTAssertTrue(plan.escalationTriggers.contains(.privacyOrCapabilityGate))
        XCTAssertNotEqual(plan.primary.kind, .sparseVectorFilter)
    }

    func testPlannerUsesSystem2WhenKnowledgeMustBeExtracted() {
        let plan = MatchStrategyPlanner().plan(
            for: MatchTaskProfile(
                candidateCount: 50,
                activeInterestCount: 0,
                preconfiguredGraphAvailable: false,
                requiresNewKnowledgeExtraction: true,
                ambiguity: 0.8,
                batchSize: 8,
                gpuAvailable: false
            )
        )

        XCTAssertEqual(plan.primary.kind, .deepReconfiguration)
        XCTAssertEqual(plan.primary.cognitiveMode, .system2Reconfiguration)
        XCTAssertTrue(plan.escalationTriggers.contains(.requiresNewKnowledge))
        XCTAssertTrue(plan.escalationTriggers.contains(.missingPreconfiguredCoverage))
    }
}
