// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// The entity half of the perspective. Every test here corresponds to a bug
/// that was actually in the code: entities that could not be found after being
/// added, a first insert that threw, a graph keyed on display names, and no way
/// at all to remove anybody.
///
/// `Perspective` is an actor and `XCTAssert*` takes autoclosures, so every
/// call is hoisted into a `let` before it is asserted on. That is not style —
/// `await` inside an autoclosure does not compile.
final class PerspectiveEntityProjectionTests: XCTestCase {

    private let source = "cell:///Relations"

    private func entity(
        _ name: String,
        reference: String? = nil,
        projectedBy: String? = nil,
        interests: [String] = []
    ) -> EntityRepresentation {
        EntityRepresentation(
            interests: interests.map {
                Weight<Interest>(
                    weight: 0.5,
                    value: Interest(name: $0, types: [], parts: [], partOf: [], purposes: [])
                )
            },
            name: name,
            nodeIdentifier: reference,
            projectionSource: projectedBy
        )
    }

    private func weighted(_ entity: EntityRepresentation, _ weight: Double = 0.6) -> Weight<EntityRepresentation> {
        Weight<EntityRepresentation>(weight: weight, value: entity)
    }

    // MARK: - Identity

    func testNodeIdentifierOverridesTheNameAsReference() {
        let named = entity("Anne Hansen")
        XCTAssertEqual(named.reference, "Anne Hansen", "without an identifier the old behaviour must be unchanged")

        let opaque = entity("Anne Hansen", reference: "e-abc123")
        XCTAssertEqual(opaque.reference, "e-abc123")
    }

