// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if canImport(CellVapor)
import XCTest
import class Vapor.Application
import WebSocketKit
import NIOCore
import NIOPosix
import NIOWebSocket
@testable import CellBase
@testable import CellVapor

/// N35: real HTTP upgrade, WebSocket callbacks, authentication, mux and protected
/// Cell GET. Only the resolver and the non-cooperative Cell barrier are fixtures.
final class BridgeMultiplexTwoChannelTests: XCTestCase {
    func testHeldProtectedAAllowsSignedBAndSelectiveCloseRetainsQuotaAndRejectsLateResult() async throws {
        let oldResolver = CellBase.defaultCellResolver, oldVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultCellResolver = oldResolver; CellBase.defaultIdentityVault = oldVault }
        let clientVault = EphemeralIdentityVault(), serverVault = SigningTrapVault()
        let identity = await clientVault.identity(for: "n35-client", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(identity)
        CellBase.defaultIdentityVault = serverVault
        let cell = await GeneralCell(owner: owner.publicIdentitySnapshot())
        let hold = N35Barrier(), entered = expectation(description: "A entered protected GET"), returned = expectation(description: "held Cell returned late result")
        await cell.addInterceptForGet(requester: owner, key: "held") { _, _ in
            entered.fulfill()
            await hold.wait() // deliberately ignores cancellation
            returned.fulfill()
            return .string("late-A")
        }
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("signed-value") }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "N35", emitCell: cell, scope: .template, identity: owner)
        let app = try await Application.make(.testing)
        let state = N35State(), limits = BridgeChannelLimits()
        app.webSocket("n35") { _, socket in
            do {
                let raw = VaporBridgeTransport(webSocket: socket)
                let gate = try BridgeChannelTransport(underlying: raw, endpoint: state.endpoint(), limits: limits, source: "127.0.0.1") { physical, _ in
                    BridgeMultiplexServerSession(physicalTransport: physical) { target, _, logical in
                        let bridge = try await BridgeBase(.init(owner: owner.publicIdentitySnapshot(),
                            transport: logical, connection: .inbound(publisherUuid: target),
                            inboundPublisherLookupIdentity: owner.publicIdentitySnapshot()))
                        try await bridge.setTransport(logical, connection: .inbound(publisherUuid: target))
                        try bridge.activateAuthenticatedChannel()
                        state.addLogical(logical)
                        return bridge
                    }
                }
                state.install(raw, gate)
            } catch { XCTFail("N35 server setup failed: \(error)"); socket.close(code: .policyViolation, promise: nil) }
        }
        var clientGate: BridgeChannelTransport?
        do {
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/n35"))
            let endpoint = try BridgeChannelAuthentication.Endpoint(url: url, domain: "bridge", allowInsecureLoopback: true)
            state.configure(endpoint)
            let gate = try BridgeChannelTransport(underlying: VaporBridgeTransport(), endpoint: endpoint)
            clientGate = gate
            let mux = BridgeMultiplexSession(physicalTransport: gate)
            let a = try mux.channelTransport(targetEndpoint: "N35")
            let bridgeA = try await makeBridge(a, owner: owner, cell: cell)
            try await a.setup(url, identity: owner)
            let initial = try await bridgeA.get(keypath: "secret", requester: owner)
            XCTAssertEqual(initial, .string("signed-value"))
            let pending = Task { try await bridgeA.get(keypath: "held", requester: owner) }
            await fulfillment(of: [entered], timeout: 5)
            let bFinished = expectation(description: "B signed GET completed while A held")
            let b = try mux.channelTransport(targetEndpoint: "N35")
            let bridgeB = try await makeBridge(b, owner: owner, cell: cell)
            let sibling = Task {
                do {
                    try await b.setup(url, identity: owner)
                    let value = try await bridgeB.get(keypath: "secret", requester: owner)
                    XCTAssertEqual(value, .string("signed-value"))
                    bFinished.fulfill()
                } catch { XCTFail("N35 B progress failed: \(error)") }
            }
            let progress = await XCTWaiter.fulfillment(of: [bFinished], timeout: 5)
            XCTAssertEqual(progress, .completed, "N35 B must finish before releasing A")
            XCTAssertEqual(limits.connectionCount, 1, "A and B share one authenticated physical connection")
            let serverA = try XCTUnwrap(state.logicals.first)
            XCTAssertGreaterThanOrEqual(state.raw?.receiveSnapshot.count ?? 0, 1)
            XCTAssertGreaterThanOrEqual(limits.outstandingWorkCount, 1)
            let aID = try XCTUnwrap(a as? BridgeMultiplexChannelTransport).channelID
            let closeProbe = BridgeCommand(cmd: "get", identity: owner.publicIdentitySnapshot(),
                payload: .string("held"), cid: 999999, protocolVersion: 2, channelID: aID)
            XCTAssertNotNil(state.gate?.prepareMultiplexDispatch(closeProbe), "Live server A is routable")
            await a.close()
            // Observe the production routing table without dispatching more work.
            // This cannot retire A itself: only the real close frame does that.
            try await n35Eventually { state.gate?.prepareMultiplexDispatch(closeProbe) == nil }
            XCTAssertEqual(state.gate?.session.state, .authenticated)
            XCTAssertGreaterThanOrEqual(state.raw?.receiveSnapshot.count ?? 0, 1, "A executing receive stays charged after logical close")
            XCTAssertGreaterThanOrEqual(limits.outstandingWorkCount, 1, "A executing gate work stays charged after logical close")
            XCTAssertGreaterThan(state.raw?.receiveSnapshot.bytes ?? 0, 0, "Held payload bytes remain charged")
            await hold.release()
            await fulfillment(of: [returned], timeout: 5)
            do { _ = try await pending.value; XCTFail("N35 late A result must not complete retired client GET") } catch {}
            do {
                try await serverA.sendData(JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .string("late-A"), cid: 999998)))
                XCTFail("N35 retired server transport accepted late A result")
            } catch { XCTAssertEqual(error as? BridgeMultiplexError, .channelNotFound) }
            await sibling.value
            try await n35Eventually { state.raw?.receiveSnapshot.count == 0 && limits.outstandingWorkCount == 0 }
            let surviving = try await bridgeB.get(keypath: "secret", requester: owner)
            XCTAssertEqual(surviving, .string("signed-value"), "B survives A retirement and late result")
            let calls = await serverVault.calls; XCTAssertEqual(calls, 0)
            await b.close(); await gate.close(); await state.gate?.close()
            withExtendedLifetime(mux) {}
            await app.server.shutdown(); try await app.asyncShutdown()
        } catch {
            await hold.release(); await clientGate?.close(); await state.gate?.close()
            await app.server.shutdown(); try await app.asyncShutdown()
            throw error
        }
    }

    /// Three fresh authenticated sockets/keys repeat signed reads on both channels.
    /// The raw-frame phase separately proves queued order on both logical lanes.
    func testRepeatedTwoChannelOrderingAndOriginSigning() async throws {
        for _ in 0..<3 {
            try await testHeldProtectedAAllowsSignedBAndSelectiveCloseRetainsQuotaAndRejectsLateResult()
            let a = N35WireConsumer(), b = N35WireConsumer(), hold = N35WireBarrier()
            a.holdFirst = hold
            let fixture = try await N35WireSocket.make(muxConsumers: ["A": [a], "B": [b]])
            do {
                try await fixture.authenticate()
                try await fixture.openMuxChannel("A")
                try await fixture.openMuxChannel("B")
                _ = try await fixture.inject([fixture.muxFlow(0, channel: "A")])
                try await n35WireEventually { a.values == [0] }
                _ = try await fixture.inject([
                    fixture.muxFlow(1, channel: "A"), fixture.muxFlow(2, channel: "A"),
                    fixture.muxFlow(10, channel: "B"), fixture.muxFlow(11, channel: "B")
                ])
                try await n35WireEventually { b.values == [10, 11] }
                XCTAssertEqual(a.values, [0])
                XCTAssertGreaterThanOrEqual(fixture.transport.receiveSnapshot.count, 3)
                await hold.release()
                try await n35WireEventually { a.values == [0, 1, 2] && fixture.transport.receiveSnapshot.count == 0 }
                XCTAssertEqual(fixture.gate.session.state, .authenticated)
                await fixture.close()
            } catch { await hold.release(); await fixture.close(); throw error }
        }
    }

    private func makeBridge(_ transport: BridgeTransportProtocol, owner: Identity, cell: GeneralCell) async throws -> BridgeBase {
        let bridge = try await BridgeBase(.init(owner: owner, transport: transport, connection: .outbound,
            identityProofScopes: [.init(domain: cell.identityDomain, resource: cell.uuid)]))
        try await bridge.setTransport(transport, connection: .outbound)
        return bridge
    }
}

