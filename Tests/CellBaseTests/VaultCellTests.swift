// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class VaultCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testInvalidCreatePayloadReturnsStructuredFieldErrors() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        let invalidPayload: ValueType = .object([
            "id": .string(""),
            "title": .string(""),
            "content": .string("Body"),
            "tags": .list([]),
            "createdAtEpochMs": .integer(1_700_000_000_000),
            "updatedAtEpochMs": .integer(1_700_000_000_000)
        ])

        guard let response = try await cell.set(keypath: "vault.note.create", value: invalidPayload, requester: owner) else {
            XCTFail("Expected response payload")
            return
        }

        guard case let .object(object) = response else {
            XCTFail("Expected object response")
            return
        }

        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertEqual(object["code"], .string("validation_error"))

        guard case let .list(fieldErrors)? = object["field_errors"] else {
            XCTFail("Expected field_errors list")
            return
        }

        let fields = fieldErrors.compactMap { value -> String? in
            guard case let .object(entry) = value, case let .string(field)? = entry["field"] else { return nil }
            return field
        }

        XCTAssertTrue(fields.contains("id"))
        XCTAssertTrue(fields.contains("title"))
    }

    func testCreateAndListAreDeterministic() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        let noteA = VaultNoteRecord(
            id: "a-note",
            title: "A",
            content: "alpha",
            tags: ["x"],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 2_000
        )
        let noteB = VaultNoteRecord(
            id: "b-note",
            title: "B",
            content: "beta",
            tags: ["x"],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 2_000
        )

        _ = try await cell.set(
            keypath: "vault.note.create",
            value: try VaultCellCodec.encode(noteB),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "vault.note.create",
            value: try VaultCellCodec.encode(noteA),
            requester: owner
        )

        let query = VaultQuery(limit: 10, offset: 0, sortBy: .updatedAt, descending: true)
        guard let first = try await cell.set(
            keypath: "vault.note.list",
            value: try VaultCellCodec.encode(query),
            requester: owner
        ),
        let second = try await cell.set(
            keypath: "vault.note.list",
            value: try VaultCellCodec.encode(query),
            requester: owner
        ) else {
            XCTFail("Expected list responses")
            return
        }

        let firstIDs = try extractNoteIDs(fromListResponse: first)
        let secondIDs = try extractNoteIDs(fromListResponse: second)
        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(firstIDs, ["b-note", "a-note"])
    }

    func testLinkAddAndBacklinkQueries() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        let noteA = VaultNoteRecord(
            id: "note-a",
            title: "A",
            content: "A",
            tags: [],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
        let noteB = VaultNoteRecord(
            id: "note-b",
            title: "B",
            content: "B",
            tags: [],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )

        _ = try await cell.set(keypath: "vault.note.create", value: try VaultCellCodec.encode(noteA), requester: owner)
        _ = try await cell.set(keypath: "vault.note.create", value: try VaultCellCodec.encode(noteB), requester: owner)

        let link = VaultLinkRecord(fromNoteID: "note-a", toNoteID: "note-b", createdAtEpochMs: 2_000)
        _ = try await cell.set(keypath: "vault.link.add", value: try VaultCellCodec.encode(link), requester: owner)

        guard let forward = try await cell.set(
            keypath: "vault.links.forward",
            value: .string("note-a"),
            requester: owner
        ),
        let backlinks = try await cell.set(
            keypath: "vault.links.backlinks",
            value: .string("note-b"),
            requester: owner
        ) else {
            XCTFail("Expected forward/backlinks response")
            return
        }

        XCTAssertEqual(try extractLinkTargets(fromLinksResponse: forward, idKey: "toNoteID"), ["note-b"])
        XCTAssertEqual(try extractLinkTargets(fromLinksResponse: backlinks, idKey: "fromNoteID"), ["note-a"])
    }

    func testVaultStateReturnsSnapshotPayload() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        let noteA = VaultNoteRecord(
            id: "note-a",
            title: "A",
            content: "Alpha",
            tags: ["inbox"],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
        let noteB = VaultNoteRecord(
            id: "note-b",
            title: "B",
            content: "Beta",
            tags: ["project"],
            createdAtEpochMs: 2_000,
            updatedAtEpochMs: 2_000
        )

        _ = try await cell.set(keypath: "vault.note.create", value: try VaultCellCodec.encode(noteA), requester: owner)
        _ = try await cell.set(keypath: "vault.note.create", value: try VaultCellCodec.encode(noteB), requester: owner)
        _ = try await cell.set(
            keypath: "vault.link.add",
            value: try VaultCellCodec.encode(
                VaultLinkRecord(fromNoteID: "note-a", toNoteID: "note-b", relationship: "references", createdAtEpochMs: 3_000)
            ),
            requester: owner
        )

        let state = try await cell.get(keypath: "vault.state", requester: owner)
        guard case let .object(object) = state,
              case let .list(notes)? = object["notes"],
              case let .list(links)? = object["links"],
              case let .list(operations)? = object["operations"] else {
            XCTFail("Expected full vault.state snapshot")
            return
        }

        XCTAssertEqual(object["schemaVersion"], .string(VaultStatePayload.currentSchemaVersion))
        XCTAssertEqual(object["stateVersion"], .integer(3))
        XCTAssertEqual(object["noteCount"], .integer(2))
        XCTAssertEqual(object["linkCount"], .integer(1))
        XCTAssertEqual(object["note_count"], .integer(2))
        XCTAssertEqual(object["link_count"], .integer(1))
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(operations.contains(.string("vault.note.create")))
        XCTAssertTrue(operations.contains(.string("vault.links.backlinks")))
    }

    func testMutationsIncrementStateVersion() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        _ = try await cell.set(
            keypath: "vault.note.create",
            value: try VaultCellCodec.encode(
                VaultNoteRecord(
                    id: "note-a",
                    title: "A",
                    content: "Alpha",
                    tags: [],
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_000
                )
            ),
            requester: owner
        )
        let versionAfterCreate = try await extractStateVersion(from: cell, requester: owner)
        XCTAssertEqual(versionAfterCreate, 1)

        _ = try await cell.set(
            keypath: "vault.note.update",
            value: try VaultCellCodec.encode(
                VaultNoteRecord(
                    id: "note-a",
                    title: "A2",
                    content: "Alpha updated",
                    tags: [],
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_100
                )
            ),
            requester: owner
        )
        let versionAfterUpdate = try await extractStateVersion(from: cell, requester: owner)
        XCTAssertEqual(versionAfterUpdate, 2)

        _ = try await cell.set(
            keypath: "vault.note.create",
            value: try VaultCellCodec.encode(
                VaultNoteRecord(
                    id: "note-b",
                    title: "B",
                    content: "Beta",
                    tags: [],
                    createdAtEpochMs: 2_000,
                    updatedAtEpochMs: 2_000
                )
            ),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "vault.link.add",
            value: try VaultCellCodec.encode(VaultLinkRecord(fromNoteID: "note-a", toNoteID: "note-b", createdAtEpochMs: 3_000)),
            requester: owner
        )
        let versionAfterLink = try await extractStateVersion(from: cell, requester: owner)
        XCTAssertEqual(versionAfterLink, 4)
    }

    func testMutationFlowEventIncludesOperationRecordAndVersion() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)
        let expectation = expectation(description: "mutation event emitted")
        var cancellables: Set<AnyCancellable> = []
        var captured: FlowElement?

        let feed = try await cell.flow(requester: owner)
        feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                if flowElement.topic == "vault.mutation" {
                    captured = flowElement
                    expectation.fulfill()
                }
            }
        )
        .store(in: &cancellables)

        _ = try await cell.set(
            keypath: "vault.note.create",
            value: try VaultCellCodec.encode(
                VaultNoteRecord(
                    id: "note-flow",
                    title: "Flow",
                    content: "sync seed",
                    tags: [],
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_000
                )
            ),
            requester: owner
        )

        await fulfillment(of: [expectation], timeout: 1.0)

        guard case let .object(content)? = captured?.content else {
            XCTFail("Expected object event content")
            return
        }
        XCTAssertEqual(captured?.title, "VaultMutationEvent")
        XCTAssertEqual(content["schemaVersion"], .string(VaultMutationEvent.currentSchemaVersion))
        XCTAssertEqual(content["stateVersion"], .integer(1))
        XCTAssertEqual(content["operation"], .string("vault.note.create"))
        XCTAssertEqual(content["recordKind"], .string("note"))
        XCTAssertEqual(content["recordID"], .string("note-flow"))
        XCTAssertNotNil(content["result"])
    }

    func testVaultStateAndMutationEventsRoundTripThroughCodable() throws {
        let note = VaultNoteRecord(
            id: "note-a",
            slug: "note-a",
            title: "A",
            content: "Alpha",
            tags: ["inbox"],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
        let link = VaultLinkRecord(fromNoteID: "note-a", toNoteID: "note-b", relationship: "references", createdAtEpochMs: 2_000)
        let state = VaultStatePayload(
            stateVersion: 7,
            noteCount: 1,
            linkCount: 1,
            notes: [note],
            links: [link],
            operations: ["vault.note.create", "vault.link.add"],
            updatedAtEpochMs: 3_000
        )

        let stateData = try JSONEncoder().encode(state)
        let decodedState = try JSONDecoder().decode(VaultStatePayload.self, from: stateData)
        XCTAssertEqual(decodedState, state)

        let mutation = VaultMutationEvent(
            stateVersion: 8,
            operation: "vault.note.update",
            recordKind: "note",
            recordID: "note-a",
            result: try VaultCellCodec.encode(note),
            emittedAtEpochMs: 4_000
        )
        let mutationData = try JSONEncoder().encode(mutation)
        let decodedMutation = try JSONDecoder().decode(VaultMutationEvent.self, from: mutationData)

        XCTAssertEqual(decodedMutation.schemaVersion, VaultMutationEvent.currentSchemaVersion)
        XCTAssertEqual(decodedMutation.stateVersion, 8)
        XCTAssertEqual(decodedMutation.operation, "vault.note.update")
        XCTAssertEqual(decodedMutation.recordKind, "note")
        XCTAssertEqual(decodedMutation.recordID, "note-a")
        XCTAssertEqual(decodedMutation.emittedAtEpochMs, 4_000)
    }

    private func extractNoteIDs(fromListResponse value: ValueType) throws -> [String] {
        guard case let .object(root) = value,
              case let .object(result)? = root["result"],
              case let .list(items)? = result["items"] else {
            throw NSError(domain: "VaultCellTests", code: 1)
        }

        return items.compactMap { item in
            guard case let .object(obj) = item, case let .string(id)? = obj["id"] else { return nil }
            return id
        }
    }

    private func extractLinkTargets(fromLinksResponse value: ValueType, idKey: String) throws -> [String] {
        guard case let .object(root) = value,
              case let .object(result)? = root["result"],
              case let .list(links)? = result["links"] else {
            throw NSError(domain: "VaultCellTests", code: 2)
        }

        return links.compactMap { item in
            guard case let .object(obj) = item, case let .string(id)? = obj[idKey] else { return nil }
            return id
        }
    }

    private func extractStateVersion(from cell: VaultCell, requester: Identity) async throws -> Int? {
        let state = try await cell.get(keypath: "vault.state", requester: requester)
        guard case let .object(object) = state,
              case let .integer(version)? = object["stateVersion"] else {
            return nil
        }
        return version
    }
}
