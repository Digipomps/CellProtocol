// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@preconcurrency import Combine
@_spi(Testing) @testable import CellBase

/// Loopback lifecycle guarantees (G1–G6) carried onto main's channel-authenticated
/// bridge. One test per guarantee; G6 is opt-in and its default is main's
/// non-blocking close (see BridgeRetirementOnChannelAuthTests).
final class BridgeLoopbackGuaranteeTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private final class Latch: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                done = true; defer { waiters.removeAll() }; return waiters
            }
            pending.forEach { $0.resume() }
        }
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in if done { return true }; waiters.append(c); return false }
                if now { c.resume() }
            }
        }
    }

    /// Answers description/connectEmitter/feed from inside sendData, before
    /// the send returns, like an in-process or loopback transport.
    private final class InlineWire: BridgeTransportProtocol, @unchecked Sendable {
        var channelSession: BridgeChannelSession?
        weak var bridge: BridgeBase?
        var feedElements = 1
        static func new() -> BridgeTransportProtocol { InlineWire() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { bridge = delegate as? BridgeBase }
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            switch command.command {
            case .connectEmitter:
                try await bridge?.consumeResponse(command: .init(cmd: "response", payload: .connectState(.connected), cid: command.cid))
            case .feed:
                for index in 0..<feedElements {
                    let element = FlowElement(title: "e\(index)", content: .string("\(index)"), properties: .init(type: .event, contentType: .string))
                    try await bridge?.consumeResponse(command: .init(cmd: "response", payload: .flowElement(element), cid: command.cid))
                }
            default: return
            }
        }
        func close() async { channelSession?.close() }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    }

    /// Holds every send (optionally only one command kind) until released.
    private final class HeldWire: BridgeTransportProtocol, @unchecked Sendable {
        var channelSession: BridgeChannelSession?
        weak var delegate: BridgeDelegateProtocol?
        let release = Latch()
        let sent = Flag(), closes = Flag()
        private let lock = NSLock(); private var frames: [BridgeCommand] = []
        var holdCommand: Command?
        var answerOpens = false
        static func new() -> BridgeTransportProtocol { HeldWire() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { frames.append(command) }
            if answerOpens, command.command == .openChannel {
                try await delegate?.consumeResponse(command: .init(cmd: "channelOpened", payload: nil, cid: command.cid,
                                                                   protocolVersion: 2, channelID: command.channelID))
                return
            }
            guard holdCommand == nil || command.command == holdCommand else { return }
            sent.add()
            await release.wait()
        }
        func close() async { closes.add(); channelSession?.close() }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
        func lastCID(_ kind: Command) -> Int? { lock.withLock { frames.last { $0.command == kind }?.cid } }
        func firstCID(_ kind: Command) -> Int? { lock.withLock { frames.first { $0.command == kind }?.cid } }
        func count(_ kind: Command, _ id: String? = nil) -> Int {
            lock.withLock { frames.filter { $0.command == kind && (id == nil || $0.channelID == id) }.count }
        }
    }

    private func owner(_ name: String = "owner") async -> Identity {
        await MockIdentityVault().identity(for: name, makeNewIfNotFound: true)!
    }

    private func until(_ seconds: Double = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func authenticated(_ wire: some BridgeTransportProtocol, owner: Identity,
                               setSession: (BridgeChannelSession) -> Void) async throws -> BridgeBase {
        setSession(try await authenticatedSessionFixture(principal: owner))
        let bridge = try await BridgeBase(.init(owner: owner, transport: wire, connection: .outbound))
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        return bridge
    }

    // G1 (attach): a connectEmitter response delivered inside the send is not lost.
    func testG1AttachResponseDeliveredInsideSendIsNotLost() async throws {
        let owner = await owner(), wire = InlineWire()
        let bridge = try await authenticated(wire, owner: owner) { wire.channelSession = $0 }
        let state = try await bridge.attach(emitter: BridgeBase(owner: owner), label: "fixture", requester: owner)
        XCTAssertEqual(state, .connected)
        await bridge.finishRetirement()
    }

    // G1 (feed): elements that arrive inside the .feed send, before the first
    // local subscriber, are delivered to that subscriber in order.
    func testG1FeedElementsBeforeFirstSubscriberAreDeliveredInOrder() async throws {
        let owner = await owner(), wire = InlineWire()
        wire.feedElements = 3
        let bridge = try await authenticated(wire, owner: owner) { wire.channelSession = $0 }
        let publisher = try await bridge.flow(requester: owner)
        let lock = NSLock(); var titles: [String] = []
        let subscription = publisher.sink(receiveCompletion: { _ in }, receiveValue: { e in lock.withLock { titles.append(e.title) } })
        await until { lock.withLock { titles.count } == 3 }
        XCTAssertEqual(lock.withLock { titles }, ["e0", "e1", "e2"])
        subscription.cancel()
        await bridge.finishRetirement()
    }

    // G2: the outbound feed start is owned work. With the owned-work quota held
    // full, the start is refused, the bridge retires and the physical finalizer
    // runs without an external join; nothing hangs.
    func testG2OutboundFeedStartRefusedByQuotaRetiresAndFinalizes() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.holdCommand = .dropFlow
        let bridge = try await authenticated(wire, owner: owner) { wire.channelSession = $0 }
        for _ in 0..<64 { bridge.dropFlow(label: "held", requester: owner) }
        await until { wire.sent.count == 64 }
        XCTAssertEqual(wire.sent.count, 64)
        XCTAssertFalse(bridge.isRetired, "the exact quota admits held control work")
        do { _ = try await bridge.flow(requester: owner); XCTFail("refused feed start must fail") } catch {}
        XCTAssertTrue(bridge.isRetired, "refusal is terminal")
        await until { wire.closes.count > 0 }
        XCTAssertEqual(wire.closes.count, 1, "refusal starts the physical finalizer")
        XCTAssertEqual(wire.count(.feed), 0, "no feed frame is sent after refusal")
        wire.release.open()
        await until { bridge.isFullyRetired }
        XCTAssertTrue(bridge.isFullyRetired, "cleanup completes without finishRetirement")
    }

    // G3: client channel close joins admitted work (setup and sends). Every
    // closer waits, the channel's capacity is held until return, and a close
    // started from inside the channel's own work does not deadlock.
    func testG3ClientChannelCloseJoinsWorkAndHoldsCapacity() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.answerOpens = true; wire.holdCommand = .get
        let session = BridgeMultiplexSession(physicalTransport: wire, maximumChannels: 2)
        let channel = try session.channelTransport(targetEndpoint: "a")
        let sibling = try session.channelTransport(targetEndpoint: "b")
        try await channel.setup(URL(string: "wss://fixture.invalid")!, identity: owner)
        let frame = BridgeCommand(cmd: "get", identity: owner, payload: .string("k"), cid: 1)
        let send = Task { try? await channel.sendData(JSONEncoder().encode(frame)) }
        await until { wire.sent.count == 1 }
        let done = Flag()
        let a = Task { await channel.close(); done.add() }
        let b = Task { await channel.close(); done.add() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(done.count, 0, "both closers join the held send")
        XCTAssertThrowsError(try session.channelTransport(targetEndpoint: "c"), "capacity held until return") {
            XCTAssertEqual($0 as? BridgeMultiplexError, .resourceLimitExceeded)
        }
        wire.release.open()
        await send.value; await a.value; await b.value
        XCTAssertEqual(done.count, 2)
        let next = try session.channelTransport(targetEndpoint: "c")
        await next.close(); await sibling.close()
    }

    func testG3ClientCloseFromInsideChannelWorkDoesNotJoinItself() async throws {
        final class SelfClosing: BridgeDelegateProtocol, @unchecked Sendable {
            let uuid = UUID().uuidString
            var channel: BridgeTransportProtocol?
            func consumeCommand(command: BridgeCommand) async throws {
                if command.command == .ready { return }
                await channel?.close()
            }
            func consumeResponse(command: BridgeCommand) async throws {}
            func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
            func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
            func pushError(errorMessage: String?, error: Error?) async {}
            func ready() async throws {}
        }
        let owner = await owner(), wire = HeldWire()
        wire.answerOpens = true; wire.holdCommand = .get
        let session = BridgeMultiplexSession(physicalTransport: wire)
        let channel = try session.channelTransport(targetEndpoint: "a") as! BridgeMultiplexChannelTransport
        let delegate = SelfClosing(); delegate.channel = channel
        channel.setDelegate(delegate)
        try await channel.setup(URL(string: "wss://fixture.invalid")!, identity: owner)
        let command = BridgeCommand(cmd: "get", identity: owner, payload: nil, cid: 2, protocolVersion: 2, channelID: channel.channelID)
        let work = Task { try await session.consumeCommand(command: command) }
        let returned = expectation(description: "self-close inside work returns")
        Task { _ = try? await work.value; returned.fulfill() }
        await fulfillment(of: [returned], timeout: 2)
        await channel.close()
    }

    // G4: a completed open does not keep its timeout work (and so the session
    // and its physical transport) alive.
    func testG4CompletedOpenDoesNotRetainSession() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.answerOpens = true; wire.holdCommand = .get // close frames pass unheld
        var session: BridgeMultiplexSession? = BridgeMultiplexSession(physicalTransport: wire, closesWhenIdle: true)
        weak var weakSession = session
        var channel: BridgeTransportProtocol? = try session!.channelTransport(targetEndpoint: "a")
        try await channel!.setup(URL(string: "wss://fixture.invalid")!, identity: owner)
        await channel!.close()
        channel = nil; session = nil
        await until(1) { weakSession == nil }
        XCTAssertNil(weakSession, "completed open must not retain timeout work")
    }

    // G5: a description response for a cid whose request timed out never
    // configures the bridge, even when the cid is audited again; the
    // replacement request's own response does.
    func testG5StaleDescriptionCidNeverConfigures() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.holdCommand = .feed // descriptions pass through unheld
        let bridge = try await authenticated(wire, owner: owner) { wire.channelSession = $0 }
        bridge.rpcReplyTimeoutSeconds = 1
        let initial = bridge.uuid
        let stale = try await BridgeBase(owner: owner).advertise(for: owner)
        let current = try await BridgeBase(owner: owner).advertise(for: owner)
        do { try await bridge.retrieveProxyRepresentation(for: owner); XCTFail("A must time out") } catch {}
        let staleCID = try XCTUnwrap(wire.firstCID(.description))
        let request = Task { try await bridge.retrieveProxyRepresentation(for: owner) }
        await until { wire.count(.description) == 2 }
        // Re-audit A's cid, then deliver A's late response.
        XCTAssertTrue(bridge.auditor.storeBridgeCommand(BridgeCommand(cmd: "description", identity: owner, payload: nil, cid: staleCID), for: staleCID))
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .description(stale), cid: staleCID))
        XCTAssertEqual(bridge.uuid, initial, "stale description must not configure")
        let currentCID = try XCTUnwrap(wire.lastCID(.description))
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .description(current), cid: currentCID))
        try await request.value
        XCTAssertEqual(bridge.uuid, current.uuid, "current request configures")
        await bridge.finishRetirement()
    }

    // G6 (opt-in): with closeJoinsChannelWork, every peer closeChannel joins
    // the delegate's held work, the ID and capacity stay reserved until it
    // returns, and the channel is reusable afterwards.
    func testG6OptInServerCloseJoinsWorkAndReservesID() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.holdCommand = .dropFlow
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let lock = NSLock(); var bridges: [BridgeBase] = []
        let session = BridgeMultiplexServerSession(physicalTransport: wire, maximumChannels: 1, closeJoinsChannelWork: true) { _, principal, transport in
            let bridge = BridgeBase(owner: principal)
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Target"))
            try bridge.activateAuthenticatedChannel()
            lock.withLock { bridges.append(bridge) }
            return bridge
        }
        func frame(_ kind: Command, _ id: String) -> BridgeCommand {
            BridgeCommand(cmd: kind.rawValue, identity: owner.publicIdentitySnapshot(), payload: nil, cid: 1,
                          protocolVersion: 2, channelID: id, targetEndpoint: kind == .openChannel ? "cell://localhost/Target" : nil)
        }
        try await session.consumeCommand(command: frame(.openChannel, "first"))
        let bridge = try XCTUnwrap(lock.withLock { bridges.first })
        bridge.dropFlow(label: "held", requester: owner)
        await until { wire.sent.count == 1 }
        let done = Flag()
        let a = Task { try? await session.consumeCommand(command: frame(.closeChannel, "first")); done.add() }
        let b = Task { try? await session.consumeCommand(command: frame(.closeChannel, "first")); done.add() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(done.count, 0, "every closer joins held channel work")
        XCTAssertTrue(bridge.isRetired); XCTAssertFalse(bridge.isFullyRetired)
        try await session.consumeCommand(command: frame(.openChannel, "first"))
        XCTAssertEqual(wire.count(.channelOpened, "first"), 1, "the ID stays reserved through the join")
        XCTAssertEqual(wire.count(.channelRejected, "first"), 1)
        wire.release.open()
        await a.value; await b.value
        XCTAssertEqual(done.count, 2)
        XCTAssertTrue(bridge.isFullyRetired)
        try await session.consumeCommand(command: frame(.openChannel, "first"))
        XCTAssertEqual(wire.count(.channelOpened, "first"), 2, "capacity reusable after the join")
        await session.closeAndJoin()
    }

    // G6: closeAndJoin also joins a session control send in flight.
    func testG6CloseAndJoinJoinsServerControlSend() async throws {
        let owner = await owner(), wire = HeldWire()
        wire.holdCommand = .response
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        let session = BridgeMultiplexServerSession(physicalTransport: wire) { _, principal, _ in BridgeBase(owner: principal) }
        let send = Task { await session.sendCommand(command: .response, identity: owner, payload: .string("x")) }
        await until { wire.sent.count == 1 }
        let done = Flag()
        let a = Task { await session.closeAndJoin(); done.add() }
        let b = Task { await session.closeAndJoin(); done.add() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(done.count, 0, "closeAndJoin waits for the held control send")
        wire.release.open()
        await send.value; await a.value; await b.value
        XCTAssertEqual(done.count, 2)
    }

    // G2 (inbound): a feed value refused by the channel quota is terminal for
    // the bridge; retirement closes the physical transport once and finishes
    // after the held drain returns, without an external join. A value whose
    // frame exceeds the peer's 1 MiB inbound limit is refused the same way.
    func testG2InboundFeedQuotaRefusalIsTerminal() async throws {
        final class Pusher: FlowElementPusherCell {
            override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> { getFeedPublisher() }
        }
        for oversized in [false, true] {
            let prior = CellBase.defaultCellResolver
            let resolver = CellResolver.makeIsolatedForTesting(); CellBase.defaultCellResolver = resolver
            let owner = await owner("feed-\(oversized)")
            let cell = Pusher(owner: owner), wire = HeldWire()
            wire.holdCommand = .response
            try await resolver.registerNamedEmitCell(name: "Target", emitCell: cell, scope: .scaffoldUnique, identity: owner)
            wire.channelSession = try await authenticatedSessionFixture(principal: owner)
            let bridge = try await BridgeBase(.init(owner: owner, transport: wire, connection: .inbound(publisherUuid: "Target"), inboundPublisherLookupIdentity: owner))
            try await bridge.setTransport(wire, connection: .inbound(publisherUuid: "Target"))
            try bridge.activateAuthenticatedChannel()
            try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 7))
            XCTAssertTrue(bridge.feedActive)
            let small = FlowElement(title: "v", content: .string("x"), properties: .init(type: .event, contentType: .string))
            if oversized {
                let big = FlowElement(title: "v", content: .string(String(repeating: "x", count: 1024 * 1024 + 1)), properties: .init(type: .event, contentType: .string))
                cell.pushFlowElement(big, requester: owner)
            } else {
                for _ in 0..<32 { cell.pushFlowElement(small, requester: owner) }
                await until { wire.sent.count == 1 }
                XCTAssertFalse(bridge.isRetired, "the exact queue budget keeps the feed live")
                XCTAssertEqual(wire.sent.count, 1, "main's drain is ordered: one send in flight")
                cell.pushFlowElement(small, requester: owner)
            }
            XCTAssertTrue(bridge.isRetired && !bridge.feedActive, "refusal is terminal")
            await until { wire.closes.count > 0 }
            XCTAssertEqual(wire.closes.count, 1, "one physical close")
            wire.release.open()
            await until { bridge.isFullyRetired }
            XCTAssertTrue(bridge.isFullyRetired, "cleanup completes without finishRetirement")
            CellBase.defaultCellResolver = prior
        }
    }
}
