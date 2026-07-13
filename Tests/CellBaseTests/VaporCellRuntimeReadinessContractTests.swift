// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellVapor

final class VaporCellRuntimeReadinessContractTests: XCTestCase {
    func testVaporDecodedCellsAreImmediatelyAndConcurrentlyReady() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousDocumentRoot = CellBase.documentRootPath
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.documentRootPath = previousDocumentRoot
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-readiness-vapor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolvedOwner = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)

        try await assertDecodedReadiness(
            await EntityAnchorCell(owner: owner),
            owner: owner,
            expectedKey: "person",
            requiredGrant: Grant(keypath: "person", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await OrchestratorCell(owner: owner),
            owner: owner,
            expectedKey: "outwardMenu",
            requiredGrant: Grant(keypath: "skeleton", permission: "r---")
        )
    }

    private func assertDecodedReadiness<T: GeneralCell>(
        _ source: T,
        owner: Identity,
        expectedKey: String,
        requiredGrant: Grant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let encoded = try JSONEncoder().encode(source)
        let immediate = try JSONDecoder().decode(T.self, from: encoded)
        let immediateKeys = try await immediate.keys(requester: owner)
        XCTAssertTrue(immediateKeys.contains(expectedKey), file: file, line: line)
        XCTAssertTrue(immediate.agreementTemplate.checkGrant(requestedGrant: requiredGrant), file: file, line: line)

        let concurrent = try JSONDecoder().decode(T.self, from: encoded)
        let persistedGrantCount = concurrent.agreementTemplate.grants.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask { try await concurrent.ensureRuntimeReady() }
            }
            try await group.waitForAll()
        }
        let concurrentKeys = try await concurrent.keys(requester: owner)
        XCTAssertTrue(concurrentKeys.contains(expectedKey), file: file, line: line)
        XCTAssertEqual(concurrent.agreementTemplate.grants.count, persistedGrantCount, file: file, line: line)
    }
}
