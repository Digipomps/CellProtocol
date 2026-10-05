// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if canImport(CellVapor)
import XCTest
import class Vapor.Application
import class Vapor.WebSocket
@testable import CellBase
@testable import CellApple
@testable import CellVapor

/// Real URLSessionWebSocketTask receives every frame. Handshake proof is created
/// by the core client operation; the test supplies its challenge locally so the
/// Apple adapter can be exercised in the receiving/server gate role.
final class AppleWebSocketAdmissionTests: XCTestCase {
    func testQuotaPlusOneRetainsWorkUntilHeldPreparationReturns() async throws {
        let budget = BridgeWebSocketReceiveBudget()
        let socket = AppleQuotaConnection()
        let physical = AppleBridgeTransport(webSocketConnection: socket, receiveBudget: budget)
        let hold = AppleReceiveBarrier()
        physical.beforeReceivePreparation = { await hold.wait() }
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: "wss://native.example/bridge")!, domain: "bridge")
        let gate = try BridgeChannelTransport(underlying: physical, endpoint: endpoint,
            limits: BridgeChannelLimits(), source: "test") { _, _ in AppleReceiveConsumer() }
        let bytes = Data("{}".utf8)
        for _ in 0..<64 { await physical.onMessage(connection: socket, data: bytes) }
        XCTAssertEqual(physical.receiveSnapshot.count, 64)
        XCTAssertEqual(budget.snapshot.count, 64)
        await physical.onMessage(connection: socket, data: bytes)
        XCTAssertTrue(physical.receiveSnapshot.stopped)
        XCTAssertEqual(gate.session.state, .closed)
        XCTAssertEqual(budget.snapshot.count, 64, "Cancellation cannot release non-cooperative retained work")
        await hold.release()
        await physical.waitForPendingReceivesForTesting()
        await gate.close()
        XCTAssertEqual(budget.snapshot.count, 0)
        XCTAssertEqual(socket.closeCount, 1)
    }

    func testGlobalAdmissionSpansAppleConnectionsAndSharedVaporBudgetType() async throws {
        let budget = BridgeWebSocketReceiveBudget(maximumCount: 3, maximumBytes: 10)
        let firstSocket = AppleQuotaConnection(), secondSocket = AppleQuotaConnection()
        let first = AppleBridgeTransport(webSocketConnection: firstSocket, receiveBudget: budget)
        let second = AppleBridgeTransport(webSocketConnection: secondSocket, receiveBudget: budget)
        let hold = AppleReceiveBarrier()
        first.beforeReceivePreparation = { await hold.wait() }
        second.beforeReceivePreparation = { await hold.wait() }
        let bytes = Data("{}".utf8)
        await first.onMessage(connection: firstSocket, data: bytes)
        await first.onMessage(connection: firstSocket, data: bytes)
        await second.onMessage(connection: secondSocket, data: bytes)
        XCTAssertEqual(budget.snapshot.count, 3)
        XCTAssertEqual(budget.snapshot.bytes, 6)
        await second.onMessage(connection: secondSocket, data: bytes)
        XCTAssertTrue(second.receiveSnapshot.stopped)
        XCTAssertFalse(first.receiveSnapshot.stopped)
        XCTAssertEqual(budget.snapshot.count, 3)
        await first.close()
        await hold.release()
        await first.waitForPendingReceivesForTesting()
        await second.waitForPendingReceivesForTesting()
        await second.close()
        XCTAssertEqual(budget.snapshot.count, 0)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        // The old Vapor name is an alias, not an independent global budget.
        XCTAssertTrue(VaporBridgeReceiveBudget.shared === BridgeWebSocketReceiveBudget.shared)
    }

    func testStalePhysicalCallbacksCannotDispatchOrRetireCurrentAdapter() async throws {
        let old = AppleQuotaConnection(), current = AppleQuotaConnection()
        let physical = AppleBridgeTransport(webSocketConnection: current)
        let consumer = AppleReceiveConsumer()
        physical.setDelegate(consumer)
        let command = try JSONEncoder().encode(BridgeCommand(cmd: "get", payload: .string("7"), cid: 1))
        await physical.onMessage(connection: old, data: command)
        await physical.onError(connection: old, error: AppleReceiveError.timeout)
        await physical.onDisconnected(connection: old, error: nil)
        XCTAssertFalse(physical.receiveSnapshot.stopped)
        XCTAssertEqual(consumer.values, [])
        await physical.onMessage(connection: current, data: command)
        await physical.waitForPendingReceivesForTesting()
        XCTAssertEqual(consumer.values, [7])
        await physical.close()
        await physical.onMessage(connection: current, data: command)
        XCTAssertEqual(consumer.values, [7])
        XCTAssertEqual(physical.receiveSnapshot.count, 0)
        XCTAssertEqual(current.closeCount, 1)
    }

    func testHeldMuxOperationAllowsSiblingAndSelectiveCloseOverNativeSocket() async throws {
        let app = try await Application.make(.testing)
        let state = AppleReceiveFixture()
        let hold = AppleReceiveBarrier()
        let a = AppleReceiveConsumer(hold: hold), b = AppleReceiveConsumer()
        app.webSocket("native") { _, socket in state.socket = socket }
        var gate: BridgeChannelTransport?
        do {
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let url = URL(string: "ws://127.0.0.1:\(port)/native")!
            let endpoint = try BridgeChannelAuthentication.Endpoint(url: url, domain: "bridge", allowInsecureLoopback: true)
            let connection = WebSocketTaskConnection2(url: url)
            let physical = AppleBridgeTransport(webSocketConnection: connection)
            let prepared = try BridgeChannelTransport(underlying: physical, endpoint: endpoint,
                limits: BridgeChannelLimits(), source: "native-loopback") { transport, _ in
                    BridgeMultiplexServerSession(physicalTransport: transport) { target, _, channel in
                        let consumer = target == "A" ? a : b
                        consumer.install(channel)
                        return consumer
                    }
                }
            gate = prepared
            try await connection.connect()
            try await appleEventually { state.socket != nil }
            let owner = await MockIdentityVault().identity(for: "apple-receive-test", makeNewIfNotFound: true)!
            let operation = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint)
            let challenge = try prepared.session.issueChallenge(operation.hello)
            let proof = try await operation.sign(challenge)
            try await state.send(BridgeCommand(cmd: "channelAuthProof", payload: .string(
                String(decoding: BridgeChannelAuthentication.encode(proof), as: UTF8.self)), cid: 0))
            try await appleEventually { prepared.session.state == .authenticated }
            for id in ["A", "B"] {
                try await state.send(BridgeCommand(cmd: "openChannel", identity: owner.publicIdentitySnapshot(),
                    payload: nil, cid: 1, protocolVersion: 2, channelID: id, targetEndpoint: id))
            }
            try await appleEventually { a.hasChannel && b.hasChannel }
            func command(_ id: String, _ value: Int) -> BridgeCommand {
                BridgeCommand(cmd: "get", identity: owner.publicIdentitySnapshot(), payload: .string(String(value)),
                    cid: value + 10, protocolVersion: 2, channelID: id)
            }
            try await state.send(command("A", 0))
            try await appleEventually { a.values == [0] }
            try await state.send(command("A", 1))
            try await state.send(command("B", 2))
            try await state.send(BridgeCommand(cmd: "closeChannel", identity: owner.publicIdentitySnapshot(),
                payload: nil, cid: 30, protocolVersion: 2, channelID: "A"))
            try await appleEventually { b.values == [2] && a.isClosed }
            XCTAssertEqual(a.values, [0], "Retired A cannot consume its queued command")
            XCTAssertEqual(prepared.session.state, .authenticated)
            await hold.release()
            await physical.waitForPendingReceivesForTesting()
            XCTAssertEqual(a.values, [0], "Retired A cannot execute queued work after the hold returns")
            try await state.send(command("B", 3))
            try await appleEventually { b.values == [2, 3] }
            await prepared.close()
            await app.server.shutdown(); try await app.asyncShutdown()
        } catch {
            await hold.release()
            await gate?.close()
            await app.server.shutdown(); try? await app.asyncShutdown()
            throw error
        }
    }
}

