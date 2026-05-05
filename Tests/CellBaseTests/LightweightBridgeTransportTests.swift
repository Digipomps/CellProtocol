// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

private final class MockLightweightWebSocketClient: LightweightWebSocketClient, @unchecked Sendable {
    weak var delegate: LightweightWebSocketClientDelegate?

    private(set) var sentTexts: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var pingCount = 0
    private(set) var connected = false
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private var pingResults: [Result<Void, Error>]

    init(pingResults: [Result<Void, Error>] = []) {
        self.pingResults = pingResults
    }

    func connect() async throws {
        connectCount += 1
        connected = true
        await delegate?.clientDidConnect(self)
    }

    func disconnect() async throws {
        disconnectCount += 1
        connected = false
        await delegate?.clientDidDisconnect(self, error: nil)
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func send(data: Data) async throws {
        sentData.append(data)
    }

    func ping() async throws {
        pingCount += 1
        guard !pingResults.isEmpty else {
            return
        }
        switch pingResults.removeFirst() {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func emit(command: BridgeCommand) async throws {
        let data = try JSONEncoder().encode(command)
        await delegate?.client(self, didReceive: data)
    }
}

private final class MockLightweightWebSocketClientSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [MockLightweightWebSocketClient]

    init(_ clients: [MockLightweightWebSocketClient]) {
        self.clients = clients
    }

    func next() -> MockLightweightWebSocketClient {
        lock.lock()
        defer { lock.unlock() }
        if clients.count == 1, let client = clients.first {
            return client
        }
        return clients.removeFirst()
    }
}

private actor RecordingBridgeDelegate: BridgeDelegateProtocol {
    var consumedCommands: [BridgeCommand] = []
    var consumedResponses: [BridgeCommand] = []
    var sentSetValueStates: [(String, SetValueState)] = []
    var pushedErrors: [String] = []

    let uuid = "recording-bridge-delegate"

    func consumeCommand(command: BridgeCommand) async throws {
        consumedCommands.append(command)
    }

    func consumeResponse(command: BridgeCommand) async throws {
        consumedResponses.append(command)
    }

    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
    }

    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        sentSetValueStates.append((requestedKey, setValueState))
    }

    func pushError(errorMessage: String?, error: Error?) async {
        pushedErrors.append(errorMessage ?? String(describing: error))
    }

    func ready() async throws {
    }
}

