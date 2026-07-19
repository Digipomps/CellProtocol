// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase

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
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        setenv("HOME", tempRoot.path, 1)
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        return try await body(tempRoot.path)
    }

    private func withSeparateTempHomeAndDocumentRoot<T>(
        _ body: (_ homeRoot: URL, _ documentRoot: URL) async throws -> T
    ) async throws -> T {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-tests-\(UUID().uuidString)")
        let homeRoot = tempRoot.appendingPathComponent("home")
        let documentRoot = tempRoot.appendingPathComponent("runtime-cells")
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        setenv("HOME", homeRoot.path, 1)
        CellBase.documentRootPath = documentRoot.path
        return try await body(homeRoot, documentRoot)
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

    func testFileSystemStorageStoresUnderDocumentRootNotHome() async throws {
        try await withSeparateTempHomeAndDocumentRoot { homeRoot, documentRoot in
            let storage = FileSystemCellStorage()
            let tcu = TypedCellUtility(storage: storage)
            try tcu.register(name: "GeneralCell", type: GeneralCell.self)

            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await GeneralCell(owner: owner)

            tcu.storeAsTypedCell(cellName: "GeneralCell", cell: cell, uuid: cell.uuid)

            let documentRootFile = documentRoot
                .appendingPathComponent(cell.uuid)
                .appendingPathComponent("typedCell.json")
            let oldHomeFile = homeRoot
                .appendingPathComponent("CellsContainer")
                .appendingPathComponent(cell.uuid)
                .appendingPathComponent("typedCell.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: documentRootFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldHomeFile.path))

            let loaded = tcu.loadTypedEmitCell(with: cell.uuid) as? GeneralCell
            XCTAssertEqual(loaded?.uuid, cell.uuid)
        }
    }

    func testCellStoragePathPolicyRejectsTraversalAndSymlinkEscape() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cell-storage-path-policy-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = tempRoot.appendingPathComponent("storage", isDirectory: true)
        let outsideRoot = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertThrowsError(try CellStoragePathPolicy.component("..", under: storageRoot))
        XCTAssertThrowsError(try CellStoragePathPolicy.component("nested/name", under: storageRoot))
        XCTAssertThrowsError(try CellStoragePathPolicy.relativePath("../outside", under: storageRoot))
        XCTAssertThrowsError(try CellStoragePathPolicy.relativePath("/absolute", under: storageRoot))
        XCTAssertThrowsError(try CellStoragePathPolicy.existingURL(outsideRoot, under: storageRoot))

        let symlink = storageRoot.appendingPathComponent("linked-outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideRoot)
        XCTAssertThrowsError(try CellStoragePathPolicy.existingURL(symlink, under: storageRoot))
    }

    func testFileSystemStorageRejectsProductionLimitBeforeDecode() async throws {
        try await withSeparateTempHomeAndDocumentRoot { _, documentRoot in
            let uuid = "oversized-cell"
            let cellDirectory = documentRoot.appendingPathComponent(uuid, isDirectory: true)
            let cellFile = cellDirectory.appendingPathComponent("typedCell.json")
            try FileManager.default.createDirectory(at: cellDirectory, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: cellFile.path, contents: nil))
            let handle = try FileHandle(forWritingTo: cellFile)
            try handle.truncate(atOffset: UInt64(PersistedCellFileIO.maximumStoredCellBytes + 1))
            try handle.close()

            let decoder = CellJSONCoder()
            XCTAssertThrowsError(try FileSystemCellStorage().loadEmitCell(with: uuid, decoder: decoder)) { error in
                XCTAssertEqual(
                    error as? FileSystemCellStorage.StorageError,
                    .storedCellTooLarge
                )
            }
        }
    }

    func testFileSystemStorageRejectsPathTraversal() async throws {
        try await withSeparateTempHomeAndDocumentRoot { _, documentRoot in
            let storage = FileSystemCellStorage()
            var configuration = CellConfiguration(name: "Traversal probe")
            configuration.uuid = "traversal-probe"
            let escapeName = "escaped-cell-\(UUID().uuidString)"
            let escapedURL = documentRoot
                .deletingLastPathComponent()
                .appendingPathComponent(escapeName)
                .appendingPathComponent("typedCell.json")

            XCTAssertThrowsError(try storage.storeCell(
                cellName: "CellConfiguration",
                cell: configuration,
                uuid: "../\(escapeName)"
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))

            let decoder = CellJSONCoder()
            XCTAssertThrowsError(try storage.loadEmitCell(
                at: "../\(escapeName)",
                decoder: decoder
            ))
            XCTAssertThrowsError(try storage.loadEmitCell(
                with: documentRoot.deletingLastPathComponent(),
                decoder: decoder
            ))
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

/// Cross-platform coverage for the descriptor reader itself. Keep these tests
/// outside `canImport(CellVapor)` so the Glibc implementation is exercised by
/// the Linux gate even when the test target does not link the Vapor product.
final class PersistedCellFileIOTests: XCTestCase {
    func testReaderAcceptsExactBoundaryAndRejectsOneByteOver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-cell-bounded-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exactURL = root.appendingPathComponent("exact")
        let overURL = root.appendingPathComponent("over")
        let testLimit = 4_096
        let exact = Data(repeating: 0xA5, count: testLimit)
        try exact.write(to: exactURL)
        try Data(repeating: 0x5A, count: testLimit + 1).write(to: overURL)

        XCTAssertEqual(
            try PersistedCellFileIO.readRegularFile(at: exactURL, maximumBytes: testLimit),
            exact
        )
        XCTAssertThrowsError(
            try PersistedCellFileIO.readRegularFile(at: overURL, maximumBytes: testLimit)
        ) { error in
            XCTAssertEqual(
                error as? PersistedCellFileIO.ReadError,
                .storedCellTooLarge
            )
        }
    }

    func testReaderRejectsFinalSymlinkWithoutLeakingPathOrContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-cell-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = "private-cell-content-marker"
        let targetURL = root.appendingPathComponent("target")
        let symlinkURL = root.appendingPathComponent("typedCell.json")
        try Data(marker.utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try PersistedCellFileIO.readStoredCell(at: symlinkURL)) { error in
            XCTAssertEqual(error as? PersistedCellFileIO.ReadError, .invalidFile)
            let description = String(describing: error)
            XCTAssertFalse(description.contains(root.path))
            XCTAssertFalse(description.contains(marker))
        }
    }

    func testReaderRejectsHardLinkAndDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-cell-file-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetURL = root.appendingPathComponent("target")
        let hardLinkURL = root.appendingPathComponent("typedCell.json")
        try Data("persisted-cell".utf8).write(to: targetURL)
        try FileManager.default.linkItem(at: targetURL, to: hardLinkURL)

        XCTAssertThrowsError(try PersistedCellFileIO.readStoredCell(at: hardLinkURL)) { error in
            XCTAssertEqual(error as? PersistedCellFileIO.ReadError, .invalidFile)
        }
        XCTAssertThrowsError(try PersistedCellFileIO.readStoredCell(at: root)) { error in
            XCTAssertEqual(error as? PersistedCellFileIO.ReadError, .invalidFile)
        }
    }
}
