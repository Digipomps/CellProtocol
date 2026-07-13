// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellApple
@_spi(HAVENRuntime) @testable import CellBase

final class AppleRuntimeStorageTests: XCTestCase {
    private var previousDocumentRootPath: String?
    private var previousDefaultIdentityVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousDocumentRootPath = CellBase.documentRootPath
        previousDefaultIdentityVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.documentRootPath = previousDocumentRootPath
        CellBase.defaultIdentityVault = previousDefaultIdentityVault
        super.tearDown()
    }

    func testFileSystemCellStorageUsesRuntimeDocumentRoot() throws {
        let uuid = UUID().uuidString
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellProtocolTests", isDirectory: true)
            .appendingPathComponent("AppleRuntimeStorageTests-\(uuid)", isDirectory: true)
        let documentsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let expectedURL = testRoot
            .appendingPathComponent("CellsContainer", isDirectory: true)
            .appendingPathComponent(uuid, isDirectory: true)
            .appendingPathComponent("typedCell.json")
        let documentsLeakURL = documentsRoot
            .appendingPathComponent("CellsContainer", isDirectory: true)
            .appendingPathComponent(uuid, isDirectory: true)
            .appendingPathComponent("typedCell.json")

        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: documentsLeakURL.deletingLastPathComponent())
        }

        CellBase.documentRootPath = testRoot.path

        var configuration = CellConfiguration(name: "Runtime root probe")
        configuration.uuid = uuid
        try FileSystemCellStorage().storeCell(
            cellName: "CellConfiguration",
            cell: configuration,
            uuid: uuid
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: documentsLeakURL.path),
            "Test-host storage must not leak runtime cells into the user's Documents directory."
        )
    }

    func testFileSystemCellStorageRoundTripsFromRuntimeDocumentRoot() async throws {
        let uuid = UUID().uuidString
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellProtocolTests", isDirectory: true)
            .appendingPathComponent("AppleRuntimeStorageRoundTrip-\(uuid)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        CellBase.documentRootPath = testRoot.path

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        let typedUtility = TypedCellUtility(storage: FileSystemCellStorage())
        try typedUtility.register(name: "GeneralCell", type: GeneralCell.self)
        typedUtility.storeAsTypedCell(cellName: "GeneralCell", cell: cell, uuid: cell.uuid)

        let loaded = typedUtility.loadTypedEmitCell(with: cell.uuid) as? GeneralCell
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.uuid, cell.uuid)
        XCTAssertEqual(loaded?.storedOwnerIdentity.uuid, owner.uuid)
    }
}
