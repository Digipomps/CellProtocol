// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CellAccessGraphContractsTests: XCTestCase {
    func testContractKeypathsMatchEntityGraphSurface() {
        XCTAssertEqual(CellAccessGraphContract.rootKeypath, "atlas.entityGraph")
        XCTAssertEqual(CellAccessGraphContract.stateKeypath, "atlas.entityGraph.state")
        XCTAssertEqual(CellAccessGraphContract.syncRuntimeCellsKeypath, "atlas.entityGraph.syncRuntimeCells")
        XCTAssertEqual(CellAccessGraphContract.queryKeypath, "atlas.entityGraph.query")
        XCTAssertEqual(CellAccessGraphContract.mermaidKeypath, "atlas.entityGraph.mermaid")
    }

    func testRuntimeMaterializerFiltersIdentityInstancesToRequester() {
        let now = Date(timeIntervalSince1970: 10)
        let registry = CellResolverRegistrySnapshot(
            resolves: [
                CellResolverResolveSnapshot(
                    name: "Chat",
                    cellType: "ChatCell",
                    cellScope: .identityUnique,
                    persistancy: .persistant,
                    identityDomain: "private",
                    hasLifecyclePolicy: false
                )
            ],
            sharedNamedInstances: [
                CellResolverNamedInstanceSnapshot(name: "SharedFeed", uuid: "shared-1")
            ],
            identityNamedInstances: [
                CellResolverNamedInstanceSnapshot(name: "MyChat", uuid: "mine-1", identityUUID: "me"),
                CellResolverNamedInstanceSnapshot(name: "OtherChat", uuid: "other-1", identityUUID: "other")
            ]
        )

        let materialized = CellAccessGraphRuntimeMaterializer.materializeRuntimeCells(
            registry: registry,
            requesterIdentityUUID: "me",
            now: now
        )

        XCTAssertEqual(materialized.registeredCellTypes, 1)
        XCTAssertEqual(materialized.persistentCellTypes, 1)
        XCTAssertEqual(materialized.activeCells, 2)
        XCTAssertTrue(materialized.nodes.contains { $0.id == "cell:registered:Chat" })
        XCTAssertTrue(materialized.nodes.contains { $0.id == "cell:active:mine-1" })
        XCTAssertTrue(materialized.nodes.contains { $0.id == "cell:active:shared-1" })
        XCTAssertFalse(materialized.nodes.contains { $0.id == "cell:active:other-1" })
        XCTAssertTrue(materialized.edges.contains { $0.kind == .hasAccessToCell && $0.fromNodeID == "identity:me" })
        XCTAssertFalse(materialized.edges.contains { $0.fromNodeID == "identity:other" || $0.toNodeID == "cell:active:other-1" })
    }

    func testGraphSnapshotContractsRoundTripAsCodableTransport() throws {
        let now = Date(timeIntervalSince1970: 20)
        let snapshot = CellAccessGraphSnapshot(
            nodes: [
                CellAccessGraphNode(
                    id: "cell:active:test",
                    kind: .cell,
                    label: "TestCell",
                    payloadJSON: #"{"runtimeState":"active"}"#,
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            ],
            edges: [
                CellAccessGraphEdge(
                    id: "edge:runs",
                    fromNodeID: "cell:active:test",
                    toNodeID: CellAccessGraphContract.localScaffoldID,
                    kind: .runsOnScaffold,
                    observedAt: now
                )
            ],
            proofs: [
                CellAccessGraphProof(
                    id: "proof-1",
                    proofType: "test",
                    payloadHash: "hash",
                    payloadJSON: "{}"
                )
            ],
            sources: [
                CellAccessGraphSource(
                    id: CellAccessGraphContract.runtimeResolverSourceID,
                    sourceType: "runtimeResolver",
                    trustLevel: "local",
                    lastSyncAt: now
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CellAccessGraphSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }
}