private final class AppleQuotaConnection: WebSocketConnection2, @unchecked Sendable {
    weak var delegate: WebSocketConnectionDelegate2?
    private let lock = NSLock()
    private var closes = 0
    var closeCount: Int { lock.withLock { closes } }
    func send(text: String) async throws {}
    func send(data: Data) async throws {}
    func connect() async throws {}
    func disconnect() async throws { lock.withLock { closes += 1 } }
    func ping() async throws {}
}

private final class AppleReceiveFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSocket: WebSocket?
    var socket: WebSocket? {
        get { lock.withLock { storedSocket } }
        set { lock.withLock { storedSocket = newValue } }
    }
    func send(_ command: BridgeCommand) async throws {
        let socket = try XCTUnwrap(socket)
        let data = command.cmd.hasPrefix("channelAuth") ? try BridgeChannelAuthentication.encode(command) : try JSONEncoder().encode(command)
        try await socket.send([UInt8](data))
    }
}
private final class AppleReceiveConsumer: BridgeDelegateProtocol, @unchecked Sendable {
    let uuid = UUID().uuidString
    private let lock = NSLock()
    private var channel: BridgeTransportProtocol?
    private var received: [Int] = []
    private var closed = false
    private let hold: AppleReceiveBarrier?
    init(hold: AppleReceiveBarrier? = nil) { self.hold = hold }
    func install(_ channel: BridgeTransportProtocol) { lock.withLock { self.channel = channel } }
    var hasChannel: Bool { lock.withLock { channel != nil } }
    var values: [Int] { lock.withLock { received } }
    var isClosed: Bool { lock.withLock { closed } }
    func consumeCommand(command: BridgeCommand) async throws {
        guard command.command == .get, case .string(let key) = command.payload, let value = Int(key) else { return }
        let first = lock.withLock { received.append(value); return received.count == 1 }
        if first { await hold?.wait() }
    }
    func consumeResponse(command: BridgeCommand) async throws {}
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
    func pushError(errorMessage: String?, error: Error?) async { lock.withLock { closed = true } }
    func ready() async throws {}
}
private actor AppleReceiveBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private enum AppleReceiveError: Error { case timeout }
private func appleEventually(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(1)) }
    guard check() else { XCTFail("Expected native receive progress before releasing the held operation", file: file, line: line); throw AppleReceiveError.timeout }
}
#endif
