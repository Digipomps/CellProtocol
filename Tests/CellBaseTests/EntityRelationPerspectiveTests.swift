// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class EntityRelationPerspectiveTests: XCTestCase {
    private func record(graph: EntityRepresentation? = nil) -> EntityRelationRecord {
        let date = Date(timeIntervalSince1970: 1_786_300_000)
        return EntityRelationRecord(
            relationID: "relation-example",
            subject: EntityRelationSubject(displayName: "Legacy name", validatedContactRef: "contact-example"),
            origin: EntityRelationOrigin(kind: .manual, at: date, sourceLabel: "test"),
            interests: EntityRelationInterests(declared: ["Legacy tag"]),
            purposeRefs: ["purpose-external"], createdAt: date, updatedAt: date,
            entityRepresentation: graph
        )
    }

    private func graph() -> EntityRepresentation {
        let interest = Interest(name: "Shared interest", types: [], parts: [], partOf: [], purposes: [])
        interest.nodeIdentifier = "interest-example"
        let helper = CellConfiguration(name: "Review helper", cellReferences: [
            CellReference(endpoint: "cell:///Review", label: "Review")
        ])
        let purpose = Purpose(name: "Review together", description: "Owner's knowledge",
                              interests: [Weight(weight: 0.4, value: interest)],
                              goal: helper, helperCells: [helper],
                              composition: .purpose(PurposeCompositionLeaf(purposeRef: "purpose-step")))
        purpose.nodeIdentifier = "purpose-example"
        return EntityRepresentation(
            interests: [Weight(weight: 0.4, value: interest)],
            purposes: [Weight(weight: 0.8, value: purpose), Weight(weight: 0.6, value: purpose)],
            entities: [Weight<EntityRepresentation>(weight: 0.3, reference: "entity-example")],
            name: "My representation", person: ["displayName": .string("Private name")],
            nodeIdentifier: "entity-example"
        )
    }

    func testOwnerStoragePreservesPersonGraphWeightsIDsAndFunctionality() async throws {
        let original = record(graph: graph())
        let stored = EntityRelationCodec.value(original)
        let decoded = try XCTUnwrap(EntityRelationCodec.decode(EntityRelationRecord.self, from: stored))
        let node = try XCTUnwrap(decoded.entityRepresentation)
        XCTAssertEqual(node.person["displayName"], .string("Private name"))
        XCTAssertEqual(node.purposes.map(\.weight), [0.8, 0.6])
        let edge = try XCTUnwrap(node.purposes.first as? Weight<Purpose>)
        let purpose = try await edge.node
        XCTAssertEqual(purpose.reference, "purpose-example")
        XCTAssertEqual(purpose.goal?.name, "Review helper")
        XCTAssertEqual(purpose.helperCells.first?.cellReferences?.first?.endpoint, "cell:///Review")
        XCTAssertEqual(purpose.composition, .purpose(PurposeCompositionLeaf(purposeRef: "purpose-step")))
        let interestEdge = try XCTUnwrap(purpose.interests.first as? Weight<Interest>)
        let interest = try await interestEdge.node
        XCTAssertEqual(interest.reference, "interest-example")
        XCTAssertEqual(original, decoded)
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(EntityBatchPersistEnvelope(
            schema: EntityRelationRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(keypath: EntityRelationRecordV1.keypath(relationID: original.relationID), value: stored)]
        )))
    }

    func testStoredAndProjectedPurposesUseExistingSignalMatcher() async throws {
        let decoded = try XCTUnwrap(EntityRelationCodec.decode(EntityRelationRecord.self, from: EntityRelationCodec.value(record(graph: graph()))))
        let projection = try decoded.matchingRepresentation(reference: "e-salted", source: "cell:///Relations", includeGraph: true)
        let wire = try EntityRepresentationDataCodec.encoder().encode(projection)
        let reloaded = try EntityRepresentationDataCodec.decoder().decode(EntityRepresentation.self, from: wire)
        let result = try await WeightedGraphRuntime().match(start: reloaded, signal: Signal(
            relationship: .purposes, weight: 0.6, tolerance: 0.001, token: "test-correlation"
        ))
        XCTAssertEqual(result.hits.map(\.ref), ["purpose-example"], "The second edge is a reference, not an inline purpose")
        let back = try XCTUnwrap(reloaded.entities.first as? Weight<EntityRepresentation>)
        XCTAssertEqual(back.reference, "e-salted")
        let target = try await back.node
        XCTAssertTrue(target === reloaded)
    }

    func testPrivatePersonIsOmittedRecursivelyAndDefaultScopeRemainsNarrow() throws {
        let source = graph()
        source.parts = [Weight(weight: 1, value: EntityRepresentation(name: "Nested", person: ["secret": .string("nested-private")]))]
        let full = try record(graph: source).matchingRepresentation(reference: "e-safe", source: "cell:///Relations", includeGraph: true)
        let json = String(decoding: try EntityRepresentationDataCodec.encoder().encode(full), as: UTF8.self)
        XCTAssertFalse(json.contains("Private name"))
        XCTAssertFalse(json.contains("nested-private"))
        XCTAssertTrue(full.person.isEmpty)
        XCTAssertEqual(full.purposes.count, 2)
        let narrow = try record(graph: source).matchingRepresentation(reference: "e-safe", source: "cell:///Relations")
        XCTAssertTrue(narrow.purposes.isEmpty)
        XCTAssertTrue(narrow.parts.isEmpty)
        XCTAssertEqual(narrow.interests.first?.weight, 0.4, "Author weights must not become the legacy 0.75")
        XCTAssertEqual(source.nodeIdentifier, "entity-example")
        XCTAssertEqual(source.person["displayName"], .string("Private name"))
    }

    func testReferenceBackEdgesDoNotRetainDecodedGraph() throws {
        weak var observed: EntityRepresentation?
        do {
            let copy = try EntityRepresentationDataCodec.copy(graph(), ownerPrivate: true)
            observed = copy
            XCTAssertNotNil(observed)
        }
        XCTAssertNil(observed)
    }

    func testLegacyRecordAdaptsWithoutRewritingOrInventingPurposeTargets() async throws {
        let legacy = record()
        let valueBefore = try EntityRelationCodec.encoder().encode(legacy)
        let node = try legacy.perspectiveRepresentation()
        XCTAssertEqual(node.name, "Legacy name")
        XCTAssertEqual(node.interests.first?.weight, 0.75)
        XCTAssertEqual(node.purposes.first?.reference, "purpose-external")
        XCTAssertNil(node.purposes.first?.value)
        XCTAssertEqual(valueBefore, try EntityRelationCodec.encoder().encode(legacy))
        XCTAssertNil(legacy.entityRepresentation)
        let unresolved = try XCTUnwrap(node.purposes.first as? Weight<Purpose>)
        do {
            _ = try await unresolved.node
            XCTFail("An external reference without a Perspective context must not invent a purpose")
        } catch { }
    }

    /// Actual object cycles, with multiple paths back to every node. The same
    /// per-document Codable ID registers must bound output to one body per ID.
    func testCyclicSharedGraphSerializesEachNodeBodyOnceAndStaysBounded() throws {
        let purposes = (0..<30).map { i -> Purpose in
            let node = Purpose(name: "Node \(i)", description: "cycle fixture")
            node.nodeIdentifier = "purpose-cycle-\(i)"
            return node
        }
        let root = EntityRepresentation(name: "Root", nodeIdentifier: "entity-cycle-root")
        root.purposes = [Weight(weight: 0.8, value: purposes[0]), Weight(weight: 0.6, value: purposes[0])]
        root.entities = [Weight(weight: 1, value: root)]
        for (i, node) in purposes.enumerated() {
            let next = purposes[(i + 1) % purposes.count]
            node.purposes = [Weight(weight: 0.8, value: next), Weight(weight: 0.6, value: next)]
            node.entities = [Weight(weight: 1, value: root)]
        }
        // The input graph has intentionally strong object cycles; decoding it
        // must instead reconstruct reference edges without retaining cycles.
        defer {
            root.entities = []
            for node in purposes { node.purposes = []; node.entities = [] }
        }
        let data = try EntityRepresentationDataCodec.encoder(ownerPrivate: true).encode(root)
        XCTAssertLessThan(data.count, 25_000, "Thirty nodes with loops must not expand into repeated subtrees")
        let text = String(decoding: data, as: UTF8.self)
        for id in [root.reference] + purposes.map(\.reference) {
            let occurrence = "\"nodeIdentifier\":\"\(id)\""
            XCTAssertEqual(text.components(separatedBy: occurrence).count - 1, 1, id)
        }
        XCTAssertTrue(text.contains("\"reference\":\"entity-cycle-root\""))
        weak var observed: EntityRepresentation?
        do {
            let decoded = try EntityRepresentationDataCodec.decoder(ownerPrivate: true).decode(EntityRepresentation.self, from: data)
            observed = decoded
            XCTAssertEqual(data, try EntityRepresentationDataCodec.encoder(ownerPrivate: true).encode(decoded))
        }
        XCTAssertNil(observed)
    }

    func testStandalonePurposeAndInterestRootsUseTheSameCycleRegisters() throws {
        let purpose = Purpose(name: "Root purpose", description: "test")
        purpose.nodeIdentifier = "purpose-root"
        purpose.parts = [Weight(weight: 1, value: purpose)]
        let interest = Interest(name: "Root interest", types: [], parts: [], partOf: [], purposes: [])
        interest.nodeIdentifier = "interest-root"
        interest.parts = [Weight(weight: 1, value: interest)]
        defer { purpose.parts = []; interest.parts = [] }
        for data in [try EntityRepresentationDataCodec.encoder().encode(purpose),
                     try EntityRepresentationDataCodec.encoder().encode(interest)] {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let part = try XCTUnwrap((value["parts"] as? [[String: Any]])?.first)
            XCTAssertNil(part["value"], "A back edge to the root must use a reference immediately")
            XCTAssertEqual(part["reference"] as? String, value["nodeIdentifier"] as? String)
            XCTAssertLessThan(data.count, 1_000)
        }
    }

    func testPerspectivePersistenceUsesCycleRegistersAndRetainsEntityNodes() async throws {
        let entity = graph()
        entity.entities = [Weight(weight: 1, value: entity)]
        defer { entity.entities = [] }
        let container = InterestsAndPurposesContainer(interests: [], purposes: [], entities: [entity])
        let context = Perspective()
        let encoder = await context.pimpEncoder()
        let original = try encoder.encode(container)
        XCTAssertLessThan(original.count, 10_000)
        let decoder = await context.pimpDecoder()
        let decoded = try decoder.decode(InterestsAndPurposesContainer.self, from: original)
        XCTAssertEqual(decoded.entities.count, 1)
        let first = try XCTUnwrap(decoded.entities.first)
        let back = try XCTUnwrap(first.entities.first as? Weight<EntityRepresentation>)
        let target = try await back.node
        XCTAssertTrue(first === target)
        let freshEncoder = await context.pimpEncoder()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: freshEncoder.encode(decoded)) as? NSDictionary)
        let legacyDecoder = await context.pimpDecoder()
        let legacy = try legacyDecoder.decode(InterestsAndPurposesContainer.self, from: Data("{\"interests\":[],\"purposes\":[]}".utf8))
        XCTAssertTrue(legacy.entities.isEmpty, "Older container writes omitted this field entirely")
    }

    func testDocumentationGraphDecodesAndMatchesOnlyWhenItsConditionIsMet() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Docs/EntityData-Review-2026-09-11/EntityRepresentation.example.json"))
        let entity = try EntityRepresentationDataCodec.decoder(ownerPrivate: true).decode(EntityRepresentation.self, from: data)
        let signal = Signal(relationship: .interests, weight: 0.65, tolerance: 0.001, token: "documented-example")
        let withoutEvidence = try await WeightedGraphRuntime().match(start: entity, signal: signal)
        XCTAssertTrue(withoutEvidence.hits.isEmpty)
        let config = WeightedGraphRuntimeConfiguration(relationships: [.interests], maxHops: 1, ttl: 1,
            conditionContext: InterestConditionContext(evaluatedAt: 100, metadataTimestamps: ["owner-confirmed": 99]))
        let withEvidence = try await WeightedGraphRuntime().match(start: entity, signal: signal, configuration: config)
        XCTAssertEqual(withEvidence.hits.map(\.ref), ["interest-data-demo"])
    }

    func testInvalidGraphCannotTurnAnEncodingFailureIntoADeletionMutation() throws {
        let invalid = graph()
        invalid.purposes[0].weight = .nan
        XCTAssertThrowsError(try EntityRelationCodec.persistenceValue(record(graph: invalid)))
        let valid = try EntityRelationCodec.persistenceValue(record(graph: graph()))
        guard case .object = valid else { return XCTFail("A stored record must be an object, never a null deletion") }
    }

    func testRelationEqualityNoticesGraphOnlyAndPrivateKnowledgeChanges() throws {
        let original = record(graph: graph())
        var changed = original
        changed.entityRepresentation = try EntityRepresentationDataCodec.copy(try XCTUnwrap(original.entityRepresentation), ownerPrivate: true)
        changed.entityRepresentation?.purposes[0].weight = 0.9
        XCTAssertNotEqual(original, changed)
        changed.entityRepresentation = try EntityRepresentationDataCodec.copy(try XCTUnwrap(original.entityRepresentation), ownerPrivate: true)
        changed.entityRepresentation?.person["displayName"] = .string("Updated")
        XCTAssertNotEqual(original, changed)
        changed = original
        changed.updatedAt.addTimeInterval(0.125)
        XCTAssertNotEqual(original, changed)
    }
}
