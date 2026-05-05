// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellVapor

final class VaporBridgeTransportTests: XCTestCase {
    private var previousResolver: CellResolverProtocol?
    private var previousSendDataAsText = false

    override func setUp() {
        super.setUp()
        previousResolver = CellBase.defaultCellResolver
        previousSendDataAsText = CellBase.sendDataAsText
    }

    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
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
