// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if canImport(CellVapor)
import XCTest
import WebSocketKit
import NIOCore
import NIOPosix
import NIOWebSocket
@testable import CellBase
@testable import CellVapor

/// Inject frames at WebSocketKit's real aggregator/handler on a live NIO socket.
/// One event-loop turn makes admission assertions independent of Task scheduling.
/// The existing BridgeChannelWebSocketTests additionally cover HTTP upgrade/wire.
final class VaporWebSocketAdmissionTests: XCTestCase {
    func testCheckedFutureAwaitPreservesImmediateEventLoopErrorsAndCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock { try await group.shutdownGracefully() }
        let loop = group.next()
        let immediate = try await loop.makeSucceededFuture(41).n30CheckedGet()
        XCTAssertEqual(immediate, 41)
        for value in 0..<64 {
            let promise = loop.makePromise(of: Int.self)
            loop.execute { promise.succeed(value) }
            let received = try await promise.futureResult.n30CheckedGet()
            XCTAssertEqual(received, value)
        }
        do {
            let failed: EventLoopFuture<Int> = loop.makeFailedFuture(N30Error.timeout)
            _ = try await failed.n30CheckedGet()
            XCTFail("Future failure must remain a thrown error")
        } catch {
            guard case N30Error.timeout = error else {
                XCTFail("Expected the original N30 timeout error, got \(error)")
                return
            }
        }
        // Like NIO get(), task cancellation does not cancel the underlying future.
        let promise = loop.makePromise(of: Int.self)
        let waiting = Task { try await promise.futureResult.n30CheckedGet() }
        waiting.cancel()
        loop.execute { promise.succeed(73) }
        let received = try await waiting.value
        XCTAssertEqual(received, 73)
    }

    private func make(budget: VaporBridgeReceiveBudget? = nil, holdPhysicalClose: N30Barrier? = nil) async throws -> N30Socket {
        let socket = try await N30Socket.make(budget: budget, holdPhysicalClose: holdPhysicalClose)
        addTeardownBlock { await socket.close() }
        return socket
    }

    func testMuxHeldOperationAllowsSiblingAndSelectiveCloseOnSameSocket() async throws {
        let a = N30Consumer(), replacement = N30Consumer(), b = N30Consumer(), hold = N30Barrier()
        a.holdFirst = hold
        a.replyAfterCommand = true
        let fixture = try await N30Socket.make(muxConsumers: ["A": [a, replacement], "B": [b]])
        addTeardownBlock { await hold.release(); await fixture.close() }
        try await fixture.authenticate()
        try await fixture.openMuxChannel("A")
        try await fixture.openMuxChannel("B")
        _ = try await fixture.inject([fixture.muxCommand("get", channel: "A", value: 0)])
        try await n30Eventually { a.values == [0] }
        _ = try await fixture.inject([
            fixture.muxCommand("get", channel: "A", value: 1),
            fixture.muxCommand("get", channel: "B", value: 2),
            fixture.muxCommand("closeChannel", channel: "A")
        ])
        // Both assertions must succeed BEFORE releasing the non-cooperative A.
        try await n30Eventually { b.values == [2] && a.closes.value == 1 }
        XCTAssertEqual(a.values, [0], "Queued A work must not run after retirement")
        XCTAssertGreaterThanOrEqual(fixture.transport.receiveSnapshot.count, 1)
        XCTAssertGreaterThanOrEqual(fixture.limits.outstandingWorkCount, 1,
                                    "Closing a channel must retain its executing work quota")
        XCTAssertEqual(fixture.gate.session.state, .authenticated)
        try await fixture.openMuxChannel("A")
        _ = try await fixture.inject([fixture.muxCommand("get", channel: "A", value: 5)])
        try await n30Eventually { replacement.values == [5] }
        await hold.release()
        try await n30Eventually { fixture.transport.receiveSnapshot.count == 0 }
        XCTAssertEqual(replacement.values, [5], "Queued old A must not reach the reused wire ID")
        XCTAssertEqual(a.lateSendFailures.value, 1, "Retired A cannot publish its late result")
        XCTAssertEqual(a.values, [0])
        _ = try await fixture.inject([fixture.muxCommand("get", channel: "B", value: 3)])
        try await n30Eventually { b.values == [2, 3] }
        XCTAssertEqual(fixture.gate.session.state, .authenticated,
                       "A's cancelled consumer must not close B's physical session")
    }

    func testMuxFlowOrderIsLocalToItsChannelOnSameSocket() async throws {
        let a = N30Consumer(), b = N30Consumer(), hold = N30Barrier()
        a.holdFirst = hold
        let fixture = try await N30Socket.make(muxConsumers: ["A": [a], "B": [b]])
        addTeardownBlock { await hold.release(); await fixture.close() }
        try await fixture.authenticate()
        try await fixture.openMuxChannel("A")
        try await fixture.openMuxChannel("B")
        _ = try await fixture.inject([fixture.muxFlow(0, channel: "A")])
        try await n30Eventually { a.values == [0] }
        _ = try await fixture.inject([
            fixture.muxFlow(1, channel: "A"), fixture.muxFlow(2, channel: "A"),
            fixture.muxFlow(10, channel: "B"), fixture.muxFlow(11, channel: "B")
        ])
        try await n30Eventually { b.values == [10, 11] }
        XCTAssertEqual(a.values, [0])
        XCTAssertGreaterThanOrEqual(fixture.transport.receiveSnapshot.count, 3)
        await hold.release()
        try await n30Eventually { a.values == [0, 1, 2] && fixture.transport.receiveSnapshot.count == 0 }
        XCTAssertEqual(fixture.gate.session.state, .authenticated)
    }

    func testPreProofBurstIsAdmittedBeforeTasksAndQuotaPlusOneClosesOnlyOffender() async throws {
        let budget = VaporBridgeReceiveBudget()
        let fixture = try await make(budget: budget)
        let sibling = try await make(budget: budget)
        let hold = N30Barrier()
        addTeardownBlock { await hold.release() }
        fixture.transport.beforeReceivePreparation = { await hold.wait() }
        let data = try N30Socket.flow(0)
        let usage = try await fixture.inject(Array(repeating: data, count: 64))
        XCTAssertEqual(usage.count, 64)
        XCTAssertEqual(usage.bytes, 64 * data.count)
        XCTAssertFalse(usage.stopped)
        XCTAssertEqual(fixture.gate.session.state, .unauthenticated)
        XCTAssertEqual(fixture.consumer.values, [])
        let rejected = try await fixture.inject(Array(repeating: data, count: 2000))
        XCTAssertTrue(rejected.stopped)
        XCTAssertEqual(rejected.count, 64, "No Tasks/copies/reservations for rejected frames")
        XCTAssertEqual(fixture.gate.session.state, .closed, "Revocation is synchronous")
        try await fixture.waitForClose()
        XCTAssertEqual(fixture.physicalCloses.value, 1)
        XCTAssertEqual(budget.snapshot.count, 64, "Held work stays charged after physical close")
        await hold.release()
        try await n30Eventually { budget.snapshot.count == 0 }
        XCTAssertEqual(fixture.consumer.values, [])
        try await sibling.authenticate()
        _ = try await sibling.inject([N30Socket.flow(99)])
        try await n30Eventually { sibling.consumer.values == [99] }
        await fixture.close(); await sibling.close()
    }

    func testAuthenticatedFeedOrderSurvivesHeldFirstDispatchAndMixedTextBinaryBurst() async throws {
        let fixture = try await make()
        try await fixture.authenticate()
        let hold = N30Barrier()
        addTeardownBlock { await hold.release() }
        fixture.consumer.holdFirst = hold
        _ = try await fixture.inject([N30Socket.flow(0)])
        try await n30Eventually { fixture.consumer.values == [0] }
        let usage = try await fixture.inject((1..<64).map { try N30Socket.flow($0) })
        XCTAssertEqual(usage.count, 64)
        XCTAssertEqual(fixture.consumer.values, [0])
        await hold.release()
        try await n30Eventually { fixture.consumer.values.count == 64 }
        XCTAssertEqual(fixture.consumer.values, Array(0..<64))
        try await n30Eventually { fixture.transport.receiveSnapshot.count == 0 }
        await fixture.close()
    }

    func testOnlySigningControlPassesHeldDispatchAndMalformedFrameFailsClosed() async throws {
        let fixture = try await make()
        try await fixture.authenticate()
        let hold = N30Barrier()
        addTeardownBlock { await hold.release() }
        fixture.consumer.holdFirst = hold
        _ = try await fixture.inject([N30Socket.flow(0)])
        try await n30Eventually { fixture.consumer.values == [0] }
        let sign = try JSONEncoder().encode(BridgeCommand(cmd: "sign", identity: fixture.owner.publicIdentitySnapshot(), payload: nil, cid: 900))
        let fakeReply = try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .string("signature-shaped-but-unregistered"), cid: 901))
        _ = try await fixture.inject([N30Socket.flow(1), fakeReply, sign])
        try await n30Eventually { fixture.consumer.signs.value == 1 }
        XCTAssertEqual(fixture.consumer.values, [0])
        XCTAssertEqual(fixture.consumer.otherResponses.value, 0)
        _ = try await fixture.inject([Data("{".utf8)])
        try await fixture.waitForClose()
        XCTAssertEqual(fixture.gate.session.state, .closed)
        await hold.release()
        try await n30Eventually { fixture.transport.receiveSnapshot.count == 0 }
        XCTAssertEqual(fixture.consumer.values, [0])
        XCTAssertEqual(fixture.consumer.otherResponses.value, 0)
        await fixture.close()
    }

    func testAuthenticatedQuotaPlusOneKeepsInFlightChargeUntilConsumerReturns() async throws {
        let budget = VaporBridgeReceiveBudget()
        let fixture = try await make(budget: budget)
        try await fixture.authenticate()
        let hold = N30Barrier()
        addTeardownBlock { await hold.release() }
        fixture.consumer.holdFirst = hold
        let data = try N30Socket.flow(0)
        _ = try await fixture.inject([data])
        try await n30Eventually { fixture.consumer.values == [0] }
        _ = try await fixture.inject(Array(repeating: data, count: 64))
        try await fixture.waitForClose()
        XCTAssertGreaterThanOrEqual(budget.snapshot.count, 1)
        XCTAssertGreaterThanOrEqual(budget.snapshot.bytes, data.count)
        XCTAssertEqual(fixture.consumer.values, [0])
        await hold.release()
        try await n30Eventually { budget.snapshot.count == 0 }
        XCTAssertEqual(budget.snapshot.bytes, 0)
        await fixture.close()
    }

    func testLargeTextAndBinaryFramesAndConnectionByteQuotaRejectBeforePreparation() async throws {
        for oversized in [true, false] {
            for binary in [false, true] {
                let fixture = try await make()
                let hold = N30Barrier(), prepared = N30Counter()
                addTeardownBlock { await hold.release() }
                fixture.transport.beforeReceivePreparation = { prepared.increment(); await hold.wait() }
                let size = BridgeInboundPayloadValidator.defaultMaximumBytes
                let data = Data(repeating: 0x20, count: oversized ? size + 1 : size)
                let usage = try await fixture.inject(Array(repeating: data, count: oversized ? 1 : 4), binary: binary)
                XCTAssertEqual(usage.count, oversized ? 0 : 4)
                XCTAssertEqual(usage.bytes, oversized ? 0 : 4 * size)
                if !oversized {
                    XCTAssertFalse(usage.stopped)
                    try await n30Eventually { prepared.value == 1 }
                    _ = try await fixture.inject([Data([0x20])], binary: binary)
                }
                try await fixture.waitForClose()
                XCTAssertEqual(prepared.value, oversized ? 0 : 1)
                XCTAssertEqual(fixture.gate.session.state, .closed)
                await hold.release()
                try await n30Eventually { fixture.transport.receiveSnapshot.count == 0 }
                await fixture.close()
            }
        }
    }

    func testConcurrentCloseRetainsGateSlotUntilOwnedPhysicalCloseReturns() async throws {
        let hold = N30Barrier()
        let fixture = try await make(holdPhysicalClose: hold)
        addTeardownBlock { await hold.release() }
        try await fixture.authenticate()
        let first = Task { await fixture.transport.close() }
        try await n30Eventually { fixture.physicalCloses.value == 1 }
        let secondFinished = expectation(description: "second physical close caller returned")
        let second = Task { await fixture.transport.close(); secondFinished.fulfill() }
        // Trigger the real socket-close observer as well as simultaneous callers.
        fixture.transport.handleWebSocketClose(.success(()))
        XCTAssertEqual(fixture.gate.session.state, .closed)
        XCTAssertEqual(fixture.limits.retainedConnectionCount, 1)
        let early = await XCTWaiter.fulfillment(of: [secondFinished], timeout: 0.05)
        XCTAssertEqual(early, .timedOut, "No close caller may return before physical retirement")
        await hold.release()
        await first.value; await second.value
        try await n30Eventually { fixture.limits.retainedConnectionCount == 0 }
        XCTAssertEqual(fixture.physicalCloses.value, 1)
    }

    func testRejectedPayloadRetainsAdmissionUntilSecurityAuditReturns() async throws {
        let previous = CellBase.securityEventSink
        defer { CellBase.securityEventSink = previous }
        let budget = VaporBridgeReceiveBudget(), sink = N30HeldSecuritySink()
        let fixture = try await make(budget: budget)
        addTeardownBlock { await sink.hold.release() }
        try await fixture.authenticate()
        CellBase.securityEventSink = sink
        _ = try await fixture.inject([Data("{".utf8)])
        try await n30Eventually { sink.entered.value == 1 }
        try await fixture.waitForClose()
        XCTAssertEqual(budget.snapshot.count, 1)
        XCTAssertEqual(budget.snapshot.bytes, 1)
        await sink.hold.release()
        try await n30Eventually { budget.snapshot.count == 0 }
        XCTAssertEqual(budget.snapshot.bytes, 0)
    }

    func testConcurrentCloseRetainsGateSlotUntilResolverCleanupReturns() async throws {
        let previous = CellBase.defaultCellResolver
        defer { CellBase.defaultCellResolver = previous }
        let resolver = MockCellResolver(), entered = N30Counter(), hold = N30Barrier()
        resolver.beforeUnregister = { entered.increment(); await hold.wait() }
        CellBase.defaultCellResolver = resolver
        let fixture = try await make()
        addTeardownBlock { await hold.release() }
        try await fixture.authenticate()
        let first = Task { await fixture.transport.close() }
        try await n30Eventually { entered.value == 1 }
        let secondFinished = expectation(description: "resolver cleanup returned")
        let second = Task { await fixture.transport.close(); secondFinished.fulfill() }
        try await fixture.waitForClose()
        let early = await XCTWaiter.fulfillment(of: [secondFinished], timeout: 0.05)
        XCTAssertEqual(early, .timedOut)
        XCTAssertEqual(fixture.limits.retainedConnectionCount, 1)
        await hold.release()
        await first.value; await second.value
        try await n30Eventually { fixture.limits.retainedConnectionCount == 0 }
        XCTAssertEqual(entered.value, 1)
        XCTAssertEqual(resolver.unregisteredUUIDsSnapshot(), [fixture.gate.uuid])
    }

    func testDefaultAdaptersUseTheSameProcessWideBudget() async throws {
        let baseline = VaporBridgeReceiveBudget.shared.snapshot
        let a = try await make(), b = try await make()
        let hold = N30Barrier()
        addTeardownBlock { await hold.release() }
        a.transport.beforeReceivePreparation = { await hold.wait() }
        b.transport.beforeReceivePreparation = { await hold.wait() }
        let data = try N30Socket.flow(1)
        _ = try await a.inject([data])
        _ = try await b.inject([data])
        XCTAssertEqual(VaporBridgeReceiveBudget.shared.snapshot.count, baseline.count + 2)
        XCTAssertEqual(VaporBridgeReceiveBudget.shared.snapshot.bytes, baseline.bytes + 2 * data.count)
        await hold.release()
        try await n30Eventually { a.transport.receiveSnapshot.count == 0 && b.transport.receiveSnapshot.count == 0 }
        XCTAssertEqual(VaporBridgeReceiveBudget.shared.snapshot.count, baseline.count)
        XCTAssertEqual(VaporBridgeReceiveBudget.shared.snapshot.bytes, baseline.bytes)
    }

    func testGlobalCountAndByteBudgetsSpanConnectionsAndReleaseForFreshSibling() async throws {
        let data = try N30Socket.flow(1)
        for byteLimited in [false, true] {
            // Inject the same production ledger with smaller limits so each
            // exact boundary is exercised without opening hundreds of sockets.
            let budget = VaporBridgeReceiveBudget(maximumCount: byteLimited ? 100 : 3,
                maximumBytes: byteLimited ? 3 * data.count : 1024 * 1024)
            let a = try await make(budget: budget)
            let b = try await make(budget: budget)
            let offender = try await make(budget: budget)
            let hold = N30Barrier()
            addTeardownBlock { await hold.release() }
            a.transport.beforeReceivePreparation = { await hold.wait() }
            b.transport.beforeReceivePreparation = { await hold.wait() }
            _ = try await a.inject([data, data])
            _ = try await b.inject([data])
            XCTAssertEqual(budget.snapshot.count, 3)
            XCTAssertEqual(budget.snapshot.bytes, 3 * data.count)
            let rejected = try await offender.inject([data])
            XCTAssertTrue(rejected.stopped)
            XCTAssertEqual(rejected.count, 0)
            XCTAssertFalse(a.transport.receiveSnapshot.stopped)
            XCTAssertFalse(b.transport.receiveSnapshot.stopped)
            await hold.release()
            try await n30Eventually { budget.snapshot.count == 0 }
            let fresh = try await make(budget: budget)
            try await fresh.authenticate()
            _ = try await fresh.inject([data])
            try await n30Eventually { fresh.consumer.values == [1] }
            await a.close(); await b.close(); await offender.close(); await fresh.close()
            XCTAssertEqual(budget.snapshot.count, 0)
            XCTAssertEqual(budget.snapshot.bytes, 0)
        }
    }
}