private actor N35Barrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private final class N35State: @unchecked Sendable {
    private let lock = NSLock()
    private var endpointValue: BridgeChannelAuthentication.Endpoint?
    private var rawValue: VaporBridgeTransport?
    private var gateValue: BridgeChannelTransport?
    private var logicalValues: [BridgeTransportProtocol] = []
    var raw: VaporBridgeTransport? { lock.withLock { rawValue } }
    var gate: BridgeChannelTransport? { lock.withLock { gateValue } }
    var logicals: [BridgeTransportProtocol] { lock.withLock { logicalValues } }
    func configure(_ endpoint: BridgeChannelAuthentication.Endpoint) { lock.withLock { endpointValue = endpoint } }
    func endpoint() throws -> BridgeChannelAuthentication.Endpoint { try lock.withLock { try XCTUnwrap(endpointValue) } }
    func install(_ raw: VaporBridgeTransport, _ gate: BridgeChannelTransport) { lock.withLock { rawValue = raw; gateValue = gate } }
    func addLogical(_ logical: BridgeTransportProtocol) { lock.withLock { logicalValues.append(logical) } }
}
private func n35Eventually(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    guard check() else { XCTFail("N35 event not observed before deadline", file: file, line: line); throw N35Error.timeout }
}
private enum N35Error: Error { case timeout }
private func n35WireEventually(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    guard check() else { XCTFail("Expected observed event before deadline", file: file, line: line); throw N35WireError.timeout }
}
private enum N35WireError: Error { case timeout }
private final class N35WireHeldSecuritySink: CellSecurityEventSink, @unchecked Sendable {
    let hold = N35WireBarrier(), entered = N35WireCounter()
    func record(_ event: CellSecurityEvent) async { entered.increment(); await hold.wait() }
}
private final class N35WireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private actor N35WireBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private final class N35WireConsumer: BridgeDelegateProtocol, @unchecked Sendable {
    let uuid = UUID().uuidString
    let signs = N35WireCounter(), otherResponses = N35WireCounter()
    let closes = N35WireCounter(), lateSendFailures = N35WireCounter()
    var replyAfterCommand = false
    var channelTransport: BridgeTransportProtocol?
    private let lock = NSLock()
    private var received: [Int] = []
    var holdFirst: N35WireBarrier?
    var values: [Int] { lock.withLock { received } }
    func consumeCommand(command: BridgeCommand) async throws {
        if command.command == .sign { signs.increment(); return }
        guard command.command == .get, case let .string(key)? = command.payload, let value = Int(key) else { return }
        await record(value)
        if replyAfterCommand, let channelTransport {
            do {
                try await channelTransport.sendData(JSONEncoder().encode(BridgeCommand(
                    cmd: "response", payload: .integer(value), cid: command.cid)))
            } catch { lateSendFailures.increment(); throw error }
        }
    }
    func consumeResponse(command: BridgeCommand) async throws {
        guard case .flowElement(let flow) = command.payload, let value = Int(flow.title ?? "") else { otherResponses.increment(); return }
        await record(value)
    }
    private func record(_ value: Int) async {
        let first = lock.withLock { received.append(value); return received.count == 1 }
        if first { await holdFirst?.wait() }
    }
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
    func pushError(errorMessage: String?, error: Error?) async { closes.increment() }
    func ready() async throws {}
}

