// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

/// Hooks run before physical acceptance; the lock also makes assertions useful
/// under TSAN. Replies can be delivered while sendData is still on the stack.
final class BridgeOrderingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [BridgeCommand] = []
    private var callback: (@Sendable (BridgeCommand) async throws -> Void)?
    var beforeSend: (@Sendable (BridgeCommand) async throws -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    var commands: [BridgeCommand] { lock.withLock { frames } }
    func submit(_ command: BridgeCommand) async throws {
        try await beforeSend?(command)
        lock.withLock { frames.append(command) }
    }
}

final class BridgeOrderingFeedCell: GeneralCell {
    let values = PassthroughSubject<FlowElement, Error>()
    var finite = false
    override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        if finite { return [Self.value(1), Self.value(2)].publisher.setFailureType(to: Error.self).eraseToAnyPublisher() }
        return values.eraseToAnyPublisher()
    }
    static func value(_ n: Int) -> FlowElement {
        FlowElement(title: String(n), content: .string(String(n)), properties: .init(type: .event, contentType: .string))
    }
}

func orderingEventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    XCTAssertTrue(condition(), file: file, line: line)
}

func exerciseOrderedFeed(bridge: BridgeBase, cell: BridgeOrderingFeedCell, requester: Identity,
                         probe: BridgeOrderingProbe,
                         submit: (BridgeCommand) async throws -> Void) async throws {
    let hold = BridgeLifecycleBarrier()
    probe.beforeSend = { command in
        if case let .flowElement(value) = command.payload, value.title == "1" { await hold.hold() }
    }
    try await submit(.init(cmd: "feed", identity: requester, payload: nil, cid: 100))
    cell.values.send(BridgeOrderingFeedCell.value(1))
    await XCTWaiter.fulfillment(of: [hold.entered], timeout: 2)
    cell.values.send(BridgeOrderingFeedCell.value(2))
    cell.values.send(completion: .finished)
    XCTAssertTrue(bridge.feedActive, "Completion must retain the admitted feed while send 1 is held")
    XCTAssertEqual(bridge.pendingFeedDeliveries, 2)
    XCTAssertFalse(probe.commands.contains { if case .flowElement? = $0.payload { return true }; return false })
    await hold.release()
    await orderingEventually { bridge.pendingFeedDeliveries == 0 && !bridge.feedActive }
    let values = probe.commands.compactMap { command -> String? in
        if case let .flowElement(value) = command.payload { return value.title }; return nil
    }
    XCTAssertEqual(values, ["1", "2"])

    // Completion during sink installation (a truly synchronous finite publisher).
    probe.beforeSend = nil
    cell.finite = true
    try await submit(.init(cmd: "feed", identity: requester, payload: nil, cid: 101))
    await orderingEventually { bridge.pendingFeedDeliveries == 0 && !bridge.feedActive }
    XCTAssertEqual(probe.commands.filter { $0.cid == 101 }.compactMap {
        if case let .flowElement(value) = $0.payload { return value.title }; return nil
    }, ["1", "2"])
}

func orderingReply(to command: BridgeCommand, payload: ValueType) -> BridgeCommand {
    BridgeCommand(cmd: "response", payload: payload, cid: command.cid,
                  protocolVersion: command.protocolVersion, channelID: command.channelID)
}

