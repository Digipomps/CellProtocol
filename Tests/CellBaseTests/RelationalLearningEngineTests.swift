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

    func testTransactionalJournalRestoreAndGeneratedWeightIDsAreDeterministic() async throws {
        let started = RelationalPurposeLifecycleEvent(
            eventId: "transaction-start",
            timestamp: 1_000,
            status: .started,
            purposeId: "purpose://transaction",
            activeInterestRefs: ["interest://determinism"],
            contextConfidence: 1
        )
        let succeeded = RelationalPurposeLifecycleEvent(
            eventId: "transaction-success",
            timestamp: 1_001,
            status: .succeeded,
            purposeId: "purpose://transaction",
            activeInterestRefs: ["interest://determinism"],
            contextConfidence: 1
        )
        let envelopes = try [
            RelationalLearningEventEnvelope.from(started),
            RelationalLearningEventEnvelope.from(succeeded)
        ]

        let first = RelationalLearningEngine()
        let second = RelationalLearningEngine()
        _ = try await first.applyEnvelopeTransaction(envelopes[0])
        let firstResult = try await first.applyEnvelopeTransaction(envelopes[1])
        _ = try await second.applyEnvelopeTransaction(envelopes[0])
        let secondResult = try await second.applyEnvelopeTransaction(envelopes[1])

        XCTAssertEqual(firstResult.weightUpdates.map(\.eventId), secondResult.weightUpdates.map(\.eventId))
        XCTAssertTrue(firstResult.weightUpdates.allSatisfy {
            $0.eventId.hasPrefix("relational-weight-v1-")
        })

        let journal = await first.journalSnapshot()
        XCTAssertEqual(journal.revision, 2)
        XCTAssertEqual(journal.records.map(\.sequence), [1, 2])

        let restored = RelationalLearningEngine()
        try await restored.restore(from: journal)
        let restoredEdges = await restored.edges()
        let originalEdges = await first.edges()
        let restoredJournal = await restored.journalSnapshot()
        XCTAssertEqual(
            try canonicalJSON(restoredEdges),
            try canonicalJSON(originalEdges)
        )
        XCTAssertEqual(
            try canonicalJSON(restoredJournal),
            try canonicalJSON(journal)
        )
    }

    func testInvalidReplayIsRejectedBeforeResetOrPartialMutation() async throws {
        let engine = RelationalLearningEngine()
        let preference = RelationalExplicitPreferenceEvent(
            eventId: "baseline-preference",
            timestamp: 2_000,
            purposeId: "purpose://atomic",
            relationType: .purposeInterest,
            targetNode: RelationalNode(type: .interest, id: "interest://integrity"),
            preferenceWeight: 0.7
        )
        _ = try await engine.applyEnvelopeTransaction(.from(preference))
        let baselineEdges = await engine.edges()
        let baselineJournal = await engine.journalSnapshot()

        let validContext = try RelationalLearningEventEnvelope.from(
            RelationalContextTransitionEvent(
                eventId: "valid-context",
                timestamp: 2_001,
                domain: "location",
                toBlockId: "home",
                confidence: 1
            )
        )
        var invalidContext = validContext
        invalidContext.schemaVersion = "unsupported"

        do {
            _ = try await engine.replayTransaction(
                events: [validContext, invalidContext],
                resetFirst: true
            )
            XCTFail("Replay must validate every event before reset")
        } catch RelationalLearningError.unsupportedSchemaVersion {
            // Expected.
        }

        let finalEdges = await engine.edges()
        let finalJournal = await engine.journalSnapshot()
        let finalContext = await engine.currentActiveContextBlocks()
        XCTAssertEqual(try canonicalJSON(finalEdges), try canonicalJSON(baselineEdges))
        XCTAssertEqual(
            try canonicalJSON(finalJournal),
            try canonicalJSON(baselineJournal)
        )
        XCTAssertTrue(finalContext.isEmpty)
    }

    func testOversizedJournalIsRejectedExplicitly() throws {
        let envelope = try RelationalLearningEventEnvelope.from(
            RelationalContextTransitionEvent(
                eventId: "capacity",
                timestamp: 3_000,
                domain: "location",
                toBlockId: "home",
                confidence: 1
            )
        )
        let records = (1 ... RelationalLearningPersistedJournal.maximumRecordCount + 1).map {
            RelationalLearningJournalRecord(sequence: UInt64($0), envelope: envelope)
        }
        let journal = RelationalLearningPersistedJournal(
            revision: UInt64(records.count),
            records: records
        )
        XCTAssertThrowsError(try journal.validateShapeAndSize()) { error in
            guard case RelationalLearningError.journalCapacityExceeded = error else {
                return XCTFail("Expected explicit capacity error, got \(error)")
            }
        }
    }

    func testMismatchedRelationShapesAreRejectedWithoutMutation() async throws {
        let engine = RelationalLearningEngine()
        let baseline = RelationalExplicitPreferenceEvent(
            eventId: "shape-baseline",
            timestamp: 4_000,
            purposeId: "purpose://shape",
            relationType: .purposeInterest,
            targetNode: RelationalNode(type: .interest, id: "interest://valid"),
            preferenceWeight: 0.7
        )
        _ = try await engine.applyEnvelopeTransaction(.from(baseline))
        let baselineEdges = await engine.edges()
        let baselineJournal = await engine.journalSnapshot()

        let invalidPreference = RelationalExplicitPreferenceEvent(
            eventId: "shape-invalid-preference",
            timestamp: 4_001,
            purposeId: "purpose://shape",
            relationType: .purposeInterest,
            targetNode: RelationalNode(type: .entityRepresentation, id: "entity://wrong"),
            preferenceWeight: 0.8
        )
        let invalidSourceWeight = RelationalWeightUpdateEvent(
            eventId: "shape-invalid-source",
            emittedAt: 4_002,
            sourceEventId: nil,
            outcome: .success,
            edge: RelationalEdge(
                fromNode: RelationalNode(type: .interest, id: "interest://wrong-source"),
                relationType: .purposeInterest,
                toNode: RelationalNode(type: .interest, id: "interest://valid"),
                weightStored: 0.5,
                lastReinforcedAt: 4_002,
                decayProfileId: "noa",
                decayParamsVersion: 1
            ),
            previousWeightStored: 0.4,
            newWeightStored: 0.5,
            learningRate: 0.1,
            eligibility: 1,
            reason: "invalid source"
        )
        let invalidTargetWeight = RelationalWeightUpdateEvent(
            eventId: "shape-invalid-target",
            emittedAt: 4_003,
            sourceEventId: nil,
            outcome: .success,
            edge: RelationalEdge(
                fromNode: RelationalNode(type: .purpose, id: "purpose://shape"),
                relationType: .purposeEntity,
                toNode: RelationalNode(type: .interest, id: "interest://wrong-target"),
                weightStored: 0.5,
                lastReinforcedAt: 4_003,
                decayProfileId: "noa",
                decayParamsVersion: 1
            ),
            previousWeightStored: 0.4,
            newWeightStored: 0.5,
            learningRate: 0.1,
            eligibility: 1,
            reason: "invalid target"
        )
        let invalidEnvelopes = try [
            RelationalLearningEventEnvelope.from(invalidPreference),
            RelationalLearningEventEnvelope.from(invalidSourceWeight),
            RelationalLearningEventEnvelope.from(invalidTargetWeight)
        ]

        for envelope in invalidEnvelopes {
            do {
                _ = try await engine.applyEnvelopeTransaction(envelope)
                XCTFail("Mismatched relation shape must be rejected")
            } catch RelationalLearningError.invalidEvent {
                // Expected.
            }
            let currentEdges = await engine.edges()
            let currentJournal = await engine.journalSnapshot()
            XCTAssertEqual(
                try canonicalJSON(currentEdges),
                try canonicalJSON(baselineEdges)
            )
            XCTAssertEqual(
                try canonicalJSON(currentJournal),
                try canonicalJSON(baselineJournal)
            )
        }
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