// Keep the fixture's real NIO callbacks and Sendable requirement, with runtime
// exactly-once checks at the async boundary. Do not suppress sanitizer findings
// or alter the production transport's Future.get() path.
private extension EventLoopFuture where Value: Sendable {
    func n30CheckedGet() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.whenComplete { result in continuation.resume(with: result) }
        }
    }
}

private func n30Eventually(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    guard check() else { XCTFail("Expected observed event before deadline", file: file, line: line); throw N30Error.timeout }
}
private enum N30Error: Error { case timeout }
private final class N30HeldSecuritySink: CellSecurityEventSink, @unchecked Sendable {
    let hold = N30Barrier(), entered = N30Counter()
    func record(_ event: CellSecurityEvent) async { entered.increment(); await hold.wait() }
}
private final class N30Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private actor N30Barrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private final class N30Consumer: BridgeDelegateProtocol, @unchecked Sendable {
    let uuid = UUID().uuidString
    let signs = N30Counter(), otherResponses = N30Counter()
    let closes = N30Counter(), lateSendFailures = N30Counter()
    var replyAfterCommand = false
    var channelTransport: BridgeTransportProtocol?
    private let lock = NSLock()
    private var received: [Int] = []
    var holdFirst: N30Barrier?
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
    private var consumers: [String: [N30Consumer]]
    init(_ consumers: [String: [N30Consumer]]) { self.consumers = consumers }
    func take(_ target: String) -> N30Consumer? {
        lock.withLock {
            guard var pending = consumers[target], !pending.isEmpty else { return nil }
            let result = pending.removeFirst()
            consumers[target] = pending
            return result
        }
    }
}