func exerciseRPCOwnership(bridge: BridgeBase, requester: Identity, probe: BridgeOrderingProbe,
                          reply: @escaping @Sendable (BridgeCommand) async throws -> Void) async throws {
    bridge.rpcReplyTimeoutSeconds = 2
    probe.beforeSend = { command in
        switch command.command {
        case .set:
            guard case let .keyValue(value) = command.payload else { return }
            try await reply(orderingReply(to: command, payload: .setValueResponse(.init(state: .ok, value: value.value))))
        case .description:
            try await reply(orderingReply(to: command, payload: .description(AnyCell(uuid: "early", name: "early",
                contractTemplate: Agreement(owner: requester), identityDomain: "ordering"))))
        default: break
        }
    }
    let early = try await bridge.set(keypath: "same", value: .string("early"), requester: requester)
    XCTAssertEqual(early, .string("early"))
    try await bridge.retrieveProxyRepresentation(for: requester)
    XCTAssertEqual(bridge.uuid, "early")
    XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)
    probe.beforeSend = nil
    let start = probe.commands.count
    let first = Task { try await bridge.set(keypath: "same", value: .integer(1), requester: requester) }
    await orderingEventually { probe.commands.count == start + 1 }
    let second = Task { try await bridge.set(keypath: "same", value: .integer(2), requester: requester) }
    await orderingEventually { probe.commands.count == start + 2 }
    let requests = Array(probe.commands.suffix(2))
    try await reply(orderingReply(to: requests[1], payload: .setValueResponse(.init(state: .ok, value: .string("second-result")))))
    try await reply(orderingReply(to: requests[0], payload: .setValueResponse(.init(state: .ok, value: .string("first-result")))))
    let a = try await first.value, b = try await second.value
    XCTAssertEqual(a, .string("first-result")); XCTAssertEqual(b, .string("second-result"))

    // Timeout cleanup and a late response must not steal a second same-path waiter.
    bridge.rpcReplyTimeoutSeconds = 1
    let oldCount = probe.commands.count
    let expired = Task { try await bridge.set(keypath: "same", value: .integer(3), requester: requester) }
    await orderingEventually { probe.commands.count == oldCount + 1 }
    bridge.rpcReplyTimeoutSeconds = 3
    let live = Task { try await bridge.set(keypath: "same", value: .integer(4), requester: requester) }
    await orderingEventually { probe.commands.count == oldCount + 2 }
    let pending = Array(probe.commands.suffix(2))
    do { _ = try await expired.value; XCTFail("Missing response should time out") } catch {}
    XCTAssertNil(bridge.auditor.loadBridgeCommandForCommandId(pending[0].cid))
    XCTAssertNotNil(bridge.auditor.loadBridgeCommandForCommandId(pending[1].cid))
    try await reply(orderingReply(to: pending[0], payload: .setValueResponse(.init(state: .ok, value: .string("late")))))
    try await reply(orderingReply(to: pending[1], payload: .setValueResponse(.init(state: .ok, value: .string("live")))))
    let result = try await live.value
    XCTAssertEqual(result, .string("live"))
    XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)

    // Concurrent descriptions are cid-owned too: an invalid first response must
    // not complete the other waiter via a shared notification subject.
    let count = probe.commands.count
    let bad = Task { try await bridge.retrieveProxyRepresentation(for: requester) }
    await orderingEventually { probe.commands.count == count + 1 }
    let good = Task { try await bridge.retrieveProxyRepresentation(for: requester) }
    await orderingEventually { probe.commands.count == count + 2 }
    let descriptions = Array(probe.commands.suffix(2))
    try await reply(orderingReply(to: descriptions[1], payload: .description(AnyCell(uuid: "fresh", name: "fresh", contractTemplate: Agreement(owner: requester), identityDomain: "fresh"))))
    try await reply(orderingReply(to: descriptions[0], payload: .string("invalid")))
    try await good.value
    do { try await bad.value; XCTFail("Malformed description succeeded") } catch {}
    XCTAssertEqual(bridge.uuid, "fresh")
    XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)
}

final class BridgeFeedAndRPCOrderingTests: XCTestCase {
    func testWSFeedPreservesOrderDrainsCompletionAndSynchronousPublisher() async throws {
        let owner = await MockIdentityVault().identity(for: "ordering", makeNewIfNotFound: true)!
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        wire.beforeAccept = { try await probe.submit($0) }
        try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
        let cell = await BridgeOrderingFeedCell(owner: owner); bridge.emitCellAtEndpoint = cell
        try await exerciseOrderedFeed(bridge: bridge, cell: cell, requester: owner, probe: probe) { try await bridge.consumeCommand(command: $0) }
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }

    func testWSSetAndDescriptionOwnCIDAndPreserveImmediateRepliesAndTimeoutIsolation() async throws {
        let owner = await MockIdentityVault().identity(for: "ordering", makeNewIfNotFound: true)!
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        wire.beforeAccept = { try await probe.submit($0) }
        try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
        try await exerciseRPCOwnership(bridge: bridge, requester: owner, probe: probe) { try await bridge.consumeResponse(command: $0) }
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }

    func testMuxSetAndDescriptionOwnCIDAndPreserveImmediateRepliesAndTimeoutIsolation() async throws {
        let owner = await MockIdentityVault().identity(for: "ordering", makeNewIfNotFound: true)!
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let mux = BridgeMultiplexSession(physicalTransport: wire)
        wire.beforeAccept = { command in
            if command.command == .openChannel {
                try await mux.consumeCommand(command: .init(cmd: "channelOpened", payload: nil, cid: command.cid, protocolVersion: 2, channelID: command.channelID))
            } else { try await probe.submit(command) }
        }
        let logical = try mux.channelTransport(targetEndpoint: "cell:///ordering")
        try await bridge.setTransport(logical, connection: .outbound)
        try await logical.setup(URL(string: "wss://fixture.example/mux")!, identity: owner)
        try await exerciseRPCOwnership(bridge: bridge, requester: owner, probe: probe) { try await mux.consumeResponse(command: $0) }
        await logical.close()
    }

    func testMuxFeedPreservesOrderDrainsCompletionAndSynchronousPublisher() async throws {
        let owner = await MockIdentityVault().identity(for: "ordering", makeNewIfNotFound: true)!
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        wire.beforeAccept = { try await probe.submit($0) }
        let cell = await BridgeOrderingFeedCell(owner: owner)
        let mux = BridgeMultiplexServerSession(physicalTransport: wire) { _, _, logical in
            try await bridge.setTransport(logical, connection: .outbound)
            bridge.emitCellAtEndpoint = cell
            try bridge.activateAuthenticatedChannel()
            return bridge
        }
        try await mux.consumeCommand(command: .init(cmd: "openChannel", identity: owner,
            payload: nil, cid: 1, protocolVersion: 2, channelID: "feed", targetEndpoint: "cell:///ordering"))
        try await exerciseOrderedFeed(bridge: bridge, cell: cell, requester: owner, probe: probe) { command in
            var command = command; command.protocolVersion = 2; command.channelID = "feed"
            try await mux.consumeCommand(command: command)
        }
        let sequences = probe.commands.filter { $0.cid == 100 }.compactMap(\.sequence)
        XCTAssertEqual(sequences, [1, 2])
        await mux.pushError(errorMessage: nil, error: BridgeChannelAuthentication.Failure.closed)
    }
}