    /// Two people sharing a name collided into one node before this existed.
    func testTwoPeopleWithTheSameNameStayTwoNodes() async throws {
        let perspective = Perspective()
        _ = await perspective.upsertEntityRepresentation(entity("Anne Hansen", reference: "e-1"))
        _ = await perspective.upsertEntityRepresentation(entity("Anne Hansen", reference: "e-2"))

        let all = await perspective.allEntityRepresentations()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - CRUD

    /// `addEntityRepresentation` never populated the reference dictionary, so
    /// a lookup one line after an add came back empty.
    func testAnAddedEntityCanBeFoundAgain() async throws {
        let perspective = Perspective()
        let added = await perspective.upsertEntityRepresentation(entity("Vegar", reference: "e-vegar"))
        XCTAssertTrue(added)

        let found = await perspective.findENtityRepresentationByReference("e-vegar")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Vegar")
    }

    func testUpsertIsIdempotent() async throws {
        let perspective = Perspective()
        let first = await perspective.upsertEntityRepresentation(entity("Vegar", reference: "e-vegar"))
        let second = await perspective.upsertEntityRepresentation(entity("Vegar Hansen", reference: "e-vegar"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)

        let all = await perspective.allEntityRepresentations()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Vegar Hansen", "the later write should win on content")
    }

    /// The first insert used to throw `noEntityForReference`, so every caller
    /// treated a successful add as a failure.
    func testUpdatingSomethingNewIsAnInsertNotAnError() async throws {
        let perspective = Perspective()
        try await perspective.updateEntityRepresentation(entity("Ny", reference: "e-ny"))

        let found = await perspective.findENtityRepresentationByReference("e-ny")
        XCTAssertNotNil(found)
    }

    func testRemovingClearsEveryIndexAndTheActiveWeight() async throws {
        let perspective = Perspective()
        let node = entity("Vegar", reference: "e-vegar")
        _ = await perspective.upsertEntityRepresentation(node)
        await perspective.upsertActiveEntity(weighedEntity: weighted(node))

        let activeBefore = await perspective.getActiveEntities()
        XCTAssertEqual(activeBefore.count, 1)

        let removed = await perspective.removeEntityRepresentation(reference: "e-vegar")
        XCTAssertTrue(removed)

        let found = await perspective.findENtityRepresentationByReference("e-vegar")
        let all = await perspective.allEntityRepresentations()
        let activeAfter = await perspective.getActiveEntities()
        XCTAssertNil(found)
        XCTAssertEqual(all.count, 0)
        XCTAssertEqual(activeAfter.count, 0)

        let removedAgain = await perspective.removeEntityRepresentation(reference: "e-vegar")
        XCTAssertFalse(removedAgain)
    }

    // MARK: - Projection

    func testProjectingASetAddsAllOfIt() async throws {
        let perspective = Perspective()
        let result = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source)),
                weighted(entity("Kari", reference: "e-2", projectedBy: source))
            ])
        )
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 0)

        let active = await perspective.getActiveEntities()
        XCTAssertEqual(active.count, 2)
    }

    /// The point of a whole-set projection: deleting a relation in the source
    /// has to reach the graph. Incremental adds could never do that.
    func testSomeoneMissingFromTheNextProjectionIsRemoved() async throws {
        let perspective = Perspective()
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source)),
                weighted(entity("Kari", reference: "e-2", projectedBy: source))
            ])
        )
        let second = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 2, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source))
            ])
        )
        XCTAssertEqual(second.removed, 1)

        let gone = await perspective.findENtityRepresentationByReference("e-2")
        let kept = await perspective.findENtityRepresentationByReference("e-1")
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
    }

    /// A source owns its own slice and nothing else.
    func testAProjectionNeverTouchesAnotherSourcesNodes() async throws {
        let perspective = Perspective()
        _ = await perspective.upsertEntityRepresentation(entity("Manuelt lagt inn", reference: "e-manual"))
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source))
            ])
        )
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 2, entities: [])
        )

        let manual = await perspective.findENtityRepresentationByReference("e-manual")
        let projected = await perspective.findENtityRepresentationByReference("e-1")
        XCTAssertNotNil(manual)
        XCTAssertNil(projected)
    }

    /// A delayed write must not resurrect what a newer one removed.
    func testAStaleEpochIsIgnored() async throws {
        let perspective = Perspective()
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 5, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source))
            ])
        )
        let stale = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 2, entities: [
                weighted(entity("Gammel", reference: "e-old", projectedBy: source))
            ])
        )
        XCTAssertTrue(stale.ignoredStaleEpoch)

        let old = await perspective.findENtityRepresentationByReference("e-old")
        let current = await perspective.findENtityRepresentationByReference("e-1")
        XCTAssertNil(old)
        XCTAssertNotNil(current)
    }

    func testAnEmptyProjectionIsHowASourceWithdrawsEntirely() async throws {
        let perspective = Perspective()
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source)),
                weighted(entity("Kari", reference: "e-2", projectedBy: source))
            ])
        )
        let cleared = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 2, entities: [])
        )
        XCTAssertEqual(cleared.removed, 2)

        let all = await perspective.allEntityRepresentations()
        XCTAssertEqual(all.count, 0)
    }

    /// A weight carrying only a reference has no node to mark with a source,
    /// so it could never be removed again. Skipping is the safe answer.
    func testAReferenceOnlyWeightIsSkippedRatherThanOrphaned() async throws {
        let perspective = Perspective()
        let result = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                Weight<EntityRepresentation>(weight: 0.5, reference: "e-dangling")
            ])
        )
        XCTAssertEqual(result.added, 0)

        let all = await perspective.allEntityRepresentations()
        XCTAssertEqual(all.count, 0)
    }

    func testInterestsSurviveTheProjectionSoTheNodeCanActuallyMatch() async throws {
        let perspective = Perspective()
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 1, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source, interests: ["arendalsuka", "personvern"]))
            ])
        )
        let node = await perspective.findENtityRepresentationByReference("e-1")
        XCTAssertEqual(node?.interests.count, 2)
    }

    func testProjectionSourcesAreReportedWithTheirEpoch() async throws {
        let perspective = Perspective()
        _ = try await perspective.applyEntityProjection(
            PerspectiveEntityProjection(source: source, epoch: 3, entities: [
                weighted(entity("Vegar", reference: "e-1", projectedBy: source))
            ])
        )
        let sources = await perspective.entityProjectionSources()
        XCTAssertEqual(sources[source], 3)
    }

    /// Contact detail must not ride along into a graph built to be compared
    /// against other parties.
    func testEncodingAnEntityLeavesPersonalDetailBehind() throws {
        let node = entity("Vegar", reference: "e-1", projectedBy: source, interests: ["personvern"])
        node.person = ["email": .string("vegar@example.no")]

        let encoder = JSONEncoder()
        let interestFacilitator = Facilitator<Interest>()
        let entityFacilitator = Facilitator<EntityRepresentation>()
        if let key = CodingUserInfoKey(rawValue: "interestFacilitator") {
            encoder.userInfo[key] = interestFacilitator
        }
        if let key = CodingUserInfoKey(rawValue: "entityRepresentationsFacilitator") {
            encoder.userInfo[key] = entityFacilitator
        }
        let data = try encoder.encode(node)
        // `JSONEncoder` writes "cell:\/\/\/Relations", so compare against the
        // unescaped text rather than teaching every assertion about slashes.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")

        XCTAssertFalse(json.contains("vegar@example.no"), "contact detail must not reach the perspective")
        XCTAssertTrue(json.contains("e-1"), json)
        XCTAssertTrue(json.contains(source), json)
    }
}