final class LightweightBridgeTransportTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousSendDataAsText = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousSendDataAsText = CellBase.sendDataAsText
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.sendDataAsText = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.sendDataAsText = previousSendDataAsText
        super.tearDown()
    }

    func testSendDataUsesBinaryFramesByDefaultAndPerformsInitialPing() async throws {
        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)
        try await transport.sendData(Data("hello".utf8))

        XCTAssertEqual(socket.sentData, [Data("hello".utf8)])
        XCTAssertEqual(socket.sentTexts, [])
        XCTAssertEqual(socket.pingCount, 1)
    }

    func testSendDataUsesTextFramesWhenConfigured() async throws {
        CellBase.sendDataAsText = true

        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)
        try await transport.sendData(Data("hello".utf8))

        XCTAssertEqual(socket.sentTexts, ["hello"])
        XCTAssertEqual(socket.sentData, [])
        XCTAssertEqual(socket.pingCount, 1)
    }

    func testIncomingCommandAndResponseAreRoutedToDelegate() async throws {
        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)

        let request = BridgeCommand(cmd: Command.get.rawValue, identity: identity, payload: .string("ping"), cid: 1)
        let response = BridgeCommand(cmd: Command.response.rawValue, identity: identity, payload: .string("pong"), cid: 1)

        try await socket.emit(command: request)
        try await socket.emit(command: response)

        let consumedCommands = await delegate.consumedCommands
        let consumedResponses = await delegate.consumedResponses

        XCTAssertEqual(consumedCommands.count, 1)
        XCTAssertEqual(consumedResponses.count, 1)
        XCTAssertEqual(consumedCommands.first?.command, .get)
        XCTAssertEqual(consumedResponses.first?.command, .response)
        XCTAssertNotNil(consumedCommands.first?.identity?.identityVault)
        XCTAssertNotNil(consumedResponses.first?.identity?.identityVault)
    }

    func testIdentityVaultFallsBackToDefaultIdentityVault() async throws {
        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)

        let returnedVault = await transport.identityVault(for: identity)
        XCTAssertTrue(returnedVault is MockIdentityVault)
    }

    func testVisitingIdentityUsesBridgeIdentityVaultWhenDelegateIsBridge() async throws {
        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let bridge = try await BridgeBase(
            BridgeBase.Config(
                owner: bridgeOwner,
                transport: transport,
                connection: .outbound
            )
        )
        transport.setDelegate(bridge)

        let localIdentity = TestFixtures.makeIdentity(
            displayName: "local-owner",
            uuid: TestFixtures.fixedUUID1
        )
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: localIdentity)

        let visitingIdentity = TestFixtures.makeIdentity(
            displayName: "visiting-owner",
            uuid: TestFixtures.fixedUUID2
        )
        let returnedVault = await transport.identityVault(for: visitingIdentity)

        XCTAssertTrue(returnedVault is BridgeIdentityVault)
    }

    func testKnownLocalVisitingIdentityUsesDefaultVaultWhenDelegateIsBridge() async throws {
        let socket = MockLightweightWebSocketClient()
        let transport = LightweightBridgeTransport(connectionFactory: { _ in socket })
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let bridge = try await BridgeBase(
            BridgeBase.Config(
                owner: bridgeOwner,
                transport: transport,
                connection: .outbound
            )
        )
        transport.setDelegate(bridge)

        let localIdentity = TestFixtures.makeIdentity(
            displayName: "local-owner",
            uuid: TestFixtures.fixedUUID1
        )
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: localIdentity)

        guard let knownLocalIdentity = await CellBase.defaultIdentityVault?.identity(
            for: "conference-organizer",
            makeNewIfNotFound: true
        ) else {
            XCTFail("Expected local conference organizer identity")
            return
        }

        let returnedVault = await transport.identityVault(for: knownLocalIdentity)

        XCTAssertTrue(returnedVault is MockIdentityVault)
    }

    func testLifecycleReactivationReconnectsAfterWakeFailure() async throws {
        let pingError = URLError(.networkConnectionLost)
        let firstSocket = MockLightweightWebSocketClient(pingResults: [.success(()), .failure(pingError)])
        let secondSocket = MockLightweightWebSocketClient(pingResults: [.success(())])
        let sequence = MockLightweightWebSocketClientSequence([firstSocket, secondSocket])

        let transport = LightweightBridgeTransport(
            connectionFactory: { _ in sequence.next() },
            keepAliveIntervalNanoseconds: 5_000_000_000,
            reconnectBaseDelayNanoseconds: 20_000_000,
            reconnectMaximumDelayNanoseconds: 20_000_000
        )
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)

        await transport.handleLifecycleReactivation(trigger: "wake")
        try await Task.sleep(nanoseconds: 120_000_000)
        try await transport.sendData(Data("after-wake".utf8))

        XCTAssertEqual(firstSocket.disconnectCount, 1)
        XCTAssertEqual(secondSocket.connectCount, 1)
        XCTAssertEqual(secondSocket.sentData, [Data("after-wake".utf8)])
        XCTAssertGreaterThanOrEqual(secondSocket.pingCount, 1)

        let pushedErrors = await delegate.pushedErrors
        XCTAssertTrue(pushedErrors.contains("Lightweight bridge wake health check failed; attempting reconnect"))
    }

    func testKeepAliveFailureReconnectsUsingFreshSocket() async throws {
        let pingError = URLError(.networkConnectionLost)
        let firstSocket = MockLightweightWebSocketClient(pingResults: [.success(()), .failure(pingError)])
        let secondSocket = MockLightweightWebSocketClient(pingResults: [.success(())])
        let sequence = MockLightweightWebSocketClientSequence([firstSocket, secondSocket])

        let transport = LightweightBridgeTransport(
            connectionFactory: { _ in sequence.next() },
            keepAliveIntervalNanoseconds: 50_000_000,
            reconnectBaseDelayNanoseconds: 20_000_000,
            reconnectMaximumDelayNanoseconds: 20_000_000
        )
        let delegate = RecordingBridgeDelegate()
        transport.setDelegate(delegate)

        let identity = TestFixtures.makeIdentity(displayName: "owner")
        try await transport.setup(URL(string: "wss://bridge.example/cell")!, identity: identity)

        try await Task.sleep(nanoseconds: 220_000_000)
        try await transport.sendData(Data("after-reconnect".utf8))

        XCTAssertEqual(firstSocket.disconnectCount, 1)
        XCTAssertEqual(secondSocket.connectCount, 1)
        XCTAssertEqual(secondSocket.sentData, [Data("after-reconnect".utf8)])
        XCTAssertGreaterThanOrEqual(secondSocket.pingCount, 1)

        let pushedErrors = await delegate.pushedErrors
        XCTAssertTrue(pushedErrors.contains("Lightweight bridge keepalive failed; attempting reconnect"))
    }
}
