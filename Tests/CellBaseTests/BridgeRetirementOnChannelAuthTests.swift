// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@preconcurrency import Combine
@testable import CellBase

/// Design choices made when the loopback lifecycle (terminal retirement,
/// owned work, bounded registries) was ported onto main's channel-authenticated
/// bridge (one shared recursive lifecycle lock, per-generation checks).
final class BridgeRetirementOnChannelAuthTests: XCTestCase {
    private final class CountingWire: BridgeTransportProtocol, @unchecked Sendable {
        var channelSession: BridgeChannelSession?
        private let lock = NSLock()
        private var closes = 0
        private var sent: [BridgeCommand] = []
        var hold: BridgeLifecycleBarrier?
        var holdCommand: Command?
        var closeCount: Int { lock.withLock { closes } }
        var commands: [BridgeCommand] { lock.withLock { sent } }
        static func new() -> BridgeTransportProtocol { CountingWire() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) {}
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { sent.append(command) }
            if let hold, command.command == holdCommand { await hold.hold() }
        }
        func close() async {
            lock.withLock { closes += 1 }
            channelSession?.close()
        }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    }

    private func authenticatedBridge(owner: Identity) async throws -> (BridgeBase, CountingWire) {
        let wire = CountingWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let bridge = try await BridgeBase(.init(owner: owner, transport: wire, connection: .outbound))
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        return (bridge, wire)
    }

    private func owner(_ name: String = "owner") async -> Identity {
        let vault = MockIdentityVault()
        return await vault.identity(for: name, makeNewIfNotFound: true)!
    }

    // Choice: retirement owns fire-and-forget bridge work. finishRetirement
    // closes physical I/O first, then joins held owned work before it returns.
    func testRetirementUnderLoadJoinsHeldOwnedSendAndRefusesNewWork() async throws {
        let owner = await owner()
        let (bridge, wire) = try await authenticatedBridge(owner: owner)
        let barrier = BridgeLifecycleBarrier()
        wire.hold = barrier; wire.holdCommand = .dropFlow
        bridge.dropFlow(label: "held", requester: owner)
        await fulfillment(of: [barrier.entered], timeout: 2)

        let finished = expectation(description: "retirement joined")
        let retirement = Task { await bridge.finishRetirement(); finished.fulfill() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(bridge.isRetired, "retirement is decided synchronously")
        XCTAssertFalse(bridge.isFullyRetired, "held owned work keeps retirement open")
        XCTAssertEqual(wire.closeCount, 1, "physical close precedes the join")
        do {
            _ = try await bridge.get(keypath: "after", requester: owner)
            XCTFail("retired bridge must refuse new operations")
        } catch {}
        bridge.dropAllFlows(requester: owner) // refused by retired work registry; no frame
        await barrier.release()
        await fulfillment(of: [finished], timeout: 2)
        await retirement.value
        XCTAssertTrue(bridge.isFullyRetired)
        XCTAssertEqual(wire.commands.filter { $0.command == .unsubscribeAll }.count, 0)
        XCTAssertEqual(wire.closeCount, 1, "physical close is shared, not repeated")
        await bridge.finishRetirement()
        XCTAssertEqual(wire.closeCount, 1)
    }

    // Choice: retirement is expressed through main's generation model. The
    // pending operation fails, a late response for its cid is refused, and no
    // new authenticated generation (renewal path) can be installed afterwards.
    func testGenerationChecksStayClosedAfterRetirement() async throws {
        let owner = await owner()
        let (bridge, wire) = try await authenticatedBridge(owner: owner)
        let pending = Task { try await bridge.get(keypath: "value", requester: owner) }
        let deadline = Date().addingTimeInterval(2)
        while wire.commands.isEmpty, Date() < deadline { await Task.yield() }
        let cid = try XCTUnwrap(wire.commands.first { $0.command == .get }?.cid)

        bridge.requestRetirement()
        do { _ = try await pending.value; XCTFail("pending get must fail on retirement") } catch {}
        do {
            try await bridge.consumeResponse(command: BridgeCommand(cmd: "response", identity: owner,
                payload: .string("late"), cid: cid))
            XCTFail("late response for a retired generation must be refused")
        } catch {}
        do { try await bridge.ready(timeout: 1); XCTFail("ready after retirement") } catch {}
        XCTAssertThrowsError(try bridge.activateAuthenticatedChannel())

        let renewal = CountingWire()
        renewal.channelSession = try await authenticatedSessionFixture(principal: owner)
        do {
            try await bridge.setTransport(renewal, connection: .outbound)
            XCTFail("retired bridge must not accept a new generation")
        } catch {}
        XCTAssertEqual(renewal.closeCount, 1, "refused proposal is closed by the refusal")
        XCTAssertEqual(bridge.callbackRegistrySnapshot.count, 0)
        await bridge.finishRetirement()
    }

    // Choice: close(requester:) keeps main's non-terminal meaning (a later
    // authenticated generation may be installed). Retirement is separate.
    func testCloseKeepsMainsRenewableContractWhileRetirementIsTerminal() async throws {
        let owner = await owner()
        let (bridge, _) = try await authenticatedBridge(owner: owner)
        bridge.close(requester: owner)
        XCTAssertFalse(bridge.isRetired)
        let next = CountingWire()
        next.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(next, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        try await bridge.ready(timeout: 1)
        XCTAssertTrue(bridge.hasAuthenticatedChannel)
        await bridge.finishRetirement()
        XCTAssertEqual(next.closeCount, 1)
    }

    // Choice: main's replaceable-transport contract is kept for a live bridge
    // (generation proven afterwards); only retirement closes the door.
    func testLiveBridgeKeepsMainsReplaceableTransportUntilRetired() async throws {
        let owner = await owner()
        let (bridge, wire) = try await authenticatedBridge(owner: owner)
        let replacement = CountingWire()
        try await bridge.setTransport(replacement, connection: .outbound)
        XCTAssertTrue((bridge.transport as AnyObject?) === replacement)
        XCTAssertFalse(bridge.hasAuthenticatedChannel, "replacement is unproven until authenticated")
        XCTAssertEqual(replacement.closeCount, 0)
        bridge.requestRetirement()
        let late = CountingWire()
        do { try await bridge.setTransport(late, connection: .outbound); XCTFail("retired bridge accepted a transport") } catch {}
        XCTAssertEqual(late.closeCount, 1)
        await bridge.finishRetirement()
        XCTAssertEqual(replacement.closeCount, 1, "finalizer closes the transport it owns")
        XCTAssertEqual(wire.closeCount, 0, "a replaced transport is not the finalizer's")
    }

    // Choice: CurrentValueSubject keeps a readiness signal that lands between
    // the locked check and the subscription in ready(timeout:).
    func testReadySignalBetweenCheckAndSubscriptionIsRetained() async throws {
        let owner = await owner()
        let wire = CountingWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let bridge = try await BridgeBase(.init(owner: owner, transport: wire, connection: .outbound))
        try await bridge.setTransport(wire, connection: .outbound)
        bridge.beforeReadySubscription = { try? bridge.activateAuthenticatedChannel() }
        try await bridge.ready(timeout: 1)
        await bridge.finishRetirement()
    }

    // Choice: every reply/callback registry shares one aggregate budget, and a
    // refused registration precedes any wire frame.
    func testCallbackBudgetRefusesBeforeSending() async throws {
        let owner = await owner()
        let (bridge, wire) = try await authenticatedBridge(owner: owner)
        for i in 0..<BridgeBase.maximumCallbackRecords { XCTAssertTrue(bridge.storeConnectPromise({ _ in }, for: 10_000 + i)) }
        XCTAssertFalse(bridge.storeContractPromise({ _ in }, for: 99_999))
        do { _ = try await bridge.get(keypath: "x", requester: owner); XCTFail("get admitted over budget") } catch {}
        do { _ = try await bridge.set(keypath: "x", value: .string("x"), requester: owner); XCTFail("set admitted over budget") } catch {}
        let admitted = await bridge.admit(context: .init(source: nil, target: nil, identity: owner))
        XCTAssertEqual(admitted, .notConnected)
        XCTAssertTrue(wire.commands.isEmpty, "refusal must precede sending")
        bridge.requestRetirement()
        XCTAssertEqual(bridge.callbackRegistrySnapshot.count, 0, "retirement releases every registry")
        XCTAssertFalse(bridge.storeConnectPromise({ _ in }, for: 1), "retired registries reject late insertion")
        await bridge.finishRetirement()
    }

    private final class PoolPhysical: BridgeTransportProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var closes = 0
        var closeCount: Int { lock.withLock { closes } }
        static func new() -> BridgeTransportProtocol { PoolPhysical() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) {}
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func sendData(_ data: Data) async throws {}
        func close() async { lock.withLock { closes += 1 } }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    }

    private func poolKey(_ n: Int) throws -> BridgeConnectionPoolKey {
        BridgeConnectionPoolKey(sessionEndpoint: try XCTUnwrap(URL(string: "wss://bridge.example/session")),
                                identityUUID: "fixture-\(n)", signingKeyFingerprint: "fixture-key-\(n)",
                                homeVaultReference: "fixture-vault-\(n)")
    }

    // Choice: main's LRU eviction stays the default. Retired (evicted)
    // sessions leave the pool at once and never count against the limit.
    func testFullPoolDefaultEvictsAndRetiredSessionsDoNotCount() async throws {
        let pool = BridgeConnectionPool(maximumSessions: 2)
        XCTAssertEqual(pool.capacityPolicy, .evictLeastRecentlyUsed)
        var physicals: [PoolPhysical] = []
        var channels: [BridgeTransportProtocol] = []
        for n in 0..<5 {
            let physical = PoolPhysical(); physicals.append(physical)
            channels.append(try pool.channelTransport(for: try poolKey(n), targetEndpoint: "Cell") { physical })
            XCTAssertLessThanOrEqual(pool.sessionCount(), 2)
        }
        XCTAssertEqual(pool.sessionCount(), 2)
        XCTAssertEqual(physicals[0].closeCount, 0, "evicted session stays open while its channel is live")
        await channels[0].close()
        XCTAssertEqual(physicals[0].closeCount, 1, "evicted session closes after its last channel")
        for channel in channels.dropFirst() { await channel.close() }
    }

    // Choice: the loopback behaviour is an explicit opt-in. A full pool refuses
    // with resourceLimitExceeded while a session is not fully closed, and
    // admits again once the last channel's physical close has returned.
    func testFullPoolRejectPolicyChargesUntilPhysicalCloseReturns() async throws {
        let pool = BridgeConnectionPool(maximumSessions: 1, capacityPolicy: .rejectUntilPhysicallyClosed)
        let first = PoolPhysical()
        let channel = try pool.channelTransport(for: try poolKey(1), targetEndpoint: "Cell") { first }
        XCTAssertThrowsError(try pool.channelTransport(for: try poolKey(2), targetEndpoint: "Cell") { PoolPhysical() }) {
            XCTAssertEqual($0 as? BridgeMultiplexError, .resourceLimitExceeded)
        }
        await channel.close()
        XCTAssertEqual(first.closeCount, 1)
        let next = try pool.channelTransport(for: try poolKey(2), targetEndpoint: "Cell") { PoolPhysical() }
        XCTAssertEqual(pool.sessionCount(), 1)
        await next.close()
    }

    // An invalid target fails before any physical transport is built.
    func testInvalidPoolTargetFailsBeforePhysicalFactory() throws {
        let pool = BridgeConnectionPool()
        var built = 0
        XCTAssertThrowsError(try pool.channelTransport(for: try poolKey(1), targetEndpoint: "") { built += 1; return PoolPhysical() }) {
            XCTAssertEqual($0 as? BridgeMultiplexError, .invalidChannel)
        }
        XCTAssertEqual(built, 0)
    }
    // Choice: closing a server-side logical channel is terminal for its
    // BridgeBase delegate, but closers keep main's contract (#53): they return
    // without joining non-cooperative work. Capacity stays charged by main's
    // in-flight send reservation, and closeAndJoin() is the explicit owner join.
    func testServerChannelCloseRetiresDelegateAndJoinIsExplicit() async throws {
        let owner = await owner()
        let wire = CountingWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let barrier = BridgeLifecycleBarrier()
        let bridges = BridgeBox()
        let session = BridgeMultiplexServerSession(physicalTransport: wire, maximumChannels: 1) { _, principal, transport in
            let bridge = BridgeBase(owner: principal)
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Target"))
            try bridge.activateAuthenticatedChannel()
            bridges.add(bridge)
            return bridge
        }
        func frame(_ kind: Command, _ id: String) -> BridgeCommand {
            BridgeCommand(cmd: kind.rawValue, identity: owner.publicIdentitySnapshot(), payload: nil, cid: 1,
                          protocolVersion: 2, channelID: id, targetEndpoint: kind == .openChannel ? "cell://localhost/Target" : nil)
        }
        try await session.consumeCommand(command: frame(.openChannel, "first"))
        XCTAssertEqual(wire.commands.filter { $0.command == .channelOpened }.count, 1)
        let bridge = try XCTUnwrap(bridges.first)
        wire.hold = barrier; wire.holdCommand = .dropFlow
        bridge.dropFlow(label: "held", requester: owner)
        await fulfillment(of: [barrier.entered], timeout: 2)

        // Both closers return while the delegate's send is still held.
        try await session.consumeCommand(command: frame(.closeChannel, "first"))
        try await session.consumeCommand(command: frame(.closeChannel, "first"))
        XCTAssertTrue(bridge.isRetired, "logical close retires the delegate")
        XCTAssertFalse(bridge.isFullyRetired, "held owned work is still running")
        try await session.consumeCommand(command: frame(.openChannel, "next"))
        XCTAssertEqual(wire.commands.filter { $0.command == .channelRejected && $0.channelID == "next" }.count, 1,
                       "the held physical send keeps main's channel reservation")

        let joined = expectation(description: "closeAndJoin returns after held work")
        let join = Task { await session.closeAndJoin(); joined.fulfill() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(bridge.isFullyRetired)
        await barrier.release()
        await fulfillment(of: [joined], timeout: 2)
        await join.value
        XCTAssertTrue(bridge.isFullyRetired, "explicit join retires the actual delegate")
        XCTAssertEqual(wire.closeCount, 1)
    }

    // Capacity becomes reusable once the retired channel's work has returned.
    func testServerChannelCapacityReturnsAfterRetirementCompletes() async throws {
        let owner = await owner()
        let wire = CountingWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let session = BridgeMultiplexServerSession(physicalTransport: wire, maximumChannels: 1) { _, principal, transport in
            let bridge = BridgeBase(owner: principal)
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Target"))
            try bridge.activateAuthenticatedChannel()
            return bridge
        }
        func frame(_ kind: Command, _ id: String) -> BridgeCommand {
            BridgeCommand(cmd: kind.rawValue, identity: owner.publicIdentitySnapshot(), payload: nil, cid: 1,
                          protocolVersion: 2, channelID: id, targetEndpoint: kind == .openChannel ? "cell://localhost/Target" : nil)
        }
        try await session.consumeCommand(command: frame(.openChannel, "a"))
        try await session.consumeCommand(command: frame(.closeChannel, "a"))
        let deadline = Date().addingTimeInterval(2)
        var opened = false
        while !opened, Date() < deadline {
            try await session.consumeCommand(command: frame(.openChannel, "b-\(UUID().uuidString.prefix(8))"))
            opened = wire.commands.contains { $0.command == .channelOpened && $0.channelID?.hasPrefix("b-") == true }
            if !opened { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(opened, "capacity is reusable after the retirement completes")
        await session.closeAndJoin()
    }

    // Session close is one completion shared by every caller.
    func testServerSessionCloseIsSharedByAllCallers() async throws {
        let owner = await owner()
        let wire = CountingWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let session = BridgeMultiplexServerSession(physicalTransport: wire) { _, principal, _ in BridgeBase(owner: principal) }
        async let a: Void = session.close()
        async let b: Void = session.close()
        _ = await (a, b)
        XCTAssertEqual(wire.closeCount, 1)
    }

    // Choice: the loopback Object wire format is opt-in. The default keeps
    // main's bytes (peers unchanged); explicitEntries tags lost variants.
    func testObjectWireFormatDefaultKeepsMainBytesAndExplicitIsOptIn() throws {
        let previous = CellBase.objectWireFormat
        defer { CellBase.objectWireFormat = previous }
        XCTAssertEqual(previous, .legacyInference)
        let value = ValueType.object(["blob": .data(Data([0xCA, 0xFE])), "name": .string("n")])
        let legacy = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("&objectEntries"))
        CellBase.objectWireFormat = .explicitEntries
        let explicit = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: explicit, as: UTF8.self).contains("&objectEntries"))
        guard case let .object(decoded) = try JSONDecoder().decode(ValueType.self, from: explicit),
              case .data(let data)? = decoded["blob"] else { return XCTFail("explicit roundtrip keeps .data") }
        XCTAssertEqual(data, Data([0xCA, 0xFE]))
        CellBase.objectWireFormat = .legacyInference
        XCTAssertEqual(try JSONEncoder().encode(value), legacy, "default restores main's encoding")
    }

    private final class BridgeBox: @unchecked Sendable {
        private let lock = NSLock(); private var values: [BridgeBase] = []
        func add(_ b: BridgeBase) { lock.withLock { values.append(b) } }
        var first: BridgeBase? { lock.withLock { values.first } }
        var all: [BridgeBase] { lock.withLock { values } }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}
