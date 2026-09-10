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

final class EntityAnchorEncryptionTests: XCTestCase {
    private var previousKey: Data?
    private var previousRoot: String?
    private var previousVault: IdentityVaultProtocol?
    private var root: URL!

    override func setUpWithError() throws {
        previousKey = CellBase.persistedCellMasterKey
        previousRoot = CellBase.documentRootPath
        previousVault = CellBase.defaultIdentityVault
        root = FileManager.default.temporaryDirectory.appendingPathComponent("entity-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x67, count: 32)
        CellBase.defaultIdentityVault = MockIdentityVault()
    }

    override func tearDownWithError() throws {
        CellBase.persistedCellMasterKey = previousKey
        CellBase.documentRootPath = previousRoot
        CellBase.defaultIdentityVault = previousVault
        try FileManager.default.removeItem(at: root)
    }

    func testAppleSnapshotAndJournalEncryptionRestartAndLegacyMigration() async throws {
        let owner = try await owner()
        try await verify(await EntityAnchorCell(owner: owner), owner: owner,
            directory: CellApple.getCellsDocumentsDirectory())
    }

    func testSharedCodecRejectsMissingWrongKeyAndCrossFileSubstitution() async throws {
        let owner = try await owner()
        let agreement = Agreement(owner: owner)
        let data = Data("synthetic-private-data".utf8)
        let encrypted = try EntityAnchorPersistence.encode(data, cellUUID: "one", filename: "snapshot",
            owner: owner, agreement: agreement)
        XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(encrypted))
        XCTAssertThrowsError(try EntityAnchorPersistence.decode(encrypted, cellUUID: "two", filename: "snapshot"))
        XCTAssertThrowsError(try EntityAnchorPersistence.decode(encrypted, cellUUID: "one", filename: "journal"))
        CellBase.persistedCellMasterKey = Data(repeating: 0x68, count: 32)
        XCTAssertThrowsError(try EntityAnchorPersistence.decode(encrypted, cellUUID: "one", filename: "snapshot"))
        CellBase.persistedCellMasterKey = nil
        // Hosts may supply a key through the environment; do not alter it in tests.
        if ProcessInfo.processInfo.environment["CELL_PERSISTENCE_MASTER_KEY_B64"] == nil {
            XCTAssertThrowsError(try EntityAnchorPersistence.encode(data, cellUUID: "one", filename: "snapshot",
                owner: owner, agreement: agreement))
        }
        agreement.conditions = [ColdStorageCondition(allowPersistedColdTier: true, encryptedAtRestRequired: false)]
        XCTAssertEqual(try EntityAnchorPersistence.encode(data, cellUUID: "one", filename: "snapshot",
            owner: owner, agreement: agreement), data)
    }

    func owner() async throws -> Identity {
        let candidate = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        return try XCTUnwrap(candidate)
    }

    func verify<T: GeneralCell>(_ cell: T, owner: Identity, directory: URL) async throws {
        var batch = EntityBatchPersistEnvelope(schema: "test.security.v1",
            mutations: [.init(keypath: "person.headline", value: .string("synthetic-private-data"))])
        batch.commitRequest = try await EntityAuthorityCommitRequest.signed(envelope: batch,
            mutationID: "security-write", epoch: 1, expectedRevision: 0, expectedPreviousHash: nil,
            requester: owner, purposeRef: "purpose://security-test")
        let committed = expectation(description: "Owner-authorized journal commit")
        let subscription = try await cell.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard case let .object(response) = event.content,
                  response["operation"] == .string(EntityBatchPersistEnvelope.operation) else { return }
            XCTAssertEqual(response["status"], .string("authority_committed"))
            committed.fulfill()
        })
        defer { subscription.cancel() }
        let source = FlowElementPusherCell(owner: owner)
        _ = try await cell.attach(emitter: source, label: "security-input", requester: owner)
        try await cell.absorbFlow(label: "security-input", requester: owner)
        source.feedPublisher.send(FlowElement(title: "security-test", content: .object([
            "operation": .string(EntityBatchPersistEnvelope.operation), "envelope": .object(batch.objectValue())
        ]), properties: .init(type: .content, contentType: .object)))
        await fulfillment(of: [committed], timeout: 5)
        let snapshot = try JSONEncoder().encode(cell)
        let files = ["keypathstorage.json", "entity-authority-journal.json"]
        var encryptedFiles = [Data]()
        for file in files {
            let url = directory.appendingPathComponent(cell.name).appendingPathComponent(file)
            let stored = try Data(contentsOf: url)
            XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(stored))
            XCTAssertNil(stored.range(of: Data("synthetic-private-data".utf8)))
            encryptedFiles.append(stored)
            // Simulate a pre-fix side file, preserving its validated journal/receipt.
            let plain = try EntityAnchorPersistence.decode(stored, cellUUID: cell.uuid, filename: file)
            try plain.write(to: url, options: .atomic)
        }
        let restarted = try JSONDecoder().decode(T.self, from: snapshot)
        let value = try await restarted.get(keypath: "person.headline", requester: owner)
        XCTAssertEqual(value, .string("synthetic-private-data"))
        for file in files {
            let stored = try Data(contentsOf: directory.appendingPathComponent(cell.name).appendingPathComponent(file))
            XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(stored), "Legacy \(file) was not migrated")
        }
        // Failed encrypted reads must not overwrite the original files.
        CellBase.persistedCellMasterKey = Data(repeating: 0x69, count: 32)
        let failedRestart = try JSONDecoder().decode(T.self, from: snapshot)
        _ = try? await failedRestart.get(keypath: "person.headline", requester: owner)
        for (index, file) in files.enumerated() {
            let url = directory.appendingPathComponent(cell.name).appendingPathComponent(file)
            let before = try Data(contentsOf: url)
            do {
                _ = try await failedRestart.set(keypath: "person.uncommitted", value: .string("must-fail"), requester: owner)
                XCTFail("Write succeeded after encrypted storage failed to load")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(encryptedFiles[index]))
        }
    }
}
