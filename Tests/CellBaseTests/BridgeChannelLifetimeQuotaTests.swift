// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class BridgeChannelLifetimeQuotaTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private func endpoint() throws -> A.Endpoint {
        try .init(url: URL(string: "wss://quota.example/bridgehead/Quota/client")!, domain: "bridge")
    }
    private func owner() async -> Identity { await MockIdentityVault().identity(for: UUID().uuidString, makeNewIfNotFound: true)! }
    private func auth(_ name: String, _ payload: some Encodable) throws -> BridgeCommand {
        .init(cmd: name, payload: .string(String(decoding: try A.encode(payload), as: UTF8.self)), cid: 0)
    }
    private func proof(_ server: BridgeChannelTransport, owner: Identity) async throws -> BridgeCommand {
        let client = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint())
        // The gate validates and consumes the exact challenge held by this connection.
        let challenge = try server.session.issueChallenge(client.hello)
        return try auth("channelAuthProof", await client.sign(challenge))
    }
    private func ready(_ limits: BridgeChannelLimits, cell: GeneralCell, wire: QuotaWire = QuotaWire()) async throws -> (BridgeChannelTransport, Identity, QuotaWire) {
        let identity = await owner()
        let server = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: UUID().uuidString) { transport, _ in
            let bridge = BridgeBase(owner: identity)
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Quota"))
            return bridge
        }
        try await server.consumeCommand(command: proof(server, owner: identity))
        return (server, identity, wire)
    }
    private func get(_ server: BridgeChannelTransport, _ identity: Identity) async throws {
        try await server.consumeCommand(command: .init(cmd: "get", identity: identity, payload: .string("value"), cid: 1))
    }

    func testDisconnectRetainsPolicyAndFactoryAdmissionUntilNoncooperativeWorkReturns() async throws {
        for stage in ["policy", "factory"] {
            var config = BridgeChannelLimits.Configuration(); config.maximumPending = 2
            let limits = BridgeChannelLimits(configuration: config)
            let previous = CellBase.defaultCellResolver; defer { CellBase.defaultCellResolver = previous }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            let cell = await QuotaCell(owner: owner())
            try await resolver.registerNamedEmitCell(name: "Quota", emitCell: cell, scope: .template, identity: cell.owner)
            let healthy = try await ready(limits, cell: cell)
            var workers: [(Task<Void, Error>, QuotaBarrier)] = []
            for index in 0..<2 {
                let identity = await owner(), barrier = QuotaBarrier()
                let entered = expectation(description: "\(stage) \(index)")
                let wire = QuotaWire()
                let server = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: "source-\(index)",
                    recheckPolicy: { _ in if stage == "policy" { entered.fulfill(); await barrier.wait() } }) { _, _ in
                        if stage == "factory" { entered.fulfill(); await barrier.wait() }
                        return BridgeBase(owner: identity)
                    }
                let command = try await proof(server, owner: identity)
                let task = Task { try await server.consumeCommand(command: command) }
                await fulfillment(of: [entered], timeout: 2)
                await server.close()
                XCTAssertEqual(limits.outstandingWorkCount, index + 1, stage)
                XCTAssertEqual(limits.retainedConnectionCount, index + 2, stage)
                workers.append((task, barrier))
                try await get(healthy.0, healthy.1)
            }
            XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "next-key"), stage)
            XCTAssertEqual(limits.connectionCount, 1)
            for (task, barrier) in workers {
                await barrier.resume()
                do { try await task.value; XCTFail("Retired admission succeeded") } catch {}
            }
            XCTAssertEqual(limits.retainedConnectionCount, 1)
            XCTAssertEqual(limits.outstandingWorkCount, 0)
            let next = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "recovered"); next.close()
            try await get(healthy.0, healthy.1)
            await healthy.0.close()
            XCTAssertEqual(limits.retainedConnectionCount, 0)
        }
    }

    func testManyKeysCannotEscapeGlobalCellFeedChannelAndSendLimitsByDisconnecting() async throws {
        for stage in ["cell", "feed", "channelFactory", "send"] {
            var config = BridgeChannelLimits.Configuration()
            config.maximumOperations = 8; config.maximumFeeds = 8; config.maximumChannels = 8
            let response = try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .string("value"), cid: 1))
            // Leave room for handshakes; use a separate send-only test below for exact byte saturation.
            let limits = BridgeChannelLimits(configuration: config)
            let previous = CellBase.defaultCellResolver; defer { CellBase.defaultCellResolver = previous }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            let cell = await QuotaCell(owner: owner())
            try await resolver.registerNamedEmitCell(name: "Quota", emitCell: cell, scope: .template, identity: cell.owner)
            let healthy = try await ready(limits, cell: cell)
            var workers: [(Task<Void, Error>, QuotaBarrier)] = []
            let reached = QuotaCount()
            for index in 0..<9 {
                let barrier = QuotaBarrier(), entered = XCTestExpectation(description: "\(stage) \(index)")
                let identity = await owner(), wire = QuotaWire()
                let server = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: UUID().uuidString) { transport, _ in
                    if stage == "channelFactory" {
                        return BridgeMultiplexServerSession(physicalTransport: transport) { _, _, _ in
                            reached.increment(); entered.fulfill(); await barrier.wait()
                            return BridgeBase(owner: identity)
                        }
                    }
                    let bridge = BridgeBase(owner: identity)
                    try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Quota"))
                    return bridge
                }
                try await server.consumeCommand(command: proof(server, owner: identity))
                let suspend: @Sendable () async -> Void = { reached.increment(); entered.fulfill(); await barrier.wait() }
                cell.beforeRead = stage == "cell" ? suspend : nil
                cell.beforeFeed = stage == "feed" ? suspend : nil
                if stage == "send" { wire.beforeSend = { data in if data == response { await suspend() } } }
                let name = stage == "feed" ? "feed" : stage == "channelFactory" ? "openChannel" : "get"
                let command = BridgeCommand(cmd: name, identity: identity, payload: .string("value"), cid: 1,
                    protocolVersion: name == "openChannel" ? 2 : nil, channelID: name == "openChannel" ? UUID().uuidString : nil,
                    targetEndpoint: name == "openChannel" ? "Quota" : nil)
                let task = Task { try await server.consumeCommand(command: command) }
                if index < 8 {
                    await fulfillment(of: [entered], timeout: 2)
                    await server.close()
                    workers.append((task, barrier))
                    // An independent client still works with one retained slow worker.
                    if index == 0 {
                        cell.beforeRead = nil; cell.beforeFeed = nil
                        try await get(healthy.0, healthy.1)
                    }
                } else {
                    _ = try? await task.value
                    XCTAssertEqual(reached.value, 8, stage)
                    await server.close()
                }
            }
            cell.beforeRead = nil; cell.beforeFeed = nil
            XCTAssertEqual(limits.retainedConnectionCount, 9, stage)
            for (task, barrier) in workers {
                await barrier.resume(); _ = try? await task.value
                let cancelled = await barrier.sawCancellation
                XCTAssertTrue(cancelled, "Cancellation reached the non-cooperative \(stage) worker")
            }
            XCTAssertEqual(limits.retainedConnectionCount, 1, stage)
            XCTAssertEqual(limits.outstandingWorkCount, 0, stage)
            try await get(healthy.0, healthy.1)
            await healthy.0.close()
            XCTAssertEqual(limits.retainedConnectionCount, 0, stage)
        }
    }

    func testHangingPhysicalSendRetainsGlobalBytesAfterDisconnectAndReleasesOnlyOnReturn() async throws {
        var config = BridgeChannelLimits.Configuration()
        config.maximumPendingSendBytesPerConnection = 64 * 1024
        config.maximumPendingSendBytes = 4 * config.maximumPendingSendBytesPerConnection
        let limits = BridgeChannelLimits(configuration: config)
        let cell = await QuotaCell(owner: owner())
        let a = try await ready(limits, cell: cell), b = try await ready(limits, cell: cell)
        let spare = try await ready(limits, cell: cell)
        let entered = expectation(description: "physical send"), barrier = QuotaBarrier()
        a.2.beforeSend = { _ in entered.fulfill(); await barrier.wait() }
        let bytes = Data(repeating: 32, count: limits.configuration.maximumPendingSendBytesPerConnection)
        let sending = Task { try await a.0.sendData(bytes) }
        await fulfillment(of: [entered], timeout: 2)
        await a.0.close()
        XCTAssertEqual(limits.retainedConnectionCount, 3)
        // All retained bytes still consume the shared budget, even though A is closed.
        try b.0.session.acquireSend(bytes: bytes.count)
        var others: [BridgeChannelSession] = []
        for _ in 0..<2 {
            let pair = try await ready(limits, cell: cell)
            try pair.0.session.acquireSend(bytes: bytes.count)
            others.append(pair.0.session)
            // Keep transport alive until after release.
            retainedGates.append(pair.0)
        }
        XCTAssertThrowsError(try spare.0.session.acquireSend(bytes: 1))
        await barrier.resume(); _ = try? await sending.value
        XCTAssertEqual(limits.retainedConnectionCount, 4)
        try spare.0.session.acquireSend(bytes: 1); spare.0.session.releaseSend(bytes: 1)
        await spare.0.close()
        b.0.session.releaseSend(bytes: bytes.count)
        try b.0.session.acquireSend(bytes: 1); b.0.session.releaseSend(bytes: 1)
        for other in others { other.releaseSend(bytes: bytes.count) }
        for gate in retainedGates { await gate.close() }; retainedGates = []
        await b.0.close(); XCTAssertEqual(limits.retainedConnectionCount, 0)
    }
    func testPhysicalCloseRetainsConnectionReservationUntilAdapterReturns() async throws {
        var config = BridgeChannelLimits.Configuration(); config.maximumConnections = 1
        let limits = BridgeChannelLimits(configuration: config), cell = await QuotaCell(owner: owner())
        let pair = try await ready(limits, cell: cell), barrier = QuotaBarrier()
        let entered = expectation(description: "physical close")
        pair.2.beforeClose = { entered.fulfill(); await barrier.wait() }
        let closing = Task { await pair.0.close() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(limits.connectionCount, 0)
        XCTAssertEqual(limits.retainedConnectionCount, 1)
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "next"))
        await barrier.resume(); await closing.value
        XCTAssertEqual(limits.retainedConnectionCount, 0)
        let next = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "next"); next.close()
    }

    func testWallExpiryDuringAwaitedPhysicalSendFailsAndReleasesBytesOnReturn() async throws {
        let identity = await owner(), wire = QuotaWire(), clock = QuotaClock(), limits = BridgeChannelLimits()
        let gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: "one",
            wallClock: { clock.now }) { transport, _ in
                let bridge = BridgeBase(owner: identity)
                try await bridge.setTransport(transport, connection: .outbound)
                return bridge
            }
        try await gate.consumeCommand(command: proof(gate, owner: identity))
        let entered = expectation(description: "send in progress"), barrier = QuotaBarrier()
        wire.beforeSend = { _ in entered.fulfill(); await barrier.wait() }
        let sending = Task { try await gate.sendData(Data([1])) }
        await fulfillment(of: [entered], timeout: 2)
        clock.advance(301)
        await barrier.resume()
        do { try await sending.value; XCTFail("Expired send reported success") }
        catch { XCTAssertEqual(error as? A.Failure, .expired) }
        XCTAssertEqual(limits.outstandingWorkCount, 0)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
    }

    private var retainedGates: [BridgeChannelTransport] = []
}

private final class QuotaCell: GeneralCell {
    var beforeRead: (@Sendable () async -> Void)?
    var beforeFeed: (@Sendable () async -> Void)?
    override func get(keypath: String, requester: Identity) async throws -> ValueType { await beforeRead?(); return .string("value") }
    override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> { await beforeFeed?(); return getFeedPublisher() }
}
private final class QuotaWire: BridgeTransportProtocol, @unchecked Sendable {
    var beforeSend: (@Sendable (Data) async -> Void)?
    var beforeClose: (@Sendable () async -> Void)?
    static func new() -> BridgeTransportProtocol { QuotaWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) {}
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws { await beforeSend?(data) }
    func close() async { await beforeClose?() }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
private actor QuotaBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var sawCancellation = false
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
        sawCancellation = Task.isCancelled
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
private final class QuotaCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class QuotaClock: @unchecked Sendable {
    private let lock = NSLock(); private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