private final class N30Socket: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let listener: any Channel
    let peer: any Channel
    let channel: any Channel
    let transport: VaporBridgeTransport
    let gate: BridgeChannelTransport
    let consumer: N30Consumer
    let owner: Identity
    let physicalCloses: N30Counter
    let limits: BridgeChannelLimits
    let endpoint: BridgeChannelAuthentication.Endpoint
    private let closeLock = NSLock()
    private var closed = false

    private init(group: MultiThreadedEventLoopGroup, listener: any Channel, peer: any Channel, channel: any Channel,
                 transport: VaporBridgeTransport, gate: BridgeChannelTransport, consumer: N30Consumer, owner: Identity,
                 physicalCloses: N30Counter, limits: BridgeChannelLimits, endpoint: BridgeChannelAuthentication.Endpoint) {
        self.group = group; self.listener = listener; self.peer = peer; self.channel = channel
        self.transport = transport; self.gate = gate; self.consumer = consumer; self.owner = owner
        self.physicalCloses = physicalCloses; self.limits = limits; self.endpoint = endpoint
    }

    static func make(budget: VaporBridgeReceiveBudget? = nil, holdPhysicalClose: N30Barrier? = nil,
                     muxConsumers: [String: [N30Consumer]]? = nil) async throws -> N30Socket {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result = group.next().makePromise(of: (any Channel, VaporBridgeTransport, BridgeChannelTransport).self)
        let consumer = N30Consumer(), closes = N30Counter(), limits = BridgeChannelLimits()
        let muxTargets = muxConsumers.map(N35MuxTargets.init)
        let owner = await MockIdentityVault().identity(for: UUID().uuidString, makeNewIfNotFound: true)!
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: "wss://n30.example/bridge")!, domain: "bridge")
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(WebSocketFrameEncoder()).flatMap {
                WebSocket.server(on: channel) { socket in
                    let close: @Sendable () async -> Void = {
                        closes.increment()
                        await holdPhysicalClose?.wait()
                        try? await channel.close().n30CheckedGet()
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
        }.bind(host: "127.0.0.1", port: 0).n30CheckedGet()
        let peer = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: listener.localAddress!.port!).n30CheckedGet()
        let (channel, transport, gate) = try await result.futureResult.n30CheckedGet()
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
        try await n30Eventually { self.gate.session.state == .authenticated && self.transport.receiveSnapshot.count == 0 }
    }

    func openMuxChannel(_ id: String) async throws {
        let retained = transport.receiveSnapshot.count
        _ = try await inject([JSONEncoder().encode(BridgeCommand(cmd: "openChannel",
            identity: owner.publicIdentitySnapshot(), payload: nil, cid: 1,
            protocolVersion: 2, channelID: id, targetEndpoint: id))])
        try await n30Eventually { self.transport.receiveSnapshot.count <= retained }
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
        }.n30CheckedGet()
    }

    static func flow(_ value: Int) throws -> Data {
        try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .flowElement(
            FlowElement(title: String(value), content: .string(String(value)), properties: .init(type: .event, contentType: .string))), cid: 42))
    }
    func waitForClose() async throws { try await n30Eventually { !self.channel.isActive } }
    func close() async {
        guard closeLock.withLock({ if closed { return false }; closed = true; return true }) else { return }
        await gate.close(); await transport.close()
        try? await channel.close().n30CheckedGet(); try? await peer.close().n30CheckedGet(); try? await listener.close().n30CheckedGet()
        try? await group.shutdownGracefully()
    }
}
#endif