extension BridgeFeedAndRPCOrderingTests {
    func testFeedOverflowExplicitlyFailsQueueAndRetainsInFlightQuotaUntilReturn() async throws {
        let owner = await MockIdentityVault().identity(for: "bounds", makeNewIfNotFound: true)!
        var config = BridgeChannelLimits.Configuration()
        config.maximumOperationsPerKey = 2
        config.maximumFeedsPerKey = 1
        config.maximumPendingSendBytesPerConnection = 4096
        let limits = BridgeChannelLimits(configuration: config), wire = BridgeLifecycleWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner, limits: limits)
        let bridge = BridgeBase(owner: owner), cell = await BridgeOrderingFeedCell(owner: owner)
        try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        let hold = BridgeLifecycleBarrier()
        wire.beforeAccept = { if case .flowElement? = $0.payload { await hold.hold() } }
        try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 8))
        cell.values.send(BridgeOrderingFeedCell.value(1))
        await fulfillment(of: [hold.entered], timeout: 2)
        cell.values.send(BridgeOrderingFeedCell.value(2))
        XCTAssertEqual(bridge.pendingFeedDeliveries, 2)
        cell.values.send(BridgeOrderingFeedCell.value(3))
        await orderingEventually { wire.channelSession?.state == .closed }
        XCTAssertFalse(bridge.feedActive)
        XCTAssertEqual(bridge.pendingFeedDeliveries, 1, "Queued values fail on overflow; the physical send retains its lease")
        XCTAssertEqual(limits.retainedConnectionCount, 1)
        await hold.release()
        await orderingEventually { bridge.pendingFeedDeliveries == 0 && limits.retainedConnectionCount == 0 }
        XCTAssertEqual(wire.commands.filter { if case .flowElement? = $0.payload { return true }; return false }.count, 1)
    }

    func testSetAndDescriptionRetirementCannotCompleteOrRemoveReplacementWaiter() async throws {
        let owner = await MockIdentityVault().identity(for: "generation", makeNewIfNotFound: true)!
        for (kind, explicitClose) in [(Command.set, false), (.description, false), (.set, true), (.description, true)] {
            let bridge = BridgeBase(owner: owner), oldWire = BridgeLifecycleWire(), hold = BridgeLifecycleBarrier()
            bridge.rpcReplyTimeoutSeconds = 3
            oldWire.channelSession = try await authenticatedSessionFixture(principal: owner)
            try await bridge.setTransport(oldWire, connection: .outbound); try bridge.activateAuthenticatedChannel()
            func request() async throws -> ValueType? {
                if kind == .set { return try await bridge.set(keypath: "same", value: .string("value"), requester: owner) }
                try await bridge.retrieveProxyRepresentation(for: owner)
                return .string(bridge.uuid)
            }
            func payload(_ text: String) -> ValueType {
                if kind == .set { return .setValueResponse(.init(state: .ok, value: .string(text))) }
                return .description(AnyCell(uuid: text, name: text, contractTemplate: Agreement(owner: owner), identityDomain: text))
            }
            let old = Task { try await request() }
            await orderingEventually { oldWire.commands.count == 1 }
            let oldCommand = try XCTUnwrap(oldWire.commands.last)
            bridge.afterResponseLookup = { if $0.cid == oldCommand.cid { await hold.hold() } }
            let stale = Task { try await bridge.consumeResponse(command: orderingReply(to: oldCommand, payload: payload("old"))) }
            await fulfillment(of: [hold.entered], timeout: 2)
            if explicitClose { bridge.close(requester: owner) }
            else { await bridge.channelDidClose(try XCTUnwrap(oldWire.channelSession)) }
            // Leave the old caller's cleanup free to overlap replacement setup.
            let freshWire = BridgeLifecycleWire()
            freshWire.channelSession = try await authenticatedSessionFixture(principal: owner)
            try await bridge.setTransport(freshWire, connection: .outbound); try bridge.activateAuthenticatedChannel()
            let fresh = Task { try await request() }
            await orderingEventually { freshWire.commands.count == 1 }
            let freshCommand = try XCTUnwrap(freshWire.commands.last)
            do { _ = try await old.value; XCTFail("Retired request succeeded") } catch {}
            await hold.release()
            do { try await stale.value; XCTFail("Old response admitted") } catch {}
            XCTAssertNotNil(bridge.auditor.loadBridgeCommandForCommandId(freshCommand.cid))
            try await bridge.consumeResponse(command: orderingReply(to: freshCommand, payload: payload("fresh")))
            let result = try await fresh.value
            XCTAssertEqual(result, .string("fresh"))
            XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)
            await bridge.channelDidClose(try XCTUnwrap(freshWire.channelSession))
        }
    }
}


