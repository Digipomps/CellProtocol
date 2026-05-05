// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

#if canImport(CellVapor)
import CellVapor

final class PersistenceTests: XCTestCase {
    private var previousHome: String?
    private var previousDocumentRoot: String?
    private var previousPersistedCellMasterKey: Data?
    private var previousDiagnosticLogDomains: Set<CellBase.DiagnosticLogDomain>?
    private var previousDiagnosticLogHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?

    override func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["HOME"]
        previousDocumentRoot = CellBase.documentRootPath
        previousPersistedCellMasterKey = CellBase.persistedCellMasterKey
        previousDiagnosticLogDomains = CellBase.enabledDiagnosticLogDomains
        previousDiagnosticLogHandler = CellBase.diagnosticLogHandler
    }

    override func tearDown() {
        if let previousHome {
            setenv("HOME", previousHome, 1)
        } else {
            unsetenv("HOME")
        }
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.persistedCellMasterKey = previousPersistedCellMasterKey
        CellBase.enabledDiagnosticLogDomains = previousDiagnosticLogDomains ?? []
        CellBase.diagnosticLogHandler = previousDiagnosticLogHandler
        super.tearDown()
    }

    private func withTempHome<T>(
        _ body: (String) async throws -> T
    ) async throws -> T {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("HOME", tempRoot.path, 1)
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        return try await body(tempRoot.path)
    }

    func testTypedCellUtilityRoundTripWithFileSystemStorage() async throws {
        try await withTempHome { _ in
            let storage = FileSystemCellStorage()
            let tcu = TypedCellUtility(storage: storage)
            try tcu.register(name: "GeneralCell", type: GeneralCell.self)

            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await GeneralCell(owner: owner)

            tcu.storeAsTypedCell(cellName: "GeneralCell", cell: cell, uuid: cell.uuid)

            let loaded = tcu.loadTypedEmitCell(with: cell.uuid) as? GeneralCell
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.uuid, cell.uuid)

            let loadedByPath = tcu.loadTypedEmitCell(at: cell.uuid) as? GeneralCell
            XCTAssertNotNil(loadedByPath)
            XCTAssertEqual(loadedByPath?.uuid, cell.uuid)
        }
    }

    func testLoadMissingCellReturnsNil() async throws {
        try await withTempHome { _ in
            let storage = FileSystemCellStorage()
            let tcu = TypedCellUtility(storage: storage)
            try tcu.register(name: "GeneralCell", type: GeneralCell.self)

            var lifecycleMessages: [String] = []
            CellBase.diagnosticLogHandler = { domain, message in
                guard domain == .lifecycle else { return }
                lifecycleMessages.append(message)
            }

            let loaded = tcu.loadTypedEmitCell(with: "missing")
            XCTAssertNil(loaded)
            XCTAssertTrue(lifecycleMessages.isEmpty)

            CellBase.enabledDiagnosticLogDomains = [.lifecycle]
            let loadedWithDiagnostics = tcu.loadTypedEmitCell(with: "missing")
            XCTAssertNil(loadedWithDiagnostics)
            XCTAssertTrue(lifecycleMessages.contains("No persisted typed cell at uuid:missing"))
        }
    }

    func testTypedCellUtilityEncryptedRoundTripWhenRequired() async throws {
        try await withTempHome { tempRoot in
            CellBase.persistedCellMasterKey = Data(repeating: 0xA5, count: 32)

            let storage = FileSystemCellStorage()
            let tcu = TypedCellUtility(storage: storage)
            try tcu.register(name: "GeneralCell", type: GeneralCell.self)

            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await GeneralCell(owner: owner)

            tcu.storeAsTypedCell(
                cellName: "GeneralCell",
                cell: cell,
                uuid: cell.uuid,
                options: CellStorageWriteOptions(
                    ownerIdentityUUID: owner.uuid,
                    encryptedAtRestRequired: true
                )
            )

            let typedCellFiles = try FileManager.default
                .subpathsOfDirectory(atPath: tempRoot)
                .filter { $0.hasSuffix("typedCell.json") }
            XCTAssertEqual(typedCellFiles.count, 1)

            let persistedFileURL = URL(fileURLWithPath: tempRoot).appendingPathComponent(typedCellFiles[0])
            let persistedData = try Data(contentsOf: persistedFileURL)
            XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(persistedData))

            let loaded = tcu.loadTypedEmitCell(with: cell.uuid) as? GeneralCell
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.uuid, cell.uuid)
        }
    }
}
#endif
