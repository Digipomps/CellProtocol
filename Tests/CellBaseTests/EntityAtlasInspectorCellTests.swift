// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class EntityAtlasInspectorCellTests: XCTestCase {
    private var previousResolver: CellResolverProtocol?
    private var previousVault: IdentityVaultProtocol?
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousResolver = CellBase.defaultCellResolver
        previousVault = CellBase.defaultIdentityVault
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
    }

    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testEntityAtlasInspectorCellBuildsSnapshotAndCoverage() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let vaultCell = await VaultCell(owner: owner)
        let graphCell = await GraphIndexCell(owner: owner)

        resolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "Vault",
                cellType: "VaultCell",
                cellScope: .identityUnique,
                persistancy: .persistant,
                identityDomain: "private",
                hasLifecyclePolicy: false
            )
        )
        resolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "Graph",
                cellType: "GraphIndexCell",
                cellScope: .identityUnique,
                persistancy: .persistant,
                identityDomain: "private",
                hasLifecyclePolicy: false
            )
        )

        try await resolver.registerNamedEmitCell(name: "Vault", emitCell: vaultCell, scope: .identityUnique, identity: owner)
        try await resolver.registerNamedEmitCell(name: "Graph", emitCell: graphCell, scope: .identityUnique, identity: owner)

        let repository = AtlasVaultDocumentRepository()
        let now = Int(Date().timeIntervalSince1970 * 1000.0)
        try await repository.upsert(
            AtlasPromptDocument(
                id: "prompt.inspect",
                title: "Inspector Prompt",
                scope: AtlasDocumentScope(kind: .entity, reference: "self"),
                body: "Keep the atlas redacted and deterministic.",
                createdAtEpochMs: now,
                updatedAtEpochMs: now
            ),
            in: vaultCell,
            requester: owner
        )

        let cell = await EntityAtlasInspectorCell(owner: owner)

        let snapshotResponse = try await cell.set(
            keypath: "atlas.snapshot",
            value: .null,
            requester: owner
        )

        let snapshotEnvelope = object(snapshotResponse ?? .null)
        XCTAssertEqual(string(snapshotEnvelope["status"]), "ok")
        let snapshot = object(snapshotEnvelope["result"] ?? .null)
        XCTAssertEqual(list(snapshot["cells"]).count, 2)
        XCTAssertEqual(list(snapshot["promptDocuments"]).count, 1)

        let cells = list(snapshot["cells"])
        XCTAssertTrue(cells.contains(where: { object($0)["cellID"] == .string("cell:///Graph") }))
        XCTAssertTrue(cells.contains(where: { object($0)["cellID"] == .string("cell:///Vault") }))

        let coverageResponse = try await cell.set(
            keypath: "atlas.query.coverage",
            value: .string("purpose.local-graph-index"),
            requester: owner
        )

        let coverageEnvelope = object(coverageResponse ?? .null)
        XCTAssertEqual(string(coverageEnvelope["status"]), "ok")
        let coverage = object(coverageEnvelope["result"] ?? .null)
        XCTAssertEqual(string(coverage["status"]), "covered")

        let exportResponse = try await cell.set(
            keypath: "atlas.export.redactedMarkdown",
            value: .null,
            requester: owner
        )

        let exportEnvelope = object(exportResponse ?? .null)
        XCTAssertEqual(string(exportEnvelope["status"]), "ok")
        let exportResult = object(exportEnvelope["result"] ?? .null)
        let markdown = string(exportResult["content"])
        XCTAssertTrue(markdown.contains("# Entity Atlas (Redacted)"))
        XCTAssertFalse(markdown.contains("Keep the atlas redacted and deterministic."))
    }

    private func object(_ value: ValueType, file: StaticString = #filePath, line: UInt = #line) -> Object {
        guard case let .object(object) = value else {
            XCTFail("Expected object ValueType", file: file, line: line)
            return [:]
        }
        return object
    }

    private func list(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) -> ValueTypeList {
        guard let value else {
            XCTFail("Expected list ValueType but got nil", file: file, line: line)
            return []
        }
        guard case let .list(list) = value else {
            XCTFail("Expected list ValueType", file: file, line: line)
            return []
        }
        return list
    }

    private func string(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let value else {
            XCTFail("Expected string ValueType but got nil", file: file, line: line)
            return ""
        }
        guard case let .string(string) = value else {
            XCTFail("Expected string ValueType", file: file, line: line)
            return ""
        }
        return string
    }
}
