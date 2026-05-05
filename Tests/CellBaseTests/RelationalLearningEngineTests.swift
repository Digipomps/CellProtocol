// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class RelationalLearningEngineTests: XCTestCase {
    func testReplayDeterminismProducesIdenticalEdgesAndScores() async throws {
        let now = 1_900_000_000.0

        let policyEvent = RelationalDecayPolicyUpdatedEvent(
            eventId: "policy-v1",
            emittedAt: 1_700_000_000.0,
            policy: .defaultNoa
        )

        let contextEvent = RelationalContextTransitionEvent(
            eventId: "ctx-1",
            timestamp: 1_700_000_100.0,
            domain: "location",
            fromBlockId: nil,
            toBlockId: "home",
            confidence: 0.9,
            metadata: ["source": "test"]
        )

        let started = RelationalPurposeLifecycleEvent(
            eventId: "life-start",
            timestamp: 1_700_000_200.0,
            status: .started,
            purposeId: "purpose://networking",
            activeInterestRefs: ["interest://privacy"],
            passiveInterestRefs: ["interest://digital-rights"],
            activeEntityRefs: ["entity://alice"],
            passiveEntityRefs: [],
            activeContextBlocks: [],
            contextConfidence: 0.95
        )

        let succeeded = RelationalPurposeLifecycleEvent(
            eventId: "life-succeeded",
            timestamp: 1_700_000_400.0,
            status: .succeeded,
            purposeId: "purpose://networking",
            activeInterestRefs: ["interest://privacy"],
            passiveInterestRefs: ["interest://digital-rights"],
            activeEntityRefs: ["entity://alice"],
            passiveEntityRefs: ["entity://bob"],
            activeContextBlocks: [RelationalContextBlockSignal(domain: "time", blockId: "morning", confidence: 0.8)],
            contextConfidence: 0.9
        )

        let eventLog = try [
            RelationalLearningEventEnvelope.from(policyEvent),
            RelationalLearningEventEnvelope.from(contextEvent),
            RelationalLearningEventEnvelope.from(started),
            RelationalLearningEventEnvelope.from(succeeded)
        ]

        let engineA = RelationalLearningEngine()
        let engineB = RelationalLearningEngine()

        _ = await engineA.replay(events: eventLog, resetFirst: true)
        _ = await engineB.replay(events: eventLog, resetFirst: true)

        let edgesA = await engineA.edges()
        let edgesB = await engineB.edges()

        XCTAssertEqual(try canonicalJSON(edgesA), try canonicalJSON(edgesB))

        let snapshot = RelationalContextSnapshot(
            activeInterestRefs: ["interest://privacy"],
            passiveInterestRefs: ["interest://digital-rights"],
            activeEntityRefs: ["entity://alice"],
            passiveEntityRefs: ["entity://bob"],
            activeContextBlocks: [
                RelationalContextBlockSignal(domain: "location", blockId: "home", confidence: 0.9),
                RelationalContextBlockSignal(domain: "time", blockId: "morning", confidence: 0.8)
            ]
        )

        let scoresA = await engineA.scorePurposes(contextSnapshot: snapshot, at: now)
        let scoresB = await engineB.scorePurposes(contextSnapshot: snapshot, at: now)

        XCTAssertEqual(try canonicalJSON(scoresA), try canonicalJSON(scoresB))
    }

    func testNoaDecayIsMonotonicWithReasonableEndpoints() {
        let params = RelationalNoaDecayParameters.noaDefaults
        let policy = RelationalDecayPolicy.defaultNoa
        let checkpoints: [TimeInterval] = [0, 1 * 24 * 3600, 7 * 24 * 3600, 14 * 24 * 3600, 30 * 24 * 3600, 120 * 24 * 3600]

        let values = checkpoints.map { delta in
            RelationalDecay.retention(policy: policy, now: delta, lastReinforcedAt: 0)
        }

        XCTAssertGreaterThan(values.first ?? 0.0, 0.90)
        for index in 1..<values.count {
            XCTAssertLessThanOrEqual(values[index], values[index - 1] + 1e-9)
        }

        let tail = values.last ?? 0.0
        XCTAssertGreaterThanOrEqual(tail, params.rMin)
        XCTAssertLessThan(tail, 0.2)
    }

    func testPolicyVersionCutoverAffectsScoringDeterministically() async throws {
        let baseNow = 10.0 * 24.0 * 3600.0

        let engineBaseline = RelationalLearningEngine()
        let engineCutover = RelationalLearningEngine()

        let started = RelationalPurposeLifecycleEvent(
            eventId: "start",
            timestamp: 0,
            status: .started,
            purposeId: "purpose://focus",
            activeInterestRefs: ["interest://deep-work"],
            contextConfidence: 0.9
        )

        let succeeded = RelationalPurposeLifecycleEvent(
            eventId: "success",
            timestamp: 10,
            status: .succeeded,
            purposeId: "purpose://focus",
            activeInterestRefs: ["interest://deep-work"],
            contextConfidence: 0.9
        )

        _ = await engineBaseline.ingestPurposeLifecycleEvent(started)
        let baselineUpdates = await engineBaseline.ingestPurposeLifecycleEvent(succeeded)
        for update in baselineUpdates {
            _ = await engineBaseline.applyWeightUpdateEvent(update)
        }

        _ = await engineCutover.ingestPurposeLifecycleEvent(started)
        let cutoverUpdates = await engineCutover.ingestPurposeLifecycleEvent(succeeded)
        for update in cutoverUpdates {
            _ = await engineCutover.applyWeightUpdateEvent(update)
        }

        let fastPolicy = RelationalDecayPolicy(
            profileId: "noa",
            version: 2,
            effectiveFromTimestamp: 5.0 * 24.0 * 3600.0,
            kind: .noaDoubleSigmoid,
            noaParameters: RelationalNoaDecayParameters(
                t1Seconds: 1.0 * 24.0 * 3600.0,
                t2Seconds: 2.0 * 24.0 * 3600.0,
                k1: 0.4,
                k2: 0.3,
                rMin: 0.05
            )
        )

        _ = await engineCutover.applyDecayPolicyUpdatedEvent(
            RelationalDecayPolicyUpdatedEvent(
                eventId: "policy-v2",
                emittedAt: 5.0 * 24.0 * 3600.0,
                policy: fastPolicy
            )
        )

        let snapshot = RelationalContextSnapshot(activeInterestRefs: ["interest://deep-work"])

        let baselineScores = await engineBaseline.scorePurposes(contextSnapshot: snapshot, at: baseNow)
        let cutoverScores = await engineCutover.scorePurposes(contextSnapshot: snapshot, at: baseNow)

        let baselineScore = baselineScores.first { $0.purposeId == "purpose://focus" }?.score ?? 0.0
        let cutoverScore = cutoverScores.first { $0.purposeId == "purpose://focus" }?.score ?? 0.0

        XCTAssertGreaterThan(baselineScore, cutoverScore)

        let explainVersion = cutoverScores
            .first { $0.purposeId == "purpose://focus" }?
            .explain
            .topEdges
            .first?
            .decayParamsVersion

        XCTAssertEqual(explainVersion, 2)
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            XCTFail("Unable to encode canonical json")
            return ""
        }
        return string
    }
}
