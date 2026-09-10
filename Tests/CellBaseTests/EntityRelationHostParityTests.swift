// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellApple
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

final class EntityRelationHostParityTests: XCTestCase {
    private var previousRoot: String?
    private var previousVault: IdentityVaultProtocol?
    private var previousKey: Data?
    private var root: URL!

    override func setUpWithError() throws {
        previousRoot = CellBase.documentRootPath
        previousVault = CellBase.defaultIdentityVault
        previousKey = CellBase.persistedCellMasterKey
        CellBase.persistedCellMasterKey = Data(repeating: 0x71, count: 32)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relation-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.defaultIdentityVault = MockIdentityVault()
    }

    override func tearDownWithError() throws {
        CellBase.documentRootPath = previousRoot
        CellBase.defaultIdentityVault = previousVault
        CellBase.persistedCellMasterKey = previousKey
        try FileManager.default.removeItem(at: root)
    }

    func owner() async throws -> Identity {
        let candidate = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        return try XCTUnwrap(candidate)
    }

    func testAppleRelationAdmissionMatrix() async throws {
        let owner = try await owner()
        try await verify(await EntityAnchorCell(owner: owner), owner: owner)
    }

    func testAppleOrdinaryChronicleBatchPreservesProtectedEvents() async throws {
        let owner = try await owner()
        try await verifyOrdinaryChronicleBatch(await EntityAnchorCell(owner: owner), owner: owner)
    }

