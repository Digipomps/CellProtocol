// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase
@testable import CellApple

private final class MockAppleWebSocketConnection: WebSocketConnection2 {
    weak var delegate: WebSocketConnectionDelegate2?

    private(set) var sentTexts: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var pingCount = 0
    var sendTextError: Error?
    var sendDataError: Error?

    func send(text: String) async throws {
        if let sendTextError {
            throw sendTextError
        }
        sentTexts.append(text)
    }

    func send(data: Data) async throws {
        if let sendDataError {
            throw sendDataError
        }
        sentData.append(data)
    }

    func connect() async throws {
        connectCount += 1
    }

    func disconnect() async throws {
        disconnectCount += 1
    }

    func ping() async throws {
        pingCount += 1
    }
}

private actor RecordingAppleBridgeDelegate: BridgeDelegateProtocol {
    let uuid: String
    var consumedCommands: [BridgeCommand] = []
    var consumedResponses: [BridgeCommand] = []
    var pushedErrors: [String] = []
    var sentSetValueStates: [(String, SetValueState)] = []

    init(uuid: String = "apple-bridge-delegate") {
        self.uuid = uuid
    }

    func consumeCommand(command: BridgeCommand) async throws {
        consumedCommands.append(command)
    }

    func consumeResponse(command: BridgeCommand) async throws {
        consumedResponses.append(command)
    }

    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}

    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        sentSetValueStates.append((requestedKey, setValueState))
    }

    func pushError(errorMessage: String?, error: Error?) async {
        pushedErrors.append(errorMessage ?? String(describing: error))
    }

    func ready() async throws {}
}

private enum AppleBridgeTransportTestError: Error {
    case sendFailed
}

final class AppleBridgeTransportTests: XCTestCase {
    private var previousResolver: CellResolverProtocol?
    private var previousSendDataAsText = false

    override func setUp() {
        super.setUp()
        previousResolver = CellBase.defaultCellResolver
        previousSendDataAsText = CellBase.sendDataAsText
        CellBase.sendDataAsText = false
    }

    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
        CellBase.sendDataAsText = previousSendDataAsText
        super.tearDown()
    }

    func testInjectedConnectionBecomesDelegateAndSendsBinaryByDefault() async throws {
        let socket = MockAppleWebSocketConnection()
        let transport = AppleBridgeTransport(webSocketConnection: socket)

        try await transport.sendData(Data("hello".utf8))

        XCTAssertTrue(socket.delegate === transport)
        XCTAssertEqual(socket.sentData, [Data("hello".utf8)])
        XCTAssertEqual(socket.sentTexts, [])
    }

    func testSendDataUsesTextFramesWhenConfigured() async throws {
        CellBase.sendDataAsText = true

        let socket = MockAppleWebSocketConnection()
        let transport = AppleBridgeTransport(webSocketConnection: socket)

        try await transport.sendData(Data("hello".utf8))

        XCTAssertEqual(socket.sentTexts, ["hello"])
        XCTAssertEqual(socket.sentData, [])
    }

    func testSendDataWithoutConnectionCleansUpOnlyOnce() async throws {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        CellBase.sendDataAsText = true
        let transport = AppleBridgeTransport()
        transport.setDelegate(RecordingAppleBridgeDelegate(uuid: "missing-socket-delegate"))

        try await transport.sendData(Data("{\"cmd\":\"noop\"}".utf8))
        try await transport.sendData(Data("{\"cmd\":\"noop\"}".utf8))

        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), ["missing-socket-delegate"])
    }

    func testDisconnectAndErrorCleanupUnregisterDelegateOnlyOnce() async {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        let socket = MockAppleWebSocketConnection()
        let transport = AppleBridgeTransport(webSocketConnection: socket)
        let delegate = RecordingAppleBridgeDelegate(uuid: "closed-socket-delegate")
        transport.setDelegate(delegate)

        await transport.onDisconnected(connection: socket, error: nil)
        await transport.onError(connection: socket, error: AppleBridgeTransportTestError.sendFailed)

        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), ["closed-socket-delegate"])
        let pushedErrors = await delegate.pushedErrors
        XCTAssertTrue(pushedErrors.contains("WebSocketConnection disconnected"))
        XCTAssertTrue(pushedErrors.contains("WebSocketConnection error"))
    }

    func testSendFailureCleansUpAndRethrows() async {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        let socket = MockAppleWebSocketConnection()
        socket.sendDataError = AppleBridgeTransportTestError.sendFailed
        let transport = AppleBridgeTransport(webSocketConnection: socket)
        transport.setDelegate(RecordingAppleBridgeDelegate(uuid: "failed-send-delegate"))

        do {
            try await transport.sendData(Data("hello".utf8))
            XCTFail("Expected send failure to be rethrown")
        } catch AppleBridgeTransportTestError.sendFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), ["failed-send-delegate"])
    }

    func testIdentityVaultFallsBackToAppleVaultWithoutBridgeDelegate() async {
        let transport = AppleBridgeTransport(webSocketConnection: MockAppleWebSocketConnection())
        let visitingIdentity = TestFixtures.makeIdentity(displayName: "visiting", uuid: UUID())

        let returnedVault = await transport.identityVault(for: visitingIdentity)

        XCTAssertTrue(returnedVault is IdentityVault)
    }

    func testVisitingIdentityUsesBridgeIdentityVaultWhenDelegateIsBridge() async throws {
        let socket = MockAppleWebSocketConnection()
        let transport = AppleBridgeTransport(webSocketConnection: socket)
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let bridge = try await BridgeBase(
            BridgeBase.Config(
                owner: bridgeOwner,
                transport: transport,
                connection: .outbound
            )
        )
        transport.setDelegate(bridge)
        let visitingIdentity = TestFixtures.makeIdentity(displayName: "visiting", uuid: UUID())

        let returnedVault = await transport.identityVault(for: visitingIdentity)

        XCTAssertTrue(returnedVault is BridgeIdentityVault)
    }

    func testIncomingCommandResponseAndUnknownCommandRouteWithoutCrash() async throws {
        let socket = MockAppleWebSocketConnection()
        let transport = AppleBridgeTransport(webSocketConnection: socket)
        let delegate = RecordingAppleBridgeDelegate()
        transport.setDelegate(delegate)
        let identity = TestFixtures.makeIdentity(displayName: "sender")
        let request = BridgeCommand(cmd: Command.get.rawValue, identity: identity, payload: .string("ping"), cid: 1)
        let response = BridgeCommand(cmd: Command.response.rawValue, identity: identity, payload: .string("pong"), cid: 1)
        let unknown = BridgeCommand(cmd: "futureCommand", identity: identity, payload: .string("future"), cid: 2)

        await transport.onMessage(connection: socket, data: try JSONEncoder().encode(request))
        await transport.onMessage(connection: socket, data: try JSONEncoder().encode(response))
        await transport.onMessage(connection: socket, data: try JSONEncoder().encode(unknown))

        let consumedCommands = await delegate.consumedCommands
        let consumedResponses = await delegate.consumedResponses
        XCTAssertEqual(consumedCommands.map(\.cmd), [Command.get.rawValue, "futureCommand"])
        XCTAssertEqual(consumedCommands.last?.command, Command.none)
        XCTAssertEqual(consumedResponses.map(\.cmd), [Command.response.rawValue])
    }
}
