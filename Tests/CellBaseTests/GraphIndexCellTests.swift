// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class GraphIndexCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testReindexBuildsOutgoingIncomingAndNeighbors() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GraphIndexCell(owner: owner)

        let payload = reindexPayload(
            notes: [
                ("A", "Links to [[B]] and [[C|Label]]"),
                ("B", "Links to [[C]]"),
                ("C", "No links")
            ]
        )

        _ = try await cell.set(keypath: "graph.reindex", value: payload, requester: owner)

        let outgoingA = try await queryLinks(cell: cell, keypath: "graph.outgoing", id: "A", requester: owner)
        let incomingC = try await queryLinks(cell: cell, keypath: "graph.incoming", id: "C", requester: owner)
        let neighborsB = try await queryNeighbors(cell: cell, id: "B", requester: owner)

        XCTAssertEqual(outgoingA, ["B", "C"])
        XCTAssertEqual(incomingC, ["A", "B"])
        XCTAssertEqual(neighborsB, ["A", "C"])
    }

    func testReindexReflectsEditsAndDeletes() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GraphIndexCell(owner: owner)

        _ = try await cell.set(
            keypath: "graph.reindex",
            value: reindexPayload(
                notes: [
                    ("A", "[[B]]"),
                    ("B", "[[C]]"),
                    ("C", "leaf")
                ]
            ),
            requester: owner
        )

        _ = try await cell.set(
            keypath: "graph.reindex",
            value: reindexPayload(
                notes: [
                    ("A", "[[C]]"),
                    ("C", "leaf")
                ]
            ),
            requester: owner
        )

        let incomingC = try await queryLinks(cell: cell, keypath: "graph.incoming", id: "C", requester: owner)
        XCTAssertEqual(incomingC, ["A"])
    }

    func testReindexHandlesCycleAndOrphanNode() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GraphIndexCell(owner: owner)

        _ = try await cell.set(
            keypath: "graph.reindex",
            value: reindexPayload(
                notes: [
                    ("A", "[[B]]"),
                    ("B", "[[A]]"),
                    ("C", "orphan")
                ]
            ),
            requester: owner
        )

        let neighborsC = try await queryNeighbors(cell: cell, id: "C", requester: owner)
        XCTAssertEqual(neighborsC, [])
    }

    func testReindexAndQueryWithinThousandNoteEnvelope() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GraphIndexCell(owner: owner)

        var notes: [(String, String)] = []
        notes.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let current = "N\(index)"
            let next = "N\((index + 1) % 1_000)"
            notes.append((current, "[[\(next)]]"))
        }

        let start = Date()
        _ = try await cell.set(keypath: "graph.reindex", value: reindexPayload(notes: notes), requester: owner)
        _ = try await cell.set(keypath: "graph.outgoing", value: .string("N10"), requester: owner)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "Expected reindex+query under benchmark envelope, got \(elapsed)s")
    }

    private func reindexPayload(notes: [(String, String)]) -> ValueType {
        .object([
            "notes": .list(
                notes.map { note in
                    .object([
                        "id": .string(note.0),
                        "content": .string(note.1)
                    ])
                }
            )
        ])
    }

    private func queryLinks(
        cell: GraphIndexCell,
        keypath: String,
        id: String,
        requester: Identity
    ) async throws -> [String] {
        guard let response = try await cell.set(keypath: keypath, value: .string(id), requester: requester),
              case let .object(root) = response,
              case let .object(result)? = root["result"],
              case let .list(links)? = result["links"] else {
            throw NSError(domain: "GraphIndexCellTests", code: 10)
        }

        return links.compactMap { value in
            guard case let .string(linkID) = value else { return nil }
            return linkID
        }
    }

    private func queryNeighbors(
        cell: GraphIndexCell,
        id: String,
        requester: Identity
    ) async throws -> [String] {
        guard let response = try await cell.set(keypath: "graph.neighbors", value: .string(id), requester: requester),
              case let .object(root) = response,
              case let .object(result)? = root["result"],
              case let .list(neighbors)? = result["neighbors"] else {
            throw NSError(domain: "GraphIndexCellTests", code: 11)
        }

        return neighbors.compactMap { value in
            guard case let .string(neighborID) = value else { return nil }
            return neighborID
        }
    }
}
