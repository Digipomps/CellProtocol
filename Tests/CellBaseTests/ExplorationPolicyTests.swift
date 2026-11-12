// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class ExplorationPolicyTests: XCTestCase {
    private func candidate(_ id: String, _ weight: Double?, consent: Bool = false,
                           failures: Int = 0) -> ExplorationCandidate {
        .init(id: id, weight: weight, requiresOwnerConsent: consent, consecutiveFailures: failures)
    }

    private var routes: [ExplorationCandidate] {
        [candidate("best", 0.9), candidate("weak", 0.2), candidate("untried", nil)]
    }

    func testSeededGeneratorGoldenSequence() {
        var generator = ExplorationSeededGenerator(seed: 0)
        XCTAssertEqual(generator.next(), 0xe220a8397b1dcdaf)
        XCTAssertEqual(generator.next(), 0x6e789e6aa1b965f4)
        XCTAssertEqual(generator.next(), 0x06c45d188009454f)
    }

    func testGoldenSelectionSequencePinsProbabilityAndAlternativeMapping() throws {
        var generator = ExplorationSeededGenerator(seed: 0)
        let policy = ExplorationPolicy(epsilon: 0.5)
        let selections = try (0..<3).map { _ in try policy.select(from: routes, using: &generator) }
        XCTAssertEqual(selections.map(\.selectedID), ["best", "untried", "best"])
        XCTAssertEqual(selections.map(\.explored), [false, true, false])
    }

    func testReplayIsIdenticalIncludingExplanationsAndIndependentOfInputOrder() throws {
        let policy = ExplorationPolicy(epsilon: 0.3)
        var original = ExplorationSeededGenerator(seed: 20261112)
        var replay = ExplorationSeededGenerator(seed: 20261112)
        var explored = 0
        for _ in 0..<200 {
            let first = try policy.select(from: routes, using: &original)
            let second = try policy.select(from: routes.reversed(), using: &replay)
            XCTAssertEqual(first, second)
            if first.explored { explored += 1 }
        }
        XCTAssertGreaterThan(explored, 0)
        XCTAssertLessThan(explored, 200)
        XCTAssertEqual(original, replay)
    }

    func testGeneratorCheckpointResumesExactSequence() throws {
        let policy = ExplorationPolicy(epsilon: 0.5)
        var original = ExplorationSeededGenerator(seed: 73)
        for _ in 0..<17 { _ = try policy.select(from: routes, using: &original) }
        var restored = try JSONDecoder().decode(
            ExplorationSeededGenerator.self, from: JSONEncoder().encode(original)
        )
        for _ in 0..<100 {
            XCTAssertEqual(try policy.select(from: routes, using: &original),
                           try policy.select(from: routes, using: &restored))
        }
    }

    func testExplorationRateOverTenThousandDraws() throws {
        var generator = ExplorationSeededGenerator(seed: 20261112)
        let policy = ExplorationPolicy(epsilon: 0.2)
        var explored = 0
        var alternatives: [String: Int] = [:]
        for _ in 0..<10_000 {
            let selection = try policy.select(from: routes, using: &generator)
            if selection.explored {
                explored += 1
                let id = try XCTUnwrap(selection.selectedID)
                XCTAssertNotEqual(id, "best")
                alternatives[id, default: 0] += 1
            } else {
                XCTAssertEqual(selection.selectedID, "best")
            }
        }
        let fraction = Double(explored) / 10_000
        print("Exploration sample: \(explored)/10000 = \(fraction); epsilon=0.2, tolerance=0.015")
        XCTAssertEqual(fraction, 0.2, accuracy: 0.015)
        XCTAssertEqual(Double(alternatives["weak", default: 0]) / Double(explored), 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(alternatives["untried", default: 0], 0)
    }

    func testZeroDefaultsPreserveGreedyChoiceAndConsumeNoRandomnessEvenAfterFailures() throws {
        let policy = ExplorationPolicy()
        XCTAssertEqual(policy.epsilon, 0)
        XCTAssertEqual(policy.epsilonAfterFailures, 0)
        XCTAssertEqual(policy.failureThreshold, 2)
        var generator = ExplorationSeededGenerator(seed: 9)
        let initial = generator
        for failures in [0, 1, 2, 100] {
            let selection = try policy.select(
                from: [candidate("weak", 0.2), candidate("best", 0.9, failures: failures)],
                using: &generator
            )
            XCTAssertEqual(selection.selectedID, "best")
            XCTAssertFalse(selection.explored)
            XCTAssertEqual(selection.effectiveEpsilon, 0)
        }
        XCTAssertEqual(generator, initial)
    }

    func testZeroPolicyMatchesExistingRelationalRankingIncludingTies() async throws {
        let engine = RelationalLearningEngine()
        for (id, weight) in [("zeta", 0.9), ("alpha", 0.9), ("weak", 0.2)] {
            let event = RelationalExplicitPreferenceEvent(
                eventId: "declared-\(id)", timestamp: 100, purposeId: id,
                relationType: .purposeInterest, targetNode: .init(type: .interest, id: "declared-interest"),
                preferenceWeight: weight
            )
            _ = try await engine.applyEnvelopeTransaction(.from(event))
        }
        let scores = await engine.scorePurposes(
            contextSnapshot: .init(activeInterestRefs: ["declared-interest"]), at: 100
        )
        let candidates = scores.map { $0.explorationCandidate(requiresOwnerConsent: false) }
        var generator = ExplorationSeededGenerator(seed: 0)
        let selection = try ExplorationPolicy().select(from: candidates.reversed(), using: &generator)
        XCTAssertEqual(selection.selectedID, scores.first?.purposeId)
        XCTAssertEqual(selection.selectedID, "alpha")
        XCTAssertEqual(selection.candidates.map(\.weight), scores.map { Optional($0.score) })
        XCTAssertFalse(selection.explored)
        let after = await engine.scorePurposes(
            contextSnapshot: .init(activeInterestRefs: ["declared-interest"]), at: 100
        )
        XCTAssertEqual(after.map(\.score), scores.map(\.score))
    }

    func testUpliftUsesOnlyGreedyRouteConsecutiveFailuresAndResetsWithInput() throws {
        let policy = ExplorationPolicy(epsilonAfterFailures: 1)
        var generator = ExplorationSeededGenerator(seed: 10)
        for failures in [0, 1, 2, 3, 0] {
            let selection = try policy.select(from: [
                candidate("best", 0.9, failures: failures), candidate("weak", 0.2, failures: 100)
            ], using: &generator)
            XCTAssertEqual(selection.explored, failures >= 2)
            XCTAssertEqual(selection.effectiveEpsilon, failures >= 2 ? 1 : 0)
            XCTAssertEqual(selection.selectedID, failures >= 2 ? "weak" : "best")
        }
    }

    func testCustomThresholdAndUpliftNeverReduceBaseProbability() throws {
        var generator = ExplorationSeededGenerator(seed: 1)
        let candidates = [candidate("best", 1, failures: 2), candidate("weak", 0)]
        let delayed = try ExplorationPolicy(failureThreshold: 3, epsilonAfterFailures: 1)
            .select(from: candidates, using: &generator)
        XCTAssertFalse(delayed.explored)
        let lowerUplift = try ExplorationPolicy(epsilon: 1, epsilonAfterFailures: 0.1)
            .select(from: candidates, using: &generator)
        XCTAssertEqual(lowerUplift.effectiveEpsilon, 1)
        XCTAssertTrue(lowerUplift.explored)
    }

    func testConsentRequiredCandidatesNeverSelectedByExploration() throws {
        var generator = ExplorationSeededGenerator(seed: 56)
        let candidates = [candidate("best", 1, consent: true), candidate("unsafe", 0.5, consent: true),
                          candidate("untried-unsafe", nil, consent: true), candidate("safe", 0.1)]
        for _ in 0..<1_000 {
            let selection = try ExplorationPolicy(epsilon: 1).select(from: candidates, using: &generator)
            XCTAssertTrue(selection.explored)
            XCTAssertEqual(selection.selectedID, "safe")
            XCTAssertEqual(selection.explorationCandidateIDs, ["safe"])
            XCTAssertEqual(selection.candidates.count, 4)
        }
    }

    func testNoSafeAlternativeFallsBackWithoutClaimingExplorationOrConsumingEntropy() throws {
        var generator = ExplorationSeededGenerator(seed: 1)
        let initial = generator
        let selection = try ExplorationPolicy(epsilon: 1).select(from: [
            candidate("best", 1, consent: true), candidate("unsafe", 0, consent: true)
        ], using: &generator)
        XCTAssertFalse(selection.explored)
        XCTAssertEqual(selection.selectedID, "best") // Still a recommendation requiring consent.
        XCTAssertTrue(selection.candidates[0].requiresOwnerConsent)
        XCTAssertTrue(selection.explorationCandidateIDs.isEmpty)
        XCTAssertEqual(generator, initial)
    }

    func testEmptySingletonAndAllUntriedCandidates() throws {
        var generator = ExplorationSeededGenerator(seed: 8)
        let initial = generator
        let policy = ExplorationPolicy(epsilon: 1)
        let empty = try policy.select(from: [], using: &generator)
        XCTAssertNil(empty.selectedID)
        XCTAssertNil(empty.greedyID)
        XCTAssertFalse(empty.explored)
        let single = try policy.select(from: [candidate("only", nil)], using: &generator)
        XCTAssertEqual(single.selectedID, "only")
        XCTAssertFalse(single.explored)
        XCTAssertEqual(generator, initial)
        let untried = try policy.select(from: [candidate("b", nil), candidate("a", nil)], using: &generator)
        XCTAssertEqual(untried.greedyID, "a")
        XCTAssertEqual(untried.selectedID, "b")
        XCTAssertTrue(untried.explored)
    }

    func testExplanationCodableContainsWeightsAndBothExploredFlags() throws {
        var generator = ExplorationSeededGenerator(seed: 3)
        for epsilon in [0.0, 1.0] {
            let policy = ExplorationPolicy(epsilon: epsilon)
            let decodedPolicy = try JSONDecoder().decode(ExplorationPolicy.self, from: JSONEncoder().encode(policy))
            XCTAssertEqual(decodedPolicy, policy)
            let selection = try decodedPolicy.select(from: routes, using: &generator)
            let data = try JSONEncoder().encode(selection)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["explored"] as? Bool, epsilon == 1)
            XCTAssertEqual(selection.candidates, routes)
            XCTAssertEqual(selection.explorationCandidateIDs, ["weak", "untried"])
            XCTAssertEqual(try JSONDecoder().decode(ExplorationSelection.self, from: data), selection)
        }
    }

    func testInvalidInputsRejectBeforeConsumingRandomness() throws {
        var generator = ExplorationSeededGenerator(seed: 0)
        let initial = generator
        for epsilon in [-0.1, 1.1, .nan, .infinity] {
            XCTAssertThrowsError(try ExplorationPolicy(epsilon: epsilon).select(from: routes, using: &generator))
            XCTAssertThrowsError(try ExplorationPolicy(epsilonAfterFailures: epsilon).select(from: routes, using: &generator))
        }
        XCTAssertThrowsError(try ExplorationPolicy(failureThreshold: 0).select(from: routes, using: &generator))
        for invalid in [candidate("", 0), candidate("bad", .nan), candidate("bad", .infinity),
                        candidate("bad", 0, failures: -1)] {
            XCTAssertThrowsError(try ExplorationPolicy().select(from: [invalid], using: &generator))
        }
        // Conflicting duplicate IDs must not bypass consent filtering.
        XCTAssertThrowsError(try ExplorationPolicy(epsilon: 1).select(from: [
            candidate("same", 1, consent: true), candidate("same", 0)
        ], using: &generator))
        let missingConsent = Data(#"{"id":"unsafe","weight":0.2,"consecutiveFailures":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExplorationCandidate.self, from: missingConsent))
        XCTAssertEqual(generator, initial)
    }
}
