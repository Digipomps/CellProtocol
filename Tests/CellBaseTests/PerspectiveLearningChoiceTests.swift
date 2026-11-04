// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase
@testable import CellApple

/// WP4: real Cell actions for explicit choices and corrections. This does not
/// substitute a test dialog for the product's missing autonomous clarification UI.
final class PerspectiveLearningChoiceTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousMode = CellBase.exploreContractEnforcementMode
        CellBase.exploreContractEnforcementMode = .strict
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.exploreContractEnforcementMode = previousMode
        super.tearDown()
    }

    func testMechanicsCellExplicitChoiceCorrectionAndDuplicateAreDurable() async throws {
        let (cell, owner, _) = try await fixture()
        _ = try await cell.set(keypath: "userPreference", value: preference(id: "choice", at: 100, weight: 0.9), requester: owner)
        let correction = try preference(id: "corrected", at: 110, weight: 0.2)
        let applied = try await cell.set(keypath: "userPreference", value: correction, requester: owner)
        XCTAssertEqual(responseBool(applied, key: "applied"), true)
        let beforeDuplicate = try await cell.get(keypath: "edges", requester: owner)
        let stateBeforeDuplicate = try await cell.get(keypath: "state", requester: owner)
        let duplicate = try await cell.set(keypath: "userPreference", value: correction, requester: owner)
        XCTAssertEqual(responseBool(duplicate, key: "applied"), false)
        let afterDuplicate = try await cell.get(keypath: "edges", requester: owner)
        let stateAfterDuplicate = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(beforeDuplicate), try LearningEvidenceFixture.canonical(afterDuplicate))
        XCTAssertEqual(try LearningEvidenceFixture.canonical(stateBeforeDuplicate), try LearningEvidenceFixture.canonical(stateAfterDuplicate))
        let selected = try XCTUnwrap(try decodeEdges(afterDuplicate).first)
        XCTAssertEqual(selected.weightStored, 0.2, accuracy: 1e-12)
        let restored = try JSONDecoder().decode(RelationalLearningCell.self, from: JSONEncoder().encode(cell))
        let restoredEdges = try await restored.get(keypath: "edges", requester: owner)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(afterDuplicate), try LearningEvidenceFixture.canonical(restoredEdges))
    }

    func testMechanicsCellAmbiguousRankingDoesNotMutateUserPreferences() async throws {
        let (cell, owner, _) = try await fixture()
        for purpose in ["purpose://family", "purpose://work"] {
            _ = try await cell.set(keypath: "userPreference",
                value: preference(id: purpose, at: 100, weight: 0.8, purpose: purpose), requester: owner)
        }
        let before = try await cell.get(keypath: "edges", requester: owner)
        let response = try await cell.set(keypath: "scorePurposes", value: .object([
            "timestamp": .float(100), "activeInterestRefs": .list([.string(LearningEvidenceFixture.interest)])]), requester: owner)
        guard case let .object(object)? = response, case let .list(values)? = object["scores"] else {
            return XCTFail("Missing actual ranking result: \(String(describing: response))")
        }
        let scores = try values.map { try RelationalLearningCodec.decode(RelationalPurposeScore.self, from: $0) }
        XCTAssertEqual(Set(scores.map(\.purposeId)), ["purpose://family", "purpose://work"])
        XCTAssertEqual(scores.map(\.score), [0.8, 0.8])
        let after = try await cell.get(keypath: "edges", requester: owner)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(before), try LearningEvidenceFixture.canonical(after))
        // This witnesses no preference mutation by ranking, not a rendered user
        // choice or a Porthole no-load invariant; those need a separate path witness.
    }

    func testMechanicsCellStartedButUnconfirmedPurposeCreatesNoWeight() async throws {
        let (cell, owner, _) = try await fixture()
        let result = try await cell.set(keypath: "purposeStarted", value: .object([
            "eventId": .string("not-completed"), "timestamp": .float(100),
            "purposeId": .string(LearningEvidenceFixture.purpose),
            "activeInterestRefs": .list([.string(LearningEvidenceFixture.interest)]),
            "contextConfidence": .float(1)]), requester: owner)
        XCTAssertEqual(responseBool(result, key: "applied"), true)
        let response = try await cell.get(keypath: "edges", requester: owner)
        XCTAssertTrue(try decodeEdges(response).isEmpty)
    }

    func testMechanicsCellMalformedCorrectionDoesNotChangeState() async throws {
        let (cell, owner, _) = try await fixture()
        _ = try await cell.set(keypath: "userPreference", value: preference(id: "valid-choice", at: 100, weight: 0.8), requester: owner)
        let before = try await cell.get(keypath: "edges", requester: owner)
        let stateBefore = try await cell.get(keypath: "state", requester: owner)
        do {
            let response = try await cell.set(keypath: "userPreference", value: .object([
                "eventId": .string("missing-time-and-target"),
                "purposeId": .string(LearningEvidenceFixture.purpose), "preferenceWeight": .float(0.2)]), requester: owner)
            guard case let .object(object)? = response else {
                return XCTFail("Expected contract rejection, got \(String(describing: response))")
            }
            XCTAssertEqual(ExploreContract.string(from: object["status"]), "error")
        } catch SetValueError.paramErr {
            // Strict Explore dispatch rejects before entering the mutation handler.
        }
        let after = try await cell.get(keypath: "edges", requester: owner)
        let stateAfter = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(before), try LearningEvidenceFixture.canonical(after))
        XCTAssertEqual(try LearningEvidenceFixture.canonical(stateBefore), try LearningEvidenceFixture.canonical(stateAfter))
    }

    func testMechanicsCellRejectsCorrectionFromUnrelatedRequester() async throws {
        let (cell, owner, vault) = try await fixture()
        let outsiderCandidate = await vault.identity(for: "perspective-learning-outsider", makeNewIfNotFound: true)
        let outsider = try XCTUnwrap(outsiderCandidate)
        _ = try await cell.set(keypath: "userPreference", value: preference(id: "owner-choice", at: 100, weight: 0.8), requester: owner)
        let before = try await cell.get(keypath: "edges", requester: owner)
        try await CellContractHarness.assertSetDenied(on: cell, key: "userPreference",
            input: preference(id: "forged-correction", at: 110, weight: 0.1), requester: outsider)
        let after = try await cell.get(keypath: "edges", requester: owner)
        XCTAssertEqual(try LearningEvidenceFixture.canonical(before), try LearningEvidenceFixture.canonical(after))
    }

    func testProductRequirementDelayedOldCorrectionMustNotOverwriteNewerUserChoice() async throws {
        let (cell, owner, _) = try await fixture()
        _ = try await cell.set(keypath: "userPreference", value: preference(id: "current-choice", at: 200, weight: 0.2), requester: owner)
        _ = try await cell.set(keypath: "userPreference", value: preference(id: "delayed-old-choice", at: 100, weight: 0.9), requester: owner)
        let response = try await cell.get(keypath: "edges", requester: owner)
        let edge = try XCTUnwrap(try decodeEdges(response).first)
        // Deliberately red on the pinned implementation: distinct event IDs are
        // deduplicated, but event time does not protect the newer explicit choice.
        XCTAssertEqual(edge.weightStored, 0.2, accuracy: 1e-12,
            "WP4: an old delayed reply must not undo the user's newer correction")
        XCTAssertEqual(edge.lastReinforcedAt, 200,
            "WP4: delayed correction must not move the preference clock backwards")
    }

    private func fixture() async throws -> (RelationalLearningCell, Identity, MockIdentityVault) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let candidate = await vault.identity(for: "perspective-learning-choice-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(candidate)
        return (await RelationalLearningCell(owner: owner), owner, vault)
    }

    private func preference(id: String, at timestamp: Double, weight: Double,
                            purpose: String = LearningEvidenceFixture.purpose) throws -> ValueType {
        .object(try RelationalLearningCodec.encodeObject(RelationalExplicitPreferenceEvent(
            eventId: id, timestamp: timestamp, purposeId: purpose, relationType: .purposeInterest,
            targetNode: .init(type: .interest, id: LearningEvidenceFixture.interest), preferenceWeight: weight)))
    }

    private func decodeEdges(_ value: ValueType) throws -> [RelationalEdge] {
        guard case let .object(object) = value, case let .list(edges)? = object["edges"] else {
            throw SetValueError.paramErr
        }
        return try edges.map { try RelationalLearningCodec.decode(RelationalEdge.self, from: $0) }
    }

    private func responseBool(_ response: ValueType?, key: String) -> Bool? {
        guard case let .object(object)? = response, case let .bool(value)? = object[key] else { return nil }
        return value
    }
}