extension BridgeFeedAndRPCOrderingTests {
    func testFeedTerminalFailureAndSendFailureExplicitlyFailRemainder() async throws {
        for failSend in [false, true] {
            let owner = await MockIdentityVault().identity(for: "failure", makeNewIfNotFound: true)!
            let limits = BridgeChannelLimits(), wire = BridgeLifecycleWire(), hold = BridgeLifecycleBarrier()
            wire.channelSession = try await authenticatedSessionFixture(principal: owner, limits: limits)
            let bridge = BridgeBase(owner: owner), cell = await BridgeOrderingFeedCell(owner: owner)
            try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
            bridge.emitCellAtEndpoint = cell
            wire.beforeAccept = { command in
                if case let .flowElement(value) = command.payload, value.title == "1" {
                    await hold.hold()
                    if failSend { throw BridgeChannelAuthentication.Failure.closed }
                }
            }
            try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 9))
            cell.values.send(BridgeOrderingFeedCell.value(1))
            await fulfillment(of: [hold.entered], timeout: 2)
            cell.values.send(BridgeOrderingFeedCell.value(2))
            cell.values.send(completion: .failure(BridgeChannelAuthentication.Failure.unavailable))
            XCTAssertEqual(bridge.pendingFeedDeliveries, 1)
            XCTAssertFalse(bridge.feedActive, "Upstream failure may be authorization revocation")
            await hold.release()
            await orderingEventually { bridge.pendingFeedDeliveries == 0 && wire.channelSession?.state == .closed }
            XCTAssertEqual(wire.commands.count, failSend ? 0 : 1)
            // The final send releases its value before the next drain iteration
            // retires the feed lease. Observe retirement, not that earlier count.
            await orderingEventually { limits.retainedConnectionCount == 0 }
            XCTAssertEqual(limits.retainedConnectionCount, 0)
        }
    }

    func testFeedQueueChargesByteBudgetBeforePhysicalSubmission() async throws {
        let owner = await MockIdentityVault().identity(for: "bytes", makeNewIfNotFound: true)!
        var config = BridgeChannelLimits.Configuration(); config.maximumPendingSendBytesPerConnection = 1024
        let limits = BridgeChannelLimits(configuration: config), wire = BridgeLifecycleWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner, limits: limits)
        let bridge = BridgeBase(owner: owner), cell = await BridgeOrderingFeedCell(owner: owner)
        try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 10))
        cell.values.send(FlowElement(title: "large", content: .string(String(repeating: "x", count: 2048)), properties: .init(type: .event, contentType: .string)))
        await orderingEventually { wire.channelSession?.state == .closed }
        XCTAssertEqual(wire.commands.count, 0)
        XCTAssertEqual(bridge.pendingFeedDeliveries, 0)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
    }
}


extension BridgeFeedAndRPCOrderingTests {
    func testImmediateDescriptionReplyCompletesCallerBeforeSendReturns() async throws {
        let owner = await MockIdentityVault().identity(for: "early-description", makeNewIfNotFound: true)!
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
        bridge.rpcReplyTimeoutSeconds = 2
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound); try bridge.activateAuthenticatedChannel()
        wire.beforeAccept = { command in
            try await bridge.consumeResponse(command: orderingReply(to: command,
                payload: .description(AnyCell(uuid: "early-description", name: "early-description",
                    contractTemplate: Agreement(owner: owner), identityDomain: "early-description"))))
        }
        try await bridge.retrieveProxyRepresentation(for: owner)
        XCTAssertEqual(bridge.uuid, "early-description")
        XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }
}

extension BridgeFeedAndRPCOrderingTests {
    func testMuxUpstreamFailureClosesOnlyItsLogicalFeed() async throws {
        let owner = await MockIdentityVault().identity(for: "siblings", makeNewIfNotFound: true)!
        let bad = BridgeBase(owner: owner), good = BridgeBase(owner: owner), wire = BridgeLifecycleWire()
        let badCell = await BridgeOrderingFeedCell(owner: owner), goodCell = await BridgeOrderingFeedCell(owner: owner)
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let mux = BridgeMultiplexServerSession(physicalTransport: wire) { target, _, logical in
            let base = target == "bad" ? bad : good
            try await base.setTransport(logical, connection: .outbound)
            base.emitCellAtEndpoint = target == "bad" ? badCell : goodCell
            try base.activateAuthenticatedChannel()
            return base
        }
        for channel in ["bad", "good"] {
            try await mux.consumeCommand(command: .init(cmd: "openChannel", identity: owner, payload: nil, cid: 1,
                protocolVersion: 2, channelID: channel, targetEndpoint: channel))
            try await mux.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 2,
                protocolVersion: 2, channelID: channel))
        }
        badCell.values.send(completion: .failure(BridgeChannelAuthentication.Failure.unavailable))
        XCTAssertFalse(bad.feedActive)
        XCTAssertTrue(good.feedActive)
        try XCTUnwrap(wire.channelSession).check()
        goodCell.values.send(BridgeOrderingFeedCell.value(7))
        await orderingEventually { wire.commands.contains { command in
            if case let .flowElement(value) = command.payload { return command.channelID == "good" && value.title == "7" }; return false
        } }
        try XCTUnwrap(wire.channelSession).check()
        await mux.pushError(errorMessage: nil, error: BridgeChannelAuthentication.Failure.closed)
    }
}