    func verifyOrdinaryChronicleBatch<T: GeneralCell>(_ cell: T, owner: Identity) async throws {
        let event = EntityRelationInteractionEvent(id: "one", relationID: "synthetic", kind: .messageSent,
            at: Date(timeIntervalSince1970: 1), sourceCell: "security-test")
        let eventValue = EntityRelationCodec.value(event)
        let eventPath = EntityRelationRecordV1.chronicleKeypath(relationID: event.relationID, eventID: event.id)
        let first: ValueType = .object(["id": .string("ordinary"), "kind": .string("conference_registration")])
        let second: ValueType = .object(["type": .string("contact.endpoint.published")])
        let source = FlowElementPusherCell(owner: owner)
        _ = try await cell.attach(emitter: source, label: "chronicle-compatibility", requester: owner)
        try await cell.absorbFlow(label: "chronicle-compatibility", requester: owner)
        defer { cell.detach(label: "chronicle-compatibility", requester: owner) }
        let stream = try await cell.flow(requester: owner)
        let cases: [(EntityBatchPersistEnvelope, Bool)] = [
            (.init(schema: EntityRelationRecordV1.envelopeSchema, mutations: [.init(keypath: eventPath, value: eventValue)]), true),
            (.init(schema: "conference.registration.v1", mutations: [
                .init(keypath: "chronicle[+]", value: first), .init(keypath: "chronicle[+]", value: second)
            ]), true),
            (.init(schema: "legacy", mutations: [
                .init(keypath: "chronicle[+]", value: .object(["id": .string("must-not-commit")])),
                .init(keypath: "chronicle[id=ordinary]", value: eventValue)
            ]), false),
            (.init(schema: "legacy", mutations: [.init(keypath: "chronicle[+]", value: eventValue)]), false)
        ]
        for (index, entry) in cases.enumerated() {
            let finished = expectation(description: "chronicle compatibility \(index)")
            let correlation = "chronicle-case-\(index)"
            let subscription = stream.sink(receiveCompletion: { _ in }, receiveValue: { element in
                guard case let .object(response) = element.content,
                      response["correlationId"] == .string(correlation) else { return }
                XCTAssertEqual(response["status"], .string(entry.1 ? "persisted" : "failed"), "case \(index)")
                finished.fulfill()
            })
            source.pushFlowElement(FlowElement(title: "chronicle compatibility", content: .object([
                "operation": .string(EntityBatchPersistEnvelope.operation), "correlationId": .string(correlation),
                "envelope": .object(entry.0.objectValue())
            ]), properties: nil), requester: owner)
            await fulfillment(of: [finished], timeout: 3)
            subscription.cancel()
        }
        let expected: ValueType = .list([eventValue, first, second])
        let chronicle = try await cell.get(keypath: "chronicle", requester: owner)
        XCTAssertTrue(ExploreContractValidator.deepEqual(chronicle, expected), "Rejected batches must not partially append or alter protected events")
        let restarted = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(cell))
        let restored = try await restarted.get(keypath: "chronicle", requester: owner)
        XCTAssertTrue(ExploreContractValidator.deepEqual(restored, expected))
    }

    func verify<T: GeneralCell>(_ cell: T, owner: Identity) async throws {
        let valid = EntityRelationRecord(relationID: "synthetic", subject: .init(displayName: "Synthetic person"),
            origin: .init(kind: .manual, at: Date(timeIntervalSince1970: 1), sourceLabel: "security-test"),
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        let path = EntityRelationRecordV1.keypath(relationID: valid.relationID)
        do {
            _ = try await cell.set(keypath: path, value: EntityRelationCodec.value(valid), requester: owner)
            XCTFail("Direct writes bypassed relation schema")
        } catch { }
        let schema = try await cell.get(keypath: "entityRelationSchema", requester: owner)
        guard case let .object(schemaObject) = schema else { return XCTFail("Missing relation schema") }
        XCTAssertEqual(schemaObject["schema"], .string(EntityRelationRecordV1.envelopeSchema))
        var rawAddress = valid
        rawAddress.channels = [.init(kind: .email, ref: "synthetic@example.invalid")]
        var event = EntityRelationInteractionEvent(id: "one", relationID: "synthetic", kind: .inviteSent,
            at: Date(timeIntervalSince1970: 1), sourceCell: "security-test")
        event.summary = "Not allowed under metadata policy"
        let fullEvent = EntityRelationInteractionEvent(id: "full", relationID: "synthetic", kind: .messageSent,
            at: valid.createdAt, contentMode: .full, summary: "Synthetic content", sourceCell: "security-test")
        let fullPath = EntityRelationRecordV1.chronicleKeypath(relationID: "synthetic", eventID: "full")
        var matrix: [(String, String, ValueType, Bool)] = [
            ("wrong-schema", path, EntityRelationCodec.value(valid), false),
            (EntityRelationRecordV1.envelopeSchema, path + "-other", EntityRelationCodec.value(valid), false),
            (EntityRelationRecordV1.envelopeSchema, path, EntityRelationCodec.value(rawAddress), false),
            (EntityRelationRecordV1.envelopeSchema, path, .string("invalid-record"), false),
            (EntityRelationRecordV1.envelopeSchema, EntityRelationRecordV1.chronicleKeypath(relationID: "synthetic", eventID: "one"), EntityRelationCodec.value(event), false),
            (EntityRelationRecordV1.envelopeSchema, fullPath, EntityRelationCodec.value(fullEvent), false),
            (EntityRelationRecordV1.envelopeSchema, "relations", .object(["records": .object([:])]), false),
            (EntityRelationRecordV1.envelopeSchema, path + ".subject", .null, false),
            (EntityRelationRecordV1.envelopeSchema, path, EntityRelationCodec.value(valid), true)
        ]
        let firstEvent = EntityRelationInteractionEvent(id: "c", relationID: "a-b", kind: .messageSent, at: valid.createdAt, sourceCell: "security-test")
        let collidingEvent = EntityRelationInteractionEvent(id: "b-c", relationID: "a", kind: .messageSent, at: valid.createdAt, sourceCell: "security-test")
        let collisionPath = EntityRelationRecordV1.chronicleKeypath(relationID: "a-b", eventID: "c")
        matrix.append((EntityRelationRecordV1.envelopeSchema, collisionPath, EntityRelationCodec.value(firstEvent), true))
        matrix.append((EntityRelationRecordV1.envelopeSchema, collisionPath, EntityRelationCodec.value(firstEvent), true))
        matrix.append((EntityRelationRecordV1.envelopeSchema, collisionPath, EntityRelationCodec.value(collidingEvent), false))
        matrix.append((EntityRelationRecordV1.envelopeSchema, fullPath, EntityRelationCodec.value(fullEvent), true))
        let source = FlowElementPusherCell(owner: owner)
        _ = try await cell.attach(emitter: source, label: "parity", requester: owner)
        try await cell.absorbFlow(label: "parity", requester: owner)
        let stream = try await cell.flow(requester: owner)
        for (index, entry) in matrix.enumerated() {
            if index == matrix.count - 1 {
                _ = try await cell.set(keypath: EntityRelationRecordV1.interactionPolicyKeypath, value: .string("full"), requester: owner)
            }
            let finished = expectation(description: "matrix \(index)")
            let correlation = "case-\(index)"
            let subscription = stream.sink(receiveCompletion: { _ in }, receiveValue: { element in
                guard case let .object(response) = element.content,
                      response["correlationId"] == .string(correlation) else { return }
                XCTAssertEqual(response["status"], .string(entry.3 ? "persisted" : "failed"), "case \(index), \(entry.1)")
                finished.fulfill()
            })
            let envelope = EntityBatchPersistEnvelope(schema: entry.0, mutations: [.init(keypath: entry.1, value: entry.2)])
            source.pushFlowElement(FlowElement(title: "parity", content: .object([
                "operation": .string(EntityBatchPersistEnvelope.operation), "correlationId": .string(correlation),
                "envelope": .object(envelope.objectValue())
            ]), properties: nil), requester: owner)
            await fulfillment(of: [finished], timeout: 3)
            subscription.cancel()
        }
        let stored = try await cell.get(keypath: path, requester: owner)
        XCTAssertEqual(EntityRelationCodec.decode(EntityRelationRecord.self, from: stored), valid)
        let restarted = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(cell))
        let restored = try await restarted.get(keypath: path, requester: owner)
        XCTAssertEqual(EntityRelationCodec.decode(EntityRelationRecord.self, from: restored), valid)
    }
}