private final class N35MuxTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [String: [N35WireConsumer]]
    init(_ consumers: [String: [N35WireConsumer]]) { self.consumers = consumers }
    func take(_ target: String) -> N35WireConsumer? {
        lock.withLock {
            guard var pending = consumers[target], !pending.isEmpty else { return nil }
            let result = pending.removeFirst()
            consumers[target] = pending
            return result
        }
    }
}

private final class N35WireSocket: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let listener: any Channel
    let peer: any Channel
    let channel: any Channel
    let transport: VaporBridgeTransport
    let gate: BridgeChannelTransport
    let consumer: N35WireConsumer
    let owner: Identity
    let physicalCloses: N35WireCounter
    let limits: BridgeChannelLimits
    let endpoint: BridgeChannelAuthentication.Endpoint
    private let closeLock = NSLock()
    private var closed = false

    private init(group: MultiThreadedEventLoopGroup, listener: any Channel, peer: any Channel, channel: any Channel,
                 transport: VaporBridgeTransport, gate: BridgeChannelTransport, consumer: N35WireConsumer, owner: Identity,
                 physicalCloses: N35WireCounter, limits: BridgeChannelLimits, endpoint: BridgeChannelAuthentication.Endpoint) {
        self.group = group; self.listener = listener; self.peer = peer; self.channel = channel
        self.transport = transport; self.gate = gate; self.consumer = consumer; self.owner = owner
        self.physicalCloses = physicalCloses; self.limits = limits; self.endpoint = endpoint
    }

    static func make(budget: VaporBridgeReceiveBudget? = nil, holdPhysicalClose: N35WireBarrier? = nil,
                     muxConsumers: [String: [N35WireConsumer]]? = nil) async throws -> N35WireSocket {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let consumer = N35WireConsumer(), closes = N35WireCounter(), limits = BridgeChannelLimits()
        let muxTargets = muxConsumers.map(N35MuxTargets.init)
        let clientVault = EphemeralIdentityVault()
        let identity = await clientVault.identity(for: UUID().uuidString, makeNewIfNotFound: true)
        let owner = try XCTUnwrap(identity)
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: "wss://n35-wire.example/bridge")!, domain: "bridge")
        let result = group.next().makePromise(of: (any Channel, VaporBridgeTransport, BridgeChannelTransport).self)
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(WebSocketFrameEncoder()).flatMap {
                WebSocket.server(on: channel) { socket in
                    let close: @Sendable () async -> Void = {
                        closes.increment()
                        await holdPhysicalClose?.wait()
                        try? await channel.close().get()
                    }
                    let transport: VaporBridgeTransport
                    if let budget {
                        transport = VaporBridgeTransport(webSocket: socket, receiveBudget: budget, closeUnderlyingChannel: close)
                    } else {
                        transport = VaporBridgeTransport(webSocket: socket, closeUnderlyingChannel: close)
                    }
                    do {
                        let gate = try BridgeChannelTransport(underlying: transport, endpoint: endpoint, limits: limits, source: "loopback") { transport, _ in
                            guard let muxTargets else { return consumer }
                            return BridgeMultiplexServerSession(physicalTransport: transport) { target, _, channel in
                                guard let consumer = muxTargets.take(target) else { throw BridgeMultiplexError.invalidChannel }
                                consumer.channelTransport = channel
                                return consumer
                            }
                        }
                        result.succeed((channel, transport, gate))
                    } catch { result.fail(error) }
                }
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let peer = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: listener.localAddress!.port!).get()
        let (channel, transport, gate) = try await result.futureResult.get()
        return .init(group: group, listener: listener, peer: peer, channel: channel, transport: transport,
                     gate: gate, consumer: consumer, owner: owner, physicalCloses: closes, limits: limits, endpoint: endpoint)
    }

    func authenticate() async throws {
        let operation = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint)
        let challenge = try gate.session.issueChallenge(operation.hello)
        let proof = try await operation.sign(challenge)
        let data = try BridgeChannelAuthentication.encode(BridgeCommand(cmd: "channelAuthProof",
            payload: .string(String(decoding: BridgeChannelAuthentication.encode(proof), as: UTF8.self)), cid: 0))
        _ = try await inject([data])
        try await n35WireEventually { self.gate.session.state == .authenticated && self.transport.receiveSnapshot.count == 0 }
    }

    func openMuxChannel(_ id: String) async throws {
        let retained = transport.receiveSnapshot.count
        _ = try await inject([JSONEncoder().encode(BridgeCommand(cmd: "openChannel",
            identity: owner.publicIdentitySnapshot(), payload: nil, cid: 1,
            protocolVersion: 2, channelID: id, targetEndpoint: id))])
        try await n35WireEventually { self.transport.receiveSnapshot.count <= retained }
        XCTAssertEqual(gate.session.state, .authenticated)
    }

    func muxCommand(_ command: String, channel: String, value: Int = 0) throws -> Data {
        try JSONEncoder().encode(BridgeCommand(cmd: command, identity: owner.publicIdentitySnapshot(),
            payload: command == "get" ? .string(String(value)) : nil, cid: 10 + value,
            protocolVersion: 2, channelID: channel))
    }

    func muxFlow(_ value: Int, channel: String) throws -> Data {
        var command = try JSONDecoder().decode(BridgeCommand.self, from: Self.flow(value))
        command.protocolVersion = 2; command.channelID = channel
        return try JSONEncoder().encode(command)
    }

    @discardableResult
    func inject(_ data: [Data], binary: Bool? = nil) async throws -> (count: Int, bytes: Int, stopped: Bool) {
        try await channel.eventLoop.submit { [self] in
            for (index, bytes) in data.enumerated() {
                let frame = WebSocketFrame(fin: true, opcode: (binary ?? index.isMultiple(of: 2)) ? .binary : .text,
                    data: channel.allocator.buffer(bytes: bytes))
                channel.pipeline.fireChannelRead(NIOAny(frame))
            }
            return transport.receiveSnapshot
        }.get()
    }

    static func flow(_ value: Int) throws -> Data {
        try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .flowElement(
            FlowElement(title: String(value), content: .string(String(value)), properties: .init(type: .event, contentType: .string))), cid: 42))
    }
    func waitForClose() async throws { try await n35WireEventually { !self.channel.isActive } }
    func close() async {
        guard closeLock.withLock({ if closed { return false }; closed = true; return true }) else { return }
        await gate.close(); await transport.close()
        try? await channel.close().get(); try? await peer.close().get(); try? await listener.close().get()
        try? await group.shutdownGracefully()
    }
}
#endif
