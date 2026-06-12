// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class GoalEvaluationCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testGoalEvaluationCellConfiguresEvaluatesStoresAndEmits() async throws {
        let owner = await makeOwner()
        let cell = await GoalEvaluationCell(owner: owner)

        let feed = try await cell.flow(requester: owner)
        let updatedExpectation = expectation(description: "goal evaluation updated")
        let satisfiedExpectation = expectation(description: "goal satisfied")
        let lock = NSLock()
        var topics = [String]()

        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                lock.lock()
                topics.append(flowElement.topic)
                lock.unlock()

                if flowElement.topic == "goal.evaluation.updated" {
                    updatedExpectation.fulfill()
                }
                if flowElement.topic == "goal.satisfied" {
                    satisfiedExpectation.fulfill()
                }
            }
        )
        defer { cancellable.cancel() }

        let keys = try await cell.keys(requester: owner)
        XCTAssertTrue(keys.contains("goal.evaluate"))
        XCTAssertTrue(keys.contains("goal.lastEvaluation"))

        _ = try await cell.set(
            keypath: "goal.definition",
            value: try encode(workAtLunchDefinition()),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "goal.observations",
            value: try encode([
                GoalObservation(sourceID: "semantic-location", labels: ["Work"], confidence: 0.94),
                GoalObservation(sourceID: "semantic-time", labels: ["lunch"], confidence: 1.0)
            ]),
            requester: owner
        )

        let response = try await cell.set(
            keypath: "goal.evaluate",
            value: .object(["evaluatedAt": .string("2026-06-11T10:55:00Z")]),
            requester: owner
        )
        let evaluation: GoalEvaluation = try decode(response)
        XCTAssertEqual(evaluation.status, .satisfied)
        XCTAssertEqual(evaluation.progress, 1)

        let lastEvaluationValue = try await cell.get(keypath: "goal.lastEvaluation", requester: owner)
        let lastEvaluation: GoalEvaluation = try decode(lastEvaluationValue)
        XCTAssertEqual(lastEvaluation.goalID, evaluation.goalID)
        XCTAssertEqual(lastEvaluation.status, .satisfied)

        await fulfillment(of: [updatedExpectation, satisfiedExpectation], timeout: 1.0)

        let observedTopics = lock.withValue { topics }
        XCTAssertTrue(observedTopics.contains("goal.evaluation.updated"))
        XCTAssertTrue(observedTopics.contains("goal.satisfied"))
    }

    func testGoalEvaluationCellReturnsUnknownWhenEvidenceIsMissing() async throws {
        let owner = await makeOwner()
        let cell = await GoalEvaluationCell(owner: owner)

        _ = try await cell.set(
            keypath: "goal.definition",
            value: try encode(workAtLunchDefinition()),
            requester: owner
        )

        let response = try await cell.set(
            keypath: "goal.evaluate",
            value: .object([
                "evaluatedAt": .string("2026-06-11T10:55:00Z"),
                "observations": try encode([
                    GoalObservation(sourceID: "semantic-location", labels: ["work"], confidence: 0.94)
                ])
            ]),
            requester: owner
        )

        let evaluation: GoalEvaluation = try decode(response)
        XCTAssertEqual(evaluation.status, .unknown)
        XCTAssertEqual(evaluation.missing, ["evidence-source:semantic-time"])
    }

    func testGoalEvaluationCellRequiresDefinitionBeforeEvaluation() async throws {
        let owner = await makeOwner()
        let cell = await GoalEvaluationCell(owner: owner)

        let response = try await cell.set(
            keypath: "goal.evaluate",
            value: .object(["evaluatedAt": .string("2026-06-11T10:55:00Z")]),
            requester: owner
        )

        guard case .object(let object)? = response else {
            XCTFail("Expected structured error")
            return
        }
        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertEqual(object["code"], .string("missing_goal_definition"))
    }

    private func makeOwner() async -> Identity {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        return await vault.identity(for: "private", makeNewIfNotFound: true)!
    }

    private func workAtLunchDefinition() -> GoalDefinition {
        GoalDefinition(
            goalID: "goal.personal.location.work-at-lunch",
            purposeRef: "purpose://personal.be-at-work-for-lunch",
            title: "Be at work during lunch",
            description: "Satisfied when work and lunch semantic labels are both active.",
            lifecycle: .continuous,
            evaluatorKind: .composite,
            evidenceSources: [
                GoalEvidenceSource(sourceID: "semantic-location", endpoint: "cell:///SemanticLocation", keypath: "semanticLocation.state.currentLabels"),
                GoalEvidenceSource(sourceID: "semantic-time", endpoint: "cell:///SemanticTime", keypath: "semanticTime.state.currentLabels")
            ],
            predicate: GoalPredicate(
                kind: "all",
                all: [
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-location", expected: "work"),
                    GoalPredicate(kind: "contains-label", sourceID: "semantic-time", expected: "lunch")
                ]
            )
        )
    }

    private func decode<T: Decodable>(_ value: ValueType?, as type: T.Type = T.self) throws -> T {
        guard let value else {
            throw NSError(domain: "GoalEvaluationCellTests", code: 1)
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }
}

private extension NSLock {
    func withValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
