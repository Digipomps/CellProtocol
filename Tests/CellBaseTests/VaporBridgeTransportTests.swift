// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellVapor

final class VaporBridgeTransportTests: XCTestCase {
    private var previousResolver: CellResolverProtocol?
    private var previousDocumentRootPath: String?
    private var previousSecurityEventSink: CellSecurityEventSink?
    private var previousSendDataAsText = false

    override func setUp() {
        super.setUp()
        previousResolver = CellBase.defaultCellResolver
        previousDocumentRootPath = CellBase.documentRootPath
        previousSecurityEventSink = CellBase.securityEventSink
        previousSendDataAsText = CellBase.sendDataAsText
        CellBase.securityEventSink = nil
    }

    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
        CellBase.documentRootPath = previousDocumentRootPath
        CellBase.securityEventSink = previousSecurityEventSink
        CellBase.sendDataAsText = previousSendDataAsText
        super.tearDown()
    }

    func testCloseCleanupUnregistersDelegateOnlyOnce() async {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        let transport = VaporBridgeTransport()
        transport.setDelegate(RecordingBridgeDelegate(uuid: "vapor-bridge-delegate"))

        await transport.cleanupClosedWebSocketRegistration()
        await transport.cleanupClosedWebSocketRegistration()

        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), ["vapor-bridge-delegate"])
    }

    func testSendDataWithoutWebSocketCleansUpInTextMode() async {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        CellBase.sendDataAsText = true
        let transport = VaporBridgeTransport()
        transport.setDelegate(RecordingBridgeDelegate(uuid: "text-mode-delegate"))

        await transport.sendData(Data("{\"cmd\":\"noop\"}".utf8))
        await transport.sendData(Data("{\"cmd\":\"noop\"}".utf8))

        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), ["text-mode-delegate"])
    }

    func testIdentitySnapshotPreservesWireIdentityFields() {
        let identity = Identity("identity-snapshot", displayName: "Snapshot Identity", identityVault: MockIdentityVault())
        identity.properties = ["role": .string("speaker")]

        let restored = VaporBridgeIdentitySnapshot(identity).makeIdentity()

        XCTAssertEqual(restored.uuid, "identity-snapshot")
        XCTAssertEqual(restored.displayName, "Snapshot Identity")
        guard case .string("speaker") = restored.properties?["role"] else {
            XCTFail("Expected identity properties to survive the snapshot round trip")
            return
        }
    }

    func testVaporVaultIdentityValueForKeyPublishesStoredValueForRequester() async throws {
        var vaultIdentity = VaporIdentityVault.VaultIdentity()
        vaultIdentity.properties?["nickname"] = .string("Ada")

        let value = try await vaultIdentity
            .valueForKey(key: "nickname", requester: vaultIdentity)
            .getOneWithTimeout(1)

        guard case let .string(nickname) = value as? ValueType else {
            return XCTFail("Expected ValueType.string from Vapor VaultIdentity property publisher")
        }
        XCTAssertEqual(nickname, "Ada")
    }

    func testVaporIdentityVaultPersistsUnderCellBaseDocumentRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaporIdentityVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        CellBase.documentRootPath = root.path
        _ = await VaporIdentityVault.shared.initialize()

        let identity = await VaporIdentityVault.shared.identity(
            for: "vapor-vault-document-root-test",
            makeNewIfNotFound: true
        )

        XCTAssertNotNil(identity)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(VaporIdentityVault.identitiesFileName).path
            ),
            "VaporIdentityVault must use CellBase.documentRootPath instead of the shared host vault."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent(".secrets", isDirectory: true)
                    .appendingPathComponent("vault-master.key")
                    .path
            ),
            "The vault master key should live with the isolated runtime root."
        )
    }

    func testVaporIdentityVaultReloadsWhenDocumentRootChanges() async throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaporIdentityVaultTests-\(UUID().uuidString)-A", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaporIdentityVaultTests-\(UUID().uuidString)-B", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        CellBase.documentRootPath = firstRoot.path
        _ = await VaporIdentityVault.shared.initialize()
        let firstIdentity = await VaporIdentityVault.shared.identity(
            for: "vapor-vault-first-root",
            makeNewIfNotFound: true
        )
        XCTAssertNotNil(firstIdentity)

        CellBase.documentRootPath = secondRoot.path
        _ = await VaporIdentityVault.shared.initialize()
        let leakedIdentity = await VaporIdentityVault.shared.identity(
            for: "vapor-vault-first-root",
            makeNewIfNotFound: false
        )
        XCTAssertNil(leakedIdentity, "Identities from the previous runtime root must not leak into a new root.")

        let secondIdentity = await VaporIdentityVault.shared.identity(
            for: "vapor-vault-second-root",
            makeNewIfNotFound: true
        )
        XCTAssertNotNil(secondIdentity)

        CellBase.documentRootPath = firstRoot.path
        _ = await VaporIdentityVault.shared.initialize()
        let reloadedFirstIdentity = await VaporIdentityVault.shared.identity(
            for: "vapor-vault-first-root",
            makeNewIfNotFound: false
        )
        XCTAssertNotNil(reloadedFirstIdentity, "Switching back to the first root should reload its persisted vault.")
    }

    func testOversizedInboundPayloadIsRejectedBeforeDecode() async {
        let transport = VaporBridgeTransport()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        transport.setDelegate(RecordingBridgeDelegate(uuid: "vapor-payload-validator"))
        let oversized = Data(
            repeating: 0x20,
            count: BridgeInboundPayloadValidator.defaultMaximumBytes + 1
        )

        do {
            try await transport.extractCommand(oversized)
            XCTFail("Expected oversized payload rejection")
        } catch let error as BridgeInboundPayloadError {
            XCTAssertEqual(
                error,
                .tooLarge(
                    actualBytes: oversized.count,
                    maximumBytes: BridgeInboundPayloadValidator.defaultMaximumBytes
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.bridgePayloadTooLarge)
        XCTAssertEqual(events.last?.resource.identifier, "vapor-websocket")
    }
}

private final class RecordingBridgeDelegate: BridgeDelegateProtocol {
    let uuid: String

    init(uuid: String) {
        self.uuid = uuid
    }

    func consumeCommand(command: BridgeCommand) async throws {}

    func consumeResponse(command: BridgeCommand) async throws {}

    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}

    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}

    func pushError(errorMessage: String?, error: Error?) async {}

    func ready() async throws {}
}
